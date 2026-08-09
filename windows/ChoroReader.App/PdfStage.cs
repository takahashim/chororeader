using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using ChoroReader.Core;

namespace ChoroReader.App;

/// <summary>
/// 紙面の舞台。
///
/// <para>
/// PDF は WebView2 に載せない。MuPDF が描いた画素をネイティブのビューへ出す。
/// macOS 版が PDFKit を AppKit のビューで使っているのと同じ形である。
/// </para>
/// </summary>
internal sealed class PdfStage : IStage
{
    private readonly PdfSession _session;
    private readonly SearchIndexStore _indexes;
    private readonly string _bookPath;

    private readonly ScrollViewer _scroll;
    private readonly Grid _stack;
    private readonly Image _paper = new() { Stretch = Stretch.None, SnapsToDevicePixels = true };
    private readonly Canvas _marks = new() { IsHitTestVisible = false };

    internal PdfStage(PdfSession session, SearchIndexStore indexes, string bookPath)
    {
        _session = session;
        _indexes = indexes;
        _bookPath = bookPath;

        // 絵と囲みを重ねる。囲みは絵と同じ座標系に置くので、
        // 丁度重ねておけば倍率を変えても位置が揃う。
        _stack = new Grid
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(12),
        };
        _stack.Children.Add(_paper);
        _stack.Children.Add(_marks);

        _scroll = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Background = new SolidColorBrush(Color.FromRgb(0x3c, 0x3c, 0x3c)),
            Content = _stack,
        };
    }

    public FrameworkElement View => _scroll;

    public string BookTitle => System.IO.Path.GetFileNameWithoutExtension(_bookPath);

    public event Action? Moved;

    /// <summary>紙面は組み直せない。文字サイズも行間も効かない。</summary>
    public bool Reflowable => false;

    public IReadOnlyList<Place> Toc =>
        [.. Flatten(_session.Document.Outline(), 0)];

    private static IEnumerable<Place> Flatten(IReadOnlyList<TocEntry> entries, int depth)
    {
        foreach (var entry in entries)
        {
            // **アウトラインのページは 0 始まりである。**（PdfProbeTests が押さえている）
            // 1 始まりと思って引くと、目次から飛ぶたびに 1 ページ手前へ着く。
            yield return new Place(entry.Title, Page: entry.Page ?? 0, Depth: depth);
            foreach (var child in Flatten(entry.Children, depth + 1))
            {
                yield return child;
            }
        }
    }

    public IReadOnlyList<Place> Pages =>
        [.. Enumerable.Range(0, _session.Count).Select(i => new Place($"{i + 1}", Page: i))];

    /// <summary>
    /// 文字の層を持たない PDF はある（紙を撮っただけのもの）。
    /// <b>引けないことは引く前に分かる</b>ので、欄を押す前に理由を出す。
    /// </summary>
    public string? CannotSearch =>
        _session.Document.HasTextLayer ? null : "この PDF には文字の層がないため検索できません";

    public Whereabouts Where => new(
        $"{_session.Page + 1} / {_session.Count} ページ",
        $"{_session.Zoom * 100:F0}%");

    public Position Position => new() { Page = _session.Page };

    /// <summary>紙面には間引きが無い。ページは移った瞬間に確かなので、待つものが無い。</summary>
    public bool PositionPending => false;

    public void ResumeFrom(Position position) => _session.MoveTo(position.Page);

    /// <summary>最初のページを出す。</summary>
    public Task StartAsync() => ShowAsync(_session.Page);

    /// <summary>
    /// ページを描いて出す。
    ///
    /// <para>
    /// <b>描くのは背後のスレッドで行う。</b>大きな紙面は時間がかかり、
    /// 画面のスレッドで描くと窓が固まる。<see cref="PdfInspector"/> は直列化済みなので、
    /// 背後から呼んでよい。
    /// </para>
    /// </summary>
    internal async Task ShowAsync(int page)
    {
        _session.MoveTo(page);
        var at = _session.Page;
        var zoom = _session.Zoom;

        var drawn = await Task.Run(() => _session.Document.RenderPage(at, zoom));

        _paper.Source = ToBitmap(drawn);
        _paper.Width = drawn.Width;
        _paper.Height = drawn.Height;
        _marks.Width = drawn.Width;
        _marks.Height = drawn.Height;
        DrawnCount++;

        DrawMarks(zoom);
        Moved?.Invoke();
    }

    /// <summary>
    /// 画素の並びを、そのまま出せる絵にする。
    ///
    /// <para>
    /// <b>寸法は描いたものが名乗る値を使う。</b>倍率から計算し直すと、
    /// MuPDF の丸め方と食い違って絵が斜めに崩れる。
    /// <c>Freeze</c> するのは、背後のスレッドで作った絵を画面のスレッドで使うためである。
    /// </para>
    /// </summary>
    private static BitmapSource ToBitmap(RenderedPage drawn)
    {
        var bitmap = BitmapSource.Create(
            drawn.Width, drawn.Height, 96, 96, PixelFormats.Rgb24, null, drawn.Pixels, drawn.Stride);
        bitmap.Freeze();
        return bitmap;
    }

    /// <summary>
    /// 当たりの囲みを重ねる。
    ///
    /// <para>
    /// 座標は描いた絵の左上を原点とする点（<see cref="PageRect"/>）なので、
    /// 倍率を掛ければそのまま画素の位置になる。
    /// </para>
    /// </summary>
    private void DrawMarks(double zoom)
    {
        _marks.Children.Clear();
        foreach (var rect in _session.RectsOnPage)
        {
            var box = new Rectangle
            {
                Width = Math.Max(1, (rect.X1 - rect.X0) * zoom),
                Height = Math.Max(1, (rect.Y1 - rect.Y0) * zoom),
                Fill = new SolidColorBrush(Color.FromArgb(0x55, 0xff, 0xd5, 0x4f)),
                IsHitTestVisible = false,
            };
            Canvas.SetLeft(box, rect.X0 * zoom);
            Canvas.SetTop(box, rect.Y0 * zoom);
            _marks.Children.Add(box);
        }
    }

    // MARK: 操作

    public async Task<bool> MoveAsync(int delta)
    {
        if (!_session.Move(delta))
        {
            return false;
        }
        await ShowAsync(_session.Page);
        return true;
    }

    public async Task GoAsync(Place place) => await ShowAsync(place.Page);

    internal async Task ZoomAsync(double factor)
    {
        _session.ZoomBy(factor);
        await ShowAsync(_session.Page);
    }

    /// <summary>
    /// 紙面を引き、最初の当たりのページへ移る。
    ///
    /// <para>
    /// 索引があれば候補を絞ってから引く。<b>索引は候補を絞るだけで、当たりは決めない</b>ので、
    /// 索引の有無で結果は変わらない。
    /// </para>
    /// </summary>
    public async Task<(IReadOnlyList<Place> Hits, bool Truncated)> FindAsync(string query)
    {
        query = query.Trim();
        if (query.Length == 0)
        {
            _session.Find(string.Empty, null);
            await ShowAsync(_session.Page);
            return ([], false);
        }

        var index = await Task.Run(() =>
            _indexes.Ensure(_bookPath, () => _session.Document.PageTexts()));
        await Task.Run(() => _session.Find(query, index));

        await ShowAsync(_session.Hits.Count > 0 ? _session.Hits[0].Page : _session.Page);

        return ([.. _session.Hits.Select(hit => new Place(
            Label: $"{hit.Page + 1} ページ",
            Page: hit.Page,
            Query: query,
            Detail: hit.Excerpt.Replace('\n', ' ')))], false);
    }

    /// <summary>紙面には効かない。文字を組み直せないので、当てるものが無い。</summary>
    public Task ApplyStyleAsync(ReaderStyle style) => Task.CompletedTask;

    public void Dispose() => _session.Dispose();

    // MARK: 動作確認のための覗き口

    /// <summary>描けた回数。動作確認が「枠だけ出来ていないか」を見る。</summary>
    internal int DrawnCount { get; private set; }

    /// <summary>いま出している絵。動作確認が寸法を見る。</summary>
    internal BitmapSource? Drawn => _paper.Source as BitmapSource;

    internal int Page => _session.Page;

    internal double Zoom => _session.Zoom;

    internal int MarkCount => _marks.Children.Count;

    internal IReadOnlyList<PageHit> Hits => _session.Hits;
}
