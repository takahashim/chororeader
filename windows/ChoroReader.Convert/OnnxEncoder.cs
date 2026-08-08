namespace ChoroReader.Convert;

/// <summary>変換の結果。</summary>
/// <param name="Model">ONNX のモデル。</param>
/// <param name="Unused">読まなかった重みの名前。空でなければ、どこかを取りこぼしている。</param>
public sealed record Converted(byte[] Model, IReadOnlyList<string> Unused);

/// <summary>
/// ModernBERT の胴体を ONNX のグラフとして組む。
///
/// <para>
/// <b>使わなかった重みを申告する。</b>名前を 1 つ読み違えても変換は通り、
/// 初期値のままの層を持つモデルができて、それらしい数が出る。
/// 読んだ名前と checkpoint にある名前を突き合わせるのが、唯一の防壁である。
/// </para>
/// <para>
/// <b>長さが動く。</b>rope の表は最大長で焼いておいて切り出し、
/// 局所注意の窓は seq×seq が大きすぎるのでグラフの中で組む。
/// </para>
/// </summary>
public sealed class OnnxEncoder(EncoderConfig config, Safetensors weights, int maximumSequence = 2048)
{
    /// <summary>塞ぐ値。<b>有限にする。<c>-inf</c> にしてはいけない。</b></summary>
    /// <remarks>
    /// 完全に塞がれた行は実際に出る（詰め物の位置が、局所注意の窓から本物の外れたところにあるとき）。
    /// <c>-inf</c> だと <c>exp(-inf) = 0</c> が並び、softmax が <c>0/0 = NaN</c> を返す。
    /// その NaN は次の層で本物の位置へ移る（重み 0 を掛けても <c>0 × NaN = NaN</c> のため）。
    /// 有限値なら、全部塞がれた行は一様分布になるだけで済む。
    /// </remarks>
    public const float BlockedValue = -65504;

    /// <summary>
    /// rope の表を焼いておく長さ。<b>ここを越える入力は通らない。</b>
    /// アプリ側（<c>OnnxEmbedder.MaximumTokens</c>）が同じ長さで切り詰めるので届かない。
    /// </summary>
    public int MaximumSequence { get; } = maximumSequence;

    /// <summary>
    /// 長さが決まっているので、角度は先に計算して焼き込める。
    ///
    /// <para>
    /// 形は <c>[1, 1, seq, headDim]</c>。<b>角度は後ろ半分にも同じものを写す</b>
    /// （前半と後半を回し合わせる作りなので、位置 i と i+half が同じ角度を使う）。
    /// </para>
    /// </summary>
    public static (float[] Cos, float[] Sin) RopeTables(int seq, int headDim, float theta)
    {
        var half = headDim / 2;
        var cos = new List<float>(seq * headDim);
        var sin = new List<float>(seq * headDim);
        for (var position = 0; position < seq; position++)
        {
            var angles = new float[half];
            for (var at = 0; at < half; at++)
            {
                var exponent = -(float)(2 * at) / headDim;
                angles[at] = position * MathF.Pow(theta, exponent);
            }
            // 並べ替えではなく写す。前半と後半が同じ角度を持つ。
            for (var again = 0; again < 2; again++)
            {
                foreach (var angle in angles)
                {
                    cos.Add(MathF.Cos(angle));
                    sin.Add(MathF.Sin(angle));
                }
            }
        }
        return ([.. cos], [.. sin]);
    }

    public Converted Convert()
    {
        var (program, unused) = Assemble();
        return new Converted(program.Encode(), unused);
    }

    /// <summary>
    /// 組んだものをそのまま返す。<b>検査は書き出す前の形を見る。</b>
    /// 250 MB を吐いてから読ませるより、繋がりの検査はここで済ませたい。
    /// </summary>
    internal (OnnxProgram Program, IReadOnlyList<string> Unused) Assemble()
    {
        config.Check(MaximumSequence);

        var program = new OnnxProgram("modernbert");
        var builder = new OnnxBuilder(program);
        var read = new HashSet<string>(StringComparer.Ordinal);
        var p = config.Prefix;

        // 重みを 1 つ置く。transposed なら MatMul が食える向きへ入れ替える。
        string Place(string name, int[] expected, bool transposed = false)
        {
            read.Add(name);
            var shape = weights.Shape(name) ?? [];
            if (!shape.SequenceEqual(expected))
            {
                throw new ConvertException(
                    $"重みを読めません：{name} の形が [{string.Join(",", shape)}] で、"
                    + $"期待する [{string.Join(",", expected)}] と違います");
            }
            var values = weights.Read(name);
            var label = name.Replace(".", "_");
            if (transposed)
            {
                int rows = expected[0], columns = expected[1];
                var swapped = new float[values.Length];
                for (var row = 0; row < rows; row++)
                {
                    for (var column = 0; column < columns; column++)
                    {
                        swapped[column * rows + row] = values[row * columns + column];
                    }
                }
                builder.Weight(label, [columns, rows], swapped);
            }
            else
            {
                builder.Weight(label, expected, values);
            }
            return label;
        }

        var missing = new List<string>();
        void Require(params string[] names) =>
            missing.AddRange(names.Where(name => weights.Shape(name) is null));

        Require($"{p}embeddings.tok_embeddings.weight", $"{p}embeddings.norm.weight",
                $"{p}final_norm.weight");
        for (var layer = 0; layer < config.Layers; layer++)
        {
            Require($"{p}layers.{layer}.attn.Wqkv.weight", $"{p}layers.{layer}.attn.Wo.weight",
                    $"{p}layers.{layer}.mlp_norm.weight", $"{p}layers.{layer}.mlp.Wi.weight",
                    $"{p}layers.{layer}.mlp.Wo.weight");
        }
        if (missing.Count > 0)
        {
            throw new ConvertException("checkpoint に無い重みがあります：\n"
                + string.Join("\n", missing.Select(one => $"  ・{one}")));
        }

        int hidden = config.Hidden, heads = config.Heads;
        int headDim = config.HeadDim, intermediate = config.Intermediate;

        // 語彙の表。**転置しない**（`Gather` は行で引く）。
        var table = Place($"{p}embeddings.tok_embeddings.weight", [config.Vocab, hidden]);
        var embeddingNorm = Place($"{p}embeddings.norm.weight", [hidden]);
        var finalNorm = Place($"{p}final_norm.weight", [hidden]);

        // 語彙から引いて正規化する。
        // **負の id は表の後ろへ回り込む。** ONNX の Gather がそう定めている。
        var embedded = builder.Op("Gather", ["embedded"], [table, "input_ids"], new Attr.Int("axis", 0));
        var stream = builder.LayerNorm("emb_normed", embedded, embeddingNorm, config.Eps);

        // rope の表。**層ごとに theta が違う**（局所と全域）。
        var local = RopeTables(MaximumSequence, headDim, config.LocalRopeTheta);
        var global = RopeTables(MaximumSequence, headDim, config.GlobalRopeTheta);
        builder.Weight("rope_local_cos", [1, 1, MaximumSequence, headDim], local.Cos);
        builder.Weight("rope_local_sin", [1, 1, MaximumSequence, headDim], local.Sin);
        builder.Weight("rope_global_cos", [1, 1, MaximumSequence, headDim], global.Cos);
        builder.Weight("rope_global_sin", [1, 1, MaximumSequence, headDim], global.Sin);

        var length = builder.SequenceLength();
        var ropes = builder.SliceRope(length);
        var masks = builder.Masks(length, config.LocalAttention);

        for (var layer = 0; layer < config.Layers; layer++)
        {
            var isGlobal = config.IsGlobal(layer);
            var tag = $"l{layer}";

            // **層 0 は前正規化を持たない。** 埋め込みの後で正規化済みである。
            var normName = $"{p}layers.{layer}.attn_norm.weight";
            var attnNorm = weights.Shape(normName) is not null ? Place(normName, [hidden]) : null;

            stream = builder.Attention(
                tag, stream, attnNorm,
                wqkv: Place($"{p}layers.{layer}.attn.Wqkv.weight", [3 * hidden, hidden], transposed: true),
                wo: Place($"{p}layers.{layer}.attn.Wo.weight", [hidden, hidden], transposed: true),
                cos: isGlobal ? ropes.GlobalCos : ropes.LocalCos,
                sin: isGlobal ? ropes.GlobalSin : ropes.LocalSin,
                mask: isGlobal ? masks.Global : masks.Local,
                heads: heads, headDim: headDim, hidden: hidden,
                scale: 1 / MathF.Sqrt(headDim), eps: config.Eps);

            stream = builder.FeedForward(
                tag, stream,
                normGamma: Place($"{p}layers.{layer}.mlp_norm.weight", [hidden]),
                wi: Place($"{p}layers.{layer}.mlp.Wi.weight", [2 * intermediate, hidden], transposed: true),
                wo: Place($"{p}layers.{layer}.mlp.Wo.weight", [hidden, intermediate], transposed: true),
                intermediate: intermediate, activation: config.Activation, eps: config.Eps);
        }

        var tokens = builder.LayerNorm("token_embeddings", stream, finalNorm, config.Eps);
        var pooled = builder.MeanPool("sentence_embedding", tokens);

        // **出入口は組み終えてから置く。**
        program.Inputs.Add(new Port("input_ids", OnnxType.Int64,
                                    [Extent.Named("batch"), Extent.Named("seq")]));
        program.Inputs.Add(new Port("attention_mask", OnnxType.Int64,
                                    [Extent.Named("batch"), Extent.Named("seq")]));
        program.Outputs.Add(new Port(tokens, OnnxType.Float16,
                                     [Extent.Named("batch"), Extent.Named("seq"), Extent.Of(hidden)]));
        program.Outputs.Add(new Port(pooled, OnnxType.Float16,
                                     [Extent.Named("batch"), Extent.Of(hidden)]));

        return (program, [.. weights.Names.Where(name => !read.Contains(name))]);
    }
}
