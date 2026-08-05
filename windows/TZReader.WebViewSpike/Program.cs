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
/// 画面は出さない。結果を JSON で標準出力へ書き、すべて成立すれば終了コード 0 を返す。
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
    private const string BookUrl = "tzreader://book/chapter.xhtml";

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

        Console.Out.Write(result.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
        Console.Out.Write('\n');
        return exitCode;
    }

    private static async Task<int> RunAsync(JsonObject result)
    {
        var userDataFolder = Path.Combine(Path.GetTempPath(), "tzr-webview-spike");
        Directory.CreateDirectory(userDataFolder);

        // 書籍内リソースを配るための独自スキーム。WKURLSchemeHandler に当たるもの。
        var options = new CoreWebView2EnvironmentOptions();
        options.CustomSchemeRegistrations.Add(
            new CoreWebView2CustomSchemeRegistration(SchemeName) { TreatAsSecure = true });

        var environment = await CoreWebView2Environment.CreateAsync(
            browserExecutableFolder: null, userDataFolder: userDataFolder, options: options);
        result["webView2Version"] = environment.BrowserVersionString;

        using var form = new Form { Width = 400, Height = 300, ShowInTaskbar = false };
        using var webView = new WebView2 { Dock = DockStyle.Fill };
        form.Controls.Add(webView);

        var messages = new List<string>();
        var loaded = new TaskCompletionSource<bool>();

        await webView.EnsureCoreWebView2Async(environment);
        var core = webView.CoreWebView2;

        // 書籍側の JavaScript を止める。ここが macOS 版の allowsContentJavaScript = false に当たる。
        core.Settings.IsScriptEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsWebMessageEnabled = true;

        core.WebMessageReceived += (_, e) =>
        {
            try
            {
                messages.Add(e.TryGetWebMessageAsString());
            }
            catch (Exception)
            {
                messages.Add(e.WebMessageAsJson);
            }
        };

        // 独自スキームの要求を横取りして、メモリ上の文書を返す。
        core.AddWebResourceRequestedFilter($"{SchemeName}://*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (_, e) =>
        {
            var bytes = Encoding.UTF8.GetBytes(BookHtml);
            e.Response = environment.CreateWebResourceResponse(
                new MemoryStream(bytes), 200, "OK", "Content-Type: text/html; charset=utf-8");
        };

        await core.AddScriptToExecuteOnDocumentCreatedAsync(InjectedScript);
        core.NavigationCompleted += (_, e) => loaded.TrySetResult(e.IsSuccess);

        form.Show();
        core.Navigate(BookUrl);

        var navigated = await WithTimeout(loaded.Task, TimeSpan.FromSeconds(30));
        result["navigationSucceeded"] = navigated;
        if (!navigated)
        {
            result["conclusion"] = "独自スキームの文書を読み込めなかった";
            return 1;
        }

        // 少し待つ。メッセージは読み込み完了と前後しうる。
        await Task.Delay(500);

        var injected = await core.ExecuteScriptAsync("window.__tzrInjected === true");
        var contentRan = await core.ExecuteScriptAsync("document.getElementById('p').textContent");
        var title = await core.ExecuteScriptAsync("document.title");
        var postFailure = await core.ExecuteScriptAsync("window.__tzrPostFailed || null");

        var injectedRan = injected.Trim() == "true";
        var bookScriptRan = contentRan.Contains("CONTENT-JS-RAN", StringComparison.Ordinal)
                            || title.Contains("CONTENT-JS-RAN", StringComparison.Ordinal);
        var messageArrived = messages.Any(m => m.Contains("hello", StringComparison.Ordinal));
        var executeScriptWorks = contentRan.Trim() != "null" && contentRan.Length > 0;

        result["customSchemeServed"] = true;
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

    private static async Task<bool> WithTimeout(Task<bool> task, TimeSpan timeout)
    {
        var finished = await Task.WhenAny(task, Task.Delay(timeout));
        return finished == task && task.Result;
    }
}
