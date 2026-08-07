import AppKit
import Combine
import PDFKit

/// PDF のナビゲータ。描画、拡縮、選択、リンクは PDFKit に任せる。
@MainActor
final class PDFNavigatorController: NSObject, ObservableObject, PDFViewDelegate {
    let document: BookDocument
    let settings: ReaderSettings
    let pdfView = ReaderPDFView()

    @Published private(set) var locator: Locator
    @Published private(set) var pageLabel: String = ""

    var onOpenInNewWindow: ((Locator) -> Void)?
    var onNavigated: ((Locator) -> Void)?
    var onStatus: ((String?) -> Void)?

    /// いま強調している当たり。紙面は文字を持たない絵なので、当たりの矩形を上から塗る。
    var mark: SearchMark? { didSet { applyMark() } }

    private var observers: [NSObjectProtocol] = []

    var pageCount: Int { document.pdfDocument?.pageCount ?? 0 }

    init(document: BookDocument, settings: ReaderSettings, start: Locator?) {
        self.document = document
        self.settings = settings
        locator = start ?? Locator(page: 0, progression: 0)
        super.init()

        pdfView.document = document.pdfDocument
        pdfView.autoScales = true
        pdfView.delegate = self
        applyLayout()
        applyTheme()

        // 左右はページ移動。並べ方を変えても操作の意味は変えない。
        pdfView.onHorizontalArrow = { [weak self] side in
            guard let self else { return }
            if side == .right { self.goNextPage() } else { self.goPrevPage() }
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncLocatorFromView() }
        })

        if let page = start?.page {
            goToPage(page, pushHistory: false)
        }
        syncLocatorFromView()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 移動

    func goToPage(_ index: Int, pushHistory: Bool = true) {
        guard let doc = document.pdfDocument, index >= 0, index < doc.pageCount,
              let page = doc.page(at: index) else { return }
        if pushHistory { onNavigated?(locator) }
        pdfView.go(to: page)
        syncLocatorFromView()
    }

    func reveal(_ target: Locator) {
        if let selection = target.text, !selection.isEmpty, let doc = document.pdfDocument {
            let matches = doc.findString(selection, withOptions: [.caseInsensitive])
            if let page = target.page, let match = matches.first(where: { sel in
                sel.pages.first.map { doc.index(for: $0) } == page
            }) {
                onNavigated?(locator)
                pdfView.setCurrentSelection(match, animate: true)
                pdfView.scrollSelectionToVisible(nil)
                syncLocatorFromView()
                return
            }
        }
        if let page = target.page { goToPage(page) }
    }

    // MARK: - 当たりの強調

    /// 当たりのあったページで、その語が出ているところを塗る。
    ///
    /// PDFKit の選択（setCurrentSelection）とは別に持つ。
    /// あちらは人が文字を選び直すと消えるが、こちらは検索をやめるまで残ってほしい。
    private func applyMark() {
        guard let mark, !mark.query.isEmpty, let page = mark.target.page,
              let doc = document.pdfDocument, let target = doc.page(at: page) else {
            pdfView.highlightedSelections = nil
            return
        }
        let found = doc.findString(mark.query, withOptions: DocumentSearch.options)
            .filter { $0.pages.first == target }
        for selection in found { selection.color = .systemYellow }
        pdfView.highlightedSelections = found.isEmpty ? nil : found
    }

    func goNextPage() { pdfView.canGoToNextPage ? pdfView.goToNextPage(nil) : () }
    func goPrevPage() { pdfView.canGoToPreviousPage ? pdfView.goToPreviousPage(nil) : () }

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    func zoomToFit() {
        pdfView.autoScales = true
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
    }

    /// いま選んでいる本文。web 側と形を揃える（あちらは一往復かかる）。
    func selectedText(_ hand: @escaping (String?) -> Void) {
        hand(pdfView.currentSelection?.string)
    }

    func copySelection() {
        guard let text = pdfView.currentSelection?.string, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func applyTheme() {
        pdfView.appearance = settings.theme.appearance
        pdfView.backgroundColor = NSColor(hexString: settings.theme.background) ?? .windowBackgroundColor
    }

    func applyLayout() {
        switch settings.pageLayout {
        case .continuousScroll:
            pdfView.displayMode = .singlePageContinuous
        case .singlePage:
            pdfView.displayMode = .singlePage
        case .spread:
            pdfView.displayMode = .twoUp
            pdfView.displaysAsBook = true   // 表紙を単独で見せる
        }
        pdfView.displayDirection = .vertical
    }

    private func syncLocatorFromView() {
        guard let doc = document.pdfDocument, let page = pdfView.currentPage else { return }
        let index = doc.index(for: page)
        locator.page = index
        locator.progression = doc.pageCount > 1 ? Double(index) / Double(doc.pageCount - 1) : 0
        locator.title = page.label.map { "p.\($0)" }
        pageLabel = "\(index + 1) / \(doc.pageCount)"
    }

    // MARK: - PDFViewDelegate

    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        // 外部 URL は OS のブラウザで開く。
        NSWorkspace.shared.open(url)
    }
}

/// 左右キーをページ移動として扱う PDFView。
/// 既定では横スクロールに使われてしまい、EPUB 側と操作の意味が食い違うため。
final class ReaderPDFView: PDFView {
    enum Side { case left, right }

    var onHorizontalArrow: ((Side) -> Void)?

    override func keyDown(with event: NSEvent) {
        let plain = !event.modifierFlags.intersects([.command, .option, .control])
        if plain, let handler = onHorizontalArrow, let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSRightArrowFunctionKey: handler(.right); return
            case NSLeftArrowFunctionKey: handler(.left); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

private extension NSEvent.ModifierFlags {
    func intersects(_ other: NSEvent.ModifierFlags) -> Bool {
        !intersection(other).isEmpty
    }
}
