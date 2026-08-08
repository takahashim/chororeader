import XCTest
@testable import ChoroConvert

/// `config.json` の読み取り。
///
/// **黙って間違える形を拒むのが仕事である。**
/// 組み上げるグラフは決め打ちなので、config がそれと違うことを言っていても
/// 変換は通り、それらしい数まで出る。順位だけが静かに狂う。
final class EncoderConfigTests: XCTestCase {
    private func json(_ extra: String = "") -> String {
        """
        {"hidden_size": 512, "num_attention_heads": 8, "num_hidden_layers": 22,
         "intermediate_size": 768, "vocab_size": 102400, "norm_eps": 1e-5,
         "local_attention": 128, "global_attn_every_n_layers": 3,
         "local_rope_theta": 10000.0, "global_rope_theta": 160000.0,
         "max_position_embeddings": 8192, "hidden_activation": "gelu"\(extra)}
        """
    }

    func test_読める() throws {
        let config = try EncoderConfig(json: json())
        XCTAssertEqual(config.hidden, 512)
        XCTAssertEqual(config.heads, 8)
        XCTAssertEqual(config.headDim, 64)
        XCTAssertEqual(config.activation, .gelu)
        XCTAssertFalse(config.isClassifier)
    }

    /// 全域を見る層の選び方。**間隔で選ぶ。**
    func test_全域の層は間隔で選ぶ() throws {
        let config = try EncoderConfig(json: json())
        XCTAssertTrue(config.isGlobal(layer: 0))
        XCTAssertFalse(config.isGlobal(layer: 1))
        XCTAssertFalse(config.isGlobal(layer: 2))
        XCTAssertTrue(config.isGlobal(layer: 3))
    }

    /// eps の綴りが 2 通りある。**ruri は norm_eps。**
    func test_epsの綴りは両方受ける() throws {
        let other = """
        {"hidden_size": 512, "num_attention_heads": 8, "num_hidden_layers": 2,
         "intermediate_size": 768, "vocab_size": 100, "layer_norm_eps": 2e-5}
        """
        XCTAssertEqual(try EncoderConfig(json: other).eps, 2e-5)
    }

    // MARK: - 拒む

    func test_biasを持つと言うものは拒む() {
        for key in ["attention_bias", "mlp_bias", "norm_bias"] {
            XCTAssertThrowsError(try EncoderConfig(json: json(", \"\(key)\": true")),
                                 "\(key) が true なのに通してしまった")
        }
    }

    /// **伸縮する rope は拒む。** 参照実装だけが効かせて、こちらは効かせない。
    func test_伸縮するropeは拒む() {
        let extra = """
        , "rope_parameters": {"full_attention": {"rope_type": "llama3"}}
        """
        XCTAssertThrowsError(try EncoderConfig(json: json(extra)))
    }

    /// **layer_types が間隔と食い違えば拒む。** そちらが正しいので、
    /// 間隔に従うこちらが間違っていることになる。
    func test_layer_typesが食い違えば拒む() {
        // 0,1,2 の全部を全域にした（間隔 3 なら 0 だけのはず）
        let extra = ", \"layer_types\": [\"full_attention\", \"full_attention\", \"full_attention\"]"
        XCTAssertThrowsError(try EncoderConfig(json: json(extra)))
    }

    /// 食い違わなければ通ること。**拒みすぎないこと**も見る。
    func test_layer_typesが合っていれば通る() throws {
        let extra = ", \"layer_types\": [\"full_attention\", \"sliding_attention\", \"sliding_attention\"]"
        XCTAssertNoThrow(try EncoderConfig(json: json(extra)))
    }

    func test_headで割り切れなければ拒む() {
        let bad = """
        {"hidden_size": 100, "num_attention_heads": 8, "num_hidden_layers": 2,
         "intermediate_size": 768, "vocab_size": 100}
        """
        XCTAssertThrowsError(try EncoderConfig(json: bad))
    }

    /// 理由をまとめて言うこと。**一覧が欲しいので、最初の 1 つで止めない。**
    func test_理由はまとめて言う() {
        do {
            _ = try EncoderConfig(json: json(", \"attention_bias\": true, \"mlp_bias\": true"))
            XCTFail("通してしまった")
        } catch let error as EncoderConfig.Failure {
            guard case let .unsupported(reasons) = error else { return XCTFail("種類が違う") }
            XCTAssertEqual(reasons.count, 2, "理由が 1 つしか出ていない")
        } catch {
            XCTFail("種類が違う：\(error)")
        }
    }

    // MARK: - バケット

    /// **学習された位置を超えるバケットは拒む。** 動いて、間違った数を出す。
    func test_学習された位置を超えるバケットは拒む() throws {
        let config = try EncoderConfig(json: json())
        XCTAssertNoThrow(try config.check(lengths: [64, 512, 8192]))
        XCTAssertThrowsError(try config.check(lengths: [64, 16384]))
        XCTAssertThrowsError(try config.check(lengths: []))
        XCTAssertThrowsError(try config.check(lengths: [64, 64]), "同じ長さが 2 つ")
    }

    // MARK: - 実物

    func test_実物のconfigを読む() throws {
        let hub = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        guard let walk = FileManager.default.enumerator(at: hub, includingPropertiesForKeys: nil)
        else { throw XCTSkip("置き場所がありません") }
        // **1_Pooling/config.json も同じ名前である。** 名前だけで選ぶと掴み違える。
        // モデルの config かどうかは中身で見る。
        var found: URL?
        for case let url as URL in walk
        where url.lastPathComponent == "config.json" && url.path.contains("ruri-v3-130m") {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("hidden_size") else { continue }
            found = url
            break
        }
        guard let found else { throw XCTSkip("手元に ruri-v3-130m がありません") }

        let config = try EncoderConfig(json: String(contentsOf: found, encoding: .utf8))
        XCTAssertEqual(config.hidden, 512)
        XCTAssertEqual(config.layers, 19)
        XCTAssertEqual(config.vocab, 102400)
        XCTAssertFalse(config.isClassifier)
        XCTAssertNoThrow(try config.check(lengths: [64, 128, 256, 512, 1024, 2048]))
    }
}
