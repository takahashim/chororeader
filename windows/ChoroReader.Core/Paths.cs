using System.Text;

namespace ChoroReader.Core;

/// <summary>
/// EPUB 内の参照の扱い。macOS 版と同じ結果を返す必要がある（conformance/CONTRACT.md）。
/// </summary>
public static class Paths
{
    /// <summary>
    /// 相対参照を、アーカイブ先頭からのパスへ正規化する。
    /// 区切りは常に "/"。Windows の Path.Combine は使わない。
    /// </summary>
    public static string Resolve(string basePath, string href)
    {
        var decoded = PercentDecode(href);
        if (decoded.StartsWith('/'))
        {
            return decoded[1..];
        }

        var components = new List<string>();
        if (!string.IsNullOrEmpty(basePath))
        {
            components.AddRange(basePath.Split('/', StringSplitOptions.RemoveEmptyEntries));
        }

        foreach (var part in decoded.Split('/'))
        {
            if (part.Length == 0 || part == ".")
            {
                continue;
            }
            if (part == "..")
            {
                // 先頭で頭打ちにする。アーカイブの外へは出られない。
                if (components.Count > 0)
                {
                    components.RemoveAt(components.Count - 1);
                }
                continue;
            }
            components.Add(part);
        }

        return string.Join('/', components);
    }

    /// <summary>参照から fragment を切り離す。</summary>
    public static (string Path, string? Fragment) StripFragment(string href)
    {
        var hash = href.IndexOf('#');
        if (hash < 0)
        {
            return (href, null);
        }
        var fragment = href[(hash + 1)..];
        return (href[..hash], fragment.Length == 0 ? null : fragment);
    }

    /// <summary>
    /// パーセント符号を解く。解けない並びはそのまま残す。
    /// Uri.UnescapeDataString は不正な並びで例外を投げうるため自前で処理する。
    /// </summary>
    public static string PercentDecode(string value)
    {
        if (!value.Contains('%'))
        {
            return value;
        }

        var bytes = new List<byte>(value.Length);
        for (var i = 0; i < value.Length; i++)
        {
            if (value[i] == '%' && i + 2 < value.Length
                && Uri.IsHexDigit(value[i + 1]) && Uri.IsHexDigit(value[i + 2]))
            {
                bytes.Add(Convert.ToByte(value.Substring(i + 1, 2), 16));
                i += 2;
            }
            else
            {
                bytes.AddRange(Encoding.UTF8.GetBytes(value[i].ToString()));
            }
        }
        return Encoding.UTF8.GetString(bytes.ToArray());
    }

    /// <summary>
    /// macOS は分解形（NFD）を返すことがあり Windows は合成形。比較のため NFC へ揃える。
    /// </summary>
    public static string Normalize(string value) => value.Normalize(NormalizationForm.FormC);
}
