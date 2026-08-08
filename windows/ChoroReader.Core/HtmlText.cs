using System.Text;
using System.Text.RegularExpressions;

namespace ChoroReader.Core;

/// <summary>
/// 章の HTML から本文とコードを取り出す。索引は作らず、要求されたときに走査する。
/// 抽出結果は検索の位置計算に使うため、他の実装と同じ文字列になる必要がある。
/// </summary>
public static class HtmlText
{
    /// <param name="CodeRanges">本文中でコードが占める範囲。単位は Unicode スカラー。</param>
    /// <param name="Origins">
    /// 本文の 1 文字ごとに、元の HTML でその文字が始まる位置（UTF-16 の単位）。
    ///
    /// 抽出は削って詰めるだけなので、削りながら控えておけば元へ戻せる。
    /// 別に辿り直すと規則が二重になり、片方だけ直したときに黙ってずれる。
    /// </param>
    public sealed record Extracted(
        string Text,
        IReadOnlyList<(int Start, int End)> CodeRanges,
        IReadOnlyList<int> Origins)
    {
        public bool IsCode(int offset) => CodeRanges.Any(r => offset >= r.Start && offset < r.End);
    }

    /// <summary>
    /// 名前付き実体。並びのとおりに、全体を 1 つずつ均す。
    /// <c>&amp;amp;lt;</c> が <c>&lt;</c> になるのはこの順序による。1 文字ずつ解くと結果が変わる。
    /// </summary>
    private static readonly (string From, string To)[] Entities =
    [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
        ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
    ];

    private const RegexOptions Options = RegexOptions.Singleline | RegexOptions.IgnoreCase;

    /// <summary>
    /// 本文に混ぜないところ。
    ///
    /// head は画面に出ない。題名（title）を本文として数えると、
    /// 検索が「見えないところに当たった」と言い、飛んでも何も無いことになる。
    /// </summary>
    private static readonly Regex[] Ignored =
    [
        new(@"<head\b[^>]*>.*?</head>", Options),
        new(@"<script\b[^>]*>.*?</script>", Options),
        new(@"<style\b[^>]*>.*?</style>", Options),
        new(@"<!--.*?-->", Options),
    ];

    private static readonly Regex Pre = new(@"<pre\b[^>]*>(.*?)</pre>", Options);
    private static readonly Regex Numeric = new(@"&#(x?)([0-9A-Fa-f]+);");

    /// <summary>本文に混ぜないところを抜いた並び。位置は元の HTML へ戻せる。</summary>
    private sealed class Body
    {
        /// <summary>(この並びでの始まり, 元の HTML での始まり)。残した断片ごとに 1 つ。</summary>
        private readonly List<(int Start, int From)> _pieces;

        public string Text { get; }

        private Body(string text, List<(int Start, int From)> pieces)
        {
            Text = text;
            _pieces = pieces;
        }

        public static Body Of(string html)
        {
            var ranges = new List<(int From, int To)>();
            foreach (var pattern in Ignored)
            {
                foreach (Match match in pattern.Matches(html))
                {
                    ranges.Add((match.Index, match.Index + match.Length));
                }
            }
            ranges.Sort((a, b) => a.From != b.From ? a.From.CompareTo(b.From) : a.To.CompareTo(b.To));

            var text = new StringBuilder(html.Length);
            var pieces = new List<(int, int)>();
            var at = 0;
            foreach (var (from, to) in ranges)
            {
                if (from > at)
                {
                    pieces.Add((text.Length, at));
                    text.Append(html, at, from - at);
                }
                // 入れ子や重なりがあるので、後ろへ戻さない。
                at = Math.Max(at, to);
            }
            if (at < html.Length)
            {
                pieces.Add((text.Length, at));
                text.Append(html, at, html.Length - at);
            }
            return new Body(text.ToString(), pieces);
        }

        /// <summary>この並びでの位置を、元の HTML での位置に戻す。</summary>
        public int Origin(int at)
        {
            // 始まりが at 以下である最後の断片を探す。
            var low = 0;
            var high = _pieces.Count;
            while (low < high)
            {
                var middle = (low + high) / 2;
                if (_pieces[middle].Start <= at)
                {
                    low = middle + 1;
                }
                else
                {
                    high = middle;
                }
            }
            if (low == 0)
            {
                return 0;
            }
            var (start, from) = _pieces[low - 1];
            return from + (at - start);
        }
    }

    public static Extracted Extract(string html)
    {
        var body = Body.Of(html);
        var source = body.Text;

        var text = new StringBuilder();
        var origins = new List<int>(); // まだ body の中の位置。最後に元へ戻す。
        var length = 0; // 文字数。UTF-16 の単位数ではない。
        var codeRanges = new List<(int, int)>();
        var cursor = 0;

        foreach (Match match in Pre.Matches(source))
        {
            var (before, beforeAt) = StripTagsFrom(source[cursor..match.Index], cursor);
            length += RuneCount(before);
            text.Append(before);
            origins.AddRange(beforeAt);

            var start = length;
            var code = match.Groups[1];
            var (inner, innerAt) = StripTagsFrom(code.Value, code.Index);
            length += RuneCount(inner);
            text.Append(inner);
            origins.AddRange(innerAt);
            codeRanges.Add((start, length));

            text.Append('\n');
            origins.Add(match.Index + match.Length);
            length += 1;
            cursor = match.Index + match.Length;
        }
        var (tail, tailAt) = StripTagsFrom(source[cursor..], cursor);
        text.Append(tail);
        origins.AddRange(tailAt);

        return new Extracted(text.ToString(), codeRanges, origins.Select(body.Origin).ToList());
    }

    /// <summary>タグを落として本文だけにする。タグの位置には空白を 1 つ残す。</summary>
    public static string StripTags(string source) => StripTagsFrom(source, 0).Output;

    /// <summary>
    /// タグを落とし、残した 1 文字ごとに元の位置も返す。
    /// <paramref name="baseAt"/> は <paramref name="source"/> が始まるところ。
    ///
    /// 位置を控えるのは落とすのと同じ走査の中でだけ行う。別に辿り直せば、
    /// タグの扱い・実体参照・空白の詰め方を二か所に書くことになる。
    /// </summary>
    private static (string Output, List<int> Origins) StripTagsFrom(string source, int baseAt)
    {
        var output = new StringBuilder(source.Length);
        var origins = new List<int>(source.Length);
        var insideTag = false;
        var lastWasSpace = false;

        var offset = 0;
        while (offset < source.Length)
        {
            Rune.DecodeFromUtf16(source.AsSpan(offset), out var rune, out var consumed);
            var at = baseAt + offset;
            offset += consumed;

            if (rune.Value == '<')
            {
                insideTag = true;
                continue;
            }
            if (rune.Value == '>')
            {
                insideTag = false;
                if (!lastWasSpace)
                {
                    // タグの代わりに置く空白は、タグの終わりの次を指す。
                    output.Append(' ');
                    origins.Add(at + consumed);
                    lastWasSpace = true;
                }
                continue;
            }
            if (insideTag)
            {
                continue;
            }
            if (rune.Value is '\n' or '\r' or '\t')
            {
                if (!lastWasSpace)
                {
                    output.Append(' ');
                    origins.Add(at);
                    lastWasSpace = true;
                }
                continue;
            }
            output.Append(rune.ToString());
            origins.Add(at);
            lastWasSpace = rune.Value == ' ';
        }

        return DecodeEntities(output.ToString(), origins);
    }

    /// <summary>実体参照を解く。解けた字は、書かれていた並びの始まりを指す。</summary>
    private static (string, List<int>) DecodeEntities(string source, List<int> origins)
    {
        if (!source.Contains('&'))
        {
            return (source, origins);
        }

        var text = source;
        var at = origins;
        foreach (var (from, to) in Entities)
        {
            if (text.Contains(from, StringComparison.Ordinal))
            {
                (text, at) = Replaced(text, at, Finder.Of(from), _ => to);
            }
        }
        if (!text.Contains("&#", StringComparison.Ordinal))
        {
            return (text, at);
        }

        return Replaced(text, at, Finder.Of(Numeric), found =>
        {
            var match = Numeric.Match(found);
            var radix = match.Groups[1].Value.Length == 0 ? 10 : 16;
            try
            {
                return char.ConvertFromUtf32(Convert.ToInt32(match.Groups[2].Value, radix));
            }
            catch (Exception)
            {
                // 読めない並びは、書いてあるまま残す。
                return found;
            }
        });
    }

    /// <summary>
    /// <see cref="Replaced"/> が探すもの。文字列でも正規表現でも同じように辿れるようにする。
    /// </summary>
    private readonly record struct Finder(Func<string, int, (int From, int To)?> Find)
    {
        public static Finder Of(string needle) => new((text, from) =>
        {
            var index = text.IndexOf(needle, from, StringComparison.Ordinal);
            return index < 0 ? null : ((int From, int To)?)(index, index + needle.Length);
        });

        public static Finder Of(Regex pattern) => new((text, from) =>
        {
            var match = pattern.Match(text, from);
            return match.Success ? ((int From, int To)?)(match.Index, match.Index + match.Length) : null;
        });
    }

    /// <summary>見つかった並びを置き換える。置いた字は、いずれも元の並びの始まりを指す。</summary>
    private static (string, List<int>) Replaced(
        string text, List<int> origins, Finder finder, Func<string, string> into)
    {
        var output = new StringBuilder(text.Length);
        var at = new List<int>(origins.Count);
        var cursor = 0; // UTF-16 の位置。
        var index = 0;  // 文字数。origins はこちらで引く。

        while (finder.Find(text, cursor) is { } found)
        {
            var (from, to) = found;
            var head = text[cursor..from];
            output.Append(head);
            var headLength = RuneCount(head);
            at.AddRange(origins.GetRange(index, headLength));
            index += headLength;

            var written = text[from..to];
            var origin = index < origins.Count ? origins[index] : 0;
            var put = into(written);
            output.Append(put);
            for (var n = RuneCount(put); n > 0; n--)
            {
                at.Add(origin);
            }
            index += RuneCount(written);
            cursor = to;
        }
        output.Append(text[cursor..]);
        at.AddRange(origins.GetRange(index, origins.Count - index));
        return (output.ToString(), at);
    }

    public static int RuneCount(string value)
    {
        var count = 0;
        foreach (var _ in value.EnumerateRunes())
        {
            count++;
        }
        return count;
    }
}
