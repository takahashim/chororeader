using System.Text;

namespace ChoroReader.Core;

/// <param name="Nth">
/// 読み順の 1 項目の中で何番目の当たりか。
/// 飛んだ先で「押したのはこの語のどれか」を選び直すために使う。
/// </param>
public sealed record SearchResult(
    Locator Locator,
    string ChapterTitle,
    string Before,
    string Match,
    string After,
    bool IsCode,
    int Nth);

public sealed record SearchOutcome(IReadOnlyList<SearchResult> Results, bool Truncated);

/// <summary>章を順に走査して照合位置を返す。索引は持たない。</summary>
public static class DocumentSearch
{
    public const int ResultLimit = 400;

    public static SearchOutcome SearchEpub(
        IResourceProvider resources, EpubPublication publication, string query) =>
        SearchEpubWithin(resources, publication, query, null, ResultLimit);

    /// <summary>
    /// 読み順のうち <paramref name="only"/> に挙がった位置だけを走査する。null なら全部。
    /// </summary>
    public static SearchOutcome SearchEpubWithin(
        IResourceProvider resources,
        EpubPublication publication,
        string query,
        IReadOnlyCollection<int>? only,
        int limit)
    {
        var results = new List<SearchResult>();
        var truncated = false;

        var needle = Fold.Text(query);
        if (needle.Count == 0)
        {
            return new SearchOutcome(results, truncated);
        }

        for (var position = 0; position < publication.ReadingOrder.Count; position++)
        {
            if (truncated)
            {
                break;
            }
            if (only is not null && !only.Contains(position))
            {
                continue;
            }
            var link = publication.ReadingOrder[position];
            var source = resources.ReadText(link.Href);
            if (source is null)
            {
                continue;
            }

            var title = publication.TitleForHref(link.Href) ?? EpubParser.LastComponent(link.Href);
            var extracted = HtmlText.Extract(source);
            var runes = Runes(extracted.Text);
            if (runes.Count == 0)
            {
                continue;
            }

            // 通し番号は読み順の項目ごとに数え直す。同じ経路が読み順に 2 度出ることがあり、
            // そのときは同じ文書を 2 度開くので、番号も 0 から振り直さないと選び直せない。
            var nth = 0;
            foreach (var (found, matchEnd) in Matches(runes, needle))
            {
                var snippetEnd = Math.Min(runes.Count, found + Math.Max(matchEnd - found, 12));

                results.Add(new SearchResult(
                    new Locator
                    {
                        Href = link.Href,
                        Progression = (double)found / runes.Count,
                        Title = title,
                        Text = Slice(runes, found, snippetEnd),
                    },
                    title,
                    Slice(runes, Math.Max(0, found - 30), found).Trim(),
                    Slice(runes, found, matchEnd),
                    Slice(runes, matchEnd, Math.Min(runes.Count, matchEnd + 40)).Trim(),
                    extracted.IsCode(found),
                    nth));
                nth++;

                if (results.Count >= limit)
                {
                    truncated = true;
                    break;
                }
            }
        }

        return new SearchOutcome(results, truncated);
    }

    /// <summary>
    /// 本文の中で nth 番目の当たりが占める範囲（文字単位、終わりは含まない）。
    ///
    /// 走査と同じ畳み方で数えるので、検索が返した通し番号と、ここで選ぶ当たりは必ず一致する。
    /// 当たりを強調するとき、どの語を囲むかをこれで決める。
    /// </summary>
    public static (int From, int To)? NthMatch(string text, string query, int nth)
    {
        foreach (var found in Matches(Runes(text), Fold.Text(query)))
        {
            if (nth-- == 0)
            {
                return found;
            }
        }
        return null;
    }

    /// <summary>
    /// 本文に当たる語が現れる範囲を、元の文字位置で順に返す。
    ///
    /// 走査も強調も、当たりを数えるのはここ 1 か所にする。
    /// 別々に数えると、畳み方を変えたときに片方だけ直り、
    /// 検索が言う「何番目」と、強調が囲む語が食い違う。
    /// </summary>
    private static IEnumerable<(int From, int To)> Matches(
        IReadOnlyList<Rune> runes, IReadOnlyList<Rune> needle)
    {
        if (needle.Count == 0)
        {
            yield break;
        }
        var haystack = Fold.All(runes);
        var total = runes.Count;
        var from = 0;

        while (from + needle.Count <= haystack.Folded.Count)
        {
            var hit = Find(haystack.Folded, from, needle);
            if (hit < 0)
            {
                yield break;
            }
            var found = haystack.Origin[hit];
            // 照合の長さは元の文字列側で数える。畳んだ結果と長さが変わりうるため。
            var length = OriginalLength(haystack, hit, needle.Count, total);
            from = hit + 1;
            yield return (found, Math.Min(found + length, total));
        }
    }

    /// <summary>畳んだ列の何文字ぶんが、元の何文字に当たるかを求める。</summary>
    private static int OriginalLength(Fold.Folding haystack, int foldedAt, int needleLength, int total)
    {
        var start = haystack.Origin[foldedAt];
        var end = foldedAt + needleLength < haystack.Origin.Count
            ? haystack.Origin[foldedAt + needleLength]
            : total;
        return Math.Max(end - start, 1);
    }

    /// <summary><paramref name="from"/> 以降で最初に一致する位置。見つからなければ -1。</summary>
    private static int Find(IReadOnlyList<Rune> haystack, int from, IReadOnlyList<Rune> needle)
    {
        for (var start = from; start + needle.Count <= haystack.Count; start++)
        {
            var same = true;
            for (var offset = 0; offset < needle.Count; offset++)
            {
                if (haystack[start + offset] != needle[offset])
                {
                    same = false;
                    break;
                }
            }
            if (same)
            {
                return start;
            }
        }
        return -1;
    }

    public static List<Rune> Runes(string text)
    {
        var runes = new List<Rune>(text.Length);
        foreach (var rune in text.EnumerateRunes())
        {
            runes.Add(rune);
        }
        return runes;
    }

    private static string Slice(IReadOnlyList<Rune> runes, int start, int end)
    {
        start = Math.Min(start, runes.Count);
        end = Math.Clamp(end, start, runes.Count);
        var text = new StringBuilder(end - start);
        for (var index = start; index < end; index++)
        {
            text.Append(runes[index].ToString());
        }
        return text.ToString();
    }
}
