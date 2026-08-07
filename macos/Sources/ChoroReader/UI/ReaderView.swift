import PDFKit
import SwiftUI
import WebKit

struct WebNavigatorView: NSViewRepresentable {
    let controller: WebNavigatorController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PDFNavigatorView: NSViewRepresentable {
    let controller: PDFNavigatorController
    func makeNSView(context: Context) -> PDFView { controller.pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

struct FixedLayoutNavigatorView: NSViewRepresentable {
    let controller: FixedLayoutNavigatorController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ReaderView: View {
    @ObservedObject var session: ReaderSession
    @ObservedObject private var settings = ReaderSettings.shared
    @State private var sidebarVisible: NavigationSplitViewVisibility = .automatic
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showProperties = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisible) {
            SidebarView(session: session, searchFocused: $searchFocused)
                .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 420)
        } detail: {
            VStack(spacing: 0) {
                content
                Divider()
                footer
            }
        }
        .navigationTitle(session.document.title)
        .navigationSubtitle(session.locator.title ?? "")
        // サイドバーとツールバーも本文のテーマに合わせる。
        .preferredColorScheme(settings.theme == .dark ? .dark : .light)
        .focusedSceneValue(\.readerSession, session)
        .toolbar { toolbarContent }
        .onAppear {
            // 書棚の横断検索から語句を持って開かれたときは、その一覧を出した状態で始める。
            if !session.searchQuery.isEmpty, session.sidebarTab == .search {
                sidebarVisible = .all
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .choroFocusSearch)) { _ in
            session.sidebarTab = .search
            sidebarVisible = .all
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .choroToggleSidebar)) { _ in
            sidebarVisible = (sidebarVisible == .detailOnly) ? .all : .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: .choroShowDiagnostics)) { _ in
            showDiagnostics = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .choroShowProperties)) { _ in
            showProperties = true
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(session: session)
        }
        .sheet(isPresented: $showProperties) {
            PropertiesView(subjects: [.opened(session)])
        }
    }

    @ViewBuilder
    private var content: some View {
        if let web = session.web {
            WebNavigatorView(controller: web)
                .popover(item: Binding(get: { web.preview }, set: { web.preview = $0 }),
                         attachmentAnchor: .rect(.rect(web.preview?.anchor ?? .zero)),
                         arrowEdge: .bottom) { request in
                    LinkPreviewView(controller: web, request: request, session: session)
                }
        } else if let pdf = session.pdf {
            PDFNavigatorView(controller: pdf)
        } else if let fixed = session.fixed {
            FixedLayoutNavigatorView(controller: fixed)
        } else {
            Text("表示できません")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let status = session.status {
                Text(status)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            if let web = session.web {
                Button { web.goPrevChapter() } label: { Label("前の章", systemImage: "chevron.left") }
                    .disabled(!web.canGoPrevChapter)
                Button { web.goNextChapter() } label: { Label("次の章", systemImage: "chevron.right") }
                    .disabled(!web.canGoNextChapter)
            } else if let fixed = session.fixed {
                Button { fixed.goPrevPage() } label: { Label("前のページ", systemImage: "chevron.left") }
                    .disabled(fixed.currentPage <= 0)
                Button { fixed.goNextPage() } label: { Label("次のページ", systemImage: "chevron.right") }
                    .disabled(fixed.currentPage >= fixed.pageCount - 1)
            }
            Text(session.positionLabel)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(.default, value: session.status)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { session.goBack() } label: { Label("戻る", systemImage: "chevron.left") }
                .disabled(!session.canGoBack)
            Button { session.goForward() } label: { Label("進む", systemImage: "chevron.right") }
                .disabled(!session.canGoForward)
        }

        ToolbarItemGroup {
            Button { session.addBookmark() } label: { Label("しおり", systemImage: "bookmark") }

            // 何ページの本か、文字を持つか。読む前に知りたいことが多いので、
            // メニュー（⌘I）だけでなく道具帯からも出せるようにする。
            Button { showProperties = true } label: { Label("情報", systemImage: "info.circle") }
                .help("この書籍の情報（⌘I）")

            Button { showSettings.toggle() } label: { Label("表示設定", systemImage: "textformat.size") }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    DisplaySettingsView(reflowable: session.isReflowable, paged: session.isPaged)
                        .frame(width: 300)
                        .padding(16)
                }
        }
    }
}

struct DisplaySettingsView: View {
    @ObservedObject private var settings = ReaderSettings.shared
    let reflowable: Bool
    let paged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("テーマ", selection: $settings.theme) {
                ForEach(ReaderTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if reflowable {
                labeled("文字サイズ", value: "\(Int(settings.fontSizePercent))%") {
                    Slider(value: $settings.fontSizePercent, in: 70 ... 220, step: 5)
                }
                labeled("行間", value: String(format: "%.1f", settings.lineHeight)) {
                    Slider(value: $settings.lineHeight, in: 1.2 ... 2.6, step: 0.1)
                }
                labeled("本文幅", value: settings.maxWidthEm >= 100 ? "制限なし" : "\(Int(settings.maxWidthEm))em") {
                    Slider(value: $settings.maxWidthEm, in: 28 ... 100, step: 2)
                }
                Toggle("コードを折り返す", isOn: $settings.codeWrap)
                Toggle("出版社のスタイルを優先", isOn: $settings.publisherStyle)
            } else if paged {
                Picker("並べ方", selection: $settings.pageLayout) {
                    ForEach(PageLayoutMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("ページの収め方", selection: $settings.pageFit) {
                    ForEach(PageFit.allCases) { Text($0.label).tag($0) }
                }
                Text("並べ方を変えても、左右キーで前後のページへ移動する操作は変わりません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func labeled(_ title: String, value: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            control()
        }
    }
}

extension Notification.Name {
    static let choroFocusSearch = Notification.Name("choroFocusSearch")
    /// 書棚の横断検索へ入る合図。
    static let choroFocusLibrarySearch = Notification.Name("choroFocusLibrarySearch")
    static let choroToggleSidebar = Notification.Name("choroToggleSidebar")
    static let choroShowDiagnostics = Notification.Name("choroShowDiagnostics")
    static let choroShowProperties = Notification.Name("choroShowProperties")
}

struct ReaderSessionFocusKey: FocusedValueKey {
    typealias Value = ReaderSession
}

extension FocusedValues {
    var readerSession: ReaderSession? {
        get { self[ReaderSessionFocusKey.self] }
        set { self[ReaderSessionFocusKey.self] = newValue }
    }
}
