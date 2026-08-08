import SwiftUI

/// 意味の層の入切と進み具合。
///
/// **書棚に置く。** 索引づくりは蔵書ぜんぶに関わる仕事で、
/// 1 冊の表示設定とは性質が違うためである。
///
/// 出すのは 3 つだけとする。使うかどうか、いま何をしているか、やめる。
/// 段数やモデルの選択は出さない（spec-local-ai.md 第 1.3 節、増やさない）。
struct SemanticSettingsView: View {
    @ObservedObject private var builder = SemanticIndexBuilder.shared
    @ObservedObject private var store = LibraryStore.shared

    private var hasModel: Bool { EmbeddingModelStore.installed() != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("意味で関連箇所を出す", isOn: $builder.enabled)
                .disabled(!hasModel || !supported)
                // 入にした時点で、問いが使う短いバケットを裏で開いておく。
                // そうしないと最初の 1 回だけ数百 ms 待たされる。
                .onChange(of: builder.enabled) { _, on in
                    if on {
                        builder.warm()
                    } else {
                        // 切ったら握っているものを手放す。使う見込みが無くなる唯一の折。
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
                    HStack {
                        Text(remaining == 0 ? "すべて読み込み済みです" : "\(remaining) 冊が未読み込みです")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if remaining > 0 {
                            Button("残りを読み込む") {
                                builder.enqueue(store.entries.compactMap { store.resolveURL(for: $0) })
                            }
                            .controlSize(.small)
                        }
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

    /// 索引の無い書籍の数。
    ///
    /// **数えるのに全冊ぶんのファイルを見る。** 蔵書が多いと安くはないが、
    /// この画面を開いたときにしか通らない。
    private var remaining: Int {
        store.entries.reduce(into: 0) { total, entry in
            guard let url = store.resolveURL(for: entry) else { return }
            if !SemanticIndexStore.hasIndex(for: url) { total += 1 }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
