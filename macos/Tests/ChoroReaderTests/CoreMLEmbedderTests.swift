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

    /// 手元の Core ML 変換物。無ければ nil。
    private func modelDirectory() -> URL? {
        let hub = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        guard let walk = FileManager.default.enumerator(at: hub, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in walk
        where url.lastPathComponent.hasPrefix("buckets-") && url.pathExtension == "mlpackage" {
            if url.path.contains("ruri-v3") { return url.deletingLastPathComponent() }
        }
        return nil
    }

    private func fixture() throws -> Fixture {
        let url = TestPaths.repositoryRoot
            .appendingPathComponent("macos/Tests/ChoroReaderTests/Fixtures/ruri-v3-embedding.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func embedder() throws -> CoreMLEmbedder {
        guard let directory = modelDirectory() else {
            throw XCTSkip("手元に Ruri v3 の Core ML 変換物がありません")
        }
        return try CoreMLEmbedder(model: EmbeddingModel(directory: directory))
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
    func test_長すぎる本文は切り詰めて申告する() throws {
        let embedder = try embedder()
        let short = try embedder.embed("短い一節。", as: .document)
        XCTAssertFalse(short.truncated)

        let long = String(repeating: "これは長い本文の繰り返しである。", count: 200)
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
