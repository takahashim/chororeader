import Foundation

/// 検索結果から飛んだ先で、当たった語を `<mark>` で囲む。
///
/// 印は配信時に本文へ入れる（ResourceSchemeHandler）。WebView の中で入れると、
/// 文字節を切って包む手術を JavaScript で書くことになり、
/// 抽出（HTMLText）と数え方がずれる余地が残る。
///
/// **抽出そのものには触らない。** あちらは実装間で突き合わせている中心なので、
/// 抽出した本文と元の HTML を後から突き合わせて位置を求める。
/// 突き合わせがずれても、動くのは印の位置だけで、検索の当たりは動かない。
enum SearchMarkInserter {
    /// 印に付ける名前。本文へ入れるスタイルはこれを見て色を当てる。
    static let className = "choro-found"

    /// 印を入れた場所。実装間で突き合わせるために、囲んだ語とその直前の文脈で表す。
    ///
    /// 位置を数で言うと、実装ごとの数え方（バイトか、符号位置か、書記素か）の違いが
    /// そのまま差になる。文字列で示せば、置いた場所が同じかどうかだけを比べられる。
    struct Placement {
        /// 囲んだ語。
        var marked: String
        /// 囲んだところの直前にある本文（元の HTML から、最大 20 文字）。
        var before: String
    }

    /// 印を置く場所。囲めなければ nil。
    static func locate(in html: String, query: String, nth: Int) -> Placement? {
        let source = Array(html)
        guard let (start, end) = span(source, query: query, nth: nth) else { return nil }
        return Placement(marked: String(source[start ..< end]),
                         before: String(source[max(0, start - 20) ..< start]))
    }

    /// 本文の nth 番目の当たりを囲んだ HTML。囲めなければ nil。
    static func insert(into html: String, query: String, nth: Int) -> String? {
        let source = Array(html)
        guard let (start, end) = span(source, query: query, nth: nth) else { return nil }

        var out = String(source[0 ..< start])
        out += "<mark class=\"\(className)\">"
        out += String(source[start ..< end])
        out += "</mark>"
        out += String(source[end...])
        return out
    }

    /// 囲む範囲（元の HTML の文字位置）。
    private static func span(_ source: [Character], query: String, nth: Int) -> (Int, Int)? {
        guard !query.isEmpty else { return nil }
        let text = HTMLText.extract(String(source)).text
        guard let (from, to) = nthMatch(in: text, query: query, nth: nth) else { return nil }

        let origins = align(source, Array(text))
        guard from < origins.count, to - 1 < origins.count else { return nil }

        let start = origins[from]
        var end = origins[to - 1] + sourceWidth(source, at: origins[to - 1])
        // 節をまたぐ当たりは、始まりの地の文で切る。タグを囲むと入れ子が壊れる。
        end = min(end, runEnd(source, from: start))
        guard end > start, end <= source.count else { return nil }
        return (start, end)
    }

    /// 本文の中で nth 番目の当たりが占める範囲（文字単位、終わりは含まない）。
    /// 走査（DocumentSearch.scanEPUB）と同じ探し方で数えるので、
    /// 検索が返した通し番号と、ここで選ぶ当たりは必ず一致する。
    static func nthMatch(in text: String, query: String, nth: Int) -> (Int, Int)? {
        var searchStart = text.startIndex
        var count = 0
        while let range = text.range(of: query, options: DocumentSearch.options,
                                     range: searchStart ..< text.endIndex) {
            if count == nth {
                let from = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                return (from, from + length)
            }
            count += 1
            searchStart = range.upperBound
        }
        return nil
    }

    // MARK: - 元の HTML との突き合わせ

    /// 抽出した本文の 1 文字ごとに、元の HTML でその文字が始まる位置を求める。
    ///
    /// 抽出は削って詰めるだけなので、元を頭から舐めながら同じ文字を拾えば揃う。
    /// 揃わない文字（タグの位置に足した空白など）は、いま見ている位置を指しておく。
    private static func align(_ source: [Character], _ text: [Character]) -> [Int] {
        var origins: [Int] = []
        origins.reserveCapacity(text.count)
        var at = 0
        var cursor = 0
        var insideTag = false

        while at < text.count, cursor < source.count {
            // 本文に混ぜないところは、抽出も消している。飛ばす。
            if let end = skipIgnored(source, from: cursor) {
                cursor = end
                insideTag = false
                continue
            }

            let c = source[cursor]
            if c == "<" {
                insideTag = true
                cursor += 1
                continue
            }
            if c == ">" {
                insideTag = false
                cursor += 1
                // タグの位置には空白が 1 つ入る。本文側がそれを待っていれば、ここを指す。
                if text[at] == " " {
                    origins.append(cursor)
                    at += 1
                }
                continue
            }
            if insideTag {
                cursor += 1
                continue
            }

            // 実体参照は解かれて 1 文字になる。始まりの位置を指しておく。
            if c == "&", let length = entityLength(source, at: cursor) {
                origins.append(cursor)
                at += 1
                cursor += length
                continue
            }

            if c == text[at] {
                origins.append(cursor)
                at += 1
                cursor += 1
                continue
            }

            // 改行や連なった空白は 1 つに詰められる。本文側が空白を待っていれば、そこで揃える。
            if text[at] == " ", c.isWhitespace {
                origins.append(cursor)
                at += 1
                cursor += 1
                continue
            }
            cursor += 1
        }

        while origins.count < text.count { origins.append(source.count) }
        return origins
    }

    /// script / style / コメントの終わり。そこから始まっていなければ nil。
    private static func skipIgnored(_ source: [Character], from cursor: Int) -> Int? {
        if starts(source, at: cursor, with: "<!--") {
            return find(source, from: cursor, closing: "-->") ?? source.count
        }
        for name in ["script", "style"] where starts(source, at: cursor, with: "<\(name)") {
            return find(source, from: cursor, closing: "</\(name)>") ?? source.count
        }
        return nil
    }

    private static func starts(_ source: [Character], at cursor: Int, with needle: String) -> Bool {
        let chars = Array(needle)
        guard cursor + chars.count <= source.count else { return false }
        for (offset, c) in chars.enumerated()
        where source[cursor + offset].lowercased() != c.lowercased() {
            return false
        }
        return true
    }

    private static func find(_ source: [Character], from cursor: Int, closing: String) -> Int? {
        let chars = Array(closing)
        var index = cursor
        while index + chars.count <= source.count {
            if starts(source, at: index, with: closing) { return index + chars.count }
            index += 1
        }
        return nil
    }

    /// 本文の 1 文字が、元の HTML で占める長さ。実体参照は書かれたぶんを数える。
    private static func sourceWidth(_ source: [Character], at cursor: Int) -> Int {
        guard cursor < source.count else { return 0 }
        if source[cursor] == "&", let length = entityLength(source, at: cursor) { return length }
        return 1
    }

    /// `&...;` の長さ。実体参照でなければ nil。
    private static func entityLength(_ source: [Character], at cursor: Int) -> Int? {
        var index = cursor + 1
        let limit = min(source.count, cursor + 12)
        while index < limit {
            if source[index] == ";" { return index - cursor + 1 }
            if source[index] == " " || source[index] == "<" { return nil }
            index += 1
        }
        return nil
    }

    /// その文字が属する地の文の終わり。次のタグの手前で止める。
    private static func runEnd(_ source: [Character], from cursor: Int) -> Int {
        var index = cursor
        while index < source.count, source[index] != "<" { index += 1 }
        return index
    }
}
