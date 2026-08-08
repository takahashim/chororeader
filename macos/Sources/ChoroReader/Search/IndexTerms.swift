import Foundation
import PDFKit

/// 巻末の用語索引に載っている語。
///
/// **索引は、著者が「この本はこれを扱う」と認めた語の一覧である。**
/// 全文検索の当たりと違い、人が選んでいる。1 冊あたり 160〜670 語あった。
///
/// 意味の索引には入れない紙面（`BackIndex`）を、こちらでは語として使う。
/// 矛盾ではない。**索引の紙面は「何にでも似る」からベクトルの邪魔になるだけで、
/// 語の一覧としては最良の材料である。**
///
/// ## 取り出し方
///
/// 範囲は `BackIndex` が決める。そこから先は書式で違う。
///
/// - **EPUB**：`<li>` の**自分の字だけ**を採る。入れ子の `ul`/`ol` は頁番号の
///   リンクなので数えない。リンクだけの項目も語ではない（頁番号か節見出しを指している）
/// - **PDF**：行ごとに、末尾の頁番号と点線を落とす
///
/// ## 確かめ方
///
/// 蔵書には**同じ本の EPUB 版と PDF 版**が 4 冊ぶんあった。まったく別の経路で
/// 取り出して **96% が一致**した（91〜99%）。片方だけでは「取れているつもり」で
/// 終わるので、この突き合わせで確かめた。
enum IndexTerms {
    /// 1 冊ぶんの語。索引が無ければ空。
    ///
    /// **UI を持つスレッドから呼んではいけない。** 書籍を読む。
    static func of(_ source: SearchIndexStore.Source) -> [String] {
        switch source {
        case let .epub(resources, publication):
            guard let range = BackIndex.range(in: publication) else { return [] }
            let html = range.compactMap { at -> String? in
                guard at < publication.readingOrder.count,
                      let data = try? resources.read(publication.readingOrder[at].href)
                else { return nil }
                return CSSCompat.decodeText(data)
            }.joined(separator: "\n")
            return unique(fromHTML(html))

        case let .pdf(pdf):
            let titles = SemanticUnits.pageTitles(pdf)
            guard let range = BackIndex.range(in: pdf, pageTitles: titles) else { return [] }
            let lines = range.flatMap { page in
                (pdf.page(at: page)?.string ?? "").split(whereSeparator: \.isNewline).map(String.init)
            }
            return unique(lines.compactMap(term(from:)))
        }
    }

    /// 同じ語は 1 度だけ。**並びは出てきた順のまま**（あいうえお順は索引の側の都合）。
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

    /// 組みが読めなかったときに、素の字として読む。
    private static func asLines(_ html: String) -> [String] {
        HTMLText.extract(html).text
            .split(whereSeparator: \.isNewline)
            .compactMap { term(from: String($0)) }
    }

    /// **リンクだけの項目は語ではなく、指す先である。**
    /// 頁番号のことも、節の見出しのこともある。どちらも語ではない。
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
        // 字が 1 つも無いもの（記号だけ）は語ではない。
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }
}
