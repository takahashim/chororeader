namespace ChoroReader.Core;

/// <summary>形式共通の読書位置。</summary>
public sealed record Locator
{
    public string? Href { get; init; }
    public int? Page { get; init; }
    public double Progression { get; init; }
    public string? Fragment { get; init; }
    public string? Title { get; init; }
    public string? Text { get; init; }
}

public sealed record Link(string Href, string MediaType, string? Id, IReadOnlySet<string> Properties);

public sealed record TocEntry(string Title, string? Href, string? Fragment, int? Page, IReadOnlyList<TocEntry> Children);

public enum PublicationLayout
{
    Reflowable,
    Fixed,
}

public enum ReadingDirection
{
    Ltr,
    Rtl,
}

public sealed record EpubPublication
{
    public required string Title { get; init; }
    public required IReadOnlyList<string> Authors { get; init; }
    public string? Language { get; init; }
    public string? Identifier { get; init; }
    public required IReadOnlyList<Link> ReadingOrder { get; init; }
    public required IReadOnlyList<TocEntry> TableOfContents { get; init; }
    public string? CoverHref { get; init; }
    public required PublicationLayout Layout { get; init; }
    public required ReadingDirection Direction { get; init; }

    public string? TitleForHref(string href)
    {
        static string? Search(IReadOnlyList<TocEntry> entries, string href)
        {
            foreach (var entry in entries)
            {
                if (entry.Href == href)
                {
                    return entry.Title;
                }
                var found = Search(entry.Children, href);
                if (found is not null)
                {
                    return found;
                }
            }
            return null;
        }
        return Search(TableOfContents, href);
    }
}

public enum DocumentFormat
{
    ReflowableEpub,
    FixedEpub,
    Pdf,
    Markdown,
}

public static class DocumentFormats
{
    /// <summary>拡張子から表示種別のあたりを付ける。EPUB の固定レイアウト判定は OPF を読んでから。</summary>
    public static DocumentFormat? Detect(string path)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();
        return extension switch
        {
            ".epub" => DocumentFormat.ReflowableEpub,
            ".pdf" => DocumentFormat.Pdf,
            ".md" or ".markdown" => DocumentFormat.Markdown,
            _ => null,
        };
    }

    public static string ToWireName(this DocumentFormat format) => format switch
    {
        DocumentFormat.ReflowableEpub => "reflowableEPUB",
        DocumentFormat.FixedEpub => "fixedEPUB",
        DocumentFormat.Pdf => "pdf",
        DocumentFormat.Markdown => "markdown",
        _ => "unknown",
    };
}

/// <summary>
/// 実装間で揃える必要のあるエラー分類（conformance/CONTRACT.md）。表示文言ではなくこの値を揃える。
/// </summary>
public sealed class DocumentException : Exception
{
    public string Kind { get; }

    public DocumentException(string kind, string message) : base(message) => Kind = kind;

    public static DocumentException BrokenArchive(string detail) => new("brokenArchive", detail);
    public static DocumentException MissingContainer() => new("missingContainer", "META-INF/container.xml から rootfile を取り出せない");
    public static DocumentException MissingOpf(string path) => new("missingOPF", $"OPF が見つからない: {path}");
    public static DocumentException CannotParseOpf(string detail) => new("cannotParseOPF", detail);
    public static DocumentException EmptySpine() => new("emptySpine", "spine に linear な項目がない");
    public static DocumentException CannotOpenPdf() => new("cannotOpenPDF", "PDF として開けない");
    public static DocumentException UnsupportedFormat(string name) => new("unsupportedFormat", name);
}
