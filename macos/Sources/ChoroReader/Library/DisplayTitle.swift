import Foundation

/// 書棚に出す名前を決める。
///
/// **書籍は題名を名乗らないことが多い。** 手元の PDF を測ったところ、
/// 128 件のうち 104 件が題名を持たなかった。名乗っていても、元の原稿の
/// ファイル名がそのまま入っていることがある（「Microsoft Word - …docx」）。
///
/// どちらの場合も、**ファイル名の方が読める**。人が付けた名前だからである。
/// 中身の題名を捨てるわけではない。書籍の情報（BookProperties）では
/// 名乗ったままを出す。ここが決めるのは一覧に並べる名前だけである。
enum DisplayTitle {
    private static let placeholders: Set<String> = [
        "book", "books", "untitled", "no title", "document", "print", "pdf",
        "無題", "(無題)", "名称未設定", "タイトルなし",
    ]

    /// 元の原稿から引き継がれた名前。題名ではなく、作った道具の痕跡である。
    private static let traces = [
        "microsoft word - ", "microsoft powerpoint - ", "microsoft excel - ",
    ]

    private static let sourceExtensions = [".docx", ".doc", ".indd", ".pages", ".pptx", ".xlsx"]

    /// 一覧に出す名前。`title` が使えなければ、拡張子を外したファイル名を返す。
    ///
    /// **親フォルダまでは見ない。** `<書名>/book.pdf` のように意味を持つ置き方もあるが、
    /// フォルダ名が書籍と関係ないことの方が多い。当たらない代用は、無いより悪い。
    static func of(title: String, path: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if usable(trimmed) { return trimmed }
        return name(URL(fileURLWithPath: path).deletingPathExtension()) ?? trimmed
    }

    /// 道筋の末尾。名前と呼べないものは nil。
    private static func name(_ url: URL) -> String? {
        let last = url.lastPathComponent
        return ["", "/", ".", ".."].contains(last) ? nil : last
    }

    static func usable(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let lower = trimmed.lowercased()
        if placeholders.contains(lower) { return false }
        if traces.contains(where: { lower.hasPrefix($0) }) { return false }
        if sourceExtensions.contains(where: { lower.hasSuffix($0) }) { return false }
        return true
    }
}

extension LibraryEntry {
    var displayTitle: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        return DisplayTitle.of(title: title, path: path)
    }
}
