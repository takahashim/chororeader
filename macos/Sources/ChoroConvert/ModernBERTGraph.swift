import Foundation

/// ModernBERT の胴体を MIL のグラフとして組む。
///
/// kohagi の `modernbert.rs` から移した。**1 つの層は 23 の演算**でできている。
/// 前正規化 → 束ねた QKV → rope → マスク付きの注意 → 出口の射影 → 残差、
/// そして前正規化 → 門付きの中間層 → 残差。
///
/// 層の違いは**マスクだけ**である。窓の層には局所マスク、
/// `global_attn_every_n_layers` ごとの層には全域マスクを渡す。
///
/// 形はすべて書く（`MILProgram` の方針）。食い違えば Core ML が組み立てで落ちる。
struct ModernBERTGraph {
    let config: EncoderConfig
    /// このバケットの長さ。
    let seq: Int

    /// 重みの置き場所（`weight.bin` の目録の位置）。
    struct BlockOffsets {
        /// 層 0 は前段の正規化を持たない（埋め込みの後で正規化済みのため）。
        var attnNorm: UInt64?
        var wqkv: UInt64
        var wqkvBias: UInt64
        var wo: UInt64
        var woBias: UInt64
        var mlpNorm: UInt64
        var mlpWi: UInt64
        var mlpWiBias: UInt64
        var mlpWo: UInt64
        var mlpWoBias: UInt64
        var ropeCos: UInt64
        var ropeSin: UInt64
    }

    private var hidden: Int { config.hidden }
    private var heads: Int { config.heads }
    private var headDim: Int { config.headDim }
    private var intermediate: Int { config.intermediate }

    /// 注意の目盛り。`1 / sqrt(head の幅)`。
    var scale: Float { 1 / Float(headDim).squareRoot() }

    // MARK: - rope の表

    /// 長さが決まっているので、角度は先に計算して焼き込める。
    ///
    /// 形は `[1, 1, seq, headDim]`。**角度は後ろ半分にも同じものを写す**
    /// （前半と後半を回し合わせる作りなので、位置 i と i+half が同じ角度を使う）。
    static func ropeTables(seq: Int, headDim: Int, theta: Float) -> (cos: [Float], sin: [Float]) {
        let half = headDim / 2
        var cosTable = [Float](); cosTable.reserveCapacity(seq * headDim)
        var sinTable = [Float](); sinTable.reserveCapacity(seq * headDim)
        for position in 0 ..< seq {
            var angles = [Float](); angles.reserveCapacity(half)
            for at in 0 ..< half {
                let exponent = -Float(2 * at) / Float(headDim)
                angles.append(Float(position) * powf(theta, exponent))
            }
            // 並べ替えではなく写す。前半と後半が同じ角度を持つ。
            cosTable.append(contentsOf: angles.map { cosf($0) })
            cosTable.append(contentsOf: angles.map { cosf($0) })
            sinTable.append(contentsOf: angles.map { sinf($0) })
            sinTable.append(contentsOf: angles.map { sinf($0) })
        }
        return (cosTable, sinTable)
    }

    /// 窓の層が**見てはいけない**位置。`[1, 1, seq, seq]` を行から並べる。
    ///
    /// 窓は総幅なので、ある位置は左右へ `window / 2` ずつ届く
    /// （ModernBERT の `local_attention` の定め方）。
    ///
    /// **窓は入力に依らないので定数にできる。** 詰め物の方だけが入力で決まるので、
    /// そちらはグラフの中で組む（`prologue`）。
    static func windowCondition(seq: Int, window: Int) -> [Bool] {
        let reach = window / 2
        var out = [Bool](repeating: false, count: seq * seq)
        for row in 0 ..< seq {
            for column in 0 ..< seq {
                out[row * seq + column] = abs(row - column) > reach
            }
        }
        return out
    }

    // MARK: - 組み立て

    /// 埋め込みから最後の正規化まで。返すのは `[1, seq, hidden]`。
    ///
    /// - Parameters:
    ///   - ids: `[1, seq]` の int32
    ///   - blocks: 層ごとの重みの位置
    ///   - tokens: 語彙の表の位置
    ///   - embeddingNorm: 埋め込みの後の正規化
    ///   - finalNorm: 最後の正規化
    ///   - masks: 局所と全域のマスクの位置
    func build(into mil: inout MILProgram, ids: MILProgram.Value,
               attentionMask: MILProgram.Value,
               blocks: [BlockOffsets], tokens: UInt64,
               embeddingNorm: UInt64, finalNorm: UInt64) -> MILProgram.Value {
        let hiddenShape = [1, seq, hidden]
        // **epsilon は gamma と同じ型でなければならない。** fp32 で置くと
        // 「gamma と epsilon の型が違う」と言われて読めない（実際に踏んだ）。
        let epsilon = mil.constant("epsilon", .init(.fp16, []), .halves([config.eps]))

        // 語彙の表から引き、正規化する。
        let table = mil.constant("tok_embeddings", .init(.fp16, [config.vocab, hidden]),
                                 .blob(offset: tokens))
        // **負の id は表の後ろへ回り込む**（辿った Python と同じにする）。
        let zero = mil.constant("id_zero", .init(.int32, []), .ints([0]))
        let nonNegative = mil.op("greater_equal",
                                 out: .init(name: "id_ok", type: .init(.bool, [1, seq])),
                                 inputs: [("x", ids), ("y", zero)])
        let vocabSize = mil.constant("id_vocab", .init(.int32, []), .ints([Int32(config.vocab)]))
        let wrapped = mil.op("add",
                             out: .init(name: "id_wrapped", type: .init(.int32, [1, seq])),
                             inputs: [("x", ids), ("y", vocabSize)])
        let safeIds = mil.op("select",
                             out: .init(name: "id_safe", type: .init(.int32, [1, seq])),
                             inputs: [("cond", nonNegative), ("a", ids), ("b", wrapped)])

        let gatherAxis = mil.constant("emb_axis", .init(.int32, []), .ints([0]))
        // `batch_dims` と `validate_indices` は省けない。**省くと読めない。**
        let batchDims = mil.constant("emb_batch_dims", .init(.int32, []), .ints([0]))
        let validate = mil.constant("emb_validate", .init(.bool, []), .bools([false]))
        let gathered = mil.op("gather",
                              out: .init(name: "embedded", type: .init(.fp16, hiddenShape)),
                              inputs: [("x", table), ("indices", safeIds), ("axis", gatherAxis),
                                       ("batch_dims", batchDims), ("validate_indices", validate)])
        let embeddingGamma = mil.constant("emb_norm", .init(.fp16, [hidden]),
                                          .blob(offset: embeddingNorm))
        let normAxes = mil.constant("emb_norm_axes", .init(.int32, [1]), .ints([-1]))
        var stream = mil.op("layer_norm",
                            out: .init(name: "emb_normed", type: .init(.fp16, hiddenShape)),
                            inputs: [("x", gathered), ("axes", normAxes),
                                     ("epsilon", epsilon), ("gamma", embeddingGamma)])

        let (global, local) = masks(&mil, attentionMask: attentionMask)

        for (at, block) in blocks.enumerated() {
            let mask = config.isGlobal(layer: at) ? global : local
            stream = attention(&mil, layer: at, input: stream, weights: block,
                               mask: mask, epsilon: epsilon)
            stream = feedForward(&mil, layer: at, input: stream, weights: block, epsilon: epsilon)
        }

        let finalGamma = mil.constant("final_norm", .init(.fp16, [hidden]), .blob(offset: finalNorm))
        let finalAxes = mil.constant("final_norm_axes", .init(.int32, [1]), .ints([-1]))
        return mil.op("layer_norm",
                      out: .init(name: "hidden", type: .init(.fp16, hiddenShape)),
                      inputs: [("x", stream), ("axes", finalAxes),
                               ("epsilon", epsilon), ("gamma", finalGamma)])
    }

    /// 注意のマスクを 2 つ作る。**詰め物は入力で決まるので、グラフの中で組む。**
    ///
    /// 定数で焼き込んでいた頃は、詰め物のある入力で参照実装と食い違った
    /// （cosine 0.935。バケットいっぱいまで詰まった入力では一致していたので、
    /// 気付くのが遅れた）。
    private func masks(_ mil: inout MILProgram,
                       attentionMask: MILProgram.Value) -> (global: MILProgram.Value,
                                                            local: MILProgram.Value) {
        let square = [1, 1, seq, seq]

        // [1, seq] を [1, 1, seq, seq] へ広げる。1 が「見てよい位置」。
        let axis1 = mil.constant("m_ax1", .init(.int32, [1]), .ints([1]))
        let m3 = mil.op("expand_dims",
                        out: .init(name: "m3", type: .init(.int32, [1, 1, seq])),
                        inputs: [("x", attentionMask), ("axes", axis1)])
        let axis2 = mil.constant("m_ax2", .init(.int32, [1]), .ints([2]))
        let m4 = mil.op("expand_dims",
                        out: .init(name: "m4", type: .init(.int32, [1, 1, 1, seq])),
                        inputs: [("x", m3), ("axes", axis2)])
        let reps = mil.constant("m_reps", .init(.int32, [4]), .ints([1, 1, Int32(seq), 1]))
        let tiled = mil.op("tile",
                           out: .init(name: "m_tiled", type: .init(.int32, square)),
                           inputs: [("x", m4), ("reps", reps)])
        let toFp16 = mil.constant("m_dtype_fp16", .init(.string, []), .strings(["fp16"]))
        let asFp16 = mil.op("cast",
                            out: .init(name: "m_fp16", type: .init(.fp16, square)),
                            inputs: [("x", tiled), ("dtype", toFp16)])

        // 1 - 見てよい ＝ 詰め物なら 1、そうでなければ 0。
        let one = mil.constant("m_one", .init(.fp16, []), .halves([1]))
        let inverted = mil.op("sub",
                              out: .init(name: "m_inverted", type: .init(.fp16, square)),
                              inputs: [("x", one), ("y", asFp16)])
        let toBool = mil.constant("m_dtype_bool", .init(.string, []), .strings(["bool"]))
        let isPadding = mil.op("cast",
                               out: .init(name: "m_is_padding", type: .init(.bool, square)),
                               inputs: [("x", inverted), ("dtype", toBool)])

        // 詰め物のところは塞ぎ、それ以外は inverted が既に持っている 0。
        //
        // **塞ぐ値は有限にする（fp16 の最小の有限値）。`-inf` にしてはいけない。**
        //
        // 完全に塞がれた行は実際に出る（詰め物の位置が、局所注意の窓から
        // 本物の外れたところにあるとき）。`-inf` だと `exp(-inf) = 0` が並び、
        // softmax が `0/0 = NaN` を返す。その NaN は次の層で本物の位置へ移る
        // （重み 0 を掛けても `0 × NaN = NaN` のため）。
        //
        // 実測：CPU で seq 256 以上・詰め物ありのとき、**本物の位置まで 100% NaN**
        // になっていた。ANE では出ないが、それは `-inf` の扱いが違うだけで、
        // 頼れる性質ではない。
        //
        // PyTorch（transformers）は fp32 の最小の有限値を使っており、NaN を出さない。
        // 有限値なら、全部塞がれた行は一様分布になるだけで済む。
        let blocked = mil.constant("m_blocked", .init(.fp16, []), .halves([-65504]))
        let global = mil.op("select",
                            out: .init(name: "global_mask", type: .init(.fp16, square)),
                            inputs: [("cond", isPadding), ("a", blocked), ("b", inverted)])

        // 窓そのものは入力に依らないので定数。
        let outside = mil.constant("m_outside", .init(.bool, square),
                                   .bools(Self.windowCondition(seq: seq,
                                                               window: config.localAttention)))
        let local = mil.op("select",
                           out: .init(name: "local_mask", type: .init(.fp16, square)),
                           inputs: [("cond", outside), ("a", blocked), ("b", global)])
        return (global, local)
    }

    // MARK: - 注意（演算 1〜16）

    private func attention(_ mil: inout MILProgram, layer: Int, input: MILProgram.Value,
                           weights: BlockOffsets, mask: MILProgram.Value,
                           epsilon: MILProgram.Value) -> MILProgram.Value {
        let tag = { (name: String) in "l\(layer)_\(name)" }
        let hiddenShape = [1, seq, hidden]
        let perHead = [1, heads, seq, headDim]

        // 1. 前正規化。層 0 は埋め込みの後で正規化済みなので持たない。
        var normed = input
        if let offset = weights.attnNorm {
            let gamma = mil.constant(tag("attn_norm"), .init(.fp16, [hidden]), .blob(offset: offset))
            let axes = mil.constant(tag("attn_norm_axes"), .init(.int32, [1]), .ints([-1]))
            normed = mil.op("layer_norm",
                            out: .init(name: tag("attn_normed"), type: .init(.fp16, hiddenShape)),
                            inputs: [("x", input), ("axes", axes),
                                     ("epsilon", epsilon), ("gamma", gamma)])
        }

        // 2〜5. 束ねた QKV を作り、3 つに割る。
        let wqkv = mil.constant(tag("wqkv"), .init(.fp16, [3 * hidden, hidden]),
                                .blob(offset: weights.wqkv))
        let wqkvBias = mil.constant(tag("wqkv_bias"), .init(.fp16, [3 * hidden]),
                                    .blob(offset: weights.wqkvBias))
        let qkv = mil.op("linear",
                         out: .init(name: tag("qkv"), type: .init(.fp16, [1, seq, 3 * hidden])),
                         inputs: [("x", normed), ("weight", wqkv), ("bias", wqkvBias)])
        let shape5 = mil.constant(tag("qkv_shape"), .init(.int32, [5]),
                                  .ints([1, -1, 3, Int32(heads), Int32(headDim)]))
        let qkv5 = mil.op("reshape",
                          out: .init(name: tag("qkv5"),
                                     type: .init(.fp16, [1, seq, 3, heads, headDim])),
                          inputs: [("x", qkv), ("shape", shape5)])
        let perm = mil.constant(tag("qkv_perm"), .init(.int32, [5]), .ints([0, 3, 2, 1, 4]))
        let qkvt = mil.op("transpose",
                          out: .init(name: tag("qkvt"),
                                     type: .init(.fp16, [1, heads, 3, seq, headDim])),
                          inputs: [("x", qkv5), ("perm", perm)])
        let splitAxis = mil.constant(tag("qkv_split_axis"), .init(.int32, []), .ints([2]))
        let splitSizes = mil.constant(tag("qkv_split_sizes"), .init(.int32, [3]), .ints([1, 1, 1]))
        let parts = mil.split("split",
                              outs: ["qkv_q", "qkv_k", "qkv_v"].map {
                                  .init(name: tag($0), type: .init(.fp16, [1, heads, 1, seq, headDim]))
                              },
                              inputs: [("x", qkvt), ("axis", splitAxis),
                                       ("split_sizes", splitSizes)])
        var squeezed: [MILProgram.Value] = []
        for (name, part) in zip(["q", "k", "v"], parts) {
            let axes = mil.constant(tag("\(name)_sq_axes"), .init(.int32, [1]), .ints([2]))
            squeezed.append(mil.op("squeeze",
                                   out: .init(name: tag(name), type: .init(.fp16, perHead)),
                                   inputs: [("x", part), ("axes", axes)]))
        }

        // 6〜7. 問いと鍵に rope を掛ける。値には掛けない。
        let cos = mil.constant(tag("rope_cos"), .init(.fp16, [1, 1, seq, headDim]),
                               .blob(offset: weights.ropeCos))
        let sin = mil.constant(tag("rope_sin"), .init(.fp16, [1, 1, seq, headDim]),
                               .blob(offset: weights.ropeSin))
        let query = rotateHalf(&mil, tag: tag("q"), x: squeezed[0], cos: cos, sin: sin)
        let key = rotateHalf(&mil, tag: tag("k"), x: squeezed[1], cos: cos, sin: sin)

        // 8〜12. 目盛りを掛けた内積とマスク、softmax、値との積。
        let no = mil.constant(tag("false"), .init(.bool, []), .bools([false]))
        let yes = mil.constant(tag("true"), .init(.bool, []), .bools([true]))
        let scores = mil.op("matmul",
                            out: .init(name: tag("scores"), type: .init(.fp16, [1, heads, seq, seq])),
                            inputs: [("x", query), ("y", key),
                                     ("transpose_x", no), ("transpose_y", yes)])
        let scaleValue = mil.constant(tag("scale"), .init(.fp16, []), .halves([scale]))
        let scaled = mil.op("mul",
                            out: .init(name: tag("scaled"), type: .init(.fp16, [1, heads, seq, seq])),
                            inputs: [("x", scores), ("y", scaleValue)])
        let masked = mil.op("add",
                            out: .init(name: tag("masked"), type: .init(.fp16, [1, heads, seq, seq])),
                            inputs: [("x", scaled), ("y", mask)])
        let softmaxAxis = mil.constant(tag("sm_axis"), .init(.int32, []), .ints([-1]))
        let probabilities = mil.op("softmax",
                                   out: .init(name: tag("probs"),
                                              type: .init(.fp16, [1, heads, seq, seq])),
                                   inputs: [("x", masked), ("axis", softmaxAxis)])
        let context = mil.op("matmul",
                             out: .init(name: tag("context"), type: .init(.fp16, perHead)),
                             inputs: [("x", probabilities), ("y", squeezed[2]),
                                      ("transpose_x", no), ("transpose_y", no)])

        // 13〜16. head をまとめ、射影して残差を足す。
        let outPerm = mil.constant(tag("out_perm"), .init(.int32, [4]), .ints([0, 2, 1, 3]))
        let merged = mil.op("transpose",
                            out: .init(name: tag("merged"),
                                       type: .init(.fp16, [1, seq, heads, headDim])),
                            inputs: [("x", context), ("perm", outPerm)])
        let flatShape = mil.constant(tag("flat_shape"), .init(.int32, [3]),
                                     .ints([1, -1, Int32(hidden)]))
        let flat = mil.op("reshape",
                          out: .init(name: tag("flat"), type: .init(.fp16, hiddenShape)),
                          inputs: [("x", merged), ("shape", flatShape)])
        let wo = mil.constant(tag("wo"), .init(.fp16, [hidden, hidden]), .blob(offset: weights.wo))
        let woBias = mil.constant(tag("wo_bias"), .init(.fp16, [hidden]),
                                  .blob(offset: weights.woBias))
        let projected = mil.op("linear",
                               out: .init(name: tag("attn_out"), type: .init(.fp16, hiddenShape)),
                               inputs: [("x", flat), ("weight", wo), ("bias", woBias)])
        return mil.op("add",
                      out: .init(name: tag("attn_residual"), type: .init(.fp16, hiddenShape)),
                      inputs: [("x", input), ("y", projected)])
    }

    /// `concat(-x2, x1)`（最後の軸で前後を入れ替えて符号を変える）。演算 7 つ。
    private func rotateHalf(_ mil: inout MILProgram, tag: String, x: MILProgram.Value,
                            cos: MILProgram.Value, sin: MILProgram.Value) -> MILProgram.Value {
        let half = headDim / 2
        let full = [1, heads, seq, headDim]
        let halved = [1, heads, seq, half]

        let straight = mil.op("mul",
                              out: .init(name: "\(tag)_cos", type: .init(.fp16, full)),
                              inputs: [("x", x), ("y", cos)])

        let beginLow = mil.constant("\(tag)_lo_begin", .init(.int32, [4]), .ints([0, 0, 0, 0]))
        let endLow = mil.constant("\(tag)_lo_end", .init(.int32, [4]),
                                  .ints([1, Int32(heads), Int32(seq), Int32(half)]))
        // `end_mask` は「その軸では end を無視して端まで行く」という指示。
        // 切る軸だけを効かせるので、最後の 1 つだけ false にする。
        let maskLow = mil.constant("\(tag)_lo_mask", .init(.bool, [4]),
                                   .bools([true, true, true, false]))
        let x1 = mil.op("slice_by_index",
                        out: .init(name: "\(tag)_x1", type: .init(.fp16, halved)),
                        inputs: [("x", x), ("begin", beginLow), ("end", endLow),
                                 ("end_mask", maskLow)])

        let beginHigh = mil.constant("\(tag)_hi_begin", .init(.int32, [4]),
                                     .ints([0, 0, 0, Int32(half)]))
        let endHigh = mil.constant("\(tag)_hi_end", .init(.int32, [4]),
                                   .ints([1, Int32(heads), Int32(seq), Int32(headDim)]))
        let maskHigh = mil.constant("\(tag)_hi_mask", .init(.bool, [4]),
                                    .bools([true, true, true, true]))
        let x2 = mil.op("slice_by_index",
                        out: .init(name: "\(tag)_x2", type: .init(.fp16, halved)),
                        inputs: [("x", x), ("begin", beginHigh), ("end", endHigh),
                                 ("end_mask", maskHigh)])

        let minusOne = mil.constant("\(tag)_neg1", .init(.fp16, []), .halves([-1]))
        let negated = mil.op("mul",
                             out: .init(name: "\(tag)_negx2", type: .init(.fp16, halved)),
                             inputs: [("x", x2), ("y", minusOne)])

        let axis = mil.constant("\(tag)_cat_axis", .init(.int32, []), .ints([-1]))
        let interleave = mil.constant("\(tag)_interleave", .init(.bool, []), .bools([false]))
        let rotated = mil.op("concat",
                             out: .init(name: "\(tag)_rot", type: .init(.fp16, full)),
                             inputs: [("axis", axis), ("interleave", interleave)],
                             variadic: ("values", [negated, x1]))
        let crossed = mil.op("mul",
                             out: .init(name: "\(tag)_sin", type: .init(.fp16, full)),
                             inputs: [("x", rotated), ("y", sin)])
        return mil.op("add",
                      out: .init(name: "\(tag)_rope", type: .init(.fp16, full)),
                      inputs: [("x", straight), ("y", crossed)])
    }

    // MARK: - 中間層（演算 17〜23）

    private func feedForward(_ mil: inout MILProgram, layer: Int, input: MILProgram.Value,
                             weights: BlockOffsets, epsilon: MILProgram.Value) -> MILProgram.Value {
        let tag = { (name: String) in "l\(layer)_\(name)" }
        let hiddenShape = [1, seq, hidden]

        let gamma = mil.constant(tag("mlp_norm"), .init(.fp16, [hidden]),
                                 .blob(offset: weights.mlpNorm))
        let axes = mil.constant(tag("mlp_norm_axes"), .init(.int32, [1]), .ints([-1]))
        let normed = mil.op("layer_norm",
                            out: .init(name: tag("mlp_normed"), type: .init(.fp16, hiddenShape)),
                            inputs: [("x", input), ("axes", axes),
                                     ("epsilon", epsilon), ("gamma", gamma)])

        let wi = mil.constant(tag("mlp_wi"), .init(.fp16, [2 * intermediate, hidden]),
                              .blob(offset: weights.mlpWi))
        let wiBias = mil.constant(tag("mlp_wi_bias"), .init(.fp16, [2 * intermediate]),
                                  .blob(offset: weights.mlpWiBias))
        let wide = mil.op("linear",
                          out: .init(name: tag("mlp_wide"),
                                     type: .init(.fp16, [1, seq, 2 * intermediate])),
                          inputs: [("x", normed), ("weight", wi), ("bias", wiBias)])

        let gegluAxis = mil.constant(tag("geglu_axis"), .init(.int32, []), .ints([-1]))
        let gegluSizes = mil.constant(tag("geglu_sizes"), .init(.int32, [2]),
                                      .ints([Int32(intermediate), Int32(intermediate)]))
        let halves = mil.split("split",
                               outs: [.init(name: tag("gate_in"),
                                            type: .init(.fp16, [1, seq, intermediate])),
                                      .init(name: tag("up"),
                                            type: .init(.fp16, [1, seq, intermediate]))],
                               inputs: [("x", wide), ("axis", gegluAxis),
                                        ("split_sizes", gegluSizes)])

        // gelu は mode を取り、silu は入力だけを取る。
        // 下流の形は同じなので、2 つはこの 1 つの演算だけが違う。
        let gateOut = MILProgram.Value(name: tag("gate"),
                                       type: .init(.fp16, [1, seq, intermediate]))
        let gate: MILProgram.Value
        switch config.activation {
        case .gelu:
            let mode = mil.constant(tag("gelu_mode"), .init(.string, []), .strings(["EXACT"]))
            gate = mil.op("gelu", out: gateOut, inputs: [("x", halves[0]), ("mode", mode)])
        case .silu:
            gate = mil.op("silu", out: gateOut, inputs: [("x", halves[0])])
        }
        let gated = mil.op("mul",
                           out: .init(name: tag("gated"),
                                      type: .init(.fp16, [1, seq, intermediate])),
                           inputs: [("x", gate), ("y", halves[1])])

        let wo = mil.constant(tag("mlp_wo"), .init(.fp16, [hidden, intermediate]),
                              .blob(offset: weights.mlpWo))
        let woBias = mil.constant(tag("mlp_wo_bias"), .init(.fp16, [hidden]),
                                  .blob(offset: weights.mlpWoBias))
        let out = mil.op("linear",
                         out: .init(name: tag("mlp_out"), type: .init(.fp16, hiddenShape)),
                         inputs: [("x", gated), ("weight", wo), ("bias", woBias)])
        return mil.op("add",
                      out: .init(name: tag("out"), type: .init(.fp16, hiddenShape)),
                      inputs: [("x", input), ("y", out)])
    }
}
