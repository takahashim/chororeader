//! 書籍の中身を配る経路。
//!
//! EPUB は展開せず、要求されたときに ZIP から取り出す。
//! 本文は生成元を持たない枠（sandbox="allow-scripts"）へ入れる。書籍の script は
//! CSP で止め、こちらの出先（agent.js）だけを nonce で通す（spikes/findings-tauri.md）。

use tauri::http::{Request, Response};
use tauri::Manager;

use chororeader_core::archive::ResourceProvider;
use chororeader_core::css_compat;
use chororeader_core::mark;

use crate::library::{Content, Library};

pub const SCHEME: &str = "choro";

/// 画面を開くための入り口。Windows では独自スキームが `http://<名前>.localhost` になる。
///
/// 窓ごとに文書が違う。読書は index.html、書棚は shelf.html で、
/// 片方にしか要らない道具を、もう片方が読み込まずに済むようにしてある。
pub fn app_url(page: &str, query: &str) -> String {
    let base = if cfg!(windows) {
        format!("http://{SCHEME}.localhost")
    } else {
        format!("{SCHEME}://localhost")
    };
    format!("{base}/app/{page}{query}")
}

/// 画面を作るファイル。焼き込んで配るので、増やすときはここへ 1 行足す。
const ASSETS: &[(&str, &str, &str)] = &[
    ("index.html", include_str!("../ui/index.html"), "text/html; charset=utf-8"),
    ("shelf.html", include_str!("../ui/shelf.html"), "text/html; charset=utf-8"),
    ("chrome.css", include_str!("../ui/chrome.css"), CSS),
    ("reader.css", include_str!("../ui/reader.css"), CSS),
    ("shelf.css", include_str!("../ui/shelf.css"), CSS),
    ("selftest.js", include_str!("../ui/selftest.js"), JS),
    ("selftest-checks.js", include_str!("../ui/selftest-checks.js"), JS),
    ("reader.js", include_str!("../ui/reader.js"), JS),
    ("shelf.js", include_str!("../ui/shelf.js"), JS),
    ("chrome.js", include_str!("../ui/chrome.js"), JS),
    ("lib/layout.js", include_str!("../ui/lib/layout.js"), JS),
    ("lib/hit-row.js", include_str!("../ui/lib/hit-row.js"), JS),
    ("lib/diagnosis.js", include_str!("../ui/lib/diagnosis.js"), JS),
    ("lib/mark.js", include_str!("../ui/lib/mark.js"), JS),
    ("readers/paged.js", include_str!("../ui/readers/paged.js"), JS),
    ("readers/reflowable.js", include_str!("../ui/readers/reflowable.js"), JS),
    ("readers/overlays.js", include_str!("../ui/readers/overlays.js"), JS),
    ("readers/talk.js", include_str!("../ui/readers/talk.js"), JS),
    ("lib/format.js", include_str!("../ui/lib/format.js"), JS),
    ("agent.js", include_str!("../ui/agent.js"), JS),
];

const JS: &str = "text/javascript; charset=utf-8";
const CSS: &str = "text/css; charset=utf-8";

pub fn serve(app: &tauri::AppHandle, request: &Request<Vec<u8>>) -> Response<Vec<u8>> {
    let path = percent_decode(request.uri().path().trim_start_matches('/'));

    if let Some(name) = path.strip_prefix("app/") {
        return match ASSETS.iter().find(|(asset, _, _)| *asset == name) {
            Some((_, body, content_type)) => typed(body.as_bytes().to_vec(), content_type),
            None => not_found(),
        };
    }

    let library = app.state::<Library>();

    if let Some(rest) = path.strip_prefix("book/") {
        let Some((id, href)) = rest.split_once('/') else {
            return not_found();
        };
        // 検索から飛んできたときは、当たりを囲んだ本文を返す。
        // 囲むのを画面側でやると、文字節を切って包む手術を JS で書くことになる。
        return serve_book(&library, id, href, wanted_mark(request));
    }

    if let Some(rest) = path.strip_prefix("pdf/") {
        return serve_pdf(&library, rest);
    }

    // 書棚に並べる表紙。開いたときに置いた画像をそのまま返す。
    if let Some(name) = path.strip_prefix("cover/") {
        if name.contains('/') || name.contains("..") {
            return not_found();
        }
        let store = app.state::<crate::store::Store>();
        return match std::fs::read(store.cover_path(name)) {
            Ok(bytes) => typed(bytes, mime_of(&extension(name))),
            Err(_) => not_found(),
        };
    }

    not_found()
}

/// 経路に付いた `?q=<語>&nth=<何番目>`。検索から飛んできたときだけ載っている。
fn wanted_mark(request: &Request<Vec<u8>>) -> Option<(String, usize)> {
    let query = request.uri().query()?;
    let mut word = None;
    let mut nth = 0usize;
    for pair in query.split('&') {
        match pair.split_once('=') {
            Some(("q", value)) => word = Some(percent_decode(value)),
            Some(("nth", value)) => nth = value.parse().unwrap_or(0),
            _ => {}
        }
    }
    word.filter(|w| !w.is_empty()).map(|w| (w, nth))
}

fn serve_book(
    library: &Library,
    id: &str,
    href: &str,
    mark: Option<(String, usize)>,
) -> Response<Vec<u8>> {
    let Some(book) = library.get(id) else {
        return not_found();
    };
    let book = book.lock().unwrap();
    let Content::Epub { archive, .. } = &book.content else {
        return not_found();
    };
    let Some(data) = archive.read(href) else {
        return not_found();
    };

    match extension(href).as_str() {
        // 古い EPUB の -epub- 接頭辞は配信時に書き換える。元のファイルには触れない。
        "css" => {
            let rewritten = css_compat::rewrite(&css_compat::decode_text(&data));
            typed(rewritten.css.into_bytes(), "text/css; charset=utf-8")
        }
        // 本文は text/html として渡す。XHTML として解釈させると、
        // 名前空間の宣言が無い断片で丸ごと解析に失敗する（macOS 版で踏んだ）。
        "xhtml" | "html" | "htm" => {
            let rewritten = css_compat::rewrite_xhtml(&css_compat::decode_text(&data));
            let body = match mark {
                Some((query, nth)) => {
                    mark::insert(&rewritten.css, &query, nth).unwrap_or(rewritten.css)
                }
                None => rewritten.css,
            };
            book_html(&body)
        }
        other => typed(data, mime_of(other)),
    }
}

/// `pdf/<書籍 id>/<ページ番号>/<倍率>` を描いて PNG で返す。
fn serve_pdf(library: &Library, rest: &str) -> Response<Vec<u8>> {
    let mut parts = rest.split('/');
    let Some(id) = parts.next() else {
        return not_found();
    };
    let page: i32 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    let zoom: f32 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(1.0);

    let Some(book) = library.get(id) else {
        return not_found();
    };
    let book = book.lock().unwrap();
    let Content::Pdf { worker, .. } = &book.content else {
        return not_found();
    };
    match worker.render_page(page, zoom) {
        Some(png) => Response::builder()
            .header("Content-Type", "image/png")
            .header("Cache-Control", "no-store")
            .body(png)
            .unwrap(),
        None => not_found(),
    }
}

fn extension(name: &str) -> String {
    match name.rfind('.') {
        Some(index) => name[index + 1..].to_lowercase(),
        None => String::new(),
    }
}

fn mime_of(extension: &str) -> &'static str {
    match extension {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "js" => "text/javascript; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "xml" | "ncx" | "opf" => "application/xml; charset=utf-8",
        _ => "application/octet-stream",
    }
}

/// 要求の経路に含まれる符号を解く。日本語のファイル名がそのまま来ることもある。
fn percent_decode(value: &str) -> String {
    chororeader_core::paths::percent_decode(value)
}

/// 書籍の本文を返す。**書籍の script はここで止める。**
///
/// 本文の枠は sandbox="allow-scripts" で、生成元を持たない文書として入る。
/// script が走る余地はあるので、走ってよいものを CSP の nonce で 1 本に限る。
/// nonce は要求ごとに引き直すため、書籍側に書いておいて当てることはできない。
///
/// 止め方を配信側に置くのは、HTML を解析して script を削る形だと
/// `<svg><script>` や `on…=` 属性や `javascript:` を取りこぼすためである。
/// CSP はブラウザが強制するので、書き方の変化に左右されない。
fn book_html(body: &str) -> Response<Vec<u8>> {
    let nonce = fresh_nonce();
    let policy = format!(
        "default-src 'none'; script-src 'nonce-{nonce}'; style-src 'unsafe-inline' choro:; \
         img-src choro: data:; media-src choro:; font-src choro:; connect-src 'none'; \
         base-uri 'none'; form-action 'none'"
    );
    Response::builder()
        .header("Content-Type", "text/html; charset=utf-8")
        .header("Content-Security-Policy", policy)
        .body(inject_agent(body, &nonce).into_bytes())
        .unwrap()
}

/// 要求ごとの nonce。当てられては意味がないので、走らせるごとの種と通し番号から作る。
fn fresh_nonce() -> String {
    use std::hash::{BuildHasher, Hasher};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::OnceLock;

    static SEED: OnceLock<u64> = OnceLock::new();
    static COUNT: AtomicU64 = AtomicU64::new(0);
    // HashMap の種は OS の乱数から取られる。別に乱数の口を増やさずに済む。
    let seed = *SEED.get_or_init(|| std::collections::hash_map::RandomState::new().build_hasher().finish());
    let count = COUNT.fetch_add(1, Ordering::Relaxed);
    format!("{:016x}{:08x}", seed, count)
}

/// 出先を本文へ差し込む。head があればその中の頭、無ければ文書の先頭。
fn inject_agent(html: &str, nonce: &str) -> String {
    let tag = format!("<script nonce=\"{nonce}\" src=\"/app/agent.js\"></script>");
    match head_starts(html) {
        Some(at) => {
            let mut out = String::with_capacity(html.len() + tag.len());
            out.push_str(&html[..at]);
            out.push_str(&tag);
            out.push_str(&html[at..]);
            out
        }
        None => format!("{tag}{html}"),
    }
}

/// `<head …>` の閉じ括弧の次の位置。`<header>` とは取り違えない。
fn head_starts(html: &str) -> Option<usize> {
    let lower = html.to_ascii_lowercase();
    for (at, _) in lower.match_indices("<head") {
        let next = lower[at + 5..].chars().next();
        if next.is_some_and(|c| c.is_ascii_alphanumeric()) {
            continue; // <header> など
        }
        return lower[at..].find('>').map(|close| at + close + 1);
    }
    None
}


fn typed(body: Vec<u8>, content_type: &str) -> Response<Vec<u8>> {
    Response::builder()
        .header("Content-Type", content_type)
        .body(body)
        .unwrap()
}

fn not_found() -> Response<Vec<u8>> {
    Response::builder().status(404).body(Vec::new()).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn head_の頭へ差し込む() {
        let out = inject_agent("<html><head><title>題</title></head><body>本文</body></html>", "n");
        assert!(out.starts_with("<html><head><script nonce=\"n\" src=\"/app/agent.js\"></script><title>"), "{out}");
    }

    #[test]
    fn 属性つきの_head_も見分ける() {
        let out = inject_agent("<head profile=\"x\"><meta/></head>", "n");
        assert!(out.starts_with("<head profile=\"x\"><script"), "{out}");
    }

    #[test]
    fn header_を_head_と取り違えない() {
        let out = inject_agent("<body><header>見出し</header></body>", "n");
        assert!(out.starts_with("<script nonce=\"n\""), "{out}");
    }

    #[test]
    fn head_が無ければ先頭へ置く() {
        let out = inject_agent("<p>断片</p>", "n");
        assert_eq!(out, "<script nonce=\"n\" src=\"/app/agent.js\"></script><p>断片</p>");
    }

    #[test]
    fn nonce_は要求ごとに変わる() {
        assert_ne!(fresh_nonce(), fresh_nonce());
    }
}
