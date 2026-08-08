import XCTest
@testable import ChoroReader

/// 書棚を意味で引く。
///
/// **引けなかったことを黙らない**のが要点である。
/// まだ読み込んでいない本があるのに「見つかりませんでした」とだけ出すと、
/// 蔵書に無いのか、まだ見ていないのかが分からず、次にすることが決まらない。
@MainActor
final class SemanticSearchTests: XCTestCase {
    private func entry(_ name: String) -> LibraryEntry {
        LibraryEntry(id: BookID(url: URL(fileURLWithPath: "/tmp/\(name).epub")),
                     path: "/tmp/\(name).epub", bookmarkData: nil,
                     title: name, authors: [], format: .reflowableEPUB,
                     lastOpenedAt: Date(timeIntervalSince1970: 0))
    }

    func test_空の問いでは何もしない() {
        let model = SemanticSearchModel()
        model.run("   ", over: [entry("a")]) { _ in nil }
        XCTAssertTrue(model.found.isEmpty)
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.query, "")
    }

    /// 索引がまだ 1 冊も無ければ、そう言う。
    ///
    /// 数えるのは**引きながら**なので、返るのを待つ（1 冊ずつ読んで捨てるため、
    /// 先に全冊を見に行かない）。
    func test_読み込んでいなければそう言う() throws {
        try XCTSkipUnless(EmbeddingModelStore.installed() != nil, "手元にモデルがありません")
        let model = SemanticSearchModel()
        model.run("架空の問い", over: [entry("a"), entry("b")]) { _ in nil }

        let done = expectation(description: "返る")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertTrue(model.found.isEmpty)
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.missing, 2, "未読み込みの数を数えていない")
        XCTAssertNotNil(model.reason)
    }

    func test_消せば元に戻る() {
        let model = SemanticSearchModel()
        model.run("架空の問い", over: [entry("a")]) { _ in nil }
        model.clear()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.missing, 0)
        XCTAssertNil(model.reason)
    }
}
