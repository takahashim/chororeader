using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 埋め込みの前後の処理。
///
/// <para>
/// <b>ここが黙って間違える場所である。</b>接頭辞・切り詰め・平均の取り方・正規化のどれか一つでも
/// 食い違えば、例外は出ずに違うベクトルが出るだけで、症状としては現れない。
/// </para>
/// <para>
/// <b>モデルが無くても全部噛む。</b>本物一式は 250 MB あって CI には置けないので、
/// 本物との突き合わせ（OnnxEmbedderTests）は飛ぶ。飛ばない側をここに置く。
/// </para>
/// </summary>
public class EmbeddingPipelineTests
{
    // MARK: 接頭辞

    /// <summary>
    /// Ruri v3 の検索用の接頭辞。<b>綴りは実装間で同じでなければならない</b>
    /// （macOS 版の EmbeddingModel.Prefix と同じ）。末尾の空白まで含めて 1 つの決まりである。
    /// </summary>
    [Fact]
    public void 接頭辞は文書と問いで違う()
    {
        Assert.Equal("検索文書: ", EmbeddingPipeline.PrefixOf(EmbeddingKind.Document));
        Assert.Equal("検索クエリ: ", EmbeddingPipeline.PrefixOf(EmbeddingKind.Query));
    }

    // MARK: 切り詰め

    [Fact]
    public void 収まるものは切り詰めない()
    {
        int[] ids = [1, 10, 11, 12, 2];
        var (kept, truncated) = EmbeddingPipeline.Truncate(ids, 2048);

        Assert.False(truncated);
        Assert.Equal(ids, kept);
    }

    /// <summary>
    /// <b>末尾の <c>&lt;/s&gt;</c> は残す。</b>前処理の形を崩すと、
    /// 切り詰めた本文だけ別の性質のベクトルになる。
    /// </summary>
    [Fact]
    public void 切り詰めても末尾の印は残す()
    {
        int[] ids = [1, 10, 11, 12, 13, 14, 2];
        var (kept, truncated) = EmbeddingPipeline.Truncate(ids, 4);

        Assert.True(truncated);
        Assert.Equal(4, kept.Length);
        Assert.Equal([1, 10, 11, 2], kept);
    }

    [Fact]
    public void ちょうど収まるものは切り詰めない()
    {
        int[] ids = [1, 10, 2];

        Assert.False(EmbeddingPipeline.Truncate(ids, 3).Truncated);
        Assert.True(EmbeddingPipeline.Truncate(ids, 2).Truncated);
    }

    // MARK: 平均

    /// <summary>
    /// <b>詰めた分は数に入れない。</b>マスクを掛け忘れると、
    /// 詰め物のぶんだけ薄まったベクトルになる。
    /// </summary>
    [Fact]
    public void 詰めた分は平均に入れない()
    {
        // 3 トークン × 2 次元。3 つ目は詰め物。
        float[] hidden = [1, 1, 3, 3, 100, 100];
        long[] mask = [1, 1, 0];

        var made = EmbeddingPipeline.MeanPool(hidden, mask, dimension: 2);

        Assert.Equal([2f, 2f], made);
    }

    /// <summary>CLS ではなく平均。頭のトークンだけを取っていないこと。</summary>
    [Fact]
    public void 頭のトークンだけを取らない()
    {
        float[] hidden = [1, 1, 3, 3];
        long[] mask = [1, 1];

        Assert.Equal([2f, 2f], EmbeddingPipeline.MeanPool(hidden, mask, dimension: 2));
    }

    [Fact]
    public void マスクが全て降りていたら零を返す()
    {
        Assert.Equal([0f, 0f], EmbeddingPipeline.MeanPool([1, 1], [0], dimension: 2));
    }

    // MARK: 正規化

    /// <summary>
    /// 元モデルは Transformer → Pooling の 2 段で、<b>Normalize の段を持たない</b>。
    /// 割るのはこちらの仕事で、忘れると近さが内積そのものでなくなる。
    /// </summary>
    [Fact]
    public void 長さ1に揃える()
    {
        float[] vector = [3, 4];

        EmbeddingPipeline.Normalize(vector);

        Assert.Equal(0.6f, vector[0], 1e-6);
        Assert.Equal(0.8f, vector[1], 1e-6);
        Assert.Equal(1.0, Math.Sqrt(vector.Sum(v => (double)v * v)), 1e-6);
    }

    [Fact]
    public void 零のベクトルは割らない()
    {
        float[] vector = [0, 0];

        EmbeddingPipeline.Normalize(vector);

        Assert.Equal([0f, 0f], vector);
    }

    /// <summary>
    /// <b>ノルムは double で積む</b>（kohagi の l2_normalize と同じ）。
    /// float で積むと、次元が多いときに桁が落ちて長さが 1 からずれる。
    /// </summary>
    [Fact]
    public void ノルムはdoubleで積む()
    {
        // 512 次元。1 つだけ大きく、残りは float の刻みに埋もれる大きさにする。
        var vector = new float[512];
        vector[0] = 4096;
        for (var at = 1; at < vector.Length; at++)
        {
            vector[at] = 0.02f;
        }

        EmbeddingPipeline.Normalize(vector);

        Assert.Equal(1.0, Math.Sqrt(vector.Sum(v => (double)v * v)), 1e-6);
    }
}
