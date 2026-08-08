import Foundation
import PDFKit

enum IndexTerms {
    /// 1 冊ぶんの語。索引が無ければ空。
    ///
    /// **UI を持つスレッドから呼んではいけない。** 書籍を読む。
    static func of(_ source: SearchIndexStore.Source) -> [String] {
        switch source {
        case let .epub(resources, publication):
            guard let range = BackIndex.range(in: publication) else { return [] }
            var made: [String] = []
            for at in range {
                guard at < publication.readingOrder.count,
                      let data = try? resources.read(publication.readingOrder[at].href)
                else { continue }
                let html = CSSCompat.decodeText(data)
                if isColophon(HTMLText.extract(html).text) { break }
                made.append(contentsOf: fromHTML(html))
            }
            return unique(made)

        case let .pdf(pdf):
            let titles = SemanticUnits.pageTitles(pdf)
            guard let range = BackIndex.range(in: pdf, pageTitles: titles) else { return [] }
            var made: [String] = []
            for page in range {
                let text = pdf.page(at: page)?.string ?? ""
                if isColophon(text) { break }
                made.append(contentsOf: text.split(whereSeparator: \.isNewline)
                    .compactMap { term(from: String($0)) })
            }
            return unique(made)
        }
    }

    static func isColophon(_ text: String) -> Bool {
        guard text.contains("発行") || text.contains("発 行") else { return false }
        return text.range(of: "[0-9０-９]{4}\\s*年\\s*[0-9０-９]{1,2}\\s*月",
                          options: .regularExpression) != nil
    }

    private static func unique(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    // MARK: - EPUB

    /// 索引の紙面（XHTML）から語を採る。
    ///
    /// `<li>` が無い本もあるので、そのときは行として読む。
    static func fromHTML(_ html: String) -> [String] {
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]) else {
            return asLines(html)
        }
        // 索引の 1 項目が何で組まれているかは本による。**上から順に当てる。**
        // 一覧が本命で、段落や定義リストで組む本もある。
        for tag in ["li", "dt", "p", "div"] {
            let nodes = (try? document.nodes(forXPath: "//*[local-name()='\(tag)']")) ?? []
            let made = nodes.compactMap { node -> String? in
                guard let element = node as? XMLElement, !isPointer(element) else { return nil }
                return term(from: ownText(of: element))
            }
            if !made.isEmpty { return made }
        }
        return asLines(html)
    }

    private static func asLines(_ html: String) -> [String] {
        HTMLText.extract(html).text
            .split(whereSeparator: \.isNewline)
            .compactMap { term(from: String($0)) }
    }

    private static func isPointer(_ element: XMLElement) -> Bool {
        let elements = (element.children ?? []).compactMap { $0 as? XMLElement }
        guard elements.count == 1, elements[0].name?.lowercased() == "a" else { return false }
        let own = (element.children ?? [])
            .filter { $0.kind == .text }
            .compactMap { $0.stringValue }
            .joined()
        return own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// その項目**自身の**字。入れ子の一覧は数えない。
    ///
    /// 索引は「語（外側）＋頁番号のリンク（内側）」の入れ子になっている。
    /// 内側まで数えると、頁番号ばかり拾って語が出ない（805 項目から 82 語しか
    /// 出ていなかった）。
    private static func ownText(of element: XMLElement) -> String {
        var out = ""
        for child in element.children ?? [] {
            if let inner = child as? XMLElement {
                let name = inner.name?.lowercased() ?? ""
                // 入れ子の一覧は頁番号なので数えない。段の中の段も同じ。
                if ["ul", "ol", "p", "div", "dd"].contains(name) { continue }
                out += ownText(of: inner)
            } else if child.kind == .text {
                out += child.stringValue ?? ""
            }
        }
        return out
    }

    // MARK: - 語を整える

    /// 見出し（あ行・A・記号）として捨てる形。
    private static let heading = try? NSRegularExpression(
        pattern: "^(?:[ぁ-んァ-ヶ]{1,2}行?|[A-Za-z]|記号|数字|その他)$")

    /// 1 行（1 項目）から語を採る。語でなければ nil。
    ///
    /// 落とすもの：末尾の頁番号、点線、参照（→ …）、見出し、数字だけの行。
    ///
    /// **点線には結合文字を使う本がある**（U+0336 の重ね打ち）。
    /// 見た目が同じでも普通の記号として落とせないので、結合文字ごと落とす。
    static func term(from raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "[[:space:]]+", with: " ",
                                            options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // 参照はその語の説明ではないので、そこで切る。
        if let arrow = text.range(of: "(→|⇒|参照)", options: .regularExpression) {
            text = String(text[..<arrow.lowerBound])
        }
        // 末尾の頁番号・点線・結合文字。
        let trailing = CharacterSet(charactersIn: "0123456789０-９，,、 -–—ー.．・･…‥〜~")
            .union(.nonBaseCharacters)
        var scalars = text.unicodeScalars
        while let last = scalars.last, trailing.contains(last) { scalars.removeLast() }
        text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)

        guard (1 ... 40).contains(text.count) else { return nil }
        let whole = NSRange(text.startIndex ..< text.endIndex, in: text)
        if heading?.firstMatch(in: text, range: whole) != nil { return nil }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }
}
