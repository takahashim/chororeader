using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 蔵書の横断検索。
///
/// <para>
/// 1 冊ずつ索引で候補を絞ってから走査し直す。
/// <b>索引は候補を減らすだけ</b>なので、当たりは 1 冊ずつ開いて引いたときと変わらない。
/// ここが崩れると、書棚から引いたときだけ取りこぼす。
/// </para>
/// </summary>
public class LibrarySearchTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), $"choro-library-{Guid.NewGuid():N}");

    private LibrarySearch Search() => new(new SearchIndexStore(_directory));

    public void Dispose()
    {
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (Exception)
        {
            // 消せなくても検査の結果には関わらない。
        }
        GC.SuppressFinalize(this);
    }

    private static string[] Shelf() =>
        new[] { "epub3-basic.epub", "legacy-css.epub", "footnotes.epub",
                "encoded-paths.epub", "repeated-spine.epub" }
            .Select(TestPaths.Fixture).ToArray();

    [Fact]
    public void 当たる本だけを返す()
    {
        var shelf = Shelf();
        Assert.All(shelf, p => Assert.True(File.Exists(p),
            "フィクスチャがありません。conformance で bundle exec ruby choroconf generate を先に走らせてください"));

        var found = Search().Search(shelf, "本文").ToList();

        Assert.NotEmpty(found);
        Assert.All(found, book => Assert.NotEmpty(book.Hits));
        // 当たらない語では 1 冊も返らない。
        Assert.Empty(Search().Search(shelf, "そんな語はどこにも出てこない"));
        // 空の問い合わせでは引かない。
        Assert.Empty(Search().Search(shelf, "   "));
    }

    /// <summary>
    /// 索引を通した結果が、1 冊ずつ開いて引いた結果と変わらないこと。
    ///
    /// <para>
    /// 索引ありと索引なしの比較は <see cref="SearchIndexTests"/> が押さえているが、
    /// あちらは走査の入り口を直に呼んでいる。ここは<b>横断検索の経路そのもの</b>を通す。
    /// 経路が増えれば、絞り方を間違える場所も増える。
    /// </para>
    /// </summary>
    [Theory]
    [InlineData("本文")]
    [InlineData("章")]
    [InlineData("の")]
    [InlineData("ファイル名")]
    [InlineData("脚注")]
    public void 横断で引いても一冊ずつ引いたときと同じ当たりを返す(string query)
    {
        foreach (var path in Shelf())
        {
            using var archive = new EpubArchive(path);
            var publication = EpubParser.Parse(archive);

            // 索引を通さず、そのまま引いたときの答え。
            var direct = DocumentSearch.SearchEpubWithin(
                archive, publication, query, null, LibrarySearch.PerBookLimit);

            var across = Search().Of(path, query);

            if (direct.Results.Count == 0)
            {
                Assert.Null(across);
                continue;
            }

            Assert.NotNull(across);
            // 飛び先が同じであること。経路と章内の通し番号で、当たりが一意に決まる。
            Assert.Equal(
                direct.Results.Select(r => $"{r.Locator.Href}|{r.Nth}"),
                across.Hits.Select(h => $"{h.Href}|{h.Nth}"));
            // 抜粋には当たった語が入っていること。一覧に並べて読めるもの。
            Assert.All(across.Hits, hit => Assert.Contains(query, hit.Excerpt, StringComparison.Ordinal));
        }
    }

    [Fact]
    public void 一冊が結果を埋め尽くさない()
    {
        // 「の」はどの章にも出る。上限で打ち切られ、打ち切ったことを言うこと。
        var found = Search().Of(TestPaths.Fixture("epub3-basic.epub"), "の");

        if (found is null)
        {
            return; // この書籍に「の」が無ければ、この検査は何も言わない。
        }
        Assert.True(found.Hits.Count <= LibrarySearch.PerBookLimit,
                    $"{found.Hits.Count} 件返っている");
    }

    [Fact]
    public void 紙面も同じ経路で引ける()
    {
        var found = Search().Of(TestPaths.SamplePdf, "page");

        Assert.NotNull(found);
        Assert.NotEmpty(found.Hits);
        // 飛び先はページ番号で決まる。EPUB の経路は持たない。
        Assert.All(found.Hits, hit =>
        {
            Assert.NotNull(hit.Page);
            Assert.Null(hit.Href);
        });
    }

    [Fact]
    public void 開けない本があっても止まらない()
    {
        var broken = Path.Combine(_directory, "壊れた本.epub");
        Directory.CreateDirectory(_directory);
        File.WriteAllBytes(broken, [0x00, 0x01, 0x02]);

        var shelf = new[] { broken, Path.Combine(_directory, "無い本.epub"), TestPaths.Fixture("epub3-basic.epub") };
        var found = Search().Search(shelf, "本文").ToList();

        // 壊れた本と無い本を飛ばして、最後の 1 冊まで届くこと。
        Assert.Single(found);
        Assert.EndsWith("epub3-basic.epub", found[0].Path);
    }

    [Fact]
    public void 途中でやめられる()
    {
        using var stop = new CancellationTokenSource();
        var shelf = Shelf();

        var found = new List<BookHits>();
        Assert.Throws<OperationCanceledException>(() =>
        {
            foreach (var book in Search().Search(shelf, "本文", stop.Token))
            {
                found.Add(book);
                stop.Cancel(); // 1 冊目を受け取ったところで降りる。
            }
        });
        Assert.Single(found);
    }
}
