import SwiftUI
import UniformTypeIdentifiers

/// 情報を見せる相手。sheet(item:) が同一性を要るので包む。
/// 複数入れると、保存するたびに次へ進む流しになる。
struct ShownFile: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.path).joined(separator: "\u{0}") }

    init(url: URL) { urls = [url] }
    init(urls: [URL]) { self.urls = urls }
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
    @State private var showSemantic = false
    @AppStorage("shelfMode") private var mode: ShelfMode = .cover
    @State private var dropTargeted = false
    /// 選んでいる書籍。表でも表紙でも同じものを使う。
    ///
    /// 書類が紛れ込んだ書棚を掃除するには、1 冊ずつでは終わらない。
    /// 複数選べることと、まとめて外せることを対にする。
    @State private var selection: Set<LibraryEntry.ID> = []
    /// 外してよいか尋ねている最中の冊数。読書位置としおりも消えるので必ず尋ねる。
    @State private var confirmingRemoval = false
    @StateObject private var search = LibrarySearchModel()
    @StateObject private var semantic = SemanticSearchModel()
    @ObservedObject private var builder = SemanticIndexBuilder.shared
    /// 引き方。**混ぜない**（spec-local-ai.md 第 5.2 節）。
    /// 正確な検索には「当たり」があるが、意味の近さには無い。
    @State private var searchKind: SearchKind = .exact
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
            if !selection.isEmpty {
                selectionBar
                Divider()
            }
            Group {
                // **引き方ごとに見る問いが違う。** 語句側だけを見ていると、
                // 意味で引いても書棚の一覧が出たままになる。
                if !currentQuery.isEmpty {
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
            ToolbarItem {
                Button { showSemantic.toggle() } label: {
                    Label("意味の層", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .popover(isPresented: $showSemantic, arrowEdge: .bottom) {
                    SemanticSettingsView().frame(width: 340).padding(16)
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
        // 外すと読書位置としおりも消える。取り返しがつかないので必ず尋ねる。
        .confirmationDialog(removalQuestion, isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("\(selection.count) 冊を外す", role: .destructive) {
                store.remove(Set(selection))
                selection = []
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("書棚から外すだけで、ファイルは消えません。ただし読書位置としおりは失われます。")
        }
        // 書棚では開いていない書籍のことも尋ねられる。開かずにファイルから読む。
        .sheet(item: $showing) { shown in
            PropertiesView(subjects: shown.urls.map { .file($0) })
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

    /// 選んでいる冊数と、まとめてできること。
    ///
    /// 何冊選んだかは表の見た目だけでは数えられない。掃除の途中で
    /// 「いま何冊消そうとしているか」が分からないのは危ない。
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) 冊を選択中")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("すべて選択") { selection = Set(store.recent.map(\.id)) }
                .font(.system(size: 11))
                .keyboardShortcut("a", modifiers: .command)
            Button("選択を解除") { selection = [] }
                .font(.system(size: 11))
            Spacer()
            Button(role: .destructive) { askRemoval() } label: {
                Label("書棚から外す", systemImage: "trash")
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var removalQuestion: String {
        selection.count == 1
            ? "この書籍を書棚から外しますか？"
            : "選んだ \(selection.count) 冊を書棚から外しますか？"
    }

    /// 選んでいるものを外す。⌫ でも呼ぶ。
    private func askRemoval() {
        guard !selection.isEmpty else { return }
        confirmingRemoval = true
    }

    // MARK: - 横断検索

    private var searchBar: some View {
        HStack(spacing: 8) {
            if builder.enabled {
                Picker("", selection: $searchKind) {
                    ForEach(SearchKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: searchKind) { _, _ in
                    search.clear()
                    semantic.clear()
                    if !queryText.isEmpty { runSearch() }
                }
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            // 蔵書を丸ごと引くのは重いので、1 文字ごとには走らせず、確定してから走らせる。
            TextField(searchKind == .exact ? "蔵書を検索（Return で実行）"
                                           : "意味で探す（Return で実行）", text: $queryText)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onSubmit { runSearch() }
            if !search.query.isEmpty || !semantic.query.isEmpty || !queryText.isEmpty {
                Button {
                    queryText = ""
                    search.clear()
                    semantic.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("検索をやめる")
            }
            if search.running || semantic.running {
                ProgressView().controlSize(.small)
            }
            if !progressLabel.isEmpty {
                Text(progressLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// いま引いている問い。画面を切り替える判断に使う。
    private var currentQuery: String {
        searchKind == .semantic ? semantic.query : search.query
    }

    private var progressLabel: String {
        if searchKind == .semantic {
            if semantic.running { return "探しています" }
            guard !semantic.query.isEmpty else { return "" }
            // まだ読み込んでいない本があることを隠さない。
            // 「無かった」のか「見ていない」のかで、次にすることが変わる。
            let missing = semantic.missing > 0 ? "・未読み込み \(semantic.missing) 冊" : ""
            return "\(semantic.found.count) 件\(missing)"
        }
        if let building = search.building { return "索引を作成中：\(building)" }
        if search.running { return "\(search.searched) / \(search.total) 冊" }
        guard !search.query.isEmpty else { return "" }
        return "\(search.books.count) 冊 / \(search.hitCount) 件"
    }

    private func runSearch() {
        switch searchKind {
        case .exact:
            search.run(queryText, over: store.recent) { store.resolveURL(for: $0) }
        case .semantic:
            semantic.run(queryText, over: store.recent) { store.resolveURL(for: $0) }
        }
    }

    private var results: some View {
        Group {
            if searchKind == .semantic {
                semanticResults
            } else {
                exactResults
            }
        }
    }

    /// 意味で引いた結果。
    ///
    /// **当たりを囲めない。** 語が一致していないので、前後の文脈に印を付けられない。
    /// だから節の見出しと抜き書きを出し、どれくらい近いのかを数で添える。
    private var semanticResults: some View {
        Group {
            if let reason = semantic.reason {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(reason).foregroundStyle(.secondary)
                    if semantic.missing > 0 {
                        Button("残りを読み込む") {
                            builder.enqueue(store.entries.compactMap { store.resolveURL(for: $0) })
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(semantic.found) { passage in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(passage.book.displayTitle).font(.callout).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(String(format: "%.2f", passage.score))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        if !passage.unit.heading.isEmpty {
                            Text(passage.unit.heading).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(passage.unit.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        openWindow(value: BookRoute(path: passage.book.path,
                                                    locator: passage.unit.target, query: nil))
                    }
                }
            }
        }
    }

    private var exactResults: some View {
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
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selection.contains(entry.id)
                                      ? Color.accentColor.opacity(0.25) : Color.clear)
                                .padding(-6)
                        )
                        // ⌘クリックで選び、そのまま押せば開く。macOS の流儀に合わせる。
                        .gesture(TapGesture().modifiers(.command).onEnded {
                            if selection.contains(entry.id) { selection.remove(entry.id) }
                            else { selection.insert(entry.id) }
                        })
                        .onTapGesture { selection = []; openEntry(entry) }
                        .contextMenu {
                            menu(forSelected: selection.contains(entry.id) ? selection : [entry.id])
                        }
                }
            }
            .padding(20)
        }
        .onDeleteCommand(perform: askRemoval)
    }

    // MARK: - 表で並べる

    private var table: some View {
        Table(store.recent, selection: $selection) {
            TableColumn("") { entry in
                CoverThumb(entry: entry, height: 34)
            }
            .width(30)
            TableColumn("題名") { entry in
                Text(entry.displayTitle)
                    .foregroundStyle(entry.fileExists ? Color.primary : Color.secondary)
            }
            TableColumn("著者") { entry in Text(entry.displayAuthors) }
            TableColumn("形式") { entry in Text(label(for: entry.format)) }
                .width(60)
            TableColumn("読み進み") { entry in Text(progressLabel(entry)) }
                .width(80)
        }
        .onDeleteCommand(perform: askRemoval)
        .contextMenu(forSelectionType: LibraryEntry.ID.self) { ids in
            menu(forSelected: ids)
        } primaryAction: { ids in
            if let id = ids.first, let entry = store.recent.first(where: { $0.id == id }) {
                openEntry(entry)
            }
        }
    }

    /// 選んでいる冊数に合わせたメニュー。
    ///
    /// 1 冊なら今までどおり。何冊も選んでいるときは、その分だけまとめて扱う。
    @ViewBuilder
    private func menu(forSelected ids: Set<LibraryEntry.ID>) -> some View {
        let chosen = store.recent.filter { ids.contains($0.id) }
        if chosen.count == 1, let entry = chosen.first {
            Button("新しいウィンドウで開く") { openEntry(entry) }
            Button("情報を見る") { showing = store.resolveURL(for: entry).map(ShownFile.init) }
            Button("Finder で表示") {
                if let url = store.resolveURL(for: entry) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider()
            Button("一覧から削除", role: .destructive) {
                selection = [entry.id]
                confirmingRemoval = true
            }
        } else if chosen.count > 1 {
            // 名無しの本をまとめて直す道もこれ。保存するたびに次の本へ進む。
            Button("選んだ \(chosen.count) 冊の情報を見る") {
                showing = ShownFile(urls: chosen.compactMap { store.resolveURL(for: $0) })
            }
            Button("Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    chosen.compactMap { store.resolveURL(for: $0) })
            }
            Divider()
            Button("選んだ \(chosen.count) 冊を一覧から削除", role: .destructive) {
                selection = ids
                confirmingRemoval = true
            }
        }
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
            Text(entry.displayTitle)
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

/// 蔵書の引き方。
///
/// **混ぜない**（spec-local-ai.md 第 5.2 節）。正確な検索には「当たり」があり、
/// 当たった語を囲める。意味の近さには当たりが無く、囲むものも無い。
/// 同じ一覧に並べると、どちらの目で見ればよいのか分からなくなる。
enum SearchKind: String, CaseIterable, Identifiable {
    case exact, semantic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .exact: return "語句"
        case .semantic: return "意味"
        }
    }
}
