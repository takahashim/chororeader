import CryptoKit
import Foundation

/// 用語索引の語の置き場所。
///
/// 二字組索引（`SearchIndexStore`）の隣に、同じ考え方で置く。
/// **書籍から何度でも作り直せるので、消えても困らない。**
///
/// 意味の索引と分けてあるのは、こちらが**推論を要らない**からである。
/// 意味の索引は作り直しに全冊の埋め込みをやり直す（数分〜数十分）が、
/// こちらは書籍を読むだけで数秒で済む。規則を直すたびに作り直せる。
///
/// **「索引が無い」と「まだ見ていない」を分ける。** 索引を持たない本でも
/// 空の記録を置く。置かないと、毎回その本を開き直すことになる。
enum IndexTermsStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChoroReader/Terms", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// 語の記録。**規則を変えたら版を上げる。**
    struct Record: Codable {
        /// 抽出の規則の版。上げると作り直される。
        var version: Int
        var size: UInt64
        var modified: UInt64
        var terms: [String]
    }

    /// いまの抽出の規則の版。
    ///
    /// 上げると全冊が作り直される。**作り直しは安い**ので、
    /// 規則を直したら遠慮なく上げる。
    static let version = 1

    // MARK: - 取り出し

    /// 置いてあるものだけを返す。無くても作らない。
    static func cached(for url: URL) -> [String]? {
        guard let (size, modified) = stamp(of: url) else { return nil }
        if let box = memory.object(forKey: key(for: url)),
           box.size == size, box.modified == modified {
            return box.terms
        }
        guard let data = try? Data(contentsOf: location(for: url)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == version, record.size == size, record.modified == modified
        else { return nil }
        memory.setObject(Box(terms: record.terms, size: size, modified: modified),
                         forKey: key(for: url), cost: cost(of: record.terms))
        return record.terms
    }

    /// 無ければ作って置く。
    ///
    /// **UI を持つスレッドから呼んではいけない。** 書籍を読む。
    @discardableResult
    static func terms(for url: URL, source: @autoclosure () -> SearchIndexStore.Source?) -> [String] {
        if let already = cached(for: url) { return already }
        guard let source = source() else { return [] }
        let made = IndexTerms.of(source)
        write(made, for: url)
        return made
    }

    static func hasRecord(for url: URL) -> Bool { cached(for: url) != nil }

    static func discard(for url: URL) {
        memory.removeObject(forKey: key(for: url))
        try? FileManager.default.removeItem(at: location(for: url))
    }

    // MARK: - ファイル

    private static func write(_ terms: [String], for url: URL) {
        guard let (size, modified) = stamp(of: url) else { return }
        let record = Record(version: version, size: size, modified: modified, terms: terms)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: location(for: url), options: .atomic)
        memory.setObject(Box(terms: terms, size: size, modified: modified),
                         forKey: key(for: url), cost: cost(of: terms))
    }

    private static func location(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).terms")
    }

    private static func key(for url: URL) -> NSString {
        url.standardizedFileURL.path as NSString
    }

    private static func stamp(of url: URL) -> (UInt64, UInt64)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (UInt64(size), UInt64(max(0, modified.timeIntervalSince1970)))
    }

    // MARK: - 記憶

    private final class Box {
        let terms: [String]
        let size: UInt64
        let modified: UInt64
        init(terms: [String], size: UInt64, modified: UInt64) {
            self.terms = terms
            self.size = size
            self.modified = modified
        }
    }

    private static func cost(of terms: [String]) -> Int {
        terms.reduce(0) { $0 + $1.utf8.count + 16 }
    }

    /// 語は小さい（1 冊 600 語で 20 KB ほど）ので、蔵書ぶん抱えても構わない。
    private static let memory: NSCache<NSString, Box> = {
        let made = NSCache<NSString, Box>()
        made.totalCostLimit = 32 * 1024 * 1024
        return made
    }()
}
