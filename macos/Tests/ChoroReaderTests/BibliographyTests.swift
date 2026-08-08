import XCTest
@testable import ChoroReader

/// 書誌の拾い方。
///
/// **拾えないことより、間違って拾うことの方が悪い。** 出版社や ISBN は
/// 同じ本を見分けるのに使うので、取り違えると別の本が同じものに見える。
final class BibliographyTests: XCTestCase {
    // MARK: - 発行日

    /// **形が違うだけで捨てない。** 年しか名乗らない本がある。
    func test_日付は形が違っても拾う() {
        XCTAssertEqual(Bibliography.date("2015-11-10T09:00:00Z"), "2015-11-10")
        XCTAssertEqual(Bibliography.date("2015-08-15"), "2015-08-15")
        XCTAssertEqual(Bibliography.date("2016-12"), "2016-12")
        XCTAssertEqual(Bibliography.date("2014"), "2014")
        XCTAssertEqual(Bibliography.date("  2014-11-14T09:00:00Z  "), "2014-11-14")
    }

    /// 日付でないものは拾わない。
    func test_日付でなければ拾わない() {
        for raw in ["", "   ", "近日発売", "第 2 版", "20", "abc-de-fg"] {
            XCTAssertNil(Bibliography.date(raw), "「\(raw)」を日付と見なしている")
        }
    }

    /// **時刻と時間帯は落とす。** 持つと、同じ日の本が版元によって前後する。
    func test_時刻は持たない() {
        XCTAssertEqual(Bibliography.date("2015-11-10T23:59:59+09:00"), "2015-11-10")
        XCTAssertEqual(Bibliography.date("2015-11-10T00:00:00Z"), "2015-11-10")
    }

    // MARK: - ISBN

    /// **最初の identifier とは限らない。** EPUB は uuid を先に置くことが多い。
    func test_並びの中からISBNを選ぶ() {
        let made = Bibliography.isbn(from: [
            "urn:uuid:02ef13a8-c202-4441-9f48-58bd2ab0de44",
            "urn:isbn:9784774177786",
        ])
        XCTAssertEqual(made, "9784774177786")
    }

    /// 区切りは形がまちまち。数字だけにして持つ。
    func test_区切りを抜いて持つ() {
        XCTAssertEqual(Bibliography.isbn(from: ["978-4-7741-7778-6"]), "9784774177786")
        XCTAssertEqual(Bibliography.isbn(from: ["ISBN 978-4-7741-7778-6"]), "9784774177786")
        XCTAssertEqual(Bibliography.isbn(from: ["4-7741-7778-1"]), "4774177781")
        // 末尾の検査文字が X の 10 桁もある。
        XCTAssertEqual(Bibliography.isbn(from: ["0-8044-2957-X"]), "080442957X")
    }

    /// **桁の合わないものは ISBN ではない。** uuid の数字だけを拾って
    /// それらしい値を作らないこと。
    func test_桁が合わなければ拾わない() {
        XCTAssertNil(Bibliography.isbn(from: ["urn:uuid:1C7B3B7D-7DD9-41CF-8FC6-DCF3FA51B376"]))
        XCTAssertNil(Bibliography.isbn(from: ["urn:uid:485fd2e4-4326-11e5"]))
        XCTAssertNil(Bibliography.isbn(from: []))
        XCTAssertNil(Bibliography.isbn(from: ["12345"]))
    }

    // MARK: - 全体

    func test_何も無ければ空と分かる() {
        XCTAssertTrue(Bibliography().isEmpty)
        XCTAssertFalse(Bibliography(publisher: "架空出版").isEmpty)
    }

    /// 発行年で並べ替えられること。
    func test_発行年を取り出せる() {
        XCTAssertEqual(Bibliography(published: "2015-11-10").year, 2015)
        XCTAssertEqual(Bibliography(published: "2014").year, 2014)
        XCTAssertNil(Bibliography().year)
    }

    // MARK: - EPUB から

    /// OPF だけを差し替えた EPUB を組む。**実書籍は使わない。**
    private func book(metadata: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-biblio-\(UUID().uuidString)", isDirectory: true)
        for part in ["META-INF", "OEBPS"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(part), withIntermediateDirectories: true)
        }
        func put(_ text: String, _ path: String) throws {
            try Data(text.utf8).write(to: directory.appendingPathComponent(path))
        }
        try put("application/epub+zip", "mimetype")
        try put("""
        <?xml version="1.0"?><container version="1.0" \
        xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>\
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\
        </rootfiles></container>
        """, "META-INF/container.xml")
        try put("""
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\(metadata)</metadata>
          <manifest><item id="t" href="text.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="t"/></spine>
        </package>
        """, "OEBPS/content.opf")
        try put("<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\">"
                + "<head><title>架空</title></head><body><p>架空の本文である。</p></body></html>",
                "OEBPS/text.xhtml")

        let url = directory.appendingPathComponent("book.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-X", url.path, "mimetype", "META-INF/container.xml",
                         "OEBPS/content.opf", "OEBPS/text.xhtml"]
        try zip.run()
        zip.waitUntilExit()
        return url
    }

    /// OPF から出版社・発行日・ISBN・副題を拾うこと。
    ///
    /// **副題は順番では見分けられない。** `title-type` を refines で指し直す。
    func test_OPFから拾う() throws {
        let url = try book(metadata: """
        <dc:identifier id="id">urn:uuid:00000000-0000-0000-0000-000000000000</dc:identifier>
        <dc:identifier id="i2">urn:isbn:9784774170077</dc:identifier>
        <dc:title id="t1">架空の技術書</dc:title>
        <meta refines="#t1" property="title-type">main</meta>
        <dc:title id="t2">実践サンプル工学入門</dc:title>
        <meta refines="#t2" property="title-type">subtitle</meta>
        <dc:creator>架空太郎</dc:creator>
        <dc:publisher>架空出版</dc:publisher>
        <dc:date>2014-11-14T09:00:00Z</dc:date>
        <dc:language>ja</dc:language>
        """)
        let publication = try EPUBParser.parse(try ZipArchive(url: url))
        let made = Bibliography.of(publication)

        XCTAssertEqual(made.publisher, "架空出版")
        XCTAssertEqual(made.published, "2014-11-14")
        XCTAssertEqual(made.isbn, "9784774170077")
        XCTAssertEqual(made.subtitle, "実践サンプル工学入門", "副題を順番で選んでいる")
    }

    /// 名乗っていない本でも落ちないこと。**揃わない本の方が多い。**
    func test_名乗っていなければ空で返る() throws {
        let url = try book(metadata: """
        <dc:identifier id="id">urn:uuid:00000000-0000-0000-0000-000000000000</dc:identifier>
        <dc:title>架空の技術書</dc:title>
        """)
        let made = Bibliography.of(try EPUBParser.parse(try ZipArchive(url: url)))
        XCTAssertTrue(made.isEmpty, "名乗っていないのに何か拾っている")
    }
}
