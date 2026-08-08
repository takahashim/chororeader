using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ChoroReader.Core;

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

    /// <summary>
    /// 読書の窓を確かめる。
    ///
    /// <para>
    /// <b>殻は形式に依らず 1 度だけ見る。</b>窓を形式で分けていたころは
    /// 目次も検索もしおりも形式ごとに確かめていて、片方だけ直る事故が起きやすかった。
    /// 舞台ごとの中身（本文が名乗るか、紙面が描けたか）だけを分ける。
    /// </para>
    /// </summary>
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
            // 舞台。形式ごとに中身が出ているところまで見る。
            var ready = window.Web is { } web
                ? await CheckWebAsync(web, Check)
                : await CheckPdfAsync(window.Paper!, Check);

            if (ready)
            {
                await CheckShellAsync(window, Check);
            }

            result["診断"] = window.Web is { } w ? await DiagnoseAsync(w) : DiagnosePdf(window.Paper!);
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
    /// 本文の舞台。名乗るところと、位置の便りが届くところまで見る。
    /// </summary>
    private static async Task<bool> CheckWebAsync(WebStage web, Action<string, bool, string?> check)
    {
        check("最初の章が名乗った", await web.WaitForReadyAsync(Deadline), null);
        check("本文が空でない", web.ReadyCount > 0, $"ReadyCount={web.ReadyCount}");
        if (web.ReadyCount == 0)
        {
            return false;
        }

        // 章を送って、名乗り直すこと。枠だけ出来る不具合はここで出る。
        var before = web.ReadyCount;
        await web.MoveAsync(1);
        check("次の章が名乗った", await web.WaitForReadyAsync(Deadline), null);
        check("名乗りが増えた", web.ReadyCount > before, $"{before} → {web.ReadyCount}");

        await web.MoveAsync(-1);
        check("前の章へ戻れた", await web.WaitForReadyAsync(Deadline), null);

        // 章の中のどこかは、間引かれた便りが届いてから。
        // 待たずに次へ進むと毎回捨てられるので、ここで待つ。
        check("位置の便りが届いた", await web.WaitForPositionAsync(Deadline),
              $"PositionCount={web.PositionCount}");
        return true;
    }

    /// <summary>
    /// 紙面の舞台。名乗る相手がいないので、<b>出ている絵そのものを見る</b>。
    /// 枠だけ出来て中身が空でも窓は開くので、絵が付いていること、
    /// 寸法が紙面と辻褄が合うこと、ページを送ると描き直すことまで見る。
    /// </summary>
    private static async Task<bool> CheckPdfAsync(PdfStage paper, Action<string, bool, string?> check)
    {
        check("紙面が描けた", paper.Drawn is not null, $"DrawnCount={paper.DrawnCount}");
        var first = paper.Drawn;
        check("絵に大きさがある", first is { PixelWidth: > 0, PixelHeight: > 0 },
              first is null ? null : $"{first.PixelWidth}x{first.PixelHeight}");
        if (first is null)
        {
            return false;
        }

        // ページを送って、描き直すこと。枠だけ出来る不具合はここで出る。
        var before = paper.DrawnCount;
        await paper.MoveAsync(1);
        check("次のページへ進めた", paper.Page == 1, $"Page={paper.Page}");
        check("描き直した", paper.DrawnCount > before, $"{before} → {paper.DrawnCount}");

        await paper.MoveAsync(-1);
        check("前のページへ戻れた", paper.Page == 0, $"Page={paper.Page}");

        // 倍率を上げたら絵も大きくなること。
        var small = paper.Drawn!.PixelWidth;
        await paper.ZoomAsync(2.0);
        check("拡げたら絵も大きくなった", paper.Drawn!.PixelWidth > small,
              $"{small} → {paper.Drawn!.PixelWidth}（{paper.Zoom:F2} 倍）");
        await paper.ZoomAsync(0.5);
        return true;
    }

    /// <summary>
    /// 殻。形式に依らず同じ場所にあるもの。
    ///
    /// <para>
    /// 引く語は舞台に合わせる。本文には「本文」があり、見本の PDF には "page" がある。
    /// </para>
    /// </summary>
    private static async Task CheckShellAsync(ReaderWindow window, Action<string, bool, string?> check)
    {
        var stage = window.Stage;
        var query = window.Web is null ? "page" : "本文";

        // 読んだところを覚えていること。
        //
        // **紙面は 1 枚送ってから見る。**最初のページに居たままだと、
        // 覚え書きが 0 でも「合っている」ことになり、何も確かめていない。
        if (window.Paper is { } paper)
        {
            await paper.MoveAsync(1);
        }
        var remembered = window.Remembered;
        check("読んだところを覚えた",
              window.Web is not null
                  ? remembered.Href.Length > 0
                  : remembered.Page == window.Paper!.Page && remembered.Page > 0,
              $"Href={remembered.Href} Page={remembered.Page}");

        check("目次かページが並んだ", stage.Toc.Count > 0 || stage.Pages.Count > 0,
              $"Toc={stage.Toc.Count} Pages={stage.Pages.Count}");

        // 引いて、当たりへ飛ぶこと。
        await window.FindAsync(query);
        check("窓の中で当たりが出た", window.HitCount > 0, $"Hits={window.HitCount}");

        await window.FindAsync("そんな語はどこにも出てこない");
        check("当たらない語では空になる", window.HitCount == 0, $"Hits={window.HitCount}");

        await window.FindAsync(query);
        if (window.FirstHit is { } hit)
        {
            await window.GoAsync(hit);
            if (window.Web is { } web)
            {
                // 飛んだ先で当たりを囲むこと。印は配信の瞬間に本文へ入る。
                var marked = await web.AskAsync($"!!document.querySelector('.{Mark.ClassName}')");
                check("飛んだ先で当たりを囲んだ", marked.Trim() == "true",
                      $"{hit.Href}#{hit.Nth} → {marked.Trim()}");
            }
            else
            {
                check("飛んだ先で当たりを囲んだ", window.Paper!.MarkCount > 0,
                      $"p.{hit.Page + 1} Marks={window.Paper!.MarkCount}");
            }
        }

        // 履歴。**当たり任せにしない。**当たりが今いる章に出ると、飛んでも場所が変わらず、
        // 戻れないのが正しい状態になってしまう。離れた 2 か所を明示的に辿る。
        var places = stage.Toc.Count >= 2 ? stage.Toc : stage.Pages;
        if (places.Count >= 2)
        {
            await window.GoAsync(places[0]);
            await window.GoAsync(places[^1]);
            check("飛んだあと戻れる", window.CanGoBack, $"Places={places.Count}");

            await window.GoBackAsync();
            check("戻ったら進める", window.CanGoForward, null);
        }

        // しおり。付けて外せること。
        window.ToggleBookmark();
        check("しおりを付けられた", window.BookmarkCount > 0, $"Bookmarks={window.BookmarkCount}");
        window.ToggleBookmark();
        check("しおりを外せた", window.BookmarkCount == 0, $"Bookmarks={window.BookmarkCount}");

        // 表示設定。効く書籍でだけ本文に当たること。
        await window.ApplyStyleAsync(new ReaderStyle { Theme = ReaderTheme.Dark });
        if (window.Web is { } styled)
        {
            var applied = await styled.AskAsync(
                "(document.getElementById('choro-style') || {}).textContent ? " +
                "document.getElementById('choro-style').textContent.indexOf('#1c1c1e') >= 0 : false");
            check("表示設定が本文に当たった", applied.Trim() == "true", applied.Trim());
        }
        else
        {
            check("紙面では組み直しを出さない", !stage.Reflowable, null);
        }
    }

    /// <summary>
    /// 書棚を確かめる。並べられるか、横断して引けるか、表紙が出るか。
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
            // 埋め込みは黙って外れる。実行ファイルから取り出せるところまで見る。
            var samples = Samples.CopyOut();
            Check("見本を取り出せた", samples.Count == Samples.Names.Length,
                  $"{samples.Count} / {Samples.Names.Length}");
            Check("取り出した見本が読める", samples.All(File.Exists) && samples.All(p => new FileInfo(p).Length > 0));

            Check("蔵書が並んだ", window.BookCount > 0, $"BookCount={window.BookCount}");

            // 表紙。取れなかった書籍は題名だけで並ぶので、落とさずに数だけ見る。
            await window.LoadCoversAsync();
            Check("表紙が出た", window.CoverCount > 0, $"Covers={window.CoverCount} / {window.BookCount}");

            await window.FindAsync("本文");
            Check("横断で当たりが出た", window.HitCount > 0, $"Hits={window.HitCount}");
            Check("引いたら結果の面に変わった", window.ShowingResults, null);

            // 当たらない語では空になること。前の結果が残らない。
            await window.FindAsync("そんな語はどこにも出てこない");
            Check("当たらない語では空になる", window.HitCount == 0, $"Hits={window.HitCount}");

            // 空の問い合わせでも落ちず、蔵書の面へ戻ること。
            await window.FindAsync("   ");
            Check("空の問い合わせでも落ちない", window.HitCount == 0);
            Check("空にしたら蔵書へ戻る", !window.ShowingResults, null);

            // 表紙と一覧を行き来できること。
            window.ShowTable();
            Check("一覧へ切り替えられた", window.ShowingTable, null);
            window.ShowCovers();
            Check("表紙へ戻せた", !window.ShowingTable, null);

            result["診断"] = new JsonObject
            {
                ["蔵書"] = window.BookCount,
                ["表紙"] = window.CoverCount,
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
    private static async Task<JsonObject> DiagnoseAsync(WebStage web) => new()
    {
        ["移動の結末"] = web.LastNavigationStatus,
        ["移動が成った"] = web.LastNavigationSucceeded,
        ["取り消した移動"] = new JsonArray(web.CancelledNavigations.Select(u => (JsonNode?)u).ToArray()),
        ["配った要求"] = new JsonArray(web.RequestedUris.Select(u => (JsonNode?)u).ToArray()),
        ["届いた便り"] = new JsonArray(web.RawMessages.Select(m => (JsonNode?)m).ToArray()),
        ["本文の状態"] = await web.AskAsync("document.readyState"),
        ["本文の丈"] = await web.AskAsync("document.documentElement.outerHTML.length"),
        ["本文の頭"] = await web.AskAsync("document.documentElement.outerHTML.slice(0, 200)"),
        // 入口が始まったことと、名乗るところまで来たことを分けて聞く。
        // 一緒にすると、リスナが死んでいても「注入は走った」と読めてしまう。
        ["入口が始まった"] = await web.AskAsync("window.__choroReady === true"),
        ["名乗るまで来た"] = await web.AskAsync("window.__choroNamed === true"),
        ["橋がある"] = await web.AskAsync("!!(window.chrome && window.chrome.webview)"),
        ["便りの失敗"] = await web.AskAsync("window.__choroPostFailed || null"),
    };

    private static JsonObject DiagnosePdf(PdfStage paper) => new()
    {
        ["ページ"] = paper.Page,
        ["倍率"] = paper.Zoom,
        ["描けた回数"] = paper.DrawnCount,
        ["絵の大きさ"] = paper.Drawn is { } sheet ? $"{sheet.PixelWidth}x{sheet.PixelHeight}" : null,
        ["当たり"] = new JsonArray(
            paper.Hits.Take(5)
                .Select(h => (JsonNode?)$"p.{h.Page + 1} 矩形 {h.Rects.Count} 個: {h.Excerpt}")
                .ToArray()),
    };
}
