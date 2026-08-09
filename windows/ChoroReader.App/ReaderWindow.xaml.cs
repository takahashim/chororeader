using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using ChoroReader.Core;

namespace ChoroReader.App;

/// <summary>サイドバーの面。</summary>
internal enum Pane
{
    Toc,
    Pages,
    Found,
    Marks,
}

/// <summary>
/// 読書の窓。1 窓 1 文書（spec.md 4.1）。
///
/// <para>
/// <b>形式で窓を分けない。</b>道具帯・サイドバー・下辺は形式に依らず同じ場所にあり、
/// 差し替わるのは舞台（<see cref="IStage"/>）だけである
/// （windows/README.md「画面の組み立て」）。
/// </para>
/// <para>
/// 殻はネイティブで、本文だけが WebView2 に入る。
/// 書籍の script は CSP で止め、注入したものだけを動かす（spec.md 15.1）。
/// </para>
/// </summary>
public partial class ReaderWindow : Window
{
    private readonly IStage _stage;
    private readonly ReadingStore _store;
    private readonly string _bookPath;

    /// <summary>戻る／進む。目次や検索から飛んだあと元へ帰る道。</summary>
    private readonly History<Place> _history = new();

    private ReaderStyle _style;

    /// <summary>いま出している面。</summary>
    private Pane _pane = Pane.Toc;

    /// <summary>直前に引いた結果。面を切り替えて戻ってきても消えないように控える。</summary>
    private IReadOnlyList<Place> _found = [];

    /// <summary>組み立ての途中では設定を当てない。部品を初期値にするだけで便りが飛ぶ。</summary>
    private bool _settling = true;

    internal ReaderWindow(IStage stage, ReadingStore store, string bookPath)
    {
        InitializeComponent();
        _stage = stage;
        _store = store;
        _bookPath = bookPath;
        _style = store.Settings;

        StageHost.Content = stage.View;
        stage.Moved += OnStageMoved;

        // 覚えていた場所から始める。無ければ最初から。
        _stage.ResumeFrom(store.StateOf(bookPath).Position);
        store.RememberTitle(bookPath, stage.BookTitle);

        // **つまみの配線は組み立てが済んでから行う。**
        //
        // XAML に書くと、読み込みの最中に発火する。`Minimum="70"` を置いた時点で
        // `Value` が 0 から 70 へ引き上げられ、`ValueChanged` が走るためである。
        // そのとき同じポップオーバーの後ろにある値の表示（LineValue・WidthValue）は
        // まだ作られていないので、null を触って落ちる。
        //
        // **`async void` の中で落ちるので、その場では落ちない。** 例外は催しの列へ
        // 積まれ、後で誰かが列を回したときに出る。窓が先に閉じれば出ないこともある。
        // CI で 1 度は通り、次に落ちたのはそのためである。
        SizeSlider.ValueChanged += OnStyleSlid;
        LineSlider.ValueChanged += OnStyleSlid;
        WidthSlider.ValueChanged += OnStyleSlid;

        // 縦は読むための軸、横は移動するための軸（spec.md 10.2）。
        // 矢印はメニューのキー等価にしない。窓が焦点を持っているときだけ処理する。
        PreviewKeyDown += OnKeyDown;
        Closed += (_, _) => _stage.Dispose();
    }

    internal async Task StartAsync()
    {
        FillPane();
        ShowStyle();
        await _stage.StartAsync();
        Remember();
        ShowWhere();

        // 開いた場所を履歴の起点にする。積まないと、1 度飛んだだけでは戻り先が無い。
        _history.Visit(Anchor());
        ShowHistory();
    }

    // MARK: 舞台からの便り

    /// <summary>
    /// 舞台が動いたら、道具帯と下辺を書き直し、読んだ場所を控える。
    /// </summary>
    private void OnStageMoved()
    {
        ShowWhere();
        Remember();
    }

    private void ShowWhere()
    {
        var (title, position) = _stage.Where;
        PlaceLabel.Text = $"{_stage.BookTitle} — {title}";
        Title = $"{_stage.BookTitle} — {title}";
        PositionLabel.Text = position;
        BookmarkButton.IsChecked = HasBookmarkHere();
    }

    /// <summary>
    /// どこまで読んだかを控える。
    ///
    /// <para>
    /// <b>章は移った瞬間に、章の中の位置は便りが届いてから。</b>
    /// 位置の便りは間引いて届くので、それを待って章まで書いていると、
    /// 開いてすぐ閉じたときに覚え書きが前の章のまま残る（<see cref="ReadingStore.RememberChapter"/>）。
    /// </para>
    /// </summary>
    private void Remember()
    {
        if (_stage.PositionPending)
        {
            _store.RememberChapter(_bookPath, _stage.Position.Href);
        }
        else
        {
            _store.Remember(_bookPath, _stage.Position);
        }
    }

    /// <summary>覚えている位置。動作確認が「戻せたか」を見る。</summary>
    internal Position Remembered => _store.StateOf(_bookPath).Position;

    // MARK: サイドバー

    private void OnToggleSide(object sender, RoutedEventArgs e)
    {
        var open = SideToggle.IsChecked == true;
        // 閉じているときは仕切りも消す。掴めるものが残っていると、
        // 何も無いところに縦線が出て、押しても何も起きない。
        SideColumn.Width = open ? new GridLength(300) : new GridLength(0);
        SideColumn.MinWidth = open ? 180 : 0;
        SplitColumn.Width = open ? GridLength.Auto : new GridLength(0);
        SideSplitter.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowSide(Pane pane)
    {
        _pane = pane;
        SideToggle.IsChecked = true;
        OnToggleSide(this, new RoutedEventArgs());
        (pane switch
        {
            Pane.Pages => PagesTab,
            Pane.Found => FoundTab,
            Pane.Marks => MarksTab,
            _ => TocTab,
        }).IsChecked = true;
        FillPane();
    }

    private void OnPaneChanged(object sender, RoutedEventArgs e)
    {
        if (_settling)
        {
            return;
        }
        _pane = sender switch
        {
            var t when ReferenceEquals(t, PagesTab) => Pane.Pages,
            var t when ReferenceEquals(t, FoundTab) => Pane.Found,
            var t when ReferenceEquals(t, MarksTab) => Pane.Marks,
            _ => Pane.Toc,
        };
        FillPane();
    }

    /// <summary>
    /// いま選ばれている面を並べる。
    ///
    /// <para>
    /// <b>空のときは、空である理由を出す。</b>ただ空の一覧を出すと、
    /// 目次を持たない書籍なのか、こちらが読み損ねたのかが読者に分からない。
    /// </para>
    /// </summary>
    private void FillPane()
    {
        // 紙面を持たない書籍では、ページのタブそのものを出さない。
        PagesTab.Visibility = _stage.Pages.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        var (rows, note) = _pane switch
        {
            Pane.Pages => (_stage.Pages, "この書籍にはページ画像がありません"),
            Pane.Found => (_found, Query.Text.Trim().Length == 0
                ? "語句を入力してください"
                : _stage.CannotSearch ?? "見つかりませんでした"),
            Pane.Marks => (Bookmarks(), "しおりはまだありません（☆ で追加）"),
            _ => (_stage.Toc, "目次がありません"),
        };

        Rows.ItemsSource = rows;
        PaneNote.Text = note;
        PaneNote.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnGoRow(object sender, MouseButtonEventArgs e)
    {
        if (Rows.SelectedItem is Place place)
        {
            await GoAsync(place);
        }
    }

    // MARK: 移動

    /// <summary>
    /// 行き先へ飛ぶ。
    ///
    /// <para>
    /// 飛んだ先は履歴に積む。<b>前後へ送っただけのものも積む</b>ので、
    /// 章をいくつか送ってから検索で飛んでも、送った道を辿って帰れる。
    /// </para>
    /// </summary>
    internal async Task GoAsync(Place place)
    {
        await _stage.GoAsync(place);
        _history.Visit(Anchor(place.Fragment));
        ShowHistory();
    }

    /// <summary>
    /// 履歴に積む形。
    ///
    /// <para>
    /// <b>行き先そのものではなく、着いた場所を積む。</b>
    /// 当たりの一覧から積むと、書き出しが 1 件ずつ違うので同じ章でも別のものになり、
    /// 同じ章の当たりを行き来しただけで履歴が伸びて、戻るを押しても同じ章に留まり続ける。
    /// 語と番号も落とす（戻ったときに前の印を引きずらないため）。
    /// </para>
    /// </summary>
    private Place Anchor(string? fragment = null) =>
        new(_stage.Where.Title, _stage.Position.Href, fragment, _stage.Position.Page);

    private void ShowHistory()
    {
        BackButton.IsEnabled = _history.CanGoBack;
        ForwardButton.IsEnabled = _history.CanGoForward;
    }

    internal async Task GoBackAsync()
    {
        if (_history.GoBack() is { } place)
        {
            await _stage.GoAsync(place);
            ShowHistory();
        }
    }

    internal async Task GoForwardAsync()
    {
        if (_history.GoForward() is { } place)
        {
            await _stage.GoAsync(place);
            ShowHistory();
        }
    }

    private async void OnGoBack(object sender, RoutedEventArgs e) => await GoBackAsync();

    private async void OnGoForward(object sender, RoutedEventArgs e) => await GoForwardAsync();

    internal async Task MoveAsync(int delta)
    {
        if (await _stage.MoveAsync(delta))
        {
            _history.Visit(Anchor());
            ShowHistory();
        }
    }

    private async void OnGoPrev(object sender, RoutedEventArgs e) => await MoveAsync(-1);

    private async void OnGoNext(object sender, RoutedEventArgs e) => await MoveAsync(1);

    private async void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.KeyboardDevice.Modifiers is not ModifierKeys.None || Query.IsKeyboardFocusWithin)
        {
            return;
        }
        switch (e.Key)
        {
            // 横は移動するための軸。前後の章・ページへ。
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

    // MARK: 引く

    internal int HitCount => _found.Count;

    /// <summary>最初の当たり。動作確認が飛び先として使う。</summary>
    internal Place? FirstHit => _found.Count > 0 ? _found[0] : null;

    internal int TocCount => _stage.Toc.Count;

    internal async Task FindAsync(string query)
    {
        query = query.Trim();
        Query.Text = query;

        if (_stage.CannotSearch is { } reason)
        {
            _found = [];
            ShowSide(Pane.Found);
            StatusLabel.Text = reason;
            return;
        }

        StatusLabel.Text = query.Length == 0 ? string.Empty : "引いています…";
        var (hits, truncated) = await _stage.FindAsync(query);
        _found = hits;

        ShowSide(Pane.Found);
        StatusLabel.Text = query.Length == 0
            ? string.Empty
            : hits.Count == 0
                ? $"「{query}」は見つかりませんでした"
                : $"{hits.Count} 件{(truncated ? "（打ち切り）" : "")}";
    }

    private async void OnQueryKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            await FindAsync(Query.Text);
        }
    }

    // MARK: しおり

    /// <summary>
    /// しおりを行き先の形にする。
    ///
    /// <para>
    /// <b>章の中の位置も渡す。</b>章の頭へ飛ばすだけでは、長い章に挟んだしおりが役に立たない。
    /// </para>
    /// </summary>
    private IReadOnlyList<Place> Bookmarks() =>
        [.. _store.StateOf(_bookPath).Bookmarks.Select(mark => new Place(
            Label: mark.Label.Length > 0 ? mark.Label : mark.Text,
            Href: mark.Href,
            Page: mark.Page,
            Progression: mark.Progression,
            Detail: mark.Label.Length > 0 && mark.Text.Length > 0 ? mark.Text : null))];

    private Bookmark Here() => new()
    {
        Href = _stage.Position.Href,
        Progression = _stage.Position.Progression,
        Page = _stage.Position.Page,
        Label = _stage.Where.Title,
        Text = _stage.Position.Text,
    };

    private bool HasBookmarkHere()
    {
        var here = Here();
        return _store.StateOf(_bookPath).Bookmarks.Any(
            mark => mark.Href == here.Href && mark.Page == here.Page
                    && Math.Abs(mark.Progression - here.Progression) < 0.0005);
    }

    /// <summary>いまの場所にしおりを付ける。もう付いていれば外す。</summary>
    internal void ToggleBookmark()
    {
        var after = _store.ToggleBookmark(_bookPath, Here());
        BookmarkButton.IsChecked = HasBookmarkHere();
        StatusLabel.Text = HasBookmarkHere() ? "しおりを付けました" : "しおりを外しました";
        if (_pane == Pane.Marks)
        {
            FillPane();
        }
        BookmarkCount = after.Count;
    }

    /// <summary>いまのしおりの数。動作確認が見る。</summary>
    internal int BookmarkCount { get; private set; }

    private void OnToggleBookmark(object sender, RoutedEventArgs e) => ToggleBookmark();

    // MARK: 表示設定

    private void OnToggleStyle(object sender, RoutedEventArgs e) =>
        StylePanel.IsOpen = StyleButton.IsChecked == true;

    /// <summary>
    /// 覚えていた設定を部品へ映す。
    ///
    /// <para>
    /// 組み直せない書籍では、効く設定だけを出す。
    /// 触れるのに何も起きない部品を並べると、効かないのか壊れているのか分からない。
    /// </para>
    /// </summary>
    private void ShowStyle()
    {
        _settling = true;

        SizeSlider.Value = _style.FontSizePercent;
        LineSlider.Value = _style.LineHeight;
        WidthSlider.Value = _style.MaxWidthEm;
        CodeWrapBox.IsChecked = _style.CodeWrap;
        PublisherBox.IsChecked = _style.PublisherStyle;
        ThemePicker.SelectedIndex = _style.Theme switch
        {
            ReaderTheme.Sepia => 1,
            ReaderTheme.Dark => 2,
            _ => 0,
        };

        ReflowableOnly.Visibility = _stage.Reflowable ? Visibility.Visible : Visibility.Collapsed;
        StyleNote.Visibility = _stage.Reflowable ? Visibility.Collapsed : Visibility.Visible;

        ShowStyleValues();
        _settling = false;
    }

    private void ShowStyleValues()
    {
        SizeValue.Text = $"{SizeSlider.Value:F0}%";
        LineValue.Text = $"{LineSlider.Value:F1}";
        WidthValue.Text = WidthSlider.Value >= 100 ? "制限なし" : $"{WidthSlider.Value:F0}em";
    }

    private async void OnStyleSlid(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        // 覚えていた設定を部品へ映している最中も発火する。そこでは当てない。
        if (_settling)
        {
            return;
        }
        ShowStyleValues();
        await ApplyPickedStyleAsync();
    }

    private async void OnStyleChanged(object sender, RoutedEventArgs e) => await ApplyPickedStyleAsync();

    private async void OnStyleChanged(object sender, SelectionChangedEventArgs e) => await ApplyPickedStyleAsync();

    private async Task ApplyPickedStyleAsync()
    {
        if (_settling)
        {
            return;
        }
        await ApplyStyleAsync(_style with
        {
            FontSizePercent = SizeSlider.Value,
            LineHeight = LineSlider.Value,
            MaxWidthEm = WidthSlider.Value,
            CodeWrap = CodeWrapBox.IsChecked == true,
            PublisherStyle = PublisherBox.IsChecked == true,
            Theme = ThemePicker.SelectedIndex switch
            {
                1 => ReaderTheme.Sepia,
                2 => ReaderTheme.Dark,
                _ => ReaderTheme.Light,
            },
        });
        // 次に開く窓も同じ見え方にする。
        _store.SaveSettings(_style);
    }

    internal async Task ApplyStyleAsync(ReaderStyle style)
    {
        _style = style;
        await _stage.ApplyStyleAsync(style);
    }

    // MARK: 書棚

    /// <summary>
    /// 書棚を開く。
    ///
    /// <para>
    /// <b>いったん催しの列へ戻してから開く。</b>WebView2 は自分の呼び返しの最中に
    /// 次の WebView を作らせず、枠だけ出来て中身が空になる（windows/README.md の規則）。
    /// </para>
    /// </summary>
    private void OnOpenShelf(object sender, RoutedEventArgs e) =>
        Dispatcher.BeginInvoke(new Action(() => ((App)Application.Current).OpenShelf()));

    // MARK: 動作確認のための覗き口

    /// <summary>舞台。動作確認が形式ごとの中身を見る。</summary>
    internal IStage Stage => _stage;

    /// <summary>戻れるか。動作確認が「飛んだあと帰れるか」を見る。</summary>
    internal bool CanGoBack => _history.CanGoBack;

    internal bool CanGoForward => _history.CanGoForward;

    internal WebStage? Web => _stage as WebStage;

    internal PdfStage? Paper => _stage as PdfStage;
}
