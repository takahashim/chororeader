using System.Text;
using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 本文の配信。
///
/// <para>
/// ここは書籍が触れる面なので、<b>アーカイブの外へ出られないこと</b>が要点になる。
/// 変換（CSS 互換・印）を配信の瞬間に通すのも、元ファイルを書き換えないためである。
/// </para>
/// </summary>
public class ResourceDeliveryTests
{
    private static EpubArchive OpenFixture()
    {
        var path = TestPaths.Fixture("epub3-basic.epub");
        Assert.True(File.Exists(path),
                    "フィクスチャがありません。conformance で bundle exec ruby choroconf generate を先に走らせてください");
        return new EpubArchive(path);
    }

    private static string Text(DeliveredResource resource) => Encoding.UTF8.GetString(resource.Body);

    [Fact]
    public void 章を配れる()
    {
        using var archive = OpenFixture();
        var delivery = new ResourceDelivery(archive);

        var made = delivery.Deliver(ResourceDelivery.UrlOf("OEBPS/text/ch01.xhtml"));

        Assert.NotNull(made);
        Assert.Contains("第 1 章", Text(made));
        Assert.StartsWith("application/xhtml+xml", made.ContentType);
    }

    [Theory]
    [InlineData("../../etc/passwd")]
    [InlineData("OEBPS/text/../../../etc/passwd")]
    [InlineData("/etc/passwd")]
    [InlineData("OEBPS/text/ない章.xhtml")]
    public void 書庫に無いものは配らない(string href)
    {
        using var archive = OpenFixture();
        var delivery = new ResourceDelivery(archive);

        Assert.Null(delivery.DeliverHref(href));
    }

    /// <summary>
    /// 相対参照はここで正規化する。書籍の中の <c>../</c> を含む参照はこれで解ける。
    ///
    /// <para>
    /// 供給の範囲を守るのは <see cref="IResourceProvider"/> の役目である。
    /// 書庫は項目名の完全一致で引くので外へ出ようがなく、
    /// フォルダから配るときは <see cref="FolderResourceProvider"/> が根の外を拒む。
    /// </para>
    /// </summary>
    [Fact]
    public void 相対参照を正規化してから引く()
    {
        using var archive = OpenFixture();
        var delivery = new ResourceDelivery(archive);

        var direct = delivery.DeliverHref("OEBPS/images/cover.png");
        var relative = delivery.DeliverHref("OEBPS/text/../images/cover.png");

        Assert.NotNull(direct);
        Assert.NotNull(relative);
        Assert.Equal(direct.Body, relative.Body);
    }

    /// <summary>フォルダから配るときも、根の外は取り出せない。</summary>
    [Fact]
    public void 供給の範囲の外へは出られない()
    {
        var root = Path.Combine(Path.GetTempPath(), $"choro-deliver-{Guid.NewGuid():N}");
        Directory.CreateDirectory(Path.Combine(root, "book"));
        File.WriteAllText(Path.Combine(root, "秘密.txt"), "見えてはいけない");
        File.WriteAllText(Path.Combine(root, "book", "ch01.xhtml"), "<p>本文</p>");
        try
        {
            var delivery = new ResourceDelivery(new FolderResourceProvider(Path.Combine(root, "book")));

            Assert.NotNull(delivery.DeliverHref("ch01.xhtml"));
            Assert.Null(delivery.DeliverHref("../秘密.txt"));
            Assert.Null(delivery.Deliver(ResourceDelivery.UrlOf("../秘密.txt")));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    /// <summary>配信元が違う要求は受け取らない。横取りの網から漏れたものを掴まないため。</summary>
    [Theory]
    [InlineData("https://example.com/OEBPS/text/ch01.xhtml")]
    [InlineData("http://choro.invalid/OEBPS/text/ch01.xhtml")]
    [InlineData("file:///etc/passwd")]
    [InlineData("ちがう")]
    public void 配信元が違う要求は受け取らない(string url)
    {
        using var archive = OpenFixture();
        var delivery = new ResourceDelivery(archive);

        Assert.Null(delivery.Deliver(url));
    }

    [Fact]
    public void 経路と_URL_を往復できる()
    {
        foreach (var href in new[] { "OEBPS/text/ch01.xhtml", "OEBPS/text/第1章.xhtml", "a b/c#d.xhtml" })
        {
            Assert.Equal(href, ResourceDelivery.HrefOf(ResourceDelivery.UrlOf(href)));
        }

        // 飛び先は経路に混ざらない。
        var url = ResourceDelivery.UrlOf("OEBPS/text/ch01.xhtml", "sec1");
        Assert.Equal("OEBPS/text/ch01.xhtml", ResourceDelivery.HrefOf(url));
    }

    [Fact]
    public void 本文には_CSP_を添える()
    {
        using var archive = OpenFixture();
        var delivery = new ResourceDelivery(archive);

        var made = delivery.Deliver(ResourceDelivery.UrlOf("OEBPS/text/ch01.xhtml"));
        Assert.NotNull(made);
        Assert.Equal(ResourceDelivery.ContentSecurityPolicy, made.ContentSecurityPolicy);
    }

    /// <summary>
    /// 許し先は、経路を組み立てるのと同じところから取る。
    /// Tauri 版は別に書いていて、Windows でだけ何にも当たらなかった。
    /// </summary>
    [Fact]
    public void CSP_の許し先は本文の配信元と揃っている()
    {
        var policy = ResourceDelivery.ContentSecurityPolicy;

        Assert.Contains($"img-src {ResourceDelivery.Origin}", policy);
        Assert.Contains($"style-src 'unsafe-inline' {ResourceDelivery.Origin}", policy);
        Assert.Contains($"font-src {ResourceDelivery.Origin}", policy);
        // 外へ出る道は塞ぐ。読書時にネットワークを使わない不変条件（spec.md 2.2）。
        Assert.Contains("default-src 'none'", policy);
        Assert.Contains("connect-src 'none'", policy);
        Assert.Contains("form-action 'none'", policy);
        Assert.Contains("base-uri 'none'", policy);
    }

    [Fact]
    public void CSS_は配るときに書き換える()
    {
        using var archive = new EpubArchive(TestPaths.Fixture("legacy-css.epub"));
        var delivery = new ResourceDelivery(archive);

        var made = delivery.DeliverHref("OEBPS/style/book.css");
        Assert.NotNull(made);
        Assert.StartsWith("text/css", made.ContentType);

        var css = Text(made);
        Assert.Contains("writing-mode: vertical-rl", css);
        Assert.DoesNotContain("-epub-writing-mode: vertical-rl", css);
        Assert.Contains("text-combine-upright: all", css);

        // コメントと文字列リテラルの中は変えない（spec.md 6 章）。
        Assert.Contains("/* -epub-writing-mode はコメントなので変えない */", css);
        Assert.Contains("""content: "-epub-hyphens: auto";""", css);

        // 何を変えたかは切り分けのために控える。
        Assert.NotEmpty(delivery.CssChangeLog);
        Assert.All(delivery.CssChangeLog, line => Assert.Contains("OEBPS/style/book.css", line));
    }

    /// <summary>
    /// 印は配信の瞬間に入れる。WebView の中で入れると、文字節を切って包む手術を
    /// JavaScript で書くことになり、抽出と数え方がずれる余地が残る。
    /// </summary>
    [Fact]
    public void 印は配るときに入れる()
    {
        using var archive = OpenFixture();
        var delivery = new ResourceDelivery(archive);
        const string Href = "OEBPS/text/ch01.xhtml";

        Assert.DoesNotContain(Mark.ClassName, Text(delivery.DeliverHref(Href)!));

        delivery.SearchMark = ("本文", 0);
        Assert.Contains(Mark.ClassName, Text(delivery.DeliverHref(Href)!));

        // 外せば元に戻る。覚えていたものを返してしまわないこと。
        delivery.SearchMark = null;
        Assert.DoesNotContain(Mark.ClassName, Text(delivery.DeliverHref(Href)!));
    }

    [Fact]
    public void 覚えていても印の付き方ごとに別のものを返す()
    {
        using var archive = OpenFixture();
        var delivery = new ResourceDelivery(archive);
        const string Href = "OEBPS/text/ch01.xhtml";

        delivery.SearchMark = ("本文", 0);
        var first = Text(delivery.DeliverHref(Href)!);
        delivery.SearchMark = ("章", 0);
        var second = Text(delivery.DeliverHref(Href)!);

        Assert.NotEqual(first, second);
    }

    [Fact]
    public void 覚えるのは文字のものだけ()
    {
        using var archive = OpenFixture();
        var delivery = new ResourceDelivery(archive);

        // 画像を溜め込むとメモリを圧迫するので、覚えない。
        Assert.NotNull(delivery.DeliverHref("OEBPS/images/cover.png"));
        Assert.Equal(0, delivery.CachedByteCount);

        Assert.NotNull(delivery.DeliverHref("OEBPS/text/ch01.xhtml"));
        Assert.True(delivery.CachedByteCount > 0);
    }

    /// <summary>
    /// 抜粋を、書籍内リソースと同じ経路で配れるようにする。
    /// 対象と同じ階層へ置くことで、抜粋に含まれる相対参照がそのまま解決される。
    /// </summary>
    [Fact]
    public void 組み立てた抜粋も同じ経路で配れる()
    {
        using var archive = OpenFixture();
        var delivery = new ResourceDelivery(archive);
        const string Path = "OEBPS/text/__choro_preview__.xhtml";

        Assert.Null(delivery.DeliverHref(Path));

        delivery.ProvideSynthetic(Path, "<p>抜粋の中身</p>");
        var made = delivery.DeliverHref(Path);

        Assert.NotNull(made);
        Assert.Contains("抜粋の中身", Text(made));
        // 書籍から切り出した断片は名前空間が欠けていることがある。寛容な HTML パーサへ渡す。
        Assert.StartsWith("text/html", made.ContentType);
    }

    /// <summary>
    /// XHTML として渡すのは、そう名乗っている文書だけにする。
    /// HTML5 でも XML として妥当なことはあり、XHTML として解釈させると
    /// 名前空間が付かず、style の中身が本文として表示されてしまう。
    /// </summary>
    [Fact]
    public void 名乗っていない文書は_HTML_として配る()
    {
        var provider = new FolderResourceProvider(Path.GetTempPath());
        provider.ProvideSynthetic("plain.html",
                                  "<html><head><style>p{}</style></head><body><p>本文</p></body></html>"u8.ToArray());
        provider.ProvideSynthetic("broken.xhtml", "<html><body><p>閉じていない</body></html>"u8.ToArray());
        provider.ProvideSynthetic("proper.xhtml",
                                  """<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><p>本文</p></body></html>"""u8.ToArray());
        var delivery = new ResourceDelivery(provider);

        Assert.StartsWith("text/html", delivery.DeliverHref("plain.html")!.ContentType);
        // 拡張子が名乗っていても、XML として読めなければ HTML へ倒す。
        Assert.StartsWith("text/html", delivery.DeliverHref("broken.xhtml")!.ContentType);
        Assert.StartsWith("application/xhtml+xml", delivery.DeliverHref("proper.xhtml")!.ContentType);
    }
}
