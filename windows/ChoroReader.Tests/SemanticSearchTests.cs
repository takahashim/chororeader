using System.IO.Compression;
using ChoroReader.Core;
using ChoroReader.Semantic;

namespace ChoroReader.Tests;

/// <summary>
/// 蔵書を横断して意味で引く。
///
/// <para>
/// 偽の埋め込み器は<b>文字の出方から向きを決める</b>ので、意味を持っていない。
/// ここで確かめられるのは順位の良し悪しではなく、<b>配管</b>である
/// （spec-local-ai.md 8 の 1 段目）。
/// </para>
/// <para>
/// とりわけ、<b>本文は索引に控えていない</b>ので原書から切り出せていること、
/// <b>1 冊ずつ捨てられる</b>形で読んでいること、
/// 飛び先が読書の窓で解ける形で出ていることを見る。
/// </para>
/// </summary>
public class SemanticSearchTests : IDisposable
{
    private const string Model = "ruri-v3-130m";

    private readonly string _root =
        Path.Combine(Path.GetTempPath(), $"choro-search-{Guid.NewGuid():N}");

    public SemanticSearchTests() => Directory.CreateDirectory(_root);

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
    /// 本文を差し替えた EPUB を 1 冊置く。中身は架空で、実在の書籍からは取っていない。
    /// </summary>
    private string Book(string name, string body)
    {
        var where = Path.Combine(_root, name);
        File.Copy(Path.Combine(TestPaths.Samples, "sample-reflowable.epub"), where, overwrite: true);
        using (var zip = ZipFile.Open(where, ZipArchiveMode.Update))
        {
            for (var at = 1; at <= 3; at++)
            {
                var path = $"OEBPS/text/ch{at:00}.xhtml";
                zip.GetEntry(path)?.Delete();
                using var writer = new StreamWriter(zip.CreateEntry(path).Open());
                writer.Write($"""
                    <?xml version="1.0" encoding="UTF-8"?>
                    <html xmlns="http://www.w3.org/1999/xhtml"><body>
                    <h1 id="s{at}">第 {at} 節</h1>
                    <p>{string.Concat(Enumerable.Repeat($"{body}第 {at} 節の説明である。", 12))}</p>
                    </body></html>
                    """);
            }
        }
        return where;
    }

    private (SemanticIndexStore Store, List<(string Path, string Title)> Books) Shelf()
    {
        var store = new SemanticIndexStore(Path.Combine(_root, "semantic"));
        var embedder = new FakeEmbedder(dimension: 16);
        var books = new List<(string, string)>();

        foreach (var (name, body) in new[]
                 {
                     ("あいうえの本.epub", "あいうえお。"),
                     ("かきくけの本.epub", "かきくけこ。"),
                 })
        {
            var path = Book(name, body);
            var pieces = SemanticUnits.OfEpub(new EpubArchive(path), Publication(path));
            Assert.NotEmpty(pieces);
            store.Build(path, pieces, embedder, Model);
            books.Add((path, Path.GetFileNameWithoutExtension(path)));
        }
        return (store, books);
    }

    private static EpubPublication Publication(string path)
    {
        using var archive = new EpubArchive(path);
        return EpubParser.Parse(archive);
    }

    private static float[] Ask(string text) =>
        new FakeEmbedder(dimension: 16).Embed(text, EmbeddingKind.Query).Vector;

    // MARK: 引く

    [Fact]
    public void 蔵書を横断して引ける()
    {
        var (store, books) = Shelf();
        var search = new SemanticSearch(store, Model);

        var found = search.Run(Ask("あいうえお"), books);

        Assert.NotEmpty(found);
        Assert.All(found, one => Assert.Contains(books, book => book.Path == one.BookPath));
        // 近い順に並ぶこと。
        Assert.Equal(found.Select(one => one.Score).OrderByDescending(s => s), found.Select(one => one.Score));
    }

    /// <summary>
    /// <b>本文は索引に控えていない。</b>原書から切り出せていること。
    /// ここが切れていると、一覧に何も出ないまま順位だけが正しい状態になる。
    /// </summary>
    [Fact]
    public void 本文を原書から切り出す()
    {
        var (store, books) = Shelf();

        var found = new SemanticSearch(store, Model).Run(Ask("あいうえお"), books);

        Assert.All(found, one => Assert.NotEmpty(one.Text));
        // 切り出した本文が、その書籍に実際にある文であること。
        var top = found[0];
        using var archive = new EpubArchive(top.BookPath);
        var whole = string.Concat(SearchUnits.OfEpub(archive, Publication(top.BookPath)));
        Assert.Contains(top.Text.TrimEnd('…')[..20], whole);
    }

    /// <summary>飛び先が、読書の窓で解ける形で出ていること。表題は見出しから埋まる。</summary>
    [Fact]
    public void 飛び先と見出しが出る()
    {
        var (store, books) = Shelf();

        var found = new SemanticSearch(store, Model).Run(Ask("あいうえお"), books);

        Assert.All(found, one =>
        {
            Assert.NotNull(one.Target.Href);
            Assert.InRange(one.Target.Progression, 0, 1);
            Assert.NotEmpty(one.Heading);
            Assert.Equal(one.Heading, one.Target.Title);
        });
    }

    /// <summary>上限まで。多く採っても、冊をまたいだ上位には残らない。</summary>
    [Fact]
    public void 上限まで返す()
    {
        var (store, books) = Shelf();
        var search = new SemanticSearch(store, Model);

        Assert.Equal(2, search.Run(Ask("あいうえお"), books, limit: 2).Count);
        Assert.Empty(search.Run(Ask("あいうえお"), books, limit: 0));
    }

    /// <summary>
    /// <b>同じ問いには同じ並びを返す。</b>辞書や集合の並び順に任せると、
    /// 引き直すたびに順が入れ替わる。
    /// </summary>
    [Fact]
    public void 同じ問いには同じ並びを返す()
    {
        var (store, books) = Shelf();
        var search = new SemanticSearch(store, Model);

        var first = search.Run(Ask("あいうえお"), books);
        for (var again = 0; again < 3; again++)
        {
            Assert.Equal(first.Select(one => (one.BookPath, one.Target.Href, one.Target.Progression)),
                         search.Run(Ask("あいうえお"), books)
                               .Select(one => (one.BookPath, one.Target.Href, one.Target.Progression)));
        }
    }

    // MARK: 索引の無いもの

    /// <summary>索引の無い書籍は黙って飛ばす。作っていないだけで、落ちる話ではない。</summary>
    [Fact]
    public void 索引の無い書籍は飛ばす()
    {
        var (store, books) = Shelf();
        var without = Book("索引の無い本.epub", "さしすせそ。");
        books.Add((without, "索引の無い本"));

        var found = new SemanticSearch(store, Model).Run(Ask("あいうえお"), books);

        Assert.NotEmpty(found);
        Assert.DoesNotContain(found, one => one.BookPath == without);
    }

    /// <summary>モデルが違えば使わない。古いベクトルで引くと、順位だけが静かに狂う。</summary>
    [Fact]
    public void モデルが違えば引かない()
    {
        var (store, books) = Shelf();

        Assert.Empty(new SemanticSearch(store, "別のモデル").Run(Ask("あいうえお"), books));
    }

    /// <summary>長さの違う問いでは引かない。次元の違うモデルを混ぜたときに黙って通さない。</summary>
    [Fact]
    public void 長さの違う問いでは引かない()
    {
        var (store, books) = Shelf();

        Assert.Empty(new SemanticSearch(store, Model).Run(new float[8], books));
    }

    [Fact]
    public void 蔵書が空なら何も返さない()
    {
        var (store, _) = Shelf();

        Assert.Empty(new SemanticSearch(store, Model).Run(Ask("あいうえお"), []));
    }
}
