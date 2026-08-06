import XCTest
@testable import ChoroReader

/// 同じ書籍を複数ウィンドウで開いたときに、パース結果と注釈が共有されることを守る。
/// これが崩れると、片方のウィンドウのしおりがもう片方に映らなくなる。
@MainActor
final class DocumentSharingTests: XCTestCase {
    func testSameURLYieldsSameDocument() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Fixtures.gihyo))
        let url = URL(fileURLWithPath: Fixtures.gihyo)

        let first = try DocumentRegistry.shared.open(url: url)
        DocumentRegistry.shared.retain(first)
        defer { DocumentRegistry.shared.release(first) }

        let second = try DocumentRegistry.shared.open(url: url)
        DocumentRegistry.shared.retain(second)
        defer { DocumentRegistry.shared.release(second) }

        XCTAssertTrue(first === second, "同じ書籍が二重にパースされている")
        XCTAssertEqual(first.id, second.id)
    }

    func testDocumentIsReleasedWhenAllWindowsClose() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Fixtures.gihyo))
        let url = URL(fileURLWithPath: Fixtures.gihyo)

        let first = try DocumentRegistry.shared.open(url: url)
        DocumentRegistry.shared.retain(first)
        let second = try DocumentRegistry.shared.open(url: url)
        DocumentRegistry.shared.retain(second)

        // ウィンドウが 1 つ残っているあいだは保持し続ける。
        DocumentRegistry.shared.release(first)
        let stillOpen = try DocumentRegistry.shared.open(url: url)
        XCTAssertTrue(stillOpen === first)

        // 最後のウィンドウが閉じたら手放す。
        DocumentRegistry.shared.release(second)
        DocumentRegistry.shared.release(stillOpen)
        let reopened = try DocumentRegistry.shared.open(url: url)
        XCTAssertFalse(reopened === first, "最後のウィンドウが閉じても解放されていない")
        DocumentRegistry.shared.release(reopened)
    }

    func testBookIDIsStableAcrossOpens() {
        let url = URL(fileURLWithPath: "/tmp/例の本.epub")
        XCTAssertEqual(BookID(url: url), BookID(url: url))
        XCTAssertNotEqual(BookID(url: url), BookID(url: URL(fileURLWithPath: "/tmp/別の本.epub")))
    }
}
