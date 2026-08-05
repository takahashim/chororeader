//! 章を順に走査して照合位置を返す。索引は持たない。

use crate::archive::ResourceProvider;
use crate::css_compat;
use crate::html_text;
use crate::paths;
use crate::publication::{Locator, Publication};

pub const RESULT_LIMIT: usize = 400;

#[derive(Debug, Clone)]
pub struct SearchResult {
    pub locator: Locator,
    pub chapter_title: String,
    pub before: String,
    pub matched: String,
    pub after: String,
    pub is_code: bool,
}

#[derive(Debug, Clone)]
pub struct SearchOutcome {
    pub results: Vec<SearchResult>,
    pub truncated: bool,
}

/// 照合のために文字を畳む。
///
/// 日本語では単語境界が定まらないため、標準は部分一致とする。
/// 全角と半角、大文字と小文字、濁点の合成の違いを区別しない。
/// 1 文字が 1 文字に写る畳み方だけを使う。位置を元の文字列へ戻せなくなるため。
fn fold(c: char) -> Option<char> {
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

fn is_combining_mark(c: char) -> bool {
    matches!(c as u32,
        0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF
        | 0x20D0..=0x20FF | 0xFE20..=0xFE2F | 0x3099..=0x309A)
}

/// 元の文字位置を保ったまま畳んだ列。`origin[i]` は `folded[i]` が元の何文字目かを指す。
struct Folded {
    folded: Vec<char>,
    origin: Vec<usize>,
}

fn fold_all(chars: &[char]) -> Folded {
    let mut folded = Vec::with_capacity(chars.len());
    let mut origin = Vec::with_capacity(chars.len());
    for (index, &c) in chars.iter().enumerate() {
        if let Some(f) = fold(c) {
            folded.push(f);
            origin.push(index);
        }
    }
    Folded { folded, origin }
}

pub fn search_epub(
    resources: &dyn ResourceProvider,
    publication: &Publication,
    query: &str,
) -> SearchOutcome {
    let mut results = Vec::new();
    let mut truncated = false;

    let query_chars: Vec<char> = query.chars().collect();
    let needle = fold_all(&query_chars).folded;
    if needle.is_empty() {
        return SearchOutcome {
            results,
            truncated,
        };
    }

    for link in &publication.reading_order {
        if truncated {
            break;
        }
        let Some(data) = resources.read(&link.href) else {
            continue;
        };

        let title = publication
            .title_for_href(&link.href)
            .map(str::to_string)
            .unwrap_or_else(|| paths::last_component(&link.href).to_string());

        let extracted = html_text::extract(&css_compat::decode_text(&data));
        let chars: Vec<char> = extracted.text.chars().collect();
        if chars.is_empty() {
            continue;
        }
        let haystack = fold_all(&chars);

        let mut from = 0usize;
        while from + needle.len() <= haystack.folded.len() {
            let Some(hit) = find(&haystack.folded[from..], &needle) else {
                break;
            };
            let folded_at = from + hit;
            let found = haystack.origin[folded_at];

            // 照合の長さは元の文字列側で数える。畳んだ結果と長さが変わりうるため。
            let match_length = original_length(&haystack, folded_at, needle.len(), chars.len());
            let after_start = (found + match_length).min(chars.len());
            let snippet_end = (found + match_length.max(12)).min(chars.len());

            results.push(SearchResult {
                locator: Locator {
                    href: Some(link.href.clone()),
                    progression: found as f64 / chars.len() as f64,
                    title: Some(title.clone()),
                    text: Some(slice(&chars, found, snippet_end)),
                },
                chapter_title: title.clone(),
                before: slice(&chars, found.saturating_sub(30), found)
                    .trim()
                    .to_string(),
                matched: slice(&chars, found, after_start),
                after: slice(&chars, after_start, (after_start + 40).min(chars.len()))
                    .trim()
                    .to_string(),
                is_code: extracted.is_code(found),
            });

            if results.len() >= RESULT_LIMIT {
                truncated = true;
                break;
            }
            from = folded_at + 1;
        }
    }

    SearchOutcome {
        results,
        truncated,
    }
}

/// 畳んだ列の何文字ぶんが、元の何文字に当たるかを求める。
fn original_length(haystack: &Folded, folded_at: usize, needle_len: usize, total: usize) -> usize {
    let start = haystack.origin[folded_at];
    let end = haystack
        .origin
        .get(folded_at + needle_len)
        .copied()
        .unwrap_or(total);
    (end - start).max(1)
}

fn find(haystack: &[char], needle: &[char]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    (0..=haystack.len() - needle.len()).find(|&i| &haystack[i..i + needle.len()] == needle)
}

fn slice(chars: &[char], start: usize, end: usize) -> String {
    let start = start.min(chars.len());
    let end = end.clamp(start, chars.len());
    chars[start..end].iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 全角と半角を区別しない() {
        let chars: Vec<char> = "ＡＢＣ".chars().collect();
        let haystack = fold_all(&chars);
        let needle: Vec<char> = fold_all(&"abc".chars().collect::<Vec<_>>()).folded;
        assert_eq!(find(&haystack.folded, &needle), Some(0));
    }

    #[test]
    fn 結合文字は飛ばして数える() {
        // "か" + 濁点 は "が" と同じ扱いにする。
        let chars: Vec<char> = "か\u{3099}き".chars().collect();
        let haystack = fold_all(&chars);
        assert_eq!(haystack.folded, vec!['か', 'き']);
        assert_eq!(haystack.origin, vec![0, 2]);
    }
}
