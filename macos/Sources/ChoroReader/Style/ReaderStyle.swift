import Foundation

/// 表示設定の値そのもの。
///
/// 画面の状態から切り離してあるのは、生成する CSS が入力から一意に決まる部分だからである。
/// Windows 実装と突き合わせる対象になる（conformance/CONTRACT.md）。
struct ReaderStyle: Codable, Equatable {
    var fontSizePercent: Double = 100
    var lineHeight: Double = 1.8
    var maxWidthEm: Double = 42
    var theme: ReaderTheme = .light
    var bodyFont: String = ""
    var codeFont: String = "SF Mono"
    var codeWrap: Bool = false
    var publisherStyle: Bool = false

    /// 暗いテーマでは、背景色を持たない要素にだけ文字色を当てる。その印付けが要るかどうか。
    var needsForegroundMarking: Bool { !publisherStyle && theme == .dark }

    init() {}

    /// 欠けているキーは既定値で補う。
    /// 合成される Decodable はプロパティの既定値を使わずに失敗するため、自前で組み立てる。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ReaderStyle()
        fontSizePercent = try container.decodeIfPresent(Double.self, forKey: .fontSizePercent) ?? fallback.fontSizePercent
        lineHeight = try container.decodeIfPresent(Double.self, forKey: .lineHeight) ?? fallback.lineHeight
        maxWidthEm = try container.decodeIfPresent(Double.self, forKey: .maxWidthEm) ?? fallback.maxWidthEm
        theme = try container.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? fallback.theme
        bodyFont = try container.decodeIfPresent(String.self, forKey: .bodyFont) ?? fallback.bodyFont
        codeFont = try container.decodeIfPresent(String.self, forKey: .codeFont) ?? fallback.codeFont
        codeWrap = try container.decodeIfPresent(Bool.self, forKey: .codeWrap) ?? fallback.codeWrap
        publisherStyle = try container.decodeIfPresent(Bool.self, forKey: .publisherStyle) ?? fallback.publisherStyle
    }

    init(fontSizePercent: Double, lineHeight: Double, maxWidthEm: Double, theme: ReaderTheme,
         bodyFont: String, codeFont: String, codeWrap: Bool, publisherStyle: Bool) {
        self.fontSizePercent = fontSizePercent
        self.lineHeight = lineHeight
        self.maxWidthEm = maxWidthEm
        self.theme = theme
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.codeWrap = codeWrap
        self.publisherStyle = publisherStyle
    }

    /// 本文へ被せるスタイル。出版社 CSS を壊さない範囲に絞る。
    func css() -> String {
        let t = theme
        let widthRule = maxWidthEm > 0 ? "max-width: \(Int(maxWidthEm))em !important;" : ""
        let bodyFontRule = bodyFont.isEmpty ? "" : "font-family: \"\(bodyFont)\", serif !important;"

        // 出版社スタイル優先のときは、色と幅だけを最小限に整える。
        if publisherStyle {
            return """
            html { background-color: \(t.background) !important; }
            body { \(widthRule) margin-left: auto !important; margin-right: auto !important; }
            img, svg, video { max-width: 100% !important; height: auto !important; }
            pre { overflow-x: auto; }
            """
        }

        // 文字色の上書きは暗いテーマだけに限る。
        // 明るいテーマとセピアでは、出版社の配色は明るい紙を前提に組まれていてそのまま読める。
        // 一律に上書きすると、見出しの黒帯のように背景色を持つ要素から文字色を奪ってしまう。
        let colorRules = t == .dark ? """
        body { color: \(t.foreground) !important; }
        /* 背景色を持たない要素だけに当てる。印は choroApplyForeground が付ける。 */
        .choro-fg { color: \(t.foreground) !important; }
        a.choro-fg, .choro-fg a:not([class]) { color: \(t.link) !important; }
        """ : """
        body { color: \(t.foreground); }
        """

        return """
        html {
            font-size: \(Int(fontSizePercent))% !important;
            background-color: \(t.background) !important;
            -webkit-text-size-adjust: none;
        }
        body {
            line-height: \(String(format: "%.2f", lineHeight)) !important;
            \(widthRule)
            margin: 0 auto !important;
            padding: 2em 1.6em 6em !important;
            background-color: \(t.background) !important;
            \(bodyFontRule)
        }
        \(colorRules)
        img, svg, video { max-width: 100% !important; height: auto !important; }
        table { max-width: 100% !important; display: block; overflow-x: auto; }
        /* コードは等幅で読めることを最優先にし、内側の色付けには触れない */
        pre, code, kbd, samp {
            font-family: "\(codeFont)", ui-monospace, Menlo, monospace !important;
            background-color: \(t.codeBackground) !important;
        }
        pre {
            padding: 0.8em 1em !important;
            border-radius: 6px;
            overflow-x: auto !important;
            white-space: \(codeWrap ? "pre-wrap" : "pre") !important;
            word-break: \(codeWrap ? "break-all" : "normal") !important;
        }
        """
    }
}
