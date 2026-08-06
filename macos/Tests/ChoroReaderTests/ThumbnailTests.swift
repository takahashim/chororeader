import AppKit
import XCTest
@testable import ChoroReader

/// ページのサムネイル。数百ページの書籍でも一覧を開いた瞬間に破綻しないことを守る。
@MainActor
final class ThumbnailTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let url = TestPaths.fixture("\(name).epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "conformance/choroconf generate でフィクスチャを作ってください")
        return url
    }

    private func makeSession(_ name: String) throws -> ReaderSession {
        let document = try BookDocument(url: fixture(name))
        return ReaderSession(document: document, startLocator: nil)
    }

    func testProvidedForImagePagedBooks() throws {
        let session = try makeSession("fixed-layout")
        let provider = try XCTUnwrap(session.thumbnails, "画像ページの書籍でサムネイルが用意されていない")
        XCTAssertEqual(provider.pageCount, 5)
        XCTAssertTrue(session.availableTabs.contains(.thumbnails))
    }

    func testNotProvidedForReflowableBooks() throws {
        let session = try makeSession("epub3-basic")
        XCTAssertNil(session.thumbnails, "リフロー型でサムネイルを出そうとしている")
        XCTAssertFalse(session.availableTabs.contains(.thumbnails),
                       "使えないタブを並べている")
    }

    func testGeneratesDownscaledImages() throws {
        let session = try makeSession("fixed-layout")
        let provider = try XCTUnwrap(session.thumbnails)

        let done = expectation(description: "サムネイル生成")
        var image: NSImage?
        provider.thumbnail(at: 2, maxPixel: 160) { made in
            image = made
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        let made = try XCTUnwrap(image, "サムネイルを作れていない")
        // 元は 600x850。原寸のまま読み込むとメモリを食うため、縮小されている必要がある。
        XCTAssertLessThanOrEqual(max(made.size.width, made.size.height), 160)
        XCTAssertGreaterThan(min(made.size.width, made.size.height), 0)
    }

    func testCachesGeneratedImages() throws {
        let session = try makeSession("fixed-layout")
        let provider = try XCTUnwrap(session.thumbnails)
        XCTAssertNil(provider.cached(at: 0), "作る前から結果がある")

        let done = expectation(description: "サムネイル生成")
        provider.thumbnail(at: 0, maxPixel: 160) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertNotNil(provider.cached(at: 0), "二度目のために保持していない")
    }

    func testOutOfRangeIndexReturnsNil() throws {
        let session = try makeSession("fixed-layout")
        let provider = try XCTUnwrap(session.thumbnails)

        let done = expectation(description: "範囲外")
        var image: NSImage? = NSImage()
        provider.thumbnail(at: 99, maxPixel: 160) { made in
            image = made
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertNil(image)
    }
}
