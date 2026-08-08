using System.Text;
using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 決定的な偽の埋め込み器。
///
/// <para>
/// 単位の切り出し・索引ファイルの失効・候補から原文への解決は、
/// <b>本物のモデルが無くても固められる</b>（spec-local-ai.md 8）。
/// 本物を差すと結果が機械とモデルの版に左右され、CI では回せない。
/// </para>
/// <para>
/// 出すのは<b>文字の出方から決まる向き</b>である。同じ文には同じベクトル、
/// 違う文には違うベクトルが出て、似た文どうしは近くなる。
/// 意味を持っているわけではないが、配管を確かめるにはそれで足りる。
/// </para>
/// </summary>
internal sealed class FakeEmbedder(int dimension = 8, int limit = 1000) : IEmbedder
{
    public int Dimension { get; } = dimension;

    /// <summary>何回呼ばれたか。索引づくりが本当に走ったかを見る。</summary>
    internal int Calls { get; private set; }

    /// <summary>最後に渡された文。見出しを頭に付けているかを見る。</summary>
    internal string? Last { get; private set; }

    internal List<EmbeddingKind> Kinds { get; } = [];

    public Embedded Embed(string text, EmbeddingKind kind)
    {
        Calls++;
        Last = text;
        Kinds.Add(kind);

        // 問いと文書で違う向きになるようにする。接頭辞の付け分けと同じ役をさせる。
        var salt = kind == EmbeddingKind.Query ? 31 : 17;
        var made = new float[Dimension];
        foreach (var b in Encoding.UTF8.GetBytes(text))
        {
            made[b % Dimension] += 1;
        }
        made[0] += salt / 100f;

        // 正規化する。近さを内積そのものにするため（本物もそうしている）。
        var length = MathF.Sqrt(made.Sum(v => v * v));
        if (length > 0)
        {
            for (var at = 0; at < made.Length; at++)
            {
                made[at] /= length;
            }
        }
        return new Embedded(made, Truncated: text.Length > limit);
    }
}
