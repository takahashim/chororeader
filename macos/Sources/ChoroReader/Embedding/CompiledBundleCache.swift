import CoreML
import Foundation

@available(macOS 15, *)
enum CompiledBundleCache {
    static func compiled(_ package: URL) throws -> URL {
        let cache = try cacheDirectory()
        let stamp = try Self.stamp(of: package)
        let target = cache.appendingPathComponent("\(package.lastPathComponent)-\(stamp).mlmodelc")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        let made = try compileResolvingLinks(package)
        // 置き換えは一息で行う。途中で落ちた組みかけを次回掴まない。
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: made, to: target)
        } catch {
            return made   // 置けなくても、この場では使える
        }
        // 古い版は捨てる。モデルを入れ替えるたびに 264 MB が積み上がる。
        let others = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        for name in others
        where name.hasPrefix(package.lastPathComponent) && name != target.lastPathComponent {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent(name))
        }
        return target
    }

    /// 組み直す。**符号の連なり（symlink）は先に解いておく。**
    ///
    /// Hugging Face の置き場所は実体を blobs/ に置き、snapshots/ から符号で指す作りで、
    /// Core ML のコンパイラはこれを辿れない（weight.bin が「存在しません」になる）。
    /// そのままで通ればそれでよく、駄目なら実体を写してから組む。
    private static func compileResolvingLinks(_ package: URL) throws -> URL {
        if let made = try? MLModel.compileModel(at: package) { return made }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChoroReader-CoreML-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let copy = staging.appendingPathComponent(package.lastPathComponent)
        try copyResolvingLinks(from: package, to: copy)
        return try MLModel.compileModel(at: copy)
    }

    /// 符号を解きながら写す。中身は 264 MB あるので、要るときだけ通る道にする。
    private static func copyResolvingLinks(from source: URL, to target: URL) throws {
        let manager = FileManager.default
        let resolved = source.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            for name in try manager.contentsOfDirectory(atPath: resolved.path) {
                try copyResolvingLinks(from: resolved.appendingPathComponent(name),
                                       to: target.appendingPathComponent(name))
            }
        } else {
            try manager.copyItem(at: resolved, to: target)
        }
    }

    private static func cacheDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChoroReader/CoreML", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func stamp(of package: URL) throws -> String {
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let target = FileManager.default.fileExists(atPath: weights.path) ? weights : package
        let values = try target.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        let modified = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(size)-\(modified)"
    }
}
