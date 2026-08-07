import XCTest
@testable import ChoroReader

/// 埋め込みが参照実装（kohagi）と同じベクトルを返すこと。
///
/// トークナイザと同じで、**ずれても例外は出ず、黙って違うベクトルが出る**。
/// 詰め方・平均の取り方・正規化のどれか一つでも食い違えば、
/// 関連箇所も意味検索も静かに質が落ちるだけで、症状としては現れない。
///
/// 期待値は kohagi（`--device coreml`）で 1 度作って凍結してある
/// （Fixtures/ruri-v3-embedding.json）。例文は架空のもの。
///
/// モデル一式（264 MB）はリポジトリへ入れない。手元に無ければ飛ばす。
@available(macOS 15, *)
@MainActor
final class CoreMLEmbedderTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let text: String
            let prefix: String
            let vector: [Float]
        }
        let dimension: Int
        let cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = TestPaths.repositoryRoot
            .appendingPathComponent("macos/Tests/ChoroReaderTests/Fixtures/ruri-v3-embedding.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func embedder() throws -> CoreMLEmbedder {
        guard let model = EmbeddingModelStore.installed() else {
            throw XCTSkip("手元に Ruri v3 の Core ML 変換物がありません（\(EmbeddingModelStore.directory.path)）")
        }
        return try CoreMLEmbedder(model: model)
    }

    func test_参照実装と同じベクトルを返す() throws {
        let embedder = try embedder()
        let expected = try fixture()
        XCTAssertEqual(embedder.dimension, expected.dimension)

        for one in expected.cases {
            let prefix = EmbeddingModel.Prefix(rawValue: one.prefix) ?? .document
            let made = try embedder.embed(one.text, as: prefix).vector
            XCTAssertEqual(made.count, expected.dimension)

            // 同じ向きであることを見る。ANE と CPU では最下位の桁が揃わないので、
            // 値そのものではなく cosine で比べる。
            var dot = 0.0
            for (a, b) in zip(made, one.vector) { dot += Double(a) * Double(b) }
            XCTAssertGreaterThan(dot, 0.9999, "「\(one.text.prefix(24))」でベクトルが違う（cosine \(dot)）")
        }
    }

    /// 正規化されていること。内積がそのまま cosine になる前提を守る。
    ///
    /// **上の照合では捕まらない。** cosine は大きさを見ないので、正規化を外しても
    /// 向きは同じままで通ってしまう（実際に外して確かめた）。二つで補い合う。
    func test_単位ベクトルを返す() throws {
        let embedder = try embedder()
        let made = try embedder.embed("架空の技術書の一節です。", as: .document).vector
        var squared = 0.0
        for value in made { squared += Double(value) * Double(value) }
        XCTAssertEqual(squared.squareRoot(), 1.0, accuracy: 1e-4)
    }

    /// 長い本文は切り詰めたうえで、切れたことを申告する。
    ///
    /// **長さはバケット集合から決める。** 数を決め打ちにすると、束を組み直したときに
    /// 黙って通るようになる（実際、512 までの束に合わせた 200 回は 2048 の束では収まった）。
    func test_長すぎる本文は切り詰めて申告する() throws {
        let embedder = try embedder()
        let short = try embedder.embed("短い一節。", as: .document)
        XCTAssertFalse(short.truncated)

        // 1 回で 1 トークン以上にはなるので、上限の回数を繰り返せば必ず超える。
        let long = String(repeating: "これは長い本文の繰り返しである。", count: embedder.maximumTokens)
        let made = try embedder.embed(long, as: .document)
        XCTAssertTrue(made.truncated, "切れたのに申告していない")
        XCTAssertEqual(made.vector.count, embedder.dimension)
    }

    /// 接頭辞で結果が変わること。付け忘れを検査で捕まえる。
    func test_接頭辞で結果が変わる() throws {
        let embedder = try embedder()
        let text = "非同期処理の書き方"
        let asDocument = try embedder.embed(text, as: .document).vector
        let asQuery = try embedder.embed(text, as: .query).vector

        var dot = 0.0
        for (a, b) in zip(asDocument, asQuery) { dot += Double(a) * Double(b) }
        XCTAssertLessThan(dot, 0.999, "接頭辞が効いていない")
    }
}

/// バケットを使うときに開く形になったので、複数の筋から同時に呼べること。
///
/// 索引作りは裏で走り、問いは前で走るので、同じ埋め込み器が両方から呼ばれる。
///
/// **この検査は競合そのものを捕まえられない。** 閂を外して 3 度走らせても通り、
/// Thread Sanitizer も何も言わなかった。`opened` の書き換えがぶつかる窓が狭いためで、
/// 「出ない」ことは「無い」ことではない。閂は、共有され書き換わる状態がある以上
/// 要るという理由で掛けてある。ここで見ているのは、同時に呼んでも
/// 答えが壊れないという当たり前の方だけである。
@available(macOS 15, *)
final class CoreMLEmbedderRaceTests: XCTestCase {
    func test_複数の筋から同時に呼べる() throws {
        guard let model = EmbeddingModelStore.installed() else {
            throw XCTSkip("手元に Ruri v3 の Core ML 変換物がありません")
        }
        let embedder = try CoreMLEmbedder(model: model)

        // 長さをばらけさせて、別々のバケットを同時に開かせる。
        // concurrentPerform で本当に同時に走らせる（async だと順に流れることがある）。
        let texts = (0 ..< 32).map { String(repeating: "架空の一節である。", count: 1 + ($0 % 8) * 12) }
        let failures = NSMutableArray()
        DispatchQueue.concurrentPerform(iterations: texts.count) { at in
            do {
                let made = try embedder.embed(texts[at], as: .document)
                if made.vector.count != embedder.dimension { failures.add("次元が違う") }
            } catch {
                failures.add("\(error)")
            }
        }
        XCTAssertEqual(failures.count, 0, "同時に呼ぶと壊れる：\(failures)")
    }
}
