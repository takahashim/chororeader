import CoreML
import Foundation

/// 問いと本文を**並べて読み**、どれくらい答えているかを 1 つの点にする。
///
/// 埋め込みは問いと本文を別々にベクトルにするので、見えるのは「話題が近いか」までである。
/// こちらは両方を 1 本の並びに詰めて注意を通すので、**話題は合うが中身が違う**候補を落とせる
/// （spikes/findings-reranker.md：上位 3 件に使えるものが 7〜9/15 → 10〜11/15）。
///
/// 値段は埋め込みと逆で、**候補の数だけ推論が要る**。40 件で 160 ms 前後（見積もり）。
/// だから索引は作れない。候補を絞ったあとにだけ通す。
///
/// 束の開き方と詰め方は `BucketBundle` が持つ。ここが受け持つのは
/// **組の詰め方**（`<s> 問い </s><s> 本文 </s>`）と、出口の点である。
@available(macOS 15, *)
final class CrossEncoder {
    private let tokenizer: UnigramTokenizer
    private let buckets: BucketBundle

    init(model: RerankerModel) throws {
        tokenizer = try UnigramTokenizer(contentsOf: model.tokenizerURL)
        buckets = try BucketBundle(directory: model.directory) { loaded, length in
            try Self.check(loaded, length: length)
        }
    }

    var maximumTokens: Int { buckets.maximumTokens }

    /// 組の点。**素の logit をそのまま返す**（参照実装と同じ値）。
    ///
    /// 0〜1 に均すのは見せる側の仕事である。ここで均すと参照実装と突き合わせられない。
    ///
    /// **UI を持つスレッドから呼んではいけない。**
    func score(query: String, passage: String) throws -> Float {
        let ids = tokenizer.encodePair(query, passage, limit: maximumTokens)
        let made = try buckets.predict(ids, output: "score")
        guard let value = made.values.first else {
            throw BucketBundle.Failure.shapeMismatch("score が空です")
        }
        return value
    }

    /// まとめて点を付ける。**返すのは渡した並びのままの点**で、並べ替えはしない。
    ///
    /// 並べ替えを内側でやると「元が何位だったか」を呼ぶ側が持てなくなる。
    /// 効いたかどうかを人に見せるには、その差が要る。
    ///
    /// - Parameter shouldStop: 割り込みが要るときに真を返す。問いが変わったら
    ///   途中で降りる。40 件を最後まで回すと、次の問いが待たされる。
    func scores(query: String, passages: [String],
                shouldStop: () -> Bool = { false }) throws -> [Float]? {
        var made: [Float] = []
        made.reserveCapacity(passages.count)
        for passage in passages {
            if shouldStop() { return nil }
            made.append(try score(query: query, passage: passage))
        }
        return made
    }

    /// 束が思い込みどおりか。**埋め込みの束を名前だけ変えて置かれると、ここで落ちる。**
    private static func check(_ model: MLModel, length: Int) throws {
        try BucketBundle.checkInputs(model, length: length)
        let shape = try BucketBundle.outputShape(model, named: "score", length: length)
        // [1, 1]。列が返るなら分類頭ではない。
        guard shape.isEmpty || shape.reduce(1, *) == 1 else {
            throw BucketBundle.Failure.shapeMismatch("seq-\(length) の score が \(shape) です（1 つのはず）")
        }
    }
}
