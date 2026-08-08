using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 書籍ひとつぶんの意味の索引。書き出して読み直せること、近い順に返すこと。
///
/// <para>
/// <b>読み込みは前だけをほどく。</b>飛び先や見出しは当たった書籍でしかほどかない。
/// そこが崩れても引く分には気付けないので、往復で押さえる。
/// </para>
/// </summary>
public class SemanticIndexTests
{
    private const string Model = "ruri-v3-130m";

    private static SemanticUnit Unit(int section, string href, double at, string heading, string? anchor = null) =>
        new()
        {
            Locator = new Locator { Href = href, Progression = at, Text = anchor, Fragment = null },
            Heading = heading,
            Section = section,
        };

    /// <summary>1 本だけ立った向き。近さを人が読める形で組める。</summary>
    private static float[] Axis(int dimension, int which)
    {
        var made = new float[dimension];
        made[which] = 1;
        return made;
    }

    private static SemanticIndex Built(int dimension = 4)
    {
        SemanticUnit[] units =
        [
            Unit(0, "ch01.xhtml", 0.0, "はじめの節", "ここから始まる"),
            Unit(0, "ch01.xhtml", 0.5, "はじめの節"),
            Unit(1, "ch02.xhtml", 0.25, "つぎの節", "つぎの話"),
        ];
        float[] vectors =
        [
            .. Axis(dimension, 0),
            .. Axis(dimension, 1),
            .. Axis(dimension, 2),
        ];
        return new SemanticIndex(Model, dimension, units, vectors, truncated: 1);
    }

    // MARK: 往復

    [Fact]
    public void 書き出して読み直せる()
    {
        var index = Built();
        var again = SemanticIndex.Decode(index.Encode(), 0, Model);

        Assert.NotNull(again);
        Assert.Equal(index.Count, again!.Count);
        Assert.Equal(index.Dimension, again.Dimension);
        Assert.Equal(index.Truncated, again.Truncated);
        Assert.Equal(Model, again.Model);
    }

    /// <summary>飛び先・見出し・目印は、当たってから要るもの。往復して崩れないこと。</summary>
    [Fact]
    public void 飛び先と見出しと目印が往復する()
    {
        var again = SemanticIndex.Decode(Built().Encode(), 0, Model)!;

        Assert.Equal("ch01.xhtml", again.Unit(0).Locator.Href);
        Assert.Equal("ここから始まる", again.Unit(0).Locator.Text);
        Assert.Equal("はじめの節", again.Unit(0).Heading);
        Assert.Equal(0, again.Unit(0).Section);

        // 目印の無い単位は、無いまま戻る。空文字にしない。
        Assert.Null(again.Unit(1).Locator.Text);

        Assert.Equal("ch02.xhtml", again.Unit(2).Locator.Href);
        Assert.Equal(1, again.Unit(2).Section);
    }

    /// <summary>
    /// 位置は 10 万分の 1 まで。1,000 ページの本で 0.01 ページぶんの粗さで足りる。
    /// </summary>
    [Fact]
    public void 章の中の位置は10万分の1まで戻る()
    {
        var units = new[] { Unit(0, "ch01.xhtml", 0.123456, "節") };
        var index = new SemanticIndex(Model, 4, units, Axis(4, 0), 0);

        var again = SemanticIndex.Decode(index.Encode(), 0, Model)!;
        Assert.Equal(0.12346, again.Unit(0).Locator.Progression, 5);
    }

    /// <summary>PDF はページを持つ。0 ページ目と「ページを持たない」を取り違えないこと。</summary>
    [Fact]
    public void ページの0と無しを取り違えない()
    {
        SemanticUnit[] units =
        [
            new() { Locator = new Locator { Page = 0 }, Heading = "頭", Section = 0 },
            new() { Locator = new Locator { Href = "ch01.xhtml" }, Heading = "章", Section = 1 },
        ];
        var index = new SemanticIndex(Model, 4, units, [.. Axis(4, 0), .. Axis(4, 1)], 0);

        var again = SemanticIndex.Decode(index.Encode(), 0, Model)!;
        Assert.Equal(0, again.Unit(0).Locator.Page);
        Assert.Null(again.Unit(1).Locator.Page);
    }

    /// <summary>
    /// ベクトルは fp16 で持つ。<b>戻したときに近さの順が変わらないこと</b>を見る。
    /// 値そのものは丸まるので、そこは求めない。
    /// </summary>
    [Fact]
    public void ベクトルはfp16で戻る()
    {
        var again = SemanticIndex.Decode(Built().Encode(), 0, Model)!;

        var vector = again.Vector(0)!;
        Assert.Equal(4, vector.Length);
        Assert.Equal(1f, vector[0], 0.001);
        Assert.Equal(0f, vector[1], 0.001);

        Assert.Null(again.Vector(-1));
        Assert.Null(again.Vector(again.Count));
    }

    // MARK: 壊れたもの

    [Fact]
    public void 途中で切れたものは読まない()
    {
        var whole = Built().Encode();

        for (var cut = 1; cut < whole.Length; cut += 7)
        {
            Assert.Null(SemanticIndex.Decode(whole[..cut], 0, Model));
        }
    }

    [Fact]
    public void 後ろに何か付いていたら読まない()
    {
        var whole = Built().Encode();

        // メタデータの長さが合わなくなる。頭の検査を通っても、ここで落ちる。
        Assert.Null(SemanticIndex.Decode([.. whole, 0], 0, Model));
    }

    // MARK: 引く

    /// <summary>
    /// <b>順位は節で決め、着地は段落でする。</b>
    /// 節の点は段落の平均で決める。最大にすると段落の多い節ほど得をする。
    /// </summary>
    [Fact]
    public void 節でまとめて段落へ着地する()
    {
        var index = Built();

        // 0 番の向きに近い問い。節 0 の平均は (1 + 0) / 2 = 0.5、節 1 は 0。
        var found = index.Nearest(Axis(4, 0), limit: 10);

        Assert.Equal(2, found.Count);           // 節は 2 つ。段落は 3 つある
        Assert.Equal(0, found[0].Unit);         // 節 0 の代表は、いちばん近い段落
        Assert.Equal(0.5f, found[0].Score, 0.01);
        Assert.Equal(2, found[1].Unit);
    }

    /// <summary>節の中でいちばん近い段落を代表にする。頭の段落ではない。</summary>
    [Fact]
    public void 節の代表はいちばん近い段落()
    {
        var index = Built();

        // 1 番の向きに近い問い。節 0 の中では 2 つ目の段落が当たる。
        var found = index.Nearest(Axis(4, 1), limit: 10);

        Assert.Equal(1, found[0].Unit);
    }

    [Fact]
    public void 長さが違う問いには何も返さない()
    {
        Assert.Empty(Built().Nearest(new float[3], limit: 10));
        Assert.Empty(Built().Nearest([], limit: 10));
    }

    [Fact]
    public void 上限まで返す()
    {
        Assert.Single(Built().Nearest(Axis(4, 0), limit: 1));
        Assert.Empty(Built().Nearest(Axis(4, 0), limit: 0));
    }

    /// <summary>
    /// <b>同点なら番号の小さい順に並べる。</b>
    ///
    /// <para>
    /// 辞書の並び順に任せると、節の代表がどの段落になったかで順が決まってしまう。
    /// 節を先に見つけた順と、代表の段落の番号は一致しない（代表は節の中でいちばん近い段落なので、
    /// 後ろの段落へ動く）。並べ方を決めておかないと、同じ点の節が入れ替わる。
    /// </para>
    /// </summary>
    [Fact]
    public void 同点なら番号の小さい順に並べる()
    {
        // 節 0 は段落 0（0 点）と段落 2（1 点）、節 1 は段落 1（0.5 点）。
        // 平均はどちらも 0.5 で並ぶが、節 0 の代表は段落 2 になる。
        SemanticUnit[] units =
        [
            Unit(0, "ch01.xhtml", 0.0, "節 0"),
            Unit(1, "ch01.xhtml", 0.3, "節 1"),
            Unit(0, "ch01.xhtml", 0.6, "節 0"),
        ];
        float[] vectors = [.. Axis(4, 1), 0.5f, 0, 0, 0, .. Axis(4, 0)];
        var index = new SemanticIndex(Model, 4, units, vectors, 0);

        var found = index.Nearest(Axis(4, 0), limit: 10);

        Assert.Equal(2, found.Count);
        Assert.Equal(0.5f, found[0].Score, 0.01);
        Assert.Equal(0.5f, found[1].Score, 0.01);
        // 辞書任せだと節 0（代表は段落 2）が先に来て [2, 1] になる。
        Assert.Equal([1, 2], found.Select(one => one.Unit).ToArray());
    }

    /// <summary>
    /// 文字列は表で 1 度だけ書く。見出しと章の道筋は同じ節の段落ぶん重複する。
    /// </summary>
    [Fact]
    public void 同じ見出しは一度しか書かない()
    {
        var heading = new string('見', 200);
        var many = Enumerable.Range(0, 50)
            .Select(at => Unit(0, "ch01.xhtml", at / 50.0, heading))
            .ToList();
        var vectors = new float[many.Count * 4];

        var size = new SemanticIndex(Model, 4, many, vectors, 0).Encode().Length;

        // 50 回書けば見出しだけで 3 万バイトを超える。表なら 1 度で済む。
        Assert.True(size < 10_000, $"{size} バイトある。表になっていない");
    }
}
