import Foundation
import PDFKit

struct LibraryHit: Identifiable, Hashable {
    let id = UUID()
    var result: SearchResult
}

/// 1 冊ぶんの当たり。
struct LibraryBookHits: Identifiable, Hashable {
    var id: BookID
    var title: String
    var path: String
    var hits: [LibraryHit]
    /// 上限で打ち切ったか。打ち切ったときは、その本を開いて全件を見る道を出す。
    var truncated: Bool
}

/// 書棚にある書籍を横断して引く。
///
/// 1 冊ずつ索引で候補を絞り、残った章（PDF ならページ）だけを走査し直す。
/// 索引は候補を減らすだけなので、当たりは 1 冊ずつ開いて引いたときと変わらない。
///
/// 索引がまだ無い書籍はその場で作る。1 冊目は書籍を丸ごと読むぶん遅いが、
/// 2 度目からは索引だけで済む。作りながら結果を返すので、待たされている間も手は止まらない。
@MainActor
final class LibrarySearchModel: ObservableObject {
    /// 1 冊から拾う上限。1 冊が結果を埋め尽くさないようにする。
    nonisolated static let perBookLimit = 20

    @Published private(set) var books: [LibraryBookHits] = []
    @Published private(set) var searched = 0
    @Published private(set) var total = 0
    @Published private(set) var building: String?
    @Published private(set) var running = false
    @Published private(set) var query = ""

    private var generation = 0
    private let queue = DispatchQueue(label: "dev.chororeader.library-search", qos: .userInitiated)

    func cancel() {
        generation += 1
        running = false
        building = nil
    }

    var hitCount: Int { books.reduce(0) { $0 + $1.hits.count } }

    func clear() {
        cancel()
        books = []
        searched = 0
        total = 0
        query = ""
    }

    func run(_ query: String, over entries: [LibraryEntry], resolve: (LibraryEntry) -> URL?) {
        cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        books = []
        searched = 0
        guard !query.isEmpty else {
            total = 0
            return
        }

        // 参照の解決は書棚側の仕事なので、走らせる前に済ませておく。
        let targets: [(entry: LibraryEntry, url: URL)] = entries.compactMap { entry in
            resolve(entry).map { (entry, $0) }
        }
        total = targets.count
        running = true

        let generation = self.generation
        queue.async { [weak self] in
            for target in targets {
                guard let self, self.isCurrent(generation) else { return }

                let needsBuilding = SearchIndexStore.cached(for: target.url) == nil
                if needsBuilding {
                    let title = target.entry.displayTitle
                    DispatchQueue.main.async { self.report(generation, building: title) }
                }

                let found = Self.hits(query: query, entry: target.entry, url: target.url)
                DispatchQueue.main.async { self.absorb(generation, found) }
            }
            DispatchQueue.main.async { self?.finish(generation) }
        }
    }

    // MARK: - 進み具合

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation
    }

    private func report(_ generation: Int, building title: String) {
        guard isCurrent(generation) else { return }
        building = title
    }

    private func absorb(_ generation: Int, _ found: LibraryBookHits?) {
        guard isCurrent(generation) else { return }
        if let found { books.append(found) }
        searched += 1
        building = nil
    }

    private func finish(_ generation: Int) {
        guard isCurrent(generation) else { return }
        running = false
        building = nil
    }

    // MARK: - 1 冊を引く

    private nonisolated static func hits(query: String, entry: LibraryEntry, url: URL) -> LibraryBookHits? {
        // 索引があるうちは書籍を開かない。当たらない本には触らずに済む。
        var source: SearchIndexStore.Source?
        var index = SearchIndexStore.cached(for: url)
        if index == nil {
            source = SearchIndexStore.open(url)
            guard let source else { return nil }
            index = SearchIndexStore.index(for: url, source: source)
        }
        guard let candidates = index?.candidates(query), !candidates.isEmpty else { return nil }

        if source == nil { source = SearchIndexStore.open(url) }
        guard let source else { return nil }

        let results: [SearchResult]
        let truncated: Bool
        switch source {
        case let .epub(resources, publication):
            let outcome = DocumentSearch.scanEPUB(resources: resources, publication: publication,
                                                  query: query, only: candidates, limit: perBookLimit)
            results = outcome.results
            truncated = outcome.truncated
        case let .pdf(pdf):
            let outcome = scanPDF(pdf, query: query, pages: candidates)
            results = outcome.results
            truncated = outcome.truncated
        }
        if results.isEmpty { return nil }

        return LibraryBookHits(id: entry.id, title: entry.displayTitle, path: entry.path,
                               hits: results.map { LibraryHit(result: $0) }, truncated: truncated)
    }

    /// PDF は候補のページだけを読み直す。PDFKit の検索は書籍全体にしか掛けられないため。
    private nonisolated static func scanPDF(_ pdf: PDFKit.PDFDocument, query: String,
                                            pages: [Int]) -> DocumentSearch.Outcome {
        var results: [SearchResult] = []
        var truncated = false
        for number in pages {
            if results.count >= perBookLimit { truncated = true; break }
            guard let page = pdf.page(at: number), let text = page.string else { continue }
            let chars = Array(text)

            var from = text.startIndex
            while let range = text.range(of: query, options: DocumentSearch.options,
                                         range: from ..< text.endIndex) {
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                let end = offset + text.distance(from: range.lowerBound, to: range.upperBound)
                results.append(SearchResult(
                    locator: Locator(page: number,
                                     progression: pdf.pageCount > 1 ? Double(number) / Double(pdf.pageCount - 1) : 0,
                                     title: page.label.map { "p.\($0)" },
                                     text: String(text[range])),
                    chapterTitle: "ページ \(page.label ?? String(number + 1))",
                    before: String(chars[max(0, offset - 30) ..< offset])
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    match: String(text[range]),
                    after: String(chars[min(chars.count, end) ..< min(chars.count, end + 40)])
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    isCode: false
                ))
                if results.count >= perBookLimit { truncated = true; break }
                from = range.upperBound
            }
        }
        return DocumentSearch.Outcome(results: results, truncated: truncated)
    }
}
