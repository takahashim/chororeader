using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 紙面の検索。当たりの矩形と、索引によるページの絞り込み。
///
/// <para>
/// 矩形は飛んだ先で当たりを囲むために使う（spec.md 10.4）。
/// 座標が枠から外れていると、囲みが紙面の外に描かれて何も見えない。
/// </para>
/// </summary>
public class PdfSearchTests
{
    /// <summary>見本の PDF に必ず出る語。英語の書類なので日本語では引けない。</summary>
    private const string Needle = "page";

    [Fact]
    public void 当たりに矩形が付きページの枠に収まる()
    {
        using var document = PdfInspector.Open(TestPaths.SamplePdf);
        var hits = document.Search(Needle, 20);

        Assert.NotEmpty(hits);
        foreach (var hit in hits)
        {
            Assert.NotEmpty(hit.Rects);
            var (width, height) = document.PageSize(hit.Page);

            foreach (var rect in hit.Rects)
            {
                Assert.True(rect.X1 > rect.X0, $"幅が無い矩形: {rect}");
                Assert.True(rect.Y1 > rect.Y0, $"高さが無い矩形: {rect}");

                // 枠の左上を原点にしてあるので、負にはならず、寸法も超えない。
                // 端に触れる当たりがあるので、丸めのぶんだけ余裕を見る。
                Assert.True(rect.X0 >= -1, $"左が枠の外: {rect}");
                Assert.True(rect.Y0 >= -1, $"上が枠の外: {rect}");
                Assert.True(rect.X1 <= width + 1, $"右が枠の外: {rect}（幅 {width}）");
                Assert.True(rect.Y1 <= height + 1, $"下が枠の外: {rect}（高さ {height}）");
            }
        }
    }

    /// <summary>
    /// MuPDFCore は文字ごとに矩形を返す。「page」なら 4 個で、隙間なく隣り合っている。
    /// そのまま渡すと囲みの数が増えるうえ、1 ページあたりの上限をすぐ使い切る。
    /// </summary>
    [Fact]
    public void 同じ行の当たりは一つの矩形にまとめる()
    {
        using var document = PdfInspector.Open(TestPaths.SamplePdf);
        var hits = document.Search(Needle, 20);

        Assert.NotEmpty(hits);
        foreach (var hit in hits)
        {
            foreach (var a in hit.Rects)
            {
                foreach (var b in hit.Rects)
                {
                    if (a.Equals(b))
                    {
                        continue;
                    }
                    var sameLine = Math.Min(a.Y1, b.Y1) - Math.Max(a.Y0, b.Y0) > 0;
                    var touching = Math.Abs(a.X1 - b.X0) < 0.5 || Math.Abs(b.X1 - a.X0) < 0.5;
                    Assert.False(sameLine && touching, $"同じ行で隣り合う矩形が残っている: {a} と {b}");
                }
            }
        }
    }

    /// <summary>
    /// 描いた絵は、名乗る寸法と辻褄が合っていること。
    ///
    /// <para>
    /// 画素の並びは縦横を名乗らない。寸法を取り違えると、絵は「出るが崩れる」。
    /// 落ちてくれないぶん質が悪いので、長さで縛る。
    /// </para>
    /// </summary>
    [Theory]
    [InlineData(1.0)]
    [InlineData(1.5)]
    [InlineData(0.5)]
    public void 描いた絵の寸法と画素の数が合う(double zoom)
    {
        using var document = PdfInspector.Open(TestPaths.SamplePdf);

        for (var page = 0; page < document.PageCount; page++)
        {
            var drawn = document.RenderPage(page, zoom);

            Assert.True(drawn.Width > 0 && drawn.Height > 0, $"{page} ページ目の寸法が 0");
            // RGB は 1 画素 3 バイト。ここが合わなければ、寸法か形式のどちらかが違う。
            Assert.Equal(drawn.Stride * drawn.Height, drawn.Pixels.Length);

            // 紙面の縦横比と、描いた絵の縦横比が揃っていること。
            var (width, height) = document.PageSize(page);
            Assert.Equal(width / height, (double)drawn.Width / drawn.Height, 1);
        }
    }

    [Fact]
    public void 倍率を上げると絵も大きくなる()
    {
        using var document = PdfInspector.Open(TestPaths.SamplePdf);

        var small = document.RenderPage(0, 1.0);
        var large = document.RenderPage(0, 2.0);

        Assert.True(large.Width > small.Width, $"{small.Width} → {large.Width}");
        Assert.True(large.Height > small.Height, $"{small.Height} → {large.Height}");
    }

    [Fact]
    public void 抜粋に前後の文脈が入る()
    {
        using var document = PdfInspector.Open(TestPaths.SamplePdf);
        var hits = document.Search(Needle, 20);

        Assert.NotEmpty(hits);
        foreach (var hit in hits)
        {
            Assert.Contains(Needle, hit.Excerpt, StringComparison.OrdinalIgnoreCase);
            // 抜粋は 1 行に均す。紙面の改行をそのまま出すと一覧が崩れる。
            Assert.DoesNotContain('\n', hit.Excerpt);
        }
    }

    /// <summary>
    /// 索引はページを絞るだけで、当たりを決めない。
    /// EPUB 側（<see cref="SearchIndexTests"/>）と同じ不変条件を、紙面でも見る。
    /// </summary>
    [Fact]
    public void ページを絞っても絞らなくても同じ当たりを返す()
    {
        using var document = PdfInspector.Open(TestPaths.SamplePdf);
        var index = SearchIndex.Build(SearchUnits.OfPdf(document));

        foreach (var query in new[] { Needle, "Sample", "bookmark", "出てこない語", "z" })
        {
            var candidates = index.Candidates(query);
            var full = document.Search(query, 20);
            var narrow = document.SearchWithin(query, 20, candidates);

            Assert.Equal(
                full.Select(h => $"{h.Page}|{h.Excerpt}|{h.Rects.Count}"),
                narrow.Select(h => $"{h.Page}|{h.Excerpt}|{h.Rects.Count}"));
        }
    }

    [Fact]
    public void 索引が紙面のページを絞る()
    {
        using var document = PdfInspector.Open(TestPaths.SamplePdf);
        var index = SearchIndex.Build(SearchUnits.OfPdf(document));

        Assert.Equal(document.PageCount, index.UnitCount);

        // 出てこない語は 1 ページも残らない。開かずに 0 件と分かる。
        var none = index.Candidates("qqzzxx");
        Assert.NotNull(none);
        Assert.Empty(none);
        Assert.Empty(document.SearchWithin("qqzzxx", 20, none));
    }
}
