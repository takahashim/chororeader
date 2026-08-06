import SwiftUI

/// 表示がおかしいときに、原因が書籍側か実装側かを切り分けるための画面。
/// 出している内容は `ChoroReader probe report` と同じもので、Windows 実装との突き合わせにも使う。
struct DiagnosticsView: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss

    @State private var report: BookReport?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let report {
                        summary(report)
                        details(report)
                    } else if session.document.pdfDocument != nil {
                        Text("PDF の診断は未対応です。")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    liveLog
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .task {
            if report == nil { report = session.document.report() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("書籍の診断").font(.headline)
                Text(session.document.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let report {
                Label(report.isHealthy ? "問題は見つかりません" : "確認すべき点があります",
                      systemImage: report.isHealthy ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(report.isHealthy ? Color.green : Color.orange)
                    .font(.callout)
            }
        }
        .padding(16)
    }

    private func summary(_ report: BookReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(report.summaryLines, id: \.label) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.label)
                        .frame(width: 150, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(line.value)
                        .foregroundStyle(line.warning ? Color.orange : Color.primary)
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func details(_ report: BookReport) -> some View {
        if !report.cssChanges.isEmpty {
            section("CSS の互換変換") {
                ForEach(report.cssChanges, id: \.self) { change in
                    Text(change.logLine).font(.system(.callout, design: .monospaced))
                }
            }
        }
        if !report.missingResources.isEmpty {
            section("欠落しているリソース") {
                ForEach(report.missingResources.prefix(20), id: \.self) { path in
                    Text(path).font(.system(.callout, design: .monospaced)).foregroundStyle(.orange)
                }
                if report.missingResources.count > 20 {
                    Text("ほか \(report.missingResources.count - 20) 件").foregroundStyle(.secondary)
                }
            }
        }
        if !report.missingTOCTargets.isEmpty {
            section("目次が指す先が見つからない") {
                ForEach(report.missingTOCTargets.prefix(20), id: \.self) { path in
                    Text(path).font(.system(.callout, design: .monospaced)).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var liveLog: some View {
        let log = session.web?.schemeHandler.cssChangeLog ?? []
        if !log.isEmpty {
            section("この画面までに実際に変換した CSS") {
                ForEach(log.prefix(20), id: \.self) { line in
                    Text(line).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button(copied ? "コピーしました" : "JSON をコピー") { copyJSON() }
                .disabled(report == nil)
            Text("`ChoroReader probe report <ファイル>` と同じ内容です")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func copyJSON() {
        guard let report else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
