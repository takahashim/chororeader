using System.Diagnostics;
using TZReader.Core;

namespace TZReader.Probe;

/// <summary>
/// MuPDF が Windows 実装の要求を満たすかを確かめる。
/// 見るのは、開けること、ページ数、目次、テキスト層、検索、描画の速さ。
/// </summary>
internal static class PdfSpike
{
    internal static int Run(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: tzprobe pdfspike <pdf> [検索語]");
            return 2;
        }

        var path = args[0];
        var needle = args.Length > 1 ? args[1] : "型";

        // 1 回目にはネイティブライブラリの読み込みが混ざる。2 回目が実際の 1 冊あたりの費用。
        var first = Stopwatch.StartNew();
        using (var warm = PdfInspector.Open(path))
        {
            _ = warm.PageCount;
        }
        first.Stop();

        var opened = Stopwatch.StartNew();
        using var document = PdfInspector.Open(path);
        var pageCount = document.PageCount;
        opened.Stop();
        Console.WriteLine($"開く: 1 回目 {first.ElapsedMilliseconds} ms / 2 回目 {opened.ElapsedMilliseconds} ms  ページ数: {pageCount}");
        Console.WriteLine($"テキスト層: {(document.HasTextLayer ? "あり" : "なし")}");

        var outline = document.Outline();
        Console.WriteLine($"目次: {CountEntries(outline)} 項目（第 1 階層 {outline.Count}）");
        PrintOutline(outline, 0, 8);

        var textTimer = Stopwatch.StartNew();
        var sample = document.TextOfPage(Math.Min(10, document.PageCount - 1));
        textTimer.Stop();
        var oneLine = sample.Replace("\n", " ").Trim();
        Console.WriteLine($"本文抽出: {textTimer.ElapsedMilliseconds} ms  {oneLine[..Math.Min(90, oneLine.Length)]}");

        var searchTimer = Stopwatch.StartNew();
        var hits = document.Search(needle, 20).ToList();
        searchTimer.Stop();
        Console.WriteLine($"検索「{needle}」: {hits.Count} 件（上限 20）{searchTimer.ElapsedMilliseconds} ms");
        foreach (var (page, text) in hits.Take(3))
        {
            Console.WriteLine($"   p.{page + 1}: {text}");
        }

        var renderTimer = Stopwatch.StartNew();
        var pixels = document.RenderPage(0, 1.5);
        renderTimer.Stop();
        var size = document.PageSize(0);
        Console.WriteLine($"描画: {renderTimer.ElapsedMilliseconds} ms  {pixels.Length} バイト  " +
                          $"ページ寸法 {size.Width:F0}x{size.Height:F0}");

        return 0;
    }

    private static int CountEntries(IReadOnlyList<TocEntry> entries) =>
        entries.Sum(e => 1 + CountEntries(e.Children));

    private static void PrintOutline(IReadOnlyList<TocEntry> entries, int depth, int remaining)
    {
        foreach (var entry in entries)
        {
            if (remaining <= 0)
            {
                return;
            }
            Console.WriteLine($"   {new string(' ', depth * 2)}{entry.Title}  [p.{entry.Page + 1}]");
            remaining--;
            PrintOutline(entry.Children, depth + 1, remaining);
        }
    }
}
