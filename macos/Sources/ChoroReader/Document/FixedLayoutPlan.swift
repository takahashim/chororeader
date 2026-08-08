import Foundation

enum FixedLayoutPlan {
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
        return found.count == 1 ? found.first : nil
    }

    /// ページの寸法。固定レイアウトの各ページは meta viewport で大きさを名乗る。
    ///
    /// 拡大の枠を先に決めるために要る。大きさを与えないと画像がすべて同じ位置に積まれ、
    /// 遅延読み込みが効かなくなる。名乗っていなければ nil。
    ///
    /// content の並びは、1 つでも `=` を欠いていたら全体を捨てる。
    /// 半端に読めたぶんだけ使うと、書き損じた書籍で妙な寸法を掴むことになる。
    static func viewport(for href: String, resources: ResourceProvider) -> (width: Double, height: Double)? {
        guard let data = try? resources.read(href) else { return nil }
        let source = CSSCompat.decodeText(data)
        let pattern = #"(?i)<meta\b[^>]*\bname\s*=\s*["']viewport["'][^>]*\bcontent\s*=\s*["']([^"']+)["']"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }

        var width: Double?
        var height: Double?
        for part in source[range].split(separator: ",", omittingEmptySubsequences: false) {
            guard let equals = part.firstIndex(of: "=") else { return nil }
            let key = part[..<equals].trimmingCharacters(in: .whitespaces)
            let value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "width": width = Double(value)
            case "height": height = Double(value)
            default: break
            }
        }
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return (w, h)
    }

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
