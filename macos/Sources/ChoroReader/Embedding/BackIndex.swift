import Foundation
import PDFKit

/// 巻末の用語索引がどこからどこまでかを見つける。
///
/// 意味の近さで引くと、**索引の紙面が上位に来る**。語がひたすら並んでいるので
/// 何にでも少しずつ似てしまう。並べ直し（reranker）でも直らない
/// （spikes/findings-reranker.md）。
///
/// ## 目次の項目名だけで決める
///
/// 蔵書で数えた（EPUB 8 冊・PDF 9 冊、2026-08-08）。
///
/// | | EPUB | PDF |
/// |---|---|---|
/// | 索引を持つ | 4 冊 | 5 冊 |
/// | 目次・outline の項目名から範囲が取れた | 4 冊 | 5 冊 |
/// | 索引を持たない本を誤って拾った | 0 冊 | 0 冊 |
///
/// 索引を持つ本は必ず目次に載せている、というだけのことである。
///
/// **`epub:type="index"` は当てにしない。** 標本では 1 冊も付けていなかった。
///
/// **紙面の形（短い行＋頁番号）では判定しない。** 索引を持たない 4 冊のうち
/// **3 冊**で「索引らしい章」を誤検出した。目次に書いていない本は、そもそも
/// 索引を持っていなかった（巻末に「索引」の語すら無い）。
///
/// ## 巻末に無ければ見ない
///
/// 本文の途中に「索引」という節があっても触らない（データベースの索引を
/// 説明する章など）。標本では索引の始まりは EPUB で 92〜97%、PDF で 97〜98% だった。
enum BackIndex {
    /// これより手前から始まるものは索引と見なさない。
    ///
    /// 実測の最小が 92% なので、少し余裕を見て 0.8 に置く。
    /// ここを厳しくすると、前書きの長い本で取りこぼす。
    static let leastPlace = 0.8

    /// 索引の見出しとして認める名前。**完全一致で見る。**
    ///
    /// 「索引の作り方」のような節を巻き込まないため、部分一致にはしない。
    private static let names = ["索引", "さくいん", "用語索引", "事項索引", "index"]

    /// その見出しが索引か。空白は取り除いて比べる。
    static func isIndexName(_ title: String) -> Bool {
        let bare = title.filter { !$0.isWhitespace && $0 != "　" }.lowercased()
        return names.contains(bare)
    }

    // MARK: - EPUB

    /// 読み順のうち、索引が占める範囲。無ければ nil。
    ///
    /// 始まりは目次の「索引」の飛び先、終わりは**その次の目次項目**（奥付など）。
    /// 次が無ければ本の末尾までとする。
    static func range(in publication: EPUBPublication) -> Range<Int>? {
        let ordered = flattened(publication.tableOfContents)
            .compactMap { entry -> (place: Int, title: String)? in
                guard let href = entry.href, let at = publication.index(ofHref: href) else { return nil }
                return (at, entry.title)
            }
            .sorted { $0.place < $1.place }

        let total = publication.readingOrder.count
        guard total > 0, let hit = ordered.firstIndex(where: { isIndexName($0.title) }) else { return nil }
        let from = ordered[hit].place
        guard Double(from) / Double(total) >= leastPlace else { return nil }
        // 同じ章を指す項目が続くことがあるので、**先へ進んだ**最初の項目を終わりにする。
        let until = ordered.dropFirst(hit + 1).first { $0.place > from }?.place ?? total
        return from ..< until
    }

    private static func flattened(_ entries: [TOCEntry]) -> [TOCEntry] {
        entries.flatMap { [$0] + flattened($0.children) }
    }

    // MARK: - PDF

    /// ページのうち、索引が占める範囲。無ければ nil。
    ///
    /// - Parameter titles: ページごとの「いまどの節か」（outline から引いたもの）。
    ///   節の見出しは次の区切りまで引き継がれるので、**名前が索引であるページを
    ///   拾うだけで始まりと終わりが決まる。**
    static func range(pageTitles titles: [String]) -> Range<Int>? {
        let total = titles.count
        guard total > 0, let from = titles.firstIndex(where: isIndexName) else { return nil }
        guard Double(from) / Double(total) >= leastPlace else { return nil }
        let until = titles[from...].firstIndex { !isIndexName($0) } ?? total
        return from ..< until
    }
}
