import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var store = LibraryStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if store.entries.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(minWidth: 460, minHeight: 320)
        .navigationTitle("ライブラリ")
        .toolbar {
            Button {
                for url in FileOpener.runOpenPanel() { open(url) }
            } label: {
                Label("開く", systemImage: "plus")
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
        }
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

    private var list: some View {
        List {
            ForEach(store.recent) { entry in
                Button {
                    openEntry(entry)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: entry.format))
                            .font(.title3)
                            .foregroundStyle(entry.fileExists ? Color.accentColor : Color.secondary)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1)
                            HStack(spacing: 6) {
                                if !entry.authors.isEmpty {
                                    Text(entry.displayAuthors).lineLimit(1)
                                }
                                if let locator = entry.lastLocator {
                                    Text(progressLabel(locator))
                                }
                                if !entry.fileExists {
                                    Text("ファイルが見つかりません").foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("新しいウィンドウで開く") { openEntry(entry) }
                    Button("Finder で表示") {
                        if let url = store.resolveURL(for: entry) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Divider()
                    Button("一覧から削除", role: .destructive) { store.remove(entry.id) }
                }
            }
        }
    }

    private func icon(for format: DocumentFormat) -> String {
        switch format {
        case .pdf: return "doc.richtext"
        case .fixedEPUB: return "photo.on.rectangle"
        case .markdown: return "text.alignleft"
        case .reflowableEPUB: return "book"
        }
    }

    private func progressLabel(_ locator: Locator) -> String {
        if let page = locator.page { return "p.\(page + 1)" }
        return "\(Int(locator.progression * 100))%"
    }

    private func openEntry(_ entry: LibraryEntry) {
        guard let url = store.resolveURL(for: entry) else { return }
        open(url)
    }

    private func open(_ url: URL) {
        openWindow(value: BookRoute(path: url.path, locator: nil))
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
