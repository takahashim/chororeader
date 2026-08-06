import AppKit
import SwiftUI

struct BookRoute: Codable, Hashable {
    var path: String
    var locator: Locator?
    /// 開いた直後に引かせる語句。書棚の横断検索から「この本の全件」へ渡るときに使う。
    var query: String?
}

/// Finder やメニューからのファイル要求を、開いているウィンドウのどれか 1 つが処理する。
@MainActor
final class OpenRequests {
    static let shared = OpenRequests()
    private var handler: ((URL) -> Void)?
    private var queue: [URL] = []

    func setHandler(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        flush()
    }

    func request(_ url: URL) {
        queue.append(url)
        flush()
    }

    private func flush() {
        guard let handler else { return }
        let pending = queue
        queue = []
        pending.forEach(handler)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            urls.forEach { OpenRequests.shared.request($0) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct ChoroReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("書棚", id: "library") {
            LibraryView()
        }
        .defaultSize(width: 560, height: 420)
        .commands { AppCommands() }

        WindowGroup(for: BookRoute.self) { $route in
            if let route {
                ReaderWindowView(route: route)
            }
        }
        .defaultSize(width: 1000, height: 860)
    }
}

struct ReaderWindowView: View {
    let route: BookRoute

    @Environment(\.openWindow) private var openWindow
    @State private var session: ReaderSession?
    @State private var failure: BookDocument.OpenError?
    @State private var otherFailure: String?

    var body: some View {
        Group {
            if let session {
                ReaderView(session: session)
            } else if let failure {
                ErrorView(title: failure.errorDescription ?? "開けませんでした",
                          detail: failure.diagnosticDetail,
                          path: route.path)
            } else if let otherFailure {
                ErrorView(title: "開けませんでした", detail: otherFailure, path: route.path)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            OpenRequests.shared.setHandler { url in
                openWindow(value: BookRoute(path: url.path, locator: nil, query: nil))
            }
            if session == nil { load() }
        }
        .onDisappear {
            if let session { DocumentRegistry.shared.release(session.document) }
        }
    }

    private func load() {
        let url = URL(fileURLWithPath: route.path)
        do {
            let document = try DocumentRegistry.shared.open(url: url)
            DocumentRegistry.shared.retain(document)
            let newSession = ReaderSession(document: document, startLocator: route.locator)
            if let query = route.query, !query.isEmpty {
                newSession.searchQuery = query
                newSession.runSearch()
            }
            newSession.openInNewWindow = { locator in
                openWindow(value: BookRoute(path: route.path, locator: locator, query: nil))
            }
            session = newSession
        } catch let error as BookDocument.OpenError {
            failure = error
        } catch {
            otherFailure = String(describing: error)
        }
    }
}

struct ErrorView: View {
    let title: String
    let detail: String
    let path: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(title).font(.headline)
            Text((path as NSString).lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("診断情報をコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(title)\n\(path)\n\(detail)", forType: .string)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.readerSession) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("開く…") {
                for url in FileOpener.runOpenPanel() { OpenRequests.shared.request(url) }
            }
            .keyboardShortcut("o", modifiers: .command)

            // 書籍を 1 冊も持たないマシンでも、読み方と機能を確かめられるようにする。
            // 表示の経路が形式ごとに別なので、3 形式そろえてある。
            Menu("サンプルを開く") {
                Button("リフロー型 EPUB") { Samples.open("sample-reflowable", "epub") }
                Button("固定レイアウト EPUB") { Samples.open("sample-fixed", "epub") }
                Button("PDF") { Samples.open("sample", "pdf") }
            }

            // 離れた 2 か所を並べて読むための最短経路。
            // 目次や検索から開くのではなく、いま見ている場所をそのまま複製する。
            Button("この場所を新しいウィンドウで開く") {
                if let session { session.openInNewWindow(session.locator) }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(session == nil)

            Divider()

            Button("書棚") { openWindow(id: "library") }
                .keyboardShortcut("l", modifiers: .command)

            // 読書中の窓からも蔵書を引けるようにする。⌘F は開いている本の中を引く。
            Button("蔵書を検索…") {
                openWindow(id: "library")
                NotificationCenter.default.post(name: .choroFocusLibrarySearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .textEditing) {
            Button("検索") { NotificationCenter.default.post(name: .choroFocusSearch, object: nil) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(session == nil)
        }

        CommandMenu("移動") {
            Button("戻る") { session?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(session?.canGoBack != true)
            Button("進む") { session?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(session?.canGoForward != true)
            Divider()
            Button("次の章／ページ") {
                if let web = session?.web { web.goNextChapter() }
                else if let fixed = session?.fixed { fixed.goNextPage() }
                else { session?.pdf?.goNextPage() }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(session == nil)
            Button("前の章／ページ") {
                if let web = session?.web { web.goPrevChapter() }
                else if let fixed = session?.fixed { fixed.goPrevPage() }
                else { session?.pdf?.goPrevPage() }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(session == nil)
            Divider()
            Button("しおりを追加") { session?.addBookmark() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session == nil)
        }

        CommandGroup(after: .help) {
            Button("この書籍の診断…") {
                NotificationCenter.default.post(name: .choroShowDiagnostics, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(session == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("サイドバーの表示を切り替え") {
                NotificationCenter.default.post(name: .choroToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button("大きくする") { adjustScale(+1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(session == nil)
            Button("小さくする") { adjustScale(-1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(session == nil)
            Button("標準の大きさ") { resetScale() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(session == nil)
        }
    }

    private func adjustScale(_ direction: Int) {
        guard let session else { return }
        if session.isReflowable {
            let settings = ReaderSettings.shared
            settings.fontSizePercent = min(220, max(70, settings.fontSizePercent + Double(direction) * 10))
        } else if direction > 0 {
            session.pdf?.zoomIn()
            session.fixed?.zoomIn()
        } else {
            session.pdf?.zoomOut()
            session.fixed?.zoomOut()
        }
    }

    private func resetScale() {
        guard let session else { return }
        if session.isReflowable {
            ReaderSettings.shared.fontSizePercent = 100
        } else {
            session.pdf?.zoomToFit()
            session.fixed?.zoomToFit()
        }
    }
}
