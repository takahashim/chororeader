using System.IO;
using System.Reflection;

namespace ChoroReader.App;

/// <summary>
/// 同梱の見本書籍。
///
/// <para>
/// 書籍を 1 冊も持たないマシンでも、アプリだけで読み方と機能を確かめられるようにする。
/// macOS 版も同じ 3 つを束に入れている（Samples.swift）。
/// </para>
/// <para>
/// 実行ファイルの中にあるものはそのままでは開けないので、作業場所へ写してから渡す。
/// </para>
/// </summary>
internal static class Samples
{
    /// <summary>並べる順。読み方の違いが分かるよう、形式の違う 3 つにしてある。</summary>
    internal static readonly string[] Names =
    [
        "sample-reflowable.epub",
        "sample-fixed.epub",
        "sample.pdf",
    ];

    private static string Directory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChoroReader", "samples");

    /// <summary>写し出して、開ける経路にする。写せなければ飛ばす。</summary>
    internal static IReadOnlyList<string> CopyOut()
    {
        var made = new List<string>();
        foreach (var name in Names)
        {
            if (CopyOut(name) is { } path)
            {
                made.Add(path);
            }
        }
        return made;
    }

    internal static string? CopyOut(string name)
    {
        try
        {
            using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
            if (source is null)
            {
                return null;
            }

            System.IO.Directory.CreateDirectory(Directory);
            var destination = Path.Combine(Directory, name);

            // 版が変わったら写し直す。大きさが同じなら中身も同じとみなす。
            if (!File.Exists(destination) || new FileInfo(destination).Length != source.Length)
            {
                using var into = File.Create(destination);
                source.CopyTo(into);
            }
            return destination;
        }
        catch (Exception)
        {
            return null; // 写せなくても、手元の書籍は開ける。
        }
    }
}
