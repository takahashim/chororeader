import Combine
import Foundation
import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case toc, thumbnails, search, bookmarks
    var id: String { rawValue }

    var label: String {
        switch self {
        case .toc: return "目次"
        case .thumbnails: return "ページ"
        case .search: return "検索"
        case .bookmarks: return "しおり"
        }
    }
    var systemImage: String {
        switch self {
        case .toc: return "list.bullet.indent"
        case .thumbnails: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        case .bookmarks: return "bookmark"
        }
    }
}

/// 1 ウィンドウにつき 1 つ。位置と履歴と検索状態を持つ。
/// 書籍そのもの（BookDocument）はウィンドウ間で共有する。
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
    @Published var isSearching = false
    @Published var searchTruncated = false
    @Published var status: String?

    /// ⌘クリックなどで別ウィンドウを開く要求。ビュー側で openWindow に繋ぐ。
    var openInNewWindow: ((Locator) -> Void)?

    /// ページのサムネイル。画像ページの書籍と PDF でだけ用意する。
    private(set) lazy var thumbnails: ThumbnailProvider? = ThumbnailProvider.make(for: self)

    private var cancellables: Set<AnyCancellable> = []
    private let pdfSearcher = PDFSearcher()
    private var statusClearWorkItem: DispatchWorkItem?

    var locator: Locator { web?.locator ?? pdf?.locator ?? fixed?.locator ?? Locator() }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    /// 文字サイズなど、リフローを前提とした設定が効くかどうか。
    var isReflowable: Bool { web != nil }
    /// ページ単位で並べる形式かどうか。並べ方とフィットの設定はこちらで使う。
    var isPaged: Bool { pdf != nil || fixed != nil }
    /// サイドバーに出すタブ。形式によって使えないものは並べない。
    var availableTabs: [SidebarTab] {
        SidebarTab.allCases.filter { $0 != .thumbnails || thumbnails != nil }
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
        web?.onOpenInNewWindow = { [weak self] target in self?.openInNewWindow?(target) }
        pdf?.onOpenInNewWindow = { [weak self] target in self?.openInNewWindow?(target) }
        fixed?.onOpenInNewWindow = { [weak self] target in self?.openInNewWindow?(target) }
        web?.onStatus = { [weak self] message in self?.showStatus(message) }
        pdf?.onStatus = { [weak self] message in self?.showStatus(message) }
        fixed?.onStatus = { [weak self] message in self?.showStatus(message) }

        // 位置の保存。スクロール中に書き込み続けないよう間引く。
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

    func openInNewWindow(_ target: Locator) {
        openInNewWindow?(target)
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

    var searchAvailable: Bool {
        if document.format == .fixedEPUB { return false }
        if let pdfDoc = document.pdfDocument {
            // テキスト層のない PDF は検索できない。その旨を UI に出す。
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
