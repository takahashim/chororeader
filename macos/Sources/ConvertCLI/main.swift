import ChoroConvert
import Foundation

// 実行体は入口だけを持つ。中身は ChoroConvert 側にあり、そちらは検査から触れる。
setvbuf(stdout, nil, _IOLBF, 0)

func value(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let at = arguments.firstIndex(of: name), at + 1 < arguments.count else { return nil }
    return arguments[at + 1]
}

let usage = """
使い方：
  choro-convert --model-id <名前> --out-dir <置き場所> [--sequence-lengths 64,128,…]
  choro-convert --model-path <model.safetensors> --config-path <config.json> \\
                --out-dir <置き場所> [--sequence-lengths …]

  --format            coreml（既定）か onnx。onnx はバケットを取らない
                      （長さが動くので、要らない）
  --sequence-lengths  バケットの長さ。既定は埋め込みが 64,128,256,512,1024,2048、
                      reranker が 256,512
  --max-sequence      onnx のとき、rope の表を焼く長さ。既定 2048
  --cache             取ってきたものの置き場所（既定：~/Library/Caches/ChoroConvert）

頭（埋め込みか reranker か）は config.json の architectures から判る。
"""

guard let outDir = value("--out-dir") else {
    print(usage)
    exit(2)
}
let output = URL(fileURLWithPath: outDir)

do {
    let materials: HubFetch.Materials
    if let modelId = value("--model-id") {
        let cache = value("--cache").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ChoroConvert", isDirectory: true)
        materials = try HubFetch.materials(for: modelId, into: cache) { print("  \($0)") }
    } else if let modelPath = value("--model-path"), let configPath = value("--config-path") {
        materials = HubFetch.local(weights: URL(fileURLWithPath: modelPath),
                                   config: URL(fileURLWithPath: configPath))
    } else {
        print(usage)
        exit(2)
    }

    let config = try EncoderConfig(json: String(contentsOf: materials.config, encoding: .utf8))
    let weights = try Safetensors(contentsOf: materials.weights)

    if value("--format") == "onnx" {
        // **ONNX はバケットを取らない。** 長さが動くので、焼き分ける理由が無い。
        let limit = value("--max-sequence").flatMap { Int($0) } ?? 2048
        print("変換します：\(config.isClassifier ? "reranker" : "埋め込み")"
            + "（層 \(config.layers)・幅 \(config.hidden)）／ ONNX・最大 \(limit)")

        let made = try ONNXEncoder(config: config, weights: weights,
                                   maximumSequence: limit).convert()
        try FileManager.default.createDirectory(at: output.appendingPathComponent("onnx"),
                                                withIntermediateDirectories: true)
        try made.model.write(to: output.appendingPathComponent("onnx/model.onnx"))
        try HubFetch.place(materials, beside: output)
        try HeadMarker.write(classifier: config.isClassifier, to: output)

        print("書きました：\(output.path)")
        print(String(format: "  onnx/model.onnx %.1f MB", Double(made.model.count) / 1048576))
        if !made.unused.isEmpty {
            // **読まなかった重みは黙らない。** 取りこぼしたまま通る形だからである。
            print("  読まなかった重み \(made.unused.count) 個："
                + made.unused.prefix(5).joined(separator: ", ") + "…")
        }
        exit(0)
    }

    // バケットの既定は頭で変える。reranker は問いと本文の組なので短くてよい。
    let lengths = (value("--sequence-lengths")
        ?? (config.isClassifier ? "256,512" : "64,128,256,512,1024,2048"))
        .split(separator: ",").compactMap { Int($0) }

    print("変換します：\(config.isClassifier ? "reranker" : "埋め込み")"
        + "（層 \(config.layers)・幅 \(config.hidden)）／ バケット \(lengths.sorted())")

    let made = try EncoderConverter(config: config, weights: weights).convert(lengths: lengths)

    let name = "buckets-" + lengths.sorted().map(String.init).joined(separator: "-") + ".mlpackage"
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try ModelPackage.write(made.model, weights: made.blob,
                           to: output.appendingPathComponent(name))
    try HubFetch.place(materials, beside: output)
    try HeadMarker.write(classifier: config.isClassifier, to: output)

    print("書きました：\(output.path)")
    print(String(format: "  model.mlmodel %.2f MB / weight.bin %.1f MB",
                 Double(made.model.data.count) / 1048576, Double(made.blob.count) / 1048576))
    if !made.unused.isEmpty {
        // **読まなかった重みは黙らない。** 取りこぼしたまま通る形だからである。
        print("  読まなかった重み \(made.unused.count) 個："
            + made.unused.prefix(5).joined(separator: ", ") + "…")
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
