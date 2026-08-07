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
