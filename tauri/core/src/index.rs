//! 全文検索の索引。
//!
//! 日本語には単語の切れ目が無いので、二字組（バイグラム）を鍵にした転置索引を持つ。
//!
//! この索引は**候補を絞るだけ**で、当たりを決めない。
//! 二字組が同じ単位に出ていても、続けて出ているとは限らないためである。
//! 絞った単位を `search` の走査にかけ直して初めて当たりが決まる。
//! そうすることで、結果は索引が無いときと一字も変わらない（conformance/CONTRACT.md の
//! 「検索のヒット位置、件数、順序」を索引の導入で動かさないため）。
//!
//! 当たりの位置を索引に持たせないぶん、容量が小さい。
//! 日本語 50 万字（400 ページ相当）で 300 KB 前後に収まる。

use crate::search::fold_text;

/// 索引の形式の版。読めない版のファイルは捨てて作り直す。
const VERSION: u8 = 1;
const MAGIC: &[u8; 4] = b"CHIX";

/// 単位の終わりを表す番人。
///
/// 1 文字だけの問い合わせは「その字で始まる二字組」をまとめて引くが、
/// 単位の最後の 1 文字は次の字を持たないので、そのままでは引けない。
/// 二字目を 0 にした組を足しておくと、範囲を引くだけで漏れなく当たる。
const SENTINEL: u32 = 0;

/// 2 文字を 1 つの数にする。Unicode の符号位置は 21 bit に収まる。
fn key_of(first: char, second: u32) -> u64 {
    ((first as u64) << 21) | second as u64
}

fn first_char_range(c: char) -> (u64, u64) {
    let base = (c as u64) << 21;
    (base, base + (1 << 21))
}

#[derive(Debug, Clone, Default)]
pub struct Index {
    unit_count: u32,
    /// 昇順に並べた鍵。
    keys: Vec<u64>,
    /// `keys[i]` の単位番号は `units[offsets[i]..offsets[i + 1]]`。
    offsets: Vec<u32>,
    units: Vec<u32>,
}

impl Index {
    pub fn build<S: AsRef<str>>(units: &[S]) -> Index {
        let mut pairs: Vec<(u64, u32)> = Vec::new();

        for (number, unit) in units.iter().enumerate() {
            let number = number as u32;
            let chars = fold_text(unit.as_ref());
            for window in chars.windows(2) {
                pairs.push((key_of(window[0], window[1] as u32), number));
            }
            if let Some(&last) = chars.last() {
                pairs.push((key_of(last, SENTINEL), number));
            }
        }

        pairs.sort_unstable();
        pairs.dedup();

        let mut index = Index {
            unit_count: units.len() as u32,
            keys: Vec::new(),
            offsets: vec![0],
            units: Vec::new(),
        };
        for (key, unit) in pairs {
            if index.keys.last() != Some(&key) {
                index.keys.push(key);
                index.offsets.push(index.units.len() as u32);
            }
            index.units.push(unit);
            *index.offsets.last_mut().unwrap() = index.units.len() as u32;
        }
        index
    }

    pub fn unit_count(&self) -> usize {
        self.unit_count as usize
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// 問い合わせが当たりうる単位の番号。昇順。
    ///
    /// `None` は「索引では絞れないので全部を見よ」を意味する。
    pub fn candidates(&self, query: &str) -> Option<Vec<u32>> {
        let chars = fold_text(query);
        match chars.len() {
            0 => None,
            1 => Some(self.by_first_char(chars[0])),
            _ => {
                let mut found: Option<Vec<u32>> = None;
                for window in chars.windows(2) {
                    let posting = self.posting(key_of(window[0], window[1] as u32));
                    found = Some(match found {
                        None => posting.to_vec(),
                        Some(current) => intersect(&current, posting),
                    });
                    if found.as_ref().is_some_and(Vec::is_empty) {
                        break;
                    }
                }
                found
            }
        }
    }

    fn posting(&self, key: u64) -> &[u32] {
        match self.keys.binary_search(&key) {
            Ok(at) => &self.units[self.offsets[at] as usize..self.offsets[at + 1] as usize],
            Err(_) => &[],
        }
    }

    /// その字で始まる二字組をすべて合併する。
    fn by_first_char(&self, c: char) -> Vec<u32> {
        let (from, to) = first_char_range(c);
        let start = self.keys.partition_point(|&k| k < from);
        let end = self.keys.partition_point(|&k| k < to);

        let mut seen = vec![false; self.unit_count as usize];
        let mut found = Vec::new();
        for at in start..end {
            for &unit in &self.units[self.offsets[at] as usize..self.offsets[at + 1] as usize] {
                let slot = &mut seen[unit as usize];
                if !*slot {
                    *slot = true;
                    found.push(unit);
                }
            }
        }
        found.sort_unstable();
        found
    }

    // --- 書き出しと読み込み ------------------------------------------------
    //
    // 鍵も単位番号も昇順に並んでいるので、差分を可変長で書けば大半が 1 バイトで済む。

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(MAGIC);
        out.push(VERSION);
        put(&mut out, self.unit_count as u64);
        put(&mut out, self.keys.len() as u64);

        let mut previous = 0u64;
        for (at, &key) in self.keys.iter().enumerate() {
            put(&mut out, key - previous);
            previous = key;
            put(&mut out, (self.offsets[at + 1] - self.offsets[at]) as u64);
        }

        for at in 0..self.keys.len() {
            let mut previous = 0u32;
            for &unit in &self.units[self.offsets[at] as usize..self.offsets[at + 1] as usize] {
                put(&mut out, (unit - previous) as u64);
                previous = unit;
            }
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Index> {
        let mut cursor = Cursor {
            bytes,
            at: MAGIC.len() + 1,
        };
        if bytes.len() < cursor.at || &bytes[..MAGIC.len()] != MAGIC || bytes[MAGIC.len()] != VERSION
        {
            return None;
        }

        let unit_count = cursor.get()? as u32;
        let key_count = cursor.get()? as usize;

        let mut keys = Vec::with_capacity(key_count);
        let mut lengths = Vec::with_capacity(key_count);
        let mut previous = 0u64;
        for _ in 0..key_count {
            previous += cursor.get()?;
            keys.push(previous);
            lengths.push(cursor.get()? as u32);
        }

        let mut offsets = Vec::with_capacity(key_count + 1);
        offsets.push(0u32);
        let mut units = Vec::new();
        for &length in &lengths {
            let mut previous = 0u32;
            for _ in 0..length {
                previous += cursor.get()? as u32;
                if previous >= unit_count {
                    return None;
                }
                units.push(previous);
            }
            offsets.push(units.len() as u32);
        }

        Some(Index {
            unit_count,
            keys,
            offsets,
            units,
        })
    }
}

fn intersect(left: &[u32], right: &[u32]) -> Vec<u32> {
    let mut found = Vec::new();
    let (mut a, mut b) = (0, 0);
    while a < left.len() && b < right.len() {
        match left[a].cmp(&right[b]) {
            std::cmp::Ordering::Less => a += 1,
            std::cmp::Ordering::Greater => b += 1,
            std::cmp::Ordering::Equal => {
                found.push(left[a]);
                a += 1;
                b += 1;
            }
        }
    }
    found
}

fn put(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

struct Cursor<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Cursor<'_> {
    fn get(&mut self) -> Option<u64> {
        let mut value = 0u64;
        let mut shift = 0;
        loop {
            let byte = *self.bytes.get(self.at)?;
            self.at += 1;
            value |= ((byte & 0x7f) as u64) << shift;
            if byte & 0x80 == 0 {
                return Some(value);
            }
            shift += 7;
            if shift >= 64 {
                return None;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn built() -> Index {
        Index::build(&[
            "型システムの話",
            "配列と連結リスト",
            "型推論と単一化",
        ])
    }

    #[test]
    fn 二字以上は含む単位だけに絞る() {
        assert_eq!(built().candidates("型").unwrap(), vec![0, 2]);
        assert_eq!(built().candidates("配列").unwrap(), vec![1]);
        assert_eq!(built().candidates("型推論").unwrap(), vec![2]);
    }

    #[test]
    fn 無い語は候補が空になる() {
        assert!(built().candidates("継続モナド").unwrap().is_empty());
    }

    #[test]
    fn 空の問い合わせは絞れない() {
        assert!(built().candidates("").is_none());
    }

    #[test]
    fn 単位の最後の一文字も引ける() {
        let index = Index::build(&["あいう"]);
        assert_eq!(index.candidates("う").unwrap(), vec![0]);
    }

    #[test]
    fn 全角と半角を区別しない() {
        let index = Index::build(&["ＡＰＩ の設計"]);
        assert_eq!(index.candidates("api").unwrap(), vec![0]);
    }

    #[test]
    fn 続いていなくても候補には残る() {
        // 「型」と「論」は在るが「型論」とは続かない。索引は絞るだけなので候補には出す。
        let index = Index::build(&["型と推論"]);
        assert_eq!(index.candidates("と推").unwrap(), vec![0]);
    }

    #[test]
    fn 書き出して読み戻せる() {
        let index = built();
        let bytes = index.encode();
        let back = Index::decode(&bytes).expect("読み戻せる");
        assert_eq!(back.unit_count(), index.unit_count());
        assert_eq!(back.keys, index.keys);
        assert_eq!(back.units, index.units);
        assert_eq!(back.candidates("型推論").unwrap(), vec![2]);
    }

    #[test]
    fn 壊れた入力は読まない() {
        assert!(Index::decode(b"").is_none());
        assert!(Index::decode(b"XXXX\x01").is_none());
        let mut bytes = built().encode();
        bytes[4] = VERSION + 1;
        assert!(Index::decode(&bytes).is_none());
    }
}
