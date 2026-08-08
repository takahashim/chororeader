import Foundation
import PDFKit

/// 書誌。**書棚が本を並べ替えたり、同じ本を見分けたりするための情報。**
///
/// 題名と著者は既に持っていたが、出版社・発行日・ISBN は**読みながら捨てていた**。
/// EPUB は OPF に、PDF は書類属性に入っている。
///
/// | | EPUB | PDF |
/// |---|---|---|
/// | 出版社 | `dc:publisher` | `Publisher`（規格外の属性） |
/// | 発行日 | `dc:date` | `Issued` か `CreationDate` |
/// | ISBN | `dc:identifier` の `urn:isbn:…` | `ISBN` か `SrcISBN` |
/// | 副題 | `title-type` が `subtitle` の `dc:title` | 無し |
///
/// 手元の蔵書で数えると、EPUB は 8 冊中 4 冊が ISBN を、PDF は 9 冊中 4 冊が
/// `Publisher` と `ISBN` を持っていた。**全部は揃わない前提で組む。**
///
/// **プローブの出力には載せない。** 契約（conformance/CONTRACT.md）に載せると
/// Rust と C# にも同じ解釈を要求することになる。書棚は macOS だけの話なので、
/// 揃える必要が出るまでこちら側に留める。
struct Bibliography: Codable, Hashable {
    var publisher: String?
    var published: String?
    var isbn: String?
    var subtitle: String?

    var isEmpty: Bool {
        publisher == nil && published == nil && isbn == nil && subtitle == nil
    }

    var year: Int? {
        published.flatMap { Int($0.prefix(4)) }
    }

    // MARK: - 取り出す

    static func of(_ publication: EPUBPublication) -> Bibliography {
        Bibliography(publisher: publication.publisher,
                     published: date(publication.published),
                     isbn: isbn(from: publication.identifiers),
                     subtitle: publication.subtitle)
    }

    static func of(_ pdf: PDFKit.PDFDocument) -> Bibliography {
        let attributes = pdf.documentAttributes ?? [:]
        func text(_ key: String) -> String? {
            let value = (attributes[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value : nil
        }
        let issued = text("Issued")
            ?? (attributes[PDFKit.PDFDocumentAttribute.creationDateAttribute] as? Date).map {
                stamp.string(from: $0)
            }
        var made = Bibliography(publisher: text("Publisher"),
                                published: date(issued),
                                isbn: isbn(from: [text("ISBN"), text("SrcISBN")].compactMap { $0 }),
                                subtitle: nil)
        // **名乗りを先に、紙面を後に。** 名乗っていない欄だけを奥付で埋める
        // （`Colophon`）。手元の 9 冊では ISBN が 4 冊から 6 冊に増えた。
        if made.publisher == nil || made.isbn == nil {
            let read = Colophon.bibliography(of: pdf)
            made.publisher = made.publisher ?? read.publisher
            made.isbn = made.isbn ?? read.isbn
        }
        return made
    }

    // MARK: - 整える

    private static let stamp: DateFormatter = {
        let made = DateFormatter()
        made.locale = Locale(identifier: "en_US_POSIX")
        made.timeZone = TimeZone(secondsFromGMT: 0)
        made.dateFormat = "yyyy-MM-dd"
        return made
    }()

    /// `2015-11-10T09:00:00Z` も `2015-11-10` も `2015` も受ける。
    /// **形が違うだけで捨てない。** 年しか無い本がある。
    static func date(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let head = String(raw.prefix(10))
        for pattern in ["\\d{4}-\\d{2}-\\d{2}", "\\d{4}-\\d{2}", "\\d{4}"] {
            if let found = head.range(of: "^" + pattern, options: .regularExpression) {
                return String(head[found])
            }
        }
        return nil
    }

    /// 並びの中から ISBN を選ぶ。**最初の identifier とは限らない。**
    /// EPUB は uuid を先に置き、ISBN を後ろに置くことが多い。
    static func isbn(from values: [String]) -> String? {
        for value in values {
            let digits = value.uppercased()
                .replacingOccurrences(of: "URN:ISBN:", with: "")
                .filter { $0.isNumber || $0 == "X" }
            if digits.count == 13 || digits.count == 10 { return digits }
        }
        return nil
    }
}
