namespace ChoroReader.Convert;

/// <summary>
/// ONNX の演算を積む手。名前を配りながら <see cref="OnnxProgram"/> を組み立てる。
///
/// <para>
/// <b>形は書かない。</b>Core ML は形を全部書かないと組み立てで落ちるが、
/// ONNX は形を推す。書かないぶん、間違いは組み立てではなく実行のときに出る。
/// だから最後の答え合わせは、必ず ONNX Runtime に読ませて行う。
/// </para>
/// </summary>
internal sealed class OnnxBuilder(OnnxProgram program)
{
    internal OnnxProgram Program { get; } = program;

    private int _counter;

    // MARK: 置く

    /// <summary>演算を 1 つ積む。出た値の名前を返す。</summary>
    internal string Op(string type, string[] outputs, string[] inputs, params Attr[] attributes)
    {
        Program.Ops.Add(new Op(type, inputs, outputs, attributes));
        return outputs[0];
    }

    /// <summary>重み。<b>fp16 で置く。</b></summary>
    internal void Weight(string name, int[] dims, ReadOnlySpan<float> values) =>
        Program.Initializers.Add(new Initializer(name, dims, OnnxType.Float16, Halves(values)));

    /// <summary>添え物の定数（軸の並び、切る位置など）。int64 で置く。</summary>
    internal string Numbers(string name, ReadOnlySpan<long> values, bool scalar = false)
    {
        var raw = new byte[values.Length * 8];
        for (var at = 0; at < values.Length; at++)
        {
            BitConverter.TryWriteBytes(raw.AsSpan(at * 8, 8), values[at]);
        }
        Program.Initializers.Add(new Initializer(
            name, scalar ? [] : [values.Length], OnnxType.Int64, raw));
        return name;
    }

    /// <summary>fp16 の 1 つ。塞ぐ値や目盛りに使う。</summary>
    internal string Half(string name, float value)
    {
        Program.Initializers.Add(new Initializer(name, [], OnnxType.Float16, Halves([value])));
        return name;
    }

    private string Fresh(string hint) => $"{hint}_{++_counter}";

    // MARK: よく使う組み合わせ

    /// <summary>
    /// 正規化。ModernBERT は bias を持たないので gamma だけ渡す。
    /// 平均と分散は fp32 で取る（<c>stash_type</c> の既定）。fp16 のまま取ると桁が落ちる。
    /// </summary>
    internal string LayerNorm(string name, string input, string gamma, float eps) =>
        Op("LayerNormalization", [name], [input, gamma],
           new Attr.Int("axis", -1), new Attr.Float("epsilon", eps));

    /// <summary>いま流れている長さ。<c>Shape</c> から 2 つ目の軸を取る。</summary>
    internal string SequenceLength()
    {
        var shape = Op("Shape", [Fresh("ids_shape")], ["input_ids"]);
        var one = Numbers("seq_axis", [1], scalar: true);
        return Op("Gather", [Fresh("seq_len")], [shape, one], new Attr.Int("axis", 0));
    }

    /// <summary>rope の表を、いまの長さまで切り出す。焼いてあるのは最大長ぶんである。</summary>
    internal (string LocalCos, string LocalSin, string GlobalCos, string GlobalSin) SliceRope(string length)
    {
        var starts = Numbers("rope_start", [0]);
        var axes = Numbers("rope_axis", [2]);
        // `Slice` の `ends` は 1 次元で要る。`Shape` から取った長さは 0 次元なので包む。
        var wrapAxis = Numbers("rope_wrap_axis", [0]);
        var ends = Op("Unsqueeze", [Fresh("rope_end")], [length, wrapAxis]);

        string Cut(string name) => Op("Slice", [$"{name}_cut"], [name, starts, ends, axes]);

        return (Cut("rope_local_cos"), Cut("rope_local_sin"),
                Cut("rope_global_cos"), Cut("rope_global_sin"));
    }

    /// <summary>
    /// 注意のマスクを 2 つ作る。
    ///
    /// <para>
    /// <b>詰め物は入力で決まるので、グラフの中で組む。</b>
    /// 窓の方も、seq×seq を焼くと大きすぎるので組む。
    /// </para>
    /// <para>
    /// 形は <c>[batch,1,1,S]</c> と <c>[1,1,S,S]</c> のままにする。ONNX が放送するので、
    /// <c>[1,1,S,S]</c> へ広げなくてよい。
    /// </para>
    /// </summary>
    internal (string Global, string Local) Masks(string length, int window)
    {
        // 1 が「見てよい位置」。1 - それ ＝ 詰め物なら 1。
        var asHalf = Op("Cast", [Fresh("mask_half")], ["attention_mask"],
                        new Attr.Int("to", (int)OnnxType.Float16));
        var axes = Numbers("mask_axes", [1, 2]);
        var wide = Op("Unsqueeze", [Fresh("mask_wide")], [asHalf, axes]);
        var one = Half("mask_one", 1);
        var inverted = Op("Sub", [Fresh("mask_inverted")], [one, wide]);
        var blocked = Half("mask_blocked", OnnxEncoder.BlockedValue);
        // 詰め物なら塞ぐ値、そうでなければ 0。掛けるだけで済む。
        var global = Op("Mul", ["global_mask"], [inverted, blocked]);

        // 窓。ある位置は左右へ window/2 ずつ届く。
        var zero = Numbers("win_zero", [0], scalar: true);
        var step = Numbers("win_step", [1], scalar: true);
        var positions = Op("Range", [Fresh("win_range")], [zero, length, step]);
        var rowAxis = Numbers("win_row_axis", [1]);
        var columnAxis = Numbers("win_col_axis", [0]);
        var rows = Op("Unsqueeze", [Fresh("win_rows")], [positions, rowAxis]);
        var columns = Op("Unsqueeze", [Fresh("win_cols")], [positions, columnAxis]);
        var difference = Op("Sub", [Fresh("win_diff")], [rows, columns]);
        var distance = Op("Abs", [Fresh("win_abs")], [difference]);
        var reach = Numbers("win_reach", [window / 2], scalar: true);
        var outside = Op("Greater", [Fresh("win_outside")], [distance, reach]);
        var zeroHalf = Half("win_zero_half", 0);
        var picked = Op("Where", [Fresh("win_masked")], [outside, blocked, zeroHalf]);
        var squareAxes = Numbers("win_square_axes", [0, 1]);
        var square = Op("Unsqueeze", [Fresh("win_square")], [picked, squareAxes]);

        // **足さずに小さい方を採る。** 足すと -65504 が 2 つ重なって fp16 から溢れ、
        // -inf になる。そうなると softmax が NaN を返す。
        var local = Op("Min", ["local_mask"], [global, square]);
        return (global, local);
    }

    /// <summary>注意。</summary>
    internal string Attention(string tag, string input, string? normGamma, string wqkv, string wo,
                              string cos, string sin, string mask,
                              int heads, int headDim, int hidden, float scale, float eps)
    {
        // 1. 前正規化。層 0 は埋め込みの後で正規化済みなので持たない。
        var normed = input;
        if (normGamma is not null)
        {
            normed = LayerNorm($"{tag}_attn_normed", input, normGamma, eps);
        }

        // 2〜5. 束ねた QKV を作り、3 つに割る。
        // **bias は無い**（config で拒んである）ので、足し算を置かない。
        var qkv = Op("MatMul", [$"{tag}_qkv"], [normed, wqkv]);
        var shape5 = Numbers($"{tag}_qkv_shape", [0, -1, 3, heads, headDim]);
        var qkv5 = Op("Reshape", [$"{tag}_qkv5"], [qkv, shape5]);
        var qkvt = Op("Transpose", [$"{tag}_qkvt"], [qkv5], new Attr.Ints("perm", [0, 3, 2, 1, 4]));
        var sizes = Numbers($"{tag}_qkv_sizes", [1, 1, 1]);
        Op("Split", [$"{tag}_q5", $"{tag}_k5", $"{tag}_v5"], [qkvt, sizes], new Attr.Int("axis", 2));
        var squeezeAxis = Numbers($"{tag}_sq_axis", [2]);
        var query = Op("Squeeze", [$"{tag}_q"], [$"{tag}_q5", squeezeAxis]);
        var key = Op("Squeeze", [$"{tag}_k"], [$"{tag}_k5", squeezeAxis]);
        var value = Op("Squeeze", [$"{tag}_v"], [$"{tag}_v5", squeezeAxis]);

        // 6〜7. 問いと鍵に rope を掛ける。値には掛けない。
        var rotatedQuery = Rope($"{tag}_q", query, cos, sin, headDim);
        var rotatedKey = Rope($"{tag}_k", key, cos, sin, headDim);

        // 8〜12. 目盛りを掛けた内積とマスク、softmax、値との積。
        // **ONNX の MatMul は転置の指示を取らない。** 鍵を先に転置する。
        var keyT = Op("Transpose", [$"{tag}_kt"], [rotatedKey], new Attr.Ints("perm", [0, 1, 3, 2]));
        var scores = Op("MatMul", [$"{tag}_scores"], [rotatedQuery, keyT]);
        var scaleValue = Half($"{tag}_scale", scale);
        var scaled = Op("Mul", [$"{tag}_scaled"], [scores, scaleValue]);
        var masked = Op("Add", [$"{tag}_masked"], [scaled, mask]);
        var probabilities = Op("Softmax", [$"{tag}_probs"], [masked], new Attr.Int("axis", -1));
        var context = Op("MatMul", [$"{tag}_context"], [probabilities, value]);

        // 13〜16. head をまとめ、射影して残差を足す。
        var merged = Op("Transpose", [$"{tag}_merged"], [context], new Attr.Ints("perm", [0, 2, 1, 3]));
        var flatShape = Numbers($"{tag}_flat_shape", [0, -1, hidden]);
        var flat = Op("Reshape", [$"{tag}_flat"], [merged, flatShape]);
        var projected = Op("MatMul", [$"{tag}_attn_out"], [flat, wo]);
        return Op("Add", [$"{tag}_attn_residual"], [input, projected]);
    }

    /// <summary><c>concat(-x2, x1)</c> を掛け合わせる。</summary>
    private string Rope(string tag, string x, string cos, string sin, int headDim)
    {
        var half = headDim / 2;
        var straight = Op("Mul", [$"{tag}_cos"], [x, cos]);

        var lowStart = Numbers($"{tag}_lo_start", [0]);
        var lowEnd = Numbers($"{tag}_lo_end", [half]);
        var axis = Numbers($"{tag}_rope_axis", [3]);
        var x1 = Op("Slice", [$"{tag}_x1"], [x, lowStart, lowEnd, axis]);

        var highStart = Numbers($"{tag}_hi_start", [half]);
        var highEnd = Numbers($"{tag}_hi_end", [headDim]);
        var x2 = Op("Slice", [$"{tag}_x2"], [x, highStart, highEnd, axis]);

        var negated = Op("Neg", [$"{tag}_negx2"], [x2]);
        var rotated = Op("Concat", [$"{tag}_rot"], [negated, x1], new Attr.Int("axis", -1));
        var crossed = Op("Mul", [$"{tag}_sin"], [rotated, sin]);
        return Op("Add", [$"{tag}_rope"], [straight, crossed]);
    }

    /// <summary>中間層。</summary>
    internal string FeedForward(string tag, string input, string normGamma, string wi, string wo,
                                int intermediate, Activation activation, float eps)
    {
        var normed = LayerNorm($"{tag}_mlp_normed", input, normGamma, eps);
        var wide = Op("MatMul", [$"{tag}_mlp_wide"], [normed, wi]);

        var sizes = Numbers($"{tag}_geglu_sizes", [intermediate, intermediate]);
        Op("Split", [$"{tag}_gate_in", $"{tag}_up"], [wide, sizes], new Attr.Int("axis", -1));

        string gate;
        if (activation == Activation.Gelu)
        {
            // **opset 17 に Gelu は無い**（20 から）。素で組む。
            // `0.5x(1 + erf(x/√2))`。Core ML 版の EXACT と同じ式である。
            var rootTwo = Half($"{tag}_root2", MathF.Sqrt(2));
            var divided = Op("Div", [$"{tag}_gelu_div"], [$"{tag}_gate_in", rootTwo]);
            var erf = Op("Erf", [$"{tag}_gelu_erf"], [divided]);
            var one = Half($"{tag}_gelu_one", 1);
            var plus = Op("Add", [$"{tag}_gelu_plus"], [erf, one]);
            var scaled = Op("Mul", [$"{tag}_gelu_scaled"], [$"{tag}_gate_in", plus]);
            var halfValue = Half($"{tag}_gelu_half", 0.5f);
            gate = Op("Mul", [$"{tag}_gate"], [scaled, halfValue]);
        }
        else
        {
            var sigmoid = Op("Sigmoid", [$"{tag}_silu"], [$"{tag}_gate_in"]);
            gate = Op("Mul", [$"{tag}_gate"], [$"{tag}_gate_in", sigmoid]);
        }

        var gated = Op("Mul", [$"{tag}_gated"], [gate, $"{tag}_up"]);
        var out_ = Op("MatMul", [$"{tag}_mlp_out"], [gated, wo]);
        return Op("Add", [$"{tag}_out"], [input, out_]);
    }

    /// <summary>マスクの立っているトークンだけで平均する。<b>詰めた分は数に入れない。</b></summary>
    internal string MeanPool(string name, string tokens)
    {
        var asHalf = Op("Cast", [Fresh("pool_half")], ["attention_mask"],
                        new Attr.Int("to", (int)OnnxType.Float16));
        var axis = Numbers("pool_unsqueeze_axis", [2]);
        var wide = Op("Unsqueeze", [Fresh("pool_mask")], [asHalf, axis]);
        var kept = Op("Mul", [Fresh("pool_kept")], [tokens, wide]);
        var sumAxis = Numbers("pool_axis", [1]);
        var summed = Op("ReduceSum", [Fresh("pool_sum")], [kept, sumAxis], new Attr.Int("keepdims", 0));
        var counted = Op("ReduceSum", [Fresh("pool_count")], [wide, sumAxis], new Attr.Int("keepdims", 0));
        return Op("Div", [name], [summed, counted]);
    }

    // MARK: fp16

    /// <summary>fp16 のバイト列にする。</summary>
    internal static byte[] Halves(ReadOnlySpan<float> values)
    {
        var raw = new byte[values.Length * 2];
        for (var at = 0; at < values.Length; at++)
        {
            BitConverter.TryWriteBytes(raw.AsSpan(at * 2, 2),
                                       BitConverter.HalfToUInt16Bits((Half)values[at]));
        }
        return raw;
    }
}
