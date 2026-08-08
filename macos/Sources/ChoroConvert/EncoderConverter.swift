import Foundation

public struct EncoderConverter {
    let config: EncoderConfig
    let weights: Safetensors

    public init(config: EncoderConfig, weights: Safetensors) {
        self.config = config
        self.weights = weights
    }

    static func functionName(_ length: Int) -> String { "seq_\(length)" }

    public struct Made {
        public var model: ModelBytes
        public var blob: Data
        /// 読まなかった重みの名前。空でなければ、どこかを取りこぼしている。
        public var unused: [String]
    }

    public enum Failure: Error, LocalizedError {
        case missing([String])

        public var errorDescription: String? {
            switch self {
            case let .missing(names):
                return "checkpoint に無い重みがあります：\n" + names.map { "  ・\($0)" }.joined(separator: "\n")
            }
        }
    }

    public func convert(lengths: [Int]) throws -> Made {
        try config.check(lengths: lengths)

        var blob = WeightBlob()
        var read = Set<String>()

        func place(_ name: String, expected: [Int]) throws -> UInt64 {
            read.insert(name)
            let values = try weights.read(name)
            let shape = weights.shape(of: name) ?? []
            guard shape == expected else {
                throw Safetensors.Failure.cannotRead(
                    "\(name) の形が \(shape) で、期待する \(expected) と違います")
            }
            return blob.append(fp16: values)
        }

        var missing: [String] = []
        func require(_ names: [String]) {
            missing.append(contentsOf: names.filter { weights.shape(of: $0) == nil })
        }
        let hidden = config.hidden
        let intermediate = config.intermediate
        let p = config.prefix
        require(["\(p)embeddings.tok_embeddings.weight", "\(p)embeddings.norm.weight",
                 "\(p)final_norm.weight"])
        if config.isClassifier {
            require(["head.dense.weight", "head.norm.weight",
                     "classifier.weight", "classifier.bias"])
        }
        for layer in 0 ..< config.layers {
            require(["\(p)layers.\(layer).attn.Wqkv.weight", "\(p)layers.\(layer).attn.Wo.weight",
                     "\(p)layers.\(layer).mlp_norm.weight", "\(p)layers.\(layer).mlp.Wi.weight",
                     "\(p)layers.\(layer).mlp.Wo.weight"])
        }
        guard missing.isEmpty else { throw Failure.missing(missing) }

        let tokens = try place("\(p)embeddings.tok_embeddings.weight", expected: [config.vocab, hidden])
        let embeddingNorm = try place("\(p)embeddings.norm.weight", expected: [hidden])
        let finalNorm = try place("\(p)final_norm.weight", expected: [hidden])

        // 射影に bias は無いので（config で拒んである）、0 を置く。
        let zeroQKV = blob.append(fp16: [Float](repeating: 0, count: 3 * hidden))
        let zeroHidden = blob.append(fp16: [Float](repeating: 0, count: hidden))
        let zeroWide = blob.append(fp16: [Float](repeating: 0, count: 2 * intermediate))

        var perLayer: [(wqkv: UInt64, wo: UInt64, mlpNorm: UInt64,
                        mlpWi: UInt64, mlpWo: UInt64, attnNorm: UInt64?)] = []
        for layer in 0 ..< config.layers {
            // **層 0 は前正規化を持たない。** 埋め込みの後で正規化済みである。
            var attnNorm: UInt64?
            let normName = "\(p)layers.\(layer).attn_norm.weight"
            if weights.shape(of: normName) != nil {
                attnNorm = try place(normName, expected: [hidden])
            }
            perLayer.append((
                wqkv: try place("\(p)layers.\(layer).attn.Wqkv.weight", expected: [3 * hidden, hidden]),
                wo: try place("\(p)layers.\(layer).attn.Wo.weight", expected: [hidden, hidden]),
                mlpNorm: try place("\(p)layers.\(layer).mlp_norm.weight", expected: [hidden]),
                mlpWi: try place("\(p)layers.\(layer).mlp.Wi.weight", expected: [2 * intermediate, hidden]),
                mlpWo: try place("\(p)layers.\(layer).mlp.Wo.weight", expected: [hidden, intermediate]),
                attnNorm: attnNorm))
        }

        var head: ClassifierHead.Offsets?
        if config.isClassifier {
            head = .init(dense: try place("head.dense.weight", expected: [hidden, hidden]),
                         norm: try place("head.norm.weight", expected: [hidden]),
                         classifier: try place("classifier.weight", expected: [1, hidden]),
                         classifierBias: try place("classifier.bias", expected: [1]))
        }

        var functions: [(name: String, function: Protowire)] = []
        var described: [(name: String, inputs: [ModelPackage.Feature],
                         outputs: [ModelPackage.Feature])] = []

        for length in lengths.sorted() {
            let local = ModernBERTGraph.ropeTables(seq: length, headDim: config.headDim,
                                                   theta: config.localRopeTheta)
            let global = ModernBERTGraph.ropeTables(seq: length, headDim: config.headDim,
                                                    theta: config.globalRopeTheta)
            let localCos = blob.append(fp16: local.cos)
            let localSin = blob.append(fp16: local.sin)
            let globalCos = blob.append(fp16: global.cos)
            let globalSin = blob.append(fp16: global.sin)
            let graph = ModernBERTGraph(config: config, seq: length)
            var mil = MILProgram()
            let ids = MILProgram.Value(name: "input_ids", type: .init(.int32, [1, length]))
            let attention = MILProgram.Value(name: "attention_mask",
                                             type: .init(.int32, [1, length]))

            let blocks = perLayer.enumerated().map { at, one -> ModernBERTGraph.BlockOffsets in
                let isGlobal = config.isGlobal(layer: at)
                return .init(attnNorm: one.attnNorm, wqkv: one.wqkv, wqkvBias: zeroQKV,
                             wo: one.wo, woBias: zeroHidden, mlpNorm: one.mlpNorm,
                             mlpWi: one.mlpWi, mlpWiBias: zeroWide,
                             mlpWo: one.mlpWo, mlpWoBias: zeroHidden,
                             ropeCos: isGlobal ? globalCos : localCos,
                             ropeSin: isGlobal ? globalSin : localSin)
            }

            var out = graph.build(into: &mil, ids: ids, attentionMask: attention,
                                  blocks: blocks, tokens: tokens,
                                  embeddingNorm: embeddingNorm, finalNorm: finalNorm)
            if let head {
                // epsilon は胴体が置いたものを使い回せないので、頭でも 1 つ置く。
                let epsilon = mil.constant("head_epsilon", .init(.fp16, []),
                                           .halves([config.eps]))
                out = ClassifierHead(config: config, seq: length)
                    .build(into: &mil, hidden: out, attentionMask: attention,
                           weights: head, epsilon: epsilon)
            }

            let name = Self.functionName(length)
            // `attention_mask` は**使う**。詰め物の位置を注意から外すためである。
            functions.append((name, mil.function(inputs: [ids, attention], outputs: [out])))
            described.append((name,
                              [.init(name: "input_ids", dataType: .int32, shape: [1, length]),
                               .init(name: "attention_mask", dataType: .int32, shape: [1, length])],
                              [.init(name: out.name, dataType: .fp16, shape: out.type.shape)]))
        }

        let program = MILProgram.program(functions: functions)
        let model = ModelPackage.model(program: program, functions: described,
                                       defaultFunction: described[0].name)
        let unused = weights.names.filter { !read.contains($0) }
        return Made(model: ModelBytes(model), blob: blob.finish(), unused: unused)
    }
}
