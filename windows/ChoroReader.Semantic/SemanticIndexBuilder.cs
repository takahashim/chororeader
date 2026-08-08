using System.Runtime.InteropServices;
using ChoroReader.Core;

namespace ChoroReader.Semantic;

/// <summary>いま作っているもの。画面に出すためのもの。</summary>
public sealed record Working(string Title, int Done, int Total)
{
    public double Fraction => Total > 0 ? (double)Done / Total : 0;
}

/// <summary>まだ作っていない冊数と、作ったが版が変わった冊数。</summary>
/// <remarks>
/// <b>この 2 つは人にとって違う。</b>前者は待てば済むが、後者は全量が作り直しになる
/// （spec-local-ai.md 4.4）。混ぜて数えると、モデルを入れ替えた日に
/// 「なぜ終わらないのか」が分からなくなる。
/// </remarks>
public readonly record struct SemanticCounts(int NotBuilt, int Stale);

/// <summary>
/// 意味の索引を作る係。
///
/// <para>
/// <b>初回が重いことを前提に組む</b>（spec-local-ai.md 4.4）。
/// 1 冊で数十秒、蔵書 1,000 冊なら数時間かかる。だから
/// </para>
/// <list type="bullet">
/// <item>順番を付ける（いま開いた本 → 残り）</item>
/// <item>進み具合を見せ、途中でやめられる</item>
/// <item>残りは既定では電源に繋がっているときだけ進める</item>
/// </list>
/// <para>
/// 二字組索引と違って<b>黙って始めない</b>。あちらは 1 冊 1 秒で済むが、
/// こちらは電池と時間を目に見えて使う。
/// </para>
/// <para>
/// <b>画面を知らない。</b>動いたことは <see cref="Changed"/> で伝えるだけにして、
/// どの筋で描き直すかは窓に決めさせる。そうしておけば macOS でも検査できる。
/// </para>
/// </summary>
public sealed class SemanticIndexBuilder : IDisposable
{
    /// <summary>書棚が落ち着いてから、これだけ待って始める。</summary>
    public static readonly TimeSpan IdleDelay = TimeSpan.FromSeconds(8);

    private readonly SemanticIndexStore _store;
    private readonly Func<IEmbedder> _open;
    private readonly Func<bool> _onPower;
    private readonly string _model;

    private readonly Lock _gate = new();
    private readonly List<Job> _queue = [];

    private IEmbedder? _embedder;
    private CancellationTokenSource? _stopping;
    private bool _running;
    private int _generation;
    private int _idleGeneration;
    private bool _disposed;

    /// <summary>
    /// 待っている仕事。<b>電源の条件を仕事そのものに持たせる。</b>
    ///
    /// <para>
    /// 「いま何もしていなければ 1 冊目＝開いた本」と見なすと、中断の直後も
    /// 1 冊終えた直後も何もしていない状態なので、まとめて並べた 1 冊目まで
    /// 電源の条件を素通りする（macOS 版が踏んだ）。
    /// </para>
    /// </summary>
    private readonly record struct Job(string Path, bool IgnoresPower);

    public SemanticIndexBuilder(SemanticIndexStore store, Func<IEmbedder> open, string model,
                                Func<bool>? onPower = null)
    {
        _store = store;
        _open = open;
        _model = model;
        _onPower = onPower ?? OnPower;
    }

    // MARK: 設定

    /// <summary>意味の層を使うか。<b>切ったら抱えている埋め込み器も降ろす。</b></summary>
    public bool Enabled
    {
        get { lock (_gate) { return _enabled; } }
        set
        {
            lock (_gate)
            {
                if (_enabled == value)
                {
                    return;
                }
                _enabled = value;
            }
            if (!value)
            {
                // **降ろすのは切ったときだけ。** 使う見込みが無くなる唯一の折である
                // （spec-local-ai.md 4.5）。時計で降ろすと、書棚で引くたびに
                // 作り直しの値段を払うことになる。
                Stop();
                lock (_gate)
                {
                    (_embedder as IDisposable)?.Dispose();
                    _embedder = null;
                }
            }
            Changed?.Invoke();
        }
    }

    private bool _enabled;

    public bool OnPowerOnly { get; set; } = true;

    // MARK: 見えるもの

    /// <summary>いま作っているもの。止まっていれば null。</summary>
    public Working? Working { get; private set; }

    /// <summary>直近に落ちた理由。画面に出すためのもの。</summary>
    public string? Failure { get; private set; }

    public int Pending
    {
        get { lock (_gate) { return _queue.Count; } }
    }

    /// <summary>何かが動いた。窓が描き直す合図。</summary>
    public event Action? Changed;

    /// <summary>
    /// まだ作っていない冊数と、版が変わった冊数を分けて数える。
    ///
    /// <para>
    /// 数えるのは<b>索引ファイルの頭だけ</b>なので、蔵書ぶん呼んでも安い。
    /// </para>
    /// </summary>
    public SemanticCounts Count(IEnumerable<string> bookPaths)
    {
        var notBuilt = 0;
        var stale = 0;
        foreach (var path in bookPaths)
        {
            if (_store.RecordedModel(path) is not { } recorded)
            {
                notBuilt++;
            }
            else if (recorded != _model)
            {
                stale++;
            }
        }
        return new SemanticCounts(notBuilt, stale);
    }

    /// <summary>
    /// 問いを 1 本のベクトルにする。
    ///
    /// <para>
    /// <b>索引づくりと同じ埋め込み器を使う。</b>問いのたびに開き直すと、
    /// 語彙とグラフを読み込む値段（数百 ms）を毎回払う。**握っておくことだけを考える**
    /// （spec-local-ai.md 4.5）。
    /// </para>
    /// <para>
    /// <b>画面のスレッドから呼んではいけない。</b>初回はモデルを開く。
    /// </para>
    /// </summary>
    public float[] Ask(string query)
    {
        IEmbedder embedder;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _embedder ??= _open();
            embedder = _embedder;
        }
        return embedder.Embed(query, EmbeddingKind.Query).Vector;
    }

    // MARK: 頼む

    /// <summary>
    /// 開いた本を先に作る。<b>割り込ませる。</b>
    /// 読んでいる本の関連箇所が出ないのが、いちばん困る。
    /// </summary>
    public void Prioritize(string bookPath)
    {
        lock (_gate)
        {
            if (!_enabled || _store.Has(bookPath, _model))
            {
                return;
            }
            _queue.RemoveAll(job => Same(job.Path, bookPath));
            _queue.Insert(0, new Job(bookPath, IgnoresPower: true));
        }
        Start();
    }

    /// <summary>
    /// 書棚が落ち着いたら、残りを作り始める。
    ///
    /// <para>
    /// 書棚は開いたまま置かれることが多いので、少し待ってから始める。
    /// 開いた直後は表紙の読み込みなどが走っており、そこへ重ねない。
    /// </para>
    /// </summary>
    public void ScheduleIdle(IReadOnlyList<string> bookPaths, TimeSpan? after = null)
    {
        lock (_gate)
        {
            if (!_enabled)
            {
                return;
            }
            _idleGeneration++;
        }
        var mine = _idleGeneration;
        _ = Task.Run(async () =>
        {
            await Task.Delay(after ?? IdleDelay);
            // その間に書棚が動いたら、そちらの番に譲る。
            lock (_gate)
            {
                if (_idleGeneration != mine)
                {
                    return;
                }
            }
            Enqueue(bookPaths);
        });
    }

    /// <summary>残りを順に作る。既に索引のあるものは並べない。</summary>
    public void Enqueue(IReadOnlyList<string> bookPaths)
    {
        lock (_gate)
        {
            if (!_enabled)
            {
                return;
            }
            foreach (var path in bookPaths)
            {
                if (_queue.Any(job => Same(job.Path, path)) || _store.Has(path, _model))
                {
                    continue;
                }
                _queue.Add(new Job(path, IgnoresPower: false));
            }
        }
        Start();
    }

    /// <summary>途中でやめる。<b>作りかけは置かない。</b></summary>
    public void Stop()
    {
        lock (_gate)
        {
            _queue.Clear();
            _stopping?.Cancel();
        }
    }

    private static bool Same(string left, string right) =>
        string.Equals(Paths.Normalize(left), Paths.Normalize(right), StringComparison.Ordinal);

    // MARK: 進める

    private void Start()
    {
        lock (_gate)
        {
            if (_running || _queue.Count == 0 || !_enabled || _disposed)
            {
                return;
            }
            _running = true;
            _stopping = new CancellationTokenSource();
            // **落ちた理由を消すのは、新しく走り出すときだけ。**
            // 1 冊落ちても残りは進むので、次の 1 冊が成功した時点で消すと、
            // 読者に伝わらないまま終わる。
            Failure = null;
        }
        _ = Task.Run(RunAsync);
    }

    private async Task RunAsync()
    {
        while (true)
        {
            Job job;
            CancellationToken cancel;
            lock (_gate)
            {
                cancel = _stopping?.Token ?? CancellationToken.None;
                if (cancel.IsCancellationRequested || _queue.Count == 0 || !_enabled)
                {
                    _running = false;
                    Working = null;
                    Changed?.Invoke();
                    return;
                }
                job = _queue[0];
                _queue.RemoveAt(0);

                // 開いた本は、電源に繋がっていなくても作る。
                if (!job.IgnoresPower && OnPowerOnly && !_onPower())
                {
                    _running = false;
                    Working = null;
                    Changed?.Invoke();
                    return;
                }
                _generation++;
            }

            var mine = _generation;
            var title = Path.GetFileNameWithoutExtension(job.Path);
            Working = new Working(title, 0, 0);
            Changed?.Invoke();

            try
            {
                await Task.Run(() => BuildOne(job.Path, title, mine, cancel), cancel);
            }
            catch (OperationCanceledException)
            {
                // やめた。何も言わない。
            }
            catch (Exception error)
            {
                Failure = $"{title}：{error.Message}";
                Changed?.Invoke();
            }
        }
    }

    private void BuildOne(string bookPath, string title, int generation, CancellationToken cancel)
    {
        var pieces = Pieces(bookPath);
        if (pieces.Count == 0)
        {
            return;
        }

        IEmbedder embedder;
        lock (_gate)
        {
            // **一度作ったら持ち続ける。** 作り直しは語彙とグラフを開き直すので高い
            // （spec-local-ai.md 4.5）。膨らまないものを時計で降ろす値打ちは無い。
            _embedder ??= _open();
            embedder = _embedder;
        }

        _store.Build(bookPath, pieces, embedder, _model,
                     progress: made =>
                     {
                         // **毎段落は届けない。** 1 冊 600 段落ぶん流すと、
                         // 見ている画面がその回数だけ描き直される。
                         if (!ShouldReport(made))
                         {
                             return;
                         }
                         // 遅れて届いた分で、次の本の進み具合を上書きしない。
                         if (_generation != generation)
                         {
                             return;
                         }
                         Working = new Working(title, made.Done, made.Total);
                         Changed?.Invoke();
                     },
                     cancel: cancel);
    }

    /// <summary>進み具合を届けるか。人に見えるのは帯の動きなので、そこだけで足りる。</summary>
    private static bool ShouldReport(SemanticProgress made) =>
        made.Done == 1 || made.Done == made.Total || made.Done % 16 == 0;

    /// <summary>書籍を段落に切る。読めない書籍は空にして、次へ進む。</summary>
    private static IReadOnlyList<SemanticPiece> Pieces(string bookPath)
    {
        if (DocumentFormats.Detect(bookPath) == DocumentFormat.Pdf)
        {
            using var paper = PdfInspector.Open(bookPath);
            return SemanticUnits.OfPdf(paper);
        }
        using var archive = new EpubArchive(bookPath);
        return SemanticUnits.OfEpub(archive, EpubParser.Parse(archive));
    }

    // MARK: 電源

    /// <summary>
    /// 電源に繋がっているか。
    ///
    /// <para>
    /// Windows でしか聞けない。ほかでは繋がっていることにする
    /// （開発機で索引づくりが止まると、確かめようがない）。
    /// </para>
    /// </summary>
    private static bool OnPower()
    {
        if (!OperatingSystem.IsWindows())
        {
            return true;
        }
        try
        {
            return GetSystemPowerStatus(out var status) && status.ACLineStatus != 0;
        }
        catch (Exception)
        {
            return true;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemPowerStatus(out SystemPowerStatus status);

    public void Dispose()
    {
        Stop();
        lock (_gate)
        {
            _disposed = true;
            (_embedder as IDisposable)?.Dispose();
            _embedder = null;
        }
    }
}
