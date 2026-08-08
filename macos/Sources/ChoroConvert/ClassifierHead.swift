import Foundation

/// 分類頭（reranker）
struct ClassifierHead {
    let config: EncoderConfig
    let seq: Int

    struct Offsets {
        var dense: UInt64
        var norm: UInt64
        var classifier: UInt64
        var classifierBias: UInt64
    }

    /// 隠れ状態から score を作る。
    func build(into mil: inout MILProgram, hidden state: MILProgram.Value,
               attentionMask: MILProgram.Value, weights: Offsets,
               epsilon: MILProgram.Value) -> MILProgram.Value {
        let width = config.hidden

        // プーリング。**cls は先頭のトークンだけを取る。**
        let pooled: MILProgram.Value
        switch config.classifierPooling {
        case .cls:
            let begin = mil.constant("pool_begin", .init(.int32, [3]), .ints([0, 0, 0]))
            let end = mil.constant("pool_end", .init(.int32, [3]),
                                   .ints([1, 1, Int32(width)]))
            let endMask = mil.constant("pool_end_mask", .init(.bool, [3]),
                                       .bools([true, false, true]))
            let sliced = mil.op("slice_by_index",
                                out: .init(name: "pool_sliced", type: .init(.fp16, [1, 1, width])),
                                inputs: [("x", state), ("begin", begin), ("end", end),
                                         ("end_mask", endMask)])
            let axes = mil.constant("pool_axes", .init(.int32, [1]), .ints([1]))
            pooled = mil.op("squeeze",
                            out: .init(name: "pooled", type: .init(.fp16, [1, width])),
                            inputs: [("x", sliced), ("axes", axes)])
        case .mean:
            pooled = meanPooled(&mil, state: state, attentionMask: attentionMask)
        }

        let dense = mil.constant("head_dense", .init(.fp16, [width, width]),
                                 .blob(offset: weights.dense))
        let denseBias = mil.constant("head_dense_bias", .init(.fp16, [width]),
                                     .halves([Float](repeating: 0, count: width)))
        let projected = mil.op("linear",
                               out: .init(name: "head_projected", type: .init(.fp16, [1, width])),
                               inputs: [("x", pooled), ("weight", dense), ("bias", denseBias)])

        let activated = MILProgram.Value(name: "head_activated", type: .init(.fp16, [1, width]))
        let gated: MILProgram.Value
        switch config.classifierActivation {
        case .gelu:
            let mode = mil.constant("head_gelu_mode", .init(.string, []), .strings(["EXACT"]))
            gated = mil.op("gelu", out: activated, inputs: [("x", projected), ("mode", mode)])
        case .silu:
            gated = mil.op("silu", out: activated, inputs: [("x", projected)])
        }

        let gamma = mil.constant("head_norm", .init(.fp16, [width]), .blob(offset: weights.norm))
        let axes = mil.constant("head_norm_axes", .init(.int32, [1]), .ints([-1]))
        let normed = mil.op("layer_norm",
                            out: .init(name: "head_normed", type: .init(.fp16, [1, width])),
                            inputs: [("x", gated), ("axes", axes),
                                     ("epsilon", epsilon), ("gamma", gamma)])

        let classifier = mil.constant("classifier", .init(.fp16, [1, width]),
                                      .blob(offset: weights.classifier))
        let bias = mil.constant("classifier_bias", .init(.fp16, [1]),
                                .blob(offset: weights.classifierBias))
        return mil.op("linear",
                      out: .init(name: "score", type: .init(.fp16, [1, 1])),
                      inputs: [("x", normed), ("weight", classifier), ("bias", bias)])
    }

    /// 詰め物を外して平均する。`classifier_pooling` が mean のとき。
    private func meanPooled(_ mil: inout MILProgram, state: MILProgram.Value,
                            attentionMask: MILProgram.Value) -> MILProgram.Value {
        let width = config.hidden
        let toFp16 = mil.constant("pool_dtype", .init(.string, []), .strings(["fp16"]))
        let asFp16 = mil.op("cast",
                            out: .init(name: "pool_mask", type: .init(.fp16, [1, seq])),
                            inputs: [("x", attentionMask), ("dtype", toFp16)])
        let axes = mil.constant("pool_expand_axes", .init(.int32, [1]), .ints([2]))
        let expanded = mil.op("expand_dims",
                              out: .init(name: "pool_mask3", type: .init(.fp16, [1, seq, 1])),
                              inputs: [("x", asFp16), ("axes", axes)])
        let masked = mil.op("mul",
                            out: .init(name: "pool_masked", type: .init(.fp16, [1, seq, width])),
                            inputs: [("x", state), ("y", expanded)])
        let sumAxes = mil.constant("pool_sum_axes", .init(.int32, [1]), .ints([1]))
        let keep = mil.constant("pool_keep", .init(.bool, []), .bools([false]))
        let total = mil.op("reduce_sum",
                           out: .init(name: "pool_sum", type: .init(.fp16, [1, width])),
                           inputs: [("x", masked), ("axes", sumAxes), ("keep_dims", keep)])
        let count = mil.op("reduce_sum",
                           out: .init(name: "pool_count", type: .init(.fp16, [1])),
                           inputs: [("x", asFp16), ("axes", sumAxes), ("keep_dims", keep)])
        let countAxes = mil.constant("pool_count_axes", .init(.int32, [1]), .ints([1]))
        let widened = mil.op("expand_dims",
                             out: .init(name: "pool_count2", type: .init(.fp16, [1, 1])),
                             inputs: [("x", count), ("axes", countAxes)])
        return mil.op("real_div",
                      out: .init(name: "pooled", type: .init(.fp16, [1, width])),
                      inputs: [("x", total), ("y", widened)])
    }
}
