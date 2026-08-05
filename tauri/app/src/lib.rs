//! tzreader の Tauri 版。
//!
//! 画面は Web だが、書籍を解釈するのは tzreader-core であり、
//! その振る舞いは macOS 版・C# 版と conformance で突き合わせてある。
//! ここに書くのは、画面と core をつなぐ部分だけにする。

mod library;
mod protocol;
mod store;

use serde::Serialize;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_dialog::DialogExt;

use tzreader_core::archive::ResourceProvider;
use tzreader_core::style::{ReaderStyle, Theme};
use tzreader_core::{css_compat, html_text, paths, preview, report, search};

use library::{describe, BookInfo, Content, Library};
use store::{Bookmark, BookState, Position, Store};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // 引数で書籍を渡されたら、それを開いた状態で始める。
    let opening = std::env::args().nth(1);

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Library::default())
        .invoke_handler(tauri::generate_handler![
            open_book,
            pick_book,
            recent_books,
            reader_css,
            settings,
            save_settings,
            search_book,
            preview_link,
            chapter_text,
            page_text,
            diagnose,
            open_in_new_window,
            book_state,
            remember_position,
            toggle_bookmark,
            open_external,
        ])
        .register_asynchronous_uri_scheme_protocol(protocol::SCHEME, |ctx, request, responder| {
            let app = ctx.app_handle().clone();
            // 描画で画面を止めないため、要求ごとに別スレッドで応える。
            std::thread::spawn(move || responder.respond(protocol::serve(&app, &request)));
        })
        .setup(move |app| {
            app.manage(Store::load(app.handle()));
            let query = match &opening {
                Some(path) => format!("?path={}", urlencode(path)),
                None => String::new(),
            };
            open_window(app.handle(), "main", &query)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Tauri の起動に失敗した");
}

fn open_window(
    app: &tauri::AppHandle,
    label: &str,
    query: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    WebviewWindowBuilder::new(
        app,
        label,
        WebviewUrl::External(protocol::app_url(query).parse()?),
    )
    .title("tzreader")
    .inner_size(1000.0, 760.0)
    .build()?;
    Ok(())
}

fn urlencode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

// MARK: 書籍を開く

#[tauri::command]
fn open_book(library: tauri::State<'_, Library>, path: String) -> Result<BookInfo, String> {
    let book = library.open(&path)?;
    let book = book.lock().unwrap();
    Ok(describe(&book))
}

#[tauri::command]
fn pick_book(app: tauri::AppHandle) -> Option<String> {
    // 命令はワーカースレッドで走るため、ここで待ってよい。
    app.dialog()
        .file()
        .add_filter("書籍", &["epub", "pdf"])
        .blocking_pick_file()
        .and_then(|file| file.into_path().ok())
        .map(|path| path.to_string_lossy().into_owned())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RecentBook {
    path: String,
    name: String,
    exists: bool,
}

#[tauri::command]
fn recent_books(store: tauri::State<'_, Store>) -> Vec<RecentBook> {
    store
        .recent()
        .into_iter()
        .map(|path| RecentBook {
            name: paths::last_component(&path).to_string(),
            exists: std::path::Path::new(&path).exists(),
            path,
        })
        .collect()
}

#[tauri::command]
fn open_in_new_window(app: tauri::AppHandle, path: String, href: String) -> Result<(), String> {
    // ラベルは重ならなければよい。開いた数を数えて付ける。
    let label = format!("book-{}", app.webview_windows().len() + 1);
    let query = format!("?path={}&href={}", urlencode(&path), urlencode(&href));
    open_window(&app, &label, &query).map_err(|e| e.to_string())
}

// MARK: 表示設定

#[tauri::command]
fn reader_css(settings: serde_json::Value) -> serde_json::Value {
    let style = style_from(&settings);
    serde_json::json!({
        "css": style.css(),
        "needsForegroundMarking": style.needs_foreground_marking(),
    })
}

fn style_from(settings: &serde_json::Value) -> ReaderStyle {
    let fallback = ReaderStyle::default();
    ReaderStyle {
        font_size_percent: settings["fontSizePercent"]
            .as_f64()
            .unwrap_or(fallback.font_size_percent),
        line_height: settings["lineHeight"].as_f64().unwrap_or(fallback.line_height),
        max_width_em: settings["maxWidthEm"].as_f64().unwrap_or(fallback.max_width_em),
        theme: Theme::parse(settings["theme"].as_str()),
        body_font: settings["bodyFont"].as_str().unwrap_or("").to_string(),
        code_font: settings["codeFont"]
            .as_str()
            .unwrap_or(&fallback.code_font)
            .to_string(),
        code_wrap: settings["codeWrap"].as_bool().unwrap_or(fallback.code_wrap),
        publisher_style: settings["publisherStyle"]
            .as_bool()
            .unwrap_or(fallback.publisher_style),
    }
}

#[tauri::command]
fn settings(store: tauri::State<'_, Store>) -> serde_json::Value {
    store.settings()
}

#[tauri::command]
fn save_settings(store: tauri::State<'_, Store>, settings: serde_json::Value) {
    store.save_settings(settings);
}

// MARK: 読む

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Hit {
    href: String,
    page: i32,
    progression: f64,
    title: String,
    excerpt: String,
    is_code: bool,
}

#[tauri::command]
fn search_book(
    library: tauri::State<'_, Library>,
    id: String,
    query: String,
) -> Result<Vec<Hit>, String> {
    let book = library.get(&id).ok_or("書籍が開かれていない")?;
    let book = book.lock().unwrap();
    match &book.content {
        Content::Epub {
            archive,
            publication,
        } => {
            let outcome = search::search_epub(archive, publication, &query);
            Ok(outcome
                .results
                .into_iter()
                .map(|r| Hit {
                    href: r.locator.href.unwrap_or_default(),
                    page: 0,
                    progression: r.locator.progression,
                    title: r.chapter_title,
                    excerpt: format!("{}{}{}", r.before, r.matched, r.after),
                    is_code: r.is_code,
                })
                .collect())
        }
        Content::Pdf { worker, .. } => Ok(worker
            .search(&query, 400)
            .into_iter()
            .map(|(page, excerpt)| Hit {
                href: String::new(),
                page,
                progression: 0.0,
                title: format!("p.{}", page + 1),
                excerpt,
                is_code: false,
            })
            .collect()),
    }
}

/// リンク先を移動せずに確かめるための抜粋。
#[tauri::command]
fn preview_link(
    library: tauri::State<'_, Library>,
    id: String,
    href: String,
    fragment: Option<String>,
    css: String,
) -> Option<serde_json::Value> {
    let book = library.get(&id)?;
    let book = book.lock().unwrap();
    let Content::Epub { archive, .. } = &book.content else {
        return None;
    };
    let built = preview::make(archive, &href, fragment.as_deref(), &css)?;
    Some(serde_json::json!({
        "html": built.html,
        "isFootnote": built.is_footnote,
    }))
}

#[tauri::command]
fn chapter_text(
    library: tauri::State<'_, Library>,
    id: String,
    href: String,
) -> Result<String, String> {
    let book = library.get(&id).ok_or("書籍が開かれていない")?;
    let book = book.lock().unwrap();
    let Content::Epub { archive, .. } = &book.content else {
        return Err("EPUB ではない".to_string());
    };
    let data = archive.read(&href).ok_or("章が見つからない")?;
    Ok(html_text::extract(&css_compat::decode_text(&data)).text)
}

#[tauri::command]
fn page_text(library: tauri::State<'_, Library>, id: String, page: i32) -> Result<String, String> {
    let book = library.get(&id).ok_or("書籍が開かれていない")?;
    let book = book.lock().unwrap();
    let Content::Pdf { worker, .. } = &book.content else {
        return Err("PDF ではない".to_string());
    };
    Ok(worker.text_of_page(page))
}

/// 書籍の診断。probe report と同じ値を返す。
#[tauri::command]
fn diagnose(library: tauri::State<'_, Library>, id: String) -> Result<serde_json::Value, String> {
    let book = library.get(&id).ok_or("書籍が開かれていない")?;
    let book = book.lock().unwrap();
    let Content::Epub {
        archive,
        publication,
    } = &book.content
    else {
        return Err("EPUB ではない".to_string());
    };
    let report = report::make(archive, publication);
    Ok(serde_json::json!({
        "spineCount": report.spine_count,
        "tocEntryCount": report.toc_entry_count,
        "tocMaxDepth": report.toc_max_depth,
        "missingResources": report.missing_resources,
        "missingTOCTargets": report.missing_toc_targets,
        "missingSpineItems": report.missing_spine_items,
        "cssFileCount": report.css_file_count,
        "legacyCSSFileCount": report.legacy_css_file_count,
        "cssChanges": report.css_changes.iter()
            .map(|c| serde_json::json!({"from": c.from, "to": c.to, "count": c.count}))
            .collect::<Vec<_>>(),
        "xhtmlCount": report.xhtml_count,
        "malformedXHTMLCount": report.malformed_xhtml_count,
        "imageCount": report.image_count,
        "fontCount": report.font_count,
    }))
}

// MARK: 位置としおり

#[tauri::command]
fn book_state(store: tauri::State<'_, Store>, path: String) -> BookState {
    store.state_of(&path)
}

#[tauri::command]
fn remember_position(store: tauri::State<'_, Store>, path: String, position: Position) {
    store.remember(&path, position);
}

#[tauri::command]
fn toggle_bookmark(
    store: tauri::State<'_, Store>,
    path: String,
    bookmark: Bookmark,
) -> Vec<Bookmark> {
    store.toggle_bookmark(&path, bookmark)
}

#[tauri::command]
fn open_external(app: tauri::AppHandle, url: String) -> Result<(), String> {
    // 外部の URL は既定のブラウザに渡す。読書中にアプリがネットワークを使うことはない。
    let _ = app;
    let program = if cfg!(target_os = "windows") {
        ("cmd", vec!["/C".to_string(), "start".to_string(), String::new(), url])
    } else if cfg!(target_os = "macos") {
        ("open", vec![url])
    } else {
        ("xdg-open", vec![url])
    };
    std::process::Command::new(program.0)
        .args(program.1)
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}
