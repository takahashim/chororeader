using System.Text;
using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 書籍を段落に切る。
///
/// <para>
/// ここが崩れると意味の索引がまるごと的外れになる。しかも<b>気付きにくい</b>。
/// 順位が少し悪いのか、切り方が壊れているのかは、結果を眺めても見分けが付かない。
/// </para>
/// </summary>
public class SemanticUnitsTests
{
    /// <summary>本文を作る。区切りが要るので句点で終える。</summary>
    private static string Sentences(string body, int times) =>
        string.Concat(Enumerable.Repeat(body + "。", times));

    /// <summary>好きな中身を返す供給元。書籍を作らずに切り出しを試せる。</summary>
    private sealed class Pages : IResourceProvider
    {
        private readonly Dictionary<string, byte[]> _pages = [];

        internal Pages Put(string href, string html)
        {
            _pages[href] = Encoding.UTF8.GetBytes(html);
            return this;
        }

        public bool Contains(string path) => _pages.ContainsKey(path);

        public byte[] Read(string path) => _pages.TryGetValue(path, out var found)
            ? found
            : throw new FileNotFoundException(path);
    }

    private static EpubPublication Book(params string[] hrefs) => new()
    {
        Title = "検査用の本",
        Authors = [],
        ReadingOrder = [.. hrefs.Select(h => new Link(h, "application/xhtml+xml", null, new HashSet<string>()))],
        TableOfContents = [],
        Layout = PublicationLayout.Reflowable,
        Direction = ReadingDirection.Ltr,
    };

    // MARK: 段落に切る

    [Fact]
    public void 狙いの長さで段落に切る()
    {
        // 「あ」20 字＋句点で 21 字。40 文で 840 字ぶん。
        var html = $"<html><body><p>{Sentences(new string('あ', 20), 40)}</p></body></html>";
        var pieces = SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml"));

        Assert.True(pieces.Count >= 2, $"{pieces.Count} 個しか出ていない");
        // 狙いは 400 字。区切りで詰めるので少し超えるが、上限の 800 は越えない。
        foreach (var piece in pieces)
        {
            Assert.InRange(piece.Text.Length, SemanticUnits.DefaultLeastCharacters, 800);
        }
    }

    /// <summary>
    /// <b>短い切れ端は独り立ちさせない。</b>1 文だけの段落を単位にすると、
    /// 文脈の無いベクトルが索引を埋める。
    /// </summary>
    [Fact]
    public void 短すぎる本文は切り出さない()
    {
        var html = "<html><body><p>短い。</p></body></html>";

        Assert.Empty(SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml")));
    }

    /// <summary>端数は前の段落に足す。捨てない。</summary>
    [Fact]
    public void 端数は前の段落に足す()
    {
        // 420 字ぶん（1 つ目の段落）＋ 42 字ぶん（端数）。
        var html = $"<html><body><p>{Sentences(new string('あ', 20), 20)}{Sentences(new string('い', 20), 2)}</p></body></html>";
        var pieces = SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml"));

        Assert.Single(pieces);
        // 端数の「い」が捨てられていないこと。
        Assert.Contains("い", pieces[0].Text);
    }

    // MARK: 見出し

    [Fact]
    public void 見出しで節に割り_見出しを各段落に添える()
    {
        var body = Sentences(new string('あ', 20), 25);
        var other = Sentences(new string('い', 20), 25);
        var html = $"""
            <html><body>
            <h1 id="first">はじめの節</h1><p>{body}</p>
            <h2 id="second">つぎの節</h2><p>{other}</p>
            </body></html>
            """;
        var pieces = SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml"));

        Assert.Contains(pieces, p => p.Unit.Heading == "はじめの節");
        Assert.Contains(pieces, p => p.Unit.Heading == "つぎの節");

        // 節が違えば通し番号も違う。順位は節で決めるので、ここが潰れると効かない。
        Assert.True(pieces.Select(p => p.Unit.Section).Distinct().Count() >= 2);

        // **見出しの札そのものは本文に含めない。** 見出しは別に持っているので二重になる。
        Assert.All(pieces, p => Assert.DoesNotContain("はじめの節", p.Text));
    }

    /// <summary>節の頭の段落は見出しの id へ飛ばす。途中の段落は本文で探す。</summary>
    [Fact]
    public void 節の頭の段落だけ見出しのidへ飛ばす()
    {
        var html = $"""
            <html><body><h1 id="first">節</h1><p>{Sentences(new string('あ', 20), 45)}</p></body></html>
            """;
        var pieces = SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml"));

        Assert.True(pieces.Count >= 2, $"{pieces.Count} 個しか出ていない");
        Assert.Equal("first", pieces[0].Unit.Locator.Fragment);
        Assert.All(pieces.Skip(1), p => Assert.Null(p.Unit.Locator.Fragment));
    }

    /// <summary>最初の見出しより前の本文（前書きなど）を捨てない。</summary>
    [Fact]
    public void 見出しより前の本文も拾う()
    {
        var html = $"""
            <html><body><p>{Sentences(new string('ま', 20), 25)}</p>
            <h1>節</h1><p>{Sentences(new string('あ', 20), 25)}</p></body></html>
            """;
        var pieces = SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml"));

        Assert.Contains(pieces, p => p.Unit.Heading.Length == 0 && p.Text.Contains('ま'));
    }

    // MARK: 飛び先

    [Fact]
    public void 章の中の位置は順に進む()
    {
        var html = $"<html><body><p>{Sentences(new string('あ', 20), 60)}</p></body></html>";
        var pieces = SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml"));

        var places = pieces.Select(p => p.Unit.Locator.Progression).ToList();
        Assert.Equal(places, places.Order());
        Assert.Equal(0, places[0]);
        Assert.All(places, at => Assert.InRange(at, 0, 1));
    }

    /// <summary>
    /// 目印は本文の頭 30 字。<b>長いほど外れやすい</b>ので、それ以上は載せない。
    /// </summary>
    [Fact]
    public void 目印は頭の30字()
    {
        var html = $"<html><body><p>{Sentences(new string('あ', 20), 30)}</p></body></html>";
        var pieces = SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml"));

        var anchor = pieces[0].Unit.Locator.Text;
        Assert.NotNull(anchor);
        Assert.Equal(30, anchor!.Length);
        Assert.StartsWith(anchor, pieces[0].Text);
    }

    /// <summary>
    /// 目印は<b>符号単位で切らない</b>。上位・下位の片割れだけを残すと、壊れた文字で始まる。
    /// </summary>
    [Fact]
    public void 目印は文字の途中で切らない()
    {
        // 「𩸽」は 2 符号単位。30 個並べると、符号単位で切れば 15 文字目で割れる。
        var html = $"<html><body><p>{Sentences(string.Concat(Enumerable.Repeat("𩸽", 20)), 30)}</p></body></html>";
        var pieces = SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml"));

        var anchor = pieces[0].Unit.Locator.Text!;
        Assert.DoesNotContain(anchor, c => char.IsHighSurrogate(c) && anchor.IndexOf(c) == anchor.Length - 1);
        Assert.Equal(30, anchor.EnumerateRunes().Count());
        Assert.StartsWith(anchor, pieces[0].Text);
    }

    /// <summary>本文が短ければ目印を載せない。当たらない目印で寄せると却って外れる。</summary>
    [Fact]
    public void 短い本文には目印を載せない()
    {
        var html = $"<html><body><p>あい。{Sentences(new string('う', 20), 20)}</p></body></html>";
        var pieces = SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml"));

        Assert.NotNull(pieces[0].Unit.Locator.Text);   // ここは長いので載る
        Assert.True(pieces[0].Unit.Locator.Text!.Length >= 8);
    }

    // MARK: 巻末の索引

    /// <summary>
    /// <b>巻末の索引は載せない。</b>語がひたすら並ぶ紙面は何にでも少しずつ似てしまい、
    /// 意味検索の上位を埋める。
    /// </summary>
    [Fact]
    public void 巻末の索引は切り出さない()
    {
        var pages = new Pages();
        var hrefs = new List<string>();
        for (var at = 0; at < 20; at++)
        {
            var href = $"ch{at:00}.xhtml";
            hrefs.Add(href);
            var mark = at == 18 ? 'さ' : 'ほ';
            pages.Put(href, $"<html><body><p>{Sentences(new string(mark, 20), 25)}</p></body></html>");
        }

        var book = new EpubPublication
        {
            Title = "索引のある本",
            Authors = [],
            ReadingOrder = [.. hrefs.Select(h => new Link(h, "application/xhtml+xml", null, new HashSet<string>()))],
            TableOfContents = [
                new TocEntry("第 1 章", "ch00.xhtml", null, null, []),
                new TocEntry("索引", "ch18.xhtml", null, null, []),
                new TocEntry("奥付", "ch19.xhtml", null, null, [])],
            Layout = PublicationLayout.Reflowable,
            Direction = ReadingDirection.Ltr,
        };

        var pieces = SemanticUnits.OfEpub(pages, book);

        Assert.NotEmpty(pieces);
        Assert.DoesNotContain(pieces, p => p.Unit.Locator.Href == "ch18.xhtml");
        // 奥付は索引ではない。落とし過ぎていないこと。
        Assert.Contains(pieces, p => p.Unit.Locator.Href == "ch19.xhtml");
    }

    // MARK: PDF

    [Fact]
    public void 紙面はページごとに切る()
    {
        using var paper = PdfInspector.Open(Path.Combine(TestPaths.Samples, "sample.pdf"));
        var pieces = SemanticUnits.OfPdf(paper, leastCharacters: 20);

        Assert.NotEmpty(pieces);
        Assert.All(pieces, p =>
        {
            Assert.NotNull(p.Unit.Locator.Page);
            Assert.Null(p.Unit.Locator.Href);
            Assert.InRange(p.Unit.Locator.Page!.Value, 0, paper.PageCount - 1);
        });

        // 見出しはアウトラインから引く。ページごとに違う見本なので、そのまま並ぶ。
        Assert.Contains(pieces, p => p.Unit.Heading == "Page 1");
    }

    /// <summary>移動に渡す飛び先には、見出しが表題として入る。</summary>
    [Fact]
    public void 飛び先の表題は見出しから埋める()
    {
        var html = $"""
            <html><body><h1>節の名</h1><p>{Sentences(new string('あ', 20), 25)}</p></body></html>
            """;
        var pieces = SemanticUnits.OfEpub(new Pages().Put("ch01.xhtml", html), Book("ch01.xhtml"));

        Assert.Equal("節の名", pieces[0].Unit.Target.Title);
        Assert.Null(pieces[0].Unit.Locator.Title);
    }
}
