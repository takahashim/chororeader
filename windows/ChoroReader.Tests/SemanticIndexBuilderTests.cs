using ChoroReader.Core;
using ChoroReader.Semantic;

namespace ChoroReader.Tests;

/// <summary>
/// 意味の索引を作る係。
///
/// <para>
/// <b>黙って始めないこと</b>が要である。1 冊で数十秒、蔵書 1,000 冊なら数時間かかり、
/// 電池と時間を目に見えて使う。入にしていないのに走り出す、電源に繋がっていないのに
/// 残りを進める、というのが最も困る（spec-local-ai.md 4.4）。
/// </para>
/// <para>
/// 係は画面を知らないので、本物のモデルも窓も要らずにここで確かめられる。
/// </para>
/// </summary>
public class SemanticIndexBuilderTests : IDisposable
{
    private const string Model = "ruri-v3-130m";

    private readonly string _root =
        Path.Combine(Path.GetTempPath(), $"choro-builder-{Guid.NewGuid():N}");

    private readonly List<string> _books = [];

    public SemanticIndexBuilderTests()
    {
        Directory.CreateDirectory(_root);
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

    /// <summary>
    /// 読める EPUB を 1 冊置く。
    ///
    /// <para>
    /// <b>見本をそのまま写すと段落が 1 つも出ない。</b>章が 291・144・102 字しかなく、
    /// 段落の下限（100 字）に届かないためである。見本の骨組みは借りて、本文だけ差し替える。
    /// 中身は架空で、実在の書籍からは取っていない。
    /// </para>
    /// </summary>
    private string Book(string name)
    {
        var where = Path.Combine(_root, name);
        File.Copy(Path.Combine(TestPaths.Samples, "sample-reflowable.epub"), where, overwrite: true);

        using (var zip = System.IO.Compression.ZipFile.Open(
                   where, System.IO.Compression.ZipArchiveMode.Update))
        {
            for (var at = 1; at <= 3; at++)
            {
                var path = $"OEBPS/text/ch{at:00}.xhtml";
                zip.GetEntry(path)?.Delete();
                var entry = zip.CreateEntry(path);
                using var writer = new StreamWriter(entry.Open());
                writer.Write($"""
                    <?xml version="1.0" encoding="UTF-8"?>
                    <html xmlns="http://www.w3.org/1999/xhtml"><body>
                    <h1 id="s{at}">第 {at} 章</h1>
                    <p>{Filler(at)}</p>
                    </body></html>
                    """);
            }
        }

        _books.Add(where);
        return where;
    }

    /// <summary>段落の下限を越える長さの、意味の無い本文。</summary>
    private static string Filler(int at) =>
        string.Concat(Enumerable.Repeat($"これは第 {at} 章の本文であり、検査のために置いた架空の文である。", 20));

    private SemanticIndexStore Store() => new(Path.Combine(_root, "semantic"));

    private SemanticIndexBuilder Open(SemanticIndexStore store, FakeEmbedder embedder,
                                      bool onPower = true) =>
        new(store, () => embedder, Model, onPower: () => onPower);

    /// <summary>止まるまで待つ。長くても数秒で終わる仕事しか並べない。</summary>
    private static async Task Settled(SemanticIndexBuilder builder)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        while (DateTime.UtcNow < deadline)
        {
            if (builder.Pending == 0 && builder.Working is null)
            {
                // 1 拍おいて、最後の 1 冊が書き終わるのを待つ。
                await Task.Delay(50);
                if (builder.Pending == 0 && builder.Working is null)
                {
                    return;
                }
            }
            await Task.Delay(20);
        }
        Assert.Fail("止まらなかった");
    }

    // MARK: 黙って始めない

    /// <summary><b>入にしていなければ何もしない。</b></summary>
    [Fact]
    public async Task 入にしていなければ作らない()
    {
        var store = Store();
        var embedder = new FakeEmbedder();
        using var builder = Open(store, embedder);
        var book = Book("ある本.epub");

        builder.Prioritize(book);
        builder.Enqueue([book]);
        await Task.Delay(200);

        Assert.Equal(0, embedder.Calls);
        Assert.Equal(0, builder.Pending);
        Assert.Null(store.SizeOnDisk(book));
    }

    /// <summary>
    /// <b>電源に繋がっていなければ、残りは進めない。</b>
    /// ただし開いた本は別で、繋がっていなくても作る。
    /// </summary>
    [Fact]
    public async Task 電源が無ければ残りは進めない()
    {
        var store = Store();
        var embedder = new FakeEmbedder();
        using var builder = Open(store, embedder, onPower: false);
        builder.Enabled = true;
        var book = Book("ある本.epub");

        builder.Enqueue([book]);
        await Settled(builder);
        Assert.Equal(0, embedder.Calls);
        Assert.Null(store.SizeOnDisk(book));

        // 開いた本は割り込ませる。電源の条件を素通りしてよい唯一のもの。
        builder.Prioritize(book);
        await Settled(builder);
        Assert.True(embedder.Calls > 0);
        Assert.NotNull(store.SizeOnDisk(book));
    }

    /// <summary>
    /// <b>電源の条件は仕事そのものに持たせる。</b>
    ///
    /// <para>
    /// 「いま何もしていなければ 1 冊目＝開いた本」と見なすと、開いた本を 1 冊終えた直後は
    /// 何もしていない状態なので、次に並べた 1 冊目まで電源の条件を素通りする。
    /// </para>
    /// </summary>
    [Fact]
    public async Task 開いた本を作った後も残りは電源を見る()
    {
        var store = Store();
        var embedder = new FakeEmbedder();
        using var builder = Open(store, embedder, onPower: false);
        builder.Enabled = true;

        var opened = Book("開いた本.epub");
        builder.Prioritize(opened);
        await Settled(builder);
        var after = embedder.Calls;
        Assert.True(after > 0);

        // 続けて残りを並べる。電源が無いので進まないこと。
        var rest = Book("残りの本.epub");
        builder.Enqueue([rest]);
        await Settled(builder);

        Assert.Equal(after, embedder.Calls);
        Assert.Null(store.SizeOnDisk(rest));
    }

    // MARK: 作る

    [Fact]
    public async Task 並べたぶんを順に作る()
    {
        var store = Store();
        using var builder = Open(store, new FakeEmbedder());
        builder.Enabled = true;
        var books = new[] { Book("1 冊目.epub"), Book("2 冊目.epub") };

        builder.Enqueue(books);
        await Settled(builder);

        Assert.All(books, book => Assert.NotNull(store.SizeOnDisk(book)));
        Assert.Null(builder.Working);
        Assert.Null(builder.Failure);
    }

    /// <summary>既に索引のあるものは並べない。書棚を開き直すたびに作り直さない。</summary>
    [Fact]
    public async Task 作ってあるものは並べない()
    {
        var store = Store();
        var embedder = new FakeEmbedder();
        using var builder = Open(store, embedder);
        builder.Enabled = true;
        var book = Book("ある本.epub");

        builder.Enqueue([book]);
        await Settled(builder);
        var after = embedder.Calls;

        builder.Enqueue([book]);
        builder.Prioritize(book);
        await Settled(builder);

        Assert.Equal(after, embedder.Calls);
    }

    /// <summary>進み具合が届くこと。届かないと、何分も無言で待たせることになる。</summary>
    [Fact]
    public async Task 進み具合が届く()
    {
        var store = Store();
        using var builder = Open(store, new FakeEmbedder());
        builder.Enabled = true;
        var seen = new List<Working>();
        builder.Changed += () =>
        {
            if (builder.Working is { } made)
            {
                seen.Add(made);
            }
        };

        builder.Enqueue([Book("ある本.epub")]);
        await Settled(builder);

        Assert.NotEmpty(seen);
        Assert.Contains(seen, one => one.Total > 0 && one.Done > 0);
        Assert.All(seen, one => Assert.InRange(one.Fraction, 0, 1));
    }

    /// <summary>途中でやめられること。<b>作りかけは置かない。</b></summary>
    [Fact]
    public async Task 途中でやめられる()
    {
        var store = Store();
        using var builder = Open(store, new FakeEmbedder());
        builder.Enabled = true;
        var books = Enumerable.Range(0, 6).Select(at => Book($"{at} 冊目.epub")).ToList();

        builder.Enqueue(books);
        builder.Stop();
        await Settled(builder);

        Assert.Equal(0, builder.Pending);
        // 全部は作られていないこと。止まっていないなら 6 冊とも出来ている。
        Assert.True(books.Count(book => store.SizeOnDisk(book) is not null) < books.Count);
    }

    /// <summary>切ったら止まること。抱えている埋め込み器も降りる。</summary>
    [Fact]
    public async Task 切ったら止まる()
    {
        var store = Store();
        using var builder = Open(store, new FakeEmbedder());
        builder.Enabled = true;
        var books = Enumerable.Range(0, 6).Select(at => Book($"{at} 冊目.epub")).ToList();

        builder.Enqueue(books);
        builder.Enabled = false;
        await Settled(builder);

        Assert.Equal(0, builder.Pending);
        Assert.Null(builder.Working);
    }

    // MARK: 数える

    /// <summary>
    /// <b>「まだ作っていない」と「作ったが版が変わった」を分けて数える。</b>
    /// 前者は待てば済むが、後者は全量が作り直しになる。
    /// </summary>
    [Fact]
    public async Task 未作成と版違いを分けて数える()
    {
        var store = Store();
        using var builder = Open(store, new FakeEmbedder());
        builder.Enabled = true;
        var made = Book("作った本.epub");
        var notYet = Book("まだの本.epub");

        builder.Enqueue([made]);
        await Settled(builder);

        Assert.Equal(new SemanticCounts(NotBuilt: 1, Stale: 0), builder.Count([made, notYet]));

        // 別のモデルから見れば、作ってあるものは版違いになる。
        using var other = new SemanticIndexBuilder(store, () => new FakeEmbedder(), "別のモデル",
                                                   onPower: () => true);
        Assert.Equal(new SemanticCounts(NotBuilt: 1, Stale: 1), other.Count([made, notYet]));
    }

    /// <summary>読めない書籍で止まらないこと。1 冊のために残りが全部止まっては困る。</summary>
    [Fact]
    public async Task 読めない書籍があっても次へ進む()
    {
        var store = Store();
        using var builder = Open(store, new FakeEmbedder());
        builder.Enabled = true;

        var broken = Path.Combine(_root, "壊れた本.epub");
        File.WriteAllText(broken, "これは EPUB ではない");
        var good = Book("読める本.epub");

        builder.Enqueue([broken, good]);
        await Settled(builder);

        Assert.NotNull(store.SizeOnDisk(good));
        Assert.NotNull(builder.Failure);
    }
}
