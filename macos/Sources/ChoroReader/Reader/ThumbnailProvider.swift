import AppKit
import ImageIO
import PDFKit

/// ページのサムネイルを、必要になった分だけ作る。
///
/// 画像は ImageIO の縮小読み込みを使い、原寸まで復号せずにサムネイルだけを取り出す。
/// 数百ページの書籍でも、一覧を開いた瞬間にメモリを食い潰さないようにするため。
final class ThumbnailProvider {
    enum Source {
        case images(resources: ResourceProvider, hrefs: [String?])
        case pdf(PDFKit.PDFDocument)
    }

    private let source: Source
    private let cache = NSCache<NSNumber, NSImage>()
    private let queue = DispatchQueue(label: "dev.chororeader.thumbnails", qos: .userInitiated)

    init(source: Source) {
        self.source = source
        cache.countLimit = 240
    }

    var pageCount: Int {
        switch source {
        case let .images(_, hrefs): return hrefs.count
        case let .pdf(document): return document.pageCount
        }
    }

    /// 固定レイアウト EPUB 用。ページ画像を持つ書籍だけサムネイルを出せる。
    @MainActor
    static func make(for session: ReaderSession) -> ThumbnailProvider? {
        if let fixed = session.fixed, let resources = session.document.resources {
            let hrefs = fixed.pages.map { page -> String? in
                if case let .image(href) = page { return href }
                return nil
            }
            guard hrefs.contains(where: { $0 != nil }) else { return nil }
            return ThumbnailProvider(source: .images(resources: resources, hrefs: hrefs))
        }
        if let document = session.document.pdfDocument {
            return ThumbnailProvider(source: .pdf(document))
        }
        return nil
    }

    func cached(at index: Int) -> NSImage? {
        cache.object(forKey: NSNumber(value: index))
    }

    func thumbnail(at index: Int, maxPixel: Int, completion: @escaping (NSImage?) -> Void) {
        if let hit = cached(at: index) {
            completion(hit)
            return
        }

        switch source {
        case let .images(resources, hrefs):
            guard let href = hrefs[safe: index] ?? nil else {
                completion(nil)
                return
            }
            queue.async { [weak self] in
                let image = (try? resources.read(href)).flatMap { Self.thumbnail(from: $0, maxPixel: maxPixel) }
                DispatchQueue.main.async {
                    if let image { self?.cache.setObject(image, forKey: NSNumber(value: index)) }
                    completion(image)
                }
            }

        case let .pdf(document):
            // PDFKit の描画は主スレッドで行う。ページ数が多くても、見えている分しか作らない。
            DispatchQueue.main.async { [weak self] in
                guard let page = document.page(at: index) else {
                    completion(nil)
                    return
                }
                let box = page.bounds(for: .mediaBox)
                let scale = CGFloat(maxPixel) / max(box.width, box.height, 1)
                let size = CGSize(width: box.width * scale, height: box.height * scale)
                let image = page.thumbnail(of: size, for: .mediaBox)
                self?.cache.setObject(image, forKey: NSNumber(value: index))
                completion(image)
            }
        }
    }

    /// 原寸まで復号せずにサムネイルを得る。
    private static func thumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
