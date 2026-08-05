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

fn regex(pattern: &str) -> Regex {
    RegexBuilder::new(pattern)
        .case_insensitive(true)
        .dot_matches_new_line(true)
        .build()
        .expect("組み込みの正規表現")
}

pub fn extract(html: &str) -> Extracted {
    static SCRIPT: OnceLock<Regex> = OnceLock::new();
    static STYLE: OnceLock<Regex> = OnceLock::new();
    static COMMENT: OnceLock<Regex> = OnceLock::new();
    static PRE: OnceLock<Regex> = OnceLock::new();

    let script = SCRIPT.get_or_init(|| regex(r"<script\b[^>]*>.*?</script>"));
    let style = STYLE.get_or_init(|| regex(r"<style\b[^>]*>.*?</style>"));
    let comment = COMMENT.get_or_init(|| regex(r"<!--.*?-->"));
    let pre = PRE.get_or_init(|| regex(r"<pre\b[^>]*>(.*?)</pre>"));

    let source = script.replace_all(html, "");
    let source = style.replace_all(&source, "");
    let source = comment.replace_all(&source, "");

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
