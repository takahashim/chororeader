//! tzreader の Tauri 版。
//!
//! 画面は Web だが、書籍を解釈するのは tzreader-core であり、
//! その振る舞いは macOS 版・C# 版と conformance で突き合わせてある。
//! ここに書くのは、画面と core をつなぐ部分だけにする。

mod library;
mod protocol;
pub mod store;

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
    // 引数で渡された書籍は、1 冊につき 1 つの窓で開く。
    // 同じ書籍を 2 度渡してもよい。離れた 2 か所を並べて見るための道具である。
    let opening: Vec<String> = std::env::args().skip(1).filter(|a| !a.starts_with('-')).collect();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Library::default())
        .invoke_handler(tauri::generate_handler![
            open_book,
            pick_book,
            library,
            reader_css,
            settings,
            save_settings,
            search_book,
            preview_link,
            chapter_text,
            page_text,
            page_size,
            diagnose,
            open_in_new_window,
            book_state,
            remember_position,
            toggle_bookmark,
            open_external,
            focus_webview,
        ])
        // 窓が鍵盤を得たら、WebView を受け手に戻す。
        // ファイルダイアログが受け手を奪ったまま返さないことがあり、
        // そうなると画面側では焦点が当たって見えるのにキーが 1 つも届かない。
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Focused(true) = event {
                for webview in window.webviews() {
                    let _ = webview.set_focus();
                }
            }
        })
        .register_asynchronous_uri_scheme_protocol(protocol::SCHEME, |ctx, request, responder| {
            let app = ctx.app_handle().clone();
            // 描画で画面を止めないため、要求ごとに別スレッドで応える。
            std::thread::spawn(move || responder.respond(protocol::serve(&app, &request)));
        })
        .setup(move |app| {
            app.manage(Store::load(app.handle()));
            if opening.is_empty() {
                open_window(app.handle(), "main", "")?;
            } else {
                for (index, path) in opening.iter().enumerate() {
                    let label = if index == 0 {
                        "main".to_string()
                    } else {
                        format!("book-{}", NEXT_WINDOW.fetch_add(1, std::sync::atomic::Ordering::Relaxed))
                    };
                    open_window(app.handle(), &label, &format!("?path={}", urlencode(path)))?;
                }
            }
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
    // 同じ大きさで真上に重ねると、増えたことに気付けない。少しずらす。
    let offset = (app.webview_windows().len() as f64) * 26.0 % 160.0;
    WebviewWindowBuilder::new(
        app,
        label,
        WebviewUrl::External(protocol::app_url(query).parse()?),
    )
    .title("tzreader")
    .inner_size(1000.0, 760.0)
    .position(60.0 + offset, 60.0 + offset)
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

#[tauri::command(async)]
fn open_book(
    books: tauri::State<'_, Library>,
    store: tauri::State<'_, Store>,
    path: String,
) -> Result<BookInfo, String> {
    let book = books.open(&path)?;
    let book = book.lock().unwrap();
    let info = describe(&book);
    // 書棚に出すための覚え書きを残す。表紙もここで作る。
    store.remember_meta(&path, &info.title, &info.authors, &info.format, cover_of(&book));
    Ok(info)
}

/// 書棚に並べる表紙。EPUB は書籍が指す画像をそのまま、PDF は 1 ページ目を小さく描く。
fn cover_of(book: &library::Book) -> Option<(String, Vec<u8>)> {
    let key = fingerprint(&book.path);
    match &book.content {
        Content::Epub {
            archive,
            publication,
        } => {
            let href = publication.cover_href.as_ref()?;
            let bytes = archive.read(href)?;
            let extension = href.rsplit_once('.').map(|(_, e)| e.to_lowercase());
            Some((format!("{key}.{}", extension.unwrap_or_else(|| "img".into())), bytes))
        }
        Content::Pdf { worker, .. } => Some((format!("{key}.png"), worker.render_page(0, 0.35)?)),
    }
}

/// パスから決まる短い名前。表紙の置き場所に使う。
fn fingerprint(path: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in path.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

/// 書籍を選ぶダイアログ。
///
/// 同期の命令は主スレッドで走る。そこで `blocking_pick_file` を呼ぶと、
/// ダイアログの応答を待つあいだイベントループが止まり、開いたまま固まる。
/// 待たない形（結果を受け取る関数を渡す形）を使い、受け取りは別スレッドで待つ。
#[tauri::command]
async fn pick_book(app: tauri::AppHandle) -> Option<String> {
    let (sender, receiver) = std::sync::mpsc::channel();
    app.dialog()
        .file()
        .add_filter("書籍", &["epub", "pdf"])
        .pick_file(move |file| {
            let _ = sender.send(file);
        });

    tauri::async_runtime::spawn_blocking(move || receiver.recv().ok().flatten())
        .await
        .ok()
        .flatten()
        .and_then(|file| file.into_path().ok())
        .map(|path| path.to_string_lossy().into_owned())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Shelved {
    path: String,
    name: String,
    title: String,
    authors: Vec<String>,
    format: String,
    cover: String,
    exists: bool,
}

/// 書棚。書籍を開き直さずに並べられるよう、覚え書きから作る。
#[tauri::command(async)]
fn library(store: tauri::State<'_, Store>) -> Vec<Shelved> {
    store
        .library()
        .into_iter()
        .map(|(path, state)| Shelved {
            name: paths::last_component(&path).to_string(),
            title: if state.title.is_empty() {
                paths::last_component(&path).to_string()
            } else {
                state.title
            },
            authors: state.authors,
            format: state.format,
            cover: state.cover,
            exists: std::path::Path::new(&path).exists(),
            path,
        })
        .collect()
}

/// 窓の名札。閉じた窓の番号を使い回さないよう、単調に増やす。
static NEXT_WINDOW: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);

#[tauri::command]
fn open_in_new_window(app: tauri::AppHandle, path: String, href: String) -> Result<(), String> {
    let n = NEXT_WINDOW.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let query = format!("?path={}&href={}", urlencode(&path), urlencode(&href));
    open_window(&app, &format!("book-{n}"), &query).map_err(|e| e.to_string())
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

#[tauri::command(async)]
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
#[tauri::command(async)]
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

#[tauri::command(async)]
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

#[tauri::command(async)]
fn page_text(library: tauri::State<'_, Library>, id: String, page: i32) -> Result<String, String> {
    let book = library.get(&id).ok_or("書籍が開かれていない")?;
    let book = book.lock().unwrap();
    let Content::Pdf { worker, .. } = &book.content else {
        return Err("PDF ではない".to_string());
    };
    Ok(worker.text_of_page(page))
}

/// ページの大きさ（ポイント）。合わせ方を計算するために要る。
#[tauri::command(async)]
fn page_size(library: tauri::State<'_, Library>, id: String, page: i32) -> Result<(f32, f32), String> {
    let book = library.get(&id).ok_or("書籍が開かれていない")?;
    let book = book.lock().unwrap();
    let Content::Pdf { worker, .. } = &book.content else {
        return Err("PDF ではない".to_string());
    };
    Ok(worker.page_size(page))
}

/// 書籍の診断。probe report と同じ値を返す。
#[tauri::command(async)]
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

/// 画面側の様子を標準エラーへ出す。原因を追うあいだだけ使う。
#[tauri::command]
fn ui_log(message: String) {
    eprintln!("[ui] {message}");
}

// MARK: 位置としおり

#[tauri::command(async)]
fn book_state(store: tauri::State<'_, Store>, path: String) -> BookState {
    store.state_of(&path)
}

#[tauri::command(async)]
fn remember_position(store: tauri::State<'_, Store>, path: String, position: Position) {
    store.remember(&path, position);
}

#[tauri::command(async)]
fn toggle_bookmark(
    store: tauri::State<'_, Store>,
    path: String,
    bookmark: Bookmark,
) -> Vec<Bookmark> {
    store.toggle_bookmark(&path, bookmark)
}

/// WebView を鍵盤の受け手にする。
///
/// 画面側の focus() では届かない。あちらが動かすのは文書の中の焦点だけで、
/// OS から見た受け手（macOS の first responder）は別にあるためである。
/// 窓の処理なので、ワーカースレッドへは逃がさない。
#[tauri::command]
fn focus_webview(webview: tauri::Webview) -> Result<(), String> {
    webview.set_focus().map_err(|e| e.to_string())
}

#[tauri::command(async)]
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
