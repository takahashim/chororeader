using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ChoroReader.App;

/// <summary>
/// 窓の中を、目で見ずに確かめる。
///
/// <para>
/// 開発機は macOS で、実行できるのは Windows だけである。
/// 画面を見られない相手（CI と、コンソールから開発する者）が合否を読めるように、
/// 判定をアプリ自身に持たせる。結果は JSON で標準出力へ書き、終了コードにも出す。
/// </para>
/// <para>
/// <b>窓の数だけを見ていては、枠だけ出来て中身が空の状態を捕まえられない。</b>
/// 本文が名乗るところまで見る（spikes/findings-tauri.md）。
/// </para>
/// <para>
/// <b>落ちたときは、落ちた事実だけでなく理由を出す。</b>
/// 読み込めていないのか、読み込めたが注入が走らないのか、走ったが便りが届かないのかで
/// 直すところが違う。合否のあとに、その切り分けに要るものを並べる。
/// </para>
/// </summary>
internal static class Selftest
{
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(20);

    internal static async Task<int> RunAsync(ReaderWindow window)
    {
        var result = new JsonObject();
        var checks = new JsonArray();
        var passed = true;

        void Check(string what, bool ok, string? detail = null)
        {
            passed &= ok;
            checks.Add(new JsonObject { ["what"] = what, ["ok"] = ok, ["detail"] = detail });
        }

        try
        {
            Check("最初の章が名乗った", await window.WaitForReadyAsync(Deadline));
            Check("本文が空でない", window.ReadyCount > 0, $"ReadyCount={window.ReadyCount}");

            if (window.ReadyCount > 0)
            {
                // 章を送って、名乗り直すこと。枠だけ出来る不具合はここで出る。
                var before = window.ReadyCount;
                await window.MoveAsync(1);
                Check("次の章が名乗った", await window.WaitForReadyAsync(Deadline));
                Check("名乗りが増えた", window.ReadyCount > before, $"{before} → {window.ReadyCount}");

                await window.MoveAsync(-1);
                Check("前の章へ戻れた", await window.WaitForReadyAsync(Deadline));
            }

            result["診断"] = await DiagnoseAsync(window);
        }
        catch (Exception e)
        {
            passed = false;
            result["error"] = e.ToString();
        }

        result["checks"] = checks;
        result["passed"] = passed;

        // 日本語が化けると読めない。標準出力を UTF-8 にしてから書く。
        Console.OutputEncoding = Encoding.UTF8;
        Console.Out.WriteLine(result.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        }));

        return passed ? 0 : 1;
    }

    /// <summary>
    /// どこで止まっているかを聞き出す。
    ///
    /// <list type="bullet">
    /// <item>要求が 1 つも来ていない → 移動そのものが起きていない</item>
    /// <item>要求は来たが本文が空 → 配信か解析で転んでいる</item>
    /// <item>本文はあるが注入が走っていない → CSP かエンジンの設定</item>
    /// <item>注入は走ったが便りが無い → 橋（postMessage）</item>
    /// </list>
    /// </summary>
    private static async Task<JsonObject> DiagnoseAsync(ReaderWindow window) => new()
    {
        ["移動の結末"] = window.LastNavigationStatus,
        ["移動が成った"] = window.LastNavigationSucceeded,
        ["取り消した移動"] = new JsonArray(window.CancelledNavigations.Select(u => (JsonNode?)u).ToArray()),
        ["配った要求"] = new JsonArray(window.RequestedUris.Select(u => (JsonNode?)u).ToArray()),
        ["届いた便り"] = new JsonArray(window.RawMessages.Select(m => (JsonNode?)m).ToArray()),
        ["本文の状態"] = await window.AskAsync("document.readyState"),
        ["本文の丈"] = await window.AskAsync("document.documentElement.outerHTML.length"),
        ["本文の頭"] = await window.AskAsync("document.documentElement.outerHTML.slice(0, 200)"),
        ["注入が走った"] = await window.AskAsync("window.__choroReady === true"),
        ["橋がある"] = await window.AskAsync("!!(window.chrome && window.chrome.webview)"),
        ["便りの失敗"] = await window.AskAsync("window.__choroPostFailed || null"),
    };
}
