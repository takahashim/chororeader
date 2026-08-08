using System.Text;
using System.Text.RegularExpressions;
using MuPDFCore;

namespace ChoroReader.Core;

/// <summary>
/// PDF の実装。MuPDF を使う。
/// この型より外へ MuPDF の型を漏らさない。描画ライブラリを差し替えても影響を UI に閉じるため。
///
/// <para>
/// <b>1 つの文書は直列に使う。</b>MuPDF の context は例外スタックとリソースキャッシュを抱えており、
/// 同時に触ると壊れる。並行に読ませたいときは context を複製する作りになっている
/// （MuPDFCore の <c>CloneContext</c>）。ここでは複製せず、取り出しのほうを直列化する。
/// <see cref="EpubArchive"/> が ZipArchive を扱うのと同じである。
/// </para>
/// <para>
/// 直列化しないと、描画と検索を並行させた瞬間に
/// 「found duplicate pdf_obj in the store」「array not closed before end of file」が出て、
/// 壊れたキャッシュを読んだまま進む。落ちるとは限らないぶん、かえって質が悪い。
/// </para>
/// </summary>
internal sealed class MuPdfBackend : IPdfBackend
{
    private readonly Lock _gate = new();
    private readonly MuPDFContext _context;
    private readonly MuPDFDocument _document;
    private bool _disposed;

    /// <summary>何度も要るものは開いたときに写しておく。呼ぶたびに MuPDF へ降りずに済む。</summary>
    private readonly int _pageCount;

    private bool? _hasTextLayer;
    private IReadOnlyList<TocEntry>? _outline;

    internal static void Register() => PdfBackend.Factory = path => new MuPdfBackend(path);

    private MuPdfBackend(string path)
    {
        _context = new MuPDFContext();
        _document = new MuPDFDocument(_context, path);
        _pageCount = _document.Pages.Count;
    }

    public int PageCount => _pageCount;

    /// <summary>
    /// テキスト層があるか。先頭の数ページに文字があるかで判断する。
    /// 全ページ走査は開くたびには重い。一度出した答えは変わらないので写しておく。
    /// </summary>
    public bool HasTextLayer
    {
        get
        {
            lock (_gate)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                if (_hasTextLayer is { } known)
                {
                    return known;
                }

                var limit = Math.Min(_pageCount, 5);
                var found = false;
                for (var i = 0; i < limit && !found; i++)
                {
                    found = ReadText(i).Trim().Length > 0;
                }
                _hasTextLayer = found;
                return found;
            }
        }
    }

    public string TextOfPage(int index)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return ReadText(index);
        }
    }

    public IReadOnlyList<TocEntry> Outline()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _outline ??= ReadOutline();
        }
    }

    /// <summary>
    /// 検索。ヒットの位置は UI 側でハイライトの矩形へ変換する。
    ///
    /// <para>
    /// 遅延列挙（<c>yield return</c>）にはしない。MuPDF に触るのが呼び出し側の反復のときになり、
    /// 鍵の外へ出てしまう。上限があるので、ここで数え切ってから返す。
    /// </para>
    /// </summary>
    public IReadOnlyList<(int Page, string Text)> Search(string needle, int limit)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var pattern = new Regex(Regex.Escape(needle), RegexOptions.IgnoreCase);
            var hits = new List<(int, string)>();
            for (var i = 0; i < _pageCount && hits.Count < limit; i++)
            {
                using var page = _document.GetStructuredTextPage(i);
                foreach (var span in page.Search(pattern))
                {
                    hits.Add((i, page.GetText(span)));
                    if (hits.Count >= limit)
                    {
                        break;
                    }
                }
            }
            return hits;
        }
    }

    /// <summary>ページを描く。UI が受け取って表示する。</summary>
    public byte[] RenderPage(int index, double zoom)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _document.Render(index, zoom, PixelFormats.RGB, includeAnnotations: true);
        }
    }

    public (double Width, double Height) PageSize(int index)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var bounds = _document.Pages[index].Bounds;
            return (bounds.Width, bounds.Height);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _document.Dispose();
            _context.Dispose();
        }
    }

    // MARK: 鍵の内側

    private string ReadText(int index)
    {
        if (index < 0 || index >= _pageCount)
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

    private IReadOnlyList<TocEntry> ReadOutline()
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
}
