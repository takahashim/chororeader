import Foundation

/// Hugging Face から checkpoint の材料を取ってくる。
///
/// **変換のときにしか通らない。** 読書時ネットワーク不使用の不変条件
/// （spec.md 第 2.2 節）には触れない。書籍とは無関係の通信である。
///
/// 手元の HF キャッシュに既にあれば、そちらを使う。
/// 無ければ取って、置き場所へ写す。**2 度目からは取らない。**
public struct HubFetch {
    private static let required = ["config.json", "model.safetensors"]
    private static let optional = ["tokenizer.json", "tokenizer_config.json",
                                   "special_tokens_map.json", "1_Pooling/config.json"]

    public enum Failure: Error, LocalizedError {
        case cannotFetch(String)

        public var errorDescription: String? {
            switch self {
            case let .cannotFetch(why): return "モデルを取得できません：\(why)"
            }
        }
    }

    public struct Materials {
        public var directory: URL
        var explicitConfig: URL?
        var explicitWeights: URL?

        public var config: URL {
            explicitConfig ?? directory.appendingPathComponent("config.json")
        }
        public var weights: URL {
            explicitWeights ?? directory.appendingPathComponent("model.safetensors")
        }
        var extras: [(name: String, url: URL)]
    }

    public static func local(weights: URL, config: URL) -> Materials {
        // そばへ写すものは、重みと同じ場所から拾えるだけ拾う。
        var made = materials(at: weights.deletingLastPathComponent())
        made.explicitWeights = weights
        made.explicitConfig = config
        return made
    }

    /// 手元にあればそれを、無ければ取ってくる。
    ///
    /// - Parameter report: 進み具合。取るのに時間がかかるので、黙って待たせない。
    public static func materials(for modelId: String, into cache: URL,
                                 report: (String) -> Void) throws -> Materials {
        if let found = inHuggingFaceCache(modelId) {
            report("手元の Hugging Face の置き場所を使います")
            return materials(at: found)
        }

        let directory = cache.appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "--"),
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for name in required + optional {
            let target = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            let source = "https://huggingface.co/\(modelId)/resolve/main/\(name)"
            guard let url = URL(string: source) else { continue }
            report("取っています：\(name)")
            do {
                let data = try Data(contentsOf: url)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
            } catch {
                // 無くてよいものは黙って飛ばす（1_Pooling は reranker には無い）。
                if required.contains(name) {
                    throw Failure.cannotFetch("\(name)：\(error.localizedDescription)")
                }
            }
        }
        return materials(at: directory)
    }

    private static func materials(at directory: URL) -> Materials {
        var extras: [(String, URL)] = []
        for name in optional {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { extras.append((name, url)) }
        }
        extras.append(("config.json", directory.appendingPathComponent("config.json")))
        return Materials(directory: directory, extras: extras)
    }

    private static func inHuggingFaceCache(_ modelId: String) -> URL? {
        let hub = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        let folder = "models--" + modelId.replacingOccurrences(of: "/", with: "--")
        let snapshots = hub.appendingPathComponent(folder).appendingPathComponent("snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)
        else { return nil }
        for entry in entries.sorted() {
            let directory = snapshots.appendingPathComponent(entry)
            let weights = directory.appendingPathComponent("model.safetensors")
            let config = directory.appendingPathComponent("config.json")
            if FileManager.default.fileExists(atPath: weights.path),
               FileManager.default.fileExists(atPath: config.path) {
                return directory
            }
        }
        return nil
    }

    /// 変換物のそばへ材料を写す。
    ///
    /// **符号の連なり（symlink）は解いて写す。** Hugging Face の置き場所は
    /// 実体を blobs/ に置いて snapshots/ から指す作りで、そのまま写すと
    /// 壊れた繋がりが残る。
    public static func place(_ materials: Materials, beside output: URL) throws {
        let manager = FileManager.default
        for (name, source) in materials.extras {
            let target = output.appendingPathComponent(name)
            try? manager.removeItem(at: target)
            try manager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            try manager.copyItem(at: source.resolvingSymlinksInPath(), to: target)
        }
    }
}
