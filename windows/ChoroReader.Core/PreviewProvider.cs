using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace ChoroReader.Core;

/// <summary>
/// リンク先を移動せずに確かめるための、小さな抜粋を組み立てる。
/// どこを切り出すかは実装間で揃える（conformance/CONTRACT.md）。
/// </summary>
public static class PreviewProvider
{
    /// <summary>抜粋に入れる本文の目安。脚注はこれよりずっと短く収まる。</summary>
    private const int Budget = 1200;

    public const string SyntheticName = "__choro_preview__.xhtml";

    public sealed record Preview(string Path, string Html, bool IsFootnote);

    public static Preview? Make(IResourceProvider resources, string href, string? fragment, string css)
    {
        if (resources.ReadText(href) is not { } text)
        {
            return null;
        }

        var source = CssCompat.RewriteXhtml(text).Css;
        var extracted = Extract(source, fragment);
        if (extracted.Body.Length == 0)
        {
            return null;
        }

        var directory = EpubParser.DirectoryOf(href);
        var path = directory.Length == 0 ? SyntheticName : $"{directory}/{SyntheticName}";

        // 抜粋には epub:type のような接頭辞付き属性が混ざる。XHTML として解釈させると
        // 名前空間が宣言されていない断片で丸ごとパースに失敗するため、HTML として配信する。
        var html = $$"""
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><style>
        {{css}}
        {{ReaderStyle.PreviewOverlayCss()}}
        </style></head>
        <body>{{extracted.Body}}</body>
        </html>
        """;

        return new Preview(path, html, extracted.IsFootnote);
    }

    private readonly record struct Extracted(string Body, bool IsFootnote);

    private static Extracted Extract(string source, string? fragment)
    {
        var document = Parse(source);
        if (document is null)
        {
            return new Extracted(EscapedPlainText(source), false);
        }

        if (string.IsNullOrEmpty(fragment))
        {
            return new Extracted(LeadingContent(document), false);
        }

        var target = ElementWithId(document, fragment);
        if (target is null)
        {
            return new Extracted(LeadingContent(document), false);
        }

        // 脚注は要素 1 つで完結する。前後を足すとかえって読みにくい。
        if (IsFootnoteElement(target))
        {
            return new Extracted(target.ToString(SaveOptions.DisableFormatting), true);
        }

        var html = target.ToString(SaveOptions.DisableFormatting);
        var length = target.Value.Length;
        var node = target.NextNode;
        while (length < Budget && node is not null)
        {
            if (node is XElement element)
            {
                html += element.ToString(SaveOptions.DisableFormatting);
                length += element.Value.Length;
            }
            node = node.NextNode;
        }
        return new Extracted(html, false);
    }

    private static bool IsFootnoteElement(XElement element)
    {
        var type = (Attribute(element, "type") ?? string.Empty) + " " + (Attribute(element, "role") ?? string.Empty);
        if (type.Contains("footnote", StringComparison.Ordinal)
            || type.Contains("note", StringComparison.Ordinal)
            || type.Contains("doc-footnote", StringComparison.Ordinal))
        {
            return true;
        }
        return element.Name.LocalName == "aside";
    }

    private static XElement? ElementWithId(XDocument document, string id) =>
        document.Descendants().FirstOrDefault(e => Attribute(e, "id") == id);

    private static string LeadingContent(XDocument document)
    {
        var body = document.Descendants().FirstOrDefault(e => e.Name.LocalName == "body");
        if (body is null)
        {
            return string.Empty;
        }
        var html = string.Empty;
        var length = 0;
        foreach (var child in body.Elements())
        {
            html += child.ToString(SaveOptions.DisableFormatting);
            length += child.Value.Length;
            if (length >= Budget)
            {
                break;
            }
        }
        return html;
    }

    private static XDocument? Parse(string source)
    {
        try
        {
            using var reader = System.Xml.XmlReader.Create(
                new StringReader(source),
                new System.Xml.XmlReaderSettings
                {
                    DtdProcessing = System.Xml.DtdProcessing.Ignore,
                    XmlResolver = null,
                });
            return XDocument.Load(reader);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>XML として読めない章のための最後の手段。整形は諦め、文字だけ見せる。</summary>
    private static string EscapedPlainText(string source)
    {
        var text = HtmlText.StripTags(source);
        if (text.Length > Budget)
        {
            text = text[..Budget];
        }
        var escaped = text
            .Replace("&", "&amp;", StringComparison.Ordinal)
            .Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal);
        return $"<p>{escaped}</p>";
    }

    private static string? Attribute(XElement element, string name) =>
        element.Attributes().FirstOrDefault(a => a.Name.LocalName == name)?.Value;
}

/// <summary>
/// 固定レイアウトの組み立てのうち、画面に依らない部分。
/// ページの種別の見分けと、見開きの組み方を扱う。
/// </summary>
public static class FixedLayoutPlan
{
    public sealed record PageContent(string Kind, string Href);

    /// <summary>
    /// ページが画像 1 枚で構成されているなら、その画像を直接表示する。
    /// 文字が固定座標で置かれているページは、元の XHTML をそのまま埋め込む。
    /// </summary>
    public static PageContent Content(string href, IResourceProvider resources)
    {
        if (resources.ReadText(href) is not { } source)
        {
            return new PageContent("document", href);
        }

        var reference = PrimaryImageReference(source);
        if (reference is null)
        {
            return new PageContent("document", href);
        }

        var resolved = Paths.Resolve(EpubParser.DirectoryOf(href), reference);
        if (!resources.Contains(resolved))
        {
            return new PageContent("document", href);
        }

        // 画像以外に本文が載っているページは、画像だけを出すと内容が落ちる。
        var text = HtmlText.StripTags(source).Trim();
        return text.Length < 40 ? new PageContent("image", resolved) : new PageContent("document", href);
    }

    private static string? PrimaryImageReference(string html)
    {
        string[] patterns =
        [
            @"<img\b[^>]*\bsrc\s*=\s*[""']([^""']+)[""']",
            @"<image\b[^>]*\bxlink:href\s*=\s*[""']([^""']+)[""']",
            @"<image\b[^>]*\bhref\s*=\s*[""']([^""']+)[""']",
        ];

        var found = new List<string>();
        foreach (var pattern in patterns)
        {
            foreach (Match match in Regex.Matches(html, pattern, RegexOptions.IgnoreCase))
            {
                found.Add(match.Groups[1].Value);
            }
        }
        // 画像が複数あるページは、単純な 1 枚もののページではない。
        return found.Count == 1 ? found[0] : null;
    }

    /// <summary>
    /// ページの寸法。固定レイアウトの各ページは meta viewport で大きさを名乗る。
    ///
    /// 拡大の枠を先に決めるために要る。大きさを与えないと画像がすべて同じ位置に積まれ、
    /// 遅延読み込みが効かなくなる。名乗っていなければ null。
    ///
    /// content の並びは、1 つでも <c>=</c> を欠いていたら全体を捨てる。
    /// 半端に読めたぶんだけ使うと、書き損じた書籍で妙な寸法を掴むことになる。
    /// </summary>
    public static (double Width, double Height)? Viewport(string href, IResourceProvider resources)
    {
        if (resources.ReadText(href) is not { } source)
        {
            return null;
        }
        var match = Regex.Match(
            source,
            @"<meta\b[^>]*\bname\s*=\s*[""']viewport[""'][^>]*\bcontent\s*=\s*[""']([^""']+)[""']",
            RegexOptions.IgnoreCase);
        if (!match.Success)
        {
            return null;
        }

        double? width = null;
        double? height = null;
        foreach (var part in match.Groups[1].Value.Split(','))
        {
            var equals = part.IndexOf('=', StringComparison.Ordinal);
            if (equals < 0)
            {
                return null;
            }
            var key = part[..equals].Trim();
            var value = part[(equals + 1)..].Trim();
            var number = double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
                ? parsed
                : (double?)null;
            if (key == "width")
            {
                width = number;
            }
            else if (key == "height")
            {
                height = number;
            }
        }
        return width is > 0 && height is > 0 ? (width.Value, height.Value) : null;
    }

    /// <summary>見開きの組み方。表紙は単独で見せ、以降を 2 枚ずつまとめる。</summary>
    public static IReadOnlyList<IReadOnlyList<int>> Spreads(int pageCount)
    {
        if (pageCount <= 0)
        {
            return [];
        }
        var result = new List<IReadOnlyList<int>> { new[] { 0 } };
        var index = 1;
        while (index < pageCount)
        {
            if (index + 1 < pageCount)
            {
                result.Add(new[] { index, index + 1 });
                index += 2;
            }
            else
            {
                result.Add(new[] { index });
                index += 1;
            }
        }
        return result;
    }
}
