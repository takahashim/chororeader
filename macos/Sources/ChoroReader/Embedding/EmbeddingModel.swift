import Foundation

struct EmbeddingModel {
    let directory: URL

    var tokenizerURL: URL { directory.appendingPathComponent("tokenizer.json") }
    var configURL: URL { directory.appendingPathComponent("config.json") }
    var poolingURL: URL { directory.appendingPathComponent("1_Pooling/config.json") }

    func dimension() throws -> Int {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL))
        guard let dict = json as? [String: Any], let hidden = dict["hidden_size"] as? Int
        else { throw Failure.cannotRead("config.json に hidden_size がありません") }
        return hidden
    }

    /// 平均を取るか、先頭のトークンだけを取るか。
    /// **モデル自身の申告に従う。** こちらで決めると checkpoint ごとに食い違う。
    func pooling() -> Pooling {
        guard let data = try? Data(contentsOf: poolingURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .mean }   // 申告が無ければ平均。Ruri v3 はこちら
        if (dict["pooling_mode_cls_token"] as? Bool) == true { return .cls }
        return .mean
    }

    enum Prefix: String {
        case document = "検索文書: "
        /// 引くための問い。
        case query = "検索クエリ: "
    }

    enum Pooling {
        case mean
        case cls
    }

    enum Failure: Error, LocalizedError {
        case cannotRead(String)

        var errorDescription: String? {
            switch self {
            case let .cannotRead(why): return "モデルを読めません：\(why)"
            }
        }
    }
}

protocol Embedding {
    var dimension: Int { get }
    /// これを超えたら頭から切り詰める。
    var maximumTokens: Int { get }
    func embed(_ text: String, as prefix: EmbeddingModel.Prefix) throws -> (vector: [Float], truncated: Bool)
}
