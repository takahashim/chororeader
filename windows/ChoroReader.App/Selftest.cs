using System.Text.Json;
using System.Text.Json.Nodes;

namespace ChoroReader.App;

/// <summary>
/// 窓の中を、目で見ずに確かめる。
///
/// <para>
/// 開発機は macOS で、実行できるのは Windows だけである。
/// 画面を見られない相手（CI と、コンソールから開発する者）が合否を読めるように、
/// 判定をアプリ自身に持たせる。結果は JSON で標準出力へ書き、終了コードにも出す。
/// </para>
/// <para>
/// <b>窓の数だけを見ていては、枠だけ出来て中身が空の状態を捕まえられない。</b>
/// 本文が名乗るところまで見る（spikes/findings-tauri.md）。
/// </para>
/// </summary>
internal static class Selftest
{
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(20);

    internal static async Task<int> RunAsync(ReaderWindow window)
    {
        var result = new JsonObject();
        var checks = new JsonArray();
        var passed = true;

        void Check(string what, bool ok, string? detail = null)
        {
            passed &= ok;
            checks.Add(new JsonObject
            {
                ["what"] = what,
                ["ok"] = ok,
                ["detail"] = detail,
            });
        }

        try
        {
            // 1 章目。開いた直後に待ちが仕掛かっている。
            Check("最初の章が名乗った", await window.WaitForReadyAsync(Deadline));
            Check("本文が空でない", window.ReadyCount > 0, $"ReadyCount={window.ReadyCount}");

            // 章を送って、名乗り直すこと。枠だけ出来る不具合はここで出る。
            var before = window.ReadyCount;
            await window.MoveAsync(1);
            var moved = await window.WaitForReadyAsync(Deadline);
            Check("次の章が名乗った", moved);
            Check("名乗りが増えた", window.ReadyCount > before,
                  $"{before} → {window.ReadyCount}");

            // 戻れること。
            await window.MoveAsync(-1);
            Check("前の章へ戻れた", await window.WaitForReadyAsync(Deadline));
        }
        catch (Exception e)
        {
            passed = false;
            result["error"] = e.ToString();
        }

        result["checks"] = checks;
        result["passed"] = passed;
        Console.Out.WriteLine(result.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        }));

        return passed ? 0 : 1;
    }
}
