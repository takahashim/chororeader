import Foundation
import PDFKit

// PDFKit 検証: 技術書 PDF のロード時間、ページ数、アウトライン、日本語検索を確認する。

guard CommandLine.arguments.count >= 2 else {
    print("usage: pdfprobe <pdf-path> [search-term]")
    exit(1)
}
let path = CommandLine.arguments[1]
let term = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "関数"

func ms(_ from: Date) -> String {
    String(format: "%.1f ms", Date().timeIntervalSince(from) * 1000)
}

let t0 = Date()
guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
    print("ERROR: open failed: \(path)")
    exit(1)
}
print("open: \(ms(t0))  pages: \(doc.pageCount)  encrypted: \(doc.isEncrypted)")

// アウトライン
func walk(_ node: PDFOutline, depth: Int, out: inout [String]) {
    for i in 0..<node.numberOfChildren {
        guard let child = node.child(at: i) else { continue }
        let page = child.destination?.page.flatMap { doc.index(for: $0) + 1 }
        let label = child.label ?? "(no label)"
        out.append(String(repeating: "  ", count: depth) + "\(label)  [p.\(page.map(String.init) ?? "-")]")
        if depth < 2 { walk(child, depth: depth + 1, out: &out) }
    }
}
if let root = doc.outlineRoot {
    var lines: [String] = []
    walk(root, depth: 0, out: &lines)
    print("outline: \(lines.count) entries (depth<=3)")
    for line in lines.prefix(25) { print("  " + line) }
} else {
    print("outline: none")
}

// テキスト層の確認
let mid = doc.page(at: min(10, doc.pageCount - 1))
let sample = (mid?.string ?? "").replacingOccurrences(of: "\n", with: " ").prefix(120)
print("text sample (p.\(min(11, doc.pageCount))): \(sample.isEmpty ? "(no text layer)" : String(sample))")

// 日本語全文検索
let t1 = Date()
let hits = doc.findString(term, withOptions: [.caseInsensitive])
print("search \"\(term)\": \(hits.count) hits in \(ms(t1))")
for sel in hits.prefix(5) {
    if let page = sel.pages.first {
        let p = doc.index(for: page) + 1
        print("  p.\(p): \(sel.string ?? "")")
    }
}
