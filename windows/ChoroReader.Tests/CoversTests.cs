using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 書棚に並べる表紙のもと。
///
/// <para>
/// 復号と縮小は画面側の仕事なので、ここで見るのは<b>どこから何を取るか</b>だけである。
/// </para>
/// </summary>
public class CoversTests
{
    private static string Where(string name) => Path.Combine(TestPaths.Samples, name);

    [Fact]
    public void EPUBは_OPFが指す表紙を返す()
    {
        var cover = Assert.IsType<EncodedCover>(Covers.Of(Where("sample-reflowable.epub")));

        Assert.Equal("OEBPS/images/cover.png", cover.Href);
        Assert.NotEmpty(cover.Bytes);

        // 書籍に入っているものをそのまま渡す。加工しない。
        using var archive = new EpubArchive(Where("sample-reflowable.epub"));
        Assert.Equal(archive.Read("OEBPS/images/cover.png"), cover.Bytes);
    }

    [Fact]
    public void PDFは_1ページ目を描いて返す()
    {
        var cover = Assert.IsType<PixelCover>(Covers.Of(Where("sample.pdf")));

        Assert.True(cover.Page.Width > 0 && cover.Page.Height > 0);
        Assert.Equal(cover.Page.Height * cover.Page.Stride, cover.Page.Pixels.Length);
    }

    /// <summary>
    /// <b>原寸で描いてから縮めない。</b>数百ページの書籍を並べるので、
    /// 1 冊ごとに全画素を起こすと書棚が固まる。
    /// </summary>
    [Fact]
    public void PDFの表紙は升目に収まる大きさで描く()
    {
        var cover = Assert.IsType<PixelCover>(Covers.Of(Where("sample.pdf")));

        Assert.True(Math.Max(cover.Page.Width, cover.Page.Height) <= Covers.MaxPixel,
                    $"{cover.Page.Width}x{cover.Page.Height} は升目に大きい");

        // 縮めた結果 1 画素になってしまっては表紙にならない。
        Assert.True(Math.Max(cover.Page.Width, cover.Page.Height) > 1);
    }

    /// <summary>
    /// 表紙を持たない書籍も、開けない書籍もある。
    /// 表紙が取れないことは<b>書棚が並ばない理由にならない</b>ので、失敗は失敗のまま返す。
    /// </summary>
    [Fact]
    public void 取れないときは何も返さない()
    {
        Assert.Null(Covers.Of(Path.Combine(TestPaths.Samples, "そんな本はありません.epub")));

        var broken = Path.Combine(Path.GetTempPath(), $"choro-broken-{Guid.NewGuid():N}.pdf");
        File.WriteAllText(broken, "これは PDF ではない");
        try
        {
            Assert.Null(Covers.Of(broken));
        }
        finally
        {
            File.Delete(broken);
        }
    }
}
