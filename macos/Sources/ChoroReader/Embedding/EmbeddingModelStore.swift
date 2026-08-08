import Foundation

enum EmbeddingModelStore {
    static let defaultName = "ruri-v3-130m-coreml"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChoroReader/Models", isDirectory: true)
    }

    /// 手元に入っているモデル。無ければ nil。
    ///
    /// **束があることまで見る。** 名前の付いた空の入れ物を掴んで、
    /// 使う段になってから落ちるのを避ける。
    static func installed(_ name: String = defaultName) -> EmbeddingModel? {
        let place = directory.appendingPathComponent(name, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []
        guard names.contains(where: { $0.hasPrefix("buckets-") && $0.hasSuffix(".mlpackage") }),
              names.contains("tokenizer.json")
        else { return nil }
        return EmbeddingModel(directory: place)
    }
}
