using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace TZReader.WebViewSpike;

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
        <script>
          document.title = "CONTENT-JS-RAN";
          document.getElementById('p').textContent = "CONTENT-JS-RAN";
        </script>
        </body></html>
        """;

    /// <summary>アプリが注入するスクリプト。macOS 版の注入スクリプトと同じ役割。</summary>
    private const string InjectedScript = """
        window.__tzrInjected = true;
        try {
          window.chrome.webview.postMessage(JSON.stringify({ kind: 'hello', title: document.title }));
        } catch (e) {
          window.__tzrPostFailed = String(e);
        }
        """;

    private const string SchemeName = "tzreader";

    private static readonly JsonArray Steps = [];

    [STAThread]
    private static int Main()
    {
        var result = new JsonObject();
        var exitCode = 1;

        try
        {
            exitCode = RunAsync(result).GetAwaiter().GetResult();
        }
        catch (Exception e)
        {
            result["error"] = e.ToString();
        }

        result["steps"] = Steps;
        Console.Out.Write(result.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
        Console.Out.Write('\n');
        return exitCode;
    }

    private static void Step(string name) => Steps.Add(name);

    private static async Task<int> RunAsync(JsonObject result)
    {
        var userDataFolder = Path.Combine(Path.GetTempPath(), "tzr-webview-spike");
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
            : "https://tzr.invalid/chapter.xhtml";
        var filter = customSchemeRegistered ? $"{SchemeName}://*" : "https://tzr.invalid/*";

        using var form = new Form { Width = 400, Height = 300, ShowInTaskbar = false };
        using var webView = new WebView2 { Dock = DockStyle.Fill };
        form.Controls.Add(webView);
        form.Show();
        Step("ウィンドウを作った");

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
        core.AddWebResourceRequestedFilter(filter, CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (_, e) =>
        {
            var bytes = Encoding.UTF8.GetBytes(BookHtml);
            e.Response = environment.CreateWebResourceResponse(
                new MemoryStream(bytes), 200, "OK", "Content-Type: text/html; charset=utf-8");
        };

        await core.AddScriptToExecuteOnDocumentCreatedAsync(InjectedScript);
        Step("注入スクリプトを登録した");

        var loaded = new TaskCompletionSource<bool>();
        core.NavigationCompleted += (_, e) =>
        {
            result["navigationStatus"] = e.WebErrorStatus.ToString();
            loaded.TrySetResult(e.IsSuccess);
        };

        core.Navigate(bookUrl);
        var navigated = await WithTimeout(loaded.Task, TimeSpan.FromSeconds(30));
        result["navigatedTo"] = bookUrl;
        result["navigationSucceeded"] = navigated;
        Step($"読み込みが{(navigated ? "成功した" : "失敗した")}");

        if (!navigated)
        {
            result["conclusion"] = "横取りした文書を読み込めなかった";
            return 1;
        }

        // メッセージは読み込み完了と前後しうる。少し待つ。
        await Task.Delay(500);

        var injected = await core.ExecuteScriptAsync("window.__tzrInjected === true");
        var paragraph = await core.ExecuteScriptAsync("document.getElementById('p').textContent");
        var title = await core.ExecuteScriptAsync("document.title");
        var postFailure = await core.ExecuteScriptAsync("window.__tzrPostFailed || null");
        Step("判定用のスクリプトを実行した");

        var injectedRan = injected.Trim() == "true";
        var bookScriptRan = paragraph.Contains("CONTENT-JS-RAN", StringComparison.Ordinal)
                            || title.Contains("CONTENT-JS-RAN", StringComparison.Ordinal);
        var messageArrived = messages.Any(m => m.Contains("hello", StringComparison.Ordinal));
        var executeScriptWorks = paragraph.Contains("untouched", StringComparison.Ordinal);

        result["injectedScriptRan"] = injectedRan;
        result["bookScriptRan"] = bookScriptRan;
        result["webMessageArrived"] = messageArrived;
        result["executeScriptWorks"] = executeScriptWorks;
        result["postMessageFailure"] = postFailure.Trim() == "null" ? null : postFailure;
        result["messages"] = new JsonArray(messages.Select(m => (JsonNode?)m).ToArray());

        // macOS と同じ前提が成り立つ条件。
        var holds = injectedRan && !bookScriptRan && messageArrived && executeScriptWorks;
        result["assumptionHolds"] = holds;
        result["conclusion"] = holds
            ? "macOS 版と同じ前提が成り立つ。注入スクリプトとメッセージで組める。"
            : "前提が崩れる。EPUB ナビゲータの作りを見直す必要がある。";

        form.Close();
        return holds ? 0 : 1;
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
