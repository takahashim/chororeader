namespace ChoroReader.Core;

/// <summary>
/// 巻末の用語索引がどこからどこまでかを見つける。
///
/// <para>
/// 意味の近さで引くと、<b>索引の紙面が上位に来る</b>。語がひたすら並んでいるので
/// 何にでも少しずつ似てしまう。並べ直し（reranker）でも直らない
/// （spikes/findings-reranker.md）。
/// </para>
/// <para>
/// <b>まず目次の項目名で決める。</b>蔵書で数えたところ（EPUB 8 冊・PDF 9 冊、2026-08-08）、
/// 索引を持つ本（EPUB 4・PDF 5）は<b>すべて目次に載せていた</b>し、
/// 持たない本を誤って拾うこともなかった。索引を持つ本は必ず目次に載せる、というだけのことである。
/// <c>epub:type="index"</c> は当てにしない。標本では 1 冊も付けていなかった。
/// </para>
/// <para>
/// <b>形だけでは判定しない。</b>EPUB で試したところ、索引を持たない 4 冊のうち
/// <b>3 冊</b>で「索引らしい章」を誤検出した。見出しと組にして初めて使える。
/// </para>
/// <para>
/// <b>巻末に無ければ見ない。</b>本文の途中に「索引」という節があっても触らない
/// （データベースの索引を説明する章など）。
/// 標本では索引の始まりは EPUB で 92〜97%、PDF で 97〜98% だった。
/// </para>
/// </summary>
public static class BackIndex
{
    /// <summary>
    /// これより手前から始まるものは索引と見なさない。
    ///
    /// <para>
    /// 実測の最小が 92% なので、少し余裕を見て 0.8 に置く。
    /// ここを厳しくすると、前書きの長い本で取りこぼす。
    /// </para>
    /// </summary>
    public const double LeastPlace = 0.8;

    /// <summary>
    /// 索引の見出しとして認める名前。<b>完全一致で見る。</b>
    /// 「索引の作り方」のような節を巻き込まないため、部分一致にはしない。
    /// </summary>
    private static readonly string[] Names = ["索引", "さくいん", "用語索引", "事項索引", "index"];

    /// <summary>索引らしいと見なす、数字を含む行の割合。実測は 0.56〜0.96 だった。</summary>
    private const double LeastDigitLines = 0.5;

    /// <summary>これより行が少ない頁は見ない。扉や白紙を拾わないため。</summary>
    private const int LeastLines = 15;

    /// <summary>その見出しが索引か。空白は取り除いて比べる。</summary>
    public static bool IsIndexName(string title)
    {
        var bare = string.Concat(title.Where(c => !char.IsWhiteSpace(c) && c != '　')).ToLowerInvariant();
        return Names.Contains(bare);
    }

    /// <summary>始まりと終わり。終わりは含まない。</summary>
    public readonly record struct Span(int From, int Until)
    {
        public bool Contains(int at) => at >= From && at < Until;
    }

    // MARK: EPUB

    /// <summary>
    /// 読み順のうち、索引が占める範囲。無ければ null。
    ///
    /// <para>
    /// 始まりは目次の「索引」の飛び先、終わりは<b>その次の目次項目</b>（奥付など）。
    /// 次が無ければ本の末尾までとする。
    /// </para>
    /// </summary>
    public static Span? Of(EpubPublication publication)
    {
        var total = publication.ReadingOrder.Count;
        if (total == 0)
        {
            return null;
        }

        var places = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var at = 0; at < total; at++)
        {
            places.TryAdd(publication.ReadingOrder[at].Href, at);
        }

        var ordered = Flatten(publication.TableOfContents)
            .Select(entry => entry.Href is { } href && places.TryGetValue(href, out var at)
                ? ((int Place, string Title)?)(at, entry.Title)
                : null)
            .Where(one => one is not null)
            .Select(one => one!.Value)
            .OrderBy(one => one.Place)
            .ToList();

        var hit = ordered.FindIndex(one => IsIndexName(one.Title));
        if (hit < 0)
        {
            return null;
        }

        var from = ordered[hit].Place;
        if ((double)from / total < LeastPlace)
        {
            return null;
        }

        // 同じ章を指す項目が続くことがあるので、**先へ進んだ**最初の項目を終わりにする。
        var next = ordered.Skip(hit + 1).FirstOrDefault(one => one.Place > from);
        var until = next.Place > from ? next.Place : total;
        return new Span(from, until);
    }

    private static IEnumerable<TocEntry> Flatten(IReadOnlyList<TocEntry> entries)
    {
        foreach (var entry in entries)
        {
            yield return entry;
            foreach (var child in Flatten(entry.Children))
            {
                yield return child;
            }
        }
    }

    // MARK: PDF

    /// <summary>
    /// ページのうち、索引が占める範囲。無ければ null。
    ///
    /// <para>
    /// <b>アウトラインを先に見て、無ければ本文で探す。</b>しおりを持たない PDF は珍しくない。
    /// </para>
    /// </summary>
    public static Span? Of(PdfInspector paper, IReadOnlyList<string> pageTitles) =>
        Of(pageTitles) ?? ByText(paper);

    /// <summary>
    /// アウトラインの見出しから決める。
    ///
    /// <para>
    /// 節の見出しは次の区切りまで引き継がれるので、<b>名前が索引であるページを拾うだけで
    /// 始まりと終わりが決まる。</b>
    /// </para>
    /// </summary>
    public static Span? Of(IReadOnlyList<string> pageTitles)
    {
        var total = pageTitles.Count;
        if (total == 0)
        {
            return null;
        }

        var from = -1;
        for (var at = 0; at < total; at++)
        {
            if (IsIndexName(pageTitles[at]))
            {
                from = at;
                break;
            }
        }
        if (from < 0 || (double)from / total < LeastPlace)
        {
            return null;
        }

        var until = from;
        while (until < total && IsIndexName(pageTitles[until]))
        {
            until++;
        }
        return new Span(from, until);
    }

    /// <summary>
    /// しおりが無いときに、紙面から探す。
    ///
    /// <para>
    /// 手元の PDF 9 冊で、<b>アウトラインから取れる正解を隠して</b>測った（2026-08-08）。
    /// 索引を持つ 5 冊はすべて当て、始まりは全冊ぴたり。持たない 4 冊で誤検出は無し。
    /// 終わりのずれは −1 〜 +2 ページだった。
    /// </para>
    /// <para>
    /// 手掛かりは 2 つだけである。
    /// </para>
    /// <list type="bullet">
    /// <item><b>頁の頭に「索引」の見出しがある。</b>5 冊すべてで取れた。
    /// 柱や頁番号が先に来るので、頭の 3 行まで見る</item>
    /// <item><b>数字を含む行が多い。</b>頁番号がぶら下がるためで、実測 0.56〜0.96 だった</item>
    /// </list>
    /// <para>
    /// <b>行の短さは使わない。</b>索引らしさの筋は良いが、取り出した本文は段組みを
    /// 1 行に繋いでしまうので、実測は 0.06〜0.95 とばらついて当てにならない。
    /// </para>
    /// <para>
    /// 本文で探すのは巻末だけなので、読むのは全体の 2 割で足りる。
    /// </para>
    /// </summary>
    private static Span? ByText(PdfInspector paper)
    {
        var total = paper.PageCount;
        if (total == 0)
        {
            return null;
        }

        var looksLike = new Dictionary<int, bool>();
        var titled = new Dictionary<int, bool>();

        void Look(int page)
        {
            if (looksLike.ContainsKey(page))
            {
                return;
            }
            var lines = paper.TextOfPage(page)
                .Split('\n')
                .Select(line => line.Trim())
                .Where(line => line.Length > 0)
                .ToList();
            if (lines.Count < LeastLines)
            {
                looksLike[page] = false;
                titled[page] = false;
                return;
            }
            var digits = lines.Count(line => line.Any(char.IsDigit));
            looksLike[page] = (double)digits / lines.Count > LeastDigitLines;
            // 柱や頁番号が先に来るので、頭の数行まで見る。
            titled[page] = lines.Take(3).Any(IsIndexName);
        }

        var tail = (int)(total * LeastPlace);
        var from = -1;
        for (var page = tail; page < total; page++)
        {
            Look(page);
            if (titled[page] && looksLike[page])
            {
                from = page;
                break;
            }
        }
        if (from < 0)
        {
            return null;
        }

        var until = from + 1;
        while (until < total)
        {
            Look(until);
            if (!looksLike[until])
            {
                break;
            }
            until++;
        }
        return new Span(from, until);
    }

    /// <summary>
    /// ページごとの「いまどの節か」。アウトラインから引く。
    ///
    /// <para>
    /// <b>アウトラインのページは 0 始まりである</b>（PdfOutlineTests が押さえている）。
    /// </para>
    /// </summary>
    public static IReadOnlyList<string> PageTitles(PdfInspector paper)
    {
        var titles = new string[paper.PageCount];
        Array.Fill(titles, string.Empty);
        if (titles.Length == 0)
        {
            return titles;
        }

        var marks = Flatten(paper.Outline())
            .Where(entry => entry.Page is >= 0)
            .Select(entry => (Page: entry.Page!.Value, entry.Title))
            .OrderBy(mark => mark.Page)
            .ToList();

        var current = string.Empty;
        var next = 0;
        for (var page = 0; page < titles.Length; page++)
        {
            while (next < marks.Count && marks[next].Page <= page)
            {
                current = marks[next].Title;
                next++;
            }
            titles[page] = current;
        }
        return titles;
    }
}
