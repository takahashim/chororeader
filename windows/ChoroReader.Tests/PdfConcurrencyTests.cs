using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 1 つの PDF を複数のスレッドから使う。
///
/// 描画は時間がかかるので背後のスレッドへ回すことになり、そのあいだに検索も走る。
/// MuPDF の context は例外スタックとリソースキャッシュを抱えていて、同時に触ると壊れる。
///
/// 直列化していなかったころ、この検査は
/// 「found duplicate pdf_obj in the store」「array not closed before end of file」を出し、
/// プロセスごと落ちることもあった。
/// **落ちずに壊れた値を返すほうが多い**ので、例外の有無だけでなく値まで見る。
/// </summary>
public class PdfConcurrencyTests
{
    private const int Threads = 8;
    private const int Rounds = 40;

    [Fact]
    public void 並行に読んでも直列に読んだときと同じ値を返す()
    {
        using var document = PdfInspector.Open(TestPaths.SamplePdf);
        Assert.True(document.PageCount > 0, "見本の PDF が読めていない");

        // 先に 1 つずつ読んで、正しい答えを控える。
        var expectedText = Enumerable.Range(0, document.PageCount)
            .Select(document.TextOfPage).ToArray();
        var expectedSize = Enumerable.Range(0, document.PageCount)
            .Select(document.PageSize).ToArray();
        var expectedHits = document.Search("の", 5);

        var mistakes = new System.Collections.Concurrent.ConcurrentBag<string>();

        Parallel.For(0, Threads, worker =>
        {
            for (var round = 0; round < Rounds; round++)
            {
                var page = round % document.PageCount;
                try
                {
                    switch (worker % 4)
                    {
                        case 0:
                            if (document.TextOfPage(page) != expectedText[page])
                            {
                                mistakes.Add($"{page} ページ目の本文が変わった");
                            }
                            break;

                        case 1:
                            var hits = document.Search("の", 5);
                            if (hits.Count != expectedHits.Count)
                            {
                                mistakes.Add($"検索の件数が {expectedHits.Count} から {hits.Count} へ変わった");
                            }
                            break;

                        case 2:
                            // 描いた絵の中身までは見ない。長さが 0 なら描けていない。
                            if (document.RenderPage(page, 1.0).Length == 0)
                            {
                                mistakes.Add($"{page} ページ目が描けなかった");
                            }
                            break;

                        default:
                            if (document.PageSize(page) != expectedSize[page])
                            {
                                mistakes.Add($"{page} ページ目の寸法が変わった");
                            }
                            break;
                    }
                }
                catch (Exception e)
                {
                    mistakes.Add($"{e.GetType().Name}: {e.Message.Split('\n')[0]}");
                }
            }
        });

        Assert.True(mistakes.IsEmpty, string.Join("\n", mistakes.Distinct().Take(10)));
    }

    /// <summary>
    /// 閉じたあとに触ると、解放済みのネイティブメモリを読むことになる。
    /// 落ちる前に、こちらの誤りとして知らせる。
    /// </summary>
    [Fact]
    public void 閉じたあとに使うとその場で知らせる()
    {
        var document = PdfInspector.Open(TestPaths.SamplePdf);
        document.Dispose();

        Assert.Throws<ObjectDisposedException>(() => document.TextOfPage(0));
        Assert.Throws<ObjectDisposedException>(() => document.Search("の", 1));
        Assert.Throws<ObjectDisposedException>(() => document.RenderPage(0, 1.0));

        // 二度閉じても落ちない。
        document.Dispose();
    }

    /// <summary>
    /// 検索は遅延させない。遅延させると、MuPDF に触るのが呼び出し側の反復のときになり、
    /// 直列化の鍵が外れたところで走ることになる。
    /// </summary>
    [Fact]
    public void 検索は呼んだ時点で数え切っている()
    {
        using var document = PdfInspector.Open(TestPaths.SamplePdf);
        var hits = document.Search("の", 5);

        // 数え切った列は、閉じたあとでも辿れる。遅延していれば、ここで落ちる。
        document.Dispose();
        var pages = hits.Select(hit => hit.Page).ToList();
        Assert.Equal(hits.Count, pages.Count);
    }
}
