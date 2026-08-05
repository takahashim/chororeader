import Foundation
import PDFKit

/// 実装間の振る舞いを突き合わせるための CLI。
/// 出力の形は conformance/CONTRACT.md で定義し、Windows 実装も同じ形を返す。
/// UI もライブラリ保存も通らない純粋な経路にしておく（副作用を持ち込まない）。
enum ProbeCLI {
    static let schemaVersion = 1

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.count >= 2 && arguments[1] == "probe"
    }

    static func run(_ arguments: [String]) -> Never {
        // arguments[0] == "probe"
        let args = Array(arguments.dropFirst())
        guard let command = args.first else {
            fail("usage: TZReader probe <parse|toc|resolve|css|search|detect> ...")
        }

        switch command {
        case "parse": parse(Array(args.dropFirst()))
        case "report": report(Array(args.dropFirst()))
        case "style": style()
        case "text": text(Array(args.dropFirst()))
        case "preview": preview(Array(args.dropFirst()))
        case "fixed": fixed(Array(args.dropFirst()))
        case "resolve": resolve(Array(args.dropFirst()))
        case "css": css()
        case "search": search(Array(args.dropFirst()))
        case "detect": detect(Array(args.dropFirst()))
        case "version": emit(["schema": AnyCodableValue(schemaVersion), "implementation": AnyCodableValue("swift")])
        default: fail("unknown command: \(command)")
        }
    }

    // MARK: - コマンド

    private static func parse(_ args: [String]) -> Never {
        guard let path = args.first else { fail("usage: probe parse <epub>") }
        do {
            let archive = try ZipArchive(url: URL(fileURLWithPath: path))
            let pub = try EPUBParser.parse(archive)
            emit(ParseOutput(
                schema: schemaVersion,
                command: "parse",
                format: pub.layout == .fixed ? "fixedEPUB" : "reflowableEPUB",
                title: norm(pub.title),
                authors: pub.authors.map(norm),
                language: pub.language.map(norm),
                identifier: pub.identifier.map(norm),
                layout: pub.layout.rawValue,
                direction: pub.direction.rawValue,
                coverHref: pub.coverHref.map(norm),
                readingOrder: pub.readingOrder.map {
                    ParseOutput.Item(href: norm($0.href), mediaType: norm($0.mediaType))
                },
                tableOfContents: pub.tableOfContents.map(tocNode)
            ))
        } catch {
            emitError(error)
        }
    }

    private static func report(_ args: [String]) -> Never {
        guard let path = args.first else { fail("usage: probe report <epub>") }
        do {
            let archive = try ZipArchive(url: URL(fileURLWithPath: path))
            let pub = try EPUBParser.parse(archive)
            emit(ReportOutput(schema: schemaVersion, command: "report",
                              report: BookReport.make(archive: archive, publication: pub)))
        } catch {
            emitError(error)
        }
    }

    /// 表示設定から作る CSS。設定は標準入力から JSON で受け取る。
    private static func style() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let style = (try? JSONDecoder().decode(ReaderStyle.self, from: input)) ?? ReaderStyle()
        emit(StyleOutput(schema: schemaVersion, command: "style",
                         css: normalizeNewlines(style.css()),
                         needsForegroundMarking: style.needsForegroundMarking))
    }

    /// 章から取り出した本文。検索も診断も抜粋もこの結果に乗っているため、ここを揃える。
    private static func text(_ args: [String]) -> Never {
        guard args.count >= 2 else { fail("usage: probe text <epub> <href>") }
        do {
            let archive = try ZipArchive(url: URL(fileURLWithPath: args[0]))
            let extracted = HTMLText.extract(CSSCompat.decodeText(try archive.read(args[1])))
            emit(TextOutput(schema: schemaVersion, command: "text",
                            href: norm(args[1]),
                            text: norm(extracted.text),
                            codeRanges: extracted.codeRanges.map { [$0.lowerBound, $0.upperBound] }))
        } catch {
            emitError(error)
        }
    }

    /// リンク先の抜粋。整形の細部ではなく、どこを切り出したかを揃える。
    private static func preview(_ args: [String]) -> Never {
        guard args.count >= 2 else { fail("usage: probe preview <epub> <href> [fragment]") }
        do {
            let archive = try ZipArchive(url: URL(fileURLWithPath: args[0]))
            let fragment = args.count >= 3 && !args[2].isEmpty ? args[2] : nil
            guard let built = PreviewProvider.make(resources: archive, href: args[1],
                                                   fragment: fragment, css: "") else {
                emit(PreviewOutput(schema: schemaVersion, command: "preview",
                                   path: nil, isFootnote: false, text: nil))
            }
            emit(PreviewOutput(schema: schemaVersion, command: "preview",
                               path: norm(built.path),
                               isFootnote: built.isFootnote,
                               // 抜粋に混ざる自前の CSS は比較の対象にしない。
                               text: norm(HTMLText.extract(built.html).text
                                   .trimmingCharacters(in: .whitespacesAndNewlines))))
        } catch {
            emitError(error)
        }
    }

    /// 固定レイアウトの組み立て。ページの種別と、見開きの組み方を揃える。
    private static func fixed(_ args: [String]) -> Never {
        guard args.count >= 1 else { fail("usage: probe fixed <epub> [ページ番号]") }
        do {
            let archive = try ZipArchive(url: URL(fileURLWithPath: args[0]))
            let publication = try EPUBParser.parse(archive)
            let page = args.count >= 2 ? Int(args[1]) ?? 0 : 0
            let rtl = publication.direction == .rtl
            let spreads = FixedLayoutPlan.spreads(pageCount: publication.readingOrder.count, rtl: rtl)

            let pages = publication.readingOrder.map { link -> FixedOutput.Page in
                switch FixedLayoutPlan.pageContent(for: link.href, resources: archive) {
                case let .image(href):
                    return FixedOutput.Page(index: 0, kind: "image", href: norm(href))
                case let .document(href):
                    return FixedOutput.Page(index: 0, kind: "document", href: norm(href))
                }
            }.enumerated().map { index, page in
                FixedOutput.Page(index: index, kind: page.kind, href: page.href)
            }

            emit(FixedOutput(schema: schemaVersion, command: "fixed",
                             direction: publication.direction.rawValue,
                             pages: pages,
                             spreads: spreads,
                             spreadForPage: spreads.first { $0.contains(page) } ?? [page]))
        } catch {
            emitError(error)
        }
    }

    private static func resolve(_ args: [String]) -> Never {
        // 引数は base と href の 2 つ。空の base は "" として渡す。
        guard args.count >= 2 else { fail("usage: probe resolve <base> <href>") }
        let result = EPUBParser.resolve(base: args[0], href: args[1])
        emit(ResolveOutput(schema: schemaVersion, command: "resolve",
                           base: args[0], href: args[1], result: norm(result)))
    }

    private static func css() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let result = CSSCompat.rewrite(css: CSSCompat.decodeText(input))
        emit(CSSOutput(schema: schemaVersion, command: "css",
                       output: normalizeNewlines(result.css),
                       changes: result.changes.sorted { ($0.from, $0.to) < ($1.from, $1.to) }))
    }

    private static func search(_ args: [String]) -> Never {
        guard args.count >= 2 else { fail("usage: probe search <epub> <query>") }
        do {
            let archive = try ZipArchive(url: URL(fileURLWithPath: args[0]))
            let pub = try EPUBParser.parse(archive)
            let semaphore = DispatchSemaphore(value: 0)
            var outcome: DocumentSearch.Outcome?
            DocumentSearch.searchEPUB(resources: archive, publication: pub, query: args[1]) {
                outcome = $0
                semaphore.signal()
            }
            // 完了コールバックはメインキューへ戻るため、ここで回す。
            while outcome == nil {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            let results = outcome?.results ?? []
            emit(SearchOutput(
                schema: schemaVersion,
                command: "search",
                query: norm(args[1]),
                truncated: outcome?.truncated ?? false,
                results: results.map {
                    SearchOutput.Hit(href: norm($0.locator.href ?? ""),
                                     progression: round($0.locator.progression * 1000) / 1000,
                                     match: norm($0.match),
                                     isCode: $0.isCode)
                }
            ))
        } catch {
            emitError(error)
        }
    }

    private static func detect(_ args: [String]) -> Never {
        guard let path = args.first else { fail("usage: probe detect <file>") }
        let url = URL(fileURLWithPath: path)
        guard let detected = DocumentFormat.detect(url: url) else {
            emit(DetectOutput(schema: schemaVersion, command: "detect", format: nil,
                              error: .init(kind: "unsupportedFormat")))
        }
        switch detected {
        case .pdf:
            if PDFKit.PDFDocument(url: url) == nil {
                emit(DetectOutput(schema: schemaVersion, command: "detect", format: nil,
                                  error: .init(kind: "cannotOpenPDF")))
            }
            emit(DetectOutput(schema: schemaVersion, command: "detect", format: "pdf", error: nil))
        case .markdown:
            emit(DetectOutput(schema: schemaVersion, command: "detect", format: "markdown", error: nil))
        case .reflowableEPUB, .fixedEPUB:
            do {
                let archive = try ZipArchive(url: url)
                let pub = try EPUBParser.parse(archive)
                emit(DetectOutput(schema: schemaVersion, command: "detect",
                                  format: pub.layout == .fixed ? "fixedEPUB" : "reflowableEPUB", error: nil))
            } catch {
                emit(DetectOutput(schema: schemaVersion, command: "detect", format: nil,
                                  error: .init(kind: errorKind(error))))
            }
        }
    }

    // MARK: - 出力

    private static func tocNode(_ entry: TOCEntry) -> ParseOutput.TOCNode {
        ParseOutput.TOCNode(title: norm(entry.title),
                            href: entry.href.map(norm),
                            fragment: entry.fragment.map(norm),
                            children: entry.children.map(tocNode))
    }

    /// macOS は分解形（NFD）を返すことがあり Windows は合成形（NFC）。比較のため NFC に揃える。
    private static func norm(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
    }

    private static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func errorKind(_ error: Error) -> String {
        switch error {
        case EPUBParser.Failure.emptySpine: return "emptySpine"
        case EPUBParser.Failure.missingContainer: return "missingContainer"
        case EPUBParser.Failure.missingOPF: return "missingOPF"
        case is ZipArchive.Failure: return "brokenArchive"
        default: return "cannotParseOPF"
        }
    }

    private static func emit(_ value: some Encodable) -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(0)
    }

    private static func emitError(_ error: Error) -> Never {
        emit(ErrorOutput(schema: schemaVersion, command: "error",
                         error: .init(kind: errorKind(error))))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}

// MARK: - 出力の形

struct ProbeError: Codable {
    var kind: String
}

struct ParseOutput: Codable {
    struct Item: Codable {
        var href: String
        var mediaType: String
    }
    struct TOCNode: Codable {
        var title: String
        var href: String?
        var fragment: String?
        var children: [TOCNode]
    }

    var schema: Int
    var command: String
    var format: String
    var title: String
    var authors: [String]
    var language: String?
    var identifier: String?
    var layout: String
    var direction: String
    var coverHref: String?
    var readingOrder: [Item]
    var tableOfContents: [TOCNode]
}

struct ResolveOutput: Codable {
    var schema: Int
    var command: String
    var base: String
    var href: String
    var result: String
}

struct CSSOutput: Codable {
    var schema: Int
    var command: String
    var output: String
    var changes: [CSSCompat.Change]
}

struct SearchOutput: Codable {
    struct Hit: Codable {
        var href: String
        var progression: Double
        var match: String
        var isCode: Bool
    }
    var schema: Int
    var command: String
    var query: String
    var truncated: Bool
    var results: [Hit]
}

struct DetectOutput: Codable {
    var schema: Int
    var command: String
    var format: String?
    var error: ProbeError?
}

struct StyleOutput: Codable {
    var schema: Int
    var command: String
    var css: String
    var needsForegroundMarking: Bool
}

struct TextOutput: Codable {
    var schema: Int
    var command: String
    var href: String
    var text: String
    var codeRanges: [[Int]]
}

struct PreviewOutput: Codable {
    var schema: Int
    var command: String
    var path: String?
    var isFootnote: Bool
    var text: String?
}

struct FixedOutput: Codable {
    struct Page: Codable {
        var index: Int
        var kind: String
        var href: String
    }
    var schema: Int
    var command: String
    var direction: String
    var pages: [Page]
    var spreads: [[Int]]
    var spreadForPage: [Int]
}

struct ReportOutput: Codable {
    var schema: Int
    var command: String
    var report: BookReport
}

struct ErrorOutput: Codable {
    var schema: Int
    var command: String
    var error: ProbeError
}

/// version コマンドのような、その場限りの小さな出力に使う。
struct AnyCodableValue: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init(_ value: Int) { encodeValue = { var c = $0.singleValueContainer(); try c.encode(value) } }
    init(_ value: String) { encodeValue = { var c = $0.singleValueContainer(); try c.encode(value) } }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
