import Foundation

/// ONNX の演算を積む手。名前を配りながら `ONNXProgram` を組み立てる。
///
/// **形は書かない。** Core ML は形を全部書かないと組み立てで落ちるが、
/// ONNX は形を推す。書かないぶん、間違いは組み立てではなく実行のときに出る。
/// だから最後の答え合わせは、必ず ONNX Runtime に読ませて行う。
struct Builder {
    var program: ONNXProgram

    private var counter = 0

    init(program: ONNXProgram) {
        self.program = program
    }

    // MARK: - 置く

    /// 演算を 1 つ積む。出た値の名前を返す。
    @discardableResult
    mutating func op(_ type: String, _ outputs: [String], _ inputs: [String],
                     _ attributes: [ONNXProgram.Attr] = []) -> String {
        program.ops.append(.init(type, inputs: inputs, outputs: outputs, attributes: attributes))
        return outputs[0]
    }

    /// 重み。**fp16 で置く。**
    mutating func weight(_ name: String, dims: [Int], values: [Float]) {
        program.initializers.append(.init(name: name, dims: dims, type: .float16,
                                          raw: Self.halves(values)))
    }

    /// 添え物の定数（軸の並び、切る位置など）。int64 で置く。
    mutating func numbers(_ name: String, _ values: [Int], scalar: Bool = false) -> String {
        var raw = [UInt8]()
        for value in values {
            withUnsafeBytes(of: Int64(value).littleEndian) { raw.append(contentsOf: $0) }
        }
        program.initializers.append(.init(name: name, dims: scalar ? [] : [values.count],
                                          type: .int64, raw: raw))
        return name
    }

    /// fp16 の 1 つ。塞ぐ値や目盛りに使う。
    mutating func half(_ name: String, _ value: Float) -> String {
        program.initializers.append(.init(name: name, dims: [], type: .float16,
                                          raw: Self.halves([value])))
        return name
    }

    private mutating func fresh(_ hint: String) -> String {
        counter += 1
        return "\(hint)_\(counter)"
    }

    // MARK: - よく使う組み合わせ

    /// 正規化。ModernBERT は bias を持たないので gamma だけ渡す。
    ///
    /// 平均と分散は fp32 で取る（`stash_type` の既定）。fp16 のまま取ると桁が落ちる。
    mutating func layerNorm(_ name: String, _ input: String, _ gamma: String, _ eps: Float) -> String {
        op("LayerNormalization", [name], [input, gamma],
           [.int("axis", -1), .float("epsilon", eps)])
    }

    /// いま流れている長さ。`Shape` から 2 つ目の軸を取る。
    mutating func sequenceLength() -> String {
        let shape = op("Shape", [fresh("ids_shape")], ["input_ids"])
        let one = numbers("seq_axis", [1], scalar: true)
        return op("Gather", [fresh("seq_len")], [shape, one], [.int("axis", 0)])
    }

    /// rope の表を、いまの長さまで切り出す。焼いてあるのは最大長ぶんである。
    mutating func sliceRope(to length: String) -> (localCos: String, localSin: String,
                                                   globalCos: String, globalSin: String) {
        let starts = numbers("rope_start", [0])
        let axes = numbers("rope_axis", [2])
        // `Slice` の `ends` は 1 次元で要る。`Shape` から取った長さは 0 次元なので包む。
        let wrapAxis = numbers("rope_wrap_axis", [0])
        let ends = op("Unsqueeze", [fresh("rope_end")], [length, wrapAxis])

        func cut(_ name: String) -> String {
            op("Slice", ["\(name)_cut"], [name, starts, ends, axes])
        }
        return (cut("rope_local_cos"), cut("rope_local_sin"),
                cut("rope_global_cos"), cut("rope_global_sin"))
    }

    /// 注意のマスクを 2 つ作る。
    ///
    /// **詰め物は入力で決まるので、グラフの中で組む**（MIL 版と同じ理由）。
    /// 窓の方も、seq×seq を焼くと大きすぎるので組む。
    ///
    /// 形は `[batch,1,1,S]` と `[1,1,S,S]` のままにする。ONNX が放送するので、
    /// MIL 版のように `[1,1,S,S]` へ広げなくてよい。
    mutating func masks(length: String, window: Int) -> (global: String, local: String) {
        // 1 が「見てよい位置」。1 - それ ＝ 詰め物なら 1。
        let asHalf = op("Cast", [fresh("mask_half")], ["attention_mask"],
                        [.int("to", ONNXProgram.DataType.float16.rawValue)])
        let axes = numbers("mask_axes", [1, 2])
        let wide = op("Unsqueeze", [fresh("mask_wide")], [asHalf, axes])
        let one = half("mask_one", 1)
        let inverted = op("Sub", [fresh("mask_inverted")], [one, wide])
        let blocked = half("mask_blocked", ONNXEncoder.blockedValue)
        // 詰め物なら塞ぐ値、そうでなければ 0。掛けるだけで済む。
        let global = op("Mul", ["global_mask"], [inverted, blocked])

        // 窓。ある位置は左右へ window/2 ずつ届く。
        let zero = numbers("win_zero", [0], scalar: true)
        let step = numbers("win_step", [1], scalar: true)
        let positions = op("Range", [fresh("win_range")], [zero, length, step])
        let rowAxis = numbers("win_row_axis", [1])
        let columnAxis = numbers("win_col_axis", [0])
        let rows = op("Unsqueeze", [fresh("win_rows")], [positions, rowAxis])
        let columns = op("Unsqueeze", [fresh("win_cols")], [positions, columnAxis])
        let difference = op("Sub", [fresh("win_diff")], [rows, columns])
        let distance = op("Abs", [fresh("win_abs")], [difference])
        let reach = numbers("win_reach", [window / 2], scalar: true)
        let outside = op("Greater", [fresh("win_outside")], [distance, reach])
        let zeroHalf = half("win_zero_half", 0)
        let picked = op("Where", [fresh("win_masked")], [outside, blocked, zeroHalf])
        let squareAxes = numbers("win_square_axes", [0, 1])
        let square = op("Unsqueeze", [fresh("win_square")], [picked, squareAxes])

        // **足さずに小さい方を採る。** 足すと -65504 が 2 つ重なって fp16 から溢れ、
        // -inf になる。そうなると softmax が NaN を返す（MIL 版の覚え書きと同じ話）。
        let local = op("Min", ["local_mask"], [global, square])
        return (global, local)
    }

    /// 注意。MIL 版の 1〜16 にあたる。
    mutating func attention(tag: String, input: String, normGamma: String?,
                            wqkv: String, wo: String, cos: String, sin: String, mask: String,
                            heads: Int, headDim: Int, hidden: Int,
                            scale: Float, eps: Float) -> String {
        // 1. 前正規化。層 0 は埋め込みの後で正規化済みなので持たない。
        var normed = input
        if let normGamma {
            normed = layerNorm("\(tag)_attn_normed", input, normGamma, eps)
        }

        // 2〜5. 束ねた QKV を作り、3 つに割る。
        // **bias は無い**（config で拒んである）ので、足し算を置かない。
        let qkv = op("MatMul", ["\(tag)_qkv"], [normed, wqkv])
        let shape5 = numbers("\(tag)_qkv_shape", [0, -1, 3, heads, headDim])
        let qkv5 = op("Reshape", ["\(tag)_qkv5"], [qkv, shape5])
        let qkvt = op("Transpose", ["\(tag)_qkvt"], [qkv5], [.ints("perm", [0, 3, 2, 1, 4])])
        let sizes = numbers("\(tag)_qkv_sizes", [1, 1, 1])
        op("Split", ["\(tag)_q5", "\(tag)_k5", "\(tag)_v5"], [qkvt, sizes], [.int("axis", 2)])
        let squeezeAxis = numbers("\(tag)_sq_axis", [2])
        let query = op("Squeeze", ["\(tag)_q"], ["\(tag)_q5", squeezeAxis])
        let key = op("Squeeze", ["\(tag)_k"], ["\(tag)_k5", squeezeAxis])
        let value = op("Squeeze", ["\(tag)_v"], ["\(tag)_v5", squeezeAxis])

        // 6〜7. 問いと鍵に rope を掛ける。値には掛けない。
        let rotatedQuery = rope(tag: "\(tag)_q", x: query, cos: cos, sin: sin, headDim: headDim)
        let rotatedKey = rope(tag: "\(tag)_k", x: key, cos: cos, sin: sin, headDim: headDim)

        // 8〜12. 目盛りを掛けた内積とマスク、softmax、値との積。
        // **ONNX の MatMul は転置の指示を取らない。** 鍵を先に転置する。
        let keyT = op("Transpose", ["\(tag)_kt"], [rotatedKey], [.ints("perm", [0, 1, 3, 2])])
        let scores = op("MatMul", ["\(tag)_scores"], [rotatedQuery, keyT])
        let scaleValue = half("\(tag)_scale", scale)
        let scaled = op("Mul", ["\(tag)_scaled"], [scores, scaleValue])
        let masked = op("Add", ["\(tag)_masked"], [scaled, mask])
        let probabilities = op("Softmax", ["\(tag)_probs"], [masked], [.int("axis", -1)])
        let context = op("MatMul", ["\(tag)_context"], [probabilities, value])

        // 13〜16. head をまとめ、射影して残差を足す。
        let merged = op("Transpose", ["\(tag)_merged"], [context], [.ints("perm", [0, 2, 1, 3])])
        let flatShape = numbers("\(tag)_flat_shape", [0, -1, hidden])
        let flat = op("Reshape", ["\(tag)_flat"], [merged, flatShape])
        let projected = op("MatMul", ["\(tag)_attn_out"], [flat, wo])
        return op("Add", ["\(tag)_attn_residual"], [input, projected])
    }

    /// `concat(-x2, x1)` を掛け合わせる。MIL 版の `rotateHalf` と同じ。
    private mutating func rope(tag: String, x: String, cos: String, sin: String,
                               headDim: Int) -> String {
        let half_ = headDim / 2
        let straight = op("Mul", ["\(tag)_cos"], [x, cos])

        let lowStart = numbers("\(tag)_lo_start", [0])
        let lowEnd = numbers("\(tag)_lo_end", [half_])
        let axis = numbers("\(tag)_rope_axis", [3])
        let x1 = op("Slice", ["\(tag)_x1"], [x, lowStart, lowEnd, axis])

        let highStart = numbers("\(tag)_hi_start", [half_])
        let highEnd = numbers("\(tag)_hi_end", [headDim])
        let x2 = op("Slice", ["\(tag)_x2"], [x, highStart, highEnd, axis])

        let negated = op("Neg", ["\(tag)_negx2"], [x2])
        let rotated = op("Concat", ["\(tag)_rot"], [negated, x1], [.int("axis", -1)])
        let crossed = op("Mul", ["\(tag)_sin"], [rotated, sin])
        return op("Add", ["\(tag)_rope"], [straight, crossed])
    }

    /// 中間層。MIL 版の 17〜23 にあたる。
    mutating func feedForward(tag: String, input: String, normGamma: String,
                              wi: String, wo: String, intermediate: Int, hidden: Int,
                              activation: EncoderConfig.Activation, eps: Float) -> String {
        let normed = layerNorm("\(tag)_mlp_normed", input, normGamma, eps)
        let wide = op("MatMul", ["\(tag)_mlp_wide"], [normed, wi])

        let sizes = numbers("\(tag)_geglu_sizes", [intermediate, intermediate])
        op("Split", ["\(tag)_gate_in", "\(tag)_up"], [wide, sizes], [.int("axis", -1)])

        let gate: String
        switch activation {
        case .gelu:
            // **opset 17 に Gelu は無い**（20 から）。素で組む。
            // `0.5x(1 + erf(x/√2))`。MIL 版の EXACT と同じ式である。
            let rootTwo = half("\(tag)_root2", Float(2).squareRoot())
            let divided = op("Div", ["\(tag)_gelu_div"], ["\(tag)_gate_in", rootTwo])
            let erf = op("Erf", ["\(tag)_gelu_erf"], [divided])
            let one = half("\(tag)_gelu_one", 1)
            let plus = op("Add", ["\(tag)_gelu_plus"], [erf, one])
            let scaled = op("Mul", ["\(tag)_gelu_scaled"], ["\(tag)_gate_in", plus])
            let halfValue = half("\(tag)_gelu_half", 0.5)
            gate = op("Mul", ["\(tag)_gate"], [scaled, halfValue])
        case .silu:
            let sigmoid = op("Sigmoid", ["\(tag)_silu"], ["\(tag)_gate_in"])
            gate = op("Mul", ["\(tag)_gate"], ["\(tag)_gate_in", sigmoid])
        }

        let gated = op("Mul", ["\(tag)_gated"], [gate, "\(tag)_up"])
        let out = op("MatMul", ["\(tag)_mlp_out"], [gated, wo])
        return op("Add", ["\(tag)_out"], [input, out])
    }

    /// マスクの立っているトークンだけで平均する。**詰めた分は数に入れない。**
    mutating func meanPool(_ name: String, _ tokens: String) -> String {
        let asHalf = op("Cast", [fresh("pool_half")], ["attention_mask"],
                        [.int("to", ONNXProgram.DataType.float16.rawValue)])
        let axis = numbers("pool_unsqueeze_axis", [2])
        let wide = op("Unsqueeze", [fresh("pool_mask")], [asHalf, axis])
        let kept = op("Mul", [fresh("pool_kept")], [tokens, wide])
        let sumAxis = numbers("pool_axis", [1])
        let summed = op("ReduceSum", [fresh("pool_sum")], [kept, sumAxis],
                        [.int("keepdims", 0)])
        let counted = op("ReduceSum", [fresh("pool_count")], [wide, sumAxis],
                         [.int("keepdims", 0)])
        return op("Div", [name], [summed, counted])
    }

    // MARK: - fp16

    /// fp16 のバイト列にする。
    static func halves(_ values: [Float]) -> [UInt8] {
        var raw = [UInt8]()
        raw.reserveCapacity(values.count * 2)
        for value in values {
            withUnsafeBytes(of: Float16(value).bitPattern.littleEndian) { raw.append(contentsOf: $0) }
        }
        return raw
    }
}
