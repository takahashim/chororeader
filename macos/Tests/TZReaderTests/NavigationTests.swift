import WebKit
import XCTest
@testable import TZReader

/// 縦は読むための軸、横は移動するための軸という取り決めを守る。
/// スクロールで章が変わってしまうと、読んでいるつもりが移動してしまう。
@MainActor
final class NavigationTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let url = TestPaths.fixture("\(name).epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "conformance/tzconf generate でフィクスチャを作ってください")
        return url
    }

    @discardableResult
    private func wait(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func makeController(_ name: String) throws -> WebNavigatorController {
        let document = try BookDocument(url: fixture(name))
        let controller = WebNavigatorController(document: document, settings: ReaderSettings.shared, start: nil)
        XCTAssertTrue(wait { !controller.isLoading })
        XCTAssertTrue(wait { self.evaluate(controller, "window.__tzrReady === true") as? Bool == true },
                      "注入スクリプトが動いていません")
        return controller
    }

    private func evaluate(_ controller: WebNavigatorController, _ script: String) -> Any? {
        var result: Any?
        var done = false
        controller.webView.evaluateJavaScript(script) { value, _ in
            result = value
            done = true
        }
        _ = wait(timeout: 3) { done }
        return result
    }

    private func pressArrow(_ controller: WebNavigatorController, key: String) {
        controller.webView.evaluateJavaScript("""
        document.dispatchEvent(new KeyboardEvent('keydown', { key: '\(key)', bubbles: true })); true
        """)
    }

    func testRightArrowMovesToNextChapter() throws {
        let controller = try makeController("epub3-basic")
        let first = try XCTUnwrap(controller.locator.href)

        pressArrow(controller, key: "ArrowRight")
        XCTAssertTrue(wait(timeout: 5) { controller.locator.href != first }, "右キーで次の章へ進んでいない")
        XCTAssertEqual(controller.currentIndex, 1)

        pressArrow(controller, key: "ArrowLeft")
        XCTAssertTrue(wait(timeout: 5) { controller.currentIndex == 0 }, "左キーで前の章へ戻っていない")
    }

    /// 右開きの書籍では、右が前へ戻る向きになる。
    func testArrowsFollowPageProgressionDirection() throws {
        let controller = try makeController("nonlinear-spine")
        XCTAssertEqual(controller.document.publication?.direction, .ltr)

        pressArrow(controller, key: "ArrowRight")
        XCTAssertTrue(wait(timeout: 5) { controller.currentIndex == 1 })

        let rtl = try makeController("rtl")
        XCTAssertEqual(rtl.document.publication?.direction, .rtl)
        // 右開きで 1 章しかない書籍では、右キーで前へ戻ろうとして何も起きない。
        pressArrow(rtl, key: "ArrowRight")
        _ = wait(timeout: 1) { false }
        XCTAssertEqual(rtl.currentIndex, 0)
    }

    func testScrollingDoesNotChangeChapter() throws {
        let controller = try makeController("epub3-basic")
        let first = try XCTUnwrap(controller.locator.href)

        // 章末まで送っても、縦方向の操作では章を跨がない。
        controller.webView.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight); true")
        _ = wait(timeout: 1.5) { false }
        XCTAssertEqual(controller.locator.href, first, "スクロールで章が変わってしまっている")
    }

    func testChapterEndAffordanceAppearsExceptOnLastChapter() throws {
        let controller = try makeController("epub3-basic")
        XCTAssertTrue(wait(timeout: 5) {
            (self.evaluate(controller, "!!document.getElementById('tzr-chapter-end')") as? Bool) == true
        }, "章末の行き先が出ていない")

        controller.goNextChapter()
        XCTAssertTrue(wait(timeout: 5) { !controller.isLoading && controller.currentIndex == 1 })
        XCTAssertTrue(wait(timeout: 5) {
            (self.evaluate(controller, "!!document.getElementById('tzr-chapter-end')") as? Bool) == false
        }, "最後の章にも行き先を出してしまっている")
    }
}
