using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using ChoroReader.Core;
using Microsoft.Web.WebView2.Core;

namespace ChoroReader.App;

/// <summary>
/// 読書の窓。1 窓 1 文書（spec.md 4.1）。
///
/// <para>
/// 殻はネイティブで、本文だけが WebView2 に入る。
/// 書籍の script はエンジンの段で止め、注入したものだけを動かす（spec.md 15.1）。
/// </para>
/// </summary>
public partial class ReaderWindow : Window
{
    private readonly BookSession _session;
    private readonly CoreWebView2Environment _environment;
    private ReaderStyle _style = new();
    private TaskCompletionSource<bool>? _awaitingReady;

    /// <summary>本文が名乗った回数。動作確認が「枠だけ出来ていないか」を見る。</summary>
    internal int ReadyCount { get; private set; }

    internal double Progression { get; private set; }

    /// <summary>
    /// 転んだときに「どこまで進んだか」を言えるようにする覚え書き。
    ///
    /// <para>
    /// 窓の中は目で見られない。名乗らなかったときに、読み込めていないのか、
    /// 読み込めたが注入が走らないのか、走ったが便りが届かないのかを見分けられないと、
    /// 直しようがない（spikes/findings-tauri.md）。
    /// </para>
    /// </summary>
    internal List<string> RequestedUris { get; } = [];

    internal List<string> RawMessages { get; } = [];

    internal string? LastNavigationStatus { get; private set; }

    internal bool? LastNavigationSucceeded { get; private set; }

    internal List<string> CancelledNavigations { get; } = [];

    internal ReaderWindow(BookSession session, CoreWebView2Environment environment)
    {
        InitializeComponent();
        _session = session;
        _environment = environment;
        Closed += (_, _) => _session.Dispose();
    }

    /// <summary>
    /// 本文を出せる状態にして、最初の章を開く。
    ///
    /// <para>
    /// <b>初期化は必ず await する。</b><c>GetAwaiter().GetResult()</c> で待つと、
    /// メッセージポンプを自分で止めて永久に待つ（spikes/findings-windows.md）。
    /// </para>
    /// </summary>
    internal async Task StartAsync()
    {
        await Body.EnsureCoreWebView2Async(_environment);
        var core = Body.CoreWebView2;

        // 書籍側の JavaScript は CSP（script-src 'none'）で止める。ResourceDelivery が付ける。
        //
        // **エンジンの段（IsScriptEnabled = false）では止めない。**
        // あれは「その文書に紐づく script を走らせない」という意味で、
        // 注入したスクリプトが張ったリスナまで発火しなくなる。
        // 注入そのものは走るので、同期の便りだけを見ていると気付けない。
        // Tauri 版が sandbox で踏んだのと同じ性質である（spikes/findings-tauri.md）。
        // 読書はリスナ（スクロール・鍵盤・DOMContentLoaded）の上に成り立っているので、
        // ここを切ると本文の中で何も動かなくなる。
        core.Settings.IsScriptEnabled = true;
        core.Settings.IsWebMessageEnabled = true;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.Settings.IsGeneralAutofillEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;

        core.AddWebResourceRequestedFilter($"{ResourceDelivery.Origin}/*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += OnResourceRequested;
        core.WebMessageReceived += OnWebMessage;
        core.NavigationStarting += OnNavigationStarting;
        core.NewWindowRequested += OnNewWindowRequested;
        core.NavigationCompleted += (_, e) =>
        {
            LastNavigationSucceeded = e.IsSuccess;
            LastNavigationStatus = e.WebErrorStatus.ToString();
        };

        await core.AddScriptToExecuteOnDocumentCreatedAsync(ReaderScripts.Main);

        await ShowAsync(_session.Index);
    }

    // MARK: 配信

    /// <summary>
    /// 供給できるものだけを返す。範囲の外は 404 にする。
    /// 何を配るかは <see cref="ResourceDelivery"/> が決める。ここは配線だけ。
    /// </summary>
    private void OnResourceRequested(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        var made = _session.Delivery.Deliver(e.Request.Uri);
        if (RequestedUris.Count < 50)
        {
            RequestedUris.Add($"{(made is null ? 404 : 200)} {e.Request.Uri}");
        }
        if (made is null)
        {
            e.Response = _environment.CreateWebResourceResponse(null, 404, "Not Found", string.Empty);
            return;
        }

        // CSP は配るものすべてに付く。書籍の script を止める唯一の層なので、
        // ここで条件を挟まない（挟むと、挟み損ねたものが漏れる）。
        var headers = new StringBuilder()
            .Append("Content-Type: ").Append(made.ContentType)
            .Append("\nContent-Security-Policy: ").Append(made.ContentSecurityPolicy)
            // 覚え直しはこちらが決める。書籍を差し替えたときに古い本文を出さない。
            .Append("\nCache-Control: no-store");

        e.Response = _environment.CreateWebResourceResponse(
            new MemoryStream(made.Body), 200, "OK", headers.ToString());
    }

    /// <summary>
    /// 本文の配信元から出ようとする移動は取り消す。外部 URL は OS のブラウザで開く。
    ///
    /// <para>
    /// <c>about:blank</c> は通す。WebView2 は初期化のときに自分でここへ移るので、
    /// 取り消すと出だしで躓かせることになる。
    /// </para>
    /// </summary>
    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        if (ResourceDelivery.HrefOf(e.Uri) is not null || e.Uri.StartsWith("about:", StringComparison.Ordinal))
        {
            return;
        }
        e.Cancel = true;
        if (CancelledNavigations.Count < 20)
        {
            CancelledNavigations.Add(e.Uri);
        }
        OpenOutside(e.Uri);
    }

    private void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        // 窓の開き方はこちらで決める。WebView に勝手に開かせない。
        e.Handled = true;
        OpenOutside(e.Uri);
    }

    private static void OpenOutside(string uri)
    {
        if (!Uri.TryCreate(uri, UriKind.Absolute, out var parsed))
        {
            return;
        }
        if (parsed.Scheme is not ("http" or "https"))
        {
            return;
        }
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uri) { UseShellExecute = true });
        }
        catch (Exception)
        {
            // 開けなくても読書は続けられる。
        }
    }

    // MARK: 出先とのやり取り

    private async void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string raw;
        try
        {
            raw = e.TryGetWebMessageAsString() ?? e.WebMessageAsJson;
        }
        catch (Exception)
        {
            return;
        }
        if (RawMessages.Count < 50)
        {
            RawMessages.Add(raw);
        }

        JsonElement message;
        try
        {
            message = JsonDocument.Parse(raw).RootElement;
        }
        catch (JsonException)
        {
            return;
        }
        if (!message.TryGetProperty("kind", out var kindValue) || kindValue.GetString() is not { } kind)
        {
            return;
        }

        switch (kind)
        {
            case "ready":
                ReadyCount++;
                await Send(new { kind = "style", css = _style.Css() });
                _awaitingReady?.TrySetResult(true);
                break;

            case "position":
                if (message.TryGetProperty("progression", out var at) && at.TryGetDouble(out var value))
                {
                    Progression = value;
                    PositionLabel.Text = $"{value * 100:F0}%";
                }
                break;

            case "arrow":
                // 綴じ方向が右開きなら左右の意味を入れ替える（spec.md 10.2）。
                var forward = message.TryGetProperty("side", out var side) && side.GetString() == "right";
                if (_session.Publication.Direction == ReadingDirection.Rtl)
                {
                    forward = !forward;
                }
                await MoveAsync(forward ? 1 : -1);
                break;
        }
    }

    private Task Send(object message) =>
        Body.CoreWebView2.ExecuteScriptAsync(ReaderScripts.Apply(message));

    // MARK: 移動

    internal async Task MoveAsync(int delta)
    {
        if (_session.Move(delta))
        {
            await ShowAsync(_session.Index);
        }
    }

    /// <summary>読み順の 1 つを出す。名乗るまで待てるようにしておく（動作確認が使う）。</summary>
    internal async Task ShowAsync(int index)
    {
        _session.MoveTo(index);
        var href = _session.HrefAt(_session.Index);
        ChapterLabel.Text = _session.TitleAt(_session.Index);
        Title = $"{_session.Publication.Title} — {ChapterLabel.Text}";

        _awaitingReady = new TaskCompletionSource<bool>();
        Body.CoreWebView2.Navigate(ResourceDelivery.UrlOf(href));
    }

    /// <summary>
    /// 本文が名乗るまで待つ。
    ///
    /// <b>窓の数だけを見ていては、枠だけ出来て中身が空の状態を捕まえられない。</b>
    /// 画面が名乗るところまで見る（spikes/findings-tauri.md）。
    /// </summary>
    internal async Task<bool> WaitForReadyAsync(TimeSpan timeout)
    {
        var waiting = _awaitingReady;
        if (waiting is null)
        {
            return false;
        }
        var finished = await Task.WhenAny(waiting.Task, Task.Delay(timeout));
        return finished == waiting.Task && waiting.Task.Result;
    }

    /// <summary>
    /// ページの中の様子を聞く。名乗らなかったときの切り分けに使う。
    ///
    /// <para>
    /// <c>ExecuteScriptAsync</c> は <c>IsScriptEnabled = false</c> でも使える
    /// （spikes/findings-windows.md のスパイク 3）。書籍の script を動かさずに中を覗ける。
    /// </para>
    /// </summary>
    internal async Task<string> AskAsync(string expression)
    {
        try
        {
            return await Body.CoreWebView2.ExecuteScriptAsync(expression);
        }
        catch (Exception e)
        {
            return $"\"{e.GetType().Name}\"";
        }
    }

    internal async Task ApplyStyleAsync(ReaderStyle style)
    {
        _style = style;
        await Send(new { kind = "style", css = _style.Css() });
    }
}
