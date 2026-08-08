using System.Text;
using System.Text.RegularExpressions;
using MuPDFCore;

namespace ChoroReader.Core;

/// <summary>
/// PDF の実装。MuPDF を使う。
/// この型より外へ MuPDF の型を漏らさない。描画ライブラリを差し替えても影響を UI に閉じるため。
/// </summary>
internal sealed class MuPdfBackend : IPdfBackend
{
    private readonly MuPDFContext _context;
    private readonly MuPDFDocument _document;

    internal static void Register() => PdfBackend.Factory = path => new MuPdfBackend(path);

    private MuPdfBackend(string path)
    {
        _context = new MuPDFContext();
        _document = new MuPDFDocument(_context, path);
    }

    public int PageCount => _document.Pages.Count;

    public bool HasTextLayer
    {
        get
        {
            // 先頭の数ページに文字があるかで判断する。全ページ走査は開くたびには重い。
            var limit = Math.Min(PageCount, 5);
            for (var i = 0; i < limit; i++)
            {
                if (TextOfPage(i).Trim().Length > 0)
                {
                    return true;
                }
            }
            return false;
        }
    }

    public string TextOfPage(int index)
    {
        if (index < 0 || index >= PageCount)
        {
            return string.Empty;
        }

        using var page = _document.GetStructuredTextPage(index);
        var builder = new StringBuilder();

        // ブロックの順は描画順であって読み順とは限らない。段組の書籍で崩れるため座標で並べ替える。
        var blocks = page.StructuredTextBlocks
            .OrderBy(b => Math.Round(b.BoundingBox.Y0, 1))
            .ThenBy(b => Math.Round(b.BoundingBox.X0, 1));

        foreach (var block in blocks)
        {
            foreach (var line in block)
            {
                builder.Append(line.Text);
                builder.Append('\n');
            }
        }
        return builder.ToString();
    }

    public IReadOnlyList<TocEntry> Outline()
    {
        static List<TocEntry> Walk(IReadOnlyList<MuPDFOutlineItem> items) =>
            items.Select(item => new TocEntry(
                item.Title ?? "(無題)",
                null,
                null,
                item.PageNumber,
                Walk(item.Children))).ToList();

        try
        {
            return Walk(_document.Outline.Items);
        }
        catch (Exception)
        {
            return [];
        }
    }

    /// <summary>検索。ヒットの位置は UI 側でハイライトの矩形へ変換する。</summary>
    public IEnumerable<(int Page, string Text)> Search(string needle, int limit)
    {
        var pattern = new Regex(Regex.Escape(needle), RegexOptions.IgnoreCase);
        var found = 0;
        for (var i = 0; i < PageCount && found < limit; i++)
        {
            using var page = _document.GetStructuredTextPage(i);
            foreach (var span in page.Search(pattern))
            {
                yield return (i, page.GetText(span));
                if (++found >= limit)
                {
                    break;
                }
            }
        }
    }

    /// <summary>ページを描く。UI が受け取って表示する。</summary>
    public byte[] RenderPage(int index, double zoom) =>
        _document.Render(index, zoom, PixelFormats.RGB, includeAnnotations: true);

    public (double Width, double Height) PageSize(int index)
    {
        var bounds = _document.Pages[index].Bounds;
        return (bounds.Width, bounds.Height);
    }

    public void Dispose()
    {
        _document.Dispose();
        _context.Dispose();
    }
}
