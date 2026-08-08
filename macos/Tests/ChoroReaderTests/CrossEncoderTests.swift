import XCTest
@testable import ChoroReader

/// 並べ直しが参照実装（transformers）と同じ点・同じ順を返すこと。
///
/// 埋め込みと同じで、**ずれても例外は出ず、黙って違う順が出る**。
/// 組の詰め方（`<s> 問い </s><s> 本文 </s>`）を 1 つ取り違えるだけで、
/// 並びが静かに崩れる。症状としては「なんとなく効いていない」しか現れない。
///
/// 期待値は `AutoModelForSequenceClassification` で 1 度作って凍結してある
/// （Fixtures/japanese-reranker-xsmall-v2.json）。例文はすべて架空のもの。
///
/// モデル一式（70 MB）はリポジトリへ入れない。手元に無ければ飛ばす。
@available(macOS 15, *)
final class CrossEncoderTests: XCTestCase {
    struct Fixture: Decodable {
        struct Case: Decodable {
            let query: String
            let passage: String
            /// 参照実装が詰めたトークン。**詰め物は入っていない。**
            let ids: [Int]
            /// 素の logit。
            let score: Float
        }
        struct Ordering: Decodable {
            let query: String
            let passages: [String]
            let scores: [Float]
            /// 点の高い順に並べた添字。
            let order: [Int]
        }
        /// アプリが使う上限（いちばん長いバケット）。
        let limit: Int
        let cases: [Case]
        let ordering: Ordering
    }

    static func fixture() throws -> Fixture {
        let url = TestPaths.repositoryRoot
            .appendingPathComponent("macos/Tests/ChoroReaderTests/Fixtures/japanese-reranker-xsmall-v2.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func encoder() throws -> CrossEncoder {
        guard let model = RerankerModelStore.installed() else {
            throw XCTSkip("手元に reranker の Core ML 変換物がありません（\(RerankerModelStore.directory.path)）")
        }
        return try CrossEncoder(model: model)
    }

    /// 点が参照実装と揃うこと。
    ///
    /// fp16 で通すので下の桁は揃わない。**0.05 まで**を許す
    /// （この幅での fp16 の刻みは 0.008 程度、実測の最大差は 0.023）。
    func test_参照実装と同じ点を返す() throws {
        let encoder = try encoder()
        let expected = try Self.fixture()
        for one in expected.cases {
            let made = try encoder.score(query: one.query, passage: one.passage)
            XCTAssertEqual(made, one.score, accuracy: 0.05,
                           "「\(one.query.prefix(16))」の点が違う")
        }
    }

    /// **並びが参照実装と同じであること。** 点そのものより、こちらが本題である。
    func test_参照実装と同じ順に並ぶ() throws {
        let encoder = try encoder()
        let expected = try Self.fixture().ordering
        let made = try XCTUnwrap(encoder.scores(query: expected.query, passages: expected.passages))
        let order = made.indices.sorted { made[$0] > made[$1] }
        XCTAssertEqual(order, expected.order,
                       "並びが違う。点：" + made.map { String(format: "%.3f", $0) }.joined(separator: " "))
    }

    /// 問いが変わったら途中で降りること。40 件を回し切ると次の問いが待たされる。
    func test_割り込まれたら降りる() throws {
        let encoder = try encoder()
        let expected = try Self.fixture().ordering
        var asked = 0
        let made = try encoder.scores(query: expected.query, passages: expected.passages) {
            asked += 1
            return asked > 2
        }
        XCTAssertNil(made, "降りていない")
    }

}

/// 組の詰め方。**モデルが無くても回る。**
///
/// 参照実装が詰めたトークンの並びが期待値に入っているので、そこと突き合わせる。
/// 点の照合はモデルの要る機械でしか回らないが、詰め方の食い違いは
/// ここで捕まえられる。順が崩れる原因の大半はこちらである。
final class CrossEncoderPairTests: XCTestCase {
    private func tokenizer() throws -> UnigramTokenizer {
        guard let model = RerankerModelStore.installed() else {
            throw XCTSkip("手元に reranker のモデル一式がありません")
        }
        return try UnigramTokenizer(contentsOf: model.tokenizerURL)
    }

    @available(macOS 15, *)
    func test_参照実装と同じトークンに詰める() throws {
        let tokenizer = try tokenizer()
        let expected = try CrossEncoderTests.fixture()
        for one in expected.cases {
            let made = tokenizer.encodePair(one.query, one.passage, limit: expected.limit)
            XCTAssertEqual(made, one.ids, "「\(one.query.prefix(16))」の詰め方が違う")
        }
    }

    /// 上限を越えた組は**長い側から削る**（longest_first）。
    ///
    /// 本文だけを削る形にすると、問いの長い組で参照実装と食い違う。
    /// 期待値にはその両方（本文が長い組・問いが長い組）が入っている。
    @available(macOS 15, *)
    func test_上限を越えたら長い側から削る() throws {
        let tokenizer = try tokenizer()
        let expected = try CrossEncoderTests.fixture()
        let long = expected.cases.filter { $0.ids.count >= expected.limit }
        XCTAssertGreaterThanOrEqual(long.count, 2, "切り詰めを踏む期待値が足りない")
        for one in long {
            let made = tokenizer.encodePair(one.query, one.passage, limit: expected.limit)
            XCTAssertEqual(made.count, expected.limit, "上限ちょうどに収まっていない")
            XCTAssertEqual(made, one.ids)
        }
    }
}
