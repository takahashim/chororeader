import Foundation

/// モデル一式の置き場所。
///
/// **配り方はまだ決めていない**（公開物を作り直すのか、別名で置くのか、
/// spec-local-ai.md 第 4.6 節）。決まるまで先へ進めるよう、
/// アプリからは「決まった場所を見るだけ」にしておく。
/// 後で取得を足すときも、書き込む先がここになるだけで、使う側は変わらない。
///
/// ```text
/// ~/Library/Application Support/ChoroReader/Models/
///   └─ ruri-v3-130m-coreml/
///        tokenizer.json / config.json / 1_Pooling/ / buckets-….mlpackage
/// ```
///
/// **Caches には置かない。** OS はいつでも消してよいことになっており、
/// 消えると 260 MB を取り直すことになる。組み直したもの（`.mlmodelc`）は
/// 7 秒で作れるので、そちらは Caches のままでよい（`CoreMLEmbedder`）。
enum EmbeddingModelStore {
    /// 既定のモデルの名前。sidecar の失効の鍵にも使う（第 4.3 節）。
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
