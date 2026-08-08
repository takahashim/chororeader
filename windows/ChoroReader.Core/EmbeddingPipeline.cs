namespace ChoroReader.Core;

/// <summary>
/// 埋め込みの前後の処理。推論そのものは含まない。
///
/// <para>
/// <b>ここが黙って間違える場所である。</b>接頭辞・切り詰め・平均の取り方・正規化のどれか一つでも
/// 食い違えば、例外は出ずに違うベクトルが出るだけで、関連箇所も意味検索も静かに質が落ちる
/// （spec-local-ai.md 4.6）。
/// </para>
/// <para>
/// <b>推論から切り離してあるのは、モデルが無くても確かめられるようにするためである。</b>
/// モデル一式は 250 MB あって CI には置けない。ここに置いておけば、
/// 本物が無い環境でも 4 つとも検査が噛む。
/// </para>
/// </summary>
public static class EmbeddingPipeline
{
    /// <summary>
    /// 埋め込む前に本文へ足す接頭辞。
    ///
    /// <para>
    /// Ruri v3 は検索用の接頭辞を持つ。<b>付け忘れても付け違えても動く</b>ので、
    /// 実装間で同じ綴りにしておく必要がある（macOS 版の <c>EmbeddingModel.Prefix</c> と同じ）。
    /// </para>
    /// </summary>
    public static string PrefixOf(EmbeddingKind kind) =>
        kind == EmbeddingKind.Query ? "検索クエリ: " : "検索文書: ";

    /// <summary>
    /// 収まる長さまで<b>頭から切り詰める</b>。
    ///
    /// <para>
    /// <b>末尾の <c>&lt;/s&gt;</c> は残す。</b>前処理の形を崩すと、
    /// 切り詰めた本文だけ別の性質のベクトルになる。
    /// </para>
    /// <para>
    /// 切り詰めは黙って行い、切れたかどうかを返す。呼ぶ側が単位の割り方を見直せるようにする。
    /// </para>
    /// </summary>
    public static (int[] Ids, bool Truncated) Truncate(IReadOnlyList<int> ids, int maximumTokens)
    {
        if (ids.Count <= maximumTokens)
        {
            return ([.. ids], false);
        }

        var made = ids.Take(maximumTokens).ToArray();
        if (made.Length > 0)
        {
            made[^1] = ids[^1];
        }
        return (made, true);
    }

    /// <summary>
    /// マスクの立っているトークンだけで平均する。<b>詰めた分は数に入れない。</b>
    ///
    /// <para>
    /// Ruri v3 の pooling は CLS ではなく平均である（元モデルの
    /// <c>1_Pooling/config.json</c> が <c>pooling_mode_mean_tokens: true</c>）。
    /// マスクを掛け忘れると、詰め物のぶんだけ薄まったベクトルになる。
    /// </para>
    /// </summary>
    /// <param name="tokenEmbeddings">トークン数 × 次元 を平らに並べたもの。</param>
    public static float[] MeanPool(ReadOnlySpan<float> tokenEmbeddings, ReadOnlySpan<long> mask, int dimension)
    {
        var made = new float[dimension];
        var counted = 0;
        for (var token = 0; token < mask.Length; token++)
        {
            if (mask[token] == 0)
            {
                continue;
            }
            var from = token * dimension;
            if (from + dimension > tokenEmbeddings.Length)
            {
                break;
            }
            for (var at = 0; at < dimension; at++)
            {
                made[at] += tokenEmbeddings[from + at];
            }
            counted++;
        }
        if (counted > 0)
        {
            for (var at = 0; at < dimension; at++)
            {
                made[at] /= counted;
            }
        }
        return made;
    }

    /// <summary>
    /// 長さ 1 に揃える。
    ///
    /// <para>
    /// <b>ノルムは double で積む</b>（kohagi の l2_normalize と同じ）。
    /// </para>
    /// <para>
    /// 元モデルは Transformer → Pooling の 2 段で、<b>Normalize の段を持たない</b>。
    /// 正規化はこちらの仕事である。忘れると近さが内積そのものでなくなる。
    /// </para>
    /// </summary>
    public static void Normalize(Span<float> vector)
    {
        var squared = 0.0;
        foreach (var value in vector)
        {
            squared += (double)value * value;
        }
        var norm = (float)Math.Sqrt(squared);
        if (norm <= 0)
        {
            return;
        }
        for (var at = 0; at < vector.Length; at++)
        {
            vector[at] /= norm;
        }
    }
}
