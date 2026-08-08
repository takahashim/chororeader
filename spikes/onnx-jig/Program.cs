using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

// 自作の変換器が吐いた ONNX を、**本家の読み手**に開かせる治具。
//
// ChoroConvert の検査は、組んだ bytes を検査側の読み手でほどいているだけなので、
// 番号を写し間違えていても自分では気付けない。開けるかどうかは ONNX Runtime に聞く。
// MIL の組み立てを coremltools で見ているのと同じ形である
// （macos/Tests/ChoroConvertTests/README.md）。
//
// **Swift からは ONNX Runtime を回せない**ので、こちら側に置く。
// probe には入れない。あれは突き合わせに使うので、native を抱えさせたくない。
//
//   dotnet run -- <model.onnx> [--run]
//
// 毎回は回さない。組み立てを変えたときに 1 度通す。

if (args.Length < 1)
{
    Console.Error.WriteLine("使い方: dotnet run -- <model.onnx> [--run]");
    return 2;
}

using var session = new InferenceSession(args[0]);

Console.WriteLine("入口:");
foreach (var (name, meta) in session.InputMetadata)
{
    Console.WriteLine($"  {name}: {meta.ElementType.Name}[{string.Join(",", meta.Dimensions)}]");
}
Console.WriteLine("出口:");
foreach (var (name, meta) in session.OutputMetadata)
{
    Console.WriteLine($"  {name}: {meta.ElementType.Name}[{string.Join(",", meta.Dimensions)}]");
}

if (!args.Contains("--run"))
{
    return 0;
}

// 回してみる。形だけ合っていて中身が空、を捕まえる。
// 入口の名前で入れるものを決める。トークンの列を要るものは、それらしい値を入れる。
var feeds = new List<NamedOnnxValue>();
foreach (var (name, meta) in session.InputMetadata)
{
    var shape = meta.Dimensions.Select(d => d < 0 ? 2 : d).ToArray();
    var count = shape.Aggregate(1, (a, b) => a * b);

    if (meta.ElementType == typeof(long))
    {
        var made = new DenseTensor<long>(shape);
        for (var at = 0; at < count; at++)
        {
            // input_ids は語彙の範囲に収める。mask は立てる。
            made.SetValue(at, name.Contains("mask") ? 1 : at + 1);
        }
        feeds.Add(NamedOnnxValue.CreateFromTensor(name, made));
    }
    else
    {
        var made = new DenseTensor<float>(shape);
        for (var at = 0; at < count; at++)
        {
            made.SetValue(at, (at + 1) * 10f);
        }
        feeds.Add(NamedOnnxValue.CreateFromTensor(name, made));
    }
}

using var result = session.Run(feeds);
foreach (var one in result)
{
    // 出口の型はグラフによる。fp16 で通すものもあれば、出口だけ fp32 に戻すものもある。
    var values = one.ElementType == TensorElementType.Float16
        ? one.AsEnumerable<Float16>().Take(8).Select(v => ((float)v).ToString("F4"))
        : one.AsEnumerable<float>().Take(8).Select(v => v.ToString("F4"));
    Console.WriteLine($"{one.Name} = {string.Join(", ", values)} …");
}
return 0;
