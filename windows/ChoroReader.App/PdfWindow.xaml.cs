using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using ChoroReader.Core;

namespace ChoroReader.App;

/// <summary>
/// 紙面の窓。1 窓 1 文書（spec.md 4.1）。
///
/// <para>
/// PDF は WebView2 に載せない。MuPDF が描いた画素をネイティブのビューへ出す。
/// macOS 版が PDFKit を AppKit のビューで使っているのと同じ形である。
/// </para>
/// </summary>
public partial class PdfWindow : Window
{
    private readonly PdfSession _session;

    /// <summary>描けた回数。動作確認が「枠だけ出来ていないか」を見る。</summary>
    internal int DrawnCount { get; private set; }

    /// <summary>いま出している絵。動作確認が寸法を見る。</summary>
    internal BitmapSource? Drawn => Paper.Source as BitmapSource;

    internal int Page => _session.Page;

    internal double Zoom => _session.Zoom;

    internal int MarkCount => Marks.Children.Count;

    internal PdfWindow(PdfSession session)
    {
        InitializeComponent();
        _session = session;
        Closed += (_, _) => _session.Dispose();

        // 縦は読むための軸、横は移動するための軸（spec.md 10.2）。
        // 矢印はメニューのキー等価にしない。窓が焦点を持っているときだけ処理する。
        PreviewKeyDown += OnKeyDown;
    }

    /// <summary>最初のページを出す。</summary>
    internal Task StartAsync() => ShowAsync(_session.Page);

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

        Paper.Source = ToBitmap(drawn);
        Paper.Width = drawn.Width;
        Paper.Height = drawn.Height;
        Marks.Width = drawn.Width;
        Marks.Height = drawn.Height;
        DrawnCount++;

        DrawMarks(zoom);

        PageLabel.Text = $"{at + 1} / {_session.Count} ページ";
        ZoomLabel.Text = $"{zoom * 100:F0}%";
        Title = $"{System.IO.Path.GetFileName(TitleSource)} — {at + 1} / {_session.Count}";
    }

    internal string TitleSource { get; init; } = "ChoroReader";

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
        Marks.Children.Clear();
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
            Marks.Children.Add(box);
        }
    }

    // MARK: 操作

    internal async Task MoveAsync(int delta)
    {
        if (_session.Move(delta))
        {
            await ShowAsync(_session.Page);
        }
    }

    internal async Task ZoomAsync(double factor)
    {
        _session.ZoomBy(factor);
        await ShowAsync(_session.Page);
    }

    /// <summary>紙面を引き、最初の当たりのページへ移る。</summary>
    internal async Task FindAsync(string query, SearchIndex? index)
    {
        _session.Find(query, index);
        await ShowAsync(_session.Hits.Count > 0 ? _session.Hits[0].Page : _session.Page);
    }

    internal IReadOnlyList<PageHit> Hits => _session.Hits;

    private async void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.KeyboardDevice.Modifiers is not ModifierKeys.None)
        {
            return;
        }
        switch (e.Key)
        {
            // 横は移動するための軸。前後のページへ。
            case Key.Right:
                e.Handled = true;
                await MoveAsync(1);
                break;
            case Key.Left:
                e.Handled = true;
                await MoveAsync(-1);
                break;
        }
    }
}
