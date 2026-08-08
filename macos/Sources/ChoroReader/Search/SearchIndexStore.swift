import CryptoKit
import Foundation
import PDFKit

enum SearchIndexStore {
    enum Unit {
        case chapter(href: String)
        case page(Int)
    }

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChoroReader/Index", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: - 取り出し

    /// 索引を返す。無ければその場で作って置く。
    ///
    /// 書籍を丸ごと読むので、UI を持つスレッドから呼んではいけない。
    static func index(for url: URL, source: @autoclosure () -> Source?) -> SearchIndex? {
        if let cached = cached(for: url) { return cached }
        guard let source = source() else { return nil }
        let index = SearchIndex.build(unitTexts(of: source))
        write(index, for: url)
        if let (size, modified) = stamp(of: url) {
            memory.setObject(Box(index: index, size: size, modified: modified),
                             forKey: url.standardizedFileURL.path as NSString,
                             cost: cost(ofEncoded: index.encoded().count))
        }
        return index
    }

    /// 作らずに、既にあるものだけを返す。
    ///
    /// 一度ほどいたものは持ち続ける。書棚の横断検索は引くたびに全冊の索引に触るので、
    /// 毎回ほどき直すと蔵書 78 冊で 1.4 秒かかり、絞り込みより読み込みの方が高く付く。
    static func cached(for url: URL) -> SearchIndex? {
        guard let (size, modified) = stamp(of: url) else { return nil }
        let key = url.standardizedFileURL.path as NSString

        if let box = memory.object(forKey: key), box.size == size, box.modified == modified {
            return box.index
        }

        guard let data = try? Data(contentsOf: location(for: url)),
              let (storedSize, storedModified, payload) = unwrap(data),
              storedSize == size, storedModified == modified,
              let index = SearchIndex(decoding: payload) else { return nil }

        memory.setObject(Box(index: index, size: size, modified: modified),
                         forKey: key, cost: cost(ofEncoded: payload.count))
        return index
    }

    static func warm(_ urls: [URL]) {
        let urls = urls.filter { memory.object(forKey: $0.standardizedFileURL.path as NSString) == nil }
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.concurrentPerform(iterations: urls.count) { at in
                _ = cached(for: urls[at])
            }
        }
    }

    private final class Box {
        let index: SearchIndex
        let size: UInt64
        let modified: UInt64

        init(index: SearchIndex, size: UInt64, modified: UInt64) {
            self.index = index
            self.size = size
            self.modified = modified
        }
    }

    /// ほどいた索引は元の 3 倍ほどの場所を取る。蔵書が増えても際限なく抱えないよう頭を打つ。
    ///
    /// 頭は**ほどいた側の大きさ**で打つ。置いてあるファイルの大きさで数えると、
    /// 上限が名乗った値の 3 倍の意味になり、書いてある数と実際が食い違う。
    private static let memory: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private static func cost(ofEncoded bytes: Int) -> Int { bytes * 3 }

    static func hasIndex(for url: URL) -> Bool {
        cached(for: url) != nil
    }

    static func discard(for url: URL) {
        try? FileManager.default.removeItem(at: location(for: url))
    }

    // MARK: - 組み立て

    /// 索引を作るのに要るものだけを書籍から取り出した形。
    ///
    /// `BookDocument` そのものを渡さないのは、あれが UI 側のものだからである。
    /// 索引づくりは背後のスレッドで走るので、必要なものだけを持ち出す（走査と同じ作法）。
    enum Source {
        case epub(resources: ResourceProvider, publication: EPUBPublication)
        case pdf(PDFKit.PDFDocument)
    }

    /// 索引と走査に要るものだけを開く。
    ///
    /// 開いている書籍の `BookDocument` を使い回さず、その都度開き直す。
    /// EPUB の読み出しは mmap と中央ディレクトリだけなので安く、
    /// PDFKit は別の実体にしておかないと、描画中の書籍を背後から触ることになるためである。
    static func open(_ url: URL) -> Source? {
        switch DocumentFormat.detect(url: url) {
        case .pdf:
            return PDFKit.PDFDocument(url: url).map { .pdf($0) }
        case .reflowableEPUB, .fixedEPUB:
            guard let archive = try? ZipArchive(url: url),
                  let publication = try? EPUBParser.parse(archive) else { return nil }
            return .epub(resources: archive, publication: publication)
        case .markdown, nil:
            return nil
        }
    }

    static func unitTexts(of source: Source) -> [String] {
        switch source {
        case let .epub(resources, publication):
            return publication.readingOrder.map { link in
                guard let data = try? resources.read(link.href) else { return "" }
                return HTMLText.extract(CSSCompat.decodeText(data)).text
            }
        case let .pdf(pdf):
            return (0 ..< pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        }
    }

    /// 単位番号が何を指すか。索引を引いた結果を移動先に直すために使う。
    static func units(of source: Source) -> [Unit] {
        switch source {
        case let .epub(_, publication):
            return publication.readingOrder.map { .chapter(href: $0.href) }
        case let .pdf(pdf):
            return (0 ..< pdf.pageCount).map { .page($0) }
        }
    }

    // MARK: - ファイル

    private static func location(for url: URL) -> URL {
        let key = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).idx")
    }

    private static func stamp(of url: URL) -> (UInt64, UInt64)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (UInt64(size), UInt64(max(0, modified.timeIntervalSince1970)))
    }

    private static func write(_ index: SearchIndex, for url: URL) {
        guard let (size, modified) = stamp(of: url) else { return }
        var out = Data("CHIB".utf8)
        out.append(1)
        append(&out, size)
        append(&out, modified)
        out.append(index.encoded())
        try? out.write(to: location(for: url), options: .atomic)
    }

    private static func unwrap(_ data: Data) -> (UInt64, UInt64, Data)? {
        let bytes = [UInt8](data)
        guard bytes.count > 5, Array(bytes[0 ..< 4]) == Array("CHIB".utf8), bytes[4] == 1 else { return nil }
        var cursor = 5
        func get() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while cursor < bytes.count {
                let byte = bytes[cursor]
                cursor += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }
        guard let size = get(), let modified = get() else { return nil }
        return (size, modified, data.subdata(in: cursor ..< data.count))
    }

    private static func append(_ out: inout Data, _ value: UInt64) {
        var value = value
        while true {
            let byte = UInt8(value & 0x7f)
            value >>= 7
            if value == 0 {
                out.append(byte)
                return
            }
            out.append(byte | 0x80)
        }
    }
}

/// 索引を作る頃合いを計る。
///
/// spec.md §419 のとおり、索引づくりは読書開始の邪魔をしない。
/// 本文が出て落ち着いたころに、背後でひと通り作っておく。
/// 書棚の横断検索は、ここで作られたものに乗る。
@MainActor
enum IndexBuilder {
    /// 本文表示からこれだけ待つ。
    private static let delay: TimeInterval = 3

    private static var inFlight: Set<String> = []

    static func scheduleIfNeeded(for url: URL) {
        let key = url.standardizedFileURL.path
        guard !inFlight.contains(key), SearchIndexStore.cached(for: url) == nil else { return }
        inFlight.insert(key)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            if let source = SearchIndexStore.open(url) {
                _ = SearchIndexStore.index(for: url, source: source)
            }
            DispatchQueue.main.async { inFlight.remove(key) }
        }
    }
}
