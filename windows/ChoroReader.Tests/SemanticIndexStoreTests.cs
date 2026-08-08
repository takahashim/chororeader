using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 意味の索引の置き場所と、作り直しの判断。
///
/// <para>
/// <b>失効を取り違えると、見た目は何も変わらないまま順位だけが狂う。</b>
/// モデルを入れ替えたのに古いベクトルを使い続けても、画面には何も出ない。
/// ここで見るのは主にそれである。
/// </para>
/// </summary>
public class SemanticIndexStoreTests : IDisposable
{
    private const string Model = "ruri-v3-130m";

    private readonly string _root =
        Path.Combine(Path.GetTempPath(), $"choro-semantic-{Guid.NewGuid():N}");

    private string Book { get; }

    public SemanticIndexStoreTests()
    {
        Directory.CreateDirectory(_root);
        Book = Path.Combine(_root, "ある本.epub");
        File.WriteAllText(Book, "これは書籍のつもり");
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch (Exception)
        {
            // 消せなくても検査の結果には関わらない。
        }
        GC.SuppressFinalize(this);
    }

    private SemanticIndexStore Open() => new(Path.Combine(_root, "semantic"));

    private static IReadOnlyList<SemanticPiece> Pieces(int count) =>
        [.. Enumerable.Range(0, count).Select(at => new SemanticPiece(
            new SemanticUnit
            {
                Locator = new Locator { Href = "ch01.xhtml", Progression = at / (double)count },
                Heading = $"第 {at / 3 + 1} 節",
                Section = at / 3,
            },
            $"これは {at} 番目の段落である。"))];

    private SemanticIndex Build(SemanticIndexStore store, IEmbedder embedder, string model = Model) =>
        store.Build(Book, Pieces(9), embedder, model)!;

    // MARK: 作って読み直す

    [Fact]
    public void 作って置いて読み直せる()
    {
        var store = Open();
        var made = Build(store, new FakeEmbedder());

        Assert.Equal(9, made.Count);
        Assert.Equal(8, made.Dimension);

        // 別の店から、同じ置き場所を読む。抱え込みではなくファイルから来ること。
        var again = Open().Cached(Book, Model);
        Assert.NotNull(again);
        Assert.Equal(9, again!.Count);
        Assert.Equal("第 1 節", again.Unit(0).Heading);
    }

    [Fact]
    public void 作っていなければ何も返さない()
    {
        Assert.Null(Open().Cached(Book, Model));
        Assert.False(Open().Has(Book, Model));
        Assert.Null(Open().SizeOnDisk(Book));
        Assert.Null(Open().RecordedModel(Book));
    }

    /// <summary>見出しを頭に付ける。節の途中だけを見ても何の話か分かるようにする。</summary>
    [Fact]
    public void 見出しを頭に付けて埋め込む()
    {
        var embedder = new FakeEmbedder();
        Build(Open(), embedder);

        Assert.Equal(9, embedder.Calls);
        Assert.StartsWith("第 3 節。", embedder.Last);
        // 索引に載せるのは文書として。問いの向きで作らない。
        Assert.All(embedder.Kinds, kind => Assert.Equal(EmbeddingKind.Document, kind));
    }

    [Fact]
    public void 切り詰めた数を数える()
    {
        // 上限を 5 文字にすれば、どの段落も切り詰められる。
        var made = Build(Open(), new FakeEmbedder(limit: 5));

        Assert.Equal(9, made.Truncated);
    }

    [Fact]
    public void 段落が無ければ作らない()
    {
        var store = Open();

        Assert.Null(store.Build(Book, [], new FakeEmbedder(), Model));
        Assert.Null(store.SizeOnDisk(Book));
    }

    // MARK: 失効

    /// <summary>
    /// <b>モデルを入れ替えたら使わない。</b>ファイルの大きさと更新日時だけを鍵にすると、
    /// 古いベクトルをそのまま使い続け、見た目は何も変わらないまま順位だけが狂う。
    /// </summary>
    [Fact]
    public void モデルが違えば使わない()
    {
        var store = Open();
        Build(store, new FakeEmbedder());

        Assert.NotNull(store.Cached(Book, Model));
        Assert.Null(store.Cached(Book, "別のモデル"));
        Assert.Null(Open().Cached(Book, "別のモデル"));
    }

    /// <summary>
    /// 「まだ作っていない」と「作ったが版が変わった」は、人にとって違う。
    /// 前者は待てば済むが、後者は全量が作り直しになる。
    /// </summary>
    [Fact]
    public void 作っていないのと版が変わったのを分ける()
    {
        var store = Open();

        // まだ作っていない。作り直しではない。
        Assert.False(store.IsStale(Book, Model));

        Build(store, new FakeEmbedder());
        Assert.False(store.IsStale(Book, Model));
        Assert.True(store.IsStale(Book, "別のモデル"));
    }

    /// <summary>
    /// 版を数えるのは<b>頭だけ</b>で済む。蔵書ぶん呼ばれるので、中身まで読むわけにいかない。
    /// </summary>
    [Fact]
    public void 記録したモデルは頭だけで読める()
    {
        Build(Open(), new FakeEmbedder());

        Assert.Equal(Model, Open().RecordedModel(Book));
    }

    [Fact]
    public void 書籍が変わったら使わない()
    {
        var store = Open();
        Build(store, new FakeEmbedder());
        Assert.NotNull(store.Cached(Book, Model));

        // 中身を書き換える。大きさが変わる。
        File.WriteAllText(Book, "これは書籍のつもり。書き足した。");

        Assert.Null(store.Cached(Book, Model));
        Assert.Null(Open().Cached(Book, Model));
    }

    [Fact]
    public void 書籍が消えたら使わない()
    {
        var store = Open();
        Build(store, new FakeEmbedder());

        File.Delete(Book);

        Assert.Null(store.Cached(Book, Model));
    }

    [Fact]
    public void 壊れたファイルは読まない()
    {
        var store = Open();
        Build(store, new FakeEmbedder());

        var where = Directory.GetFiles(Path.Combine(_root, "semantic"), "*.vec").Single();
        var whole = File.ReadAllBytes(where);
        File.WriteAllBytes(where, whole[..(whole.Length / 2)]);

        Assert.Null(Open().Cached(Book, Model));
    }

    [Fact]
    public void 外せる()
    {
        var store = Open();
        Build(store, new FakeEmbedder());
        Assert.NotNull(store.SizeOnDisk(Book));

        store.Discard(Book);

        Assert.Null(store.Cached(Book, Model));
        Assert.Null(store.SizeOnDisk(Book));
    }

    /// <summary>
    /// <b>降りたら書きかけを置かない。</b>半端なものを置くと、
    /// 次に開いたときに「作ってある」ことになる。
    /// </summary>
    [Fact]
    public void 途中で降りたら何も置かない()
    {
        var store = Open();
        using var stopping = new CancellationTokenSource();
        stopping.Cancel();

        Assert.Null(store.Build(Book, Pieces(9), new FakeEmbedder(), Model, cancel: stopping.Token));
        Assert.Null(store.SizeOnDisk(Book));
        Assert.Null(Open().Cached(Book, Model));
    }

    /// <summary>埋め込み器が名乗る長さと違うものを返したら、そのまま置かない。</summary>
    [Fact]
    public void 長さの違う埋め込みは受け取らない()
    {
        Assert.Throws<DocumentException>(() =>
            Open().Build(Book, Pieces(9), new WrongLength(), Model));
    }

    private sealed class WrongLength : IEmbedder
    {
        public int Dimension => 8;

        public Embedded Embed(string text, EmbeddingKind kind) => new(new float[4], false);
    }

    // MARK: 抱え込み

    /// <summary>
    /// ほどいたものは抱えておく。引くたびにほどき直すと、読み込みのほうが高く付く。
    /// </summary>
    [Fact]
    public void 一度読んだら抱えておく()
    {
        var store = Open();
        Build(store, new FakeEmbedder());

        var first = store.Cached(Book, Model);
        var second = store.Cached(Book, Model);

        Assert.NotNull(first);
        Assert.Same(first, second);
    }

    [Fact]
    public void 忘れさせられる()
    {
        var store = Open();
        Build(store, new FakeEmbedder());
        var first = store.Cached(Book, Model);

        store.ForgetMemory();

        // 読み直すので別のものになる。中身は同じ。
        var again = store.Cached(Book, Model);
        Assert.NotSame(first, again);
        Assert.Equal(first!.Count, again!.Count);
    }
}
