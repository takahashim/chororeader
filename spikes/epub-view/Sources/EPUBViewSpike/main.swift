import AppKit
import Foundation
import WebKit

// EPUB 表示スパイク:
// - unzip した EPUB を WKURLSchemeHandler でカスタムスキーム配信し WKWebView に表示
// - コードブロックを含む章を自動選択し、表示時間を計測、スナップショット PNG を保存
// 使い方: EPUBViewSpike <epub-path> <snapshot-dir>

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: EPUBViewSpike <epub-path> <snapshot-dir>")
    exit(1)
}
let epubPath = args[1]
let snapDir = URL(fileURLWithPath: args[2], isDirectory: true)
try? FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)

func msSince(_ from: Date) -> String {
    String(format: "%.0f ms", Date().timeIntervalSince(from) * 1000)
}

// --- 展開 ---
let unzipDir = snapDir.appendingPathComponent("unzipped", isDirectory: true)
try? FileManager.default.removeItem(at: unzipDir)
let tUnzip = Date()
let unzip = Process()
unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
unzip.arguments = ["-o", "-q", epubPath, "-d", unzipDir.path]
try unzip.run()
unzip.waitUntilExit()
print("unzip: \(msSince(tUnzip))")

// --- container.xml から OPF を特定 ---
let containerXML = try String(contentsOf: unzipDir.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
guard let opfRange = containerXML.range(of: #"full-path="([^"]+)""#, options: .regularExpression),
      let opfPath = containerXML[opfRange].split(separator: "\"").dropFirst().first.map(String.init) else {
    print("ERROR: OPF not found in container.xml")
    exit(1)
}
let opfDir = (opfPath as NSString).deletingLastPathComponent
print("opf: \(opfPath)")

// --- OPF パース（manifest と spine）---
final class OPFParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]  // id -> href
    var spine: [String] = []              // idref の列
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        let local = name.contains(":") ? String(name.split(separator: ":").last!) : name
        if local == "item", let id = attrs["id"], let href = attrs["href"] {
            manifest[id] = href
        } else if local == "itemref", let idref = attrs["idref"] {
            spine.append(idref)
        }
    }
}
let opfData = try Data(contentsOf: unzipDir.appendingPathComponent(opfPath))
let opfParser = OPFParser()
let xml = XMLParser(data: opfData)
xml.delegate = opfParser
xml.parse()

let spineHrefs: [String] = opfParser.spine.compactMap { opfParser.manifest[$0] }
    .map { opfDir.isEmpty ? $0 : "\(opfDir)/\($0)" }
print("spine: \(spineHrefs.count) items")

// --- コードブロックが多い章を選ぶ ---
func preCount(_ href: String) -> Int {
    guard let s = try? String(contentsOf: unzipDir.appendingPathComponent(href), encoding: .utf8) else { return 0 }
    return s.components(separatedBy: "<pre").count - 1
}
let ranked = spineHrefs.enumerated().map { ($0.offset, $0.element, preCount($0.element)) }
    .sorted { $0.2 > $1.2 }
guard let target = ranked.first else {
    print("ERROR: empty spine")
    exit(1)
}
let targetIndex = target.0
let nextIndex = min(targetIndex + 1, spineHrefs.count - 1)
print("target chapter: [\(targetIndex)] \(target.1) (\(target.2) <pre> blocks)")

// --- スキームハンドラ ---
final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    private(set) var requestCount = 0
    private(set) var totalBytes = 0
    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let relPath = url.path.removingPercentEncoding ?? url.path
        let file = root.appendingPathComponent(String(relPath.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: "tzr", code: 404))
            print("  404: \(relPath)")
            return
        }
        requestCount += 1
        totalBytes += data.count
        let mime = mimeType(for: file.pathExtension.lowercased())
        let isText = mime.hasPrefix("text/") || mime.contains("xml") || mime.contains("css")
        let resp = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                               textEncodingName: isText ? "utf-8" : nil)
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func mimeType(for ext: String) -> String {
        switch ext {
        case "xhtml", "html", "htm": return "application/xhtml+xml"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "js": return "text/javascript"
        default: return "application/octet-stream"
        }
    }
}

// --- アプリ本体 ---
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    let handler = EPUBSchemeHandler(root: unzipDir)
    var loadStart = Date()
    var step = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: "tzr")
        config.defaultWebpagePreferences.allowsContentJavaScript = false  // EPUB 内 JS 無効の方針を再現

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900), configuration: config)
        webView.navigationDelegate = self

        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 900),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.title = "EPUB Spike"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        load(chapter: targetIndex)
    }

    func load(chapter index: Int) {
        loadStart = Date()
        let url = URL(string: "tzr://book/\(spineHrefs[index].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)")!
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("didFinish: \(msSince(loadStart))  (requests: \(handler.requestCount), bytes: \(handler.totalBytes))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.advance() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("didFail: \(error.localizedDescription)")
        NSApp.terminate(nil)
    }

    func advance() {
        step += 1
        switch step {
        case 1:
            snapshot(name: "snap1-top") {
                // アプリ注入 JS は allowsContentJavaScript = false でも動くことの検証を兼ねる
                self.webView.evaluateJavaScript(
                    "document.querySelectorAll('pre')[0]?.scrollIntoView(); 'scrolled'") { result, error in
                    print("evaluateJavaScript: \(result.map { "\($0)" } ?? "nil") \(error.map { "error: \($0.localizedDescription)" } ?? "")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.advance() }
                }
            }
        case 2:
            snapshot(name: "snap2-code") {
                print("loading next chapter [\(nextIndex)] \(spineHrefs[nextIndex])")
                self.load(chapter: nextIndex)
            }
        case 3:
            snapshot(name: "snap3-next") {
                print("DONE")
                NSApp.terminate(nil)
            }
        default:
            NSApp.terminate(nil)
        }
    }

    func snapshot(name: String, then: @escaping () -> Void) {
        webView.takeSnapshot(with: nil) { image, error in
            if let image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let url = snapDir.appendingPathComponent("\(name).png")
                try? png.write(to: url)
                print("snapshot: \(url.path)")
            } else {
                print("snapshot failed: \(error?.localizedDescription ?? "unknown")")
            }
            then()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
