using System.IO;
using System.Windows;
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

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnLastWindowClose;

        var selftest = e.Args.Contains("--selftest");
        var book = e.Args.FirstOrDefault(a => !a.StartsWith("--", StringComparison.Ordinal));

        try
        {
            Directory.CreateDirectory(UserDataFolder);
            _environment = await CoreWebView2Environment.CreateAsync(userDataFolder: UserDataFolder);

            if (book is null)
            {
                // 開くものが無い。書棚を作るまでは、ここで終える。
                await Console.Error.WriteLineAsync("使い方: chororeader <EPUB のパス> [--selftest]");
                Shutdown(2);
                return;
            }

            var window = await OpenAsync(book);

            if (selftest)
            {
                Shutdown(await Selftest.RunAsync(window));
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
    internal async Task<ReaderWindow> OpenAsync(string bookPath)
    {
        var environment = _environment ?? throw new InvalidOperationException("環境がまだ用意できていない");
        var window = new ReaderWindow(BookSession.Open(bookPath), environment);
        window.Show();
        await window.StartAsync();
        return window;
    }
}
