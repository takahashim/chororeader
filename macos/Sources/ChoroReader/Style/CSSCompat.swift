import Foundation

/// 古い EPUB の CSS を、配信の瞬間に解釈可能な形へ書き換える。
/// 元ファイルには触れない。意味を変える書き換えはせず、解釈できるようにするだけに限る。
enum CSSCompat {
    /// プロパティ名だけを標準形へ移せるもの。
    private static let propertyMap: [String: String] = [
        "-epub-writing-mode": "writing-mode",
        "-epub-text-orientation": "text-orientation",
        "-epub-ruby-position": "ruby-position",
        "-epub-text-emphasis": "text-emphasis",
        "-epub-text-emphasis-color": "text-emphasis-color",
        "-epub-text-emphasis-style": "text-emphasis-style",
        "-epub-text-emphasis-position": "text-emphasis-position",
        "-epub-hyphens": "hyphens",
        "-epub-line-break": "line-break",
        "-epub-word-break": "word-break",
        "-epub-text-align-last": "text-align-last",
        "-epub-caption-side": "caption-side",
    ]

    /// 変換内容は機械可読にしておく。表示崩れの切り分けに使うほか、
    /// 別実装（Windows 版）と突き合わせるときの比較対象になるため。
    struct Change: Codable, Hashable {
        var from: String
        var to: String
        var count: Int

        var logLine: String { "\(from) → \(to) (\(count) 箇所)" }
    }

    struct Result {
        var css: String
        var changes: [Change]
    }

    static func rewrite(css: String) -> Result {
        var changes: [Change] = []
        var out = ""
        out.reserveCapacity(css.count)

        for segment in segments(of: css) {
            switch segment.kind {
            case .comment, .string:
                out += segment.text
            case .code:
                var s = segment.text
                // 値の読み替えが要るものを先に処理する。
                s = replace(s, pattern: #"-epub-text-combine-horizontal\s*:\s*[^;}]*"#,
                            with: "text-combine-upright: all", label: "-epub-text-combine-horizontal",
                            changes: &changes)
                s = replace(s, pattern: #"-epub-text-combine\s*:\s*horizontal"#,
                            with: "text-combine-upright: all", label: "-epub-text-combine: horizontal",
                            changes: &changes)
                for (old, new) in propertyMap {
                    s = replace(s, pattern: NSRegularExpression.escapedPattern(for: old) + #"(?=\s*:)"#,
                                with: new, label: old, changes: &changes)
                }
                out += s
            }
        }
        return Result(css: out, changes: changes)
    }

    /// XHTML 内の <style> ブロックにも同じ変換をかける。書籍側の要素構造には触れない。
    static func rewriteXHTML(_ html: String) -> Result {
        guard html.range(of: "-epub-") != nil else { return Result(css: html, changes: []) }
        var changes: [Change] = []
        var out = html
        let pattern = #"(?is)(<style\b[^>]*>)(.*?)(</style>)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return Result(css: html, changes: []) }
        let matches = re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed()
        for m in matches {
            guard let bodyRange = Range(m.range(at: 2), in: out) else { continue }
            let result = rewrite(css: String(out[bodyRange]))
            if !result.changes.isEmpty {
                out.replaceSubrange(bodyRange, with: result.css)
                changes.append(contentsOf: result.changes)
            }
        }
        return Result(css: out, changes: changes)
    }

    // MARK: - 実装

    private static func replace(_ s: String, pattern: String, with replacement: String,
                                label: String, changes: inout [Change]) -> String {
        guard s.range(of: "-epub-") != nil,
              let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return s }
        let range = NSRange(s.startIndex..., in: s)
        let count = re.numberOfMatches(in: s, range: range)
        guard count > 0 else { return s }
        changes.append(Change(from: label, to: replacement, count: count))
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: replacement)
    }

    private enum SegmentKind { case code, comment, string }
    private struct Segment { var kind: SegmentKind; var text: String }

    /// コメントと文字列リテラルを切り分ける。その内側を書き換えないための下ごしらえ。
    private static func segments(of css: String) -> [Segment] {
        var out: [Segment] = []
        var buffer = ""
        var i = css.startIndex

        func flush(_ kind: SegmentKind) {
            if !buffer.isEmpty { out.append(Segment(kind: kind, text: buffer)); buffer = "" }
        }

        while i < css.endIndex {
            let c = css[i]
            let next = css.index(after: i)
            if c == "/", next < css.endIndex, css[next] == "*" {
                flush(.code)
                var j = css.index(after: next)
                while j < css.endIndex {
                    if css[j] == "*", css.index(after: j) < css.endIndex, css[css.index(after: j)] == "/" {
                        j = css.index(j, offsetBy: 2)
                        break
                    }
                    j = css.index(after: j)
                }
                out.append(Segment(kind: .comment, text: String(css[i ..< j])))
                i = j
                continue
            }
            if c == "\"" || c == "'" {
                flush(.code)
                var j = css.index(after: i)
                while j < css.endIndex {
                    if css[j] == "\\" {
                        j = css.index(j, offsetBy: 2, limitedBy: css.endIndex) ?? css.endIndex
                        continue
                    }
                    if css[j] == c { j = css.index(after: j); break }
                    j = css.index(after: j)
                }
                out.append(Segment(kind: .string, text: String(css[i ..< j])))
                i = j
                continue
            }
            buffer.append(c)
            i = next
        }
        flush(.code)
        return out
    }

    /// UTF-8 以外で書かれたリソースを読めるようにする。
    static func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        for encoding in [String.Encoding.shiftJIS, .japaneseEUC, .isoLatin1] {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
