//! 章を順に走査して照合位置を返す。索引は持たない。

use crate::archive::ResourceProvider;
use crate::fold;
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
    /// 読み順の 1 項目の中で何番目の当たりか。
    /// 飛んだ先で「押したのはこの語のどれか」を選び直すために使う。
    pub nth: usize,
}

#[derive(Debug, Clone)]
pub struct SearchOutcome {
    pub results: Vec<SearchResult>,
    pub truncated: bool,
}

pub fn search_epub(
    resources: &dyn ResourceProvider,
    publication: &Publication,
    query: &str,
) -> SearchOutcome {
    search_epub_within(resources, publication, query, None, RESULT_LIMIT)
}

/// 読み順のうち `only` に挙がった位置だけを走査する。`None` なら全部。
///
/// 索引で絞った候補を渡すための入り口。索引は候補を減らすだけで当たりは決めないので、
/// ここから先の判定は絞っても絞らなくても同じである。
pub fn search_epub_within(
    resources: &dyn ResourceProvider,
    publication: &Publication,
    query: &str,
    only: Option<&[u32]>,
    limit: usize,
) -> SearchOutcome {
    let mut results = Vec::new();
    let mut truncated = false;

    let query_chars: Vec<char> = query.chars().collect();
    let needle = fold::all(&query_chars).folded;
    if needle.is_empty() {
        return SearchOutcome {
            results,
            truncated,
        };
    }

    for (position, link) in publication.reading_order.iter().enumerate() {
        if truncated {
            break;
        }
        if only.is_some_and(|only| !only.contains(&(position as u32))) {
            continue;
        }
        let Some(source) = resources.read_text(&link.href) else {
            continue;
        };

        let title = publication
            .title_for_href(&link.href)
            .map(str::to_string)
            .unwrap_or_else(|| paths::last_component(&link.href).to_string());

        let extracted = html_text::extract(&source);
        let chars: Vec<char> = extracted.text.chars().collect();
        if chars.is_empty() {
            continue;
        }
        // 通し番号は読み順の項目ごとに数え直す。同じ経路が読み順に 2 度出ることがあり、
        // そのときは同じ文書を 2 度開くので、番号も 0 から振り直さないと選び直せない。
        for (nth, (found, match_end)) in matches(&chars, &needle).enumerate() {
            let snippet_end = (found + (match_end - found).max(12)).min(chars.len());

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
                matched: slice(&chars, found, match_end),
                after: slice(&chars, match_end, (match_end + 40).min(chars.len()))
                    .trim()
                    .to_string(),
                is_code: extracted.is_code(found),
                nth,
            });

            if results.len() >= limit {
                truncated = true;
                break;
            }
        }
    }

    SearchOutcome {
        results,
        truncated,
    }
}

/// 本文の中で nth 番目の当たりが占める範囲（文字単位、終わりは含まない）。
///
/// 走査と同じ畳み方で数えるので、検索が返した通し番号と、ここで選ぶ当たりは必ず一致する。
/// 当たりを強調するとき、どの語を囲むかをこれで決める。
pub fn nth_match(text: &str, query: &str, nth: usize) -> Option<(usize, usize)> {
    let query_chars: Vec<char> = query.chars().collect();
    let needle = fold::all(&query_chars).folded;
    let chars: Vec<char> = text.chars().collect();
    // 末尾式のままだと、走査が落ちる順の都合で借りを返せない。いったん受ける。
    let found = matches(&chars, &needle).nth(nth);
    found
}

/// 本文に当たる語が現れる範囲を、元の文字位置で順に返す。
///
/// 走査も強調も、当たりを数えるのはここ 1 か所にする。
/// 別々に数えると、畳み方を変えたときに片方だけ直り、
/// 検索が言う「何番目」と、強調が囲む語が食い違う。
fn matches<'a>(chars: &'a [char], needle: &'a [char]) -> impl Iterator<Item = (usize, usize)> + 'a {
    let haystack = fold::all(chars);
    let total = chars.len();
    let mut from = 0usize;
    std::iter::from_fn(move || {
        if needle.is_empty() || from + needle.len() > haystack.folded.len() {
            return None;
        }
        let hit = find(&haystack.folded[from..], needle)?;
        let folded_at = from + hit;
        let found = haystack.origin[folded_at];
        // 照合の長さは元の文字列側で数える。畳んだ結果と長さが変わりうるため。
        let length = original_length(&haystack, folded_at, needle.len(), total);
        from = folded_at + 1;
        Some((found, (found + length).min(total)))
    })
}

/// 畳んだ列の何文字ぶんが、元の何文字に当たるかを求める。
fn original_length(haystack: &fold::Folded, folded_at: usize, needle_len: usize, total: usize) -> usize {
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
        let haystack = fold::all(&chars);
        let needle: Vec<char> = fold::all(&"abc".chars().collect::<Vec<_>>()).folded;
        assert_eq!(find(&haystack.folded, &needle), Some(0));
    }
}
