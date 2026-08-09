using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using ChoroReader.Core;
using ChoroReader.Semantic;

namespace ChoroReader.App;

/// <summary>
/// 書棚に並ぶ 1 冊。
///
/// <para>
/// 表紙は<b>後から届く</b>。書籍を開いて取り出すので、蔵書が増えるほど時間がかかる。
/// 揃うまで並べないと空の書棚を見せることになるので、先に題名で並べ、届いたぶんから差し替える。
/// </para>
/// </summary>
internal sealed class ShelfBook(string path, string title, string kind, double progression)
    : INotifyPropertyChanged
{
    public string Path { get; } = path;

    public string Title { get; } = title;

    /// <summary>リフロー EPUB・固定レイアウト EPUB・PDF のどれか。</summary>
    public string Kind { get; } = kind;

    public double Progression { get; } = progression;

    public string Percent => $"{Progression * 100:F0}%";

    private BitmapSource? _cover;

    public BitmapSource? Cover
    {
        get => _cover;
        set
        {
            _cover = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Cover)));
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public override string ToString() => Title;
}

/// <summary>
/// 意味で引いた 1 件。押すとその場所へ飛ぶ。
///
/// <para>
/// <b>当たりではない。</b>囲む語が無いので、飛び先は位置と目印だけで決まる。
/// </para>
/// </summary>
internal sealed class NearRow(SemanticHit hit)
{
    internal SemanticHit Hit { get; } = hit;

    public string Where => Hit.Heading.Length > 0 ? $"{Hit.Title} — {Hit.Heading}" : Hit.Title;

    /// <summary>近さ。<b>件数を出さない代わりに、これで測れるようにする。</b></summary>
    public string Score => Hit.Score.ToString("F2");

    public string Excerpt => Hit.Text;
}

/// <summary>横断検索の当たり 1 件。押すとその場所へ飛ぶ。</summary>
internal sealed record ShelfHit(string Path, string Title, LibraryHit Hit)
{
    public string Where => Hit.Where.Length > 0 ? $"{Title} — {Hit.Where}" : Title;

    public string Excerpt => Hit.Excerpt;

    public override string ToString() => $"{Where}: {Excerpt}";
}

/// <summary>
/// 書棚の窓。すべてネイティブで、WebView は使わない。
///
/// <para>
/// 蔵書を並べ、横断して引く（spec.md 10.4）。
/// 引くのは <see cref="LibrarySearch"/> に任せ、ここは並べるだけにする。
/// </para>
/// <para>
/// 面は 3 つあり、同時には 1 つしか出さない。
/// <b>引き方ごとに見る問いが違う。</b>語句側だけを見ていると、
/// 語句を消したのに結果が出たままになる。
/// </para>
/// </summary>
public partial class ShelfWindow : Window
{
    private readonly LibrarySearch _search;
    private readonly ReadingStore _reading;
    private readonly SemanticIndexBuilder _builder;
    private readonly SemanticIndexStore _semantic;
    private readonly List<ShelfBook> _shelf = [];
    private CancellationTokenSource? _running;

    /// <summary>いま並んでいる当たり。動作確認が見る。</summary>
    internal int HitCount => Hits.Items.Count;

    /// <summary>意味で引いた結果の数。<b>画面には出さない</b>（当たりではないので）。</summary>
    internal int NearCount => Near.Items.Count;

    /// <summary>意味で引く側を選んでいるか。</summary>
    internal bool SearchingSemantically => SemanticKind.IsChecked == true;

    internal int BookCount => _shelf.Count;

    /// <summary>表紙が出た冊数。取れない書籍はあるので、全冊とは限らない。</summary>
    internal int CoverCount => _shelf.Count(b => b.Cover is not null);

    /// <summary>結果の面を出しているか。</summary>
    internal bool ShowingResults =>
        Hits.Visibility == Visibility.Visible || Near.Visibility == Visibility.Visible;

    /// <summary>一覧（表）で並べているか。</summary>
    internal bool ShowingTable => TableMode.IsChecked == true;

    /// <summary>意味の層を入にできるか。モデルが無ければ押せない。</summary>
    internal bool CanUseSemantic => SemanticToggle.IsEnabled;

    /// <summary>意味の層が入っているか。</summary>
    internal bool SemanticEnabled => _builder.Enabled;

    /// <summary>索引づくりの様子を出しているか。</summary>
    internal bool ShowingBuilding => Building.Visibility == Visibility.Visible;

    /// <summary>いま出している状態の文。動作確認が読む。</summary>
    internal string Status => StatusLabel.Text;

    /// <summary>意味で引く。動作確認が押す。</summary>
    internal async Task FindNearAsync(string query)
    {
        SemanticKind.IsChecked = true;
        Query.Text = query;
        await FindAsync(query);
    }

    /// <summary>意味の層を入/切する。動作確認が押す。</summary>
    internal void UseSemantic(bool wanted)
    {
        SemanticToggle.IsChecked = wanted;
        OnToggleSemantic(this, new RoutedEventArgs());
    }

    internal ShelfWindow(SearchIndexStore store, ReadingStore reading,
                         SemanticIndexBuilder builder, SemanticIndexStore semantic)
    {
        InitializeComponent();
        _search = new LibrarySearch(store);
        _reading = reading;
        _builder = builder;
        _semantic = semantic;

        // 手元にモデルが無ければ、入にはできない。
        SemanticToggle.IsEnabled = App.HasModel;
        SemanticToggle.IsChecked = builder.Enabled;
        if (!App.HasModel)
        {
            SemanticToggle.ToolTip = $"モデルが見つかりません（{App.ModelDirectory}）";
        }

        // **係は画面を知らない。** 動いたことだけ伝わるので、描き直す筋はこちらで決める。
        _builder.Changed += OnBuilderChanged;
        Closed += (_, _) =>
        {
            _builder.Changed -= OnBuilderChanged;
            _running?.Cancel();
        };
        Drop += OnDrop;
        ShowBuilding();
    }

    // MARK: 意味の層

    private void OnBuilderChanged() => Dispatcher.BeginInvoke(new Action(ShowBuilding));

    /// <summary>
    /// 索引づくりの様子を出す。
    ///
    /// <para>
    /// <b>「まだ作っていない」と「作ったが版が変わった」を分けて言う</b>（spec-local-ai.md 4.4）。
    /// 前者は待てば済むが、後者は全量が作り直しになる。混ぜると、
    /// モデルを入れ替えた日に「なぜ終わらないのか」が分からなくなる。
    /// </para>
    /// </summary>
    private void ShowBuilding()
    {
        if (_builder.Working is { } working)
        {
            Building.Visibility = Visibility.Visible;
            var rest = _builder.Pending > 0 ? $"（あと {_builder.Pending} 冊）" : "";
            BuildingLabel.Text = $"意味の索引を作っています：{working.Title}{rest}";
            BuildingBar.Value = working.Fraction;
            return;
        }

        Building.Visibility = Visibility.Collapsed;
        if (_builder.Failure is { } failure)
        {
            StatusLabel.Text = $"意味の索引を作れませんでした — {failure}";
            return;
        }
        if (!_builder.Enabled || _shelf.Count == 0)
        {
            return;
        }

        var counts = _builder.Count(_shelf.Select(book => book.Path));
        StatusLabel.Text = (counts.NotBuilt, counts.Stale) switch
        {
            (0, 0) => $"{_shelf.Count} 冊（意味の索引は揃っています）",
            (_, 0) => $"{_shelf.Count} 冊（意味の索引がまだ {counts.NotBuilt} 冊）",
            (0, _) => $"{_shelf.Count} 冊（モデルが変わったので {counts.Stale} 冊が作り直しになります）",
            _ => $"{_shelf.Count} 冊（まだ {counts.NotBuilt} 冊、作り直し {counts.Stale} 冊）",
        };
    }

    private void OnToggleSemantic(object sender, RoutedEventArgs e)
    {
        var wanted = SemanticToggle.IsChecked == true;
        ((App)Application.Current).SaveSemantic(wanted);
        if (wanted)
        {
            // 入にした時点では並べない。書棚が落ち着いてから始める。
            _builder.ScheduleIdle([.. _shelf.Select(book => book.Path)]);
        }
        ShowBuilding();
    }

    private void OnStopBuilding(object sender, RoutedEventArgs e)
    {
        _builder.Stop();
        ShowBuilding();
    }

    internal void Add(params string[] paths)
    {
        foreach (var path in paths)
        {
            if (_shelf.Any(b => string.Equals(b.Path, path, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }
            var state = _reading.StateOf(path);
            _shelf.Add(new ShelfBook(
                path,
                state.Title.Length > 0 ? state.Title : System.IO.Path.GetFileNameWithoutExtension(path),
                KindOf(path),
                state.Position.Progression));
        }
        Covers.ItemsSource = null;
        Covers.ItemsSource = _shelf;
        Table.ItemsSource = null;
        Table.ItemsSource = _shelf;
        ShowShelf();

        // **書棚が落ち着いたら、残りを作り始める。** 開いた直後は表紙の読み込みが
        // 走っているので、そこへ重ねない（係が 8 秒待つ）。
        _builder.ScheduleIdle([.. _shelf.Select(book => book.Path)]);
    }

    /// <summary>
    /// 何の書籍かを、開かずに言える範囲で言う。
    /// リフローか固定かは開かないと分からないので、EPUB はそこまでにする。
    /// </summary>
    private static string KindOf(string path) =>
        DocumentFormats.Detect(path) switch
        {
            DocumentFormat.Pdf => "PDF",
            DocumentFormat.Markdown => "Markdown",
            _ => "EPUB",
        };

    /// <summary>
    /// 表紙を取り出して並べる。
    ///
    /// <para>
    /// <b>1 冊ずつ、届いたぶんから差し替える。</b>全部揃うまで待つと、
    /// 蔵書が増えたときに空の書棚を長く見せることになる。
    /// 取り出しは背後のスレッドで行う。書籍を開くので、画面で回すと固まる。
    /// </para>
    /// </summary>
    internal async Task LoadCoversAsync()
    {
        foreach (var book in _shelf.ToList())
        {
            if (book.Cover is not null)
            {
                continue;
            }
            var cover = await Task.Run(() => CoverCache.Of(book.Path));
            book.Cover = cover;
        }
    }

    // MARK: 面の出し分け

    /// <summary>
    /// 蔵書の面へ戻す。表紙か一覧かは選ばれているほうを出す。
    /// </summary>
    private void ShowShelf()
    {
        var empty = _shelf.Count == 0;
        Hits.Visibility = Visibility.Collapsed;
        Near.Visibility = Visibility.Collapsed;
        Empty.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        Covers.Visibility = !empty && !ShowingTable ? Visibility.Visible : Visibility.Collapsed;
        Table.Visibility = !empty && ShowingTable ? Visibility.Visible : Visibility.Collapsed;
        StatusLabel.Text = $"{_shelf.Count} 冊";
        ShowBuilding();
    }

    private void ShowResults()
    {
        Covers.Visibility = Visibility.Collapsed;
        Table.Visibility = Visibility.Collapsed;
        Empty.Visibility = Visibility.Collapsed;
        // 引き方で面を分ける。**混ぜない。**
        Hits.Visibility = SearchingSemantically ? Visibility.Collapsed : Visibility.Visible;
        Near.Visibility = SearchingSemantically ? Visibility.Visible : Visibility.Collapsed;
    }

    internal void ShowCovers()
    {
        CoverMode.IsChecked = true;
        if (!ShowingResults)
        {
            ShowShelf();
        }
    }

    internal void ShowTable()
    {
        TableMode.IsChecked = true;
        if (!ShowingResults)
        {
            ShowShelf();
        }
    }

    private void OnModeChanged(object sender, RoutedEventArgs e)
    {
        if (IsLoaded && !ShowingResults)
        {
            ShowShelf();
        }
    }

    // MARK: 引く

    /// <summary>
    /// 蔵書を横断して引く。
    ///
    /// <para>
    /// <b>当たった本から順に並べる。</b>全部を引き終えてから出すと、
    /// 蔵書が増えたときに何も出ない時間が長くなる。
    /// 引くのは背後のスレッドで行い、並べるのは画面のスレッドで行う。
    /// </para>
    /// </summary>
    internal async Task FindAsync(string query)
    {
        // 前の走査は降ろす。打ち込むたびに走らせると、古い結果が後から混ざる。
        _running?.Cancel();
        var mine = new CancellationTokenSource();
        _running = mine;

        Hits.Items.Clear();
        Near.Items.Clear();
        query = query.Trim();
        if (query.Length == 0)
        {
            // 語句を消したら蔵書へ戻す。結果の面を出したままにしない。
            ShowShelf();
            return;
        }

        if (SearchingSemantically)
        {
            await FindNearAsync(query, mine.Token);
            return;
        }

        ShowResults();
        StatusLabel.Text = "引いています…";
        var paths = _shelf.Select(b => b.Path).ToList();
        var books = 0;

        try
        {
            // 1 冊ずつ受け取っては並べる。列挙は背後で回す。
            await foreach (var book in Enumerate(paths, query, mine.Token))
            {
                if (mine.IsCancellationRequested)
                {
                    return;
                }
                books++;
                foreach (var hit in book.Hits)
                {
                    Hits.Items.Add(new ShelfHit(book.Path, book.Title, hit));
                }
                StatusLabel.Text = $"{books} 冊で {Hits.Items.Count} 件";
            }
            StatusLabel.Text = Hits.Items.Count == 0
                ? $"「{query}」は見つかりませんでした"
                : $"{books} 冊で {Hits.Items.Count} 件";
        }
        catch (OperationCanceledException)
        {
            // 新しい問い合わせに譲った。何も言わない。
        }
    }

    /// <summary>
    /// 意味で引く。
    ///
    /// <para>
    /// <b>件数を出さない。</b>「17 件」と言えるのは正確な検索だけである
    /// （spec-local-ai.md 5.2）。出すのは近さと、原書から切り出した本文断片。
    /// </para>
    /// <para>
    /// 索引の無い書籍は黙って飛ばされるので、<b>1 冊も無いときはそう言う</b>。
    /// 「見つからなかった」と出すと、まだ作っていないだけなのに
    /// 「この蔵書には無い」と読める。
    /// </para>
    /// </summary>
    private async Task FindNearAsync(string query, CancellationToken cancel)
    {
        if (!_builder.Enabled)
        {
            ShowResults();
            StatusLabel.Text = "意味の層が切れています。上の「意味の層」を入にしてください";
            return;
        }

        ShowResults();
        StatusLabel.Text = "引いています…";
        var books = _shelf.Select(book => (book.Path, book.Title)).ToList();

        IReadOnlyList<SemanticHit> found;
        try
        {
            // 問いを埋め込むのも索引を読むのも背後で行う。どちらも画面で回すと固まる。
            found = await Task.Run(() =>
            {
                var vector = _builder.Ask(query);
                return new SemanticSearch(_semantic, App.ModelName).Run(vector, books, cancel: cancel);
            }, cancel);
        }
        catch (OperationCanceledException)
        {
            return;   // 新しい問い合わせに譲った。
        }
        catch (Exception error)
        {
            StatusLabel.Text = $"引けませんでした — {error.Message}";
            return;
        }
        if (cancel.IsCancellationRequested)
        {
            return;
        }

        foreach (var one in found)
        {
            Near.Items.Add(new NearRow(one));
        }

        var counts = _builder.Count(books.Select(book => book.Path));
        StatusLabel.Text = found.Count > 0
            ? $"似た内容（近い順）"
            : counts.NotBuilt >= _shelf.Count
                ? "まだ意味の索引がありません。作り終えるまで引けません"
                : $"近いところは見つかりませんでした（索引がまだ {counts.NotBuilt} 冊）";
    }

    private void OnKindChanged(object sender, RoutedEventArgs e)
    {
        if (IsLoaded)
        {
            // 引き方を変えたら引き直す。前の面が残ると、どちらの結果か分からない。
            _ = FindAsync(Query.Text);
        }
    }

    private void OnOpenNear(object sender, MouseButtonEventArgs e)
    {
        if (Near.SelectedItem is NearRow row)
        {
            Open(row.Hit.BookPath);
        }
    }

    private async IAsyncEnumerable<BookHits> Enumerate(
        IReadOnlyList<string> paths, string query,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancel = default)
    {
        foreach (var path in paths)
        {
            cancel.ThrowIfCancellationRequested();
            var found = await Task.Run(() => _search.Of(path, query), cancel);
            if (found is not null)
            {
                yield return found;
            }
        }
    }

    // MARK: 操作

    private async void OnQueryKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            await FindAsync(Query.Text);
        }
    }

    /// <summary>同梱の見本を並べる。書籍を 1 冊も持たないマシンでも読み方を確かめられる。</summary>
    internal void AddSamples() => Add([.. Samples.CopyOut()]);

    private void OnAddSamples(object sender, RoutedEventArgs e) => AddSamples();

    private void OnAdd(object sender, RoutedEventArgs e)
    {
        var picker = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "書籍 (*.epub;*.pdf)|*.epub;*.pdf",
            Multiselect = true,
        };
        if (picker.ShowDialog(this) == true)
        {
            Add(picker.FileNames);
        }
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] dropped)
        {
            Add(dropped);
        }
    }

    private void OnOpenBook(object sender, MouseButtonEventArgs e)
    {
        var chosen = ShowingTable ? Table.SelectedItem : Covers.SelectedItem;
        if (chosen is ShelfBook book)
        {
            Open(book.Path);
        }
    }

    private void OnOpenHit(object sender, MouseButtonEventArgs e)
    {
        if (Hits.SelectedItem is ShelfHit hit)
        {
            Open(hit.Path);
        }
    }

    /// <summary>
    /// 書籍を開く。
    ///
    /// <para>
    /// <b>いったん催しの列へ戻してから開く。</b>WebView2 は自分の呼び返しの最中に
    /// 次の WebView を作らせず、枠だけ出来て中身が空になる（windows/README.md の規則）。
    /// ここは押した出来事の中なので、そのまま作ると踏む。
    /// </para>
    /// </summary>
    private void Open(string path) =>
        Dispatcher.BeginInvoke(new Action(async () =>
        {
            try
            {
                await ((App)Application.Current).OpenBookAsync(path);
            }
            catch (Exception error)
            {
                StatusLabel.Text = $"開けませんでした: {error.Message}";
            }
        }));
}
