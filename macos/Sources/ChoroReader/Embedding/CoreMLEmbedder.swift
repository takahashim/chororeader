import Accelerate
import CoreML
import Foundation

/// 本文を 1 本のベクトルにする。Core ML を Apple Neural Engine で動かす。
///
/// ANE は**形の決まった入力**しか受け付けない。そこで長さごとに固定形のモデルを
/// 用意し、収まる最小のものへ詰めて渡す（バケット）。
/// 変換物は kohagi の `coreml-convert` が作ったもので、
/// 128/256/512 のような長さが 1 つの束（multi-function）に入っている。
///
/// **multi-function は macOS 15 以降でしか選べない**（`MLModelConfiguration.functionName`）。
/// 意味の層は段階制で、下の段は上が無くても成立するので（spec-local-ai.md 第 3 章）、
/// この層だけを 15 以降に限る。個別形にすると 264 MB が 794 MB になる。
///
/// 出力の並べ方・詰め方・平均の取り方は kohagi と揃える。ずれると黙って違う
/// ベクトルが出るので、cosine の一致を検査で固める。
@available(macOS 15, *)
final class CoreMLEmbedder {
    private let tokenizer: UnigramTokenizer
    private let model: EmbeddingModel
    private let pooling: EmbeddingModel.Pooling
    /// 束が担う長さ。短い順。**開くのは使うときで、ここでは名前だけ持つ。**
    private let lengths: [Int]
    private let package: URL
    /// 組み直した束。1 度組んだら使い回す。
    private var compiled: URL?
    /// 開いたバケット。長さごとに 1 つ。
    private var opened: [Int: MLModel] = [:]
    /// **開く仕事は書き換えを伴う。** 索引作りは裏で走り、問いは前で走るので、
    /// 同じ埋め込み器が両方から呼ばれる。閂を掛ける。
    /// （全部を init で開いていた頃は、後は読むだけだったので要らなかった）
    private let gate = NSLock()
    let dimension: Int

    /// 束の中で、その長さを担う function の名前。
    /// **変換器の名付けと揃える**（kohagi の `function_name`）。
    private static func functionName(_ length: Int) -> String { "seq_\(length)" }

    enum Failure: Error, LocalizedError {
        case noBuckets(String)
        case shapeMismatch(String)

        var errorDescription: String? {
            switch self {
            case let .noBuckets(why): return "埋め込みのモデルを読めません：\(why)"
            case let .shapeMismatch(why): return "モデルの形が合いません：\(why)"
            }
        }
    }

    init(model: EmbeddingModel) throws {
        self.model = model
        tokenizer = try UnigramTokenizer(contentsOf: model.tokenizerURL)
        dimension = try model.dimension()
        pooling = model.pooling()

        let found = try Self.bucketLengths(in: model.directory)
        guard !found.bundle.isEmpty else {
            throw Failure.noBuckets("buckets-… の束が \(model.directory.lastPathComponent) にありません")
        }
        package = found.url
        lengths = found.bundle.sorted()
    }

    /// その長さを担うバケット。**まだ開いていなければ、ここで開く。**
    ///
    /// バケットは 1 つ開くのに 440 ms ほどかかり、**長さには依らない**（実測）。
    /// 6 つ揃えて起動時に開くと 4 秒待たされるが、1 回の埋め込みが使うのは 1 つだけである。
    /// 問いを引くだけなら短いバケット 1 つで足りるので、使うときに開く。
    ///
    /// 形の検査（`check`）も開いたときに回る。読み込みで先に落とせなくなる代わりに、
    /// 使う前には必ず通る。
    private func bucket(for length: Int) throws -> (length: Int, model: MLModel)? {
        guard let fits = lengths.first(where: { $0 >= length }) else { return nil }
        gate.lock()
        defer { gate.unlock() }
        if let already = opened[fits] { return (fits, already) }

        // `.mlpackage` はそのままでは読めない。組み直したものを置いておく。
        let ready = try compiled ?? Self.compiled(package)
        compiled = ready

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.functionName = lengths.count > 1 ? Self.functionName(fits) : nil
        let loaded = try MLModel(contentsOf: ready, configuration: configuration)
        try Self.check(loaded, length: fits, dimension: dimension)
        opened[fits] = loaded
        return (fits, loaded)
    }

    /// 組み直した束。**1 度組んだら置いておく。**
    ///
    /// `.mlpackage` は配る形で、Core ML はそのままでは読めない。組み直しに
    /// 1 束あたり 20 秒ほどかかるので、毎回払うわけにいかない。
    /// 元の束が入れ替わったら組み直す（大きさと更新日時で見る）。
    private static func compiled(_ package: URL) throws -> URL {
        let cache = try cacheDirectory()
        let stamp = try Self.stamp(of: package)
        let target = cache.appendingPathComponent("\(package.lastPathComponent)-\(stamp).mlmodelc")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        let made = try compileResolvingLinks(package)
        // 置き換えは一息で行う。途中で落ちた組みかけを次回掴まない。
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: made, to: target)
        } catch {
            return made   // 置けなくても、この場では使える
        }
        // 古い版は捨てる。モデルを入れ替えるたびに 264 MB が積み上がる。
        let others = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        for name in others
        where name.hasPrefix(package.lastPathComponent) && name != target.lastPathComponent {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent(name))
        }
        return target
    }

    /// 組み直す。**符号の連なり（symlink）は先に解いておく。**
    ///
    /// Hugging Face の置き場所は実体を blobs/ に置き、snapshots/ から符号で指す作りで、
    /// Core ML のコンパイラはこれを辿れない（weight.bin が「存在しません」になる）。
    /// そのままで通ればそれでよく、駄目なら実体を写してから組む。
    private static func compileResolvingLinks(_ package: URL) throws -> URL {
        if let made = try? MLModel.compileModel(at: package) { return made }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChoroReader-CoreML-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let copy = staging.appendingPathComponent(package.lastPathComponent)
        try copyResolvingLinks(from: package, to: copy)
        return try MLModel.compileModel(at: copy)
    }

    /// 符号を解きながら写す。中身は 264 MB あるので、要るときだけ通る道にする。
    private static func copyResolvingLinks(from source: URL, to target: URL) throws {
        let manager = FileManager.default
        let resolved = source.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            for name in try manager.contentsOfDirectory(atPath: resolved.path) {
                try copyResolvingLinks(from: resolved.appendingPathComponent(name),
                                       to: target.appendingPathComponent(name))
            }
        } else {
            try manager.copyItem(at: resolved, to: target)
        }
    }

    private static func cacheDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChoroReader/CoreML", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 束が入れ替わったかを見る印。中身を読まずに済ませる。
    private static func stamp(of package: URL) throws -> String {
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let target = FileManager.default.fileExists(atPath: weights.path) ? weights : package
        let values = try target.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        let modified = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(size)-\(modified)"
    }

    /// 一番長いバケット。切り詰めの上限になる。開かなくても分かる。
    var maximumTokens: Int { lengths.last ?? 0 }

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
        guard let bucket = try bucket(for: ids.count) else {
            throw Failure.noBuckets("\(ids.count) トークンを収めるバケットがありません")
        }

        var input = [Int32](repeating: 0, count: bucket.length)
        var mask = [Int32](repeating: 0, count: bucket.length)
        for (at, id) in ids.enumerated() {
            input[at] = Int32(id)
            mask[at] = 1
        }

        let hidden = try forward(bucket, input: input, mask: mask)
        var vector = pool(hidden, mask: mask)
        normalize(&vector)
        return (vector, truncated)
    }

    private func forward(_ bucket: (length: Int, model: MLModel),
                         input: [Int32], mask: [Int32]) throws -> [Float] {
        let shape = [1, NSNumber(value: bucket.length)] as [NSNumber]
        let ids = try MLMultiArray(shape: shape, dataType: .int32)
        let attention = try MLMultiArray(shape: shape, dataType: .int32)
        input.withUnsafeBufferPointer { source in
            ids.dataPointer.assumingMemoryBound(to: Int32.self)
                .update(from: source.baseAddress!, count: source.count)
        }
        mask.withUnsafeBufferPointer { source in
            attention.dataPointer.assumingMemoryBound(to: Int32.self)
                .update(from: source.baseAddress!, count: source.count)
        }

        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: attention),
        ])
        let out = try bucket.model.prediction(from: features)
        guard let array = out.featureValue(for: "hidden")?.multiArrayValue else {
            throw Failure.shapeMismatch("出力に hidden がありません")
        }
        return Self.readFloats(array)
    }

    /// マスクの立っているトークンだけで平均する。詰めた分は数に入れない。
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

    /// 長さ 1 に揃える。**ノルムは Double で積む**（kohagi の l2_normalize と同じ）。
    /// 単位ベクトルにしておけば、内積がそのまま cosine になる。
    private func normalize(_ vector: inout [Float]) {
        var squared = 0.0
        for value in vector { squared += Double(value) * Double(value) }
        let norm = Float(squared.squareRoot())
        guard norm > 0 else { return }
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &vector, 1, vDSP_Length(vector.count))
    }

    // MARK: - 読み込みの検査

    /// 束の中の 1 つが、こちらの思い込みどおりかを確かめる。
    ///
    /// `config.json` の次元も、名前から取ったバケットの長さも、**モデル自身とは
    /// 結び付いていない**。別の checkpoint のものを置くと、違う幅で平均した値や、
    /// 違う長さに詰めた入力が黙って通る。読み込みのここでしか捕まえられない
    /// （kohagi の `check_io` と同じ考え方）。
    private static func check(_ model: MLModel, length: Int, dimension: Int) throws {
        let description = model.modelDescription
        for name in ["input_ids", "attention_mask"] {
            guard description.inputDescriptionsByName[name] != nil else {
                let have = description.inputDescriptionsByName.keys.sorted().joined(separator: ", ")
                throw Failure.shapeMismatch("seq-\(length) に入力 \(name) がありません（あるのは \(have)）")
            }
        }
        guard let hidden = description.outputDescriptionsByName["hidden"] else {
            let have = description.outputDescriptionsByName.keys.sorted().joined(separator: ", ")
            throw Failure.shapeMismatch("seq-\(length) に出力 hidden がありません（あるのは \(have)）")
        }
        guard let shape = hidden.multiArrayConstraint?.shape, shape.count == 3 else { return }
        let declared = (seq: shape[1].intValue, dim: shape[2].intValue)
        guard declared.seq == length else {
            throw Failure.shapeMismatch("seq-\(length) と名乗るが、実際は \(declared.seq) 長")
        }
        guard declared.dim == dimension else {
            throw Failure.shapeMismatch("config.json は \(dimension) 次元だが、モデルは \(declared.dim) 次元")
        }
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
