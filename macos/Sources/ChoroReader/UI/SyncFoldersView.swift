import SwiftUI

/// 覚えたフォルダを見に行き、書棚との差分を見せてから当てる画面。
///
/// **黙って当てない。** 見つからなくなった書籍を外すと、読書位置としおりも消える。
/// 何が増えて何が無くなったかを先に見せ、外すかどうかは人が決める。
struct SyncFoldersView: View {
    @ObservedObject private var watched = WatchedFolders.shared
    @ObservedObject private var store = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var plan: SyncPlan?
    @State private var scanning = false
    /// 見つからなくなった書籍を一覧から外すか。**既定では外さない。**
    @State private var removeMissing = false
    @State private var applied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folderList
                    Divider()
                    difference
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 480)
        .task { if plan == nil { await scan() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("フォルダと同期").font(.headline)
            Text("覚えたフォルダを見に行き、書棚との違いを出します")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: - 覚えたフォルダ

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("覚えているフォルダ").font(.subheadline.weight(.semibold))
            if watched.folders.isEmpty {
                Text("まだありません。「フォルダを取り込む…」から取り込むと覚えます。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(watched.folders) { folder in
                HStack(spacing: 8) {
                    Image(systemName: watched.resolve(folder) == nil ? "questionmark.folder" : "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.name).font(.callout)
                        Text(shortened(folder.path))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if watched.resolve(folder) == nil {
                        Text("見つかりません").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    Button {
                        watched.forget(folder.path)
                        Task { await scan() }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("このフォルダを忘れる（書棚の書籍は消えません）")
                }
            }
        }
    }

    // MARK: - 差分

    @ViewBuilder
    private var difference: some View {
        if scanning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("探しています…").foregroundStyle(.secondary)
            }
        } else if let applied {
            Label(applied, systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else if let plan {
            VStack(alignment: .leading, spacing: 14) {
                Text(plan.summary).font(.subheadline.weight(.semibold))
                group("増えた", plan.added.map { $0.lastPathComponent }, "plus.circle")
                group("移動した", plan.moved.map { "\($0.entry.title) → \(shortened($0.to.path))" },
                      "arrow.right.circle")
                if !plan.missing.isEmpty {
                    group("見つからない", plan.missing.map(\.title), "questionmark.circle")
                    Toggle("見つからない書籍を一覧から外す", isOn: $removeMissing)
                        .font(.callout)
                    Text("外すと、その書籍の読書位置としおりも消えます。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ names: [String], _ symbol: String) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Label("\(title)（\(names.count) 冊）", systemImage: symbol)
                    .font(.callout.weight(.medium))
                // 何百冊も並べても読めない。頭だけ出して、残りは数で言う。
                ForEach(names.prefix(12), id: \.self) { name in
                    Text(name)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).padding(.leading, 22)
                }
                if names.count > 12 {
                    Text("ほか \(names.count - 12) 冊")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 22)
                }
            }
        }
    }

    // MARK: - 操作

    private var footer: some View {
        HStack {
            Button("フォルダを追加…") {
                if let folder = FileOpener.runFolderPanel() {
                    watched.remember(folder)
                    Task { await scan() }
                }
            }
            Spacer()
            Button("閉じる") { dismiss() }
            Button("取り込む") {
                Task { await apply() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(scanning || plan?.isEmpty != false || applied != nil)
        }
        .padding(16)
    }

    private func scan() async {
        applied = nil
        scanning = true
        let folders = watched.folders.compactMap { watched.resolve($0) }
        // 走査はファイルの中身を読まないので速い。1,700 冊で 0.5 秒ほど。
        plan = FolderSync.plan(folders: folders, store: store)
        scanning = false
    }

    private func apply() async {
        guard let plan else { return }
        scanning = true
        // 1 冊ごとに書籍を開くので、まとめて回すと書棚が固まる。取り込みと同じ扱いにする。
        var added = 0
        for url in plan.added where store.register(url) {
            added += 1
            await Task.yield()
        }
        for moved in plan.moved { store.relocate(moved.entry.id, to: moved.to) }
        if removeMissing {
            for entry in plan.missing { store.remove(entry.id) }
        }
        scanning = false
        applied = "\(added) 冊を加えました"
            + (plan.moved.isEmpty ? "" : "／\(plan.moved.count) 冊を付け替えました")
            + (removeMissing && !plan.missing.isEmpty ? "／\(plan.missing.count) 冊を外しました" : "")
        self.plan = SyncPlan()
    }

    private func shortened(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
