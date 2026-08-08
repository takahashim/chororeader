import Foundation
import PDFKit

/// 奥付の紙面から書誌を拾う。
///
/// PDF の書類属性は当てにならない。手元の 9 冊では `Publisher` と `ISBN` を
/// 名乗るのは 4 冊だけだった。一方で**末尾 6 頁の紙面には、6 冊が ISBN の字を、
/// 8 冊が「発行」の字を持っていた**（本文の無い PDF は 0 冊）。情報はある。
///
/// **名乗りを先に、紙面を後に。** 版元が明示したものと、紙面から読み取った
/// ものでは確からしさが違う。名乗っていない欄だけを紙面で埋める。
///
/// **紙面から拾った ISBN は検査数字で確かめる。** 紙面には頁番号も電話番号も
/// 並んでいるので、桁が合うだけの数を掴みうる。名乗られた ISBN は確かめない
/// （版元が書き損じていても、それがその本の名乗りである）。
enum Colophon {
    /// 奥付を探す範囲。**末尾から数えて何頁ぶんか。**
    ///
    /// 3 頁だと足りなかった（9 冊中 4 冊しか見つからない）。奥付の後ろに
    /// 著者紹介・広告・白紙が挟まる本があるためである。
    static let depth = 6

    /// 紙面から拾える書誌。名乗りで埋まらなかったところに使う。
    static func bibliography(of pdf: PDFKit.PDFDocument) -> Bibliography {
        let text = tail(of: pdf)
        guard !text.isEmpty else { return Bibliography() }
        return Bibliography(publisher: publisher(in: text),
                            published: nil,   // 発行日は書類属性の方が揃う（9/9）
                            isbn: isbn(in: text),
                            subtitle: nil)
    }

    /// 末尾の紙面。**先頭の数行で切らない。** ISBN は奥付の下の方に刷ってある。
    static func tail(of pdf: PDFKit.PDFDocument) -> String {
        guard pdf.pageCount > 0 else { return "" }
        return (max(0, pdf.pageCount - depth) ..< pdf.pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    /// 紙面の ISBN。**検査数字の合うものだけ。**
    static func isbn(in text: String) -> String? {
        let pattern = "ISBN[^0-9]{0,4}([0-9][0-9\\- ]{9,20}[0-9Xx])"
        var from = text.startIndex
        while let found = text.range(of: pattern, options: .regularExpression, range: from ..< text.endIndex) {
            let digits = text[found].uppercased().filter { $0.isNumber || $0 == "X" }
            if let made = Bibliography.isbn(from: [digits]), isValid(made) { return made }
            from = found.upperBound
        }
        return nil
    }

    /// ISBN の検査数字。**13 桁と 10 桁で規則が違う。**
    static func isValid(_ isbn: String) -> Bool {
        let digits = Array(isbn.uppercased())
        switch digits.count {
        case 13:
            var sum = 0
            for (at, c) in digits.enumerated() {
                guard let n = c.wholeNumberValue else { return false }
                sum += at % 2 == 0 ? n : n * 3
            }
            return sum % 10 == 0
        case 10:
            var sum = 0
            for (at, c) in digits.enumerated() {
                let n = c == "X" ? 10 : c.wholeNumberValue
                guard let n, at < 9 || c == "X" || c.isNumber else { return false }
                sum += n * (10 - at)
            }
            return sum % 11 == 0
        default:
            return false
        }
    }

    /// 紙面の発行所。
    ///
    /// **住所や電話番号を巻き込まない。** 奥付は「発行所 ○○社」の後ろに
    /// 〒や番地が続く。名前らしいところで切る。
    static func publisher(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let flat = line.replacingOccurrences(of: "　", with: "")
                .trimmingCharacters(in: .whitespaces)
            for mark in ["発行所", "発行元", "発行者"] where flat.hasPrefix(mark) {
                var name = String(flat.dropFirst(mark.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ：:・"))
                // 住所が続いたらそこで切る。
                if let cut = name.range(of: "[〒\\d]", options: .regularExpression) {
                    name = String(name[..<cut.lowerBound])
                }
                name = name.trimmingCharacters(in: .whitespaces)
                if (2 ... 30).contains(name.count) { return name }
            }
        }
        return nil
    }
}
