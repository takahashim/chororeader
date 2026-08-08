using System.Text;
using System.Text.Json;
using ChoroReader.Convert;

namespace ChoroReader.Tests;

/// <summary>
/// ModernBERT を ONNX として組む。
///
/// <para>
/// 数の審判は本物の変換物を凍結済み 10 件に通すこと（<see cref="OnnxEmbedderTests"/>）で、
/// そちらはモデルが要る。ここで見るのは<b>吐く前に分かること</b>だけにする。
/// 250 MB を書き出してから読ませるより、繋がりの検査はここで済ませたい。
/// </para>
/// </summary>
public class OnnxEncoderTests
{
    private const int Hidden = 8, Heads = 2, Intermediate = 16, Vocab = 12, Layers = 2;

    /// <summary>小さな ModernBERT を 1 つ組む。層 2・幅 8・head 2 の玩具である。</summary>
    private static (EncoderConfig Config, Safetensors Weights) Tiny(
        string? extra = null, IReadOnlyDictionary<string, int[]>? shapes = null)
    {
        var json = $$"""
            {
              "model_type": "modernbert",
              "architectures": ["ModernBertModel"],
              "hidden_size": {{Hidden}},
              "num_attention_heads": {{Heads}},
              "num_hidden_layers": {{Layers}},
              "intermediate_size": {{Intermediate}},
              "vocab_size": {{Vocab}},
              "norm_eps": 1e-5,
              "local_attention": 4,
              "global_attn_every_n_layers": 2,
              "local_rope_theta": 100.0,
              "global_rope_theta": 1000.0,
              "max_position_embeddings": 64,
              "hidden_activation": "gelu"{{extra}}
            }
            """;
        return (new EncoderConfig(json), Weights(shapes));
    }

    private static Safetensors Weights(IReadOnlyDictionary<string, int[]>? shapes = null)
    {
        var wanted = new Dictionary<string, int[]>(StringComparer.Ordinal)
        {
            ["embeddings.tok_embeddings.weight"] = [Vocab, Hidden],
            ["embeddings.norm.weight"] = [Hidden],
            ["final_norm.weight"] = [Hidden],
        };
        for (var layer = 0; layer < Layers; layer++)
        {
            // 層 0 は前正規化を持たない（埋め込みの後で正規化済み）。
            if (layer > 0)
            {
                wanted[$"layers.{layer}.attn_norm.weight"] = [Hidden];
            }
            wanted[$"layers.{layer}.attn.Wqkv.weight"] = [3 * Hidden, Hidden];
            wanted[$"layers.{layer}.attn.Wo.weight"] = [Hidden, Hidden];
            wanted[$"layers.{layer}.mlp_norm.weight"] = [Hidden];
            wanted[$"layers.{layer}.mlp.Wi.weight"] = [2 * Intermediate, Hidden];
            wanted[$"layers.{layer}.mlp.Wo.weight"] = [Hidden, Intermediate];
        }
        return Pack(shapes ?? wanted);
    }

    /// <summary>形式の記述どおりに safetensors を組む（読み手の裏返しではない）。</summary>
    private static Safetensors Pack(IReadOnlyDictionary<string, int[]> shapes)
    {
        var header = new Dictionary<string, object>(StringComparer.Ordinal);
        var body = new List<byte>();
        foreach (var (name, shape) in shapes)
        {
            var count = shape.Aggregate(1, (a, b) => a * b);
            var start = body.Count;
            for (var at = 0; at < count; at++)
            {
                // 中身は何でもよい。ここで見るのは形と繋がりだけである。
                body.AddRange(BitConverter.GetBytes(at % 7 * 0.01f));
            }
            header[name] = new Dictionary<string, object>
            {
                ["dtype"] = "F32",
                ["shape"] = shape,
                ["data_offsets"] = new[] { start, body.Count },
            };
        }

        var json = JsonSerializer.SerializeToUtf8Bytes(header);
        var made = new List<byte>();
        made.AddRange(BitConverter.GetBytes((long)json.Length));
        made.AddRange(json);
        made.AddRange(body);

        var where = Path.Combine(Path.GetTempPath(), $"choro-onnx-{Guid.NewGuid():N}.safetensors");
        File.WriteAllBytes(where, [.. made]);
        return new Safetensors(where);
    }

    private static OnnxProgram Program()
    {
        var (config, weights) = Tiny();
        using (weights)
        {
            return new OnnxEncoder(config, weights, maximumSequence: 64).Assemble().Program;
        }
    }

    // MARK: 繋がり

    /// <summary>
    /// <b>名前が繋がっていること。</b>
    ///
    /// <para>
    /// どの演算の入力も、入口か・定数か・前の演算の出力でなければならない。
    /// 1 つでも欠けると ONNX Runtime は読まない。実際に入口ごと落としたことがある。
    /// </para>
    /// </summary>
    [Fact]
    public void 名前が繋がっている()
    {
        var program = Program();
        var known = new HashSet<string>(
            program.Inputs.Select(one => one.Name).Concat(program.Initializers.Select(one => one.Name)),
            StringComparer.Ordinal);

        foreach (var op in program.Ops)
        {
            foreach (var input in op.Inputs.Where(one => one.Length > 0))
            {
                Assert.True(known.Contains(input),
                            $"{op.Type} の入力 {input} が、入口でも定数でも前の出力でもない");
            }
            known.UnionWith(op.Outputs);
        }

        Assert.All(program.Outputs,
                   port => Assert.True(known.Contains(port.Name), $"出口 {port.Name} を作る演算が無い"));
    }

    /// <summary>出す名前が重ならないこと。重なると、後の方が前を隠す。</summary>
    [Fact]
    public void 出す名前が重ならない()
    {
        var program = Program();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var name in program.Initializers.Select(one => one.Name))
        {
            Assert.True(seen.Add(name), $"定数 {name} が二重に置かれている");
        }
        foreach (var output in program.Ops.SelectMany(op => op.Outputs))
        {
            Assert.True(seen.Add(output), $"{output} を出す演算が 2 つある");
        }
    }

    /// <summary>出入口の名前と型。アプリ側（<c>OnnxEmbedder</c>）の読み方と揃っていること。</summary>
    [Fact]
    public void 出入口がアプリの読み方と揃う()
    {
        var program = Program();

        Assert.Equal(["input_ids", "attention_mask"], program.Inputs.Select(one => one.Name));
        Assert.All(program.Inputs, one => Assert.Equal(OnnxType.Int64, one.Type));
        Assert.Equal(["token_embeddings", "sentence_embedding"], program.Outputs.Select(one => one.Name));
        Assert.All(program.Outputs, one => Assert.Equal(OnnxType.Float16, one.Type));
    }

    /// <summary>
    /// <b>層ごとに rope の表とマスクが違う。</b>
    ///
    /// <para>
    /// 取り違えても動くし、それらしい数も出る。<b>層ごとの配線を直に見る。</b>
    /// 「どこかで使われているか」では足りない（表は切り出しの入力にも名前が出るし、
    /// 窓のマスクは全域のマスクから作るので、どの層も使っていなくても名前は現れる）。
    /// </para>
    /// </summary>
    [Fact]
    public void 全域の層と窓の層で別の表と別のマスクを使う()
    {
        var program = Program();
        var byOutput = program.Ops.ToDictionary(op => op.Outputs[0], StringComparer.Ordinal);

        var ropes = new HashSet<string>(StringComparer.Ordinal);
        var masks = new HashSet<string>(StringComparer.Ordinal);
        for (var layer = 0; layer < Layers; layer++)
        {
            // rope は `x * cos` の掛け算。2 つ目の入力が表である。
            ropes.Add(byOutput[$"l{layer}_q_cos"].Inputs[1]);
            // マスクは点に足し込む。2 つ目の入力がマスクである。
            masks.Add(byOutput[$"l{layer}_masked"].Inputs[1]);
        }

        Assert.Equal(["rope_global_cos_cut", "rope_local_cos_cut"], ropes.Order());
        Assert.Equal(["global_mask", "local_mask"], masks.Order());
    }

    /// <summary>読まなかった重みが無いこと。<b>取りこぼしても変換は通る。</b></summary>
    [Fact]
    public void 重みを取りこぼさない()
    {
        var (config, weights) = Tiny();
        using (weights)
        {
            Assert.Empty(new OnnxEncoder(config, weights, maximumSequence: 64).Convert().Unused);
        }
    }

    // MARK: 拒む

    /// <summary>
    /// <b>足りない重みは、まとめて言う。</b>使えない checkpoint を見ている人が欲しいのは
    /// 一覧であって、最初の 1 つではない。
    /// </summary>
    [Fact]
    public void 足りない重みをまとめて言う()
    {
        var (config, _) = Tiny();
        using var weights = Pack(new Dictionary<string, int[]>
        {
            ["embeddings.tok_embeddings.weight"] = [Vocab, Hidden],
        });

        var error = Assert.Throws<ConvertException>(
            () => new OnnxEncoder(config, weights, maximumSequence: 64).Convert());

        Assert.Contains("final_norm.weight", error.Message);
        Assert.Contains("layers.0.attn.Wqkv.weight", error.Message);
        Assert.Contains("layers.1.mlp.Wo.weight", error.Message);
    }

    /// <summary>形の違う重みは受け取らない。通すと、それらしい数を出すモデルができる。</summary>
    [Fact]
    public void 形の違う重みは受け取らない()
    {
        var (config, _) = Tiny();
        var shapes = new Dictionary<string, int[]>(StringComparer.Ordinal);
        using (var whole = Weights())
        {
            foreach (var name in whole.Names)
            {
                shapes[name] = whole.Shape(name)!;
            }
        }
        shapes["final_norm.weight"] = [Hidden + 1];
        using var weights = Pack(shapes);

        var error = Assert.Throws<ConvertException>(
            () => new OnnxEncoder(config, weights, maximumSequence: 64).Convert());

        Assert.Contains("final_norm.weight", error.Message);
    }

    /// <summary>
    /// <b>学習された位置を超える長さは、動いて、間違った数を出す。</b>だから拒む。
    /// </summary>
    [Fact]
    public void 学習された位置を超える長さは拒む()
    {
        var (config, weights) = Tiny();
        using (weights)
        {
            var error = Assert.Throws<ConvertException>(
                () => new OnnxEncoder(config, weights, maximumSequence: 128).Convert());

            Assert.Contains("64", error.Message);
        }
    }

    /// <summary>
    /// <b>決め打ちのグラフが守れない言い分は、値にならない。</b>
    /// 読んで無視すると、通って、それらしい数が出て、順位だけが静かに狂う。
    /// </summary>
    [Theory]
    [InlineData(",\"attention_bias\": true", "attention_bias")]
    [InlineData(",\"mlp_bias\": true", "mlp_bias")]
    [InlineData(",\"norm_bias\": true", "norm_bias")]
    [InlineData(",\"layer_types\": [\"sliding_attention\", \"full_attention\"]", "layer_types")]
    public void 守れない言い分は拒む(string extra, string wanted)
    {
        var error = Assert.Throws<ConvertException>(() => Tiny(extra));

        Assert.Contains(wanted, error.Message);
    }

    /// <summary>
    /// <b>theta の置き場所が 2 通りある。</b>新しい config は <c>rope_parameters</c> の側に持ち、
    /// 平らな鍵は持たない。そこだけを見ていると既定値で変換が通り、静かに違うベクトルが出る
    /// （macOS 版が踏んだ。cosine 0.14）。
    /// </summary>
    [Fact]
    public void ropeのthetaは新しい置き場所からも読む()
    {
        var config = new EncoderConfig($$"""
            {
              "hidden_size": {{Hidden}}, "num_attention_heads": {{Heads}},
              "num_hidden_layers": {{Layers}}, "intermediate_size": {{Intermediate}},
              "vocab_size": {{Vocab}}, "max_position_embeddings": 64,
              "rope_parameters": {
                "sliding_attention": {"rope_theta": 123.0},
                "full_attention": {"rope_theta": 456.0}
              }
            }
            """);

        Assert.Equal(123f, config.LocalRopeTheta);
        Assert.Equal(456f, config.GlobalRopeTheta);
    }

    // MARK: rope の表

    /// <summary>
    /// <b>角度は後ろ半分にも同じものを写す。</b>前半と後半を回し合わせる作りなので、
    /// 位置 i と i+half が同じ角度を使う。並べ替えではない。
    /// </summary>
    [Fact]
    public void ropeの表は前半と後半で同じ角度を持つ()
    {
        var (cos, sin) = OnnxEncoder.RopeTables(seq: 4, headDim: 8, theta: 100);

        Assert.Equal(4 * 8, cos.Length);
        Assert.Equal(4 * 8, sin.Length);
        for (var position = 0; position < 4; position++)
        {
            for (var at = 0; at < 4; at++)
            {
                Assert.Equal(cos[position * 8 + at], cos[position * 8 + 4 + at]);
                Assert.Equal(sin[position * 8 + at], sin[position * 8 + 4 + at]);
            }
        }
    }

    /// <summary>位置 0 の角度は 0。cos は 1、sin は 0 になる。</summary>
    [Fact]
    public void ropeの表は位置0で単位になる()
    {
        var (cos, sin) = OnnxEncoder.RopeTables(seq: 2, headDim: 8, theta: 100);

        Assert.All(cos.Take(8), one => Assert.Equal(1f, one));
        Assert.All(sin.Take(8), one => Assert.Equal(0f, one));
    }

    // MARK: safetensors

    /// <summary>bf16 は fp32 の上位 16 ビットそのもの。下位を 0 で埋めれば戻る。</summary>
    [Fact]
    public void bf16を読める()
    {
        var made = new List<byte>();
        var header = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
        {
            ["w"] = new Dictionary<string, object>
            {
                ["dtype"] = "BF16",
                ["shape"] = new[] { 2 },
                ["data_offsets"] = new[] { 0, 4 },
            },
        });
        made.AddRange(BitConverter.GetBytes((long)header.Length));
        made.AddRange(header);
        // 1.0f は 0x3F800000。上位 16 ビットは 0x3F80。
        made.AddRange([0x80, 0x3F, 0x00, 0xC0]);   // 1.0, -2.0

        var where = Path.Combine(Path.GetTempPath(), $"choro-bf16-{Guid.NewGuid():N}.safetensors");
        File.WriteAllBytes(where, [.. made]);
        using var weights = new Safetensors(where);

        Assert.Equal([1f, -2f], weights.Read("w"));
    }

    [Fact]
    public void 壊れた重みは読まない()
    {
        var where = Path.Combine(Path.GetTempPath(), $"choro-broken-{Guid.NewGuid():N}.safetensors");
        File.WriteAllBytes(where, Encoding.UTF8.GetBytes("これは safetensors ではない"));

        Assert.Throws<ConvertException>(() => new Safetensors(where));
    }
}
