import XCTest
@testable import ChoroReader

/// 書棚に出す名前の決め方。
///
/// 書籍は題名を名乗らないことが多い。名乗っていても、元の原稿のファイル名が
/// そのまま入っていることがある。どちらもファイル名の方が読める。
@MainActor
final class DisplayTitleTests: XCTestCase {
    private func name(_ title: String, _ path: String) -> String {
        DisplayTitle.of(title: title, path: path)
    }

    func test_まともな題名はそのまま出す() {
        XCTAssertEqual(name("関数プログラミング実践入門", "/蔵書/wdpress.epub"),
                       "関数プログラミング実践入門")
    }

    func test_題名が無ければファイル名で代える() {
        XCTAssertEqual(name("", "/蔵書/n月刊ラムダノート 4-3.pdf"), "n月刊ラムダノート 4-3")
        XCTAssertEqual(name("   ", "/蔵書/あの本.pdf"), "あの本")
    }

    /// EPUB は題名を名乗らないと「(無題)」になる（EPUBParser）。
    func test_無題もファイル名で代える() {
        XCTAssertEqual(name("(無題)", "/蔵書/同人誌2024.epub"), "同人誌2024")
        XCTAssertEqual(name("無題", "/蔵書/a.epub"), "a")
        XCTAssertEqual(name("Untitled", "/蔵書/b.pdf"), "b")
        XCTAssertEqual(name("名称未設定", "/蔵書/c.pdf"), "c")
    }

    /// 書き出しの道具が既定で入れる名前。手元の書棚に「book」が何冊も並んでいた。
    func test_道具の既定の名前は使わない() {
        XCTAssertEqual(name("book", "/蔵書/技術書典の新刊.pdf"), "技術書典の新刊")
        XCTAssertEqual(name("BOOK", "/蔵書/d.pdf"), "d")
        XCTAssertEqual(name("document", "/蔵書/e.pdf"), "e")
    }

    /// 元の原稿から引き継がれた名前。題名ではなく、作った道具の痕跡である。
    func test_原稿の痕跡は使わない() {
        XCTAssertEqual(name("Microsoft Word - 架空資料_revise01.docx",
                            "/資料/架空事件判決の解説.pdf"),
                       "架空事件判決の解説")
        XCTAssertEqual(name("入稿データ.indd", "/蔵書/f.pdf"), "f")
        XCTAssertEqual(name("Microsoft PowerPoint - 発表.pptx", "/蔵書/g.pdf"), "g")
    }

    /// 長さでは決めない。短い題名は実在する。
    func test_短い題名は捨てない() {
        XCTAssertEqual(name("Go", "/蔵書/go-book.epub"), "Go")
        XCTAssertEqual(name("R", "/蔵書/r.pdf"), "R")
    }

    /// 親フォルダまでは見ない。フォルダ名が書籍と関係ないことの方が多い。
    func test_親フォルダは見ない() {
        XCTAssertEqual(name("book", "/蔵書/2409/book.pdf"), "book")
        XCTAssertEqual(name("", "/蔵書/実践Rustプログラミング入門/main.pdf"), "main")
    }

    /// 題名もファイル名も無いときに、空を返さない。
    func test_代えるものが無ければ題名のまま() {
        XCTAssertEqual(name("book", "/"), "book")
    }

    func test_書棚の項目から引ける() {
        let entry = LibraryEntry(id: BookID(url: URL(fileURLWithPath: "/蔵書/実践Rust.pdf")),
                                 path: "/蔵書/実践Rust.pdf", bookmarkData: nil,
                                 title: "book", authors: [], format: .pdf,
                                 lastOpenedAt: Date(), lastLocator: nil)
        XCTAssertEqual(entry.displayTitle, "実践Rust")
    }
}
