using System.Text;
using System.Text.RegularExpressions;

namespace ChoroReader.Core;

/// <summary>
/// 章の HTML から本文とコードを取り出す。索引は作らず、要求されたときに走査する。
/// 抽出結果は検索の位置計算に使うため、macOS 版と同じ文字列になる必要がある。
/// </summary>
public static class HtmlText
{
    public sealed record Extracted(string Text, IReadOnlyList<(int Start, int End)> CodeRanges)
    {
        public bool IsCode(int offset) => CodeRanges.Any(r => offset >= r.Start && offset < r.End);
    }

    private static readonly Dictionary<string, string> Entities = new(StringComparer.Ordinal)
    {
        ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = "\"", ["&apos;"] = "'",
        ["&nbsp;"] = " ", ["&mdash;"] = "—", ["&ndash;"] = "–", ["&hellip;"] = "…",
    };

    public static Extracted Extract(string html)
    {
        var source = html;
        source = Regex.Replace(source, @"<script\b[^>]*>.*?</script>", string.Empty,
                               RegexOptions.Singleline | RegexOptions.IgnoreCase);
        source = Regex.Replace(source, @"<style\b[^>]*>.*?</style>", string.Empty,
                               RegexOptions.Singleline | RegexOptions.IgnoreCase);
        source = Regex.Replace(source, @"<!--.*?-->", string.Empty, RegexOptions.Singleline);

        var text = new StringBuilder();
        var codeRanges = new List<(int, int)>();
        var cursor = 0;

        foreach (Match match in Regex.Matches(source, @"<pre\b[^>]*>(.*?)</pre>",
                                              RegexOptions.Singleline | RegexOptions.IgnoreCase))
        {
            text.Append(StripTags(source[cursor..match.Index]));
            var start = text.Length;
            text.Append(StripTags(match.Groups[1].Value));
            codeRanges.Add((start, text.Length));
            text.Append('\n');
            cursor = match.Index + match.Length;
        }
        text.Append(StripTags(source[cursor..]));

        return new Extracted(text.ToString(), codeRanges);
    }

    public static string StripTags(string source)
    {
        var output = new StringBuilder(source.Length);
        var insideTag = false;
        var lastWasSpace = false;

        foreach (var c in source)
        {
            if (c == '<')
            {
                insideTag = true;
                continue;
            }
            if (c == '>')
            {
                insideTag = false;
                if (!lastWasSpace)
                {
                    output.Append(' ');
                    lastWasSpace = true;
                }
                continue;
            }
            if (insideTag)
            {
                continue;
            }
            if (c is '\n' or '\r' or '\t')
            {
                if (!lastWasSpace)
                {
                    output.Append(' ');
                    lastWasSpace = true;
                }
                continue;
            }
            output.Append(c);
            lastWasSpace = c == ' ';
        }

        return DecodeEntities(output.ToString());
    }

    private static string DecodeEntities(string source)
    {
        if (!source.Contains('&'))
        {
            return source;
        }
        var result = source;
        foreach (var (from, to) in Entities)
        {
            result = result.Replace(from, to, StringComparison.Ordinal);
        }
        if (!result.Contains("&#", StringComparison.Ordinal))
        {
            return result;
        }
        return Regex.Replace(result, @"&#(x?)([0-9A-Fa-f]+);", match =>
        {
            var radix = match.Groups[1].Value.Length == 0 ? 10 : 16;
            try
            {
                var code = Convert.ToInt32(match.Groups[2].Value, radix);
                return char.ConvertFromUtf32(code);
            }
            catch (Exception)
            {
                return match.Value;
            }
        });
    }
}
