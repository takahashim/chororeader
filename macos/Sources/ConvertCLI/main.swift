import ChoroConvert
import Foundation

// 実行体は入口だけを持つ。中身は ChoroConvert 側にあり、そちらは検査から触れる。
setvbuf(stdout, nil, _IOLBF, 0)

func value(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let at = arguments.firstIndex(of: name), at + 1 < arguments.count else { return nil }
    return arguments[at + 1]
}

guard let modelPath = value("--model-path"), let configPath = value("--config-path"),
      let outDir = value("--out-dir") else {
    print("""
    使い方：
      choro-convert --model-path <model.safetensors> --config-path <config.json> \\
                    --sequence-lengths 64,128,256,512 --out-dir <置き場所>
    """)
    exit(2)
}
let lengths = (value("--sequence-lengths") ?? "64,128,256,512")
    .split(separator: ",").compactMap { Int($0) }

do {
    let config = try EncoderConfig(json: String(contentsOfFile: configPath, encoding: .utf8))
    let weights = try Safetensors(contentsOf: URL(fileURLWithPath: modelPath))
    let made = try EncoderConverter(config: config, weights: weights).convert(lengths: lengths)

    let name = "buckets-" + lengths.sorted().map(String.init).joined(separator: "-") + ".mlpackage"
    let out = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir),
                                            withIntermediateDirectories: true)
    try ModelPackage.write(made.model, weights: made.blob, to: out)

    print("書きました：\(out.path)")
    print(String(format: "  model.mlmodel %.2f MB / weight.bin %.1f MB",
                 Double(made.model.data.count) / 1048576, Double(made.blob.count) / 1048576))
    if !made.unused.isEmpty {
        // **読まなかった重みは黙らない。** 取りこぼしたまま通る形だからである。
        print("  読まなかった重み \(made.unused.count) 個：\(made.unused.prefix(5).joined(separator: ", "))…")
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
