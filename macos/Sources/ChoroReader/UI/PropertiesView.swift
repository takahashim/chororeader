import PDFKit
import SwiftUI

struct PropertiesView: View {
    /// 何の情報を出すか。読書の窓からは開いている書籍、書棚からはファイル。
    enum Subject {
        case opened(ReaderSession)
        case file(URL)

        var url: URL {
            switch self {
            case let .opened(session): return session.document.url
            case let .file(url): return url
            }
        }
    }

    let subjects: [Subject]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LibraryStore.shared

    @State private var index = 0
    @State private var properties: BookProperties?
    @State private var titleText = ""
    @State private var authorsText = ""
    @State private var candidates: [NameCandidates.Candidate] = []
    @State private var pageImage: NSImage?
    @State private var copied = false

    init(subject: Subject) { subjects = [subject] }
    init(subjects: [Subject]) { self.subjects = subjects }

    private var current: Subject { subjects[index] }
    private var currentEntry: LibraryEntry? { store.entry(for: BookID(url: current.url)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    naming
                    if let properties {
                        ForEach(Array(properties.sections.enumerated()), id: \.offset) { _, section in
                            block(section)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(24)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 540)
        .task(id: index) { await load() }
    }

    // MARK: - 頭と足

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("書籍の情報").font(.headline)
                Text(currentEntry?.displayTitle ?? current.url.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if subjects.count > 1 {
                HStack(spacing: 6) {
                    Button { index -= 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0)
                    Text("\(index + 1) / \(subjects.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button { index += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(index + 1 >= subjects.count)
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button(copied ? "コピーしました" : "コピー") {
                guard let properties else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(properties.asText, forType: .string)
                copied = true
            }
            .disabled(properties == nil)
            Spacer()
            Button("閉じる") { dismiss() }
            if currentEntry != nil {
                Button(index + 1 < subjects.count ? "保存して次へ" : "保存") { saveAndAdvance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - 名前を付ける

    /// 書棚に並んでいる書籍にだけ出す。並んでいなければ付けた名前の置き場所が無い。
    @ViewBuilder
    private var naming: some View {
        if let entry = currentEntry {
            HStack(alignment: .top, spacing: 14) {
                if let pageImage {
                    Image(nsImage: pageImage)
                        .resizable().scaledToFit()
                        .frame(width: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(radius: 1)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("書棚での名前").font(.subheadline.weight(.semibold))
                    labeledField("題名", text: $titleText,
                                 placeholder: DisplayTitle.of(title: entry.title, path: entry.path))
                    labeledField("著者", text: $authorsText,
                                 placeholder: entry.authors.joined(separator: "、"))
                    Text("空のままなら、書籍の名乗りとファイル名で決めます。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    bibliography(of: entry)
                    if !candidates.isEmpty {
                        candidateList
                    }
                }
            }
        }
    }

    /// 書籍が名乗っている書誌。**人は直せない**（直せるのは書棚での名前だけ）。
    ///
    /// 揃わない本の方が多いので、**在るものだけ出す**。
    /// 空欄を並べても「取れなかった」のか「元から無い」のか分からない。
    @ViewBuilder
    private func bibliography(of entry: LibraryEntry) -> some View {
        let book = entry.bibliography
        if !book.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("書籍の名乗り").font(.subheadline.weight(.semibold))
                if let subtitle = book.subtitle { row("副題", subtitle) }
                if let publisher = book.publisher { row("出版社", publisher) }
                if let published = book.published { row("発行", published) }
                if let isbn = book.isbn { row("ISBN", isbn) }
            }
            .padding(.top, 4)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
                .font(.callout).frame(width: 44, alignment: .trailing)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
                .font(.callout).frame(width: 34, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveAndAdvance)
        }
    }

    /// 1 ページ目に刷ってある行。押すと欄に入る。
    ///
    /// 題名は 2 行に割れて刷られていることが多いので、押した行は**追記**する。
    /// 2 回押せば繋がる。著者らしい行（「著者：」「〜著」）は著者の欄へ回す。
    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("奥付と 1 ページ目から（押すと入る）")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(candidates.prefix(10).enumerated()), id: \.offset) { _, candidate in
                Button {
                    apply(candidate)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: candidate.isAuthor ? "person" : "textformat")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(candidate.text).lineLimit(1)
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func apply(_ candidate: NameCandidates.Candidate) {
        if candidate.isAuthor {
            authorsText = authorsText.isEmpty ? candidate.text : authorsText + "、" + candidate.text
        } else {
            titleText += candidate.text
        }
    }

    private func saveAndAdvance() {
        guard let entry = currentEntry else { return }
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let authors = authorsText
            .split(whereSeparator: { $0 == "、" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.setCustomName(entry.id, title: title, authors: authors)
        if index + 1 < subjects.count {
            index += 1
        } else {
            dismiss()
        }
    }

    // MARK: - 読み込み

    private func load() async {
        copied = false
        titleText = ""
        authorsText = ""
        candidates = []
        pageImage = nil

        if let entry = currentEntry {
            titleText = entry.customTitle ?? ""
            authorsText = (entry.customAuthors ?? []).joined(separator: "、")
        }

        switch current {
        case let .opened(session):
            properties = BookProperties.make(
                document: session.document,
                file: BookProperties.FileFacts.read(session.document.url)
            )
            prepareAids(pdf: session.document.pdfDocument)
        case let .file(url):
            properties = nil
            let pdf = url.pathExtension.lowercased() == "pdf" ? PDFKit.PDFDocument(url: url) : nil
            prepareAids(pdf: pdf)
            properties = await Task.detached { @MainActor in BookProperties.read(url) }.value
        }
    }

    /// 名前を付けるための手掛かり。1 ページ目の絵と、刷ってある行。
    private func prepareAids(pdf: PDFDocument?) {
        if let pdf {
            candidates = NameCandidates.candidates(in: pdf)
            if let page = pdf.page(at: 0) {
                let box = page.bounds(for: .mediaBox)
                let scale = 240 / max(box.width, box.height, 1)
                pageImage = page.thumbnail(of: CGSize(width: box.width * scale,
                                                      height: box.height * scale),
                                           for: .mediaBox)
            }
        } else if let name = currentEntry?.coverName {
            pageImage = CoverCache.image(named: name)
        }
    }

    private func block(_ section: BookProperties.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title).font(.subheadline.weight(.semibold))
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    Text(item.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }
}
