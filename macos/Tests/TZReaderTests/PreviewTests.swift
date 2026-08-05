import XCTest
@testable import TZReader

/// リンク先を移動せずに見せる抜粋の組み立て。
/// 脚注は要素 1 つで、節への参照は続きの段落まで含めることを守る。
final class PreviewProviderTests: XCTestCase {
    private func archive() throws -> ZipArchive {
        let path = TestPaths.fixture("footnotes.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path.path),
                          "conformance/tzconf generate でフィクスチャを作ってください")
        return try ZipArchive(url: path)
    }

    func testFootnoteShowsOnlyTheNote() throws {
        let preview = try XCTUnwrap(PreviewProvider.make(
            resources: archive(), href: "OEBPS/text/ch01.xhtml", fragment: "fn1", css: ""))

        XCTAssertTrue(preview.isFootnote, "脚注として判定されていない")
        XCTAssertTrue(preview.html.contains("これは脚注の中身です"))
        // 本文まで巻き込むと、脚注を見るために本文を読み直すことになる。
        XCTAssertFalse(preview.html.contains("本文の途中に脚注がある"))
        XCTAssertFalse(preview.html.contains("ここが参照先の節である"))
    }

    func testSectionLinkIncludesFollowingParagraphs() throws {
        let preview = try XCTUnwrap(PreviewProvider.make(
            resources: archive(), href: "OEBPS/text/ch01.xhtml", fragment: "sec2", css: ""))

        XCTAssertFalse(preview.isFootnote)
        XCTAssertTrue(preview.html.contains("1.2 後の節"))
        XCTAssertTrue(preview.html.contains("ここが参照先の節である"), "見出しだけで中身が入っていない")
        XCTAssertTrue(preview.html.contains("節の 2 段落目"))
    }

    func testMissingFragmentFallsBackToLeadingContent() throws {
        let preview = try XCTUnwrap(PreviewProvider.make(
            resources: archive(), href: "OEBPS/text/ch01.xhtml", fragment: "no-such-id", css: ""))
        XCTAssertTrue(preview.html.contains("第 1 章"), "先頭からの抜粋になっていない")
    }

    func testSyntheticPathSitsBesideTheTarget() throws {
        let preview = try XCTUnwrap(PreviewProvider.make(
            resources: archive(), href: "OEBPS/text/ch01.xhtml", fragment: "fn1", css: ""))
        // 抜粋の中の相対参照（画像や CSS）が解けるよう、対象と同じ階層に置く。
        XCTAssertEqual(preview.path, "OEBPS/text/\(PreviewProvider.syntheticName)")
    }

    func testCSSIsEmbedded() throws {
        let preview = try XCTUnwrap(PreviewProvider.make(
            resources: archive(), href: "OEBPS/text/ch01.xhtml", fragment: "fn1",
            css: "body { color: rgb(1, 2, 3); }"))
        XCTAssertTrue(preview.html.contains("rgb(1, 2, 3)"), "表示設定が抜粋へ渡っていない")
    }
}
