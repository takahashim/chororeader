import XCTest
@testable import ChoroConvert

/// ModernBERT を ONNX として組む。
///
/// 実物との突き合わせ（凍結済み 10 件との cosine）は C# 側にあり、そちらが数の審判である。
/// ここで見るのは、**ONNX Runtime に渡す前に分かること**だけにする。
///
/// とくに `名前が繋がっている` は、実際に踏んだ不具合をそのまま検査にしたものである。
/// 組み立て器が値の写しを持って回るため、入口を先に置くと最後の受け取りで消えていた。
/// ONNX Runtime は「input_ids が入口でも定数でもない」と言って読まなかったが、
/// **モデルを吐くのに 20 秒、読ませるのに数秒かかる**ので、ここで捕まえたい。
final class ONNXEncoderTests: XCTestCase {
    /// 小さな ModernBERT を 1 つ組む。層 2・幅 8・head 2 の玩具である。
    private func tiny() throws -> (config: EncoderConfig, weights: Safetensors) {
        let hidden = 8, heads = 2, intermediate = 16, vocab = 12, layers = 2
        let json = """
        {
          "model_type": "modernbert",
          "architectures": ["ModernBertModel"],
          "hidden_size": \(hidden),
          "num_attention_heads": \(heads),
          "num_hidden_layers": \(layers),
          "intermediate_size": \(intermediate),
          "vocab_size": \(vocab),
          "norm_eps": 1e-5,
          "local_attention": 4,
          "global_attn_every_n_layers": 2,
          "local_rope_theta": 100.0,
          "global_rope_theta": 1000.0,
          "max_position_embeddings": 64,
          "hidden_activation": "gelu",
          "norm_bias": false,
          "attention_bias": false,
          "mlp_bias": false,
          "classifier_pooling": "mean"
        }
        """
        let config = try EncoderConfig(json: json)

        var entries: [(name: String, shape: [Int], dtype: String, bytes: [UInt8])] = []
        func put(_ name: String, _ shape: [Int]) {
            let count = shape.reduce(1, *)
            // 中身は何でもよい。ここで見るのは形と繋がりだけである。
            let values = (0 ..< count).map { Float($0 % 7) * 0.01 }
            var bytes: [UInt8] = []
            for value in values {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
            }
            entries.append((name, shape, "F32", bytes))
        }

        put("embeddings.tok_embeddings.weight", [vocab, hidden])
        put("embeddings.norm.weight", [hidden])
        put("final_norm.weight", [hidden])
        for layer in 0 ..< layers {
            // 層 0 は前正規化を持たない（埋め込みの後で正規化済み）。
            if layer > 0 { put("layers.\(layer).attn_norm.weight", [hidden]) }
            put("layers.\(layer).attn.Wqkv.weight", [3 * hidden, hidden])
            put("layers.\(layer).attn.Wo.weight", [hidden, hidden])
            put("layers.\(layer).mlp_norm.weight", [hidden])
            put("layers.\(layer).mlp.Wi.weight", [2 * intermediate, hidden])
            put("layers.\(layer).mlp.Wo.weight", [hidden, intermediate])
        }

        var header: [String: Any] = [:]
        var body: [UInt8] = []
        for entry in entries {
            header[entry.name] = ["dtype": entry.dtype, "shape": entry.shape,
                                  "data_offsets": [body.count, body.count + entry.bytes.count]]
            body.append(contentsOf: entry.bytes)
        }
        let json2 = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var out = [UInt8]()
        for shift in stride(from: 0, to: 64, by: 8) {
            out.append(UInt8((UInt64(json2.count) >> UInt64(shift)) & 0xff))
        }
        out.append(contentsOf: [UInt8](json2))
        out.append(contentsOf: body)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-onnx-\(UUID().uuidString).safetensors")
        try Data(out).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (config, try Safetensors(contentsOf: url))
    }

    private func program() throws -> ONNXProgram {
        let (config, weights) = try tiny()
        return try ONNXEncoder(config: config, weights: weights, maximumSequence: 64).build().program
    }

    /// **名前が繋がっていること。**
    ///
    /// どの演算の入力も、入口か・定数か・前の演算の出力でなければならない。
    /// 1 つでも欠けると ONNX Runtime は読まない。実際に入口ごと落としたことがある。
    func test_名前が繋がっている() throws {
        let program = try program()

        var known = Set(program.inputs.map(\.name))
        known.formUnion(program.initializers.map(\.name))

        for op in program.ops {
            for input in op.inputs where !input.isEmpty {
                XCTAssertTrue(known.contains(input),
                              "\(op.type) の入力 \(input) が、入口でも定数でも前の出力でもない")
            }
            known.formUnion(op.outputs)
        }

        for port in program.outputs {
            XCTAssertTrue(known.contains(port.name), "出口 \(port.name) を作る演算が無い")
        }
    }

    /// 出す名前が重ならないこと。重なると、後の方が前を隠す。
    func test_出す名前が重ならない() throws {
        let program = try program()

        var seen = Set<String>()
        for name in program.initializers.map(\.name) {
            XCTAssertTrue(seen.insert(name).inserted, "定数 \(name) が二重に置かれている")
        }
        for op in program.ops {
            for output in op.outputs {
                XCTAssertTrue(seen.insert(output).inserted, "\(output) を出す演算が 2 つある")
            }
        }
    }

    /// 出入口の名前と型。アプリ側（`OnnxEmbedder`）の読み方と揃っていること。
    func test_出入口がアプリの読み方と揃う() throws {
        let program = try program()

        XCTAssertEqual(program.inputs.map(\.name), ["input_ids", "attention_mask"])
        XCTAssertTrue(program.inputs.allSatisfy { $0.type == .int64 })
        XCTAssertEqual(program.outputs.map(\.name), ["token_embeddings", "sentence_embedding"])
        XCTAssertTrue(program.outputs.allSatisfy { $0.type == .float16 })
    }

    /// **層ごとに rope の theta が違う。** 全域の層は別の表を使う。
    ///
    /// 取り違えても動くし、それらしい数も出る。使っている表の名前で見る。
    func test_全域の層と窓の層で別の表と別のマスクを使う() throws {
        let program = try program()

        // **層ごとの配線を直に見る。** 「どこかで使われているか」では足りない。
        // 表は切り出しの入力にも名前が出るし、窓のマスクは全域のマスクから作るので、
        // どの層も使っていなくても名前は現れる（実際に 2 度空振りした）。
        var byOutput: [String: ONNXProgram.Op] = [:]
        for op in program.ops { byOutput[op.outputs[0]] = op }

        var ropes = Set<String>()
        var masks = Set<String>()
        for layer in 0 ..< 2 {
            // rope は `x * cos` の掛け算。2 つ目の入力が表である。
            let rope = try XCTUnwrap(byOutput["l\(layer)_q_cos"], "層 \(layer) の rope が無い")
            ropes.insert(rope.inputs[1])
            // マスクは点に足し込む。2 つ目の入力がマスクである。
            let masked = try XCTUnwrap(byOutput["l\(layer)_masked"], "層 \(layer) のマスクが無い")
            masks.insert(masked.inputs[1])
        }

        XCTAssertEqual(ropes, ["rope_local_cos_cut", "rope_global_cos_cut"],
                       "層によって rope の表が変わっていない")
        XCTAssertEqual(masks, ["local_mask", "global_mask"],
                       "層によってマスクが変わっていない")
    }

    /// 読まなかった重みが無いこと。**取りこぼしても変換は通る。**
    func test_重みを取りこぼさない() throws {
        let (config, weights) = try tiny()
        let made = try ONNXEncoder(config: config, weights: weights, maximumSequence: 64).convert()

        XCTAssertEqual(made.unused, [], "読まなかった重みがある")
    }
}
