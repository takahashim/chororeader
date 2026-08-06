//! tzreader の Tauri 版。
//!
//! 画面は Web だが、書籍を解釈するのは tzreader-core であり、
//! その振る舞いは macOS 版・C# 版と conformance で突き合わせてある。
//! ここに書くのは、画面と core をつなぐ部分だけにする。

mod library;
mod protocol;
pub mod store;

use serde::Serialize;
use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::{Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_dialog::DialogExt;

use tzreader_core::archive::ResourceProvider;
use tzreader_core::publication::detect_format;
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
        // Windows には献立帯が無いと、鍵盤の割り当てを知る手立てがない。
        // macOS 版の献立と同じ並びにしてあり、動作確認もここから呼ぶ。
        .menu(build_menu)
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
                let _ = open_shelf_window(app);
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
            search_book,
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
                open_dropped(&window.app_handle().clone(), paths);
            }
        })
        // 落とし込みは窓ではなく WebView 側に届くことがある。取りこぼさないよう両方で受ける。
        .on_webview_event(|webview, event| {
            if let tauri::WebviewEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) = event {
                open_dropped(&webview.app_handle().clone(), paths);
            }
        })
        .register_asynchronous_uri_scheme_protocol(protocol::SCHEME, |ctx, request, responder| {
            let app = ctx.app_handle().clone();
            // 描画で画面を止めないため、要求ごとに別スレッドで応える。
            std::thread::spawn(move || responder.respond(protocol::serve(&app, &request)));
        })
        .setup(move |app| {
            app.manage(Store::load(app.handle()));

            if std::env::var("TZR_SELFTEST").is_ok() {
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
                open_shelf_window(app.handle())?;
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

/// 落とされた経路のうち、開ける形式のものを 1 つずつ窓に開く。
fn open_dropped(app: &tauri::AppHandle, paths: &[std::path::PathBuf]) {
    for path in paths {
        let Some(path) = path.to_str() else { continue };
        if detect_format(path).is_none() {
            continue;
        }
        let n = NEXT_WINDOW.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let query = format!("?path={}", urlencode(path));
        if let Err(error) = open_window(app, &format!("book-{n}"), &query) {
            eprintln!("落とされた書籍を開けなかった: {error}");
        }
    }
}

fn build_menu(app: &tauri::AppHandle) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    let item = |id: &str, label: &str, key: Option<&str>| -> tauri::Result<tauri::menu::MenuItem<tauri::Wry>> {
        let mut builder = MenuItemBuilder::with_id(id, label);
        if let Some(key) = key {
            builder = builder.accelerator(key);
        }
        builder.build(app)
    };

    // macOS では先頭の一組がアプリの献立として扱われる。
    // これを置かないと「ファイル」がそこへ吸われて消える。Windows では並びに影響しない。
    let application = SubmenuBuilder::new(app, "tzreader")
        .about(None)
        .separator()
        .hide()
        .quit()
        .build()?;

    let samples = SubmenuBuilder::new(app, "サンプルを開く")
        .item(&item("sample-reflowable", "リフロー型 EPUB", None)?)
        .item(&item("sample-fixed", "固定レイアウト EPUB", None)?)
        .item(&item("sample-pdf", "PDF", None)?)
        .build()?;

    let file = SubmenuBuilder::new(app, "ファイル")
        .item(&item("open", "開く…", Some("CmdOrCtrl+O"))?)
        .item(&samples)
        .item(&item("new-window", "この場所を新しいウィンドウで開く", Some("CmdOrCtrl+N"))?)
        .separator()
        .item(&item("shelf", "書棚", Some("CmdOrCtrl+L"))?)
        .separator()
        .close_window()
        .build()?;

    let go = SubmenuBuilder::new(app, "移動")
        .item(&item("back", "戻る", Some("CmdOrCtrl+["))?)
        .item(&item("forward", "進む", Some("CmdOrCtrl+]"))?)
        .separator()
        .item(&item("prev", "前の章／ページ", Some("CmdOrCtrl+Up"))?)
        .item(&item("next", "次の章／ページ", Some("CmdOrCtrl+Down"))?)
        .separator()
        .item(&item("find", "検索", Some("CmdOrCtrl+F"))?)
        .item(&item("bookmark", "しおりを追加", Some("CmdOrCtrl+D"))?)
        .build()?;

    let view = SubmenuBuilder::new(app, "表示")
        .item(&item("sidebar", "サイドバーの表示を切り替え", Some("CmdOrCtrl+\\"))?)
        .separator()
        .item(&item("zoom-in", "大きくする", Some("CmdOrCtrl+Plus"))?)
        .item(&item("zoom-out", "小さくする", Some("CmdOrCtrl+-"))?)
        .item(&item("zoom-reset", "標準の大きさ", Some("CmdOrCtrl+0"))?)
        .build()?;

    let help = SubmenuBuilder::new(app, "ヘルプ")
        .item(&item("diagnose", "この書籍の診断…", Some("CmdOrCtrl+Alt+I"))?)
        .separator()
        .item(&item("selftest", "動作確認…", None)?)
        .build()?;

    MenuBuilder::new(app)
        .items(&[&application, &file, &go, &view, &help])
        .build()
}

fn open_window(
    app: &tauri::AppHandle,
    label: &str,
    query: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    build_window(app, label, query, "tzreader", 1000.0, 760.0)
}

/// 書棚の窓。1 つしか持たない。すでにあるなら前へ出す。
///
/// 書棚を窓として独立させているのは macOS 版に倣ったものである。
/// 書棚が本を配る側、読書の窓が読む側、と役割が分かれ、
/// 「選んだ本がどの窓に開くのか」が決まる。
fn open_shelf_window(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(window) = app.get_webview_window("shelf") {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    build_window(app, "shelf", "?shelf=1", "書棚", 900.0, 640.0)
}

fn build_window(
    app: &tauri::AppHandle,
    label: &str,
    query: &str,
    title: &str,
    width: f64,
    height: f64,
) -> Result<(), Box<dyn std::error::Error>> {
    // 旗はここで付ける。窓ごとに書き分けると、書棚のように渡し忘れる場所が出る。
    let query = format!("{query}{}", window_flags());

    // 同じ大きさで真上に重ねると、増えたことに気付けない。少しずらす。
    let offset = (app.webview_windows().len() as f64) * 26.0 % 160.0;
    WebviewWindowBuilder::new(
        app,
        label,
        WebviewUrl::External(protocol::app_url(&query).parse()?),
    )
    .title(title)
    .inner_size(width, height)
    .position(60.0 + offset, 60.0 + offset)
    .build()?;
    Ok(())
}

/// 画面へ渡す旗。
///
/// TZR_DEBUG は様子を標準エラーへ出す。
/// TZR_SELFTEST は開いた直後に動作確認を走らせて結果を出して終わる。
/// 動作確認は最初の窓だけで走らせる。治具が開いた窓でも走ると、際限がなくなる。
fn window_flags() -> String {
    let mut flags = String::new();
    if std::env::var("TZR_DEBUG").is_ok() {
        flags.push_str("&debug=1");
    }
    static SELFTEST_LEFT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
    if std::env::var("TZR_SELFTEST").is_ok()
        && SELFTEST_LEFT.swap(false, std::sync::atomic::Ordering::Relaxed)
    {
        flags.push_str("&selftest=1");
    }
    flags
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
    let n = NEXT_WINDOW.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let query = format!("?path={}", urlencode(&path));
    open_window(app, &format!("book-{n}"), &query).map_err(|e| e.to_string())
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
    match std::env::var("TZR_SELFTEST_OUT") {
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
    open_shelf_window(&app).map_err(|e| e.to_string())
}

/// 窓の名札。閉じた窓の番号を使い回さないよう、単調に増やす。
static NEXT_WINDOW: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);

#[tauri::command]
fn open_in_new_window(
    app: tauri::AppHandle,
    path: String,
    href: String,
    fragment: Option<String>,
) -> Result<(), String> {
    let n = NEXT_WINDOW.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut query = format!("?path={}&href={}", urlencode(&path), urlencode(&href));
    // 節への参照は、開いた先でもその位置に着きたい。
    if let Some(fragment) = fragment.filter(|f| !f.is_empty()) {
        query.push_str(&format!("&frag={}", urlencode(&fragment)));
    }
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
