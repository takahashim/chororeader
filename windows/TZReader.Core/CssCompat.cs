using System.Text;
using System.Text.RegularExpressions;

namespace TZReader.Core;

/// <summary>
/// 古い EPUB の CSS を、配信時に解釈可能な形へ書き換える。
/// 元ファイルには触れず、意味を変える書き換えもしない。
/// 出力は macOS 版と一致させる必要がある（conformance/CONTRACT.md）。
/// </summary>
public static class CssCompat
{
    public sealed record Change(string From, string To, int Count);

    public sealed record Result(string Css, IReadOnlyList<Change> Changes);

    /// <summary>プロパティ名だけを標準形へ移せるもの。</summary>
    private static readonly (string From, string To)[] PropertyMap =
    [
        ("-epub-writing-mode", "writing-mode"),
        ("-epub-text-orientation", "text-orientation"),
        ("-epub-ruby-position", "ruby-position"),
        ("-epub-text-emphasis", "text-emphasis"),
        ("-epub-text-emphasis-color", "text-emphasis-color"),
        ("-epub-text-emphasis-style", "text-emphasis-style"),
        ("-epub-text-emphasis-position", "text-emphasis-position"),
        ("-epub-hyphens", "hyphens"),
        ("-epub-line-break", "line-break"),
        ("-epub-word-break", "word-break"),
        ("-epub-text-align-last", "text-align-last"),
        ("-epub-caption-side", "caption-side"),
    ];

    public static Result Rewrite(string css)
    {
        var changes = new List<Change>();
        var output = new StringBuilder(css.Length);

        foreach (var segment in Segments(css))
        {
            if (segment.Kind != SegmentKind.Code)
            {
                output.Append(segment.Text);
                continue;
            }

            var text = segment.Text;
            // 値の読み替えが要るものを先に処理する。
            text = Replace(text, @"-epub-text-combine-horizontal\s*:\s*[^;}]*",
                           "text-combine-upright: all", "-epub-text-combine-horizontal", changes);
            text = Replace(text, @"-epub-text-combine\s*:\s*horizontal",
                           "text-combine-upright: all", "-epub-text-combine: horizontal", changes);
            foreach (var (from, to) in PropertyMap)
            {
                text = Replace(text, Regex.Escape(from) + @"(?=\s*:)", to, from, changes);
            }
            output.Append(text);
        }

        return new Result(output.ToString(), changes);
    }

    /// <summary>XHTML 内の style ブロックにも同じ変換をかける。要素構造には触れない。</summary>
    public static Result RewriteXhtml(string html)
    {
        if (!html.Contains("-epub-", StringComparison.Ordinal))
        {
            return new Result(html, []);
        }

        var changes = new List<Change>();
        var result = Regex.Replace(
            html,
            @"(<style\b[^>]*>)(.*?)(</style>)",
            match =>
            {
                var inner = Rewrite(match.Groups[2].Value);
                if (inner.Changes.Count == 0)
                {
                    return match.Value;
                }
                changes.AddRange(inner.Changes);
                return match.Groups[1].Value + inner.Css + match.Groups[3].Value;
            },
            RegexOptions.Singleline | RegexOptions.IgnoreCase);

        return new Result(result, changes);
    }

    private static string Replace(string text, string pattern, string replacement,
                                  string label, List<Change> changes)
    {
        if (!text.Contains("-epub-", StringComparison.Ordinal))
        {
            return text;
        }
        var matches = Regex.Matches(text, pattern, RegexOptions.IgnoreCase);
        if (matches.Count == 0)
        {
            return text;
        }
        changes.Add(new Change(label, replacement, matches.Count));
        return Regex.Replace(text, pattern, replacement, RegexOptions.IgnoreCase);
    }

    private enum SegmentKind
    {
        Code,
        Comment,
        String,
    }

    private readonly record struct Segment(SegmentKind Kind, string Text);

    /// <summary>コメントと文字列リテラルを切り分ける。その内側を書き換えないための下ごしらえ。</summary>
    private static List<Segment> Segments(string css)
    {
        var segments = new List<Segment>();
        var buffer = new StringBuilder();

        void Flush()
        {
            if (buffer.Length > 0)
            {
                segments.Add(new Segment(SegmentKind.Code, buffer.ToString()));
                buffer.Clear();
            }
        }

        var i = 0;
        while (i < css.Length)
        {
            var c = css[i];
            if (c == '/' && i + 1 < css.Length && css[i + 1] == '*')
            {
                Flush();
                var j = i + 2;
                while (j < css.Length)
                {
                    if (css[j] == '*' && j + 1 < css.Length && css[j + 1] == '/')
                    {
                        j += 2;
                        break;
                    }
                    j++;
                }
                segments.Add(new Segment(SegmentKind.Comment, css[i..Math.Min(j, css.Length)]));
                i = j;
                continue;
            }

            if (c == '"' || c == '\'')
            {
                Flush();
                var j = i + 1;
                while (j < css.Length)
                {
                    if (css[j] == '\\')
                    {
                        j = Math.Min(j + 2, css.Length);
                        continue;
                    }
                    if (css[j] == c)
                    {
                        j++;
                        break;
                    }
                    j++;
                }
                segments.Add(new Segment(SegmentKind.String, css[i..Math.Min(j, css.Length)]));
                i = j;
                continue;
            }

            buffer.Append(c);
            i++;
        }

        Flush();
        return segments;
    }

    /// <summary>UTF-8 以外で書かれたリソースも読めるようにする。</summary>
    public static string DecodeText(byte[] data)
    {
        // BOM 付きはそのまま任せる。
        if (data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF)
        {
            return Encoding.UTF8.GetString(data, 3, data.Length - 3);
        }

        var strictUtf8 = new UTF8Encoding(false, throwOnInvalidBytes: true);
        try
        {
            return strictUtf8.GetString(data);
        }
        catch (DecoderFallbackException)
        {
            // Shift_JIS と EUC-JP は .NET Core では既定で使えないため、事前に登録しておく。
            foreach (var name in new[] { "shift_jis", "euc-jp", "iso-8859-1" })
            {
                try
                {
                    var encoding = Encoding.GetEncoding(name, EncoderFallback.ExceptionFallback,
                                                        DecoderFallback.ExceptionFallback);
                    return encoding.GetString(data);
                }
                catch (Exception)
                {
                    // 次の符号化を試す
                }
            }
            return Encoding.UTF8.GetString(data);
        }
    }

    /// <summary>符号化の登録。アプリと Probe の起動時に一度だけ呼ぶ。</summary>
    public static void RegisterEncodings() =>
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
}
