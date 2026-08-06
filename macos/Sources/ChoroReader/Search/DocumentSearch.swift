import Foundation
import PDFKit

struct SearchResult: Identifiable, Hashable {
    let id = UUID()
    var locator: Locator
    var chapterTitle: String
    var before: String
    var match: String
    var after: String
    var isCode: Bool
    /// その章の中で何番目の当たりか。同じ語が何度も出る章で、押したものを選び直すために使う。
    var nth: Int = 0
}

/// 検索結果から飛んだ先で強調する当たり。
///
/// 一覧に前後の文脈が出ていても、着いた章やページのどこに当たったのかは分からない。
/// 飛んだ先で目当ての語を探し直さずに済ませるための印である（spec.md 10.4）。
struct SearchMark: Codable, Hashable {
    var query: String
    var nth: Int
    /// 当たりのあった場所。ほかの章やページへ移ったら囲まない。
    var target: Locator
}

/// 章の HTML から本文とコードを取り出す。
enum HTMLText {
    struct Extracted {
        var text: String
        /// コードブロックが占める範囲。検索結果の種別表示に使う。
        var codeRanges: [Range<Int>]

        func isCode(at offset: Int) -> Bool {
            codeRanges.contains { $0.contains(offset) }
        }
    }

    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
    ]

    static func extract(_ html: String) -> Extracted {
        var source = html
        source = remove(pattern: #"(?is)<script\b[^>]*>.*?</script>"#, from: source)
        source = remove(pattern: #"(?is)<style\b[^>]*>.*?</style>"#, from: source)
        source = remove(pattern: #"(?s)<!--.*?-->"#, from: source)

        var text = ""
        var codeRanges: [Range<Int>] = []

        guard let re = try? NSRegularExpression(pattern: #"(?is)<pre\b[^>]*>(.*?)</pre>"#) else {
            return Extracted(text: stripTags(source), codeRanges: [])
        }

        var cursor = source.startIndex
        let full = NSRange(source.startIndex..., in: source)
        for match in re.matches(in: source, range: full) {
            guard let whole = Range(match.range, in: source),
                  let inner = Range(match.range(at: 1), in: source) else { continue }
            text += stripTags(String(source[cursor ..< whole.lowerBound]))
            let start = text.count
            text += stripTags(String(source[inner]))
            codeRanges.append(start ..< text.count)
            text += "\n"
            cursor = whole.upperBound
        }
        text += stripTags(String(source[cursor...]))

        return Extracted(text: text, codeRanges: codeRanges)
    }

    private static func remove(pattern: String, from s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    static func stripTags(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var insideTag = false
        var lastWasSpace = false
        for ch in s {
            if ch == "<" { insideTag = true; continue }
            if ch == ">" {
                insideTag = false
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
                continue
            }
            if insideTag { continue }
            if ch == "\n" || ch == "\r" || ch == "\t" {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
                continue
            }
            out.append(ch)
            lastWasSpace = (ch == " ")
        }
        return decodeEntities(out)
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        guard out.contains("&#"), let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) else {
            return out
        }
        var result = out
        for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let whole = Range(m.range, in: out),
                  let flagRange = Range(m.range(at: 1), in: out),
                  let digitsRange = Range(m.range(at: 2), in: out) else { continue }
            let radix = out[flagRange].isEmpty ? 10 : 16
            guard let code = UInt32(out[digitsRange], radix: radix), let scalar = Unicode.Scalar(code) else { continue }
            result.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return result
    }
}

enum DocumentSearch {
    static let resultLimit = 400
    /// 日本語では単語境界が定まらないため、標準は部分一致とする。全角と半角も区別しない。
    static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]

    struct Outcome {
        var results: [SearchResult]
        var truncated: Bool
    }

    static func searchEPUB(resources: ResourceProvider, publication: EPUBPublication, query: String,
                           completion: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = scanEPUB(resources: resources, publication: publication, query: query)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// 読み順のうち `only` に挙がった位置だけを走査する。`nil` なら全部。
    ///
    /// 索引で絞った候補を渡すための入り口。索引は候補を減らすだけで当たりは決めないので、
    /// ここから先の判定は絞っても絞らなくても同じ結果になる。
    /// 章を丸ごと読むので、呼ぶ側が背後のスレッドを用意する。
    static func scanEPUB(resources: ResourceProvider, publication: EPUBPublication, query: String,
                         only: [Int]? = nil, limit: Int = resultLimit) -> Outcome {
        let order = publication.readingOrder
        let titles = order.map { publication.title(forHref: $0.href) ?? ($0.href as NSString).lastPathComponent }
        let wanted = only.map(Set.init)

        var results: [SearchResult] = []
        var truncated = false

        outer: for (i, link) in order.enumerated() {
            if let wanted, !wanted.contains(i) { continue }
            guard let data = try? resources.read(link.href) else { continue }
            let extracted = HTMLText.extract(CSSCompat.decodeText(data))
            let text = extracted.text
            guard !text.isEmpty else { continue }
            let chars = Array(text)

            // 章ごとに当たりの通し番号を振る。走査は読み順なので、章の頭で数え直せばよい。
            var nth = 0
            var searchStart = text.startIndex
            while let range = text.range(of: query, options: options, range: searchStart ..< text.endIndex) {
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                let matchLength = text.distance(from: range.lowerBound, to: range.upperBound)
                let before = String(chars[max(0, offset - 30) ..< offset])
                let after = String(chars[min(chars.count, offset + matchLength) ..< min(chars.count, offset + matchLength + 40)])

                results.append(SearchResult(
                    locator: Locator(href: link.href,
                                     progression: chars.isEmpty ? 0 : Double(offset) / Double(chars.count),
                                     title: titles[i],
                                     text: String(chars[offset ..< min(chars.count, offset + max(matchLength, 12))])),
                    chapterTitle: titles[i],
                    before: before.trimmingCharacters(in: .whitespaces),
                    match: String(text[range]),
                    after: after.trimmingCharacters(in: .whitespaces),
                    isCode: extracted.isCode(at: offset),
                    nth: nth
                ))
                nth += 1

                if results.count >= limit { truncated = true; break outer }
                searchStart = range.upperBound
            }
        }

        return Outcome(results: results, truncated: truncated)
    }
}

/// PDF は PDFKit の非同期検索を使い、UI を止めない。
@MainActor
final class PDFSearcher {
    private var observers: [NSObjectProtocol] = []
    private var collected: [SearchResult] = []
    private var onUpdate: (([SearchResult], Bool) -> Void)?

    func cancel() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    func search(document: PDFKit.PDFDocument, query: String,
                onUpdate: @escaping ([SearchResult], Bool) -> Void) {
        cancel()
        collected = []
        self.onUpdate = onUpdate
        if document.isFinding { document.cancelFindString() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFDocumentDidFindMatch, object: document,
                                            queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
                self.append(selection, in: document)
            }
        })
        observers.append(center.addObserver(forName: .PDFDocumentDidEndFind, object: document,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onUpdate?(self.collected, self.collected.count >= DocumentSearch.resultLimit)
                self.cancel()
            }
        })

        document.beginFindString(query, withOptions: DocumentSearch.options)
    }

    private func append(_ selection: PDFSelection, in document: PDFKit.PDFDocument) {
        guard collected.count < DocumentSearch.resultLimit,
              let page = selection.pages.first else { return }
        let index = document.index(for: page)
        let context = contextText(for: selection, on: page)
        collected.append(SearchResult(
            locator: Locator(page: index,
                             progression: document.pageCount > 1 ? Double(index) / Double(document.pageCount - 1) : 0,
                             title: page.label.map { "p.\($0)" },
                             text: selection.string),
            chapterTitle: "ページ \(page.label ?? String(index + 1))",
            before: context.before,
            match: selection.string ?? "",
            after: context.after,
            isCode: false
        ))
        if collected.count % 20 == 0 { onUpdate?(collected, false) }
    }

    private func contextText(for selection: PDFSelection, on page: PDFPage) -> (before: String, after: String) {
        guard let pageText = page.string, let match = selection.string,
              let range = pageText.range(of: match) else { return ("", "") }
        let chars = Array(pageText)
        let offset = pageText.distance(from: pageText.startIndex, to: range.lowerBound)
        let end = offset + match.count
        let before = String(chars[max(0, offset - 30) ..< offset])
        let after = String(chars[min(chars.count, end) ..< min(chars.count, end + 40)])
        return (before.trimmingCharacters(in: .whitespacesAndNewlines),
                after.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
