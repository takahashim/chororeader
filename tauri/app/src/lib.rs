//! chororeader の Tauri 版。
//!
//! 画面は Web だが、書籍を解釈するのは chororeader-core であり、
//! その振る舞いは macOS 版・C# 版と conformance で突き合わせてある。
//! ここに書くのは、画面と core をつなぐ部分だけにする。
//!
//! 命令の一覧と、core を呼ぶだけの薄い受け渡しがここに残る。
//! 独立した仕組みは別に置く：窓と献立は windows、引くのは search_ui、
//! 索引の置き場所は indexes、配信は protocol、覚えておくものは store。

mod indexes;
mod windows;
mod library;
mod protocol;
mod search_ui;
pub mod store;

use serde::Serialize;
use tauri::{Emitter, Manager};
use tauri_plugin_dialog::DialogExt;

use chororeader_core::archive::ResourceProvider;
use chororeader_core::style::{ReaderStyle, Theme};
use chororeader_core::{css_compat, html_text, paths, preview, report};

use library::{describe, BookInfo, Content, Library};
use store::{Bookmark, BookState, Position, Store};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // 引数で渡された書籍は、1 冊につき 1 つの窓で開く。
    // 同じ書籍を 2 度渡してもよい。離れた 2 か所を並べて見るための道具である。
    let opening: Vec<String> = std::env::args().skip(1).filter(|a| !a.starts_with('-')).collect();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        // Windows には献立帯が無いと、鍵盤の割り当てを知る手立てがない。
        // macOS 版の献立と同じ並びにしてあり、動作確認もここから呼ぶ。
        .menu(windows::build_menu)
        .on_menu_event(|app, event| {
            let id = event.id().0.clone();

            // 画面を通さずに済むものは、ここで片付ける。
            // 書籍を 1 冊も持たない状態では書棚しか開いておらず、
            // 画面側の受け手が居るかどうかに頼りたくない。
            if let Some(kind) = id.strip_prefix("sample-") {
                if let Err(error) = open_sample_window(app, kind) {
                    eprintln!("サンプルを開けなかった: {error}");
                }
                return;
            }
            if id == "shelf" {
                let _ = windows::open_shelf_window(app);
                return;
            }

            // 残りは画面側が処理を持っている。名前だけ渡す。
            for (_, window) in app.webview_windows() {
                if window.is_focused().unwrap_or(false) {
                    let _ = window.emit("menu", id.clone());
                    return;
                }
            }
            let _ = app.emit("menu", id);
        })
        .manage(Library::default())
        .invoke_handler(tauri::generate_handler![
            open_book,
            pick_book,
            library,
            reader_css,
            settings,
            save_settings,
            search_ui::search_book,
            search_ui::page_marks,
            search_ui::search_library,
            search_ui::stop_library_search,
            search_ui::warm_indexes,
            preview_link,
            chapter_text,
            page_text,
            page_size,
            diagnose,
            open_in_new_window,
            open_shelf,
            open_sample,
            window_count,
            ping_menu,
            selftest_report,
            book_state,
            remember_position,
            toggle_bookmark,
            open_external,
            focus_webview,
            ui_log,
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
            // 落とされた書籍は、1 冊につき 1 つの窓で開く。
            if let tauri::WindowEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) = event {
                windows::open_dropped(&window.app_handle().clone(), paths);
            }
        })
        // 落とし込みは窓ではなく WebView 側に届くことがある。取りこぼさないよう両方で受ける。
        .on_webview_event(|webview, event| {
            if let tauri::WebviewEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) = event {
                windows::open_dropped(&webview.app_handle().clone(), paths);
            }
        })
        .register_asynchronous_uri_scheme_protocol(protocol::SCHEME, |ctx, request, responder| {
            let app = ctx.app_handle().clone();
            // 描画で画面を止めないため、要求ごとに別スレッドで応える。
            std::thread::spawn(move || responder.respond(protocol::serve(&app, &request)));
        })
        .setup(move |app| {
            app.manage(Store::load(app.handle()));
            app.manage(indexes::Indexes::load(app.handle()));

            if std::env::var("CHORO_SELFTEST").is_ok() {
                // 判定が終わらないまま居座らないための見張り。
                let handle = app.handle().clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(120));
                    eprintln!("動作確認が 120 秒以内に終わらなかった");
                    handle.exit(2);
                });
            }

            if opening.is_empty() {
                // 何も渡されなければ書棚から始める。macOS 版のライブラリ窓と同じ位置づけ。
                windows::open_shelf_window(app.handle())?;
            } else {
                for (index, path) in opening.iter().enumerate() {
                    let label = if index == 0 {
                        "main".to_string()
                    } else {
                        windows::next_label("book")
                    };
                    windows::open_window(app.handle(), &label, &format!("path={}", windows::urlencode(path)))?;
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Tauri の起動に失敗した");
}

// MARK: サンプル書籍
//
// 書籍を 1 冊も持たないマシンでも、アプリだけで読み方と機能を確かめられるようにする。
// 表示の経路が形式ごとに別なので、3 形式そろえてある。

const SAMPLES: &[(&str, &str, &[u8])] = &[
    (
        "reflowable",
        "sample-reflowable.epub",
        include_bytes!("../../../samples/sample-reflowable.epub"),
    ),
    (
        "fixed",
        "sample-fixed.epub",
        include_bytes!("../../../samples/sample-fixed.epub"),
    ),
    ("pdf", "sample.pdf", include_bytes!("../../../samples/sample.pdf")),
];

/// サンプルを取り出して開く。書き出す先は設定と同じところの下に置く。
#[tauri::command(async)]
fn open_sample(app: tauri::AppHandle, kind: String) -> Result<(), String> {
    open_sample_window(&app, &kind)
}

fn open_sample_window(app: &tauri::AppHandle, kind: &str) -> Result<(), String> {
    let path = write_sample(app, kind)?;
    let query = format!("path={}", windows::urlencode(&path));
    windows::open_window(app, &windows::next_label("book"), &query).map_err(|e| e.to_string())
}

fn write_sample(app: &tauri::AppHandle, kind: &str) -> Result<String, String> {
    let (_, name, data) = SAMPLES
        .iter()
        .find(|(id, _, _)| *id == kind)
        .ok_or("そのサンプルは無い")?;

    let directory = app
        .path()
        .app_config_dir()
        .map_err(|e| e.to_string())?
        .join("Samples");
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let path = directory.join(name);
    // 版が変わったら書き直す。大きさが同じなら中身も同じとみなす。
    let stale = std::fs::metadata(&path).map(|m| m.len() as usize != data.len()).unwrap_or(true);
    if stale {
        std::fs::write(&path, data).map_err(|e| e.to_string())?;
    }
    Ok(path.to_string_lossy().into_owned())
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
async fn pick_book(app: tauri::AppHandle, window: tauri::Window) -> Option<String> {
    let (sender, receiver) = std::sync::mpsc::channel();
    // 親を渡さないと、Windows では窓の裏に出ることがある。
    // 出ているのに見えないので、押しても何も起きないように見える。
    app.dialog()
        .file()
        .set_parent(&window)
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
    /// 一覧モードで見せる読み進み。位置を持たない書籍では空。
    progress: String,
}

/// 読み進みの見せ方。PDF はページ、EPUB は割合で言う。
fn progress_label(position: &Position) -> String {
    if position.page > 0 {
        return format!("p.{}", position.page + 1);
    }
    if position.href.is_empty() && position.progression <= 0.0 {
        return String::new();
    }
    format!("{}%", (position.progression * 100.0).round() as i64)
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
            progress: progress_label(&state.position),
            path,
        })
        .collect()
}

/// いま開いている窓の数。治具が「別窓で開いたか」を確かめるのに使う。
#[tauri::command]
fn window_count(app: tauri::AppHandle) -> usize {
    app.webview_windows().len()
}

/// 献立の道が通っているかを、治具から確かめるための試し撃ち。
///
/// 献立が効かなくなる壊れ方は、窓の権限が足りないときに起きた。
/// 押してみるまで分からない、という状態を残さないための命令である。
#[tauri::command]
fn ping_menu(app: tauri::AppHandle) -> Result<(), String> {
    app.emit("menu", "selftest-ping").map_err(|e| e.to_string())
}

/// 治具の結果を受け取る。届いた時点で判定は終わりなので、そのまま終了する。
#[tauri::command]
fn selftest_report(app: tauri::AppHandle, results: serde_json::Value) {
    let items = results.as_array().cloned().unwrap_or_default();
    // 飛ばしたものは不合格にしない。人の操作が要る検査は引数から走らせると必ず飛ぶ。
    let failed = items.iter().filter(|r| r["ok"] == false).count();
    let passed = items.iter().filter(|r| r["ok"] == true).count();
    let skipped = items.len() - failed - passed;

    let mut report = serde_json::to_string_pretty(&results).unwrap_or_default();
    report.push_str(&format!(
        "\n\n合格 {passed} ／ 不合格 {failed} ／ 飛ばした {skipped}\n"
    ));

    // Windows の release は端末を持たないため、標準出力はどこにも届かない。
    // 落ちたときにどの検査で落ちたのかが分からないのでは治具の意味がない。
    // 行き先を渡されていればそこへ書く。
    match std::env::var("CHORO_SELFTEST_OUT") {
        Ok(path) => {
            if let Err(error) = std::fs::write(&path, &report) {
                eprintln!("結果を書けなかった: {error}");
            }
        }
        Err(_) => print!("{report}"),
    }
    app.exit(if failed == 0 { 0 } else { 1 });
}

#[tauri::command]
fn open_shelf(app: tauri::AppHandle) -> Result<(), String> {
    windows::open_shelf_window(&app).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_in_new_window(
    app: tauri::AppHandle,
    path: String,
    href: String,
    fragment: Option<String>,
    query: Option<String>,
    nth: Option<usize>,
    list: Option<bool>,
) -> Result<(), String> {
    let mut params = format!("path={}&href={}", windows::urlencode(&path), windows::urlencode(&href));
    // 節への参照は、開いた先でもその位置に着きたい。
    if let Some(fragment) = fragment.filter(|f| !f.is_empty()) {
        params.push_str(&format!("&frag={}", windows::urlencode(&fragment)));
    }
    // 検索から開いたときは、当たった語を開いた先でも強調する。
    if let Some(query) = query.filter(|q| !q.is_empty()) {
        params.push_str(&format!("&q={}", windows::urlencode(&query)));
        // その章の何番目の当たりか。同じ語が何度も出る章で、押したものを選び直すために要る。
        params.push_str(&format!("&nth={}", nth.unwrap_or(0)));
        // 横断検索から全件へ渡るときだけ、開いた先で引き直して一覧も出す。
        if list.unwrap_or(false) {
            params.push_str("&list=1");
        }
    }
    windows::open_window(&app, &windows::next_label("book"), &params).map_err(|e| e.to_string())
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

// MARK: 本文を読み解く

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
