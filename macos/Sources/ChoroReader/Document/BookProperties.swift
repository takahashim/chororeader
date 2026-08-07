import Foundation
import PDFKit

/// 開いている書籍について、書籍そのものが名乗っていることをまとめる。
///
/// 診断（BookReport）とは役目が違う。あちらは「表示がおかしいときに、原因が
/// 書籍側か実装側かを切り分ける」ためのもので、実装間の突き合わせにも使う。
/// こちらは**読む人が知りたいこと**——誰が書いたか、いつ作られたか、何ページか——
/// を出すだけで、突き合わせの対象にはしない。
///
/// 形式で名乗る項目が違うので、共通の枠に押し込めない。
/// 項目の並びをそのまま持ち、画面はそれを並べるだけにする。
struct BookProperties: Equatable {
    /// ひとまとまりの項目。「書誌」「ファイル」のように区切って出す。
    struct Section: Equatable {
        var title: String
        var items: [Item]
    }

    struct Item: Equatable {
        var label: String
        var value: String
    }

    var sections: [Section]

    /// 書き写すための平たい形。目で見るだけでは書き写せない（診断と同じ）。
    var asText: String {
        sections.map { section in
            let lines = section.items.map { "  \($0.label)\t\($0.value)" }
            return ([section.title] + lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

@MainActor
extension BookProperties {
    /// ファイルから組み立てる。書棚のように、開いていない書籍から読むとき用。
    ///
    /// 書籍を開くのと同じだけ読むので、主スレッドから直に呼ばない。
    /// 開けなければ、ファイルの素性だけを返す。
    static func read(_ url: URL) -> BookProperties {
        let file = FileFacts.read(url)
        guard let document = try? BookDocument(url: url) else {
            return BookProperties(sections: [file].compactMap { $0 }.map(fileSection))
        }
        return make(document: document, file: file)
    }

    /// 開いている書籍から組み立てる。`file` はファイルそのものの素性で、中身とは別に読む。
    static func make(document: BookDocument, file: FileFacts?) -> BookProperties {
        var sections: [Section] = []

        switch document.source {
        case let .epub(_, publication):
            sections.append(epubBibliography(publication))
            sections.append(epubStructure(publication: publication))
        case let .pdf(pdf):
            sections.append(pdfBibliography(pdf))
            sections.append(pdfStructure(pdf))
        }

        if let file { sections.append(fileSection(file)) }
        return BookProperties(sections: sections.map(trimmed).filter { !$0.items.isEmpty })
    }

    /// 名乗っていない項目は出さない。空欄を並べても読む人の役に立たない。
    private static func trimmed(_ section: Section) -> Section {
        Section(title: section.title,
                items: section.items.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    // MARK: - EPUB

    private static func epubBibliography(_ publication: EPUBPublication) -> Section {
        Section(title: "書誌", items: [
            Item(label: "題名", value: publication.title),
            Item(label: "著者", value: publication.authors.joined(separator: "、")),
            Item(label: "言語", value: publication.language ?? ""),
            Item(label: "識別子", value: publication.identifier ?? ""),
        ])
    }

    private static func epubStructure(publication: EPUBPublication) -> Section {
        Section(title: "中身", items: [
            Item(label: "形式", value: publication.layout == .fixed ? "固定レイアウト EPUB" : "リフロー型 EPUB"),
            Item(label: "綴じ方向", value: publication.direction == .rtl ? "右開き" : "左開き"),
            Item(label: "章の数", value: count(publication.readingOrder.count, "項目")),
            Item(label: "目次の項目", value: count(entryCount(publication.tableOfContents), "項目")),
            Item(label: "表紙", value: publication.coverHref == nil ? "無し" : "有り"),
        ])
    }

    private static func entryCount(_ entries: [TOCEntry]) -> Int {
        entries.reduce(0) { $0 + 1 + entryCount($1.children) }
    }

    // MARK: - PDF

    private static func pdfBibliography(_ pdf: PDFKit.PDFDocument) -> Section {
        let attributes = pdf.documentAttributes ?? [:]
        func attribute(_ key: PDFDocumentAttribute) -> String {
            (attributes[key] as? String) ?? ""
        }
        func date(_ key: PDFDocumentAttribute) -> String {
            guard let value = attributes[key] as? Date else { return "" }
            return Self.dateText(value)
        }

        return Section(title: "書誌", items: [
            Item(label: "題名", value: attribute(.titleAttribute)),
            Item(label: "著者", value: attribute(.authorAttribute)),
            Item(label: "主題", value: attribute(.subjectAttribute)),
            Item(label: "キーワード", value: keywords(attributes)),
            Item(label: "作成したもの", value: attribute(.creatorAttribute)),
            Item(label: "書き出したもの", value: attribute(.producerAttribute)),
            Item(label: "作成日時", value: date(.creationDateAttribute)),
            Item(label: "更新日時", value: date(.modificationDateAttribute)),
        ])
    }

    /// キーワードは配列で来ることも 1 つの文字列で来ることもある。
    private static func keywords(_ attributes: [AnyHashable: Any]) -> String {
        if let list = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            return list.joined(separator: "、")
        }
        return (attributes[PDFDocumentAttribute.keywordsAttribute] as? String) ?? ""
    }

    private static func pdfStructure(_ pdf: PDFKit.PDFDocument) -> Section {
        var items: [Item] = [
            Item(label: "形式", value: "PDF"),
            Item(label: "版", value: "\(pdf.majorVersion).\(pdf.minorVersion)"),
            Item(label: "ページ数", value: count(pdf.pageCount, "ページ")),
        ]
        if let size = pageSize(pdf) {
            items.append(Item(label: "ページの大きさ", value: size))
        }
        // 入稿用にフォントをアウトライン化した PDF は、見た目が鮮明でも文字を持たない。
        // 検索が黙って 0 件になる理由がここで分かるようにする。
        items.append(Item(label: "文字の層", value: hasTextLayer(pdf) ? "有り" : "無し（検索できません）"))
        items.append(Item(label: "暗号化", value: pdf.isEncrypted ? "有り" : "無し"))
        if pdf.isEncrypted {
            items.append(Item(label: "コピー", value: pdf.allowsCopying ? "許可" : "不許可"))
            items.append(Item(label: "印刷", value: pdf.allowsPrinting ? "許可" : "不許可"))
        }
        return Section(title: "中身", items: items)
    }

    /// 1 ページ目の寸法。ポイントとミリの両方で出す。
    /// 技術書では判型が分かると版元の見当が付く。
    private static func pageSize(_ pdf: PDFKit.PDFDocument) -> String? {
        guard let page = pdf.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let mm = { (points: CGFloat) in Int((points * 25.4 / 72).rounded()) }
        return "\(Int(box.width.rounded())) × \(Int(box.height.rounded())) pt"
            + "（\(mm(box.width)) × \(mm(box.height)) mm）"
    }

    /// 先頭の何ページかに文字があるか。全ページ見ると開くたびに重くなる。
    private static func hasTextLayer(_ pdf: PDFKit.PDFDocument) -> Bool {
        for index in 0 ..< min(pdf.pageCount, 5) {
            if let text = pdf.page(at: index)?.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - ファイル

    /// ファイルそのものの素性。書籍の中身とは別に読む。
    struct FileFacts: Equatable {
        var name: String
        var byteCount: Int64
        var modified: Date?
        var directory: String
    }

    private static func fileSection(_ file: FileFacts) -> Section {
        Section(title: "ファイル", items: [
            Item(label: "名前", value: file.name),
            Item(label: "大きさ", value: byteText(file.byteCount)),
            Item(label: "更新日時", value: file.modified.map(dateText) ?? ""),
            Item(label: "場所", value: file.directory),
        ])
    }

    // MARK: - 見せ方

    static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func count(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)"
    }
}

extension BookProperties.FileFacts {
    /// ファイルから読む。読めなければ nil。書籍が開けていても、ここは失敗しうる。
    static func read(_ url: URL) -> BookProperties.FileFacts? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return BookProperties.FileFacts(
            name: url.lastPathComponent,
            byteCount: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate,
            directory: url.deletingLastPathComponent().path
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        )
    }
}
