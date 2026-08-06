import SwiftUI
import UniformTypeIdentifiers

/// 書棚の見せ方。表紙を並べるか、表で並べるか。
enum ShelfMode: String, CaseIterable {
    case cover
    case table

    var label: String { self == .cover ? "表紙" : "一覧" }
    var symbol: String { self == .cover ? "square.grid.2x2" : "list.bullet" }
}

struct LibraryView: View {
    @ObservedObject private var store = LibraryStore.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("shelfMode") private var mode: ShelfMode = .cover
    @State private var dropTargeted = false
    /// 表で並べるときの選択。contextMenu(forSelectionType:) はこれを前提にしている。
    @State private var selection: LibraryEntry.ID?
    @StateObject private var search = LibrarySearchModel()
    @State private var queryText = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            Group {
                if !search.query.isEmpty {
                    results
                } else if store.entries.isEmpty {
                    empty
                } else if mode == .cover {
                    covers
                } else {
                    table
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle("書棚")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("見せ方", selection: $mode) {
                    ForEach(ShelfMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem {
                Button {
                    for url in FileOpener.runOpenPanel() { open(url) }
                } label: {
                    Label("開く", systemImage: "plus")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { open(url) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
            }
        }
        .onAppear {
            OpenRequests.shared.setHandler { url in open(url) }
            // 引かれる前に索引をほどいておく。最初の検索を待たせないため。
            SearchIndexStore.warm(store.recent.compactMap { store.resolveURL(for: $0) })
        }
        .onReceive(NotificationCenter.default.publisher(for: .choroFocusLibrarySearch)) { _ in
            queryFocused = true
        }
    }

    // MARK: - 横断検索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            // 蔵書を丸ごと引くのは重いので、1 文字ごとには走らせず、確定してから走らせる。
            TextField("蔵書を検索（Return で実行）", text: $queryText)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onSubmit { runSearch() }
            if !search.query.isEmpty || !queryText.isEmpty {
                Button {
                    queryText = ""
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("検索をやめる")
            }
            if search.running {
                ProgressView().controlSize(.small)
                Text(progressLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var progressLabel: String {
        if let building = search.building { return "索引を作成中：\(building)" }
        return "\(search.searched) / \(search.total) 冊"
    }

    private func runSearch() {
        search.run(queryText, over: store.recent) { store.resolveURL(for: $0) }
    }

    private var results: some View {
        Group {
            if search.hits.isEmpty && !search.running {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("「\(search.query)」は見つかりませんでした")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedHits, id: \.title) { group in
                        Section(header: Text("\(group.title)（\(group.hits.count) 件）")) {
                            ForEach(group.hits) { hit in
                                HitRow(hit: hit, query: search.query)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { openHit(hit) }
                                    .contextMenu {
                                        Button("新しいウィンドウで開く") { openHit(hit) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    /// 本ごとにまとめる。並びは書棚と同じ（最近開いた順）。
    private var groupedHits: [(title: String, hits: [LibraryHit])] {
        var order: [BookID] = []
        var grouped: [BookID: [LibraryHit]] = [:]
        for hit in search.hits {
            if grouped[hit.bookID] == nil { order.append(hit.bookID) }
            grouped[hit.bookID, default: []].append(hit)
        }
        return order.map { (grouped[$0]!.first!.bookTitle, grouped[$0]!) }
    }

    private func openHit(_ hit: LibraryHit) {
        openWindow(value: BookRoute(path: hit.path, locator: hit.result.locator))
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("EPUB か PDF をここにドロップしてください")
                .foregroundStyle(.secondary)
            Button("ファイルを開く…") {
                for url in FileOpener.runOpenPanel() { open(url) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 表紙で並べる

    private var covers: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 176), spacing: 20)],
                      alignment: .leading, spacing: 24) {
                ForEach(store.recent) { entry in
                    CoverCard(entry: entry)
                        .onTapGesture { openEntry(entry) }
                        .contextMenu { menu(for: entry) }
                }
            }
            .padding(20)
        }
    }

    // MARK: - 表で並べる

    private var table: some View {
        Table(store.recent, selection: $selection) {
            TableColumn("") { entry in
                CoverThumb(entry: entry, height: 34)
            }
            .width(30)
            TableColumn("題名") { entry in
                Text(entry.title)
                    .foregroundStyle(entry.fileExists ? Color.primary : Color.secondary)
            }
            TableColumn("著者") { entry in Text(entry.displayAuthors) }
            TableColumn("形式") { entry in Text(label(for: entry.format)) }
                .width(60)
            TableColumn("読み進み") { entry in Text(progressLabel(entry)) }
                .width(80)
        }
        .contextMenu(forSelectionType: LibraryEntry.ID.self) { ids in
            if let id = ids.first, let entry = store.recent.first(where: { $0.id == id }) {
                menu(for: entry)
            }
        } primaryAction: { ids in
            if let id = ids.first, let entry = store.recent.first(where: { $0.id == id }) {
                openEntry(entry)
            }
        }
    }

    @ViewBuilder
    private func menu(for entry: LibraryEntry) -> some View {
        Button("新しいウィンドウで開く") { openEntry(entry) }
        Button("Finder で表示") {
            if let url = store.resolveURL(for: entry) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        Divider()
        Button("一覧から削除", role: .destructive) { store.remove(entry.id) }
    }

    private func label(for format: DocumentFormat) -> String {
        switch format {
        case .pdf: return "PDF"
        case .fixedEPUB, .reflowableEPUB: return "EPUB"
        case .markdown: return "Markdown"
        }
    }

    private func progressLabel(_ entry: LibraryEntry) -> String {
        guard let locator = entry.lastLocator else { return "" }
        if let page = locator.page { return "p.\(page + 1)" }
        return "\(Int(locator.progression * 100))%"
    }

    private func openEntry(_ entry: LibraryEntry) {
        guard let url = store.resolveURL(for: entry) else { return }
        open(url)
    }

    /// 選んだ本は読書のウィンドウに開く。書棚は残る。
    private func open(_ url: URL) {
        openWindow(value: BookRoute(path: url.path, locator: nil))
    }
}

// MARK: - 表紙

private struct CoverCard: View {
    let entry: LibraryEntry

    var body: some View {
        VStack(spacing: 6) {
            CoverThumb(entry: entry, height: 168)
            Text(entry.title)
                .font(.system(size: 12))
                .lineLimit(3)
                .multilineTextAlignment(.center)
            if !entry.authors.isEmpty {
                Text(entry.displayAuthors)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(entry.fileExists ? 1 : 0.45)
        .contentShape(Rectangle())
        .help(entry.path)
    }
}

private struct CoverThumb: View {
    let entry: LibraryEntry
    let height: CGFloat

    var body: some View {
        Group {
            if let name = entry.coverName, let image = CoverCache.image(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                blank
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
    }

    /// 表紙を取り出せない書籍もある。何も出さないより、形式が分かる枠を置く。
    private var blank: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.secondary.opacity(0.14))
            .aspectRatio(0.72, contentMode: .fit)
            .overlay {
                Image(systemName: entry.format == .pdf ? "doc.richtext" : "book")
                    .font(.system(size: height / 4))
                    .foregroundStyle(.secondary)
            }
    }
}

enum FileOpener {
    static func runOpenPanel() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.pdf]
        if let epub = UTType(filenameExtension: "epub") { types.append(epub) }
        panel.allowedContentTypes = types
        panel.message = "EPUB または PDF を選択してください"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// 当たり 1 件。章名と前後の文脈を出し、当たった語だけを強める。
private struct HitRow: View {
    let hit: LibraryHit
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(hit.result.chapterTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if hit.result.isCode {
                    Text("コード")
                        .font(.system(size: 10))
                        .padding(.horizontal, 4)
                        .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            (Text(hit.result.before).foregroundStyle(.secondary)
                + Text(hit.result.match).bold()
                + Text(hit.result.after).foregroundStyle(.secondary))
                .font(.system(size: 12))
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
