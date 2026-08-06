import Foundation

/// 同梱のサンプル書籍。
///
/// 書籍を 1 冊も持たないマシンでも、アプリだけで読み方と機能を確かめられるようにする。
/// 束の中の資源は読み取り専用の場所にあるので、開く前に作業場所へ写す。
@MainActor
enum Samples {
    static func open(_ name: String, _ extensionName: String) {
        guard let url = copyOut(name, extensionName) else { return }
        OpenRequests.shared.request(url)
    }

    nonisolated private static func copyOut(_ name: String, _ extensionName: String) -> URL? {
        guard let source = Bundle.module.url(forResource: name, withExtension: extensionName)
        else { return nil }

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChoroReader/Samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)

        // 版が変わったら写し直す。大きさが同じなら中身も同じとみなす。
        let sizeOf: (URL) -> Int? = { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        }
        if sizeOf(destination) != sizeOf(source) {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: source, to: destination)
        }
        return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
    }
}
