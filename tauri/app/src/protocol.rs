//! 書籍の中身を配る経路。
//!
//! EPUB は展開せず、要求されたときに ZIP から取り出す。
//! 画面そのものも同じ生成元から配る。そうしないと本文を入れた iframe と生成元が分かれ、
//! アプリ側のコードから本文の DOM に届かなくなる（spikes/findings-tauri.md）。

use tauri::http::{Request, Response};
use tauri::Manager;

use tzreader_core::archive::ResourceProvider;
use tzreader_core::css_compat;

use crate::library::{Content, Library};

pub const SCHEME: &str = "tzr";

/// 画面を開くための入り口。Windows では独自スキームが `http://<名前>.localhost` になる。
pub fn app_url(query: &str) -> String {
    let base = if cfg!(windows) {
        format!("http://{SCHEME}.localhost")
    } else {
        format!("{SCHEME}://localhost")
    };
    format!("{base}/app/index.html{query}")
}

pub fn serve(app: &tauri::AppHandle, request: &Request<Vec<u8>>) -> Response<Vec<u8>> {
    let path = percent_decode(request.uri().path().trim_start_matches('/'));

    if let Some(name) = path.strip_prefix("app/") {
        return match name {
            "index.html" => html(include_str!("../ui/index.html").as_bytes().to_vec()),
            "app.js" => typed(
                include_str!("../ui/app.js").as_bytes().to_vec(),
                "text/javascript; charset=utf-8",
            ),
            "selftest.js" => typed(
                include_str!("../ui/selftest.js").as_bytes().to_vec(),
                "text/javascript; charset=utf-8",
            ),
            "app.css" => typed(
                include_str!("../ui/app.css").as_bytes().to_vec(),
                "text/css; charset=utf-8",
            ),
            _ => not_found(),
        };
    }

    let library = app.state::<Library>();

    if let Some(rest) = path.strip_prefix("book/") {
        let Some((id, href)) = rest.split_once('/') else {
            return not_found();
        };
        return serve_book(&library, id, href);
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

fn serve_book(library: &Library, id: &str, href: &str) -> Response<Vec<u8>> {
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
            html(rewritten.css.into_bytes())
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
    tzreader_core::paths::percent_decode(value)
}

fn html(body: Vec<u8>) -> Response<Vec<u8>> {
    typed(body, "text/html; charset=utf-8")
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
