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

    var style: ReaderStyle {
        ReaderStyle(fontSizePercent: fontSizePercent,
                    lineHeight: lineHeight,
                    maxWidthEm: maxWidthEm,
                    theme: theme,
                    bodyFont: bodyFont,
                    codeFont: codeFont,
                    codeWrap: codeWrap,
                    publisherStyle: publisherStyle)
    }

    var needsForegroundMarking: Bool { style.needsForegroundMarking }

    func userCSS() -> String { style.css() }
}
