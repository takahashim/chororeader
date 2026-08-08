using System.IO;
using System.Windows;
using ChoroReader.Core;
using ChoroReader.Semantic;
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

    /// <summary>
    /// 意味の索引の置き場所と、それを作る係。全窓で 1 つを共有する。
    ///
    /// <para>
    /// <b>埋め込み器は要るときに 1 度だけ開く。</b>250 MB を読むので、
    /// 窓ごとに持つわけにいかない。意味の層を切ったときに降ろす（spec-local-ai.md 4.5）。
    /// </para>
    /// </summary>
    private readonly SemanticIndexStore _semantic = SemanticIndexStore.Default();

    private SemanticIndexBuilder? _builder;

    /// <summary>
    /// モデルの置き場所。<b>アプリは出どころを知らない。</b>決まった場所を見るだけにしておく
    /// （spec-local-ai.md 4.6）。配り方が決まったら、そこへ書く手順が足されるだけである。
    /// </summary>
    internal static string ModelDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChoroReader", "Models", ModelName);

    internal const string ModelName = "ruri-v3-130m-onnx";

    /// <summary>意味の索引を作る係。無ければ作る。</summary>
    internal SemanticIndexBuilder Builder => _builder ??= NewBuilder();

    private SemanticIndexBuilder NewBuilder()
    {
        var settings = _reading.Semantic;
        var made = new SemanticIndexBuilder(_semantic,
                                            () => OnnxEmbedder.Load(ModelDirectory),
                                            ModelName)
        {
            OnPowerOnly = settings.OnPowerOnly,
            // **モデルが無ければ入にしない。** 入れたつもりで走り出して、
            // 1 冊目で落ちるより、初めから切れている方が分かりやすい。
            Enabled = settings.Enabled && Directory.Exists(ModelDirectory),
        };
        return made;
    }

    /// <summary>意味の層の入/切を覚える。</summary>
    internal void SaveSemantic(bool enabled)
    {
        _reading.SaveSemantic(_reading.Semantic with { Enabled = enabled });
        Builder.Enabled = enabled;
    }

    /// <summary>手元にモデルが置いてあるか。無ければ意味の層は使えない。</summary>
    internal static bool HasModel => Directory.Exists(ModelDirectory)
                                     && File.Exists(Path.Combine(ModelDirectory, "tokenizer.json"));

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnLastWindowClose;

        var selftest = e.Args.Contains("--selftest");
        var shelf = e.Args.Contains("--shelf");
        var books = e.Args.Where(a => !a.StartsWith("--", StringComparison.Ordinal)).ToArray();

        // 速さを測るだけ。**窓を開かない。**画面を出すと、その支度まで測ることになる。
        if (e.Args.Contains("--measure"))
        {
            Shutdown(books.Length > 0 ? Measure.Run(books[0]) : 2);
            return;
        }

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

        // **開いた本を先に作る。** 読んでいる本の関連箇所が出ないのが、いちばん困る。
        Builder.Prioritize(bookPath);

        var window = new ReaderWindow(stage, _reading, bookPath);
        window.Show();
        await window.StartAsync();
        return window;
    }

    /// <summary>書棚を開く。WebView2 は使わないので、環境は要らない。</summary>
    internal ShelfWindow OpenShelf(params string[] books)
    {
        var window = new ShelfWindow(_store, _reading, Builder, _semantic);
        window.Show();
        window.Add(books);
        return window;
    }
}
