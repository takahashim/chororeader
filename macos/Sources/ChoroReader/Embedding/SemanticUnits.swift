import Foundation
import PDFKit

/// 意味の索引が載せる単位。**段落ひとつぶん。**
///
/// **本文は控えない**（spec-local-ai.md 第 4.2 節）。持つのは飛び先と、どの節の話かだけ。
///
/// 一度は抜き書き 160 字を控えていたが、測ると**本の 35% が原文のまま入っていた**。
/// 二字組索引は本文を持たず、候補を絞ってから原書を走査し直す（spec.md 第 10.4 節）。
/// 意味の索引だけが控えるのは筋が通らないので、出すときに原書から切り出す
/// （`PassageText`）。
struct SemanticUnit: Hashable {
    /// 飛び先。**表題は入れない**（`heading` と二重の状態になるため）。
    /// 渡すときは `target` を使う。
    ///
    /// `locator.text` に段落の頭 30 字を持つ。これは本文の控えではなく、
    /// **その場所へ寄せるための目印**である（既存の読書位置や検索の印と同じ性質）。
    var locator: Locator
    /// この段落を含む節の見出し。目次と同じ性質の情報で、本文ではない。
    var heading: String

    /// 移動に渡す飛び先。表題は見出しから埋める。
    var target: Locator {
        var made = locator
        made.title = heading.isEmpty ? nil : heading
        return made
    }
}

/// 書籍を段落に切る。
///
/// **節ではなく段落にする。** 節を 1 本のベクトルにすると、3 つの話題に触れた節が
/// そのどれでもない平均になる。着いた先も節の頭で、なぜ当たったのかも見えない。
/// 段落なら、飛び先がその段落になり、出す文がその段落そのものになる。
///
/// なお spikes/findings-unit-size.md の「割らない方がよい」は**この話ではない**。
/// あれは割った片を最大値で節にまとめ直し、節を順位付けする設定の話で、
/// 片の多い節ほど得をするのが悪さの正体だった。片そのものを単位にすれば、
/// まとめ直しが無いのでその仕組みは働かない。
enum SemanticUnits {
    /// 1 段落の狙い。日本語で 400 字はおよそ 200 トークン、技術書の 1〜2 段落にあたる。
    /// 小さくするほど的は絞れるが、文脈が減り、索引も膨らむ。ここが釣り合いである。
    static let targetCharacters = 400
    /// これ未満は独り立ちさせない。前の段落に足すか、捨てる。
    static let defaultLeastCharacters = 100
    /// 区切りが見つからなくても、ここを超えたら切る。
    private static let mostCharacters = 800
    /// 飛び先に載せる目印の長さ。**長すぎると綴じ方の違いで一致しない。**
    private static let anchorCharacters = 30

    /// 切り出した段落と、埋め込みに渡す本文。
    ///
    /// 本文を `SemanticUnit` に持たせないのは、索引に書かないものだからである。
    struct Piece {
        var unit: SemanticUnit
        var text: String
    }

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

    private static func epubPieces(resources: ResourceProvider,
                                   publication: EPUBPublication,
                                   leastCharacters: Int) -> [Piece] {
        var made: [Piece] = []
        for link in publication.readingOrder {
            guard let data = try? resources.read(link.href) else { continue }
            // 章の中での位置は、取り出した本文の長さで測る。綴じ方に左右されないため。
            // **足し込みを外へ出す**（変数を跨いで進めると、書き忘れても動いてしまう）。
            let sections = placed(split(CSSCompat.decodeText(data)))
            let total = max(1, sections.last.map { $0.offset + $0.text.count } ?? 0)

            for section in sections {
                for passage in passages(in: section.text, leastCharacters: leastCharacters) {
                    let locator = Locator(href: link.href,
                                          progression: min(1, Double(section.offset + passage.offset) / Double(total)),
                                          // 節の頭の段落なら見出しの id へ、そうでなければ本文で探す
                                          fragment: passage.offset == 0 ? section.fragment : nil,
                                          text: anchor(passage.text))
                    made.append(Piece(unit: SemanticUnit(locator: locator,
                                                         heading: section.heading),
                                      text: passage.text))
                }
            }
        }
        return made
    }

    private struct Section {
        var heading: String
        var fragment: String?
        var html: String
    }

    /// 本文を取り出し、章の頭からの位置を添えた節。
    private struct PlacedSection {
        var heading: String
        var fragment: String?
        var text: String
        /// 章の頭から、この節の頭までの文字数。
        var offset: Int
    }

    /// 節を順に並べ、章の頭からの位置を付ける。
    private static func placed(_ sections: [Section]) -> [PlacedSection] {
        var offset = 0
        return sections.map { section in
            let text = tidy(HTMLText.extract(section.html).text)
            defer { offset += text.count }
            return PlacedSection(heading: section.heading, fragment: section.fragment,
                                 text: text, offset: offset)
        }
    }

    /// 見出しの位置で HTML を割る。見出しが無ければ丸ごと 1 つ。
    ///
    /// 段落に切るのはこの後だが、**見出しは先に拾っておく**。
    /// どの節の話かが分からないと、一覧で見分けが付かない。
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
            // **見出しの札そのものは本文に含めない。** 見出しは別に持っているので二重になるうえ、
            // 画面では見出しと段落が別の節点なので、跨いだ目印は本文から見つからない。
            let from = match.range.location + match.range.length
            let body = from < to ? text.substring(with: NSRange(location: from, length: to - from)) : ""
            let heading = tidy(HTMLText.extract(text.substring(with: match.range(at: 2))).text)
            made.append(Section(heading: heading,
                                fragment: identifier(in: text.substring(with: match.range(at: 1))),
                                html: body))
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

    /// **ページごとに切る。** 節の範囲でまとめると、着いた先が節の頭になってしまう。
    /// ページ単位なら飛び先のページが正確に決まり、目印で行まで寄せられる。
    private static func pdfPieces(_ pdf: PDFKit.PDFDocument, leastCharacters: Int) -> [Piece] {
        let titles = sectionTitles(pdf)
        var made: [Piece] = []
        for page in 0 ..< pdf.pageCount {
            let text = tidy(pdf.page(at: page)?.string ?? "")
            guard !text.isEmpty else { continue }
            for passage in passages(in: text, leastCharacters: leastCharacters) {
                let locator = Locator(page: page,
                                      progression: Double(page) / Double(max(1, pdf.pageCount)),
                                      text: anchor(passage.text))
                made.append(Piece(unit: SemanticUnit(locator: locator,
                                                     heading: titles[page]),
                                  text: passage.text))
            }
        }
        return made
    }

    /// ページごとの「いまどの節か」。アウトラインから引く。
    private static func sectionTitles(_ pdf: PDFKit.PDFDocument) -> [String] {
        var titles = [String](repeating: "", count: pdf.pageCount)
        guard let root = pdf.outlineRoot else { return titles }

        var marks: [(page: Int, title: String)] = []
        var stack = [root]
        while let node = stack.popLast() {
            for at in (0 ..< node.numberOfChildren).reversed() {
                guard let child = node.child(at: at) else { continue }
                if let page = child.destination?.page {
                    marks.append((pdf.index(for: page), child.label ?? ""))
                }
                stack.append(child)
            }
        }
        marks.sort { $0.page < $1.page }

        var current = ""
        var next = 0
        for page in 0 ..< pdf.pageCount {
            while next < marks.count, marks[next].page <= page {
                current = marks[next].title
                next += 1
            }
            titles[page] = current
        }
        return titles
    }

    // MARK: - 段落に切る

    private struct Passage {
        /// 元の本文の中での位置。章内の位置を測るのに使う。
        var offset: Int
        var text: String
    }

    /// 文の切れ目で詰めて、狙いの長さの段落にする。
    ///
    /// **短い切れ端は前に足す。** 見出しだけの行や 1 文だけの段落を独り立ちさせると、
    /// 文脈の無いベクトルが索引を埋める。
    private static func passages(in text: String, leastCharacters: Int) -> [Passage] {
        guard text.count >= leastCharacters else { return [] }

        var made: [Passage] = []
        var current = ""
        var start = 0
        var seen = 0

        for chunk in chunks(of: text) {
            if current.isEmpty { start = seen }
            current += chunk
            seen += chunk.count
            if current.count >= targetCharacters {
                made.append(Passage(offset: start, text: tidy(current)))
                current = ""
            }
        }
        if !current.isEmpty {
            let last = tidy(current)
            if last.count >= leastCharacters {
                made.append(Passage(offset: start, text: last))
            } else if var previous = made.popLast() {
                // 端数は前に足す。独り立ちさせない。
                previous.text = tidy(previous.text + last)
                made.append(previous)
            }
        }
        return made
    }

    /// 詰める前の切れ端。改行か句点で割り、長すぎるものは力尽くで切る。
    private static func chunks(of text: String) -> [String] {
        var made: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            let breaks = character == "\n" || character == "。" || character == "．"
                || character == "！" || character == "？"
            if breaks || current.count >= mostCharacters {
                made.append(current)
                current = ""
            }
        }
        if !current.isEmpty { made.append(current) }
        return made
    }

    // MARK: - 共通

    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 飛び先に載せる目印。
    ///
    /// 読み手はこれを本文の中から探して、そこへ寄せる
    /// （EPUB は `choroScrollToText`、PDF は `findString`）。
    /// **長いほど外れやすい。** 取り出した本文と画面上の本文は、
    /// 空白や組み方の都合で完全には一致しないためである。
    /// 見つからなければ章内の位置（EPUB）やページ（PDF）へ落ちる。
    private static func anchor(_ text: String) -> String? {
        let trimmed = tidy(text)
        guard trimmed.count >= 8 else { return nil }
        return String(trimmed.prefix(anchorCharacters))
    }
}
