//! EPUB 内の参照の扱い。macOS 版・C# 版と同じ結果を返す必要がある（conformance/CONTRACT.md）。

use unicode_normalization::UnicodeNormalization;

/// 相対参照を、アーカイブ先頭からのパスへ正規化する。
/// 区切りは常に `/`。OS のパス操作は使わない。
pub fn resolve(base: &str, href: &str) -> String {
    let decoded = percent_decode(href);
    if let Some(rest) = decoded.strip_prefix('/') {
        return rest.to_string();
    }

    let mut components: Vec<&str> = base.split('/').filter(|p| !p.is_empty()).collect();

    for part in decoded.split('/') {
        match part {
            "" | "." => continue,
            ".." => {
                // 先頭で頭打ちにする。アーカイブの外へは出られない。
                components.pop();
            }
            _ => components.push(part),
        }
    }

    components.join("/")
}

/// 参照から fragment を切り離す。
pub fn strip_fragment(href: &str) -> (&str, Option<&str>) {
    match href.find('#') {
        None => (href, None),
        Some(hash) => {
            let fragment = &href[hash + 1..];
            (
                &href[..hash],
                if fragment.is_empty() { None } else { Some(fragment) },
            )
        }
    }
}

/// パーセント符号を解く。解けない並びはそのまま残す。
pub fn percent_decode(value: &str) -> String {
    if !value.contains('%') {
        return value.to_string();
    }

    let bytes = value.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        // C# 版は「% の後ろに 16 進が 2 桁続き、かつその先にまだ文字がある」ときだけ解く。
        // 末尾ぎりぎりの %XX を解かない点まで合わせる。
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && bytes[i + 1].is_ascii_hexdigit()
            && bytes[i + 2].is_ascii_hexdigit()
        {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
            if let Ok(byte) = u8::from_str_radix(hex, 16) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }

    match String::from_utf8(out) {
        Ok(text) => text,
        // 解いた結果が UTF-8 として壊れているなら、元のまま返すほうが害が少ない。
        Err(e) => String::from_utf8_lossy(e.as_bytes()).into_owned(),
    }
}

/// macOS は分解形（NFD）を返すことがあり Windows は合成形。比較のため NFC へ揃える。
pub fn normalize(value: &str) -> String {
    value.nfc().collect()
}

/// パスの親。区切りが無ければ空。
pub fn directory_of(path: &str) -> &str {
    match path.rfind('/') {
        Some(index) => &path[..index],
        None => "",
    }
}

/// パスの末尾要素。
pub fn last_component(path: &str) -> &str {
    match path.rfind('/') {
        Some(index) => &path[index + 1..],
        None => path,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 親をたどっても根から出ない() {
        assert_eq!(resolve("", "../../etc/passwd"), "etc/passwd");
        assert_eq!(resolve("a/b/c", "../../d.xhtml"), "a/d.xhtml");
    }

    #[test]
    fn 絶対参照は先頭の斜線だけを落とす() {
        assert_eq!(resolve("OEBPS", "/absolute.xhtml"), "absolute.xhtml");
    }

    #[test]
    fn 符号化された区切りは解いてから畳む() {
        assert_eq!(resolve("OEBPS", "text%2Fch01.xhtml"), "OEBPS/text/ch01.xhtml");
        assert_eq!(
            resolve("OEBPS", "%E7%AC%AC1%E7%AB%A0.xhtml"),
            "OEBPS/第1章.xhtml"
        );
    }

    #[test]
    fn 空の要素は畳む() {
        assert_eq!(
            resolve("OEBPS/text", "sub//double.xhtml"),
            "OEBPS/text/sub/double.xhtml"
        );
        assert_eq!(resolve("OEBPS/text", ""), "OEBPS/text");
    }
}
