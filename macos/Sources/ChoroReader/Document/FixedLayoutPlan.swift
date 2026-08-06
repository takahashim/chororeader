import Foundation

/// 固定レイアウトの組み立てのうち、画面に依らない部分。
/// ページの種別の見分けと、見開きの組み方を扱う。
/// Windows 実装と突き合わせる対象になる（conformance/CONTRACT.md）。
enum FixedLayoutPlan {
    /// ページの中身。画像 1 枚で構成されるページと、そうでないページを区別する。
    enum PageContent: Equatable {
        case image(href: String)
        case document(href: String)

        var kind: String {
            switch self {
            case .image: return "image"
            case .document: return "document"
            }
        }
        var href: String {
            switch self {
            case let .image(href), let .document(href): return href
            }
        }
    }

    /// ページが画像 1 枚で構成されているなら、その画像を直接表示する。
    /// 文字が固定座標で置かれているページは、元の XHTML をそのまま埋め込む。
    static func pageContent(for href: String, resources: ResourceProvider) -> PageContent {
        guard let data = try? resources.read(href) else { return .document(href: href) }
        let source = CSSCompat.decodeText(data)
        guard let reference = primaryImageReference(in: source) else { return .document(href: href) }
        let base = (href as NSString).deletingLastPathComponent
        let resolved = EPUBParser.resolve(base: base, href: reference)
        guard resources.contains(resolved) else { return .document(href: href) }

        // 画像以外に本文が載っているページは、画像だけを出すと内容が落ちる。
        let text = HTMLText.stripTags(source).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count < 40 else { return .document(href: href) }
        return .image(href: resolved)
    }

    private static func primaryImageReference(in html: String) -> String? {
        let patterns = [
            #"(?i)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#,
            #"(?i)<image\b[^>]*\bxlink:href\s*=\s*["']([^"']+)["']"#,
            #"(?i)<image\b[^>]*\bhref\s*=\s*["']([^"']+)["']"#,
        ]
        var found: [String] = []
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                found.append(String(html[range]))
            }
        }
        // 画像が複数あるページは、単純な 1 枚もののページではない。
        return found.count == 1 ? found.first : nil
    }

    /// 見開きの組み方。表紙は単独で見せ、以降を 2 枚ずつまとめる。
    /// 綴じ方向は左右の並べ方だけに効き、組み方そのものは変えない。
    static func spreads(pageCount: Int, rtl: Bool) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        var result: [[Int]] = [[0]]
        var index = 1
        while index < pageCount {
            if index + 1 < pageCount {
                result.append([index, index + 1])
                index += 2
            } else {
                result.append([index])
                index += 1
            }
        }
        return result
    }
}
