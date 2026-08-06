import AppKit
import ImageIO
import PDFKit

/// 書棚に並べる表紙を、書籍を開いたときに 1 度だけ取り出して置いておく。
///
/// 書棚を開くたびに書籍を開き直すわけにはいかない。
/// EPUB は数十メガあり、PDF は数百ページある。一覧のために毎回それを触るのは重い。
/// 原寸で持つ必要もないので、縮小したものを Application Support の下へ書く。
@MainActor
enum CoverCache {
    /// 書棚の升目に収まる大きさ。Retina を見込んで 2 倍で持つ。
    nonisolated private static let maxPixel = 640

    nonisolated private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TZReader/Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated static func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    nonisolated static func image(named name: String) -> NSImage? {
        NSImage(contentsOf: url(for: name))
    }

    /// 書籍から表紙を取り出して置く。置けたら名前を返す。
    ///
    /// EPUB は OPF が指す表紙、PDF は 1 ページ目を使う。
    /// どちらも取れない書籍はあるので、失敗は失敗のまま返す。
    static func store(from doc: BookDocument) -> String? {
        guard let image = extract(from: doc) else { return nil }
        let name = doc.id.raw + ".png"
        guard let data = png(from: image) else { return nil }
        try? data.write(to: url(for: name))
        return name
    }

    private static func extract(from doc: BookDocument) -> NSImage? {
        if let pdf = doc.pdfDocument, let page = pdf.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let scale = CGFloat(maxPixel) / max(bounds.width, bounds.height)
            return page.thumbnail(of: CGSize(width: bounds.width * scale,
                                             height: bounds.height * scale),
                                  for: .mediaBox)
        }

        guard let href = doc.publication?.coverHref,
              let resources = doc.resources,
              let data = try? resources.read(href) else { return nil }
        return downsample(data)
    }

    /// 原寸まで復号せずに縮小したものだけを取り出す。表紙が全面写真でも重くならない。
    nonisolated private static func downsample(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func png(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// 一覧から消した書籍の表紙は残さない。
    nonisolated static func discard(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }
}
