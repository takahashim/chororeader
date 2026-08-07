import XCTest
@testable import ChoroReader

/// 刷ってある行から、名前の候補を拾うところ。
///
/// 例はすべて架空のもの。実在の書籍の題名・著者・奥付は検査に入れない。
@MainActor
final class NameCandidatesTests: XCTestCase {
    private func author(_ line: String) -> String? {
        let c = NameCandidates.classify(line)
        return c.isAuthor ? c.text : nil
    }

    func test_著者の行を見分けて前置きを剥がす() {
        XCTAssertEqual(author("著者： 架空 太郎"), "架空 太郎")
        XCTAssertEqual(author("見本 花子 著"), "見本 花子")
        XCTAssertEqual(author("監修： 試作 一郎"), "試作 一郎")
    }

    func test_ただの行は題名の候補になる() {
        for line in ["架空データ解析と", "統計学の作例集", "架空技術叢書"] {
            let c = NameCandidates.classify(line)
            XCTAssertFalse(c.isAuthor, line)
            XCTAssertEqual(c.text, line)
        }
    }

    /// 「著」で終わるが名前が残らない行を、著者として空にしない。
    func test_剥がして空になるなら元のまま() {
        XCTAssertEqual(NameCandidates.classify("著").text, "著")
    }

    func test_名前の一部の著の字には反応しない() {
        XCTAssertFalse(NameCandidates.classify("著作権法の解説").isAuthor)
    }

    /// 奥付の組み方。「著 者」とラベルの字間に空白が入る。
    /// 「著者紹介」を著者「紹介」と読まないこと（ラベルと名前のあいだの空白が要る）。
    func test_奥付の著者ラベルを見分ける() {
        XCTAssertEqual(author("著 者 架空太郎"), "架空太郎")
        XCTAssertEqual(author("著　者　見本花子"), "見本花子")
        XCTAssertNil(author("著者紹介"))
    }

    /// 奥付に同居する、名前になり得ない行。形は実在の奥付に倣い、中身は架空。
    func test_奥付の雑音を落とす() {
        for line in ["2026年1月1日 初版発行Ver.1.0（PDF版）",
                     "発 行 架空出版",
                     "販 売 株式会社架空販売",
                     "発行人 架空次郎",
                     "編集人 見本三郎",
                     "企画・編集 合同会社架空企画",
                     "〒000-0000",
                     "架空県架空市架空町1丁目1番地",
                     "https://example.com/",
                     "©2026Example.Allrightsreserved.",
                     "架空な出版モデルを提案します。",
                     "“Example” との協業で実現しています。",
                     "は、株式会社架空社が推進する新しい出版レーベルで",
                     "著者紹介", "目次"] {
            XCTAssertNil(NameCandidates.candidate(from: line), "「\(line)」が候補に残る")
        }
    }

    /// 題名と著者は落とさない。
    func test_奥付の名前は残す() {
        XCTAssertEqual(NameCandidates.candidate(from: "実践サンプル工学入門")?.text,
                       "実践サンプル工学入門")
        let author = NameCandidates.candidate(from: "著 者 架空太郎")
        XCTAssertEqual(author?.text, "架空太郎")
        XCTAssertEqual(author?.isAuthor, true)
    }
}

/// 人が付けた名前の持ち方。
@MainActor
final class CustomNameTests: XCTestCase {
    func test_付けた名前が名乗りより優先で_消せば戻る() throws {
        let url = TestPaths.fixture("epub3-basic.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let store = LibraryStore.shared
        let id = BookID(url: url)
        store.remove(id)
        defer { store.remove(id) }
        XCTAssertTrue(store.register(url))

        store.setCustomName(id, title: "自分で付けた題", authors: ["自分"])
        var entry = try XCTUnwrap(store.entry(for: id))
        XCTAssertEqual(entry.displayTitle, "自分で付けた題")
        XCTAssertEqual(entry.displayAuthors, "自分")
        XCTAssertEqual(entry.title, "基本の書籍", "名乗りを書き換えている")

        // 空にすれば名乗りに戻る。
        store.setCustomName(id, title: "", authors: [])
        entry = try XCTUnwrap(store.entry(for: id))
        XCTAssertEqual(entry.displayTitle, "基本の書籍")
        XCTAssertEqual(entry.displayAuthors, "山田 太郎")
    }
}
