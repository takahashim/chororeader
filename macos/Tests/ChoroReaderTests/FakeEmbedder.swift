import Foundation
@testable import ChoroReader

/// 決定的な偽の埋め込み器。
///
/// **実物を使う検査は、モデルが手元に無ければ飛ぶ。** それでは配管が守られない。
/// 単位の切り出し・sidecar の失効・候補から原文への解決・Locator の往復は、
/// 埋め込みの中身とは無関係に決まるので、偽物で固められる（spec-local-ai.md 第 8 章の 1）。
///
/// 同じ文からは必ず同じベクトルが出る。似た文が近くなるようには**作っていない**。
/// そこは評価セット（第 8 章の 2）の仕事で、こちらの役目ではない。
struct FakeEmbedder: Embedding {
    let dimension: Int
    let maximumTokens: Int

    init(dimension: Int = 8, maximumTokens: Int = 64) {
        self.dimension = dimension
        self.maximumTokens = maximumTokens
    }

    func embed(_ text: String, as prefix: EmbeddingModel.Prefix) throws
        -> (vector: [Float], truncated: Bool) {
        // 接頭辞まで含めて数える。付け忘れが結果に出るようにしておく。
        let whole = prefix.rawValue + text
        // 長さは文字で数える。実物はトークンだが、切り詰めの筋が通ればよい。
        let truncated = whole.count > maximumTokens
        let used = truncated ? String(whole.prefix(maximumTokens)) : whole

        // 文字を次元へばらまく。同じ文なら必ず同じ向きになる。
        var vector = [Float](repeating: 0, count: dimension)
        for (at, scalar) in used.unicodeScalars.enumerated() {
            vector[Int(scalar.value) % dimension] += Float((at % 7) + 1)
        }
        var squared: Double = 0
        for value in vector { squared += Double(value) * Double(value) }
        let norm = Float(squared.squareRoot())
        if norm > 0 {
            for at in vector.indices { vector[at] /= norm }
        } else {
            vector[0] = 1   // 空でも単位ベクトルを返す
        }
        return (vector, truncated)
    }
}
