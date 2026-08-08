import Foundation
import PDFKit

/// 当たった段落の本文を、**原書から切り出す**。
///
/// 索引は本文を控えない（`SemanticUnit`）。二字組索引が候補を絞ってから
/// 原書を走査し直すのと同じで、意味の索引も地図であって写しではない
/// （spec.md 第 10.4 節、spec-local-ai.md 第 2 章の 3）。
///
/// 控えていた頃は**本の 35% が原文のまま索引ファイルに入っていた**。
enum PassageText {
    /// 切り出す長さ。**段落 1 つぶん**（`SemanticUnits` の目安が 400 字）。
    ///
    /// 一覧には 2〜3 行しか出さないので、見せるだけなら 160 字で足りる。
    /// それより長く採るのは**並べ直しのため**である。cross-encoder は本文を読んで
    /// 点を付けるので、頭の 160 字で切ると、段落の後半で答えている候補を落とす。
    ///
    /// 読むのは 1 度きりにする。見せる用と並べ直す用で 2 度開くと、
    /// 40 件で 40 回ぶん余計に開くことになる。
    static let displayCharacters = 480

    /// 1 冊ぶんをまとめて切り出す。
    ///
    /// **書籍は 1 度だけ開く。** 1 件ごとに開き直すと、40 件で 40 回開くことになる。
    ///
    /// **UI を持つスレッドから呼んではいけない。** 章やページを読む。
    /// 返すのは**渡した並びの番号**で引ける形。
    ///
    /// 単位そのものを鍵にすると、同じ頁の段落どうしが重なって取りこぼす
    /// （PDF は章も頁も位置も同じになり、違うのは目印だけである）。
    static func read(_ units: [SemanticUnit], from url: URL,
                     limit: Int = displayCharacters) -> [Int: String] {
        guard let source = SearchIndexStore.open(url) else { return [:] }
        var made: [Int: String] = [:]
        // 同じ章（ページ）を何度も取り出さない。
        var pages: [String: String] = [:]

        for (at, unit) in units.enumerated() {
            let key: String
            switch source {
            case let .epub(resources, _):
                guard let href = unit.locator.href else { continue }
                key = href
                if pages[key] == nil, let data = try? resources.read(href) {
                    pages[key] = tidy(HTMLText.extract(CSSCompat.decodeText(data)).text)
                }
            case let .pdf(pdf):
                guard let page = unit.locator.page, page >= 0, page < pdf.pageCount else { continue }
                key = "p\(page)"
                if pages[key] == nil { pages[key] = tidy(pdf.page(at: page)?.string ?? "") }
            }
            guard let whole = pages[key], !whole.isEmpty else { continue }
            made[at] = cut(whole, unit.locator, limit: limit)
        }
        return made
    }

    /// 切り出す場所を決めて、そこから採る。
    ///
    /// **採るのは長さで切るだけで、段落の終わりでは止まらない。**
    /// 単位は始まりの位置しか控えていないので、終わりが分からないためである
    /// （終わりも控えると索引が太る）。短い段落では次の段落へはみ出す。
    /// 見せる側は 2〜3 行に切るので目に見えず、並べ直す側にとっては
    /// 前後の文脈が少し混じるだけで、害にはならない。
    ///
    /// **EPUB は位置が答えである。** 章の中の位置を 10 万分の 1 まで持っているので、
    /// 1,000 字の章なら 0.01 字の粗さになる。目印はその答え合わせに使う。
    ///
    /// 目印だけで探すと外れる。**繰り返しの多い本文**（箇条書き、定型の言い回し、
    /// 同じ説明の続く節）では、手前の同じ並びに当たるためである。
    /// 実際、検査で「先頭の段落である。」が続く本文が手前に寄った。
    ///
    /// PDF は頁の中の位置を持たない（頁で既に絞れている）ので、目印で探す。
    private static func cut(_ whole: String, _ locator: Locator, limit: Int) -> String {
        let from = start(in: whole, locator, limit: limit)
        let rest = whole[from...]
        guard rest.count > limit else { return String(rest) }
        return String(rest.prefix(limit)) + "…"
    }

    private static func start(in whole: String, _ locator: Locator, limit: Int) -> String.Index {
        let anchor = (locator.text?.isEmpty ?? true) ? nil : locator.text

        guard locator.href != nil else {
            // PDF。目印で探し、無ければ頁の頭から。
            guard let anchor, let found = whole.range(of: anchor) else { return whole.startIndex }
            return found.lowerBound
        }

        let approximate = min(whole.count, max(0, Int((Double(whole.count) * locator.progression).rounded())))
        let at = whole.index(whole.startIndex, offsetBy: approximate)
        guard let anchor else { return at }

        // 位置の先が目印と合っていれば、それが答え。
        if whole[at...].hasPrefix(anchor) { return at }

        // 合わなければ、位置のまわりで**いちばん近い**ところを採る。
        // 「位置以降で最初」にすると、繰り返しの本文で手前に寄る。
        let low = whole.index(whole.startIndex, offsetBy: max(0, approximate - limit))
        let high = whole.index(whole.startIndex, offsetBy: min(whole.count, approximate + limit))
        var best: String.Index?
        var search = low ..< high
        while let found = whole.range(of: anchor, range: search) {
            if best.map({ distance(whole, from: found.lowerBound, to: at)
                          < distance(whole, from: $0, to: at) }) ?? true {
                best = found.lowerBound
            }
            guard found.lowerBound < high else { break }
            search = whole.index(after: found.lowerBound) ..< high
        }
        return best ?? at
    }

    private static func distance(_ whole: String, from: String.Index, to: String.Index) -> Int {
        abs(whole.distance(from: from, to: to))
    }

    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 一覧に出すぶんの本文を、裏で読んで配る。
///
/// 画面は一拍おいて本文が入る。**索引から出すより遅いが、控えないための代償である。**
@MainActor
final class PassageTextLoader: ObservableObject {
    /// 札（`RelatedPassage.id`）で引ける本文。
    @Published private(set) var texts: [String: String] = [:]

    private var generation = 0

    func clear() {
        generation += 1
        texts = [:]
    }

    /// 書籍ごとにまとめて読む。
    func load(_ passages: [RelatedPassage], resolve: (LibraryEntry) -> URL?) {
        generation += 1
        let mine = generation
        texts = [:]

        var byBook: [URL: [(id: String, unit: SemanticUnit)]] = [:]
        for passage in passages {
            guard let url = resolve(passage.book) else { continue }
            byBook[url, default: []].append((passage.id, passage.unit))
        }
        guard !byBook.isEmpty else { return }

        Task.detached(priority: .userInitiated) {
            for (url, wanted) in byBook {
                let made = PassageText.read(wanted.map(\.unit), from: url)
                let byId = Dictionary(uniqueKeysWithValues:
                    made.compactMap { at, text in
                        at < wanted.count ? (wanted[at].id, text) : nil
                    })
                await MainActor.run { [weak self] in
                    guard let self, self.generation == mine else { return }
                    // 1 冊ぶん読めるたびに配る。全部揃うまで待たせない。
                    self.texts.merge(byId) { _, new in new }
                }
            }
        }
    }
}
