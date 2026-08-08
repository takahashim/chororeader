using System.Text;
using System.Text.Json;
using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// トークナイザが参照実装と同じトークン ID を返すこと。
///
/// <para>
/// <b>これが唯一の防壁である。</b>食い違っても例外は出ず、黙って違うベクトルが出るので、
/// 使ってみて気付くことができない。
/// </para>
/// <para>
/// 検査は 2 段になっている。
/// </para>
/// <list type="number">
/// <item>
/// <b>合成した語彙で、踏むと分かっている 3 つを常に見る。</b>
/// Ruri v3 の <c>tokenizer.json</c> はモデルと一緒に配られる 6.4 MB のファイルで、
/// 260 MB のモデルを入れないと手に入らない。CI には置けない。
/// そこに寄りかかると、CI では誰も確かめていないことになる
/// </item>
/// <item>
/// <b>本物の語彙で、凍結済みの 37 件を見る。</b>期待値は kohagi（Rust の tokenizers crate）で
/// 1 度作ったもので、macOS 版の検査と同じファイルを共有している。
/// 例文は架空で、実在の書籍からは取っていない。<b>手元にモデルが無ければ飛ばす</b>
/// </item>
/// </list>
/// </summary>
public class UnigramTokenizerTests
{
    // MARK: 1 段目 — 合成した語彙

    /// <summary>
    /// 検査のための小さな語彙を組む。
    ///
    /// <para>
    /// 本物と同じ形（<c>model.vocab</c> が [文字列, 点] の並び）にしておけば、
    /// 読み口も一緒に確かめられる。
    /// </para>
    /// </summary>
    private static string Vocabulary(params (string Piece, double Score)[] pieces)
    {
        var vocab = new StringBuilder();
        foreach (var (piece, score) in pieces)
        {
            if (vocab.Length > 0)
            {
                vocab.Append(',');
            }
            vocab.Append($"[{JsonSerializer.Serialize(piece)},{score.ToString("R", System.Globalization.CultureInfo.InvariantCulture)}]");
        }
        return $$"""
        {
          "added_tokens": [
            {"id": 0, "content": "<unk>"},
            {"id": 1, "content": "<s>"},
            {"id": 2, "content": "</s>"}
          ],
          "post_processor": {
            "special_tokens": {
              "<s>":  {"ids": [1]},
              "</s>": {"ids": [2]}
            }
          },
          "model": {
            "unk_id": 0,
            "byte_fallback": true,
            "vocab": [{{vocab}}]
          }
        }
        """;
    }

    /// <summary>0…255 の <c>&lt;0xXX&gt;</c> を語彙の後ろに並べる。byte fallback の行き先。</summary>
    private static IEnumerable<(string, double)> ByteTokens() =>
        Enumerable.Range(0, 256).Select(b => ($"<0x{b:X2}>", -20.0));

    /// <summary>
    /// <b>同点は開始位置の小さい方（長い語彙）を採る。</b>
    ///
    /// <para>
    /// Swift 実装が黙って間違えた 3 つ目で、既製の C# トークナイザが揃わなかった理由でもある
    /// （spikes/findings-csharp-tokenizer.md）。
    /// 目次の点線や罫線のような連なりでは同じ点の分け方が並ぶので、
    /// どちらを採るかで本文が丸ごと別のベクトルになる。
    /// </para>
    /// </summary>
    [Fact]
    public void 同点なら長い語彙を採る()
    {
        // "ab" を 1 つで採る道と "a"+"b" で採る道が、点でちょうど並ぶ。
        var tokenizer = UnigramTokenizer.Parse(Vocabulary(
            ("<unk>", 0), ("<s>", 0), ("</s>", 0),
            ("ab", -1.0), ("a", -0.5), ("b", -0.5)));

        // 3 = "ab"。4,5 = "a","b"。等号を含む比較にすると後者になる。
        Assert.Equal([1, 3, 2], tokenizer.Encode("ab"));
    }

    /// <summary>
    /// <b>点の足し込みは double で行う。</b>
    ///
    /// <para>
    /// 語彙の点は f32 だが、参照実装は f64 で積む。Swift 実装が黙って間違えた 2 つ目である。
    /// 同じ点の分け方が並ぶと（目次の点線のような連なり）丸めで順位が入れ替わる。
    /// </para>
    /// <para>
    /// ここの点は<b>わざと作ったもの</b>である。差は 2e-7 で、この大きさでの float の刻み
    /// （9.5e-7）より小さい。double なら分かれ、float なら並ぶ。
    /// 本物の語彙で起きるのは長い連なりの積み重ねだが、それは凍結済みの 37 件が見ている。
    /// ここで見たいのは<b>積む型</b>だけなので、最短の形にした。
    /// </para>
    /// </summary>
    [Fact]
    public void 点はdoubleで積む()
    {
        // "a"+"b" = -12.3399998 で、"ab" = -12.34 よりわずかに高い。
        var tokenizer = UnigramTokenizer.Parse(Vocabulary(
            ("<unk>", 0), ("<s>", 0), ("</s>", 0),
            ("ab", -12.34), ("a", -6.17), ("b", -6.1699998)));

        // float で積むと差が消えて並び、同点の決まりで "ab"（id 3）になる。
        Assert.Equal([1, 4, 5, 2], tokenizer.Encode("ab"));
    }

    /// <summary>
    /// <b>語彙は正規化しない。</b>
    ///
    /// <para>
    /// Swift 実装が黙って間違えた 1 つ目。「が」（1 符号位置）と「か」＋濁点（2 符号位置）を
    /// 同じものとして扱うと、語彙の片方が消える。この語彙には 15 組ある。
    /// C# の string は序数で比べるので鍵としては踏まないが、
    /// 読み込みのどこかで正規化を挟めば同じことが起きる。
    /// </para>
    /// </summary>
    [Fact]
    public void 濁点の形が違えば別の語彙として持つ()
    {
        const string composed = "が";              // U+304C
        const string decomposed = "が";  // か + 濁点
        Assert.NotEqual(composed, decomposed);

        var tokenizer = UnigramTokenizer.Parse(Vocabulary(
            [("<unk>", 0), ("<s>", 0), ("</s>", 0),
             (decomposed, -0.5), (composed, -0.5), .. ByteTokens()]));

        // 正規化して読むと 2 つが同じ鍵になり、後から入れた方（id 4）が前を潰す。
        Assert.Equal([1, 3, 2], tokenizer.Encode(decomposed));
        Assert.Equal([1, 4, 2], tokenizer.Encode(composed));
    }

    /// <summary>点が並ばないときは、素直に高い方を採る。上の検査が偶然通っていないことの裏。</summary>
    [Fact]
    public void 点が高い分け方を採る()
    {
        var tokenizer = UnigramTokenizer.Parse(Vocabulary(
            ("<unk>", 0), ("<s>", 0), ("</s>", 0),
            ("ab", -3.0), ("a", -0.5), ("b", -0.5)));

        Assert.Equal([1, 4, 5, 2], tokenizer.Encode("ab"));
    }

    /// <summary>語彙に無い文字は、UTF-8 のバイトごとに落とす。</summary>
    [Fact]
    public void 語彙に無い文字はバイトに落とす()
    {
        var tokenizer = UnigramTokenizer.Parse(Vocabulary(
            [("<unk>", 0), ("<s>", 0), ("</s>", 0), ("a", -0.5), .. ByteTokens()]));

        // 「あ」は E3 81 82。語彙の 4 番目から <0x00> が並ぶので、id は 4 + バイト値。
        Assert.Equal([1, 4 + 0xE3, 4 + 0x81, 4 + 0x82, 2], tokenizer.Encode("あ"));

        // 語彙にある字は落とさない。
        Assert.Equal([1, 3, 2], tokenizer.Encode("a"));
    }

    /// <summary>空白は ▁ に置き換える。頭には足さない（prepend_scheme=never）。</summary>
    [Fact]
    public void 空白は印に置き換える()
    {
        var tokenizer = UnigramTokenizer.Parse(Vocabulary(
            [("<unk>", 0), ("<s>", 0), ("</s>", 0), ("▁a", -0.5), ("a", -0.5), .. ByteTokens()]));

        // 「 a」→ ▁a で 1 つ。頭に印を足すなら "a" だけでも ▁a になるはずで、そうはならない。
        Assert.Equal([1, 3, 2], tokenizer.Encode(" a"));
        Assert.Equal([1, 4, 2], tokenizer.Encode("a"));
    }

    /// <summary>特殊トークンは切り分けて素通しする。中を分けない。</summary>
    [Fact]
    public void 特殊トークンは素通しする()
    {
        var tokenizer = UnigramTokenizer.Parse(Vocabulary(
            [("<unk>", 0), ("<s>", 0), ("</s>", 0), ("a", -0.5), .. ByteTokens()]));

        // 前後の <s> </s> は挟んだぶん。中の <s> a </s> は本文に書かれたもの。
        Assert.Equal([1, 1, 3, 2, 2], tokenizer.Encode("<s>a</s>"));
    }

    [Fact]
    public void 特殊トークンを外せる()
    {
        var tokenizer = UnigramTokenizer.Parse(Vocabulary(
            [("<unk>", 0), ("<s>", 0), ("</s>", 0), ("a", -0.5), .. ByteTokens()]));

        Assert.Equal([3], tokenizer.Encode("a", addSpecialTokens: false));
    }

    [Fact]
    public void 空文字でも挟むものは返す()
    {
        var tokenizer = UnigramTokenizer.Parse(Vocabulary(
            ("<unk>", 0), ("<s>", 0), ("</s>", 0), ("a", -0.5)));

        Assert.Equal([1, 2], tokenizer.Encode(""));
        Assert.Empty(tokenizer.Encode("", addSpecialTokens: false));
    }

    [Fact]
    public void 語彙が無ければ読まない()
    {
        Assert.Throws<DocumentException>(() => UnigramTokenizer.Parse("""{"model": {"vocab": []}}"""));
    }

    // MARK: 2 段目 — 本物の語彙と凍結済みの期待値

    private sealed record Frozen(List<FrozenCase> Cases);

    private sealed record FrozenCase(string Text, List<int> Ids);

    /// <summary>
    /// 手元の Ruri v3 の <c>tokenizer.json</c>。無ければ null。
    ///
    /// <para>
    /// macOS 版が置く場所を見る。<c>CHORO_TOKENIZER_JSON</c> で差せるようにもしておく。
    /// </para>
    /// </summary>
    private static string? TokenizerJson()
    {
        if (Environment.GetEnvironmentVariable("CHORO_TOKENIZER_JSON") is { Length: > 0 } given)
        {
            return File.Exists(given) ? given : null;
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string[] places =
        [
            Path.Combine(home, "Library", "Application Support", "ChoroReader",
                         "Models", "ruri-v3-130m-coreml", "tokenizer.json"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                         "ChoroReader", "Models", "ruri-v3-130m", "tokenizer.json"),
        ];
        return places.FirstOrDefault(File.Exists);
    }

    /// <summary>
    /// 参照実装と同じトークン ID を返すこと。
    ///
    /// <para>
    /// 期待値は macOS 版の検査と同じファイルを読む。<b>2 つの実装が同じ相手と突き合わせる</b>
    /// ことに意味があるので、写しを持たない。
    /// </para>
    /// </summary>
    [SkippableFact]
    public void 参照実装と同じトークンIDを返す()
    {
        var where = TokenizerJson();
        Skip.If(where is null, "手元に Ruri v3 の tokenizer.json がありません");

        var expected = JsonSerializer.Deserialize<Frozen>(
            File.ReadAllText(Path.Combine(TestPaths.Root,
                "macos", "Tests", "ChoroReaderTests", "Fixtures", "ruri-v3-tokenizer.json")),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
        Assert.True(expected.Cases.Count > 20, "期待値が少なすぎます");

        var tokenizer = UnigramTokenizer.Load(where!);
        foreach (var one in expected.Cases)
        {
            Assert.Equal(one.Ids, tokenizer.Encode(one.Text));
        }
    }
}
