using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 巻末の用語索引を見つける。
///
/// <para>
/// 意味の近さで引くと索引の紙面が上位に来る。語がひたすら並んでいるので何にでも少しずつ似る。
/// <b>取りこぼしよりも誤検出のほうが痛い。</b>索引でない章を落とすと、その本文が
/// 意味検索から丸ごと消えるためである。誤検出しないことを厚めに見る。
/// </para>
/// </summary>
public class BackIndexTests
{
    // MARK: 名前の見分け

    [Theory]
    [InlineData("索引")]
    [InlineData("さくいん")]
    [InlineData("用語索引")]
    [InlineData("事項索引")]
    [InlineData("Index")]
    [InlineData("INDEX")]
    [InlineData(" 索 引 ")]
    [InlineData("索　引")]
    public void 索引の名前を見分ける(string title) => Assert.True(BackIndex.IsIndexName(title));

    /// <summary>
    /// <b>完全一致で見る。</b>部分一致にすると「索引の作り方」のような節を巻き込む。
    /// </summary>
    [Theory]
    [InlineData("索引の作り方")]
    [InlineData("第 8 章 索引")]
    [InlineData("indexing")]
    [InlineData("参考文献")]
    [InlineData("")]
    public void 索引でない名前は拾わない(string title) => Assert.False(BackIndex.IsIndexName(title));

    // MARK: EPUB

    private static EpubPublication Book(int chapters, params (string Title, int At)[] toc) => new()
    {
        Title = "検査用の本",
        Authors = [],
        ReadingOrder = [.. Enumerable.Range(0, chapters)
            .Select(at => new Link($"ch{at:00}.xhtml", "application/xhtml+xml", null,
                                   new HashSet<string>()))],
        TableOfContents = [.. toc.Select(one =>
            new TocEntry(one.Title, $"ch{one.At:00}.xhtml", null, null, []))],
        Layout = PublicationLayout.Reflowable,
        Direction = ReadingDirection.Ltr,
    };

    [Fact]
    public void 目次の索引から次の項目までを外す()
    {
        // 20 章。18 章目が索引、19 章目が奥付。
        var found = BackIndex.Of(Book(20, ("第 1 章", 0), ("索引", 18), ("奥付", 19)));

        Assert.NotNull(found);
        Assert.Equal(18, found!.Value.From);
        Assert.Equal(19, found.Value.Until);
        Assert.True(found.Value.Contains(18));
        Assert.False(found.Value.Contains(19));
    }

    /// <summary>次の項目が無ければ本の末尾まで。</summary>
    [Fact]
    public void 索引の後に何も無ければ末尾まで()
    {
        var found = BackIndex.Of(Book(20, ("第 1 章", 0), ("索引", 18)));

        Assert.Equal(new BackIndex.Span(18, 20), found);
    }

    /// <summary>
    /// <b>巻末に無ければ見ない。</b>本文の途中に「索引」という節があっても触らない
    /// （データベースの索引を説明する章など）。
    /// </summary>
    [Fact]
    public void 途中の索引という章は外さない()
    {
        // 20 章の 5 章目。0.25 の位置なので 0.8 に届かない。
        Assert.Null(BackIndex.Of(Book(20, ("第 1 章", 0), ("索引", 5), ("第 7 章", 6))));
    }

    /// <summary>同じ章を指す項目が続くことがある。<b>先へ進んだ</b>最初の項目を終わりにする。</summary>
    [Fact]
    public void 同じ章を指す項目が続いても先へ進む()
    {
        var found = BackIndex.Of(Book(20, ("索引", 18), ("あ行", 18), ("か行", 18), ("奥付", 19)));

        Assert.Equal(new BackIndex.Span(18, 19), found);
    }

    [Fact]
    public void 索引が無ければ何も外さない()
    {
        Assert.Null(BackIndex.Of(Book(20, ("第 1 章", 0), ("参考文献", 18), ("奥付", 19))));
        Assert.Null(BackIndex.Of(Book(20)));
    }

    // MARK: PDF（ページごとの見出し）

    /// <summary>ページごとの見出しを組む。<paramref name="from"/> 以降が索引。</summary>
    private static string[] Titles(int pages, int from) =>
        [.. Enumerable.Range(0, pages).Select(at => at < from ? $"第 {at / 5 + 1} 章" : "索引")];

    [Fact]
    public void 見出しが索引のページを外す()
    {
        var found = BackIndex.Of(Titles(100, 90));

        Assert.Equal(new BackIndex.Span(90, 100), found);
    }

    [Fact]
    public void 索引の後に別の節があればそこまで()
    {
        var titles = Titles(100, 90);
        titles[97] = "奥付";
        titles[98] = "奥付";
        titles[99] = "奥付";

        Assert.Equal(new BackIndex.Span(90, 97), BackIndex.Of(titles));
    }

    [Fact]
    public void 途中の索引という節は外さない()
    {
        Assert.Null(BackIndex.Of(Titles(100, 30)));
    }

    [Fact]
    public void 見出しが無ければ何も外さない()
    {
        Assert.Null(BackIndex.Of(Titles(100, 100)));
        Assert.Null(BackIndex.Of([]));
    }

    // MARK: PDF（本物の紙面）

    /// <summary>
    /// 見本の PDF には索引が無い。<b>誤検出しないこと</b>を見る。
    ///
    /// <para>
    /// 索引を持つ本での当たりは手元の蔵書で測ってあるが、実在の書籍なので git には入れない。
    /// ここで確かめられるのは、持たない本を拾わないことまでである。
    /// </para>
    /// </summary>
    [Fact]
    public void 索引を持たない見本を拾わない()
    {
        using var paper = PdfInspector.Open(Path.Combine(TestPaths.Samples, "sample.pdf"));
        var titles = BackIndex.PageTitles(paper);

        Assert.Equal(paper.PageCount, titles.Count);
        Assert.Null(BackIndex.Of(paper, titles));
    }

    /// <summary>
    /// ページごとの見出しは、次の区切りまで引き継ぐ。
    /// アウトラインのページが 0 始まりであることに乗っている（PdfOutlineTests）。
    /// </summary>
    [Fact]
    public void ページごとの見出しを引き継ぐ()
    {
        using var paper = PdfInspector.Open(Path.Combine(TestPaths.Samples, "sample.pdf"));

        // 見本は 1 ページに 1 つしおりが付いているので、そのまま並ぶ。
        Assert.Equal(["Page 1", "Page 2", "Page 3", "Page 4"], BackIndex.PageTitles(paper));
    }
}
