namespace ChoroReader.Tests;

/// <summary>
/// 検査に使うファイルの置き場所。
/// 実行ファイルは bin/ の下に置かれるので、リポジトリの根まで遡って探す。
/// </summary>
internal static class TestPaths
{
    /// <summary>リポジトリに入っている見本の PDF。実書籍は共有しないため、これで確かめる。</summary>
    internal static string SamplePdf => Path.Combine(Root, "samples", "sample.pdf");

    /// <summary>
    /// 突き合わせ用の合成 EPUB。生成物なので追跡していない。
    ///
    /// <para>
    /// <b>無ければ検査は落ちる。飛ばさない。</b>索引の不変条件はここでしか押さえていないので、
    /// 黙って飛ばすと「作り忘れた環境では誰も確かめていない」状態が続く。
    /// 先に conformance で <c>bundle exec ruby choroconf generate</c> を走らせること
    /// （CI もそうしている）。
    /// </para>
    /// </summary>
    internal static string Fixture(string name) =>
        Path.Combine(Root, "conformance", "fixtures", name);

    private static string Root { get; } = FindRoot();

    private static string FindRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "samples", "sample.pdf")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException("リポジトリの根が見つかりません（samples/sample.pdf を目印にしています）");
    }
}
