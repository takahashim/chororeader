using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// アウトライン（PDF のしおり）が名乗るページ番号の基準。
///
/// <para>
/// <b>MuPDFCore は文書に基準を書いていない。</b>1 始まりだと思って引くと、
/// 目次から飛ぶたびに 1 ページ手前へ着く。実際そう書いて間違えた。
/// 目で見て気付けない類の食い違いなので、ここに留めておく。
/// </para>
/// <para>
/// 使う側は <c>ChoroReader.App</c> の <c>PdfStage</c> と
/// <see cref="ChoroReader.Core.BackIndex"/>。どちらも Windows でしか動かせない、
/// あるいは画面に出るものなので、基準そのものはここで押さえる。
/// </para>
/// </summary>
public class PdfOutlineTests
{
    private static string SamplePdf => Path.Combine(TestPaths.Samples, "sample.pdf");

    /// <summary>
    /// 見本の PDF は 4 ページで、しおりが 1 ページに 1 つ付いている。
    /// 名前は「Page 1」…「Page 4」で、指す先はそれぞれ 1 枚目…4 枚目である。
    /// </summary>
    [Fact]
    public void アウトラインのページは0始まり()
    {
        using var paper = PdfInspector.Open(SamplePdf);
        var outline = paper.Outline();

        Assert.Equal(paper.PageCount, outline.Count);
        Assert.Equal(4, paper.PageCount);

        // 「Page 1」が指すのは 0 枚目。1 始まりならここが 1 になる。
        Assert.Equal([0, 1, 2, 3], outline.Select(entry => entry.Page).ToArray());

        // 名前と突き合わせる。番号だけ見ていると、並びが逆でも通ってしまう。
        Assert.Equal(["Page 1", "Page 2", "Page 3", "Page 4"],
                     outline.Select(entry => entry.Title).ToArray());

        // 指した先の紙面に、その名前が書いてある。
        for (var at = 0; at < outline.Count; at++)
        {
            Assert.Contains($"Page {at + 1}", paper.TextOfPage(outline[at].Page ?? -1));
        }
    }
}
