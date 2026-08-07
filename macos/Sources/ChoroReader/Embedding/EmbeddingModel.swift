import Foundation

/// 意味の層が使うモデル一式の置き場所。
///
/// 中身は Core ML のバンドル、トークナイザ、寸法の書かれた config で、
/// kohagi の `coreml-convert` が作って Hugging Face Hub に置いたものと同じ形である
/// （spec-local-ai.md 第 4.7 節）。アプリは成果物を使うだけで、変換はしない。
///
/// ```text
/// <置き場所>/
///   tokenizer.json                        語彙。3 つの大きさで同一
///   config.json                           hidden_size を読む
///   1_Pooling/config.json                 平均を取るか先頭を取るか
///   buckets-64-128-256-512.mlpackage      長さごとの固定形。1 つの束に入る
///   （または seq-64.mlpackage … 個別の形）
/// ```
struct EmbeddingModel {
    let directory: URL

    var tokenizerURL: URL { directory.appendingPathComponent("tokenizer.json") }
    var configURL: URL { directory.appendingPathComponent("config.json") }
    var poolingURL: URL { directory.appendingPathComponent("1_Pooling/config.json") }

    /// ベクトルの次元。`config.json` の `hidden_size`。
    ///
    /// **この値はモデル自身とは結び付いていない。** 別の checkpoint の config を
    /// 置くと、間違った幅で平均を取った値が黙って出る。読み込みのときに
    /// モデルの出力の形と突き合わせる（kohagi の `check_io` と同じ考え方）。
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

    /// 用途ごとの接頭辞。Ruri v3 はこれを付ける前提で学習されている。
    enum Prefix: String {
        /// 索引に載せる本文。関連箇所（本文どうしの比較）も両側これで揃える。
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
