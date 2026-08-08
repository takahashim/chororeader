using System.IO;
using System.Windows;
using ChoroReader.Core;
using Microsoft.Web.WebView2.Core;

namespace ChoroReader.App;

public partial class App : Application
{
    /// <summary>WebView2 の作業フォルダ。書籍そのものの隣には置かない。</summary>
    private static string UserDataFolder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChoroReader", "webview");

    /// <summary>
    /// 全窓で 1 つを共有する。
    /// 同じ作業フォルダに複数の環境を作ると衝突する（spikes/findings-windows.md）。
    /// </summary>
    private CoreWebView2Environment? _environment;

    /// <summary>
    /// 索引の置き場所。全窓で 1 つを共有する。
    /// 別々に持つと、同じ書籍の索引を窓の数だけほどくことになる。
    /// </summary>
    private readonly SearchIndexStore _store = SearchIndexStore.Default();

    /// <summary>
    /// 読書位置・しおり・表示設定の覚え書き。全窓で 1 つを共有する。
    /// 別々に持つと、後から閉じた窓が古い中身で上書きする。
    /// </summary>
    private readonly ReadingStore _reading = ReadingStore.Default();

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnLastWindowClose;

        var selftest = e.Args.Contains("--selftest");
        var shelf = e.Args.Contains("--shelf");
        var books = e.Args.Where(a => !a.StartsWith("--", StringComparison.Ordinal)).ToArray();

        try
        {
            Directory.CreateDirectory(UserDataFolder);
            _environment = await CoreWebView2Environment.CreateAsync(userDataFolder: UserDataFolder);

            // 書棚。渡された書籍を並べて、横断して引ける。
            if (shelf || books.Length == 0)
            {
                var window = OpenShelf(books);
                // 何も渡されなければ見本を並べる。空の書棚を見せても、できることが分からない。
                if (books.Length == 0)
                {
                    window.AddSamples();
                }
                if (selftest)
                {
                    Shutdown(await Selftest.RunShelfAsync(window));
                }
                return;
            }

            var opened = await OpenBookAsync(books[0]);
            if (selftest)
            {
                Shutdown(await Selftest.RunAsync(opened));
            }
        }
        catch (Exception error)
        {
            await Console.Error.WriteLineAsync(error.ToString());
            Shutdown(1);
        }
    }

    /// <summary>
    /// 窓を開く。
    ///
    /// <para>
    /// <b>WebView の呼び返しの最中に、次の窓や WebView を同期に作らない。</b>
    /// WebView2 は自分の呼び返しの最中に次の WebView を作らせず、枠だけ出来て中身が空になる。
    /// 呼ぶ側はいったん催しの列へ戻してから呼ぶこと
    /// （spikes/findings-tauri.md「同期の命令の中で窓を作ると、枠だけ出来て中身が空になる」）。
    /// </para>
    /// </summary>
    internal async Task<ReaderWindow> OpenBookAsync(string bookPath)
    {
        // **窓は形式で分けない。**差し替わるのは舞台だけである
        // （windows/README.md「画面の組み立て」）。
        IStage stage;
        if (DocumentFormats.Detect(bookPath) == DocumentFormat.Pdf)
        {
            stage = new PdfStage(PdfSession.Open(bookPath), _store, bookPath);
        }
        else
        {
            var environment = _environment ?? throw new InvalidOperationException("環境がまだ用意できていない");
            stage = new WebStage(BookSession.Open(bookPath), environment);
        }

        var window = new ReaderWindow(stage, _reading, bookPath);
        window.Show();
        await window.StartAsync();
        return window;
    }

    /// <summary>書棚を開く。WebView2 は使わないので、環境は要らない。</summary>
    internal ShelfWindow OpenShelf(params string[] books)
    {
        var window = new ShelfWindow(_store, _reading);
        window.Show();
        window.Add(books);
        return window;
    }
}
