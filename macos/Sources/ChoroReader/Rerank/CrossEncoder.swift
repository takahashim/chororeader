import CoreML
import Foundation

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

    func score(query: String, passage: String) throws -> Float {
        let ids = tokenizer.encodePair(query, passage, limit: maximumTokens)
        let made = try buckets.predict(ids, output: "score")
        guard let value = made.values.first else {
            throw BucketBundle.Failure.shapeMismatch("score が空です")
        }
        return value
    }

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
        guard shape.isEmpty || shape.reduce(1, *) == 1 else {
            throw BucketBundle.Failure.shapeMismatch("seq-\(length) の score が \(shape) です（1 つのはず）")
        }
    }
}
