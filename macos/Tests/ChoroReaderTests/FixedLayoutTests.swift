import XCTest
@testable import ChoroReader

/// ページが画像になっている固定レイアウト EPUB の扱い。
@MainActor
final class FixedLayoutTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        let url = TestPaths.fixture("fixed-layout.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "conformance/choroconf generate でフィクスチャを作ってください")
        return url
    }

    func testDetectedAsFixedLayout() throws {
        let document = try BookDocument(url: fixtureURL())
        XCTAssertEqual(document.format, .fixedEPUB)
        XCTAssertEqual(document.publication?.readingOrder.count, 5)
    }

    /// 1 枚の画像で構成されるページは、画像を直接表示する。
    func testImageOnlyPagesAreDetected() throws {
        let archive = try ZipArchive(url: fixtureURL())
        let publication = try EPUBParser.parse(archive)

        for link in publication.readingOrder {
            let content = FixedLayoutPlan.pageContent(for: link.href, resources: archive)
            guard case let .image(href) = content else {
                return XCTFail("画像ページとして扱われていない: \(link.href)")
            }
            XCTAssertTrue(archive.contains(href))
        }
    }

    /// 本文が載っているページを画像だけに置き換えると、内容が落ちてしまう。
    func testPageWithTextFallsBackToTheDocument() throws {
        let archive = try ZipArchive(url: fixtureURL())
        // 脚注フィクスチャの章は本文が主体なので、画像ページとしては扱わない。
        let textBook = TestPaths.fixture("footnotes.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: textBook.path))
        let textArchive = try ZipArchive(url: textBook)

        let content = FixedLayoutPlan.pageContent(
            for: "OEBPS/text/ch01.xhtml", resources: textArchive)
        guard case .document = content else {
            return XCTFail("本文のあるページを画像に置き換えてしまっている")
        }
        _ = archive
    }

    /// ページは meta viewport で大きさを名乗る。名乗り方の 3 通りを見る。
    ///
    /// フィクスチャは 3 ページ目に書き損じ（`height` に `=` が無い）、
    /// 4 ページ目に名乗りなしを置いてある。
    func testViewportIsReadFromEachPage() throws {
        let archive = try ZipArchive(url: fixtureURL())
        let publication = try EPUBParser.parse(archive)
        let hrefs = publication.readingOrder.map(\.href)

        let named = FixedLayoutPlan.viewport(for: hrefs[0], resources: archive)
        XCTAssertEqual(named?.width, 1200)
        XCTAssertEqual(named?.height, 1700)

        // 書き損じた並びは、半端に読めたぶん（width だけ）も使わない。
        // 妙な寸法を掴んだまま画面を組むより、名乗っていない扱いにするほうが安全である。
        XCTAssertNil(FixedLayoutPlan.viewport(for: hrefs[2], resources: archive))
        XCTAssertNil(FixedLayoutPlan.viewport(for: hrefs[3], resources: archive))
    }

    /// 見開きは表紙を単独にし、以降を 2 枚ずつまとめる。
    func testSpreadPairing() {
        XCTAssertEqual(FixedLayoutPlan.spreads(pageCount: 5, rtl: false),
                       [[0], [1, 2], [3, 4]])
        XCTAssertEqual(FixedLayoutPlan.spreads(pageCount: 6, rtl: false),
                       [[0], [1, 2], [3, 4], [5]])
        XCTAssertEqual(FixedLayoutPlan.spreads(pageCount: 1, rtl: false), [[0]])
        XCTAssertEqual(FixedLayoutPlan.spreads(pageCount: 0, rtl: false), [])
    }

    func testArrowKeysMovePages() throws {
        let document = try BookDocument(url: fixtureURL())
        ReaderSettings.shared.pageLayout = .singlePage
        let controller = FixedLayoutNavigatorController(document: document,
                                                        settings: ReaderSettings.shared, start: nil)
        XCTAssertEqual(controller.currentPage, 0)

        controller.moveHorizontally(toRight: true)
        XCTAssertEqual(controller.currentPage, 1, "右キーで次のページへ進んでいない")

        controller.moveHorizontally(toRight: false)
        XCTAssertEqual(controller.currentPage, 0, "左キーで前のページへ戻っていない")

        // 先頭より前へは行かない。
        controller.moveHorizontally(toRight: false)
        XCTAssertEqual(controller.currentPage, 0)
    }

    /// 見開きでは、めくる単位が 1 枚ではなく 1 見開きになる。
    func testSpreadModeMovesBySpread() throws {
        let document = try BookDocument(url: fixtureURL())
        ReaderSettings.shared.pageLayout = .spread
        defer { ReaderSettings.shared.pageLayout = .continuousScroll }

        let controller = FixedLayoutNavigatorController(document: document,
                                                        settings: ReaderSettings.shared, start: nil)
        XCTAssertEqual(controller.currentPage, 0)
        controller.goNextPage()
        XCTAssertEqual(controller.currentPage, 1, "表紙の次は 2 ページ目からの見開きになる")
        controller.goNextPage()
        XCTAssertEqual(controller.currentPage, 3)
        controller.goPrevPage()
        XCTAssertEqual(controller.currentPage, 1)
    }

    func testPositionRestoresByPage() throws {
        let document = try BookDocument(url: fixtureURL())
        let controller = FixedLayoutNavigatorController(
            document: document, settings: ReaderSettings.shared,
            start: Locator(page: 3, progression: 0))
        XCTAssertEqual(controller.currentPage, 3, "保存されたページから開いていない")
        XCTAssertEqual(controller.locator.href, document.publication?.readingOrder[3].href)
    }
}
