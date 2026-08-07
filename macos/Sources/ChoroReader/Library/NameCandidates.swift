import PDFKit

/// 刷ってある行から、名前の候補を拾う。
///
/// 書籍は題名をメタデータに名乗らないことが多いが、紙面には刷ってある。
/// 手で打たせる代わりに、刷ってある行を押して選べるようにする。
///
/// **奥付を先に見る。** 表紙は飾りの組版で行が砕けることがあり
/// （題名が「入門」「で作る」のような断片になって読み順にならない）、
/// 奥付は決まった形で素直に組まれている。題名も著者も、いちばん確かな形でそこにある。
///
/// 行の解釈だけを持ち、画面には触らない。
enum NameCandidates {
    struct Candidate: Equatable {
        var text: String
        /// 著者の行らしいか。「著者：」「〜著」「著 者 〜」の形から見る。
        var isAuthor: Bool
    }

    /// 候補。奥付、表紙の順に拾い、同じ行は 1 度だけ出す。
    static func candidates(in pdf: PDFDocument) -> [Candidate] {
        var seen = Set<String>()
        var out: [Candidate] = []
        for line in colophonLines(pdf) + firstPageLines(pdf) {
            guard let candidate = candidate(from: line) else { continue }
            guard seen.insert(candidate.text).inserted else { continue }
            out.append(candidate)
        }
        return out
    }

    /// 奥付らしいページの行。後ろから 3 ページまで探す。
    ///
    /// 奥付は最後か、著者紹介を挟んでそのひとつ前にある。
    /// 「発行」の字と年月日が並ぶページを奥付と見なす。
    static func colophonLines(_ pdf: PDFDocument) -> [String] {
        for back in 1 ... min(3, pdf.pageCount) {
            let lines = lines(of: pdf, page: pdf.pageCount - back, limit: 24)
            let marks = lines.filter { $0.contains("発行") || $0.contains("発 行") }
            if !marks.isEmpty { return lines }
        }
        return []
    }

    /// PDF の 1 ページ目の行。テキスト層が無ければ空になる。
    /// そのときは候補が出ないだけで、画像を見ながら打つ道は残る。
    static func firstPageLines(_ pdf: PDFDocument) -> [String] {
        lines(of: pdf, page: 0, limit: 12)
    }

    private static func lines(of pdf: PDFDocument, page index: Int, limit: Int) -> [String] {
        guard index >= 0, let text = pdf.page(at: index)?.string else { return [] }
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.prefix(limit))
    }

    /// 1 行を候補にする。名前になり得ない行は nil。
    static func candidate(from line: String) -> Candidate? {
        if isNoise(line) { return nil }
        return classify(line)
    }

    /// 名前になり得ない行。奥付には住所・URL・発行日・版元の並びが同居している。
    private static func isNoise(_ line: String) -> Bool {
        if line.count > 32 { return true }  // 本文の文。著者紹介の説明文など
        if line.hasSuffix("。") { return true }  // 文は名前ではない。奥付の説明書きを落とす
        if line.contains("〒") || line.lowercased().contains("http") { return true }
        if line.contains("丁目") || line.contains("番地") { return true }  // 〒 が別の行の住所
        if line.hasPrefix("©") || line.hasPrefix("(c)") || line.lowercased().contains("rights reserved") { return true }
        // 会社の名は題名にならない。文の折り返しで「。」を持たない断片もこれで落ちる。
        if line.contains("株式会社") || line.contains("有限会社") || line.contains("合同会社") { return true }
        if line.contains("ISBN") { return true }
        if line.contains("初版") || (line.contains("年") && line.contains("発行")) { return true }
        // 版元の役割の行。名前が続くが、著者ではない。
        if line.range(of: #"^(発\s*行|発\s*売|販\s*売|印\s*刷|製\s*本|編\s*集|企\s*画|発行人|編集人|ディレクター|アートディレクター|装丁|編集協力)"#,
                      options: .regularExpression) != nil { return true }
        // 見出しの行。
        if ["著者紹介", "目次", "奥付", "まえがき", "あとがき"].contains(line) { return true }
        if line.contains("····") { return true }  // 目次の点線
        return false
    }

    /// 役割を示す前置き。剥がした残りが名前になる。
    private static let authorPrefixes = [
        "著者：", "著者:", "監修：", "監修:", "訳：", "訳:", "編：", "編:", "著：", "著:",
    ]
    /// 名前の後ろに付く役割。全角と半角の空白の両方がある。
    private static let authorSuffixes = [
        " 著", "　著", " 訳", "　訳", " 監修", "　監修", " 編", "　編",
    ]

    static func classify(_ line: String) -> Candidate {
        for prefix in authorPrefixes where line.hasPrefix(prefix) {
            let name = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return Candidate(text: name.isEmpty ? line : name, isAuthor: true)
        }
        // 奥付の「著 者 架空太郎」。ラベルの字間に空白が入る組み方。
        // ラベルと名前のあいだの空白を必須にする。「著者紹介」を著者「紹介」と読まないため。
        if let match = line.range(of: #"^(著\s*者|訳\s*者|監\s*修|編\s*著)[ 　]+"#,
                                  options: .regularExpression) {
            let name = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return Candidate(text: name, isAuthor: true) }
        }
        for suffix in authorSuffixes where line.hasSuffix(suffix) {
            let name = String(line.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            return Candidate(text: name.isEmpty ? line : name, isAuthor: true)
        }
        return Candidate(text: line, isAuthor: false)
    }
}
