import Foundation

/// 並べ直しに使うモデル一式の置き場所。
///
/// 埋め込みと同じ `Models/` の下に、別の名前で並べる（`EmbeddingModelStore`）。
/// 中身も同じ形で、違うのは**頭**だけである。
///
/// ```text
/// <置き場所>/
///   tokenizer.json                 語彙。埋め込みの側と同じ SentencePiece Unigram
///   config.json                    層と幅
///   choro-head.json                "classifier"。これで埋め込みと見分ける
///   buckets-256-512.mlpackage      長さごとの固定形
/// ```
///
/// **`1_Pooling/` が無いことで見分けない。** 写し忘れと区別が付かないので、
/// 変換器が書き添える印（`choro-head.json`）を見る。
struct RerankerModel {
    let directory: URL

    var tokenizerURL: URL { directory.appendingPathComponent("tokenizer.json") }
    var configURL: URL { directory.appendingPathComponent("config.json") }
}

enum RerankerModelStore {
    /// 既定のモデル。スパイクで選んだもの（spikes/findings-reranker.md）。
    ///
    /// 10 層・256 次元で ruri-v3-30m と同じ形。MIT。
    /// 質の王者は 310m だが 1 問あたり秒級になり、押すたびには重い。
    static let defaultName = "japanese-reranker-xsmall-v2-coreml"

    /// 埋め込みと同じ棚に置く。取り替えるときの手順を 2 つに割らない。
    static var directory: URL { EmbeddingModelStore.directory }

    /// 手元に入っているもの。無ければ nil。
    ///
    /// **束と、分類頭の印まで見る。** 埋め込みの束を名前だけ変えて置かれると、
    /// 出力に score が無いまま使う段まで進んでしまう。
    static func installed(_ name: String = defaultName) -> RerankerModel? {
        let place = directory.appendingPathComponent(name, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []
        guard names.contains(where: { $0.hasPrefix("buckets-") && $0.hasSuffix(".mlpackage") }),
              names.contains("tokenizer.json"), isClassifier(place)
        else { return nil }
        return RerankerModel(directory: place)
    }

    private static func isClassifier(_ directory: URL) -> Bool {
        let url = directory.appendingPathComponent("choro-head.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["head"] as? String) == "classifier"
    }
}
