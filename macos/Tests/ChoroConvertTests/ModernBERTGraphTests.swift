import XCTest
@testable import ChoroConvert

/// ModernBERT のグラフ。
///
/// グラフの**形**は Core ML の組み立てが見る（型を書く方針の受け皿）。
/// ここで見るのは、形では守れない 2 つである。
///
/// - **rope の表**：角度が間違っていても、通って、それらしい数が出る
/// - **マスク**：塞ぐ場所が 1 つずれても、通って、それらしい数が出る
///
/// どちらも独立に計算して突き合わせる。
final class ModernBERTGraphTests: XCTestCase {
    private func config(activation: String = "gelu") throws -> EncoderConfig {
        try EncoderConfig(json: """
        {"hidden_size": 32, "num_attention_heads": 4, "num_hidden_layers": 4,
         "intermediate_size": 64, "vocab_size": 100, "norm_eps": 1e-5,
         "local_attention": 4, "global_attn_every_n_layers": 2,
         "local_rope_theta": 10000.0, "global_rope_theta": 160000.0,
         "max_position_embeddings": 512, "hidden_activation": "\(activation)"}
        """)
    }

    // MARK: - rope

    /// 角度が `pos * theta ^ (-2i/d)` であること。
    func test_ropeの角度() {
        let seq = 5, headDim = 8
        let theta: Float = 10000
        let (cos, sin) = ModernBERTGraph.ropeTables(seq: seq, headDim: headDim, theta: theta)
        XCTAssertEqual(cos.count, seq * headDim)
        XCTAssertEqual(sin.count, seq * headDim)

        for position in 0 ..< seq {
            for at in 0 ..< headDim / 2 {
                let angle = Float(position) * powf(theta, -Float(2 * at) / Float(headDim))
                let base = position * headDim + at
                XCTAssertEqual(cos[base], cosf(angle), accuracy: 1e-5,
                               "位置 \(position) の \(at) 番目の cos が違う")
                XCTAssertEqual(sin[base], sinf(angle), accuracy: 1e-5)
            }
        }
    }

    /// **角度は後ろ半分にも同じものを写す。** 並べ替え（交互）ではない。
    ///
    /// ここを交互にすると、回す相手がずれたまま通る。
    func test_ropeの角度は後ろ半分に写される() {
        let seq = 3, headDim = 8
        let (cos, sin) = ModernBERTGraph.ropeTables(seq: seq, headDim: headDim, theta: 10000)
        let half = headDim / 2
        for position in 0 ..< seq {
            for at in 0 ..< half {
                let base = position * headDim
                XCTAssertEqual(cos[base + at], cos[base + half + at], accuracy: 1e-6,
                               "前半と後半の cos が違う")
                XCTAssertEqual(sin[base + at], sin[base + half + at], accuracy: 1e-6)
            }
        }
    }

    /// 位置 0 は回さない（cos = 1、sin = 0）。
    func test_位置0は回さない() {
        let (cos, sin) = ModernBERTGraph.ropeTables(seq: 2, headDim: 8, theta: 10000)
        for at in 0 ..< 8 {
            XCTAssertEqual(cos[at], 1, accuracy: 1e-6)
            XCTAssertEqual(sin[at], 0, accuracy: 1e-6)
        }
    }

    /// theta が違えば表も違うこと。**局所と全域で別の theta を使う。**
    func test_thetaが違えば表も違う() {
        let local = ModernBERTGraph.ropeTables(seq: 4, headDim: 8, theta: 10000)
        let global = ModernBERTGraph.ropeTables(seq: 4, headDim: 8, theta: 160000)
        XCTAssertNotEqual(local.cos, global.cos, "theta を使っていない")
    }

    // MARK: - マスク

    /// **窓は総幅。** ある位置は左右へ `window / 2` ずつ届く。
    ///
    /// ここを「片側 window」と取り違えると、窓が倍になったまま通る。
    func test_窓は総幅で左右に半分ずつ届く() {
        let seq = 7, window = 4   // 左右に 2 ずつ
        let outside = ModernBERTGraph.windowCondition(seq: seq, window: window)
        for row in 0 ..< seq {
            for column in 0 ..< seq {
                XCTAssertEqual(outside[row * seq + column], abs(row - column) > 2,
                               "(\(row), \(column)) の塞ぎ方が違う")
            }
        }
    }

    /// 自分自身は必ず見える。
    func test_自分自身は塞がない() {
        let seq = 6
        let outside = ModernBERTGraph.windowCondition(seq: seq, window: 2)
        for at in 0 ..< seq {
            XCTAssertFalse(outside[at * seq + at], "自分を塞いでいる")
        }
    }

    /// **窓は入力に依らない**ので定数にできる。詰め物の方はグラフの中で組む。
    ///
    /// 定数で全部を焼き込んでいた頃は、詰め物のある入力で参照実装と食い違った
    /// （cosine 0.935）。バケットいっぱいまで詰まった入力では一致していたので、
    /// 気付くのが遅れた。
    func test_詰め物のマスクはグラフの中で組む() throws {
        let config = try config()
        let graph = ModernBERTGraph(config: config, seq: 8)
        var mil = MILProgram()
        let ids = MILProgram.Value(name: "input_ids", type: .init(.int32, [1, 8]))
        let attention = MILProgram.Value(name: "attention_mask", type: .init(.int32, [1, 8]))
        let out = graph.build(into: &mil, ids: ids, attentionMask: attention,
                              blocks: (0 ..< config.layers).map { _ in sampleOffsets() },
                              tokens: 0, embeddingNorm: 64, finalNorm: 128)
        let text = String(decoding: mil.program(functionName: "main",
                                                inputs: [ids, attention],
                                                outputs: [out]).data, as: UTF8.self)
        // 入力から組んだ印
        XCTAssertTrue(text.contains("m_is_padding"), "詰め物を入力から見ていない")
        XCTAssertTrue(text.contains("global_mask"))
        XCTAssertTrue(text.contains("local_mask"))
    }

    // MARK: - グラフの形

    /// 層の数だけ組まれること。**層を 1 つ落としても数は返る。**
    func test_層の数だけ組まれる() throws {
        let config = try config()
        let graph = ModernBERTGraph(config: config, seq: 8)
        var mil = MILProgram()
        let ids = MILProgram.Value(name: "input_ids", type: .init(.int32, [1, 8]))
        let attention = MILProgram.Value(name: "attention_mask", type: .init(.int32, [1, 8]))
        let blocks = (0 ..< config.layers).map { _ in sampleOffsets() }
        let out = graph.build(into: &mil, ids: ids, attentionMask: attention,
                              blocks: blocks, tokens: 0,
                              embeddingNorm: 64, finalNorm: 128)

        XCTAssertEqual(out.type.shape, [1, 8, config.hidden])
        let program = mil.program(functionName: "main", inputs: [ids, attention], outputs: [out])
        // 層ごとに 23 前後の演算。数そのものより、層の数に比例することを見る。
        let text = String(decoding: program.data, as: UTF8.self)
        for layer in 0 ..< config.layers {
            XCTAssertTrue(text.contains("l\(layer)_out"), "層 \(layer) が組まれていない")
        }
        XCTAssertFalse(text.contains("l\(config.layers)_out"), "層が多すぎる")
    }

    /// 層 0 だけ前正規化を持たないこと（埋め込みの後で正規化済み）。
    func test_層0は前正規化を持たない() throws {
        let config = try config()
        let graph = ModernBERTGraph(config: config, seq: 8)
        var mil = MILProgram()
        let ids = MILProgram.Value(name: "input_ids", type: .init(.int32, [1, 8]))
        let attention = MILProgram.Value(name: "attention_mask", type: .init(.int32, [1, 8]))
        var blocks = (0 ..< config.layers).map { _ in sampleOffsets() }
        blocks[0].attnNorm = nil
        let out = graph.build(into: &mil, ids: ids, attentionMask: attention,
                              blocks: blocks, tokens: 0,
                              embeddingNorm: 64, finalNorm: 128)
        let text = String(decoding: mil.program(functionName: "main", inputs: [ids, attention],
                                                outputs: [out]).data, as: UTF8.self)
        XCTAssertFalse(text.contains("l0_attn_normed"), "層 0 に前正規化がある")
        XCTAssertTrue(text.contains("l1_attn_normed"), "層 1 に前正規化が無い")
    }

    /// 活性が config で決まること。**gelu と silu はこの 1 演算だけが違う。**
    func test_活性はconfigで決まる() throws {
        for (name, expected) in [("gelu", "gelu"), ("silu", "silu")] {
            let config = try config(activation: name)
            let graph = ModernBERTGraph(config: config, seq: 4)
            var mil = MILProgram()
            let ids = MILProgram.Value(name: "input_ids", type: .init(.int32, [1, 4]))
        let attention = MILProgram.Value(name: "attention_mask", type: .init(.int32, [1, 4]))
            let out = graph.build(into: &mil, ids: ids, attentionMask: attention,
                                  blocks: (0 ..< config.layers).map { _ in sampleOffsets() },
                                  tokens: 0, embeddingNorm: 64, finalNorm: 128)
            let text = String(decoding: mil.program(functionName: "main", inputs: [ids, attention],
                                                    outputs: [out]).data, as: UTF8.self)
            XCTAssertTrue(text.contains(expected), "\(name) が組まれていない")
        }
    }

    /// 目盛りが `1 / sqrt(head の幅)` であること。
    func test_注意の目盛り() throws {
        let graph = ModernBERTGraph(config: try config(), seq: 8)
        XCTAssertEqual(graph.scale, 1 / Float(8).squareRoot(), accuracy: 1e-6)
    }

    private func sampleOffsets() -> ModernBERTGraph.BlockOffsets {
        .init(attnNorm: 320, wqkv: 384, wqkvBias: 448, wo: 512, woBias: 576,
              mlpNorm: 640, mlpWi: 704, mlpWiBias: 768, mlpWo: 832, mlpWoBias: 896,
              ropeCos: 960, ropeSin: 1024)
    }
}
