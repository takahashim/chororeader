import Foundation

/// ModernBERT の胴体を ONNX のグラフとして組む。
///
/// `ModernBERTGraph`（MIL 版）と**同じ順序・同じ計算**で、綴りだけが違う。
/// あちらの覚え書きはそのまま効くので、ここでは食い違うところだけを書く。
///
/// ## MIL と違うところ
///
/// - **長さが動く。** バケットが要らない。`seq` は入力から取り、rope の表は
///   最大長で焼いておいて切り出す。局所注意の窓は seq×seq が大きすぎるので、
///   焼かずにグラフの中で組む（`Range` から差の絶対値を取る）
/// - **重みはモデルの中に置く。** `weight.bin` を別に持たない
/// - **`linear` が無い。** 重みを転置して置き、`MatMul` 1 つで済ませる。
///   射影に bias は無いので（config で拒んである）足し算も要らない
/// - **`gelu` が無い**（opset 20 から）。`0.5x(1 + erf(x/√2))` を素で組む
/// - **マスクを広げなくてよい。** ONNX は放送するので `[1,1,1,S]` のまま足せる
///
/// ## 精度
///
/// 重みも計算も fp16 で通す。`LayerNormalization` だけは平均と分散を fp32 で
/// 取る（`stash_type` の既定）。Core ML 版と同じ精度になる。
public struct ONNXEncoder {
    let config: EncoderConfig
    let weights: Safetensors

    /// rope の表を焼いておく長さ。**ここを越える入力は通らない。**
    ///
    /// アプリ側（`OnnxEmbedder.MaximumTokens`）が同じ長さで切り詰めるので届かない。
    /// 8192 まで焼くこともできるが、表だけで 16 MB になる。
    public var maximumSequence: Int

    public init(config: EncoderConfig, weights: Safetensors, maximumSequence: Int = 2048) {
        self.config = config
        self.weights = weights
        self.maximumSequence = maximumSequence
    }

    public struct Made {
        public var model: Data
        /// 読まなかった重みの名前。空でなければ、どこかを取りこぼしている。
        public var unused: [String]
    }

    private var hidden: Int { config.hidden }
    private var heads: Int { config.heads }
    private var headDim: Int { config.headDim }
    private var intermediate: Int { config.intermediate }

    /// 塞ぐ値。**有限にする。`-inf` にしてはいけない**（理由は MIL 版に書いた）。
    static let blockedValue: Float = -65504

    // MARK: - 組み立て

    public func convert() throws -> Made {
        let made = try build()
        return Made(model: made.program.encoded(), unused: made.unused)
    }

    /// 組んだものをそのまま返す。**検査は書き出す前の形を見る。**
    /// 250 MB を吐いてから読ませるより、繋がりの検査はここで済ませたい。
    func build() throws -> (program: ONNXProgram, unused: [String]) {
        var program = ONNXProgram(name: "modernbert")
        var read = Set<String>()
        var builder = Builder(program: program)

        let p = config.prefix

        /// 重みを 1 つ置く。`transposed` なら `MatMul` が食える向きへ入れ替える。
        func place(_ name: String, expected: [Int], transposed: Bool = false) throws -> String {
            read.insert(name)
            let shape = weights.shape(of: name) ?? []
            guard shape == expected else {
                throw Safetensors.Failure.cannotRead(
                    "\(name) の形が \(shape) で、期待する \(expected) と違います")
            }
            let values = try weights.read(name)
            let label = name.replacingOccurrences(of: ".", with: "_")
            if transposed {
                let rows = expected[0], columns = expected[1]
                var swapped = [Float](repeating: 0, count: values.count)
                for row in 0 ..< rows {
                    for column in 0 ..< columns {
                        swapped[column * rows + row] = values[row * columns + column]
                    }
                }
                builder.weight(label, dims: [columns, rows], values: swapped)
            } else {
                builder.weight(label, dims: expected, values: values)
            }
            return label
        }

        var missing: [String] = []
        func require(_ names: [String]) {
            missing.append(contentsOf: names.filter { weights.shape(of: $0) == nil })
        }
        require(["\(p)embeddings.tok_embeddings.weight", "\(p)embeddings.norm.weight",
                 "\(p)final_norm.weight"])
        for layer in 0 ..< config.layers {
            require(["\(p)layers.\(layer).attn.Wqkv.weight", "\(p)layers.\(layer).attn.Wo.weight",
                     "\(p)layers.\(layer).mlp_norm.weight", "\(p)layers.\(layer).mlp.Wi.weight",
                     "\(p)layers.\(layer).mlp.Wo.weight"])
        }
        guard missing.isEmpty else { throw EncoderConverter.Failure.missing(missing) }

        // 語彙の表。**転置しない**（`Gather` は行で引く）。
        let table = try place("\(p)embeddings.tok_embeddings.weight", expected: [config.vocab, hidden])
        let embeddingNorm = try place("\(p)embeddings.norm.weight", expected: [hidden])
        let finalNorm = try place("\(p)final_norm.weight", expected: [hidden])

        // 語彙から引いて正規化する。
        // **負の id は表の後ろへ回り込む。** ONNX の Gather がそう定めているので、
        // MIL 版が 4 つの演算で組んでいたところが要らない。
        let embedded = builder.op("Gather", ["embedded"], [table, "input_ids"],
                                  [.int("axis", 0)])
        var stream = builder.layerNorm("emb_normed", embedded, embeddingNorm, config.eps)

        // rope の表。**層ごとに theta が違う**（局所と全域）。
        let local = ModernBERTGraph.ropeTables(seq: maximumSequence, headDim: headDim,
                                               theta: config.localRopeTheta)
        let global = ModernBERTGraph.ropeTables(seq: maximumSequence, headDim: headDim,
                                                theta: config.globalRopeTheta)
        builder.weight("rope_local_cos", dims: [1, 1, maximumSequence, headDim], values: local.cos)
        builder.weight("rope_local_sin", dims: [1, 1, maximumSequence, headDim], values: local.sin)
        builder.weight("rope_global_cos", dims: [1, 1, maximumSequence, headDim], values: global.cos)
        builder.weight("rope_global_sin", dims: [1, 1, maximumSequence, headDim], values: global.sin)

        let length = builder.sequenceLength()
        let ropes = builder.sliceRope(to: length)
        let masks = builder.masks(length: length, window: config.localAttention)

        for layer in 0 ..< config.layers {
            let isGlobal = config.isGlobal(layer: layer)
            let tag = "l\(layer)"

            var attnNorm: String?
            let normName = "\(p)layers.\(layer).attn_norm.weight"
            if weights.shape(of: normName) != nil {
                attnNorm = try place(normName, expected: [hidden])
            }

            stream = builder.attention(
                tag: tag, input: stream,
                normGamma: attnNorm,
                wqkv: try place("\(p)layers.\(layer).attn.Wqkv.weight",
                                expected: [3 * hidden, hidden], transposed: true),
                wo: try place("\(p)layers.\(layer).attn.Wo.weight",
                              expected: [hidden, hidden], transposed: true),
                cos: isGlobal ? ropes.globalCos : ropes.localCos,
                sin: isGlobal ? ropes.globalSin : ropes.localSin,
                mask: isGlobal ? masks.global : masks.local,
                heads: heads, headDim: headDim, hidden: hidden,
                scale: 1 / Float(headDim).squareRoot(), eps: config.eps)

            stream = builder.feedForward(
                tag: tag, input: stream,
                normGamma: try place("\(p)layers.\(layer).mlp_norm.weight", expected: [hidden]),
                wi: try place("\(p)layers.\(layer).mlp.Wi.weight",
                              expected: [2 * intermediate, hidden], transposed: true),
                wo: try place("\(p)layers.\(layer).mlp.Wo.weight",
                              expected: [hidden, intermediate], transposed: true),
                intermediate: intermediate, hidden: hidden,
                activation: config.activation, eps: config.eps)
        }

        let tokens = builder.layerNorm("token_embeddings", stream, finalNorm, config.eps)
        let pooled = builder.meanPool("sentence_embedding", tokens)

        // **出入口は組み終えてから置く。**
        // `Builder` は写しを持って回るので、先に置いても最後の受け取りで消える
        // （実際に踏んだ。ONNX Runtime が「input_ids が入口でも定数でもない」と言った）。
        program = builder.program
        program.inputs = [
            .init(name: "input_ids", type: .int64, shape: [.named("batch"), .named("seq")]),
            .init(name: "attention_mask", type: .int64, shape: [.named("batch"), .named("seq")]),
        ]
        program.outputs = [
            .init(name: tokens, type: .float16,
                  shape: [.named("batch"), .named("seq"), .fixed(hidden)]),
            .init(name: pooled, type: .float16, shape: [.named("batch"), .fixed(hidden)]),
        ]
        let unused = weights.names.filter { !read.contains($0) }
        return (program, unused)
    }
}
