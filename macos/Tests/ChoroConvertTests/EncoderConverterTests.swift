import XCTest
@testable import ChoroConvert

/// 変換の入口。
///
/// **いちばん強い審判は別にある**（実物を変換して参照実装と数を突き合わせる。
/// `Tests/ChoroConvertTests/README.md`）。ここで見るのは、
/// モデルが無い機械でも守れる筋である。
final class EncoderConverterTests: XCTestCase {
    /// 小さな checkpoint をその場で組む。
    private func weights(hidden: Int = 8, heads: Int = 2, layers: Int = 3,
                         intermediate: Int = 16, vocab: Int = 20,
                         skip: String? = nil, extra: [String: [Int]] = [:]) throws -> Safetensors {
        var shapes: [String: [Int]] = [
            "embeddings.tok_embeddings.weight": [vocab, hidden],
            "embeddings.norm.weight": [hidden],
            "final_norm.weight": [hidden],
        ]
        for layer in 0 ..< layers {
            shapes["layers.\(layer).attn.Wqkv.weight"] = [3 * hidden, hidden]
            shapes["layers.\(layer).attn.Wo.weight"] = [hidden, hidden]
            shapes["layers.\(layer).mlp_norm.weight"] = [hidden]
            shapes["layers.\(layer).mlp.Wi.weight"] = [2 * intermediate, hidden]
            shapes["layers.\(layer).mlp.Wo.weight"] = [hidden, intermediate]
            if layer > 0 { shapes["layers.\(layer).attn_norm.weight"] = [hidden] }
        }
        for (name, shape) in extra { shapes[name] = shape }
        if let skip { shapes[skip] = nil }

        var header: [String: Any] = [:]
        var body = [UInt8]()
        for (name, shape) in shapes.sorted(by: { $0.key < $1.key }) {
            let count = shape.reduce(1, *)
            header[name] = ["dtype": "F32", "shape": shape,
                            "data_offsets": [body.count, body.count + count * 4]]
            for at in 0 ..< count {
                let value = Float(at % 7) * 0.01
                for shift in stride(from: 0, to: 32, by: 8) {
                    body.append(UInt8((value.bitPattern >> UInt32(shift)) & 0xff))
                }
            }
        }
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var out = [UInt8]()
        for shift in stride(from: 0, to: 64, by: 8) {
            out.append(UInt8((UInt64(json.count) >> UInt64(shift)) & 0xff))
        }
        out.append(contentsOf: [UInt8](json))
        out.append(contentsOf: body)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-conv-\(UUID().uuidString).safetensors")
        try Data(out).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try Safetensors(contentsOf: url)
    }

    private func config(hidden: Int = 8, heads: Int = 2, layers: Int = 3,
                        intermediate: Int = 16, vocab: Int = 20) throws -> EncoderConfig {
        try EncoderConfig(json: """
        {"hidden_size": \(hidden), "num_attention_heads": \(heads),
         "num_hidden_layers": \(layers), "intermediate_size": \(intermediate),
         "vocab_size": \(vocab), "norm_eps": 1e-5, "local_attention": 8,
         "global_attn_every_n_layers": 2, "local_rope_theta": 10000.0,
         "global_rope_theta": 160000.0, "max_position_embeddings": 128,
         "hidden_activation": "gelu"}
        """)
    }

    func test_変換できる() throws {
        let made = try EncoderConverter(config: try config(), weights: try weights())
            .convert(lengths: [8, 16])
        XCTAssertFalse(made.model.data.isEmpty)
        XCTAssertGreaterThan(made.blob.count, 64)
        XCTAssertTrue(made.unused.isEmpty, "読まなかった重みがある：\(made.unused)")
    }

    /// **使わなかった重みを申告すること。**
    ///
    /// 名前を 1 つ読み違えても変換は通り、初期値のままの層を持つモデルができて、
    /// それらしい数が出る。これが唯一の防壁である。
    func test_使わなかった重みを申告する() throws {
        let made = try EncoderConverter(config: try config(),
                                        weights: try weights(extra: ["余りもの.weight": [4]]))
            .convert(lengths: [8])
        XCTAssertEqual(made.unused, ["余りもの.weight"])
    }

    /// 足りない重みは、まとめて言うこと。
    func test_足りない重みはまとめて言う() throws {
        do {
            _ = try EncoderConverter(config: try config(),
                                     weights: try weights(skip: "final_norm.weight"))
                .convert(lengths: [8])
            XCTFail("通してしまった")
        } catch let error as EncoderConverter.Failure {
            guard case let .missing(names) = error else { return XCTFail("種類が違う") }
            XCTAssertEqual(names, ["final_norm.weight"])
        }
    }

    /// **形が違う重みは受け取らない。** 受け取ると、別の層の重みを
    /// 読んだまま変換が通る。
    func test_形が違えば落とす() throws {
        let bad = try weights(extra: ["final_norm.weight": [999]])
        XCTAssertThrowsError(try EncoderConverter(config: try config(), weights: bad)
            .convert(lengths: [8]))
    }

    /// バケットごとに関数ができること。名前はアプリ側と揃える。
    func test_バケットごとに関数ができる() throws {
        let made = try EncoderConverter(config: try config(), weights: try weights())
            .convert(lengths: [16, 8])
        let text = String(decoding: made.model.data, as: UTF8.self)
        XCTAssertTrue(text.contains("seq_8"))
        XCTAssertTrue(text.contains("seq_16"))
        XCTAssertEqual(EncoderConverter.functionName(256), "seq_256")
    }

    /// **同じ入力からは同じ bytes が出ること。**
    /// 出るたびに違うと、変換物を突き合わせられない。
    func test_2度変換しても同じものが出る() throws {
        let converter = EncoderConverter(config: try config(), weights: try weights())
        let first = try converter.convert(lengths: [8, 16])
        let second = try converter.convert(lengths: [8, 16])
        XCTAssertEqual(first.model.data, second.model.data)
        XCTAssertEqual(first.blob, second.blob)
    }
}
