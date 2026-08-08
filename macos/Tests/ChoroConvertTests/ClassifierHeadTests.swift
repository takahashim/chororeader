import XCTest
@testable import ChoroConvert

/// 分類頭（reranker）。
///
/// **形は推測しない。** transformers の実装（`ModernBertPredictionHead` と
/// `ModernBertForSequenceClassification.forward`）から確かめて写した。
/// 数の審判は実物での照合（`Tests/ChoroConvertTests/README.md`）で、
/// ここではモデル無しで守れる筋を見る。
final class ClassifierHeadTests: XCTestCase {
    private func config(pooling: String = "cls", activation: String = "gelu",
                        classifier: Bool = true) throws -> EncoderConfig {
        let architectures = classifier ? "\"ModernBertForSequenceClassification\"" : "\"ModernBertModel\""
        return try EncoderConfig(json: """
        {"architectures": [\(architectures)],
         "hidden_size": 16, "num_attention_heads": 2, "num_hidden_layers": 2,
         "intermediate_size": 32, "vocab_size": 50, "norm_eps": 1e-5,
         "local_attention": 8, "global_attn_every_n_layers": 2,
         "max_position_embeddings": 128, "hidden_activation": "gelu",
         "classifier_pooling": "\(pooling)", "classifier_activation": "\(activation)"}
        """)
    }

    /// 分類頭のある checkpoint を見分けること。
    func test_分類頭を見分ける() throws {
        XCTAssertTrue(try config().isClassifier)
        XCTAssertFalse(try config(classifier: false).isClassifier)
    }

    /// **胴体の重みに `model.` が付く。** 前置きを取り違えると
    /// 「重みが無い」で落ちる（黙って通るよりましだが、理由が分からない）。
    func test_分類頭のある方は前置きが付く() throws {
        XCTAssertEqual(try config().prefix, "model.")
        XCTAssertEqual(try config(classifier: false).prefix, "")
    }

    /// プーリングと活性を config から読むこと。**推測しない。**
    func test_プーリングと活性をconfigから読む() throws {
        XCTAssertEqual(try config(pooling: "cls").classifierPooling, .cls)
        XCTAssertEqual(try config(pooling: "mean").classifierPooling, .mean)
        XCTAssertEqual(try config(activation: "gelu").classifierActivation, .gelu)
        XCTAssertEqual(try config(activation: "silu").classifierActivation, .silu)
        XCTAssertThrowsError(try config(pooling: "last"), "知らないプーリングを通した")
    }

    /// 出口が 1 つの数になること。
    func test_出口は1つの数() throws {
        let config = try config()
        var mil = MILProgram()
        let state = MILProgram.Value(name: "hidden", type: .init(.fp16, [1, 8, 16]))
        let mask = MILProgram.Value(name: "attention_mask", type: .init(.int32, [1, 8]))
        let epsilon = mil.constant("eps", .init(.fp16, []), .halves([1e-5]))
        let out = ClassifierHead(config: config, seq: 8)
            .build(into: &mil, hidden: state, attentionMask: mask,
                   weights: .init(dense: 0, norm: 64, classifier: 128, classifierBias: 192),
                   epsilon: epsilon)
        XCTAssertEqual(out.type.shape, [1, 1], "score が 1 つの数になっていない")
        XCTAssertEqual(out.name, "score")
    }

    /// **cls は先頭のトークンだけを取る。** 平均と取り違えると、
    /// 通って、それらしい score が出て、順位だけが狂う。
    func test_clsは先頭だけを取る() throws {
        var mil = MILProgram()
        let state = MILProgram.Value(name: "hidden", type: .init(.fp16, [1, 8, 16]))
        let mask = MILProgram.Value(name: "attention_mask", type: .init(.int32, [1, 8]))
        let epsilon = mil.constant("eps", .init(.fp16, []), .halves([1e-5]))
        let out = ClassifierHead(config: try config(pooling: "cls"), seq: 8)
            .build(into: &mil, hidden: state, attentionMask: mask,
                   weights: .init(dense: 0, norm: 64, classifier: 128, classifierBias: 192),
                   epsilon: epsilon)
        let text = String(decoding: mil.program(functionName: "main", inputs: [state, mask],
                                                outputs: [out]).data, as: UTF8.self)
        XCTAssertTrue(text.contains("pool_sliced"), "先頭を切り出していない")
        XCTAssertFalse(text.contains("pool_sum"), "平均を取っている")
    }

    func test_meanは詰め物を外して平均する() throws {
        var mil = MILProgram()
        let state = MILProgram.Value(name: "hidden", type: .init(.fp16, [1, 8, 16]))
        let mask = MILProgram.Value(name: "attention_mask", type: .init(.int32, [1, 8]))
        let epsilon = mil.constant("eps", .init(.fp16, []), .halves([1e-5]))
        let out = ClassifierHead(config: try config(pooling: "mean"), seq: 8)
            .build(into: &mil, hidden: state, attentionMask: mask,
                   weights: .init(dense: 0, norm: 64, classifier: 128, classifierBias: 192),
                   epsilon: epsilon)
        let text = String(decoding: mil.program(functionName: "main", inputs: [state, mask],
                                                outputs: [out]).data, as: UTF8.self)
        XCTAssertTrue(text.contains("pool_sum"), "平均を取っていない")
        XCTAssertTrue(text.contains("pool_count"), "詰め物を数から外していない")
    }
}
