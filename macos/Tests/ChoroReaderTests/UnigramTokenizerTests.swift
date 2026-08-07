import XCTest
@testable import ChoroReader

/// トークナイザが参照実装と同じトークン ID を返すこと。
///
/// **これが唯一の防壁である。** 食い違っても例外は出ず、黙って違うベクトルが出るので、
/// 使ってみて気付くことができない。
///
/// 期待値は kohagi（Rust の tokenizers crate）で 1 度作って凍結してある
/// （Fixtures/ruri-v3-tokenizer.json）。例文は架空のもので、実在の書籍からは取っていない。
///
/// tokenizer.json 自体はモデルと一緒に配られる 6.4 MB のファイルなので、
/// リポジトリには入れない。手元に無ければこの検査は飛ばす。
@MainActor
final class UnigramTokenizerTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let text: String
            let ids: [Int]
        }
        let cases: [Case]
    }

    /// 手元のモデルの tokenizer.json。無ければ nil。
    private func tokenizerURL() -> URL? {
        let hub = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        guard let walk = FileManager.default.enumerator(at: hub, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in walk where url.lastPathComponent == "tokenizer.json" {
            if url.path.contains("ruri-v3") { return url }
        }
        return nil
    }

    private func fixture() throws -> Fixture {
        let url = TestPaths.repositoryRoot
            .appendingPathComponent("macos/Tests/ChoroReaderTests/Fixtures/ruri-v3-tokenizer.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func test_参照実装と同じトークンIDを返す() throws {
        guard let url = tokenizerURL() else {
            throw XCTSkip("手元に Ruri v3 の tokenizer.json がありません")
        }
        let tokenizer = try UnigramTokenizer(contentsOf: url)
        let expected = try fixture()
        XCTAssertGreaterThan(expected.cases.count, 20, "期待値が少なすぎます")

        for one in expected.cases {
            XCTAssertEqual(tokenizer.encode(one.text), one.ids,
                           "「\(one.text.prefix(28))」で食い違う")
        }
    }

    /// 期待値そのものが崩れていないかを、形の側から見る。
    func test_期待値は前後を特殊トークンで挟んでいる() throws {
        let expected = try fixture()
        for one in expected.cases {
            XCTAssertEqual(one.ids.first, 1, "<s> で始まっていない：\(one.text.prefix(20))")
            XCTAssertEqual(one.ids.last, 2, "</s> で終わっていない：\(one.text.prefix(20))")
        }
    }

    /// 特殊トークンを付けない形も使う（切り詰めの長さを数えるときなど）。
    func test_特殊トークンを外せる() throws {
        guard let url = tokenizerURL() else {
            throw XCTSkip("手元に Ruri v3 の tokenizer.json がありません")
        }
        let tokenizer = try UnigramTokenizer(contentsOf: url)
        let expected = try fixture()
        let one = try XCTUnwrap(expected.cases.first { $0.ids.count > 4 })

        let bare = tokenizer.encode(one.text, addSpecialTokens: false)
        XCTAssertEqual(bare, Array(one.ids.dropFirst().dropLast()))
    }
}
