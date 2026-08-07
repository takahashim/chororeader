import WebKit
import XCTest
@testable import ChoroReader

/// ウィンドウを閉じたら、そのウィンドウが抱えていたものが解放されることを守る。
///
/// ナビゲータは WKWebView を所有する。1 つ残るたびに WebKit のプロセスと
/// 描画の資源が居座るので、多数の書籍を開いて閉じると効いてくる。
///
/// `WKUserContentController.add(_:name:)` は受け手を**強く**持つ。
/// ナビゲータを直に渡すと
/// ナビゲータ → WKWebView → configuration → userContentController → ナビゲータ
/// で輪になり、deinit そのものが呼ばれない。
@MainActor
final class NavigatorLifetimeTests: XCTestCase {
    private func document(_ name: String) throws -> BookDocument {
        let url = TestPaths.fixture(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        return try BookDocument(url: url)
    }

    func test_本文のナビゲータは窓を閉じたら解放される() throws {
        let doc = try document("epub3-basic.epub")
        weak var released: WebNavigatorController?
        autoreleasepool {
            let controller = WebNavigatorController(document: doc, settings: ReaderSettings(), start: nil)
            released = controller
            XCTAssertNotNil(released)
        }
        XCTAssertNil(released, "ナビゲータが残っている。WKWebView ごと居座る")
    }

    func test_紙面のナビゲータは窓を閉じたら解放される() throws {
        let doc = try document("fixed-layout.epub")
        weak var released: FixedLayoutNavigatorController?
        autoreleasepool {
            let controller = FixedLayoutNavigatorController(document: doc, settings: ReaderSettings(), start: nil)
            released = controller
            XCTAssertNotNil(released)
        }
        XCTAssertNil(released, "ナビゲータが残っている。WKWebView ごと居座る")
    }
}

/// 覆われた窓の中身を手放し、現れたら組み直すこと。
///
/// WKWebView は 1 つで 34 メガほどと WebContent プロセスを 1 つ持つ。
/// 窓を並べて比べるのがこのアプリの芯なので、窓の数は減らせない。
/// 代わりに、その瞬間に見られていない窓の中身を手放す。
@MainActor
final class SleepingContentTests: XCTestCase {
    private func document(_ name: String) throws -> BookDocument {
        let url = TestPaths.fixture(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        return try BookDocument(url: url)
    }

    func test_寝ると本文を手放し_起きると組み直す() throws {
        let doc = try document("epub3-basic.epub")
        let nav = WebNavigatorController(document: doc, settings: ReaderSettings(), start: nil)
        XCTAssertFalse(nav.isAsleep)
        let slept = nav.webView

        nav.sleepContent()
        XCTAssertTrue(nav.isAsleep)
        XCTAssertNil(nav.webView, "手放していない")

        nav.wakeContent()
        XCTAssertFalse(nav.isAsleep)
        XCTAssertNotNil(nav.webView, "組み直していない")
        XCTAssertFalse(nav.webView === slept, "同じものを使い回している")
    }

    func test_寝て起きても居場所を失わない() throws {
        let doc = try document("epub3-basic.epub")
        let order = try XCTUnwrap(doc.publication?.readingOrder)
        try XCTSkipUnless(order.count >= 2)

        let start = Locator(href: order[1].href, progression: 0.5, text: "本文")
        let nav = WebNavigatorController(document: doc, settings: ReaderSettings(), start: start)

        nav.sleepContent()
        nav.wakeContent()

        XCTAssertEqual(nav.locator.href, order[1].href, "章を見失っている")
    }

    func test_寝ているあいだに触っても落ちない() throws {
        let doc = try document("epub3-basic.epub")
        let nav = WebNavigatorController(document: doc, settings: ReaderSettings(), start: nil)
        nav.sleepContent()

        // 覆われた窓にも献立や設定変更は届く。落ちずに受け流すこと。
        nav.copySelection()
        nav.mark = nil
        nav.reveal(Locator(href: nav.locator.href, progression: 0.3))
        XCTAssertTrue(nav.isAsleep, "触っただけで起きてしまう")
    }

    func test_紙面も寝て起きる() throws {
        let doc = try document("fixed-layout.epub")
        let nav = FixedLayoutNavigatorController(document: doc, settings: ReaderSettings(), start: nil)
        let page = nav.currentPage

        nav.sleepContent()
        XCTAssertTrue(nav.isAsleep)
        nav.wakeContent()
        XCTAssertFalse(nav.isAsleep)
        XCTAssertEqual(nav.currentPage, page, "ページを見失っている")
    }
}
