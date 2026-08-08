import Foundation

/// 蔵書の用語索引を横断して引く画面の側。
///
/// **語を読むのは書籍を開く仕事なので、裏の筋で行う。** ただし意味の索引と違い
/// 推論を回さないので、1 冊あたり数十 ms で済む。押させずに、必要になったら読む。
@MainActor
final class TermSearchModel: ObservableObject {
    @Published private(set) var found = TermSearch.Found()
    @Published private(set) var query = ""
    /// 索引の語をまだ読んでいない書籍を読んでいる最中か。
    @Published private(set) var reading = false

    private var generation = 0

    func clear() {
        generation += 1
        found = TermSearch.Found()
        query = ""
        reading = false
    }

    /// 引く。**置いてある語だけで即座に返し、足りなければ裏で読んで引き直す。**
    ///
    /// 待たせてから出すより、出せるものを先に出す方がよい。
    /// 読み終えたら黙って増える。
    func run(_ text: String, over entries: [LibraryEntry], resolve: @escaping (LibraryEntry) -> URL?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            clear()
            return
        }
        generation += 1
        let mine = generation
        query = text
        found = TermSearch.run(text, over: entries, resolve: resolve)

        guard found.unread > 0 else { return }
        reading = true
        let urls = entries.compactMap(resolve)
        Task.detached(priority: .utility) {
            for url in urls where IndexTermsStore.cached(for: url) == nil {
                guard let source = SearchIndexStore.open(url) else { continue }
                IndexTermsStore.terms(for: url, source: source)
                await MainActor.run { [weak self] in
                    guard let self, self.generation == mine else { return }
                    // 1 冊読むたびに引き直す。全部揃うまで待たせない。
                    self.found = TermSearch.run(text, over: entries, resolve: resolve)
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == mine else { return }
                self.reading = false
            }
        }
    }

    /// 進み具合の言葉。**索引を持たない本の数を隠さない。**
    ///
    /// 「当たらない」のと「索引が無い」のとでは、人が次にすることが違う。
    var status: String {
        guard !query.isEmpty else { return "" }
        if reading { return "索引を読んでいます（残り \(found.unread) 冊）" }
        var notes: [String] = []
        if found.withoutIndex > 0 { notes.append("索引の無い本 \(found.withoutIndex) 冊") }
        if found.unread > 0 { notes.append("未読み込み \(found.unread) 冊") }
        return notes.joined(separator: " / ")
    }
}
