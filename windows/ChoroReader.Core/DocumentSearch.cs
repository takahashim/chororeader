using System.Globalization;

namespace ChoroReader.Core;

public sealed record SearchResult(
    Locator Locator,
    string ChapterTitle,
    string Before,
    string Match,
    string After,
    bool IsCode);

public sealed record SearchOutcome(IReadOnlyList<SearchResult> Results, bool Truncated);

public static class DocumentSearch
{
    public const int ResultLimit = 400;

    /// <summary>
    /// 日本語では単語境界が定まらないため、標準は部分一致とする。
    /// 全角と半角、大文字と小文字、濁点の合成の違いを区別しない。
    /// </summary>
    private const CompareOptions Options =
        CompareOptions.IgnoreCase | CompareOptions.IgnoreWidth | CompareOptions.IgnoreNonSpace;

    public static SearchOutcome SearchEpub(IResourceProvider resources, EpubPublication publication, string query)
    {
        var results = new List<SearchResult>();
        var truncated = false;
        var comparer = CompareInfo.GetCompareInfo("ja-JP");

        foreach (var link in publication.ReadingOrder)
        {
            if (truncated)
            {
                break;
            }

            byte[] data;
            try
            {
                data = resources.Read(link.Href);
            }
            catch (Exception)
            {
                continue;
            }

            var title = publication.TitleForHref(link.Href) ?? EpubParser.LastComponent(link.Href);
            var extracted = HtmlText.Extract(CssCompat.DecodeText(data));
            var text = extracted.Text;
            if (text.Length == 0)
            {
                continue;
            }

            var searchStart = 0;
            while (searchStart <= text.Length)
            {
                var found = comparer.IndexOf(text, query, searchStart, text.Length - searchStart, Options);
                if (found < 0)
                {
                    break;
                }

                // 照合の長さは元の文字列側で数える。全角半角の違いで長さが変わりうるため。
                var matchLength = MatchLength(comparer, text, found, query);
                var before = text[Math.Max(0, found - 30)..found].Trim();
                var afterStart = Math.Min(text.Length, found + matchLength);
                var after = text[afterStart..Math.Min(text.Length, afterStart + 40)].Trim();
                var snippetEnd = Math.Min(text.Length, found + Math.Max(matchLength, 12));

                results.Add(new SearchResult(
                    new Locator
                    {
                        Href = link.Href,
                        Progression = text.Length == 0 ? 0 : (double)found / text.Length,
                        Title = title,
                        Text = text[found..snippetEnd],
                    },
                    title,
                    before,
                    text[found..afterStart],
                    after,
                    extracted.IsCode(found)));

                if (results.Count >= ResultLimit)
                {
                    truncated = true;
                    break;
                }
                searchStart = found + Math.Max(matchLength, 1);
            }
        }

        return new SearchOutcome(results, truncated);
    }

    /// <summary>照合した範囲の長さを、元の文字列側の文字数で求める。</summary>
    private static int MatchLength(CompareInfo comparer, string text, int start, string query)
    {
        var remaining = text.Length - start;
        for (var length = 1; length <= remaining; length++)
        {
            if (comparer.Compare(text, start, length, query, 0, query.Length, Options) == 0)
            {
                return length;
            }
        }
        return Math.Min(query.Length, remaining);
    }
}
