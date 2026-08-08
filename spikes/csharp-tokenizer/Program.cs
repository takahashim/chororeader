using System.Text.Json;
using Microsoft.ML.Tokenizers;

// Ruri v3 のトークナイザを C# で持てるか。
//
// **これが Windows 版に意味の層を入れられるかの分かれ目である。**
// 食い違っても例外は出ず、黙って違うベクトルが出るので、使ってみて気付くことができない
// （spec-local-ai.md 4.6、spikes/findings-swift-tokenizer.md）。
//
// 期待値は kohagi（Rust の tokenizers crate）で 1 度作って凍結してあるものを、
// macOS 版の検査からそのまま借りる。例文は架空のもので、実在の書籍からは取っていない。
//
// **読むファイルが macOS 版と違う。** あちらは tokenizer.json（HuggingFace の形）で、
// Microsoft.ML.Tokenizers が読むのは tokenizer.model（SentencePiece の protobuf）である。
// 同じモデルの配り物だが別のファイルなので、同じ ID が出るとは限らない。そこを見る。
//
//   dotnet run -- <tokenizer.model> <ruri-v3-tokenizer.json>

if (args.Length < 2)
{
    Console.Error.WriteLine("使い方: dotnet run -- <tokenizer.model> <期待値の json>");
    return 2;
}

var expected = JsonSerializer.Deserialize<Fixture>(File.ReadAllText(args[1]),
    new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;

// 特殊トークンは渡さないと素通しになる。渡せば消えるのか、それとも別の話なのかを見る。
var special = new Dictionary<string, int>
{
    ["<unk>"] = 0, ["<s>"] = 1, ["</s>"] = 2, ["<pad>"] = 3,
    ["<|system|>"] = 7, ["<|user|>"] = 9, ["<|assistant|>"] = 8,
};

using var model = File.OpenRead(args[0]);
var tokenizer = SentencePieceTokenizer.Create(
    model, addBeginningOfSentence: true, addEndOfSentence: true,
    specialTokens: args.Contains("--special") ? special : null);

Console.WriteLine($"例文 {expected.Cases.Count} 件");

var agreed = 0;
var shown = 0;
foreach (var one in expected.Cases)
{
    var got = tokenizer.EncodeToIds(one.Text);
    if (got.SequenceEqual(one.Ids))
    {
        agreed++;
        continue;
    }
    shown++;
    Console.WriteLine($"""
      食い違い: {Show(one.Text)}
        期待 ({one.Ids.Count}): {string.Join(",", one.Ids.Take(24))}
        C#   ({got.Count}): {string.Join(",", got.Take(24))}
        {Diagnose(one.Ids, got)}
    """);
}

Console.WriteLine($"一致 {agreed} / {expected.Cases.Count}（食い違い {shown}）");

// 速さも見ておく。1 段落は 400 字を狙っている（spec-local-ai.md 4.1）。
var paragraph = string.Concat(Enumerable.Repeat("この段落は速さを測るためのもので、実在の書籍からは取っていない。", 13))[..400];
var watch = System.Diagnostics.Stopwatch.StartNew();
for (var i = 0; i < 1000; i++)
{
    tokenizer.EncodeToIds(paragraph);
}
watch.Stop();
Console.WriteLine($"400 字 1 段落: {watch.Elapsed.TotalMilliseconds / 1000:F3} ms（{tokenizer.EncodeToIds(paragraph).Count} トークン）");

return agreed == expected.Cases.Count ? 0 : 1;

static string Show(string text) =>
    text.Length == 0 ? "（空）"
    : text.Length > 40 ? Escape(text[..40]) + "…"
    : Escape(text);

static string Escape(string text) => text.Replace("\n", "\\n").Replace("\t", "\\t");

/// <summary>
/// 食い違いの形を言う。
///
/// <para>
/// 数だけ見ても直しようがない。<b>ずれ方に規則があるか</b>で、
/// 直せるものか（対応表を挟めば済む）、直せないものか（実装そのものが違う）が分かれる。
/// </para>
/// </summary>
static string Diagnose(List<int> expected, IReadOnlyList<int> got)
{
    if (expected.Count != got.Count)
    {
        return got.Count == 0 ? "→ 何も返っていない" : "→ 長さが違う（切り方そのものが違う）";
    }

    var gaps = expected.Zip(got, (want, have) => have - want).Where(d => d != 0).Distinct().ToList();
    return gaps.Count == 1
        ? $"→ 長さは同じ。食い違う位置はすべて {gaps[0]:+#;-#} ずれている"
        : $"→ 長さは同じ。ずれ方は {gaps.Count} 通り（{string.Join(",", gaps.Take(6))}）";
}

sealed record Fixture(List<Case> Cases);

sealed record Case(string Text, List<int> Ids);
