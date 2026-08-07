import WebKit
import XCTest
@testable import ChoroReader

/// 検索結果から飛んだ先の当たりの強調。
///
/// 印は配信時に本文へ入る（SearchMarkInserter）。ここでは書籍を開いて動かし、
/// 画面に印が出るところまでを通しで確かめる。
@MainActor
final class MarkTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func evaluate(_ webView: WKWebView, _ script: String) -> Any? {
        var result: Any?
        var done = false
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            done = true
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !done {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        return result
    }

    /// 検索結果へ飛ぶと、その章の当たりが囲まれる。
    /// スクリプト単体ではなく、書籍を開いて動かすところまでを通しで確かめる。
    func test検索結果へ飛ぶと当たりが囲まれる() throws {
        let url = TestPaths.fixture("epub3-basic.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "conformance/choroconf generate でフィクスチャを作ってください")

        let document = try BookDocument(url: url)
        let resources = try XCTUnwrap(document.resources)
        let publication = try XCTUnwrap(document.publication)
        let query = "e"
        let outcome = DocumentSearch.scanEPUB(resources: resources, publication: publication, query: query)
        let hit = try XCTUnwrap(outcome.results.last, "「\(query)」が 1 件も見つからない")

        let controller = WebNavigatorController(document: document, settings: ReaderSettings.shared, start: nil)
        XCTAssertTrue(waitUntil(timeout: 10) { !controller.isLoading })

        controller.mark = SearchMark(query: query, nth: hit.nth, target: hit.locator)
        controller.reveal(hit.locator)
        XCTAssertTrue(waitUntil(timeout: 10) { !controller.isLoading })

        let marked = waitUntil(timeout: 6) {
            self.evaluate(controller.webView,
                          "document.querySelectorAll('mark.choro-found').length") as? Int == 1
        }
        XCTAssertTrue(marked, "飛んだ先で当たりが囲まれていない")

        // 検索をやめたら消える。読み続けるあいだ残り続けては邪魔になる。
        controller.mark = nil
        XCTAssertTrue(waitUntil(timeout: 6) {
            self.evaluate(controller.webView,
                          "document.querySelectorAll('mark.choro-found').length") as? Int == 0
        }, "検索をやめても囲みが残っている")
    }

    /// 紙面は文字を持たない絵なので、当たりの矩形を上から塗る。
    /// PDFKit の選択とは別に持つ。あちらは人が文字を選び直すと消える。
    func test紙面の当たりを塗る() throws {
        let url = TestPaths.repositoryRoot.appendingPathComponent("samples/sample.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "samples/build.rb でサンプルを作ってください")

        let document = try BookDocument(url: url)
        let controller = PDFNavigatorController(document: document, settings: ReaderSettings.shared, start: nil)
        let page = try XCTUnwrap(document.pdfDocument?.page(at: 1))

        controller.mark = SearchMark(query: "sample", nth: 0,
                                     target: Locator(page: 1, progression: 0))
        let painted = try XCTUnwrap(controller.pdfView.highlightedSelections, "塗られていない")
        XCTAssertFalse(painted.isEmpty)
        XCTAssertTrue(painted.allSatisfy { $0.pages.first == page }, "当たりのないページまで塗っている")

        controller.mark = nil
        XCTAssertNil(controller.pdfView.highlightedSelections, "検索をやめても塗りが残っている")
    }
}
