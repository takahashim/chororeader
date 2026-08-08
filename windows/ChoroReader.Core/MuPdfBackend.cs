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

    /// <summary>1 ページから拾う矩形の上限。当たりが多いページでも囲みきれる数にする。</summary>
    private const int QuadsPerPage = 32;

    /// <summary>抜粋に添える前後の文脈の長さ。走査（DocumentSearch）と同じ幅にしてある。</summary>
    private const int Before = 30;
    private const int After = 40;

    internal static void Register() => PdfBackend.Factory = path => new MuPdfBackend(path);

    private MuPdfBackend(string path)
    {
        // **PDF でないものを MuPDF へ渡さない。**
        //
        // 中身が PDF でないと、MuPDF は修復を試みたうえで native の側で転ぶ。
        // そのとき文書の器はすでに出来ていて、こちらは掴む前なので後始末ができない。
        // 残った器は後で終了処理に入り、持ち主の context が先に消えているために
        // 「owner が先に破棄された」と言って**プロセスごと落とす**。
        // 開けないことを例外で伝える経路（PdfProbe.CanOpen）でさえ、
        // その場では捕まえられても、後の GC で落ちる。
        // 渡す前に見分けるのが唯一の手である。
        if (!LooksLikePdf(path))
        {
            throw DocumentException.CannotOpenPdf();
        }

        _context = new MuPDFContext();
        _document = new MuPDFDocument(_context, path);
        _pageCount = _document.Pages.Count;
    }

    /// <summary>
    /// PDF の目印があるか。
    ///
    /// <para>
    /// 頭に <c>%PDF-</c> がある。前にごみが付いた書籍もあるので、少し先まで探す
    /// （仕様も「先頭 1024 バイトのどこか」を許している）。
    /// ここで見分けたいのは<b>まったく別のもの</b>だけで、
    /// 壊れた PDF の修復は MuPDF に任せる。
    /// </para>
    /// </summary>
    private static bool LooksLikePdf(string path)
    {
        try
        {
            using var file = File.OpenRead(path);
            var head = new byte[1024];
            var read = file.ReadAtLeast(head, head.Length, throwOnEndOfStream: false);
            return head.AsSpan(0, read).IndexOf("%PDF-"u8) >= 0;
        }
        catch (Exception)
        {
            return false;
        }
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
    /// 検索。1 ページにつき 1 つ返し、そのページの当たりをすべて矩形で示す。
    ///
    /// <para>
    /// 遅延列挙（<c>yield return</c>）にはしない。MuPDF に触るのが呼び出し側の反復のときになり、
    /// 鍵の外へ出てしまう。上限があるので、ここで数え切ってから返す。
    /// </para>
    /// </summary>
    public IReadOnlyList<PageHit> SearchWithin(string needle, int limit, IReadOnlySet<int>? only)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var pattern = new Regex(Regex.Escape(needle), RegexOptions.IgnoreCase);
            var hits = new List<PageHit>();

            for (var index = 0; index < _pageCount && hits.Count < limit; index++)
            {
                if (only is not null && !only.Contains(index))
                {
                    continue;
                }

                using var page = _document.GetStructuredTextPage(index);
                // 座標は絵の左上を原点に直しておく。ページの枠は原点から始まるとは限らない。
                var bounds = _document.Pages[index].Bounds;
                var rects = new List<PageRect>();

                foreach (var span in page.Search(pattern))
                {
                    var quads = page.GetHighlightQuads(span, includeImages: false);
                    foreach (var rect in MergeByLine(quads, bounds.X0, bounds.Y0))
                    {
                        rects.Add(rect);
                        if (rects.Count >= QuadsPerPage)
                        {
                            break;
                        }
                    }
                    if (rects.Count >= QuadsPerPage)
                    {
                        break;
                    }
                }

                if (rects.Count == 0)
                {
                    continue;
                }
                // 紙面には行がそのまま出ているので、前後の文脈は本文から切り出す。
                hits.Add(new PageHit(index, ExcerptAround(ReadText(index), needle), rects));
            }
            return hits;
        }
    }

    /// <summary>
    /// ページを描く。UI が受け取って表示する。
    ///
    /// <para>
    /// 寸法は描くのと同じ丸め方で出す（<c>Rectangle.Round(zoom)</c>）。
    /// 倍率を掛けて自分で丸めると、MuPDF と食い違って絵が 1 画素ずれる。
    /// 画素の並びは縦横を名乗らないので、ここで取り違えると全体が斜めに崩れる。
    /// </para>
    /// </summary>
    public RenderedPage RenderPage(int index, double zoom)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var box = _document.Pages[index].Bounds.Round(zoom);
            var pixels = _document.Render(index, zoom, PixelFormats.RGB, includeAnnotations: true);
            return new RenderedPage(box.Width, box.Height, pixels);
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

    /// <summary>
    /// 1 つの当たりの矩形を、行ごとにまとめる。
    ///
    /// <para>
    /// MuPDFCore は<b>文字ごと</b>に矩形を返す。「page」なら 4 個で、隙間なく隣り合っている。
    /// そのまま渡すと囲みの数が増えるうえ、1 ページあたりの上限をすぐ使い切る。
    /// </para>
    /// <para>
    /// 行をまたぐ当たりは分けたままにする。1 つに均すと、行と行のあいだの
    /// 関係ない本文まで覆ってしまう。
    /// </para>
    /// </summary>
    private static List<PageRect> MergeByLine(IEnumerable<Quad> quads, double left, double top)
    {
        var merged = new List<PageRect>();
        foreach (var quad in quads)
        {
            var rect = RectOf(quad, left, top);
            if (merged.Count > 0 && SameLine(merged[^1], rect))
            {
                var last = merged[^1];
                merged[^1] = new PageRect(
                    Math.Min(last.X0, rect.X0), Math.Min(last.Y0, rect.Y0),
                    Math.Max(last.X1, rect.X1), Math.Max(last.Y1, rect.Y1));
            }
            else
            {
                merged.Add(rect);
            }
        }
        return merged;
    }

    /// <summary>縦の重なりが背の低いほうの半分を超えるなら、同じ行とみなす。</summary>
    private static bool SameLine(PageRect a, PageRect b)
    {
        var overlap = Math.Min(a.Y1, b.Y1) - Math.Max(a.Y0, b.Y0);
        var shortest = Math.Min(a.Y1 - a.Y0, b.Y1 - b.Y0);
        return shortest > 0 && overlap > shortest / 2;
    }

    /// <summary>
    /// 四隅の点を、囲む長方形に均す。傾いた行でも、覆うだけなら長方形で足りる。
    /// </summary>
    private static PageRect RectOf(Quad quad, double left, double top)
    {
        double[] xs = [quad.UpperLeft.X, quad.UpperRight.X, quad.LowerLeft.X, quad.LowerRight.X];
        double[] ys = [quad.UpperLeft.Y, quad.UpperRight.Y, quad.LowerLeft.Y, quad.LowerRight.Y];
        return new PageRect(xs.Min() - left, ys.Min() - top, xs.Max() - left, ys.Max() - top);
    }

    /// <summary>
    /// 当たりの前後を本文から切り出す。見つからなければ頭から見せる。
    /// 文字は Unicode スカラーで数える（本文の位置の数え方と揃える）。
    /// </summary>
    private static string ExcerptAround(string text, string needle)
    {
        var chars = DocumentSearch.Runes(text);
        var target = DocumentSearch.Runes(needle);

        var position = 0;
        for (var i = 0; i + target.Count <= chars.Count; i++)
        {
            var same = true;
            for (var n = 0; n < target.Count && same; n++)
            {
                same = chars[i + n] == target[n];
            }
            if (same)
            {
                position = i;
                break;
            }
        }

        var start = Math.Max(0, position - Before);
        var end = Math.Min(chars.Count, position + target.Count + After);
        return string.Concat(chars.Skip(start).Take(end - start)).Replace('\n', ' ').Trim();
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
