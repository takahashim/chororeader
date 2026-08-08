namespace ChoroReader.Core;

/// <summary>
/// 索引に載せる本文を単位ごとに切り出す。
///
/// <para>
/// 単位は EPUB なら読み順の 1 項目、PDF なら 1 ページとする（spec.md 10.4）。
/// 走査もこの単位で候補を受け取るので、切り方は両者で必ず揃っていなければならない。
/// 揃っていないと、絞った番号が別の章を指す。
/// </para>
/// </summary>
public static class SearchUnits
{
    /// <summary>読み順の 1 項目につき 1 つ。読めない章は空にして、番号をずらさない。</summary>
    public static IReadOnlyList<string> OfEpub(IResourceProvider resources, EpubPublication publication) =>
        publication.ReadingOrder
            .Select(link => resources.ReadText(link.Href) is { } source
                ? HtmlText.Extract(source).Text
                : string.Empty)
            .ToList();

    /// <summary>1 ページにつき 1 つ。</summary>
    public static IReadOnlyList<string> OfPdf(PdfInspector document) =>
        Enumerable.Range(0, document.PageCount).Select(document.TextOfPage).ToList();
}
