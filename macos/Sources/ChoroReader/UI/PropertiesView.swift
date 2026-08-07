import SwiftUI

/// 書籍そのものが名乗っていることを見せる画面。
///
/// 診断（DiagnosticsView）とは役目が違う。あちらは表示がおかしいときの切り分けで、
/// こちらは読む人が知りたいこと——誰が書いたか、いつ作られたか、何ページか——を出す。
/// 出す中身は BookProperties が決める。ここは並べるだけにする。
struct PropertiesView: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss

    @State private var properties: BookProperties?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                if let properties {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(properties.sections.enumerated()), id: \.offset) { _, section in
                            block(section)
                        }
                    }
                    .padding(16)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(32)
                }
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 460)
        .task {
            if properties == nil {
                properties = BookProperties.make(
                    document: session.document,
                    file: BookProperties.FileFacts.read(session.document.url)
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("書籍の情報").font(.headline)
            Text(session.document.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func block(_ section: BookProperties.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title).font(.subheadline.weight(.semibold))
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    // 識別子や場所は書き写したくなる。選べるようにしておく。
                    Text(item.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }

    private var footer: some View {
        HStack {
            // 目で見るだけでは書き写せない。押した時点で写す（診断と同じ）。
            Button(copied ? "コピーしました" : "コピー") {
                guard let properties else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(properties.asText, forType: .string)
                copied = true
            }
            .disabled(properties == nil)
            Spacer()
            Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
