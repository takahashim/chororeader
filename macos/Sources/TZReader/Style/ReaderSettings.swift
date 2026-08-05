import Foundation
import SwiftUI

enum ReaderTheme: String, CaseIterable, Codable, Identifiable {
    case light, sepia, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "明るい"
        case .sepia: return "セピア"
        case .dark: return "暗い"
        }
    }
    var background: String {
        switch self {
        case .light: return "#ffffff"
        case .sepia: return "#f6efe2"
        case .dark: return "#1c1c1e"
        }
    }
    var foreground: String {
        switch self {
        case .light: return "#1a1a1a"
        case .sepia: return "#3a3226"
        case .dark: return "#d6d6d6"
        }
    }
    var link: String {
        switch self {
        case .light: return "#0b5cad"
        case .sepia: return "#8a5a1a"
        case .dark: return "#79b1ff"
        }
    }
    var codeBackground: String {
        switch self {
        case .light: return "#f4f4f6"
        case .sepia: return "#ece3d2"
        case .dark: return "#2b2b2e"
        }
    }
    var appearance: NSAppearance? {
        self == .dark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
    }
}

/// ページを並べる形。操作の意味（縦は読む、横は次の単位へ）はどのモードでも変わらない。
enum PageLayoutMode: String, CaseIterable, Codable, Identifiable {
    case continuousScroll
    case singlePage
    case spread
    var id: String { rawValue }

    var label: String {
        switch self {
        case .continuousScroll: return "連続スクロール"
        case .singlePage: return "単ページ"
        case .spread: return "見開き"
        }
    }
}

/// ページを表示領域へどう収めるか。
enum PageFit: String, CaseIterable, Codable, Identifiable {
    case whole
    case width
    case actual
    var id: String { rawValue }

    var label: String {
        switch self {
        case .whole: return "ページ全体"
        case .width: return "横幅に合わせる"
        case .actual: return "原寸"
        }
    }
}

/// 表示設定。値はアプリ全体で共有し、ウィンドウごとには持たない。
final class ReaderSettings: ObservableObject {
    static let shared = ReaderSettings()

    @AppStorage("fontSizePercent") var fontSizePercent: Double = 100 { willSet { objectWillChange.send() } }
    @AppStorage("lineHeight") var lineHeight: Double = 1.8 { willSet { objectWillChange.send() } }
    @AppStorage("maxWidthEm") var maxWidthEm: Double = 42 { willSet { objectWillChange.send() } }
    @AppStorage("theme") var theme: ReaderTheme = .light { willSet { objectWillChange.send() } }
    @AppStorage("bodyFont") var bodyFont: String = "" { willSet { objectWillChange.send() } }
    @AppStorage("codeFont") var codeFont: String = "SF Mono" { willSet { objectWillChange.send() } }
    @AppStorage("codeWrap") var codeWrap: Bool = false { willSet { objectWillChange.send() } }
    @AppStorage("publisherStyle") var publisherStyle: Bool = false { willSet { objectWillChange.send() } }
    /// PDF と固定レイアウトの並べ方。技術書 PDF は連続スクロールが読みやすいので既定にする。
    @AppStorage("pageLayout") var pageLayout: PageLayoutMode = .continuousScroll { willSet { objectWillChange.send() } }
    @AppStorage("pageFit") var pageFit: PageFit = .whole { willSet { objectWillChange.send() } }

    /// 暗いテーマでは、背景色を持たない要素にだけ文字色を当てる。その印付けが要るかどうか。
    var needsForegroundMarking: Bool { !publisherStyle && theme == .dark }

    /// 本文へ被せるスタイル。出版社 CSS を壊さない範囲に絞る。
    func userCSS() -> String {
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
        // 明るいテーマとセピアでは、出版社の配色は明るい紙を前提に作られていてそのまま読める。
        // 一律に上書きすると、見出しの黒帯のように背景色を持つ要素から文字色を奪ってしまう。
        let colorRules = t == .dark ? """
        body { color: \(t.foreground) !important; }
        /* 背景色を持たない要素だけに当てる。印は tzrApplyForeground が付ける。 */
        .tzr-fg { color: \(t.foreground) !important; }
        a.tzr-fg, .tzr-fg a:not([class]) { color: \(t.link) !important; }
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
