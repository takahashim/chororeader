namespace ChoroReader.Core;

/// <summary>
/// 埋め込むものの立場。
///
/// <para>
/// Ruri v3 は検索用の接頭辞を持つ。文書側は「検索文書: 」、問い側は「検索クエリ: 」を付ける。
/// 関連箇所（文書どうしの比較）は両方 <see cref="Document"/> で揃える
/// （spec-local-ai.md 4.6）。
/// </para>
/// </summary>
public enum EmbeddingKind
{
    Document,
    Query,
}

/// <param name="Vector">正規化済みのベクトル。近さは内積そのものになる。</param>
/// <param name="Truncated">長すぎて頭から切り詰めたか。数だけ残して後から測り直せるようにする。</param>
public sealed record Embedded(float[] Vector, bool Truncated);

/// <summary>
/// 文を 1 本のベクトルにするもの。
///
/// <para>
/// <b>抽象はこの 1 枚だけ置く。</b>検査で決定的な偽物を差すために要る
/// （spec-local-ai.md 8）。単位の切り出し・索引ファイルの失効・
/// 候補から原文への解決は、これで決定的に固められる。
/// </para>
/// <para>
/// それ以上の抽象（Reranker、Analyzer …）は Level 2 以降で必要になってから作る。
/// </para>
/// </summary>
public interface IEmbedder
{
    int Dimension { get; }

    Embedded Embed(string text, EmbeddingKind kind);
}
