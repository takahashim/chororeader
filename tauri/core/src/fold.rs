//! 照合のために文字を畳む。
//!
//! 日本語では単語境界が定まらないため、標準は部分一致とする。
//! 全角と半角、大文字と小文字、濁点の合成の違いを区別しない。
//! 1 文字が 1 文字に写る畳み方だけを使う。位置を元の文字列へ戻せなくなるため。
//!
//! 畳み方は検索（search）・索引（index）・印付け（mark）が共有する。
//! どれか 1 つの持ち物にすると、残りがそこへ間借りする形になって、
//! 「畳み方はどこの決まりごとか」が名前から分からなくなる。

/// 1 文字を畳む。畳んだ結果が無くなる文字（結合文字）は `None`。
pub fn one(c: char) -> Option<char> {
    // 結合文字は無視する（.NET の CompareOptions.IgnoreNonSpace に当たる）。
    if is_combining_mark(c) {
        return None;
    }

    let code = c as u32;
    let folded = match code {
        // 全角の ASCII を半角へ。
        0xFF01..=0xFF5E => char::from_u32(code - 0xFEE0).unwrap_or(c),
        // 全角スペース。
        0x3000 => ' ',
        _ => c,
    };

    Some(folded.to_lowercase().next().unwrap_or(folded))
}

/// 畳んだ文字だけを並べる。元の位置は要らないとき用。
pub fn text(source: &str) -> Vec<char> {
    source.chars().filter_map(one).collect()
}

/// 元の文字位置を保ったまま畳んだ列。`origin[i]` は `folded[i]` が元の何文字目かを指す。
pub struct Folded {
    pub folded: Vec<char>,
    pub origin: Vec<usize>,
}

pub fn all(chars: &[char]) -> Folded {
    let mut folded = Vec::with_capacity(chars.len());
    let mut origin = Vec::with_capacity(chars.len());
    for (index, &c) in chars.iter().enumerate() {
        if let Some(f) = one(c) {
            folded.push(f);
            origin.push(index);
        }
    }
    Folded { folded, origin }
}

fn is_combining_mark(c: char) -> bool {
    matches!(c as u32,
        0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF
        | 0x20D0..=0x20FF | 0xFE20..=0xFE2F | 0x3099..=0x309A)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 結合文字は飛ばして数える() {
        // "か" + 濁点 は "が" と同じ扱いにする。
        let chars: Vec<char> = "か\u{3099}き".chars().collect();
        let folded = all(&chars);
        assert_eq!(folded.folded, vec!['か', 'き']);
        assert_eq!(folded.origin, vec![0, 2]);
    }

    #[test]
    fn 全角と大文字を畳む() {
        assert_eq!(text("ＡＢＣ"), vec!['a', 'b', 'c']);
        assert_eq!(text("　"), vec![' ']);
    }
}
