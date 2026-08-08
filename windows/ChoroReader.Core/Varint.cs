namespace ChoroReader.Core;

/// <summary>
/// 可変長整数。索引の本体も、置き場所を包む覆いも、同じ書き方で読み書きする。
///
/// <para>
/// 数の並びは昇順なので、差分を書けば大半が 1 バイトに収まる。
/// 読む側と書く側が離れると境界の扱いがずれるので、両方をここに置く。
/// </para>
/// </summary>
internal static class Varint
{
    internal static void Put(List<byte> output, ulong value)
    {
        while (true)
        {
            var lower = (byte)(value & 0x7f);
            value >>= 7;
            if (value == 0)
            {
                output.Add(lower);
                return;
            }
            output.Add((byte)(lower | 0x80));
        }
    }

    /// <summary>長さを添えて、そのまま書き足す。</summary>
    internal static void PutBytes(List<byte> output, byte[] bytes)
    {
        Put(output, (ulong)bytes.Length);
        output.AddRange(bytes);
    }

    /// <summary>読み進める位置。読み終わったぶんだけ <see cref="At"/> が進む。</summary>
    internal sealed class Cursor(byte[] bytes, int at)
    {
        internal int At { get; private set; } = at;

        /// <summary>読めなければ null。壊れたファイルはそこで諦める。</summary>
        internal ulong? Get()
        {
            var value = 0ul;
            var shift = 0;
            while (true)
            {
                if (At >= bytes.Length)
                {
                    return null;
                }
                var current = bytes[At++];
                value |= (ulong)(current & 0x7f) << shift;
                if ((current & 0x80) == 0)
                {
                    return value;
                }
                shift += 7;
                // 64 ビットに収まらない並びは、壊れているとみなす。
                if (shift >= 64)
                {
                    return null;
                }
            }
        }

        /// <summary>長さを読んでから、そのぶんを切り出す。</summary>
        internal byte[]? Take()
        {
            if (Get() is not { } length || length > int.MaxValue)
            {
                return null;
            }
            var count = (int)length;
            if (At + count > bytes.Length)
            {
                return null;
            }
            var slice = bytes[At..(At + count)];
            At += count;
            return slice;
        }

        internal byte[]? Rest() => At <= bytes.Length ? bytes[At..] : null;

        /// <summary>
        /// 読まずに読み飛ばす。長さの決まった塊（ベクトルの並びなど）を、
        /// 切り出さずに跨ぐために使う。届かなければ何もせず false。
        /// </summary>
        internal bool Skip(int count)
        {
            if (count < 0 || At + count > bytes.Length)
            {
                return false;
            }
            At += count;
            return true;
        }
    }
}
