using System.Text;
using ChoroReader.Convert;

// モデルを ONNX へ変換する。**Windows でも macOS でも同じ道具で回る。**
//
// Swift 側の choro-convert は Core ML の変換に Apple の枠組みが要るが、
// ONNX の方は .NET だけで足りる。Windows しか持たない人が配り物を自分で
// 作り直せるように、こちらへ置いた。
//
// 入口だけ。中身は同じ組物のほかのファイルにあり、そちらは検査から触れる。

// 日本語が化けると読めない。標準出力を UTF-8 にしてから書く。
Console.OutputEncoding = Encoding.UTF8;

const string usage = """
    使い方：
      choro-convert --model-path <model.safetensors> --config-path <config.json>
                    --out-dir <置き場所> [--max-sequence 2048]

      --max-sequence  rope の表を焼く長さ。既定 2048。
                      **ここを越える入力は通らない。**読む側（OnnxEmbedder）と揃える

    checkpoint のそばに tokenizer.json があれば、出来上がりのそばへ写す
    （アプリはその 2 つを同じ場所から読む）。
    """;

string? Value(string name)
{
    var at = Array.IndexOf(args, name);
    return at >= 0 && at + 1 < args.Length ? args[at + 1] : null;
}

if (Value("--model-path") is not { } modelPath
    || Value("--config-path") is not { } configPath
    || Value("--out-dir") is not { } outDir)
{
    Console.Out.WriteLine(usage);
    return 2;
}

try
{
    var limit = int.TryParse(Value("--max-sequence"), out var given) ? given : 2048;
    var config = new EncoderConfig(File.ReadAllText(configPath));
    using var weights = new Safetensors(modelPath);

    Console.Out.WriteLine($"変換します：層 {config.Layers}・幅 {config.Hidden} ／ ONNX・最大 {limit}");

    var made = new OnnxEncoder(config, weights, limit).Convert();

    var onnx = Path.Combine(outDir, "onnx");
    Directory.CreateDirectory(onnx);
    File.WriteAllBytes(Path.Combine(onnx, "model.onnx"), made.Model);

    // checkpoint のそばにあるものを、出来上がりのそばへ写す。アプリが要る。
    var beside = Path.GetDirectoryName(Path.GetFullPath(modelPath))!;
    foreach (var name in new[] { "tokenizer.json", "config.json" })
    {
        var from = Path.Combine(beside, name);
        if (File.Exists(from))
        {
            File.Copy(from, Path.Combine(outDir, name), overwrite: true);
        }
    }

    Console.Out.WriteLine($"書きました：{Path.GetFullPath(outDir)}");
    Console.Out.WriteLine($"  onnx/model.onnx {made.Model.Length / 1048576.0:F1} MB");
    if (made.Unused.Count > 0)
    {
        // **読まなかった重みは黙らない。** 取りこぼしたまま通る形だからである。
        Console.Out.WriteLine($"  読まなかった重み {made.Unused.Count} 個："
            + string.Join(", ", made.Unused.Take(5)) + "…");
    }
    return 0;
}
catch (Exception error)
{
    await Console.Error.WriteLineAsync(error.Message);
    return 1;
}
