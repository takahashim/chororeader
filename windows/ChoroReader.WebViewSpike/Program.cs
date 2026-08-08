using System.Text;
using System.Text.Json.Nodes;
using ChoroReader.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace ChoroReader.WebViewSpike;

/// <summary>
/// WebView2 が、macOS 版と同じ前提で使えるかを確かめる。
///
/// macOS では WKWebView で次が成り立つことをスパイクで確認済みである。
///   書籍由来の JavaScript は動かない。アプリが注入したスクリプトとメッセージだけが動く。
/// これが WebView2 でも成り立つかどうかで、EPUB ナビゲータの作りが変わる。
/// スクロール位置の通知、コードのコピーボタン、位置復元がこの前提に乗っているため。
///
/// 画面は出さない。結果を JSON で標準出力へ書き、前提が成り立てば終了コード 0 を返す。
/// どこで転んだか分かるよう、通過した段階を steps に積む。
/// </summary>
internal static class Program
{
    /// <summary>書籍に見立てた文書。自前の script が動くかどうかを見分けられるようにしてある。</summary>
    private const string BookHtml = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>original</title></head>
        <body>
        <p id="p">untouched</p>
        <div style="height: 3000px"></div>
        <script>
          document.title = "CONTENT-JS-RAN";
          document.getElementById('p').textContent = "CONTENT-JS-RAN";
        </script>
        </body></html>
        """;

    /// <summary>
    /// アプリが注入するスクリプト。macOS 版の注入スクリプトと同じ役割。
    ///
    /// <para>
    /// <b>同期の便りと、リスナ越しの便りを別々に出す。</b>
    /// 読書の窓が要るのは後者（スクロール・鍵盤・DOMContentLoaded）だが、
    /// 前者だけを見ていると「注入は動く」と早合点する。実際それで見落とした。
    /// </para>
    /// </summary>
    private const string InjectedScript = """
        window.__choroInjected = true;
        function choroPost(m) {
          try {
            window.chrome.webview.postMessage(JSON.stringify(m));
          } catch (e) {
            window.__choroPostFailed = String(e);
          }
        }
        choroPost({ kind: 'hello', title: document.title });
        document.addEventListener('DOMContentLoaded', function () {
          window.__choroListenerFired = true;
          choroPost({ kind: 'listener' });
        });
        // 読書が実際に頼るのはこれ。位置の追従はスクロールの出来事に乗っている。
        window.addEventListener('scroll', function () {
          window.__choroScrolled = true;
          choroPost({ kind: 'scroll', y: window.scrollY });
        });
        """;

    private const string SchemeName = "choro";

    private static readonly JsonArray Steps = [];

    /// <summary>判定が終わらないまま CI を占有しないための上限。</summary>
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(120);

    [STAThread]
    private static int Main()
    {
        var result = new JsonObject();
        var exitCode = 1;

        // WebView2 の初期化はメッセージポンプが回っていないと完了しない。
        // 待ち合わせを主スレッドでブロックすると自分で止めてしまうため、
        // Application.Run でポンプを回しながら非同期に進める。
        using var form = new Form { Width = 400, Height = 300, ShowInTaskbar = false };

        form.Shown += async (_, _) =>
        {
            try
            {
                exitCode = await RunAsync(result, form);
            }
            catch (Exception e)
            {
                result["error"] = e.ToString();
            }
            finally
            {
                form.Close();
            }
        };

        using var watchdog = new System.Windows.Forms.Timer { Interval = (int)Deadline.TotalMilliseconds };
        watchdog.Tick += (_, _) =>
        {
            watchdog.Stop();
            result["error"] = $"{Deadline.TotalSeconds} 秒以内に判定が終わらなかった";
            form.Close();
        };
        watchdog.Start();

        Application.Run(form);

        result["steps"] = Steps;
        Console.Out.Write(result.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
        Console.Out.Write('\n');
        return exitCode;
    }

    private static void Step(string name) => Steps.Add(name);

    private static async Task<int> RunAsync(JsonObject result, Form form)
    {
        var userDataFolder = Path.Combine(Path.GetTempPath(), "choro-webview-spike");
        Directory.CreateDirectory(userDataFolder);
        Step("作業フォルダを用意した");

        // 書籍内リソースを配るための独自スキーム。WKURLSchemeHandler に当たるもの。
        // 登録に失敗しても、肝心の JavaScript の問いには答えられるよう別扱いにする。
        var (environment, customSchemeRegistered) = await CreateEnvironment(userDataFolder, result);
        result["customSchemeRegistered"] = customSchemeRegistered;
        result["webView2Version"] = environment.BrowserVersionString;
        Step($"環境を作った（独自スキーム: {(customSchemeRegistered ? "登録できた" : "登録できない")}）");

        // 独自スキームが使えないときは、実在しないホスト名を横取りして同じことを試す。
        var bookUrl = customSchemeRegistered
            ? $"{SchemeName}://book/chapter.xhtml"
            : "https://choro.invalid/chapter.xhtml";
        var filter = customSchemeRegistered ? $"{SchemeName}://*" : "https://choro.invalid/*";

        var webView = new WebView2 { Dock = DockStyle.Fill };
        form.Controls.Add(webView);
        Step("WebView2 を配置した");

        await webView.EnsureCoreWebView2Async(environment);
        var core = webView.CoreWebView2;
        Step("WebView2 を初期化した");

        // 書籍側の JavaScript を止める。ここが macOS 版の allowsContentJavaScript = false に当たる。
        core.Settings.IsScriptEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsWebMessageEnabled = true;

        var messages = new List<string>();
        core.WebMessageReceived += (_, e) =>
        {
            try
            {
                messages.Add(e.TryGetWebMessageAsString() ?? e.WebMessageAsJson);
            }
            catch (Exception)
            {
                messages.Add(e.WebMessageAsJson);
            }
        };

        // 要求を横取りして、メモリ上の文書を返す。
        // 2 周目は本番と同じ CSP を添える。どちらで転んだかを見分けられるよう、別々に測る。
        var attachCsp = false;
        core.AddWebResourceRequestedFilter(filter, CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (_, e) =>
        {
            var bytes = Encoding.UTF8.GetBytes(BookHtml);
            var headers = "Content-Type: text/html; charset=utf-8";
            if (attachCsp)
            {
                headers += $"\nContent-Security-Policy: {ResourceDelivery.ContentSecurityPolicy}";
            }
            e.Response = environment.CreateWebResourceResponse(
                new MemoryStream(bytes), 200, "OK", headers);
        };

        await core.AddScriptToExecuteOnDocumentCreatedAsync(InjectedScript);
        Step("注入スクリプトを登録した");

        TaskCompletionSource<bool>? loaded = null;
        core.NavigationCompleted += (_, e) =>
        {
            result["navigationStatus"] = e.WebErrorStatus.ToString();
            loaded?.TrySetResult(e.IsSuccess);
        };

        async Task<bool> Load()
        {
            loaded = new TaskCompletionSource<bool>();
            core.Navigate(bookUrl);
            var ok = await WithTimeout(loaded.Task, TimeSpan.FromSeconds(30));
            // メッセージは読み込み完了と前後しうる。少し待つ。
            await Task.Delay(500);
            return ok;
        }

        var navigated = await Load();
        result["navigatedTo"] = bookUrl;
        result["navigationSucceeded"] = navigated;
        Step($"読み込みが{(navigated ? "成功した" : "失敗した")}");

        if (!navigated)
        {
            result["conclusion"] = "横取りした文書を読み込めなかった";
            return 1;
        }

        result["contentSecurityPolicy"] = ResourceDelivery.ContentSecurityPolicy;

        /// <summary>1 通りを測る。書籍の script が止まり、注入とリスナと便りが生きているかを見る。</summary>
        async Task<JsonObject> Measure(string label, bool scriptEnabled, bool withCsp)
        {
            core.Settings.IsScriptEnabled = scriptEnabled;
            attachCsp = withCsp;
            messages.Clear();
            var ok = await Load();

            var paragraph = await core.ExecuteScriptAsync("document.getElementById('p').textContent");
            var title = await core.ExecuteScriptAsync("document.title");
            var bookRan = paragraph.Contains("CONTENT-JS-RAN", StringComparison.Ordinal)
                          || title.Contains("CONTENT-JS-RAN", StringComparison.Ordinal);

            // スクロールさせてみる。
            //
            // ExecuteScriptAsync は script を切っていても効く（この API の仕様）。
            // だから合成入力を使わずに、出来事だけを起こせる。
            // ここで発火しなければ、位置の追従はポーリングでしか作れない。
            await core.ExecuteScriptAsync("window.scrollTo(0, 200)");
            await Task.Delay(300);

            var measured = new JsonObject
            {
                ["読み込めた"] = ok,
                ["注入が走った"] =
                    (await core.ExecuteScriptAsync("window.__choroInjected === true")).Trim() == "true",
                ["書籍の script が走った"] = bookRan,
                ["同期の便りが届いた"] = messages.Any(m => m.Contains("hello", StringComparison.Ordinal)),
                // ここが要点。読書の窓が要るのはリスナ越しの便りである。
                ["リスナが発火した"] =
                    (await core.ExecuteScriptAsync("window.__choroListenerFired === true")).Trim() == "true",
                ["リスナの便りが届いた"] = messages.Any(m => m.Contains("listener", StringComparison.Ordinal)),
                ["ExecuteScript が効く"] = paragraph.Contains("untouched", StringComparison.Ordinal),
                // 位置は本当に動いたか。動いていなければ、次の 2 行は測れていない。
                ["実際に動いた位置"] = (await core.ExecuteScriptAsync("window.scrollY")).Trim(),
                ["スクロールのリスナが発火した"] =
                    (await core.ExecuteScriptAsync("window.__choroScrolled === true")).Trim() == "true",
                ["スクロールの便りが届いた"] = messages.Any(m => m.Contains("scroll", StringComparison.Ordinal)),
                ["便りの失敗"] = (await core.ExecuteScriptAsync("window.__choroPostFailed || null")).Trim() is var f
                                 && f != "null" ? f : null,
            };
            Step($"{label} を測った");
            return measured;
        }

        // 書籍の script を止める道は 2 つある。どちらが読書に足りるかをここで決める。
        //
        // エンジンの段（IsScriptEnabled = false）で止めると、**その文書に紐づく script が
        // 走らない**という意味になり、注入したスクリプトが張ったリスナまで発火しなくなる。
        // Tauri 版が sandbox で踏んだのと同じ性質である（spikes/findings-tauri.md）。
        // 注入そのものは走るので、同期の便りだけを見ていると気付けない。
        var engineOff = await Measure("エンジンで止める", scriptEnabled: false, withCsp: true);
        var cspOnly = await Measure("CSP だけで止める", scriptEnabled: true, withCsp: true);

        result["エンジンで止める"] = engineOff;
        result["CSP だけで止める"] = cspOnly;

        // 読書に足りるかどうかは、リスナ越しの便りが届くかで決まる。
        // 位置の追従（スクロール）まで含めて見る。ここが要点である。
        static bool Reads(JsonObject m) =>
            (bool)m["読み込めた"]! && (bool)m["注入が走った"]!
            && !(bool)m["書籍の script が走った"]!
            && (bool)m["同期の便りが届いた"]!
            && (bool)m["リスナの便りが届いた"]!
            && (bool)m["スクロールの便りが届いた"]!;

        var engineWorks = Reads(engineOff);
        var cspWorks = Reads(cspOnly);
        result["読書に足りる設定"] = (engineWorks, cspWorks) switch
        {
            (true, _) => "エンジンで止める",
            (false, true) => "CSP だけで止める",
            _ => null,
        };
        result["conclusion"] = (engineWorks, cspWorks) switch
        {
            (_, true) => "書籍の script は止まり、注入もリスナも便りも生きている。この設定で組める。",
            (true, false) => "エンジンで止める側だけが足りる。CSP だけでは書籍の script が漏れる。",
            _ => "どちらの設定でも読書に足りない。EPUB ナビゲータの作りを見直す必要がある。",
        };

        // 出荷する設定（CSP だけで止める）が成り立つことを、通す条件にする。
        return cspWorks ? 0 : 1;
    }

    /// <summary>
    /// 独自スキームを登録した環境を作る。
    /// この API は版によって扱いが違うため、失敗したら登録なしで作り直す。
    /// </summary>
    private static async Task<(CoreWebView2Environment Environment, bool CustomScheme)> CreateEnvironment(
        string userDataFolder, JsonObject result)
    {
        var options = new CoreWebView2EnvironmentOptions();

        // CustomSchemeRegistrations は読み取り専用で、しかも null を返すことがある。
        // 実際 CI の Windows ランナーで null だった。使えるかどうかもこのスパイクの答えの一部。
        var registrations = options.CustomSchemeRegistrations;
        if (registrations is null)
        {
            result["customSchemeError"] = "CustomSchemeRegistrations が null。この環境では独自スキームを登録できない。";
            return (await CoreWebView2Environment.CreateAsync(null, userDataFolder, options), false);
        }

        try
        {
            registrations.Add(new CoreWebView2CustomSchemeRegistration(SchemeName) { TreatAsSecure = true });
            return (await CoreWebView2Environment.CreateAsync(null, userDataFolder, options), true);
        }
        catch (Exception e)
        {
            result["customSchemeError"] = e.Message;
            // 登録に失敗した環境オプションは使い回さない。
            return (await CoreWebView2Environment.CreateAsync(null, userDataFolder), false);
        }
    }

    private static async Task<bool> WithTimeout(Task<bool> task, TimeSpan timeout)
    {
        var finished = await Task.WhenAny(task, Task.Delay(timeout));
        return finished == task && task.Result;
    }
}
