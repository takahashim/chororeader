import AppKit
import SwiftUI

extension TOCEntry {
    var optionalChildren: [TOCEntry]? { children.isEmpty ? nil : children }
}

struct SidebarView: View {
    @ObservedObject var session: ReaderSession
    var searchFocused: FocusState<Bool>.Binding
    @Environment(\.openWindow) private var openWindow
    /// 一覧に出す本文。索引には控えていないので、原書から読む。
    @StateObject private var passages = PassageTextLoader()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $session.sidebarTab) {
                ForEach(session.availableTabs) { tab in
                    Label(tab.label, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .padding(8)

            Divider()

            switch session.sidebarTab {
            case .toc: tocList
            case .thumbnails: thumbnailList
            case .search: searchPane
            case .related: relatedList
            case .bookmarks: bookmarkList
            }
        }
    }

    // MARK: - 目次

    private var tocList: some View {
        Group {
            if session.document.tableOfContents.isEmpty {
                placeholder("目次がありません")
            } else {
                List(session.document.tableOfContents, children: \.optionalChildren) { entry in
                    Button {
                        open(entry, newWindow: NSEvent.modifierFlags.contains(.command))
                    } label: {
                        Text(entry.title)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("新しいウィンドウで開く") { open(entry, newWindow: true) }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func open(_ entry: TOCEntry, newWindow: Bool) {
        let locator = Locator(href: entry.href, page: entry.page, progression: 0,
                              fragment: entry.fragment, title: entry.title)
        if newWindow {
            session.openInNewWindow(locator)
        } else {
            session.go(to: locator)
        }
    }

    @ViewBuilder
    private var thumbnailList: some View {
        if let provider = session.thumbnails {
            ThumbnailGridView(session: session, provider: provider)
        } else {
            placeholder("この書籍にはページ画像がありません")
        }
    }

    // MARK: - 検索

    private var searchPane: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("この書籍を検索", text: $session.searchQuery)
                    .textFieldStyle(.plain)
                    .focused(searchFocused)
                    .onSubmit { session.runSearch() }
                if !session.searchQuery.isEmpty {
                    Button {
                        session.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)

            Divider()

            if !session.searchAvailable {
                placeholder(session.document.format == .fixedEPUB
                            ? "この書籍はページが画像のため検索できません"
                            : "この PDF にはテキスト層がないため検索できません")
            } else if session.isSearching {
                VStack { ProgressView() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.searchResults.isEmpty {
                placeholder(session.searchQuery.isEmpty ? "語句を入力してください" : "見つかりませんでした")
            } else {
                List {
                    Section {
                        ForEach(session.searchResults) { result in
                            resultRow(result)
                        }
                    } header: {
                        Text(session.searchTruncated
                             ? "\(session.searchResults.count) 件以上（上限で打ち切り）"
                             : "\(session.searchResults.count) 件")
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            if NSEvent.modifierFlags.contains(.command) {
                session.openInNewWindow(result)
            } else {
                session.go(to: result)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(result.chapterTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if result.isCode {
                        Text("コード")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                (Text(result.before).foregroundStyle(.secondary)
                    + Text(result.match).bold()
                    + Text(result.after).foregroundStyle(.secondary))
                    .font(result.isCode ? .system(.callout, design: .monospaced) : .callout)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("新しいウィンドウで開く") { session.openInNewWindow(result) }
        }
    }

    // MARK: - しおり

    private var bookmarkList: some View {
        Group {
            if session.document.bookmarks.isEmpty {
                placeholder("しおりはまだありません（⌘D で追加）")
            } else {
                List {
                    ForEach(session.document.bookmarks) { bookmark in
                        Button {
                            if NSEvent.modifierFlags.contains(.command) {
                                session.openInNewWindow(bookmark.locator)
                            } else {
                                session.go(to: bookmark.locator)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.name).lineLimit(1)
                                Text(bookmark.locator.text ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("新しいウィンドウで開く") { session.openInNewWindow(bookmark.locator) }
                            Button("削除", role: .destructive) { session.document.removeBookmark(bookmark) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - 関連

    private var relatedList: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    session.findRelated()
                } label: {
                    Label("選んだ箇所に近い場所を探す", systemImage: "sparkle.magnifyingglass")
                        .font(.callout)
                }
                .disabled(session.relatedRunning)
                if session.relatedRunning { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(8)

            if let seed = session.relatedSeed {
                // 何に対する結果なのかを出す。選び直したのに前の結果を見ていた、を防ぐ。
                Text(seed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }

            Divider()

            if let reason = session.relatedReason {
                placeholder(reason)
            } else if session.relatedSeed == nil {
                placeholder("本文を選んでから探してください")
            } else {
                List(session.related) { passage in
                    relatedRow(passage)
                }
                .listStyle(.sidebar)
                .task(id: session.related) {
                    passages.load(session.related) { LibraryStore.shared.resolveURL(for: $0) }
                }
            }
        }
    }

    private func relatedRow(_ passage: RelatedPassage) -> some View {
        Button {
            openWindow(value: BookRoute(path: passage.book.path,
                                        locator: passage.unit.target, query: nil))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(passage.book.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // 近さを出す。当たりではないので、どれくらい近いのかを人が測れるようにする。
                    Text(String(format: "%.2f", passage.score))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if !passage.unit.heading.isEmpty {
                    Text(passage.unit.heading).font(.callout).lineLimit(2)
                }
                Text(passages.texts[passage.id] ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
