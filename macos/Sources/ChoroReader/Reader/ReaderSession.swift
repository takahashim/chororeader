import Combine
import Foundation
import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case toc, thumbnails, search, related, bookmarks
    var id: String { rawValue }

    var label: String {
        switch self {
        case .toc: return "目次"
        case .thumbnails: return "ページ"
        case .search: return "検索"
        case .related: return "関連"
        case .bookmarks: return "しおり"
        }
    }
    var systemImage: String {
        switch self {
        case .toc: return "list.bullet.indent"
        case .thumbnails: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        case .related: return "point.3.connected.trianglepath.dotted"
        case .bookmarks: return "bookmark"
        }
    }
}

@MainActor
final class ReaderSession: ObservableObject {
    let document: BookDocument
    let settings: ReaderSettings
    let web: WebNavigatorController?
    let pdf: PDFNavigatorController?
    let fixed: FixedLayoutNavigatorController?

    @Published var backStack: [Locator] = []
    @Published var forwardStack: [Locator] = []
    @Published var sidebarTab: SidebarTab = .toc
    @Published var searchQuery = ""
    @Published var searchResults: [SearchResult] = []
    /// 検索結果から飛んだ先で強調する当たり。引き直すか、検索をやめると消える。
    @Published var mark: SearchMark? { didSet { web?.mark = mark; pdf?.mark = mark } }
    /// いまの一覧を出した語。欄の文字は引いたあとにも書き換わるので、別に覚えておく。
    private(set) var searchedQuery = ""
    @Published var isSearching = false
    @Published var related: [RelatedPassage] = []
    @Published var relatedReason: String?
    /// 種にした本文。何に対する結果なのかを画面に出すために持つ。
    @Published var relatedSeed: String?
    @Published var relatedRunning = false
    @Published var searchTruncated = false
    @Published var status: String?

    /// ⌘クリックなどで別ウィンドウを開く要求。ビュー側で openWindow に繋ぐ。
    /// 検索結果から開くときは、開いた先でも同じ当たりを囲めるように印を添える。
    var openInNewWindow: ((Locator, SearchMark?) -> Void)?

    private(set) lazy var thumbnails: ThumbnailProvider? = ThumbnailProvider.make(for: self)

    private var cancellables: Set<AnyCancellable> = []
    private let pdfSearcher = PDFSearcher()
    private var statusClearWorkItem: DispatchWorkItem?

    var locator: Locator { web?.locator ?? pdf?.locator ?? fixed?.locator ?? Locator() }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var isReflowable: Bool { web != nil }
    var isPaged: Bool { pdf != nil || fixed != nil }
    var availableTabs: [SidebarTab] {
        SidebarTab.allCases.filter {
            switch $0 {
            case .thumbnails: return thumbnails != nil
            // 意味の層を入にしていなければ、そんな考え方があること自体を見せない。
            case .related: return SemanticIndexBuilder.shared.enabled
            default: return true
            }
        }
    }

    init(document: BookDocument, startLocator: Locator?) {
        self.document = document
        settings = ReaderSettings.shared

        let start = startLocator ?? LibraryStore.shared.lastLocator(for: document.id)
        switch document.source {
        case .epub where document.format == .fixedEPUB:
            web = nil
            pdf = nil
            fixed = FixedLayoutNavigatorController(document: document, settings: settings, start: start)
        case .epub:
            web = WebNavigatorController(document: document, settings: settings, start: start)
            pdf = nil
            fixed = nil
        case .pdf:
            web = nil
            pdf = PDFNavigatorController(document: document, settings: settings, start: start)
            fixed = nil
        }

        wire()
    }

    private func wire() {
        web?.onNavigated = { [weak self] from in self?.pushHistory(from) }
        pdf?.onNavigated = { [weak self] from in self?.pushHistory(from) }
        fixed?.onNavigated = { [weak self] from in self?.pushHistory(from) }
        web?.onOpenInNewWindow = { [weak self] target in self?.openInNewWindow?(target, nil) }
        pdf?.onOpenInNewWindow = { [weak self] target in self?.openInNewWindow?(target, nil) }
        fixed?.onOpenInNewWindow = { [weak self] target in self?.openInNewWindow?(target, nil) }
        web?.onStatus = { [weak self] message in self?.showStatus(message) }
        pdf?.onStatus = { [weak self] message in self?.showStatus(message) }
        fixed?.onStatus = { [weak self] message in self?.showStatus(message) }

        let publisher: AnyPublisher<Locator, Never>
        if let web {
            publisher = web.$locator.eraseToAnyPublisher()
            web.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        } else if let pdf {
            publisher = pdf.$locator.eraseToAnyPublisher()
            pdf.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        } else if let fixed {
            publisher = fixed.$locator.eraseToAnyPublisher()
            fixed.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        } else {
            return
        }

        publisher
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] locator in
                guard let self else { return }
                LibraryStore.shared.savePosition(locator, for: self.document.id)
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.pdf?.applyTheme()
                self?.pdf?.applyLayout()
            }
            .store(in: &cancellables)

    }

    // MARK: - 関連箇所

    /// **選んだところを種にする。**
    ///
    /// 場所が変わるたびに勝手に引き直す形にしていたが、常時出ている情報は
    /// 当たらなければ視界の邪魔にしかならず、渡る理由も立たなかった。
    /// 「ここに近いものを知りたい」と思った時にだけ引く。
    ///
    /// 推論を 1 回だけ回すので裏の筋でやる。**選んだ本文は端末の外へ出ない。**
    func findRelated() {
        guard SemanticIndexBuilder.shared.enabled else { return }
        relatedSeed = nil
        selectedText { [weak self] selection in
            guard let self else { return }
            let text = (selection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 10 else {
                self.related = []
                self.relatedReason = "本文を選んでから探してください（10 字以上）"
                return
            }
            self.run(seed: text)
        }
    }

    private func selectedText(_ hand: @escaping (String?) -> Void) {
        if let web { web.selectedText(hand) } else if let pdf { pdf.selectedText(hand) } else { hand(nil) }
    }

    private func run(seed text: String) {
        guard #available(macOS 15, *), EmbeddingModelStore.installed() != nil else {
            relatedReason = "意味の層を使えません"
            return
        }
        relatedSeed = text
        relatedRunning = true
        relatedReason = nil
        let mine = document.id
        Task.detached(priority: .userInitiated) {
            // 本文どうしの比較なので、種も文書として埋め込む（両側を揃える）。
            let vector = try? EmbedderHolder.shared.use { try $0.embed(text, as: .document).vector }
            await MainActor.run { [weak self] in
                guard let self, self.relatedSeed == text else { return }
                self.relatedRunning = false
                guard let vector = vector ?? nil else {
                    self.relatedReason = "うまく引けませんでした"
                    return
                }
                let made = SemanticFinder.search(vector, over: LibraryStore.shared.entries,
                                                 excluding: mine, limits: .related) {
                    LibraryStore.shared.resolveURL(for: $0)
                }
                self.related = made.passages
                self.relatedReason = made.passages.isEmpty
                    ? "近い箇所は見つかりませんでした（未読み込み \(made.missing) 冊）"
                    : nil
            }
        }
    }

    func clearRelated() {
        related = []
        relatedSeed = nil
        relatedReason = nil
    }

    // MARK: - 移動

    func go(to target: Locator) {
        if let web {
            web.reveal(target)
        } else if let pdf {
            pdf.reveal(target)
        } else if let fixed {
            fixed.reveal(target)
        }
    }

    func go(to result: SearchResult) {
        mark = markFor(result)
        go(to: result.locator)
    }

    func openInNewWindow(_ target: Locator) {
        openInNewWindow?(target, nil)
    }

    func openInNewWindow(_ result: SearchResult) {
        openInNewWindow?(result.locator, markFor(result))
    }

    private func markFor(_ result: SearchResult) -> SearchMark {
        SearchMark(query: searchedQuery, nth: result.nth, target: result.locator)
    }

    private func pushHistory(_ from: Locator) {
        backStack.append(from)
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(locator)
        navigateWithoutHistory(target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(locator)
        navigateWithoutHistory(target)
    }

    private func navigateWithoutHistory(_ target: Locator) {
        if let web {
            let saved = web.onNavigated
            web.onNavigated = nil
            web.reveal(target)
            web.onNavigated = saved
        } else if let pdf {
            let saved = pdf.onNavigated
            pdf.onNavigated = nil
            pdf.reveal(target)
            pdf.onNavigated = saved
        } else if let fixed {
            let saved = fixed.onNavigated
            fixed.onNavigated = nil
            fixed.reveal(target)
            fixed.onNavigated = saved
        }
    }

    // MARK: - 検索

    func runSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        mark = nil
        searchedQuery = query
        guard query.count >= 1 else {
            searchResults = []
            searchTruncated = false
            return
        }
        isSearching = true
        searchTruncated = false
        sidebarTab = .search

        if let resources = document.resources, let publication = document.publication {
            DocumentSearch.searchEPUB(resources: resources, publication: publication, query: query) { [weak self] outcome in
                guard let self else { return }
                self.searchResults = outcome.results
                self.searchTruncated = outcome.truncated
                self.isSearching = false
            }
        } else if let pdfDoc = document.pdfDocument {
            pdfSearcher.search(document: pdfDoc, query: query) { [weak self] results, truncated in
                guard let self else { return }
                self.searchResults = results
                self.searchTruncated = truncated
                self.isSearching = false
            }
        } else {
            isSearching = false
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchedQuery = ""
        searchResults = []
        searchTruncated = false
        mark = nil
    }

    var searchAvailable: Bool {
        if document.format == .fixedEPUB { return false }
        if let pdfDoc = document.pdfDocument {
            return (pdfDoc.page(at: 0)?.string?.isEmpty == false)
        }
        return true
    }

    // MARK: - しおり

    func addBookmark() {
        let name = locator.title ?? document.title
        document.addBookmark(locator, name: name)
        showStatus("しおりを追加しました")
    }

    // MARK: - 状態表示

    func showStatus(_ message: String?) {
        status = message
        statusClearWorkItem?.cancel()
        guard message != nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.status = nil }
        statusClearWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
    }

    // MARK: - 位置の表示

    var positionLabel: String {
        if let pdf { return pdf.pageLabel }
        if let fixed { return fixed.pageLabel }
        guard let web, let index = web.currentIndex,
              let total = document.publication?.readingOrder.count else { return "" }
        return "\(index + 1) / \(total) 章  \(Int(web.locator.progression * 100))%"
    }
}
