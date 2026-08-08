import CoreML
import Foundation

/// 長さごとの固定形をまとめた束（multi-function）。**埋め込みと並べ直しで共有する。**
///
/// ANE は**形の決まった入力**しか受け付けない。そこで長さごとに固定形のモデルを
/// 用意し、収まる最小のものへ詰めて渡す（バケット）。
/// 束の作りは `choro-convert` と kohagi の `coreml-convert` で同じである。
///
/// **multi-function は macOS 15 以降でしか選べない**（`MLModelConfiguration.functionName`）。
/// 意味の層は段階制で、下の段は上が無くても成立するので（spec-local-ai.md 第 3 章）、
/// この層だけを 15 以降に限る。
///
/// 埋め込み器（`CoreMLEmbedder`）と cross-encoder（`CrossEncoder`）は、
/// 入口（トークンの並べ方）と出口（平均を取るか点を読むか）だけが違い、
/// **その間はまったく同じ**である。2 つ目を足すときに写すのをやめ、ここへ出した。
@available(macOS 15, *)
final class BucketBundle {
    /// 束が担う長さ。短い順。**開くのは使うときで、ここでは名前だけ持つ。**
    let lengths: [Int]
    private let package: URL
    /// 開いた束が思い込みどおりかを見る。中身は使う側で違う。
    private let verify: (MLModel, Int) throws -> Void
    /// 組み直した束。1 度組んだら使い回す。
    private var compiled: URL?
    /// 開いたバケット。長さごとに 1 つ。
    private var opened: [Int: MLModel] = [:]
    /// **開く仕事は書き換えを伴う。** 索引作りは裏で走り、問いは前で走るので、
    /// 同じ束が両方から呼ばれる。閂を掛ける。
    private let gate = NSLock()

    /// 束の中で、その長さを担う function の名前。**変換器の名付けと揃える。**
    private static func functionName(_ length: Int) -> String { "seq_\(length)" }

    enum Failure: Error, LocalizedError {
        case noBuckets(String)
        case shapeMismatch(String)

        var errorDescription: String? {
            switch self {
            case let .noBuckets(why): return "モデルを読めません：\(why)"
            case let .shapeMismatch(why): return "モデルの形が合いません：\(why)"
            }
        }
    }

    /// - Parameter verify: 開いたモデルとその長さを受け取り、違えば投げる。
    init(directory: URL, verify: @escaping (MLModel, Int) throws -> Void) throws {
        let found = try Self.bucketLengths(in: directory)
        guard !found.bundle.isEmpty else {
            throw Failure.noBuckets("buckets-… の束が \(directory.lastPathComponent) にありません")
        }
        package = found.url
        lengths = found.bundle.sorted()
        self.verify = verify
    }

    /// 一番長いバケット。切り詰めの上限になる。開かなくても分かる。
    var maximumTokens: Int { lengths.last ?? 0 }

    /// 収まる最小のバケットへ詰めて回す。
    ///
    /// 返すのは求めた出力と、**詰めたマスク**である。マスクは呼ぶ側が
    /// 平均を取るのに要る（詰めた分を数に入れないため）。
    ///
    /// **UI を持つスレッドから呼んではいけない。**
    func predict(_ ids: [Int], output name: String) throws -> (values: [Float], mask: [Int32]) {
        guard let bucket = try bucket(for: ids.count) else {
            throw Failure.noBuckets("\(ids.count) トークンを収めるバケットがありません")
        }
        var input = [Int32](repeating: 0, count: bucket.length)
        var mask = [Int32](repeating: 0, count: bucket.length)
        for (at, id) in ids.enumerated() {
            input[at] = Int32(id)
            mask[at] = 1
        }

        let shape = [1, NSNumber(value: bucket.length)] as [NSNumber]
        let idArray = try MLMultiArray(shape: shape, dataType: .int32)
        let maskArray = try MLMultiArray(shape: shape, dataType: .int32)
        input.withUnsafeBufferPointer { source in
            idArray.dataPointer.assumingMemoryBound(to: Int32.self)
                .update(from: source.baseAddress!, count: source.count)
        }
        mask.withUnsafeBufferPointer { source in
            maskArray.dataPointer.assumingMemoryBound(to: Int32.self)
                .update(from: source.baseAddress!, count: source.count)
        }

        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: idArray),
            "attention_mask": MLFeatureValue(multiArray: maskArray),
        ])
        let out = try bucket.model.prediction(from: features)
        guard let array = out.featureValue(for: name)?.multiArrayValue else {
            throw Failure.shapeMismatch("出力に \(name) がありません")
        }
        return (Self.readFloats(array), mask)
    }

    /// その長さを担うバケット。**まだ開いていなければ、ここで開く。**
    ///
    /// バケットは 1 つ開くのに 440 ms ほどかかり、**長さには依らない**（実測）。
    /// 6 つ揃えて起動時に開くと 4 秒待たされるが、1 回の推論が使うのは 1 つだけである。
    ///
    /// 形の検査（`verify`）も開いたときに回る。読み込みで先に落とせなくなる代わりに、
    /// 使う前には必ず通る。
    private func bucket(for length: Int) throws -> (length: Int, model: MLModel)? {
        guard let fits = lengths.first(where: { $0 >= length }) else { return nil }
        gate.lock()
        defer { gate.unlock() }
        if let already = opened[fits] { return (fits, already) }

        // `.mlpackage` はそのままでは読めない。組み直したものを置いておく。
        let ready = try compiled ?? CompiledBundleCache.compiled(package)
        compiled = ready

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.functionName = lengths.count > 1 ? Self.functionName(fits) : nil
        let loaded = try MLModel(contentsOf: ready, configuration: configuration)
        try verify(loaded, fits)
        opened[fits] = loaded
        return (fits, loaded)
    }

    // MARK: - 読み込みの検査に使う道具

    /// 入力が揃っていること。両方の使い手で同じ 2 つを取る。
    static func checkInputs(_ model: MLModel, length: Int) throws {
        let description = model.modelDescription
        for name in ["input_ids", "attention_mask"] {
            guard description.inputDescriptionsByName[name] != nil else {
                let have = description.inputDescriptionsByName.keys.sorted().joined(separator: ", ")
                throw Failure.shapeMismatch("seq-\(length) に入力 \(name) がありません（あるのは \(have)）")
            }
        }
    }

    /// 名前の付いた出力があること。その形も返す。
    static func outputShape(_ model: MLModel, named name: String, length: Int) throws -> [Int] {
        let description = model.modelDescription
        guard let out = description.outputDescriptionsByName[name] else {
            let have = description.outputDescriptionsByName.keys.sorted().joined(separator: ", ")
            throw Failure.shapeMismatch("seq-\(length) に出力 \(name) がありません（あるのは \(have)）")
        }
        return (out.multiArrayConstraint?.shape ?? []).map(\.intValue)
    }

    /// 置き場所にある束と、それが担う長さ。
    private static func bucketLengths(in directory: URL) throws -> (url: URL, bundle: [Int]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // buckets-64-128-256-512.mlpackage のような名前から長さを読む。
        for name in names.sorted() where name.hasPrefix("buckets-") && name.hasSuffix(".mlpackage") {
            let middle = name.dropFirst("buckets-".count).dropLast(".mlpackage".count)
            let lengths = middle.split(separator: "-").compactMap { Int($0) }
            if !lengths.isEmpty {
                return (directory.appendingPathComponent(name), lengths)
            }
        }
        throw Failure.noBuckets("buckets-… の束が見つかりません")
    }

    private static func readFloats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        var out = [Float](repeating: 0, count: count)
        switch array.dataType {
        case .float32:
            let source = array.dataPointer.assumingMemoryBound(to: Float.self)
            out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: source, count: count) }
        case .float16:
            // ANE の出力は fp16 で返る。Float へ広げる。
            let source = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            for i in 0 ..< count { out[i] = Float(Float16(bitPattern: source[i])) }
        case .double:
            let source = array.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0 ..< count { out[i] = Float(source[i]) }
        default:
            break
        }
        return out
    }
}
