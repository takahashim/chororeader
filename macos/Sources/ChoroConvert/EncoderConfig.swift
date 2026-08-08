import Foundation

/// `config.json` から、グラフを組むのに要る値を読む。
///
/// **組み上げるグラフは決め打ちである。** 射影に bias は付けず、rope は head の
/// 幅いっぱいに掛け、全域注意の層は `層 % n == 0` で選ぶ。config がそれと違うことを
/// 言っていても変換は通り、**それらしい数まで出る**。だから読むときに拒む。
///
/// 拒む理由は全部まとめて言う。使えない checkpoint を見ている人が欲しいのは
/// 一覧であって、最初の 1 つではない（kohagi の `graph_assumptions` から移した）。
public struct EncoderConfig {
    var hidden: Int
    var heads: Int
    var layers: Int
    var intermediate: Int
    var vocab: Int
    var eps: Float
    /// 局所注意の窓の幅。
    var localAttention: Int
    /// この間隔ごとの層が全域を見る。ほかは窓の中だけを見る。
    var globalEvery: Int
    var localRopeTheta: Float
    var globalRopeTheta: Float
    /// checkpoint が学習された最も長い位置。
    ///
    /// **これを超えるバケットは、後ろに学習された rope が無い。**
    /// 動きはするが間違った数を出す。
    var maxPositions: Int
    /// 中間層の門の活性。
    var activation: Activation
    /// 分類頭を持つか（reranker）。
    var isClassifier: Bool
    /// 分類頭のプーリング。**推測しない**（transformers の実装から確かめた）。
    var classifierPooling: Pooling
    /// 分類頭の活性。
    var classifierActivation: Activation
    /// 重みの名前に付く前置き。分類頭のある checkpoint は `model.` が付く。
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
        // ruri は norm_eps、ほかは layer_norm_eps を持つ。どちらも受ける。
        eps = Float(number("norm_eps") ?? number("layer_norm_eps") ?? 1e-5)
        localAttention = Int(number("local_attention") ?? 128)
        globalEvery = Int(number("global_attn_every_n_layers") ?? 3)
        // theta の置き場所が 2 通りある。**新しい config は `rope_parameters` の側に持ち、
        // 平らな鍵は null になる。** そこだけを見ていると既定値で変換が通り、
        // 静かに違うベクトルが出る（実際に踏んだ。cosine 0.14）。
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
        // 分類頭のある checkpoint は胴体の重みに `model.` が付く。
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

    /// **決め打ちのグラフが守れない言い分**を集める。
    ///
    /// どれも値にはならない。読んで無視すると、通って、それらしい数が出て、
    /// 順位だけが静かに狂う。
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

        // 組み上げる rope は伸縮しない。既定でない rope_type は参照実装だけが効かせる。
        if let rope = root["rope_parameters"] as? [String: Any] {
            for kind in ["full_attention", "sliding_attention"] {
                guard let one = rope[kind] as? [String: Any],
                      let type = one["rope_type"] as? String, type != "default" else { continue }
                out.append("rope_parameters.\(kind).rope_type が \(type) だが、"
                    + "組み上げる rope は伸縮しない")
            }
        }

        // layer_types があるなら、そちらが正しい。間隔で選ぶこちらの規則が違うことになる。
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

    /// この層は全域を見るか。
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
