import Foundation

/// 書籍を開いたときに何が起きたかを、決定的な値だけで要約する。
///
/// 用途は 2 つある。
/// 1. アプリの診断画面：表示がおかしいときに、原因が書籍側か実装側かを切り分ける。
/// 2. 実装間の突き合わせ：同じ書籍に対して Swift 版と Windows 版が同じレポートを返すことを確かめる。
/// どちらにも使えるよう、環境やタイミングに依存する値（時刻、所要時間、絶対パス）は入れない。
struct BookReport: Codable, Hashable {
    var format: String
    var layout: String
    var direction: String
    var spineCount: Int
    var tocEntryCount: Int
    var tocMaxDepth: Int
    var hasCover: Bool

    /// manifest が指しているのにアーカイブに無いリソース。壊れた EPUB の主要な兆候。
    var missingResources: [String]
    /// 目次の参照先のうち、アーカイブに無いもの。
    var missingTOCTargets: [String]
    /// spine にあるのにアーカイブに無い章。
    var missingSpineItems: [String]

    var cssFileCount: Int
    /// UTF-8 として読めなかった CSS。文字コード正規化の対象。
    var nonUTF8CSSCount: Int
    /// `-epub-` プレフィックスを含む CSS の数と、変換の内訳。
    var legacyCSSFileCount: Int
    var cssChanges: [CSSCompat.Change]

    var xhtmlCount: Int
    /// XML として解釈できない章の数。application/xhtml+xml では表示できず、text/html で配信する対象。
    var malformedXHTMLCount: Int

    var imageCount: Int
    var fontCount: Int
    var storedEntryCount: Int
    var deflatedEntryCount: Int
    /// META-INF/encryption.xml の有無。難読化フォントや DRM の判別に使う。
    var hasEncryptionMetadata: Bool

    var isHealthy: Bool {
        missingResources.isEmpty && missingTOCTargets.isEmpty && missingSpineItems.isEmpty
            && malformedXHTMLCount == 0
    }

    static func make(archive: ZipArchive, publication: EPUBPublication) -> BookReport {
        var missingResources: [String] = []
        var missingSpine: [String] = []
        var cssFiles = 0
        var nonUTF8 = 0
        var legacyCSS = 0
        var changeTotals: [String: CSSCompat.Change] = [:]
        var xhtml = 0
        var malformed = 0
        var images = 0
        var fonts = 0
        var stored = 0
        var deflated = 0

        for name in archive.names.sorted() {
            guard let entry = archive.entries[name] else { continue }
            if entry.method == 0 { stored += 1 } else { deflated += 1 }

            switch (name as NSString).pathExtension.lowercased() {
            case "css":
                cssFiles += 1
                guard let data = try? archive.read(name) else { continue }
                if String(data: data, encoding: .utf8) == nil { nonUTF8 += 1 }
                let text = CSSCompat.decodeText(data)
                guard text.contains("-epub-") else { continue }
                legacyCSS += 1
                for change in CSSCompat.rewrite(css: text).changes {
                    let key = change.from + "→" + change.to
                    if var existing = changeTotals[key] {
                        existing.count += change.count
                        changeTotals[key] = existing
                    } else {
                        changeTotals[key] = change
                    }
                }
            case "xhtml", "html", "htm":
                xhtml += 1
                guard let data = try? archive.read(name) else { continue }
                let normalized = Data(CSSCompat.rewriteXHTML(CSSCompat.decodeText(data)).css.utf8)
                if (try? XMLDocument(data: normalized, options: [.nodeLoadExternalEntitiesNever])) == nil {
                    malformed += 1
                }
            case "png", "jpg", "jpeg", "gif", "svg", "webp":
                images += 1
            case "ttf", "otf", "woff", "woff2":
                fonts += 1
            default:
                break
            }
        }

        for link in publication.readingOrder where !archive.contains(link.href) {
            missingSpine.append(link.href)
        }

        var tocTargets: [String] = []
        var maxDepth = 0
        var entryCount = 0
        func walk(_ entries: [TOCEntry], depth: Int) {
            guard !entries.isEmpty else { return }
            maxDepth = max(maxDepth, depth)
            for entry in entries {
                entryCount += 1
                if let href = entry.href, !archive.contains(href) { tocTargets.append(href) }
                walk(entry.children, depth: depth + 1)
            }
        }
        walk(publication.tableOfContents, depth: 1)

        // 章から参照されている画像や CSS のうち、実体が無いものを拾う。
        for link in publication.readingOrder {
            guard let data = try? archive.read(link.href) else { continue }
            let base = (link.href as NSString).deletingLastPathComponent
            for reference in references(in: CSSCompat.decodeText(data)) {
                let resolved = EPUBParser.resolve(base: base, href: reference)
                if !resolved.isEmpty, !archive.contains(resolved), !missingResources.contains(resolved) {
                    missingResources.append(resolved)
                }
            }
        }

        return BookReport(
            format: publication.layout == .fixed ? "fixedEPUB" : "reflowableEPUB",
            layout: publication.layout.rawValue,
            direction: publication.direction.rawValue,
            spineCount: publication.readingOrder.count,
            tocEntryCount: entryCount,
            tocMaxDepth: maxDepth,
            hasCover: publication.coverHref != nil,
            missingResources: missingResources.sorted(),
            missingTOCTargets: Array(Set(tocTargets)).sorted(),
            missingSpineItems: missingSpine.sorted(),
            cssFileCount: cssFiles,
            nonUTF8CSSCount: nonUTF8,
            legacyCSSFileCount: legacyCSS,
            cssChanges: changeTotals.values.sorted { ($0.from, $0.to) < ($1.from, $1.to) },
            xhtmlCount: xhtml,
            malformedXHTMLCount: malformed,
            imageCount: images,
            fontCount: fonts,
            storedEntryCount: stored,
            deflatedEntryCount: deflated,
            hasEncryptionMetadata: archive.contains("META-INF/encryption.xml")
        )
    }

    /// 章が参照している src / href のうち、外部 URL と fragment 以外を返す。
    private static func references(in html: String) -> [String] {
        guard let re = try? NSRegularExpression(
            pattern: #"(?i)(?:src|href|xlink:href)\s*=\s*["']([^"']+)["']"#) else { return [] }
        var out: [String] = []
        for match in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let raw = String(html[range]).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw.hasPrefix("#") || raw.hasPrefix("data:") { continue }
            if raw.contains("://") || raw.hasPrefix("mailto:") { continue }
            out.append(EPUBParser.stripFragment(raw).path)
        }
        return out.filter { !$0.isEmpty }
    }

    /// 画面表示用の要約。
    var summaryLines: [(label: String, value: String, warning: Bool)] {
        [
            ("形式", format, false),
            ("綴じ方向", direction == "rtl" ? "右開き" : "左開き", false),
            ("章数", "\(spineCount)", false),
            ("目次項目", "\(tocEntryCount)（最大 \(tocMaxDepth) 階層）", false),
            ("表紙", hasCover ? "あり" : "なし", false),
            ("CSS", "\(cssFileCount) 件（うち旧記法 \(legacyCSSFileCount)、非 UTF-8 \(nonUTF8CSSCount)）",
             legacyCSSFileCount > 0 || nonUTF8CSSCount > 0),
            ("章の XHTML", "\(xhtmlCount) 件（XML として不正 \(malformedXHTMLCount)）", malformedXHTMLCount > 0),
            ("画像 / フォント", "\(imageCount) / \(fontCount)", false),
            ("ZIP エントリ", "無圧縮 \(storedEntryCount) / 圧縮 \(deflatedEntryCount)", false),
            ("欠落リソース", missingResources.isEmpty ? "なし" : "\(missingResources.count) 件",
             !missingResources.isEmpty),
            ("目次の参照先欠落", missingTOCTargets.isEmpty ? "なし" : "\(missingTOCTargets.count) 件",
             !missingTOCTargets.isEmpty),
            ("暗号化メタデータ", hasEncryptionMetadata ? "あり" : "なし", hasEncryptionMetadata),
        ]
    }
}
