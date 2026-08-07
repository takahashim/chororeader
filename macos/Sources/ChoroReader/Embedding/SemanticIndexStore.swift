import CryptoKit
import Foundation

/// 意味の索引の置き場所と、作り直しの判断。
///
/// 二字組索引（`SearchIndexStore`）と同じ場所・同じ考え方である
/// （spec-local-ai.md 第 4.3 節）。書籍そのものから何度でも作り直せるので、
/// 消えても困らない。
///
/// **失効の鍵にモデルの名前が足してある。** ファイルの大きさと更新日時だけだと、
/// モデルを入れ替えたときに古いベクトルをそのまま使い続け、
/// 見た目は何も変わらないまま順位だけが狂う。
enum SemanticIndexStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChoroReader/Semantic", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: - 取り出し

    /// 置いてあるものだけを返す。無くても作らない。
    ///
    /// 作るのは何分もかかる仕事なので、引く側の都合で始めない（第 4.4 節）。
    static func cached(for url: URL, model: String = EmbeddingModelStore.defaultName) -> SemanticIndex? {
        guard let (size, modified) = stamp(of: url) else { return nil }
        let key = url.standardizedFileURL.path as NSString

        if let box = memory.object(forKey: key), box.size == size,
           box.modified == modified, box.index.model == model {
            return box.index
        }

        // **鍵は 1 枚の頭で見る。** 中身をほどく前に落とせるので、
        // モデルを入れ替えた直後に 20 MB を無駄に読まずに済む。
        guard let data = try? Data(contentsOf: location(for: url)),
              let head = Head(data), head.size == size, head.modified == modified,
              head.model == model,
              let index = SemanticIndex(decoding: data, from: head.cursor, model: model)
        else { return nil }

        memory.setObject(Box(index: index, size: size, modified: modified),
                         forKey: key, cost: index.count * index.dimension * 4)
        return index
    }

    static func hasIndex(for url: URL, model: String = EmbeddingModelStore.defaultName) -> Bool {
        cached(for: url, model: model) != nil
    }

    static func discard(for url: URL) {
        try? FileManager.default.removeItem(at: location(for: url))
        memory.removeObject(forKey: url.standardizedFileURL.path as NSString)
    }

    /// ほどいた索引を抱える量に頭を打つ。二字組索引と同じ作法。
    /// ベクトルは float32 でほどくので、書いてある形の 2 倍で数える。
    private static let memory: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private final class Box {
        let index: SemanticIndex
        let size: UInt64
        let modified: UInt64

        init(index: SemanticIndex, size: UInt64, modified: UInt64) {
            self.index = index
            self.size = size
            self.modified = modified
        }
    }

    // MARK: - 作る

    /// 進み具合。何分もかかるので、見せられるようにする（第 4.4 節）。
    struct Progress {
        var done: Int
        var total: Int
    }

    /// 書籍 1 冊ぶんを作って置く。
    ///
    /// **UI を持つスレッドから呼んではいけない。** 書籍を丸ごと読み、
    /// 節ごとに推論を回すので、1 冊で数十秒かかることがある。
    ///
    /// `shouldStop` が真を返したらそこで諦める。書きかけは置かない。
    @available(macOS 15, *)
    @discardableResult
    static func build(for url: URL,
                      source: SearchIndexStore.Source,
                      embedder: CoreMLEmbedder,
                      model: String = EmbeddingModelStore.defaultName,
                      progress: ((Progress) -> Void)? = nil,
                      shouldStop: (() -> Bool)? = nil) throws -> SemanticIndex? {
        let pieces = SemanticUnits.pieces(of: source)
        guard !pieces.isEmpty else { return nil }

        var units: [SemanticUnit] = []
        var vectors: [Float] = []
        vectors.reserveCapacity(pieces.count * embedder.dimension)
        var truncated = 0

        for (at, piece) in pieces.enumerated() {
            if shouldStop?() == true { return nil }
            // 見出しを頭に付ける。節の途中だけを見ても何の話か分かるようにする。
            let body = piece.unit.heading.isEmpty ? piece.text : piece.unit.heading + "。" + piece.text
            let made = try embedder.embed(body, as: .document)
            if made.truncated { truncated += 1 }
            units.append(piece.unit)
            vectors.append(contentsOf: made.vector)
            progress?(Progress(done: at + 1, total: pieces.count))
        }

        let index = SemanticIndex(model: model, dimension: embedder.dimension,
                                  units: units, vectors: vectors, truncated: truncated)
        write(index, for: url)
        return index
    }

    // MARK: - ファイル

    private static func location(for url: URL) -> URL {
        let key = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).vec")
    }

    private static func stamp(of url: URL) -> (UInt64, UInt64)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (UInt64(size), UInt64(max(0, modified.timeIntervalSince1970)))
    }

    private static func write(_ index: SemanticIndex, for url: URL) {
        guard let (size, modified) = stamp(of: url) else { return }
        var out = Head(size: size, modified: modified, model: index.model).encoded()
        out.append(index.encoded())
        try? out.write(to: location(for: url), options: .atomic)
        memory.setObject(Box(index: index, size: size, modified: modified),
                         forKey: url.standardizedFileURL.path as NSString,
                         cost: index.count * index.dimension * 4)
    }

    /// sidecar の頭。**失効の鍵をここに全部置く。**
    ///
    /// 以前は大きさと更新日時をここで、モデルの名前を中身の側で持っていた。
    /// 鍵が 2 層に散っていると、片方だけ見て通す事故になる。
    private struct Head {
        /// 版 4：抜き書きを控えるのをやめた（本文の 35% が原文のまま入っていた）。
        /// 版 3：モデルの名前を頭へ移した（それ以前は中身にあった）。
        /// 版を上げないと、古いものを新しい読み方で解いて崩れる。
        static let version: UInt8 = 4
        static let magic = Array("CHVB".utf8)

        var size: UInt64
        var modified: UInt64
        var model: String
        /// 中身の始まる位置。
        var cursor = 0

        init(size: UInt64, modified: UInt64, model: String) {
            self.size = size
            self.modified = modified
            self.model = model
        }

        init?(_ data: Data) {
            let bytes = [UInt8](data.prefix(5))
            guard bytes.count == 5, Array(bytes[0 ..< 4]) == Self.magic,
                  bytes[4] == Self.version else { return nil }
            var reader = Varint.Reader(data, from: 5)
            guard let size = reader.number(), let modified = reader.number(),
                  let model = reader.text() else { return nil }
            self.init(size: size, modified: modified, model: model)
            cursor = reader.cursor
        }

        func encoded() -> Data {
            var out = Data(Self.magic)
            out.append(Self.version)
            Varint.append(size, to: &out)
            Varint.append(modified, to: &out)
            Varint.append(model, to: &out)
            return out
        }
    }
}
