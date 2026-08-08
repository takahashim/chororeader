import Foundation

struct RelatedPassage: Identifiable, Hashable {
    /// 一覧の札。
    ///
    /// **本文の目印まで入れる。** PDF では同じ頁の段落が章も頁も位置も同じになるので、
    /// 目印を落とすと札が重なる。重なると一覧が取り違え、本文の配りも当たらない。
    var id: String {
        let where_ = "\(unit.locator.href ?? "")-\(unit.locator.page ?? -1)-\(unit.locator.progression)"
        return "\(book.path)#\(where_)#\(unit.locator.text ?? "")"
    }

    var book: LibraryEntry
    var unit: SemanticUnit
    var score: Float
}

enum RelatedPassages {
    /// これより遠いものは出さない。
    ///
    /// 意味の近さには「当たり」が無いので、下を切らないと
    /// **蔵書のどこかしらが必ず 3 件出る**。関係の無いものが常に並ぶと、
    /// 出ていること自体が信用されなくなる。
    static let leastScore: Float = 0.6

    /// 同じ本から出す数の上限。1 冊に埋め尽くされないようにする。
    private static let perBook = 2

    /// 渡されたベクトルに近い箇所を、**他の書籍から**探す。
    ///
    /// **UI を持つスレッドから呼んでよい。** 読むのはほどいた索引だけで、推論は回さない。
    @MainActor
    static func find(near query: [Float],
                     like here: SemanticIndex,
                     excluding current: BookID,
                     limit: Int = 12) -> [RelatedPassage] {
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

    /// いまの場所がどの段落に当たるか。
    ///
    /// 段落は「章のここから」という形で並んでいるので、
    /// **同じ章の中で、いまの位置を越えない最後の段落**が答えになる。
    ///
    /// 選んだところから引くのが主だが、選ばずに引くとき（節まるごとを種にするとき）に使う。
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
