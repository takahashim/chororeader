import Foundation
import PDFKit

enum BackIndex {
    static let leastPlace = 0.8

    /// 索引の見出しとして認める名前。**完全一致で見る。**
    ///
    /// 「索引の作り方」のような節を巻き込まないため、部分一致にはしない。
    private static let names = ["索引", "さくいん", "用語索引", "事項索引", "index"]

    static func isIndexName(_ title: String) -> Bool {
        let bare = title.filter { !$0.isWhitespace && $0 != "　" }.lowercased()
        return names.contains(bare)
    }

    // MARK: - EPUB

    /// 読み順のうち、索引が占める範囲。無ければ nil。
    ///
    /// 始まりは目次の「索引」の飛び先、終わりは**その次の目次項目**（奥付など）。
    /// 次が無ければ本の末尾までとする。
    static func range(in publication: EPUBPublication) -> Range<Int>? {
        let ordered = flattened(publication.tableOfContents)
            .compactMap { entry -> (place: Int, title: String)? in
                guard let href = entry.href, let at = publication.index(ofHref: href) else { return nil }
                return (at, entry.title)
            }
            .sorted { $0.place < $1.place }

        let total = publication.readingOrder.count
        guard total > 0, let hit = ordered.firstIndex(where: { isIndexName($0.title) }) else { return nil }
        let from = ordered[hit].place
        guard Double(from) / Double(total) >= leastPlace else { return nil }
        // 同じ章を指す項目が続くことがあるので、**先へ進んだ**最初の項目を終わりにする。
        let until = ordered.dropFirst(hit + 1).first { $0.place > from }?.place ?? total
        return from ..< until
    }

    private static func flattened(_ entries: [TOCEntry]) -> [TOCEntry] {
        entries.flatMap { [$0] + flattened($0.children) }
    }

    // MARK: - PDF

    /// ページのうち、索引が占める範囲。無ければ nil。
    ///
    /// **outline を先に見て、無ければ本文で探す。** しおりを持たない PDF は珍しくない。
    ///
    /// 本文で探すのは巻末だけなので、読むのは全体の 2 割で足りる。
    static func range(in pdf: PDFKit.PDFDocument, pageTitles titles: [String]) -> Range<Int>? {
        range(pageTitles: titles) ?? byText(pdf)
    }

    private static func byText(_ pdf: PDFKit.PDFDocument) -> Range<Int>? {
        let total = pdf.pageCount
        guard total > 0 else { return nil }
        var looksLike: [Int: Bool] = [:]
        var titled: [Int: Bool] = [:]

        func look(_ page: Int) {
            guard looksLike[page] == nil else { return }
            let lines = (pdf.page(at: page)?.string ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard lines.count >= leastLines else {
                looksLike[page] = false
                titled[page] = false
                return
            }
            let digits = lines.filter { $0.rangeOfCharacter(from: .decimalDigits) != nil }.count
            looksLike[page] = Double(digits) / Double(lines.count) > leastDigitLines
            // 柱や頁番号が先に来るので、頭の数行まで見る。
            titled[page] = lines.prefix(3).contains { isIndexName($0) }
        }

        let tail = Int(Double(total) * leastPlace)
        guard let from = (tail ..< total).first(where: { page in
            look(page)
            return titled[page] == true && looksLike[page] == true
        }) else { return nil }

        var until = from + 1
        while until < total {
            look(until)
            guard looksLike[until] == true else { break }
            until += 1
        }
        return from ..< until
    }

    private static let leastDigitLines = 0.5
    /// これより行が少ない頁は見ない。扉や白紙を拾わないため。
    private static let leastLines = 15

    /// outline の見出しから決める。
    ///
    /// - Parameter titles: ページごとの「いまどの節か」（outline から引いたもの）。
    ///   節の見出しは次の区切りまで引き継がれるので、**名前が索引であるページを
    ///   拾うだけで始まりと終わりが決まる。**
    static func range(pageTitles titles: [String]) -> Range<Int>? {
        let total = titles.count
        guard total > 0, let from = titles.firstIndex(where: isIndexName) else { return nil }
        guard Double(from) / Double(total) >= leastPlace else { return nil }
        let until = titles[from...].firstIndex { !isIndexName($0) } ?? total
        return from ..< until
    }
}
