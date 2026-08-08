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

                // 位置は本文が名乗るたびに届く。覚え書きに残っていること。
                var remembered = window.Remembered;
                Check("読んだ場所を覚えた", remembered.Href.Length > 0, $"Href={remembered.Href}");
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
        Write(result);
        return passed ? 0 : 1;
    }

    /// <summary>
    /// 紙面の窓を確かめる。
    ///
    /// <para>
    /// 本文の窓と違って名乗る相手がいないので、<b>出ている絵そのものを見る</b>。
    /// 枠だけ出来て中身が空でも窓は開くので、絵が付いていること、
    /// 寸法が紙面と辻褄が合うこと、ページを送ると描き直すことまで見る。
    /// </para>
    /// </summary>
    internal static async Task<int> RunPdfAsync(PdfWindow window)
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
            Check("紙面が描けた", window.Drawn is not null, $"DrawnCount={window.DrawnCount}");
            var first = window.Drawn;
            Check("絵に大きさがある", first is { PixelWidth: > 0, PixelHeight: > 0 },
                  first is null ? null : $"{first.PixelWidth}x{first.PixelHeight}");

            // ページを送って、描き直すこと。枠だけ出来る不具合はここで出る。
            var before = window.DrawnCount;
            await window.MoveAsync(1);
            Check("次のページへ進めた", window.Page == 1, $"Page={window.Page}");
            Check("描き直した", window.DrawnCount > before, $"{before} → {window.DrawnCount}");

            await window.MoveAsync(-1);
            Check("前のページへ戻れた", window.Page == 0, $"Page={window.Page}");

            // 倍率を上げたら絵も大きくなること。
            var small = window.Drawn!.PixelWidth;
            await window.ZoomAsync(2.0);
            Check("拡げたら絵も大きくなった", window.Drawn!.PixelWidth > small,
                  $"{small} → {window.Drawn!.PixelWidth}（{window.Zoom:F2} 倍）");
            await window.ZoomAsync(0.5);

            // 当たりを引いて、囲みが乗ること。
            await window.FindAsync("page", null);
            Check("紙面から当たりが出た", window.Hits.Count > 0, $"Hits={window.Hits.Count}");
            Check("当たりに囲みが乗った", window.MarkCount > 0, $"Marks={window.MarkCount}");

            result["診断"] = new JsonObject
            {
                ["ページ数"] = window.Page,
                ["倍率"] = window.Zoom,
                ["描けた回数"] = window.DrawnCount,
                ["絵の大きさ"] = window.Drawn is { } sheet ? $"{sheet.PixelWidth}x{sheet.PixelHeight}" : null,
                ["当たり"] = new JsonArray(
                    window.Hits.Take(5)
                        .Select(h => (JsonNode?)$"p.{h.Page + 1} 矩形 {h.Rects.Count} 個: {h.Excerpt}")
                        .ToArray()),
            };
        }
        catch (Exception e)
        {
            passed = false;
            result["error"] = e.ToString();
        }

        result["checks"] = checks;
        result["passed"] = passed;
        Write(result);
        return passed ? 0 : 1;
    }

    /// <summary>
    /// 書棚を確かめる。並べられるか、横断して引けるか。
    ///
    /// <para>
    /// 引くのは <see cref="ChoroReader.Core.LibrarySearch"/> で、そちらは
    /// ChoroReader.Tests が押さえている。ここで見るのは<b>画面までつながっているか</b>である。
    /// </para>
    /// </summary>
    internal static async Task<int> RunShelfAsync(ShelfWindow window)
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
            Check("蔵書が並んだ", window.BookCount > 0, $"BookCount={window.BookCount}");

            await window.FindAsync("本文");
            Check("横断で当たりが出た", window.HitCount > 0, $"Hits={window.HitCount}");

            // 当たらない語では空になること。前の結果が残らない。
            await window.FindAsync("そんな語はどこにも出てこない");
            Check("当たらない語では空になる", window.HitCount == 0, $"Hits={window.HitCount}");

            // 空の問い合わせでも落ちないこと。
            await window.FindAsync("   ");
            Check("空の問い合わせでも落ちない", window.HitCount == 0);

            result["診断"] = new JsonObject
            {
                ["蔵書"] = window.BookCount,
                ["最後の当たり"] = window.HitCount,
            };
        }
        catch (Exception e)
        {
            passed = false;
            result["error"] = e.ToString();
        }

        result["checks"] = checks;
        result["passed"] = passed;
        Write(result);
        return passed ? 0 : 1;
    }

    private static void Write(JsonObject result)
    {
        // 日本語が化けると読めない。標準出力を UTF-8 にしてから書く。
        Console.OutputEncoding = Encoding.UTF8;
        Console.Out.WriteLine(result.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        }));
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
        // 入口が始まったことと、名乗るところまで来たことを分けて聞く。
        // 一緒にすると、リスナが死んでいても「注入は走った」と読めてしまう。
        ["入口が始まった"] = await window.AskAsync("window.__choroReady === true"),
        ["名乗るまで来た"] = await window.AskAsync("window.__choroNamed === true"),
        ["橋がある"] = await window.AskAsync("!!(window.chrome && window.chrome.webview)"),
        ["便りの失敗"] = await window.AskAsync("window.__choroPostFailed || null"),
    };
}
