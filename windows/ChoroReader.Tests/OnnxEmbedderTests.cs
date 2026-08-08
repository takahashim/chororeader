using System.Text.Json;
using ChoroReader.Core;
using ChoroReader.Semantic;

namespace ChoroReader.Tests;

/// <summary>
/// 埋め込みが参照実装（kohagi）と同じベクトルを返すこと。
///
/// <para>
/// トークナイザと同じで、<b>ずれても例外は出ず、黙って違うベクトルが出る</b>。
/// 詰め方・平均の取り方・正規化のどれか一つでも食い違えば、
/// 関連箇所も意味検索も静かに質が落ちるだけで、症状としては現れない。
/// </para>
/// <para>
/// 期待値は macOS 版の検査と同じファイルを読む（kohagi の <c>--device coreml</c> で 1 度作って
/// 凍結したもの。例文は架空）。<b>2 つの実装が同じ相手と突き合わせる</b>ことに意味があるので、
/// 写しを持たない。
/// </para>
/// <para>
/// モデル一式（250 MB）はリポジトリへ入れない。<b>手元に無ければ飛ばす。</b>
/// 飛ばないぶんは <see cref="EmbeddingPipelineTests"/> に置いてある。
/// </para>
/// <para>
/// <b>実機は要らない。</b>ONNX Runtime は macOS でも動くので、正しさはここで固まる。
/// 実機へ持っていくのは速さの測定だけである。
/// </para>
/// </summary>
public class OnnxEmbedderTests
{
    private sealed record Fixture(int Dimension, List<FixtureCase> Cases);

    private sealed record FixtureCase(string Text, string Prefix, List<float> Vector);

    /// <summary>
    /// 手元の ONNX 一式。無ければ null。
    ///
    /// <para>
    /// 決まった場所を見るだけにしておく（アプリはモデルの出どころを知らない）。
    /// <c>CHORO_ONNX_MODEL</c> で差せるようにもしておく。
    /// </para>
    /// </summary>
    private static string? Where()
    {
        if (Environment.GetEnvironmentVariable("CHORO_ONNX_MODEL") is { Length: > 0 } given)
        {
            return Directory.Exists(given) ? given : null;
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string[] places =
        [
            Path.Combine(home, "Library", "Application Support", "ChoroReader",
                         "Models", "ruri-v3-130m-onnx"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                         "ChoroReader", "Models", "ruri-v3-130m-onnx"),
        ];
        return places.FirstOrDefault(Directory.Exists);
    }

    private static Fixture Expected() =>
        JsonSerializer.Deserialize<Fixture>(
            File.ReadAllText(Path.Combine(TestPaths.Root,
                "macos", "Tests", "ChoroReaderTests", "Fixtures", "ruri-v3-embedding.json")),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;

    private static OnnxEmbedder Open()
    {
        var where = Where();
        Skip.If(where is null, "手元に Ruri v3 の ONNX 変換物がありません");
        return OnnxEmbedder.Load(where!);
    }

    /// <summary>
    /// 参照実装と同じ向きのベクトルを返すこと。
    ///
    /// <para>
    /// 値そのものではなく cosine で比べる。ANE と CPU、Core ML と ONNX では
    /// 最下位の桁が揃わない。
    /// </para>
    /// </summary>
    [SkippableFact]
    public void 参照実装と同じベクトルを返す()
    {
        using var embedder = Open();
        var expected = Expected();
        Assert.Equal(expected.Dimension, embedder.Dimension);

        foreach (var one in expected.Cases)
        {
            var kind = one.Prefix == EmbeddingPipeline.PrefixOf(EmbeddingKind.Query)
                ? EmbeddingKind.Query
                : EmbeddingKind.Document;
            var made = embedder.Embed(one.Text, kind).Vector;
            Assert.Equal(expected.Dimension, made.Length);

            var dot = made.Zip(one.Vector, (a, b) => (double)a * b).Sum();
            Assert.True(dot > 0.9999,
                        $"「{one.Text[..Math.Min(24, one.Text.Length)]}」でベクトルが違う（cosine {dot:F6}）");
        }
    }

    /// <summary>
    /// 正規化されていること。内積がそのまま cosine になる前提を守る。
    ///
    /// <para>
    /// <b>上の照合では捕まらない。</b>cosine は大きさを見ないので、
    /// 正規化を外しても向きは同じままで通ってしまう。二つで補い合う。
    /// </para>
    /// </summary>
    [SkippableFact]
    public void 単位ベクトルを返す()
    {
        using var embedder = Open();
        var made = embedder.Embed("架空の技術書の一節です。", EmbeddingKind.Document).Vector;

        Assert.Equal(1.0, Math.Sqrt(made.Sum(v => (double)v * v)), 1e-4);
    }

    /// <summary>
    /// 接頭辞が効いていること。<b>付け忘れても付け違えても動く</b>ので、
    /// 別の向きが出ることを確かめる。
    /// </summary>
    [SkippableFact]
    public void 文書と問いで違う向きになる()
    {
        using var embedder = Open();
        const string text = "待っている間に他の仕事を進める書き方";

        var asDocument = embedder.Embed(text, EmbeddingKind.Document).Vector;
        var asQuery = embedder.Embed(text, EmbeddingKind.Query).Vector;

        var dot = asDocument.Zip(asQuery, (a, b) => (double)a * b).Sum();
        Assert.True(dot < 0.9999, $"同じ向きになっている（cosine {dot:F6}）。接頭辞が効いていない");
        // まったく無関係になるわけでもない。同じ本文なので近くはある。
        Assert.True(dot > 0.5, $"離れすぎている（cosine {dot:F6}）");
    }

    /// <summary>同じ本文には同じベクトル。回すたびに変わっては索引が意味を持たない。</summary>
    [SkippableFact]
    public void 同じ本文には同じベクトルを返す()
    {
        using var embedder = Open();

        var first = embedder.Embed("架空の技術書の一節です。", EmbeddingKind.Document).Vector;
        var again = embedder.Embed("架空の技術書の一節です。", EmbeddingKind.Document).Vector;

        Assert.Equal(first, again);
    }

    /// <summary>長い本文は切り詰めたうえで、切れたことを申告する。</summary>
    [SkippableFact]
    public void 長すぎる本文は切り詰めて申告する()
    {
        using var embedder = Open();

        var short_ = embedder.Embed("短い本文である。", EmbeddingKind.Document);
        Assert.False(short_.Truncated);

        var long_ = embedder.Embed(string.Concat(Enumerable.Repeat("これは長い本文である。", 3000)),
                                   EmbeddingKind.Document);
        Assert.True(long_.Truncated);
        Assert.Equal(embedder.Dimension, long_.Vector.Length);
    }
}
