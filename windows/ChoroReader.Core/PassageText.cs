using System.Text.RegularExpressions;

namespace ChoroReader.Core;

/// <summary>
/// 当たった段落の本文を、<b>原書から切り出す</b>。
///
/// <para>
/// 索引は本文を控えない（<see cref="SemanticUnit"/>）。二字組索引が候補を絞ってから
/// 原書を走査し直すのと同じで、意味の索引も地図であって写しではない
/// （spec.md 10.4、spec-local-ai.md 2 章の 3）。
/// 控えていた頃は<b>本の 35% が原文のまま索引ファイルに入っていた</b>。
/// </para>
/// </summary>
public static class PassageText
{
    /// <summary>
    /// 切り出す長さ。<b>段落 1 つぶん</b>（切り出しの目安が 400 字）。
    ///
    /// <para>
    /// 一覧には 2〜3 行しか出さないので、見せるだけなら 160 字で足りる。
    /// それより長く採るのは<b>並べ直し（Level 2）のため</b>である。
    /// cross-encoder は本文を読んで点を付けるので、頭の 160 字で切ると、
    /// 段落の後半で答えている候補を落とす。
    /// </para>
    /// </summary>
    public const int DisplayCharacters = 480;

    private static readonly Regex Spaces = new(@"\s+");

    /// <summary>
    /// 1 冊ぶんをまとめて切り出す。
    ///
    /// <para>
    /// <b>書籍は 1 度だけ開く。</b>1 件ごとに開き直すと、40 件で 40 回開くことになる。
    /// </para>
    /// <para>
    /// <b>画面のスレッドから呼んではいけない。</b>章やページを読む。
    /// 返すのは<b>渡した並びの番号</b>で引ける形。単位そのものを鍵にすると、
    /// 同じ頁の段落どうしが重なって取りこぼす（PDF は章も頁も位置も同じで、違うのは目印だけ）。
    /// </para>
    /// </summary>
    public static IReadOnlyDictionary<int, string> Read(
        IReadOnlyList<SemanticUnit> units, string bookPath, int limit = DisplayCharacters)
    {
        var made = new Dictionary<int, string>();
        if (units.Count == 0)
        {
            return made;
        }

        // 同じ章（ページ）を何度も取り出さない。
        var pages = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            if (DocumentFormats.Detect(bookPath) == DocumentFormat.Pdf)
            {
                using var paper = PdfInspector.Open(bookPath);
                for (var at = 0; at < units.Count; at++)
                {
                    if (units[at].Locator.Page is not { } page || page < 0 || page >= paper.PageCount)
                    {
                        continue;
                    }
                    var key = $"p{page}";
                    if (!pages.TryGetValue(key, out var whole))
                    {
                        whole = Tidy(paper.TextOfPage(page));
                        pages[key] = whole;
                    }
                    if (whole.Length > 0)
                    {
                        made[at] = Cut(whole, units[at].Locator, limit);
                    }
                }
                return made;
            }

            using var archive = new EpubArchive(bookPath);
            for (var at = 0; at < units.Count; at++)
            {
                if (units[at].Locator.Href is not { Length: > 0 } href)
                {
                    continue;
                }
                if (!pages.TryGetValue(href, out var whole))
                {
                    whole = archive.ReadText(href) is { } source
                        ? Tidy(HtmlText.Extract(source).Text)
                        : string.Empty;
                    pages[href] = whole;
                }
                if (whole.Length > 0)
                {
                    made[at] = Cut(whole, units[at].Locator, limit);
                }
            }
        }
        catch (Exception)
        {
            // 読めない書籍はある。切り出せたぶんだけ返す。
        }
        return made;
    }

    /// <summary>
    /// 切り出す場所を決めて、そこから採る。
    ///
    /// <para>
    /// <b>採るのは長さで切るだけで、段落の終わりでは止まらない。</b>
    /// 単位は始まりの位置しか控えていないので、終わりが分からない（終わりも控えると索引が太る）。
    /// 短い段落では次の段落へはみ出すが、見せる側は 2〜3 行に切るので目に見えず、
    /// 並べ直す側にとっては前後の文脈が少し混じるだけである。
    /// </para>
    /// </summary>
    private static string Cut(string whole, Locator locator, int limit)
    {
        var from = Start(whole, locator, limit);
        var rest = whole[from..];
        return rest.Length > limit ? rest[..limit] + "…" : rest;
    }

    /// <summary>
    /// <b>EPUB は位置が答えである。</b>章の中の位置を 10 万分の 1 まで持っているので、
    /// 1,000 字の章なら 0.01 字の粗さになる。目印はその答え合わせに使う。
    ///
    /// <para>
    /// <b>目印だけで探すと外れる。</b>繰り返しの多い本文（箇条書き、定型の言い回し、
    /// 同じ説明の続く節）では、手前の同じ並びに当たるためである。
    /// </para>
    /// <para>
    /// PDF は頁の中の位置を持たない（頁で既に絞れている）ので、目印で探す。
    /// </para>
    /// </summary>
    private static int Start(string whole, Locator locator, int limit)
    {
        var anchor = locator.Text is { Length: > 0 } text ? text : null;

        if (locator.Href is null)
        {
            // PDF。目印で探し、無ければ頁の頭から。
            if (anchor is null)
            {
                return 0;
            }
            var found = whole.IndexOf(anchor, StringComparison.Ordinal);
            return found >= 0 ? found : 0;
        }

        var approximate = Math.Clamp(
            (int)Math.Round(whole.Length * locator.Progression, MidpointRounding.AwayFromZero),
            0, whole.Length);
        if (anchor is null)
        {
            return approximate;
        }

        // 位置の先が目印と合っていれば、それが答え。
        if (whole.AsSpan(approximate).StartsWith(anchor))
        {
            return approximate;
        }

        // 合わなければ、位置のまわりで**いちばん近い**ところを採る。
        // 「位置以降で最初」にすると、繰り返しの本文で手前に寄る。
        var low = Math.Max(0, approximate - limit);
        var high = Math.Min(whole.Length, approximate + limit);
        var best = -1;
        var search = low;
        while (search < high)
        {
            var found = whole.IndexOf(anchor, search, high - search, StringComparison.Ordinal);
            if (found < 0)
            {
                break;
            }
            if (best < 0 || Math.Abs(found - approximate) < Math.Abs(best - approximate))
            {
                best = found;
            }
            search = found + 1;
        }
        return best >= 0 ? best : approximate;
    }

    private static string Tidy(string text) => Spaces.Replace(text, " ").Trim();
}
