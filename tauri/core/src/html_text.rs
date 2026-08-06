//! 章の HTML から本文とコードを取り出す。索引は作らず、要求されたときに走査する。
//! 抽出結果は検索の位置計算に使うため、他の実装と同じ文字列になる必要がある。

use std::sync::OnceLock;

use regex::{Regex, RegexBuilder};

#[derive(Debug, Clone)]
pub struct Extracted {
    pub text: String,
    /// 本文中でコードが占める範囲。単位は Unicode スカラー。
    pub code_ranges: Vec<(usize, usize)>,
}

impl Extracted {
    pub fn is_code(&self, offset: usize) -> bool {
        self.code_ranges
            .iter()
            .any(|(start, end)| offset >= *start && offset < *end)
    }
}

/// 名前付き実体。C# 版の初期化順と同じ並びで適用する。
/// `&amp;` を先に解くかどうかで結果が変わりうるため、順序も揃える。
const ENTITIES: &[(&str, &str)] = &[
    ("&amp;", "&"),
    ("&lt;", "<"),
    ("&gt;", ">"),
    ("&quot;", "\""),
    ("&apos;", "'"),
    ("&nbsp;", " "),
    ("&mdash;", "—"),
    ("&ndash;", "–"),
    ("&hellip;", "…"),
];

/// 本文に混ぜないところ。extract はこれらを消してから走査する。
///
/// head は画面に出ない。題名（title）は本文として数えると、
/// 検索が「見えないところに当たった」と言い、飛んでも何も無いことになる。
fn head() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| regex(r"<head\b[^>]*>.*?</head>"))
}

fn script() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| regex(r"<script\b[^>]*>.*?</script>"))
}

fn style() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| regex(r"<style\b[^>]*>.*?</style>"))
}

fn comment() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| regex(r"<!--.*?-->"))
}

/// 本文に混ぜないところの範囲（バイト位置）。
///
/// extract は消してから走査するので、消えた場所が元のどこだったかは分からなくなる。
/// 抽出した本文を元の HTML へ突き合わせ直すとき（mark）に、そこを飛ばすために使う。
pub fn ignored_ranges(html: &str) -> Vec<(usize, usize)> {
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    for re in [head(), script(), style(), comment()] {
        ranges.extend(re.find_iter(html).map(|m| (m.start(), m.end())));
    }
    ranges.sort_unstable();
    ranges
}

fn regex(pattern: &str) -> Regex {
    RegexBuilder::new(pattern)
        .case_insensitive(true)
        .dot_matches_new_line(true)
        .build()
        .expect("組み込みの正規表現")
}

pub fn extract(html: &str) -> Extracted {
    static PRE: OnceLock<Regex> = OnceLock::new();
    let pre = PRE.get_or_init(|| regex(r"<pre\b[^>]*>(.*?)</pre>"));

    let source = head().replace_all(html, "");
    let source = script().replace_all(&source, "");
    let source = style().replace_all(&source, "");
    let source = comment().replace_all(&source, "");

    let mut text = String::new();
    let mut length = 0usize; // 文字数。バイト数ではない。
    let mut code_ranges = Vec::new();
    let mut cursor = 0;

    for capture in pre.captures_iter(&source) {
        let whole = capture.get(0).expect("全体");
        let before = strip_tags(&source[cursor..whole.start()]);
        length += before.chars().count();
        text.push_str(&before);

        let start = length;
        let inner = strip_tags(&capture[1]);
        length += inner.chars().count();
        text.push_str(&inner);
        code_ranges.push((start, length));

        text.push('\n');
        length += 1;
        cursor = whole.end();
    }
    text.push_str(&strip_tags(&source[cursor..]));

    Extracted { text, code_ranges }
}

/// タグを落として本文だけにする。タグの位置には空白を 1 つ残す。
pub fn strip_tags(source: &str) -> String {
    let mut output = String::with_capacity(source.len());
    let mut inside_tag = false;
    let mut last_was_space = false;

    for c in source.chars() {
        if c == '<' {
            inside_tag = true;
            continue;
        }
        if c == '>' {
            inside_tag = false;
            if !last_was_space {
                output.push(' ');
                last_was_space = true;
            }
            continue;
        }
        if inside_tag {
            continue;
        }
        if c == '\n' || c == '\r' || c == '\t' {
            if !last_was_space {
                output.push(' ');
                last_was_space = true;
            }
            continue;
        }
        output.push(c);
        last_was_space = c == ' ';
    }

    decode_entities(&output)
}

/// 抽出した本文の 1 文字ごとに、元の HTML でその文字が始まるバイト位置を求める。
///
/// extract は削って詰めるだけなので、元を頭から舐めながら同じ文字を拾えば揃う。
/// 揃わない文字（タグの位置に足した空白など）は、いま見ている位置を指しておく。
/// 完全に一致しなくてよい。ずれるのは、これを使って印を置く位置だけである。
///
/// **strip_tags と同じ規則をここでも辿る。** 片方だけ直すと揃わなくなるので、
/// タグの扱い・実体参照・空白の詰め方を変えるときは、必ず両方を見ること。
pub fn align(html: &str, text: &str) -> Vec<usize> {
    let wanted: Vec<char> = text.chars().collect();
    let mut origins = Vec::with_capacity(wanted.len());
    let mut at = 0usize;

    // 本文に混ぜないところ（script / style / コメント）は、抽出も消している。飛ばす。
    let ignored = ignored_ranges(html);
    let mut cursor = 0usize;
    let mut inside_tag = false;

    while at < wanted.len() && cursor < html.len() {
        if let Some((_, end)) = ignored.iter().find(|(from, to)| cursor >= *from && cursor < *to) {
            cursor = *end;
            inside_tag = false;
            continue;
        }
        let c = html[cursor..].chars().next().expect("境界は文字の頭");
        let width = c.len_utf8();

        if c == '<' {
            inside_tag = true;
            cursor += width;
            continue;
        }
        if c == '>' {
            inside_tag = false;
            cursor += width;
            // タグの位置には空白が 1 つ入る。本文側がそれを待っていれば、ここを指す。
            if wanted[at] == ' ' {
                origins.push(cursor);
                at += 1;
            }
            continue;
        }
        if inside_tag {
            cursor += width;
            continue;
        }

        // 実体参照は解かれて 1 文字になる。始まりの位置を指しておく。
        if c == '&' {
            if let Some(length) = entity_length(&html[cursor..]) {
                origins.push(cursor);
                at += 1;
                cursor += length;
                continue;
            }
        }

        if c == wanted[at] {
            origins.push(cursor);
            at += 1;
            cursor += width;
            continue;
        }

        // 改行や連なった空白は 1 つに詰められる。本文側が空白を待っていれば、そこで揃える。
        if wanted[at] == ' ' && c.is_whitespace() {
            origins.push(cursor);
            at += 1;
            cursor += width;
            continue;
        }
        cursor += width;
    }

    // 揃えきれなかった残りは、末尾を指しておく。
    while origins.len() < wanted.len() {
        origins.push(html.len());
    }
    origins
}

/// `&...;` の長さ。実体参照でなければ `None`。
pub fn entity_length(rest: &str) -> Option<usize> {
    let end = rest.char_indices().take(12).find(|(_, c)| *c == ';')?.0;
    let inside = &rest[1..end];
    if inside.is_empty() || inside.contains('<') || inside.contains(' ') {
        return None;
    }
    Some(end + 1)
}

fn decode_entities(source: &str) -> String {
    if !source.contains('&') {
        return source.to_string();
    }

    let mut result = source.to_string();
    for (from, to) in ENTITIES {
        if result.contains(from) {
            result = result.replace(from, to);
        }
    }
    if !result.contains("&#") {
        return result;
    }

    static NUMERIC: OnceLock<Regex> = OnceLock::new();
    let numeric = NUMERIC.get_or_init(|| Regex::new(r"&#(x?)([0-9A-Fa-f]+);").expect("数値実体"));

    numeric
        .replace_all(&result, |capture: &regex::Captures| {
            let radix = if capture[1].is_empty() { 10 } else { 16 };
            match u32::from_str_radix(&capture[2], radix)
                .ok()
                .and_then(char::from_u32)
            {
                Some(c) => c.to_string(),
                // 読めない並びは、書いてあるまま残す。
                None => capture[0].to_string(),
            }
        })
        .into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn コードの範囲は文字数で数える() {
        let extracted = extract("<h1>第 1 章</h1><pre>puts</pre><p>後</p>");
        let chars: Vec<char> = extracted.text.chars().collect();
        let (start, end) = extracted.code_ranges[0];
        assert_eq!(chars[start..end].iter().collect::<String>(), "puts");
    }

    #[test]
    fn 本文の実体参照を解く() {
        assert_eq!(strip_tags("a&amp;b&#12354;"), "a&bあ");
    }

    #[test]
    fn scriptとstyleは本文に混ぜない() {
        let extracted = extract("<style>body{}</style><p>本文</p><script>x()</script>");
        assert!(!extracted.text.contains("body"));
        assert!(!extracted.text.contains("x()"));
        assert!(extracted.text.contains("本文"));
    }
}
