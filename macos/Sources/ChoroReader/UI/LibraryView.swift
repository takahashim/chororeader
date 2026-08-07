import SwiftUI
import UniformTypeIdentifiers

/// 情報を見せる相手。sheet(item:) が同一性を要るので包む。
struct ShownFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

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
    /// 情報を見せている書籍。書棚では開いていない書籍のことも尋ねられる。
    @State private var showing: ShownFile?
    @StateObject private var importing = FolderImport()
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if importing.running || importing.summary != nil {
                importBar
                Divider()
            }
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
                Menu {
                    Button("ファイルを開く…") {
                        for url in FileOpener.runOpenPanel() { open(url) }
                    }
                    Button("フォルダを取り込む…") {
                        if let folder = FileOpener.runFolderPanel() {
                            importing.run(folder, into: store)
                        }
                    }
                } label: {
                    Label("加える", systemImage: "plus")
                }
                .disabled(importing.running)
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
        // 書棚では開いていない書籍のことも尋ねられる。開かずにファイルから読む。
        .sheet(item: $showing) { shown in
            PropertiesView(subject: .file(shown.url))
        }
    }

    /// 取り込みの進み具合。終わったら結果をしばらく出しておく。
    private var importBar: some View {
        HStack(spacing: 8) {
            if importing.running {
                ProgressView(value: Double(importing.done),
                             total: Double(max(importing.total, 1)))
                    .frame(width: 120)
                Text("\(importing.done) / \(importing.total) 冊")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(importing.current)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("やめる") { importing.cancel() }
                    .font(.system(size: 11))
            } else if let summary = importing.summary {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    importing.summary = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            }
            if search.running || !search.books.isEmpty {
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
        if search.running { return "\(search.searched) / \(search.total) 冊" }
        return "\(search.books.count) 冊 / \(search.hitCount) 件"
    }

    private func runSearch() {
        search.run(queryText, over: store.recent) { store.resolveURL(for: $0) }
    }

    private var results: some View {
        Group {
            if search.books.isEmpty && !search.running {
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
                    ForEach(search.books) { book in
                        Section(header: header(for: book)) {
                            ForEach(book.hits) { hit in
                                HitRow(hit: hit)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { openHit(hit, in: book) }
                                    .contextMenu {
                                        Button("新しいウィンドウで開く") { openHit(hit, in: book) }
                                        Button("情報を見る") { showing = ShownFile(url: URL(fileURLWithPath: book.path)) }
                                    }
                            }
                            // 打ち切った本は、その本を開いて全件を見る道を出す。
                            if book.truncated {
                                Button {
                                    openAll(book)
                                } label: {
                                    Label("この本の中をすべて見る", systemImage: "arrow.up.forward.square")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func header(for book: LibraryBookHits) -> some View {
        HStack(spacing: 6) {
            Text(book.title)
            Text(book.truncated ? "\(book.hits.count) 件以上" : "\(book.hits.count) 件")
                .foregroundStyle(.secondary)
        }
    }

    private func openHit(_ hit: LibraryHit, in book: LibraryBookHits) {
        // 開いた先でも、押した当たりを囲む。どれが引っ掛かった語かを探し直さずに済ませる。
        let mark = SearchMark(query: search.query, nth: hit.result.nth, target: hit.result.locator)
        openWindow(value: BookRoute(path: book.path, locator: hit.result.locator,
                                    query: nil, mark: mark))
    }

    /// その本を開き、同じ語句で引いた一覧を出す。件数の上限は章内検索のもの（400 件）に上がる。
    private func openAll(_ book: LibraryBookHits) {
        openWindow(value: BookRoute(path: book.path, locator: nil, query: search.query))
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("EPUB か PDF をここにドロップしてください")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("ファイルを開く…") {
                    for url in FileOpener.runOpenPanel() { open(url) }
                }
                // 蔵書がフォルダに溜まっている人には、1 冊ずつ開かせない。
                Button("フォルダを取り込む…") {
                    if let folder = FileOpener.runFolderPanel() {
                        importing.run(folder, into: store)
                    }
                }
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
        Button("情報を見る") { showing = store.resolveURL(for: entry).map(ShownFile.init) }
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
        openWindow(value: BookRoute(path: url.path, locator: nil, query: nil))
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

    /// 取り込むフォルダを選ぶ。中の書籍は開かずに書棚へ加える。
    static func runFolderPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "書籍の入ったフォルダを選択してください（下の階層も探します）"
        panel.prompt = "取り込む"
        return panel.runModal() == .OK ? panel.urls.first : nil
    }
}

/// 当たり 1 件。1 件 1 行に収める。
///
/// 何十件も並ぶ一覧なので、行が折り返すと目で追えなくなる。
/// 章名を左に揃え、前後の文脈は 1 行に詰めて、当たった語だけを強める。
private struct HitRow: View {
    let hit: LibraryHit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(oneLine(hit.result.chapterTitle))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 132, alignment: .leading)

            if hit.result.isCode {
                Image(systemName: "curlybraces")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("コードブロックの中")
            }

            (Text(oneLine(hit.result.before)).foregroundStyle(.secondary)
                + Text(oneLine(hit.result.match)).bold()
                + Text(oneLine(hit.result.after)).foregroundStyle(.secondary))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    /// 改行と連なった空白を 1 つの空白に詰める。
    /// PDF の本文は行ごとに改行が入っており、そのまま出すと 1 件が何行にもなる。
    /// 端の空白は落とさない。落とすと英文で前後の語がくっつく。
    private func oneLine(_ text: String) -> String {
        var out = ""
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(character)
                lastWasSpace = false
            }
        }
        return out
    }
}
