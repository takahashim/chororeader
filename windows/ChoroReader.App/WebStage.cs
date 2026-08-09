using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using ChoroReader.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace ChoroReader.App;

/// <summary>
/// EPUB の舞台。本文だけが WebView2 に入る。
///
/// <para>
/// 書籍の script は CSP（<c>script-src 'none'</c>）で止め、注入したものだけを動かす
/// （spec.md 15.1、windows/README.md「書籍の script の止め方」）。
/// 殻はネイティブなので、WebView の中にアプリの DOM がそもそも無い。
/// </para>
/// <para>
/// リフローと固定レイアウトの両方をここが持つ。どちらも本文は HTML なので、
/// 違うのは「表示設定が効くか」と「ページの一覧を出すか」だけである。
/// </para>
/// </summary>
internal sealed class WebStage : IStage
{
    private readonly BookSession _session;
    private readonly CoreWebView2Environment _environment;
    private readonly WebView2 _body = new();
    private ReaderStyle _style = new();

    private TaskCompletionSource<bool>? _awaitingReady;
    private TaskCompletionSource<bool>? _awaitingPosition;

    /// <summary>覚えていた位置。最初の章が名乗ったら、そこへ戻す。</summary>
    private Position? _restoring;

    private double _progression;
    private string _positionText = string.Empty;

    /// <summary>章の中のどこかが、まだ届いていない。章を開くたびに立て直す。</summary>
    public bool PositionPending { get; private set; } = true;

    internal WebStage(BookSession session, CoreWebView2Environment environment)
    {
        _session = session;
        _environment = environment;
    }

    public FrameworkElement View => _body;

    public string BookTitle => _session.Publication.Title;

    public event Action? Moved;

    public bool Reflowable => _session.Publication.Layout == PublicationLayout.Reflowable;

    /// <summary>
    /// 固定レイアウトは 1 枚ずつが 1 ページなので、読み順をそのままページの一覧にする。
    /// リフローには紙面が無いので、タブそのものを出さない。
    /// </summary>
    public IReadOnlyList<Place> Pages => Reflowable
        ? []
        : [.. Enumerable.Range(0, _session.Count)
            .Select(i => new Place($"{i + 1}. {_session.TitleAt(i)}", Href: _session.HrefAt(i)))];

    /// <summary>
    /// 固定レイアウトのページは画像でできていることが多く、文字の層を持たない。
    /// 引けないことは<b>引いてみるまで分からない</b>ので、理由は当たりが 0 のときに添える。
    /// </summary>
    public string? CannotSearch => null;

    public IReadOnlyList<Place> Toc
    {
        get
        {
            var rows = new List<Place>();
            Walk(_session.Publication.TableOfContents, 0);
            return rows;

            void Walk(IReadOnlyList<TocEntry> entries, int depth)
            {
                foreach (var entry in entries)
                {
                    if (entry.Href is { } href)
                    {
                        rows.Add(new Place(entry.Title, href, entry.Fragment, Depth: depth));
                    }
                    Walk(entry.Children, depth + 1);
                }
            }
        }
    }

    public Whereabouts Where => new(_session.TitleAt(_session.Index), $"{_progression * 100:F0}%");

    public Position Position => new()
    {
        Href = _session.HrefAt(_session.Index),
        Progression = _progression,
        Text = _positionText,
    };

    public void ResumeFrom(Position position)
    {
        if (position.Href.Length == 0)
        {
            return;
        }
        var at = _session.Publication.ReadingOrder
            .Select((link, index) => (link, index))
            .FirstOrDefault(pair => pair.link.Href == position.Href);
        if (at.link is null)
        {
            return;
        }
        _session.MoveTo(at.index);
        _restoring = position;
    }

    /// <summary>
    /// 本文を出せる状態にして、最初の章を開く。
    ///
    /// <para>
    /// <b>初期化は必ず await する。</b><c>GetAwaiter().GetResult()</c> で待つと、
    /// メッセージポンプを自分で止めて永久に待つ（spikes/findings-windows.md）。
    /// </para>
    /// </summary>
    public async Task StartAsync()
    {
        await _body.EnsureCoreWebView2Async(_environment);
        var core = _body.CoreWebView2;

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
                // 覚えていた場所へは、本文が出てから戻す。出る前に送っても行き先が無い。
                if (_restoring is { } back)
                {
                    _restoring = null;
                    await Send(new { kind = "go", fragment = back.Fragment, progression = back.Progression });
                }
                _awaitingReady?.TrySetResult(true);
                break;

            case "position":
                if (message.TryGetProperty("progression", out var at) && at.TryGetDouble(out var value))
                {
                    PositionCount++;
                    PositionPending = false;
                    _progression = value;
                    _positionText = message.TryGetProperty("text", out var text)
                        ? text.GetString() ?? string.Empty
                        : string.Empty;
                    Moved?.Invoke();
                    _awaitingPosition?.TrySetResult(true);
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
        _body.CoreWebView2.ExecuteScriptAsync(ReaderScripts.Apply(message));

    // MARK: 引く

    /// <summary>
    /// 本文を引く。走査は背後のスレッドで行う。章を丸ごと読むので、画面で回すと固まる。
    /// </summary>
    public async Task<(IReadOnlyList<Place> Hits, bool Truncated)> FindAsync(string query)
    {
        query = query.Trim();
        if (query.Length == 0)
        {
            return ([], false);
        }

        var outcome = await Task.Run(() =>
            DocumentSearch.SearchEpub(_session.Resources, _session.Publication, query));

        var hits = outcome.Results.Select(hit => new Place(
            Label: hit.ChapterTitle,
            Href: hit.Locator.Href ?? string.Empty,
            Query: query,
            Nth: hit.Nth,
            Detail: $"{hit.Before}{hit.Match}{hit.After}".Replace('\n', ' '))).ToList();
        return (hits, outcome.Truncated);
    }

    // MARK: 移動

    public async Task<bool> MoveAsync(int delta)
    {
        if (!_session.Move(delta))
        {
            return false;
        }
        await ShowAsync(_session.Index);
        return true;
    }

    /// <summary>章へ飛ぶ。当たりを指していれば、配信のときに印が本文へ入る。</summary>
    public async Task GoAsync(Place place)
    {
        if (place.Href is not { Length: > 0 } href)
        {
            return;
        }
        var at = _session.Publication.ReadingOrder
            .Select((link, index) => (link, index))
            .FirstOrDefault(pair => pair.link.Href == href);
        if (at.link is null)
        {
            return;
        }

        _session.Delivery.SearchMark = place.Query is { Length: > 0 } query ? (query, place.Nth) : null;
        await ShowAsync(at.index);
        await WaitForReadyAsync(TimeSpan.FromSeconds(10));
        if (place.Query is { Length: > 0 })
        {
            await Send(new { kind = "approach" });
        }
        else if (place.Fragment is { Length: > 0 } || place.Progression > 0)
        {
            // しおりは章の中のどこかを指す。頭へ飛ばすだけでは、長い章で役に立たない。
            await Send(new { kind = "go", fragment = place.Fragment, progression = place.Progression });
        }
    }

    /// <summary>読み順の 1 つを出す。名乗るまで待てるようにしておく（動作確認が使う）。</summary>
    internal Task ShowAsync(int index)
    {
        _session.MoveTo(index);

        // 章が移ったら、章の中の位置はまだ分からない。
        // 前の章の割合を出したままにすると、下辺が嘘をつく。
        _progression = 0;
        _positionText = string.Empty;
        PositionPending = true;
        Moved?.Invoke();

        _awaitingReady = new TaskCompletionSource<bool>();
        _awaitingPosition = new TaskCompletionSource<bool>();
        _body.CoreWebView2.Navigate(ResourceDelivery.UrlOf(_session.HrefAt(_session.Index)));
        return Task.CompletedTask;
    }

    public async Task ApplyStyleAsync(ReaderStyle style)
    {
        _style = style;
        await Send(new { kind = "style", css = _style.Css() });
    }

    public void Dispose() => _session.Dispose();

    // MARK: 動作確認のための覗き口

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

    /// <summary>本文が名乗った回数。動作確認が「枠だけ出来ていないか」を見る。</summary>
    internal int ReadyCount { get; private set; }

    /// <summary>位置の便りが届いた回数。動作確認が「追従しているか」を見る。</summary>
    internal int PositionCount { get; private set; }

    /// <summary>
    /// 本文が名乗るまで待つ。
    ///
    /// <b>窓の数だけを見ていては、枠だけ出来て中身が空の状態を捕まえられない。</b>
    /// 画面が名乗るところまで見る（spikes/findings-tauri.md）。
    /// </summary>
    internal Task<bool> WaitForReadyAsync(TimeSpan timeout) => Await(_awaitingReady, timeout);

    /// <summary>
    /// 位置の便りが届くまで待つ。
    ///
    /// <para>
    /// 便りは 120 ミリ秒に間引いてある。<b>待たずに次へ進むと、毎回捨てられる。</b>
    /// 追従が生きているかを確かめたいときは、ここで待つ。
    /// </para>
    /// </summary>
    internal Task<bool> WaitForPositionAsync(TimeSpan timeout) => Await(_awaitingPosition, timeout);

    private static async Task<bool> Await(TaskCompletionSource<bool>? waiting, TimeSpan timeout)
    {
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
            return await _body.CoreWebView2.ExecuteScriptAsync(expression);
        }
        catch (Exception e)
        {
            return $"\"{e.GetType().Name}\"";
        }
    }
}
