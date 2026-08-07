import Foundation

/// いま読んでいる場所に関連する、他の書籍の箇所。
///
/// spec-local-ai.md 第 1.2 節でいう本命の機能である。
/// 意味検索（問いを打つ）と違い、**こちらは何も打たなくても出る**。
struct RelatedPassage: Identifiable, Hashable {
    var id: String { "\(book.path)#\(unit.locator.href ?? "")-\(unit.locator.page ?? -1)-\(unit.locator.progression)" }

    var book: LibraryEntry
    var unit: SemanticUnit
    var score: Float
}

/// 関連箇所を探す。
///
/// **索引は候補を出すだけ**という本体の考え方に合わせ、ここも順位を付けて返すだけで、
/// 本文は出さない。押されたら原書のその場所へ飛ぶ（第 2 章の 5）。
enum RelatedPassages {
    /// これより遠いものは出さない。
    ///
    /// 意味の近さには「当たり」が無いので、下を切らないと
    /// **蔵書のどこかしらが必ず 3 件出る**。関係の無いものが常に並ぶと、
    /// 出ていること自体が信用されなくなる。
    static let leastScore: Float = 0.6

    /// 同じ本から出す数の上限。1 冊に埋め尽くされないようにする。
    private static let perBook = 2

    /// いま読んでいる場所に近い箇所を、**他の書籍から**探す。
    ///
    /// - Parameters:
    ///   - locator: いま読んでいる場所
    ///   - here: いま読んでいる書籍の索引。ここから「いまの節」のベクトルを取る
    ///   - excluding: いま読んでいる書籍。同じ本は出さない
    ///   - limit: 出す数
    ///
    /// **UI を持つスレッドから呼んでよい。** 読むのはほどいた索引だけで、
    /// 推論は回さない（いまの節のベクトルは既にある）。
    @MainActor
    static func find(near locator: Locator,
                     in here: SemanticIndex,
                     excluding current: BookID,
                     limit: Int = 8) -> [RelatedPassage] {
        guard let at = unit(for: locator, in: here), let query = here.vector(at: at) else { return [] }

        var found: [RelatedPassage] = []
        for entry in LibraryStore.shared.entries where entry.id != current {
            guard let url = LibraryStore.shared.resolveURL(for: entry),
                  let index = SemanticIndexStore.cached(for: url),
                  index.dimension == here.dimension, index.model == here.model else { continue }
            for hit in index.nearest(to: query, limit: perBook) where hit.score >= leastScore {
                found.append(RelatedPassage(book: entry, unit: index.units[hit.unit], score: hit.score))
            }
        }
        return Array(found.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// いまの場所がどの節に当たるか。
    ///
    /// 節は「章のここから」という形で並んでいるので、
    /// **同じ章の中で、いまの位置を越えない最後の節**が答えになる。
    static func unit(for locator: Locator, in index: SemanticIndex) -> Int? {
        var best: Int?
        for (at, unit) in index.units.enumerated() {
            if let page = locator.page {
                guard let theirs = unit.locator.page, theirs <= page else { continue }
            } else if let href = locator.href {
                guard unit.locator.href == href,
                      unit.locator.progression <= locator.progression + 1e-6 else { continue }
            } else {
                continue
            }
            best = at
        }
        // どれにも当てはまらなければ、その章（頁）の最初の節を返す。
        // 章の頭に節が無い（前書きが下限に届かない）ときに起きる。
        if best == nil {
            best = index.units.firstIndex {
                if let page = locator.page { return $0.locator.page.map { $0 >= page } ?? false }
                return $0.locator.href == locator.href
            }
        }
        return best
    }
}
