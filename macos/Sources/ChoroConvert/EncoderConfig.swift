import Foundation

public struct EncoderConfig {
    public var hidden: Int
    var heads: Int
    public var layers: Int
    var intermediate: Int
    var vocab: Int
    var eps: Float
    /// 局所注意の窓の幅。
    var localAttention: Int
    var globalEvery: Int
    var localRopeTheta: Float
    var globalRopeTheta: Float
    /// checkpoint が学習された最も長い位置。
    ///
    /// **これを超えるバケットは、後ろに学習された rope が無い。**
    /// 動きはするが間違った数を出す。
    var maxPositions: Int
    var activation: Activation
    public var isClassifier: Bool
    /// 分類頭のプーリング。**推測しない**（transformers の実装から確かめた）。
    var classifierPooling: Pooling
    var classifierActivation: Activation
    var prefix: String

    enum Pooling: String {
        case cls
        case mean
    }

    enum Activation: String {
        case gelu
        case silu
    }

    var headDim: Int { hidden / heads }

    public enum Failure: Error, LocalizedError {
        case cannotRead(String)
        case unsupported([String])

        public var errorDescription: String? {
            switch self {
            case let .cannotRead(why):
                return "config.json を読めません：\(why)"
            case let .unsupported(reasons):
                return "この checkpoint は変換できません：\n" + reasons.map { "  ・\($0)" }.joined(separator: "\n")
            }
        }
    }

    public init(json text: String) throws {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.cannotRead("JSON として読めません") }

        func number(_ key: String) -> Double? { (root[key] as? NSNumber)?.doubleValue }
        func integer(_ key: String) throws -> Int {
            guard let value = number(key) else { throw Failure.cannotRead("\(key) がありません") }
            return Int(value)
        }

        hidden = try integer("hidden_size")
        heads = try integer("num_attention_heads")
        layers = try integer("num_hidden_layers")
        intermediate = try integer("intermediate_size")
        vocab = try integer("vocab_size")
        eps = Float(number("norm_eps") ?? number("layer_norm_eps") ?? 1e-5)
        localAttention = Int(number("local_attention") ?? 128)
        globalEvery = Int(number("global_attn_every_n_layers") ?? 3)
        let ropeParameters = root["rope_parameters"] as? [String: Any]
        func theta(_ kind: String, _ flat: String, _ fallback: Double) -> Float {
            if let one = ropeParameters?[kind] as? [String: Any],
               let value = (one["rope_theta"] as? NSNumber)?.doubleValue {
                return Float(value)
            }
            return Float(number(flat) ?? number("rope_theta") ?? fallback)
        }
        localRopeTheta = theta("sliding_attention", "local_rope_theta", 10000)
        globalRopeTheta = theta("full_attention", "global_rope_theta", 160000)
        maxPositions = Int(number("max_position_embeddings") ?? 8192)

        let name = (root["hidden_activation"] as? String) ?? "gelu"
        guard let activation = Activation(rawValue: name.replacingOccurrences(of: "_", with: "")) else {
            throw Failure.cannotRead("hidden_activation が \(name) は扱いません")
        }
        self.activation = activation

        let architectures = (root["architectures"] as? [String]) ?? []
        isClassifier = architectures.contains { $0.contains("SequenceClassification") }
        prefix = isClassifier ? "model." : ""

        let poolingName = (root["classifier_pooling"] as? String) ?? "cls"
        guard let pooling = Pooling(rawValue: poolingName) else {
            throw Failure.cannotRead("classifier_pooling が \(poolingName) は扱いません")
        }
        classifierPooling = pooling

        let headName = (root["classifier_activation"] as? String) ?? "gelu"
        guard let headActivation = Activation(rawValue: headName.replacingOccurrences(of: "_", with: "")) else {
            throw Failure.cannotRead("classifier_activation が \(headName) は扱いません")
        }
        classifierActivation = headActivation

        let reasons = Self.assumptions(root, globalEvery: globalEvery, hidden: hidden, heads: heads)
        guard reasons.isEmpty else { throw Failure.unsupported(reasons) }
    }

    private static func assumptions(_ root: [String: Any], globalEvery: Int,
                                    hidden: Int, heads: Int) -> [String] {
        var out: [String] = []

        // 組み上げる linear はどれも bias を持たず、正規化は gamma だけを持つ。
        // **分類器だけは bias を持つ**（transformers もそう組んでいる）。
        for (key, what) in [("attention_bias", "注意の射影"),
                            ("mlp_bias", "中間層の射影"),
                            ("norm_bias", "正規化"),
                            ("classifier_bias", "分類頭の dense")] {
            if (root[key] as? Bool) == true {
                out.append("\(key) が true だが、組み上げるグラフは\(what)に bias を持たせない")
            }
        }

        if let rope = root["rope_parameters"] as? [String: Any] {
            for kind in ["full_attention", "sliding_attention"] {
                guard let one = rope[kind] as? [String: Any],
                      let type = one["rope_type"] as? String, type != "default" else { continue }
                out.append("rope_parameters.\(kind).rope_type が \(type) だが、"
                    + "組み上げる rope は伸縮しない")
            }
        }

        if let types = root["layer_types"] as? [String] {
            let disagree = types.enumerated().compactMap { at, type -> Int? in
                let global = type == "full_attention"
                return global == (globalEvery != 0 && at % globalEvery == 0) ? nil : at
            }
            if !disagree.isEmpty {
                out.append("layer_types の層 \(disagree) が "
                    + "global_attn_every_n_layers \(globalEvery) と食い違う。"
                    + "組み上げるグラフは間隔の方に従う")
            }
        }

        // head の幅で割り切れないと、rope の掛け方が変わる。
        if heads == 0 || hidden % heads != 0 {
            out.append("hidden_size \(hidden) が num_attention_heads \(heads) で割り切れない")
        } else if (hidden / heads) % 2 != 0 {
            out.append("head の幅 \(hidden / heads) が偶数でない。rope は 2 つ組で回す")
        }

        return out
    }

    func isGlobal(layer: Int) -> Bool {
        globalEvery != 0 && layer % globalEvery == 0
    }

    /// バケットの長さが使えるかを見る。
    ///
    /// **学習された位置を超えるバケットは、動いて、間違った数を出す。**
    func check(lengths: [Int]) throws {
        var reasons: [String] = []
        for length in lengths {
            if length <= 0 { reasons.append("バケットの長さ \(length) が正でない") }
            if length > maxPositions {
                reasons.append("バケットの長さ \(length) が、学習された位置 \(maxPositions) を超える")
            }
        }
        if lengths.isEmpty { reasons.append("バケットが 1 つも無い") }
        if Set(lengths).count != lengths.count { reasons.append("同じ長さのバケットが 2 つある") }
        guard reasons.isEmpty else { throw Failure.unsupported(reasons) }
    }
}
