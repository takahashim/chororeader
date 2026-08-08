import SwiftUI

struct SemanticSettingsView: View {
    @ObservedObject private var builder = SemanticIndexBuilder.shared
    @ObservedObject private var store = LibraryStore.shared

    private var hasModel: Bool { EmbeddingModelStore.installed() != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("意味で関連箇所を出す", isOn: $builder.enabled)
                .disabled(!hasModel || !supported)
                .onChange(of: builder.enabled) { _, on in
                    if on {
                        builder.warm()
                    } else {
                        builder.stop()
                        if #available(macOS 15, *) { EmbedderHolder.shared.release() }
                    }
                }

            if !supported {
                note("この機能は macOS 15 以降で使えます")
            } else if !hasModel {
                note("モデルが見つかりません。\(EmbeddingModelStore.directory.path) に置いてください")
            } else {
                note("読んでいる場所に近い箇所を、ほかの書籍から探します。"
                     + "書籍は端末の外へ出ません。")
            }

            if builder.enabled, hasModel, supported {
                Divider()
                Toggle("電源に繋いでいるときだけ進める", isOn: $builder.onPowerOnly)
                    .font(.callout)

                if let working = builder.working {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("読み込んでいます：\(working.title)").font(.callout).lineLimit(1)
                        ProgressView(value: working.fraction)
                        HStack {
                            Text(working.total > 0
                                 ? "\(working.done) / \(working.total) 節"
                                 : "節を数えています")
                                .font(.caption).foregroundStyle(.secondary)
                            if builder.pending > 0 {
                                Text("・残り \(builder.pending) 冊")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("やめる") { builder.stop() }
                                .controlSize(.small)
                        }
                    }
                } else {
                    let left = remaining
                    HStack(alignment: .firstTextBaseline) {
                        Text(left.label).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if left.total > 0 {
                            Button(left.stale > 0 ? "作り直す" : "残りを読み込む") {
                                builder.enqueue(store.entries.compactMap { store.resolveURL(for: $0) })
                            }
                            .controlSize(.small)
                        }
                    }
                    if left.stale > 0 {
                        note("モデルが変わったので、作ったものは使えません。作り直すまで、その書籍は結果に出ません。")
                    }
                }

                if let failure = builder.failure {
                    note("うまくいかなかったものがあります：\(failure)")
                }
            }
        }
    }

    private var supported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    /// まだ作っていない書籍と、版が変わって使えなくなった書籍の数。
    ///
    /// **「作っていない」と「作り直しになった」は人にとって違う。**
    /// 前者は待てば済むが、後者は全量が作り直しになる。
    ///
    /// 数えるのに全冊ぶんのファイルを見るが、**頭だけ**なので安い。
    /// この画面を開いたときにしか通らない。
    private struct Remaining {
        var fresh = 0     // まだ作っていない
        var stale = 0     // 作ったが版が変わった
        var total: Int { fresh + stale }

        var label: String {
            if total == 0 { return "すべて読み込み済みです" }
            if stale == 0 { return "\(fresh) 冊が未読み込みです" }
            if fresh == 0 { return "\(stale) 冊が作り直しになります" }
            return "\(fresh) 冊が未読み込み、\(stale) 冊が作り直しになります"
        }
    }

    private var remaining: Remaining {
        var made = Remaining()
        for entry in store.entries {
            guard let url = store.resolveURL(for: entry) else { continue }
            guard !SemanticIndexStore.hasIndex(for: url) else { continue }
            if SemanticIndexStore.isStale(for: url) { made.stale += 1 } else { made.fresh += 1 }
        }
        return made
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
