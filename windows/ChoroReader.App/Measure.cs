using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ChoroReader.Core;
using ChoroReader.Semantic;

namespace ChoroReader.App;

/// <summary>
/// 意味の層の速さを実機で測る。
///
/// <para>
/// <b>速さだけは開発機では分からない。</b>正しさは macOS で固めてある
/// （spikes/findings-csharp-embedder.md）が、1 段落あたりの推論時間と 1 冊あたりの
/// 索引づくりは機械で変わる。実機で測るためのものをここに置く。
/// </para>
/// <para>
/// 比べる相手は macOS 版の実測である（段落単位で <b>1 冊 6.4 秒</b>、
/// 1 段落の中央 11.8 ms、技術書 1 冊 252 段落。spec-local-ai.md 4.1）。
/// </para>
/// <para>
/// <b>索引は置かない。</b>測るために作った索引が残ると、次に開いたときに
/// 「作ってある」ことになる。作る道筋は同じものを通し、書き出しだけしない。
/// </para>
/// </summary>
/// <example>
/// <code>
/// dotnet run --project ChoroReader.App/ChoroReader.App.csproj -- --measure 本.epub
/// </code>
/// </example>
internal static class Measure
{
    /// <summary>1 段落あたりを測る回数。1 回だけだと機械の気まぐれが出る。</summary>
    private const int Rounds = 20;

    internal static int Run(string bookPath)
    {
        var result = new JsonObject { ["書籍"] = Path.GetFileName(bookPath) };

        try
        {
            if (!App.HasModel)
            {
                result["error"] = $"モデルがありません（{App.ModelDirectory}）";
                Write(result);
                return 2;
            }

            // 1. モデルを開く。**launch 後の最初の問いだけは表に出る**ので、ここも測る。
            var opening = Stopwatch.StartNew();
            using var embedder = OnnxEmbedder.Load(App.ModelDirectory);
            opening.Stop();
            result["モデルを開く"] = $"{opening.ElapsedMilliseconds} ms";
            result["次元"] = embedder.Dimension;

            // 2. 書籍を段落に切る。ここは推論を含まないので、別に測る。
            var cutting = Stopwatch.StartNew();
            var pieces = Pieces(bookPath);
            cutting.Stop();
            result["段落に切る"] = $"{cutting.ElapsedMilliseconds} ms";
            result["段落"] = pieces.Count;
            if (pieces.Count == 0)
            {
                result["error"] = "段落が 1 つも出ませんでした";
                Write(result);
                return 1;
            }

            // 3. 1 段落あたり。**暖機してから測る。** 最初の 1 回は開いた直後の分を含む。
            var warm = pieces[0];
            embedder.Embed(warm.Text, EmbeddingKind.Document);

            var each = new List<double>(Rounds);
            for (var at = 0; at < Rounds; at++)
            {
                var piece = pieces[at % pieces.Count];
                var watch = Stopwatch.StartNew();
                embedder.Embed(piece.Text, EmbeddingKind.Document);
                watch.Stop();
                each.Add(watch.Elapsed.TotalMilliseconds);
            }
            each.Sort();
            result["1 段落 中央"] = $"{each[each.Count / 2]:F1} ms";
            result["1 段落 最短"] = $"{each[0]:F1} ms";
            result["1 段落 最長"] = $"{each[^1]:F1} ms";

            // 4. 1 冊ぶんの見込み。全部回すと長いので、中央値から出す。
            var perBook = each[each.Count / 2] * pieces.Count / 1000;
            result["1 冊の見込み"] = $"{perBook:F1} 秒";
            result["macOS 版の実測"] = "1 冊 6.4 秒（252 段落・1 段落 中央 11.8 ms）";

            // 5. 問いの側。書棚で引くたびに払う値段である。
            embedder.Embed("暖機", EmbeddingKind.Query);
            var asking = Stopwatch.StartNew();
            for (var at = 0; at < Rounds; at++)
            {
                embedder.Embed("待っている間に他の仕事を進める書き方", EmbeddingKind.Query);
            }
            asking.Stop();
            result["問い 1 回"] = $"{asking.Elapsed.TotalMilliseconds / Rounds:F1} ms";

            // 6. 索引の大きさ。**置かずに測る。** 形にするところまでは同じ道を通す。
            var vectors = new float[pieces.Count * embedder.Dimension];
            for (var at = 0; at < pieces.Count; at++)
            {
                var body = pieces[at].Unit.Heading.Length == 0
                    ? pieces[at].Text
                    : pieces[at].Unit.Heading + "。" + pieces[at].Text;
                embedder.Embed(body, EmbeddingKind.Document).Vector
                    .CopyTo(vectors.AsSpan(at * embedder.Dimension));
            }
            var index = new SemanticIndex(App.ModelName, embedder.Dimension,
                                          [.. pieces.Select(one => one.Unit)], vectors, 0);
            result["索引ファイル"] = $"{index.Encode().Length / 1024.0 / 1024:F2} MB";
        }
        catch (Exception error)
        {
            result["error"] = error.ToString();
            Write(result);
            return 1;
        }

        Write(result);
        return 0;
    }

    private static IReadOnlyList<SemanticPiece> Pieces(string bookPath)
    {
        if (DocumentFormats.Detect(bookPath) == DocumentFormat.Pdf)
        {
            using var paper = PdfInspector.Open(bookPath);
            return SemanticUnits.OfPdf(paper);
        }
        using var archive = new EpubArchive(bookPath);
        return SemanticUnits.OfEpub(archive, EpubParser.Parse(archive));
    }

    private static void Write(JsonObject result)
    {
        // 日本語が化けると読めない。標準出力を UTF-8 にしてから書く。
        Console.OutputEncoding = Encoding.UTF8;
        Console.Out.WriteLine(result.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        }));
    }
}
