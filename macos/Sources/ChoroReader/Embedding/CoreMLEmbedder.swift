import Accelerate
import CoreML
import Foundation

@available(macOS 15, *)
final class CoreMLEmbedder: Embedding {
    private let tokenizer: UnigramTokenizer
    private let pooling: EmbeddingModel.Pooling
    private let buckets: BucketBundle
    let dimension: Int

    init(model: EmbeddingModel) throws {
        tokenizer = try UnigramTokenizer(contentsOf: model.tokenizerURL)
        let width = try model.dimension()
        dimension = width
        pooling = model.pooling()
        buckets = try BucketBundle(directory: model.directory) { loaded, length in
            try Self.check(loaded, length: length, dimension: width)
        }
    }

    var maximumTokens: Int { buckets.maximumTokens }

    // MARK: - 埋め込む

    /// 1 本のベクトルにする。長さが最大のバケットを越えたら**頭から切り詰める**。
    ///
    /// 切り詰めは黙って行う。切れたかどうかは `truncated` で返し、
    /// 呼ぶ側が単位の割り方を見直せるようにする。
    func embed(_ text: String, as prefix: EmbeddingModel.Prefix) throws -> (vector: [Float], truncated: Bool) {
        var ids = tokenizer.encode(prefix.rawValue + text)
        let truncated = ids.count > maximumTokens
        if truncated {
            // 末尾の </s> は残す。前処理の形を崩さない。
            let last = ids.last
            ids = Array(ids.prefix(maximumTokens))
            if let last { ids[ids.count - 1] = last }
        }
        let made = try buckets.predict(ids, output: "hidden")
        var vector = pool(made.values, mask: made.mask)
        normalize(&vector)
        return (vector, truncated)
    }

    private func pool(_ hidden: [Float], mask: [Int32]) -> [Float] {
        switch pooling {
        case .cls:
            return Array(hidden.prefix(dimension))
        case .mean:
            var sum = [Float](repeating: 0, count: dimension)
            var count: Float = 0
            for (token, keep) in mask.enumerated() where keep != 0 {
                let from = token * dimension
                guard from + dimension <= hidden.count else { break }
                hidden.withUnsafeBufferPointer { source in
                    vDSP_vadd(sum, 1, source.baseAddress! + from, 1, &sum, 1, vDSP_Length(dimension))
                }
                count += 1
            }
            if count > 0 { vDSP_vsdiv(sum, 1, &count, &sum, 1, vDSP_Length(dimension)) }
            return sum
        }
    }

    private func normalize(_ vector: inout [Float]) {
        var squared = 0.0
        for value in vector { squared += Double(value) * Double(value) }
        let norm = Float(squared.squareRoot())
        guard norm > 0 else { return }
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &vector, 1, vDSP_Length(vector.count))
    }

    // MARK: - 読み込みの検査

    private static func check(_ model: MLModel, length: Int, dimension: Int) throws {
        try BucketBundle.checkInputs(model, length: length)
        let shape = try BucketBundle.outputShape(model, named: "hidden", length: length)
        guard shape.count == 3 else { return }
        guard shape[1] == length else {
            throw BucketBundle.Failure.shapeMismatch("seq-\(length) と名乗るが、実際は \(shape[1]) 長")
        }
        guard shape[2] == dimension else {
            throw BucketBundle.Failure.shapeMismatch(
                "config.json は \(dimension) 次元だが、モデルは \(shape[2]) 次元")
        }
    }
}
