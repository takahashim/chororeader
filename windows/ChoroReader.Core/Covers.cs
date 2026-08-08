namespace ChoroReader.Core;

/// <summary>
/// 書棚に並べる表紙のもと。
///
/// <para>
/// <b>Core は画像を復号しない。</b>復号と縮小と書き出しは画面側（WPF）の仕事で、
/// ここは「どこから何を取るか」だけを決める。
/// そうしておけば、取り出しの筋を macOS でも検査できる。
/// </para>
/// </summary>
public abstract record CoverSource;

/// <summary>EPUB の表紙。書籍に入っている画像をそのまま渡す（JPEG・PNG・SVG など）。</summary>
public sealed record EncodedCover(byte[] Bytes, string Href) : CoverSource;

/// <summary>PDF の 1 ページ目。MuPDF が描いた画素をそのまま渡す。</summary>
public sealed record PixelCover(RenderedPage Page) : CoverSource;

public static class Covers
{
    /// <summary>
    /// 書棚の升目に収まる大きさ。画面の倍率を見込んで 2 倍で持つ。
    /// </summary>
    public const int MaxPixel = 640;

    /// <summary>
    /// 書籍から表紙を取り出す。
    ///
    /// <para>
    /// EPUB は OPF が指す表紙、PDF は 1 ページ目。
    /// <b>どちらも取れない書籍はある。</b>表紙を持たない EPUB も、
    /// 開けない PDF もあるので、失敗は失敗のまま返す。並べるのは題名だけになる。
    /// </para>
    /// </summary>
    public static CoverSource? Of(string bookPath)
    {
        try
        {
            return DocumentFormats.Detect(bookPath) == DocumentFormat.Pdf
                ? FromPdf(bookPath)
                : FromEpub(bookPath);
        }
        catch (Exception)
        {
            // 表紙が取れなくても書棚は並ぶ。
            return null;
        }
    }

    private static CoverSource? FromEpub(string bookPath)
    {
        using var archive = new EpubArchive(bookPath);
        var publication = EpubParser.Parse(archive);
        if (publication.CoverHref is not { Length: > 0 } href || !archive.Contains(href))
        {
            return null;
        }
        return new EncodedCover(archive.Read(href), href);
    }

    /// <summary>
    /// PDF の 1 ページ目を、升目に収まる大きさで描く。
    ///
    /// <para>
    /// <b>原寸で描いてから縮めない。</b>数百ページの書籍を並べるので、
    /// 1 冊ごとに全画素を起こすと書棚が固まる。倍率を先に決めて描く。
    /// </para>
    /// </summary>
    private static CoverSource? FromPdf(string bookPath)
    {
        using var paper = PdfInspector.Open(bookPath);
        if (paper.PageCount == 0)
        {
            return null;
        }

        var (width, height) = paper.PageSize(0);
        var longest = Math.Max(width, height);
        var zoom = longest > 0 ? Math.Min(1.0, MaxPixel / longest) : 1.0;
        return new PixelCover(paper.RenderPage(0, zoom));
    }
}
