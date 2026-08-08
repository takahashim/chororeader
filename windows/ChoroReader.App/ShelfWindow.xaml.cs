using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using ChoroReader.Core;

namespace ChoroReader.App;

/// <summary>書棚に並ぶ 1 冊。押すと開く。</summary>
internal sealed record ShelfBook(string Path, string Title)
{
    public override string ToString() => Title;
}

/// <summary>横断検索の当たり 1 件。押すとその場所へ飛ぶ。</summary>
internal sealed record ShelfHit(string Path, string Title, LibraryHit Hit)
{
    public override string ToString() => $"{Title} — {Hit.Where}: {Hit.Excerpt}";
}

/// <summary>
/// 書棚の窓。すべてネイティブで、WebView は使わない。
///
/// <para>
/// 蔵書を並べ、横断して引く（spec.md 10.4）。
/// 引くのは <see cref="LibrarySearch"/> に任せ、ここは並べるだけにする。
/// </para>
/// </summary>
public partial class ShelfWindow : Window
{
    private readonly LibrarySearch _search;
    private readonly List<ShelfBook> _shelf = [];
    private CancellationTokenSource? _running;

    /// <summary>いま並んでいる当たり。動作確認が見る。</summary>
    internal int HitCount => Hits.Items.Count;

    internal int BookCount => _shelf.Count;

    internal ShelfWindow(SearchIndexStore store)
    {
        InitializeComponent();
        _search = new LibrarySearch(store);
        Closed += (_, _) => _running?.Cancel();
    }

    internal void Add(params string[] paths)
    {
        foreach (var path in paths)
        {
            if (_shelf.Any(b => string.Equals(b.Path, path, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }
            _shelf.Add(new ShelfBook(path, System.IO.Path.GetFileNameWithoutExtension(path)));
        }
        Books.ItemsSource = null;
        Books.ItemsSource = _shelf;
        StatusLabel.Text = $"{_shelf.Count} 冊";
    }

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
        query = query.Trim();
        if (query.Length == 0)
        {
            StatusLabel.Text = $"{_shelf.Count} 冊";
            return;
        }

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

    private void OnOpenSelected(object sender, MouseButtonEventArgs e)
    {
        if (Books.SelectedItem is ShelfBook book)
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
