using System.Text;

namespace ChoroReader.Core;

/// <summary>
/// 照合のために文字を畳む。
///
/// 日本語では単語境界が定まらないため、標準は部分一致とする。
/// 全角と半角、大文字と小文字、濁点の合成の違いを区別しない。
/// 1 文字が 1 文字に写る畳み方だけを使う。位置を元の文字列へ戻せなくなるため。
///
/// 畳み方は検索（DocumentSearch）と印付け（Mark）が共有する。
/// どちらか一方の持ち物にすると、残りがそこへ間借りする形になって、
/// 「畳み方はどこの決まりごとか」が名前から分からなくなる。
///
/// かつては CompareInfo（ICU）に任せていたが、当たりの通し番号を実装間で揃えるには、
/// どこを何番目と数えるかまで揃っている必要がある。畳み方を自分で持つことにした。
/// </summary>
public static class Fold
{
    /// <summary>1 文字を畳む。畳んだ結果が無くなる文字（結合文字）は null。</summary>
    public static Rune? One(Rune c)
    {
        // 結合文字は無視する（CompareOptions.IgnoreNonSpace に当たる）。
        if (IsCombiningMark(c.Value))
        {
            return null;
        }

        var folded = c.Value switch
        {
            // 全角の ASCII を半角へ。
            >= 0xFF01 and <= 0xFF5E => new Rune(c.Value - 0xFEE0),
            // 全角スペース。
            0x3000 => new Rune(' '),
            _ => c,
        };

        return Rune.ToLowerInvariant(folded);
    }

    /// <summary>畳んだ文字だけを並べる。元の位置は要らないとき用。</summary>
    public static List<Rune> Text(string source)
    {
        var result = new List<Rune>();
        foreach (var rune in source.EnumerateRunes())
        {
            if (One(rune) is { } folded)
            {
                result.Add(folded);
            }
        }
        return result;
    }

    /// <summary>
    /// 元の文字位置を保ったまま畳んだ列。
    /// <c>Origin[i]</c> は <c>Folded[i]</c> が元の何文字目かを指す。
    /// </summary>
    public sealed record Folding(IReadOnlyList<Rune> Folded, IReadOnlyList<int> Origin);

    public static Folding All(IReadOnlyList<Rune> runes)
    {
        var folded = new List<Rune>(runes.Count);
        var origin = new List<int>(runes.Count);
        for (var index = 0; index < runes.Count; index++)
        {
            if (One(runes[index]) is { } one)
            {
                folded.Add(one);
                origin.Add(index);
            }
        }
        return new Folding(folded, origin);
    }

    private static bool IsCombiningMark(int code) =>
        code is (>= 0x0300 and <= 0x036F) or (>= 0x1AB0 and <= 0x1AFF) or (>= 0x1DC0 and <= 0x1DFF)
            or (>= 0x20D0 and <= 0x20FF) or (>= 0xFE20 and <= 0xFE2F) or (>= 0x3099 and <= 0x309A);
}
