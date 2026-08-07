import Foundation
import PDFKit

/// 意味の索引が載せる単位。節ひとつぶん。
///
/// 本文の全文は持たない（spec-local-ai.md 第 4.2 節）。持つのは
/// 飛び先・見出しの道筋・候補を見分けるための短い抜き書きだけである。
struct SemanticUnit: Hashable {
    /// 飛び先。**表題は入れない**（`heading` と二重の状態になるため）。
    /// 渡すときは `target` を使う。
    var locator: Locator
    /// 見出しの道筋（章 → 節）。無ければ空。
    var heading: String
    /// 代表文。一覧で人が見分けるためのもので、検索には使わない。
    var excerpt: String

    /// 移動に渡す飛び先。表題は見出しから埋める。
    var target: Locator {
        var made = locator
        made.title = heading.isEmpty ? nil : heading
        return made
    }
}

/// 書籍を節に切る。
///
/// 既存の切り方をそのまま使い、新しい文書モデルは作らない（第 4.1 節）。
/// 二字組索引の単位（EPUB は読み順の 1 項目、PDF は 1 ページ）より細かい。
/// 意味の索引は「この節は何の話か」を 1 本のベクトルにするので、
/// ページで切ると話の途中で切れ、章で切ると話が混ざるためである。
enum SemanticUnits {
    /// 短すぎるものは載せない。扉・奥付・章番号だけの頁が拾われる。
    static let defaultLeastCharacters = 200

    /// 抜き書きの長さ。一覧に 1 行で出す前提。
    private static let excerptCharacters = 120

    /// 切り出した節と、埋め込みに渡す本文。
    ///
    /// 本文を `SemanticUnit` に持たせないのは、索引に書かないものだからである。
    /// 作るときだけ要るので、組にして返す。
    struct Piece {
        var unit: SemanticUnit
        var text: String
    }

    /// 下限を渡せるようにしてあるのは検査のためである
    /// （同梱のサンプルは読み方を見せるためのもので、既定の下限には届かない）。
    static func pieces(of source: SearchIndexStore.Source,
                       leastCharacters: Int = defaultLeastCharacters) -> [Piece] {
        switch source {
        case let .epub(resources, publication):
            return epubPieces(resources: resources, publication: publication,
                              leastCharacters: leastCharacters)
        case let .pdf(pdf):
            return pdfPieces(pdf, leastCharacters: leastCharacters)
        }
    }

    // MARK: - EPUB

    /// 読み順の 1 項目を、見出し（h1〜h3）で割る。
    ///
    /// 章がそのまま 1 単位になる本もあれば、1 章に 10 節ある本もある。
    /// 見出しが無ければ章まるごとを 1 単位とする。
    private static func epubPieces(resources: ResourceProvider,
                                   publication: EPUBPublication,
                                   leastCharacters: Int) -> [Piece] {
        var made: [Piece] = []
        for link in publication.readingOrder {
            guard let data = try? resources.read(link.href) else { continue }
            let html = CSSCompat.decodeText(data)
            let sections = split(html)

            // 章の中での位置は、取り出した本文の長さで測る。
            // 綴じ方（タグの量）に左右されないようにするためである。
            let lengths = sections.map { HTMLText.extract($0.html).text.count }
            let total = max(1, lengths.reduce(0, +))
            var passed = 0

            for (at, section) in sections.enumerated() {
                let text = HTMLText.extract(section.html).text
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let progression = Double(passed) / Double(total)
                passed += lengths[at]
                guard text.count >= leastCharacters else { continue }
                let locator = Locator(href: link.href,
                                      progression: progression,
                                      fragment: section.fragment)
                made.append(Piece(unit: SemanticUnit(locator: locator,
                                                     heading: section.heading,
                                                     excerpt: excerpt(text)),
                                  text: text))
            }
        }
        return made
    }

    private struct Section {
        var heading: String
        /// 見出しに id があれば、そこへ直に飛べる。
        var fragment: String?
        var html: String
    }

    /// 見出しの位置で HTML を割る。見出しが無ければ丸ごと 1 つ。
    private static func split(_ html: String) -> [Section] {
        guard let re = try? NSRegularExpression(
            pattern: #"(?is)<h[1-3]\b([^>]*)>(.*?)</h[1-3]>"#) else {
            return [Section(heading: "", fragment: nil, html: html)]
        }
        let text = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return [Section(heading: "", fragment: nil, html: html)] }

        var made: [Section] = []
        // 最初の見出しより前にも本文があることがある（前書きなど）。捨てない。
        if matches[0].range.location > 0 {
            made.append(Section(heading: "", fragment: nil,
                                html: text.substring(to: matches[0].range.location)))
        }
        for (at, match) in matches.enumerated() {
            let to = at + 1 < matches.count ? matches[at + 1].range.location : text.length
            let range = NSRange(location: match.range.location, length: to - match.range.location)
            let heading = HTMLText.extract(text.substring(with: match.range(at: 2))).text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            made.append(Section(heading: heading,
                                fragment: identifier(in: text.substring(with: match.range(at: 1))),
                                html: text.substring(with: range)))
        }
        return made
    }

    private static func identifier(in attributes: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\bid\s*=\s*["']([^"']+)["']"#),
              let match = re.firstMatch(in: attributes,
                                        range: NSRange(location: 0, length: (attributes as NSString).length)),
              let range = Range(match.range(at: 1), in: attributes) else { return nil }
        return String(attributes[range])
    }

    // MARK: - PDF

    /// アウトラインの項目で切る。無ければ固定のページ窓で代える。
    ///
    /// スパイクでは 52 冊すべてがアウトラインを持っていたが、
    /// 持たない本もあるので窓も残す（第 4.1 節）。
    private static func pdfPieces(_ pdf: PDFKit.PDFDocument, leastCharacters: Int) -> [Piece] {
        var pages: [String] = []
        for at in 0 ..< pdf.pageCount { pages.append(pdf.page(at: at)?.string ?? "") }

        var marks = outlineMarks(pdf)
        if marks.count < 3 {
            // 窓は 8 ページとする。節の見当が付かないので、話の切れ目は諦めて等分する。
            marks = stride(from: 0, to: pdf.pageCount, by: 8).map { (page: $0, title: "") }
        }

        var made: [Piece] = []
        for (at, mark) in marks.enumerated() {
            let to = at + 1 < marks.count ? marks[at + 1].page : pdf.pageCount
            guard mark.page >= 0, mark.page < to, to <= pages.count else { continue }
            let text = pages[mark.page ..< to].joined(separator: "\n")
                .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= leastCharacters else { continue }
            let locator = Locator(page: mark.page,
                                  progression: Double(mark.page) / Double(max(1, pdf.pageCount)))
            made.append(Piece(unit: SemanticUnit(locator: locator,
                                                 heading: mark.title,
                                                 excerpt: excerpt(text)),
                              text: text))
        }
        return made
    }

    /// アウトラインを、ページ順に並んだ目印にほどく。
    private static func outlineMarks(_ pdf: PDFKit.PDFDocument) -> [(page: Int, title: String)] {
        guard let root = pdf.outlineRoot else { return [] }
        var made: [(page: Int, title: String)] = []
        var stack = [root]
        while let node = stack.popLast() {
            for at in (0 ..< node.numberOfChildren).reversed() {
                guard let child = node.child(at: at) else { continue }
                if let page = child.destination?.page {
                    made.append((pdf.index(for: page), child.label ?? ""))
                }
                stack.append(child)
            }
        }
        // 同じページに複数の項目が刺さることがある。最初のものを残す。
        made.sort { $0.page < $1.page }
        var seen = Set<Int>()
        return made.filter { seen.insert($0.page).inserted }
    }

    // MARK: - 共通

    private static func excerpt(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > excerptCharacters else { return trimmed }
        return String(trimmed.prefix(excerptCharacters)) + "…"
    }
}
