//! chororeader の Tauri 版。
//!
//! 画面は Web だが、書籍を解釈するのは chororeader-core であり、
//! その振る舞いは macOS 版・C# 版と conformance で突き合わせてある。
//! ここに書くのは、画面と core をつなぐ部分だけにする。

mod indexes;
mod library;
mod protocol;
pub mod store;

use std::sync::atomic::{AtomicUsize, Ordering};

use serde::Serialize;
use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::{Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_dialog::DialogExt;

use chororeader_core::archive::ResourceProvider;
use chororeader_core::publication::detect_format;
use chororeader_core::style::{ReaderStyle, Theme};
use chororeader_core::{css_compat, html_text, paths, pdf, preview, report, search};

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
            page_marks,
            search_library,
            stop_library_search,
            warm_indexes,
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
                open_shelf_window(app.handle())?;
            } else {
                for (index, path) in opening.iter().enumerate() {
                    let label = if index == 0 {
                        "main".to_string()
                    } else {
                        format!("book-{}", NEXT_WINDOW.fetch_add(1, std::sync::atomic::Ordering::Relaxed))
                    };
                    open_window(app.handle(), &label, &format!("path={}", urlencode(path)))?;
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
        let query = format!("path={}", urlencode(path));
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
    let application = SubmenuBuilder::new(app, "chororeader")
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
    params: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    build_window(app, label, "index.html", params, "chororeader", 1000.0, 760.0)
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
    build_window(app, "shelf", "shelf.html", "", "書棚", 900.0, 640.0)
}

/// 窓を 1 つ作る。`page` がその窓の文書で、`params` は `&` で繋いだ引数（先頭の `?` は付けない）。
fn build_window(
    app: &tauri::AppHandle,
    label: &str,
    page: &str,
    params: &str,
    title: &str,
    width: f64,
    height: f64,
) -> Result<(), Box<dyn std::error::Error>> {
    // 旗はここで付ける。窓ごとに書き分けると、書棚のように渡し忘れる場所が出る。
    let all = [params, &window_flags()].join("&");
    let all = all.trim_matches('&').to_string();
    let query = if all.is_empty() { String::new() } else { format!("?{all}") };

    // 同じ大きさで真上に重ねると、増えたことに気付けない。少しずらす。
    let offset = (app.webview_windows().len() as f64) * 26.0 % 160.0;
    WebviewWindowBuilder::new(
        app,
        label,
        WebviewUrl::External(protocol::app_url(page, &query).parse()?),
    )
    .title(title)
    .inner_size(width, height)
    .position(60.0 + offset, 60.0 + offset)
    .build()?;
    Ok(())
}

/// 画面へ渡す旗。
///
/// CHORO_DEBUG は様子を標準エラーへ出す。
/// CHORO_SELFTEST は開いた直後に動作確認を走らせて結果を出して終わる。
/// 動作確認は最初の窓だけで走らせる。治具が開いた窓でも走ると、際限がなくなる。
fn window_flags() -> String {
    let mut flags: Vec<&str> = Vec::new();
    if std::env::var("CHORO_DEBUG").is_ok() {
        flags.push("debug=1");
    }
    static SELFTEST_LEFT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
    if std::env::var("CHORO_SELFTEST").is_ok()
        && SELFTEST_LEFT.swap(false, std::sync::atomic::Ordering::Relaxed)
    {
        flags.push("selftest=1");
    }
    flags.join("&")
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
    let query = format!("path={}", urlencode(&path));
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
    open_shelf_window(&app).map_err(|e| e.to_string())
}

/// 窓の名札。閉じた窓の番号を使い回さないよう、単調に増やす。
static NEXT_WINDOW: AtomicUsize = AtomicUsize::new(1);

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
    let n = NEXT_WINDOW.fetch_add(1, Ordering::Relaxed);
    let mut params = format!("path={}&href={}", urlencode(&path), urlencode(&href));
    // 節への参照は、開いた先でもその位置に着きたい。
    if let Some(fragment) = fragment.filter(|f| !f.is_empty()) {
        params.push_str(&format!("&frag={}", urlencode(&fragment)));
    }
    // 検索から開いたときは、当たった語を開いた先でも強調する。
    if let Some(query) = query.filter(|q| !q.is_empty()) {
        params.push_str(&format!("&q={}", urlencode(&query)));
        // その章の何番目の当たりか。同じ語が何度も出る章で、押したものを選び直すために要る。
        params.push_str(&format!("&nth={}", nth.unwrap_or(0)));
        // 横断検索から全件へ渡るときだけ、開いた先で引き直して一覧も出す。
        if list.unwrap_or(false) {
            params.push_str("&list=1");
        }
    }
    open_window(&app, &format!("book-{n}"), &params).map_err(|e| e.to_string())
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

/// 1 冊ぶんの当たり。
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct BookHits {
    path: String,
    title: String,
    hits: Vec<Hit>,
    /// 上限で打ち切ったか。打ち切ったときは、その本を開いて全件を見る道を出す。
    truncated: bool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Hit {
    href: String,
    page: i32,
    progression: f64,
    title: String,
    excerpt: String,
    is_code: bool,
    /// その章の中で何番目の当たりか。飛んだ先で同じ当たりを選び直すために使う。
    nth: usize,
    /// 紙面の当たりを囲む枠。点の座標で、倍率を掛ければ画素になる。EPUB では空。
    rects: Vec<[f32; 4]>,
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
            Ok(epub_hits(outcome.results))
        }
        Content::Pdf { worker, .. } => Ok(worker
            .search(&query, search::RESULT_LIMIT)
            .into_iter()
            .map(pdf_hit)
            .collect()),
    }
}

/// 紙面のそのページで、当たりを囲む枠。
///
/// 別の窓で開き直したときは当たりの一覧を持っていないので、その場でもう一度尋ねる。
/// 引き直しても同じ語を同じ道具で探すので、枠は最初に押したものと同じになる。
#[tauri::command(async)]
fn page_marks(
    library: tauri::State<'_, Library>,
    id: String,
    page: i32,
    query: String,
) -> Vec<[f32; 4]> {
    let Some(book) = library.get(&id) else {
        return Vec::new();
    };
    let book = book.lock().unwrap();
    let Content::Pdf { worker, .. } = &book.content else {
        return Vec::new();
    };
    worker
        .search_within(&query, 1, Some(vec![page as u32]))
        .into_iter()
        .next()
        .map(|found| found.rects)
        .unwrap_or_default()
}

fn epub_hits(results: Vec<search::SearchResult>) -> Vec<Hit> {
    results
        .into_iter()
        .map(|result| Hit {
            href: result.locator.href.unwrap_or_default(),
            page: 0,
            progression: result.locator.progression,
            title: result.chapter_title,
            excerpt: format!("{}{}{}", result.before, result.matched, result.after),
            is_code: result.is_code,
            nth: result.nth,
            rects: Vec::new(),
        })
        .collect()
}

fn pdf_hit(found: pdf::PageHit) -> Hit {
    Hit {
        href: String::new(),
        page: found.page,
        progression: 0.0,
        title: format!("p.{}", found.page + 1),
        excerpt: found.excerpt,
        is_code: false,
        nth: 0,
        rects: found.rects,
    }
}

// MARK: 蔵書を横断して引く

/// 1 冊から拾う上限。1 冊が結果を埋め尽くさないようにする。
const PER_BOOK_LIMIT: usize = 20;

/// いま生きている走査の名札。名札を付けるのは画面側で、引き直すと変わる。
/// 走っている走査は自分の名札が外れたのを見て、その場で降りる。
static SEARCH_RUN: AtomicUsize = AtomicUsize::new(0);

/// 走査の進み具合。1 冊ぶん終わるたびに画面へ送る。
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct SearchProgress {
    run: usize,
    searched: usize,
    total: usize,
    /// いま索引を作っている書籍の題名。作っていないあいだは載せない。
    building: Option<String>,
    /// 当たりのあった書籍。当たらなかった本については何も載せない。
    book: Option<BookHits>,
    done: bool,
}

/// 書棚にある書籍を横断して引く。
///
/// 1 冊ずつ索引で候補を絞り、残った章（PDF ならページ）だけを走査し直す。
/// 索引は候補を減らすだけなので、当たりは 1 冊ずつ開いて引いたときと変わらない。
///
/// 索引がまだ無い書籍はその場で作る。1 冊目は書籍を丸ごと読むぶん遅い。
/// 待たされている間も手が止まらないよう、走査は別のスレッドへ置き、
/// 1 冊ぶん終わるたびに `library-search` で送る。
#[tauri::command]
fn search_library(app: tauri::AppHandle, query: String, run: usize) {
    SEARCH_RUN.store(run, Ordering::Relaxed);
    let query = query.trim().to_string();
    if query.is_empty() {
        return;
    }
    std::thread::spawn(move || scan_library(&app, run, &query));
}

/// 引くのをやめる。走っている走査は、次の 1 冊へ移るところで降りる。
#[tauri::command]
fn stop_library_search() {
    // 0 は画面が付けない名札なので、どの走査も自分のものだとは思わない。
    SEARCH_RUN.store(0, Ordering::Relaxed);
}

/// 引かれる前に、置いてある索引をほどいておく。最初の検索を待たせないため。
/// 書棚を出すたびに呼ばれるが、ほどくのは一度でよい。
#[tauri::command]
fn warm_indexes(app: tauri::AppHandle) {
    static WARMED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if WARMED.swap(true, Ordering::Relaxed) {
        return;
    }
    std::thread::spawn(move || {
        let paths: Vec<String> = app
            .state::<Store>()
            .library()
            .into_iter()
            .map(|(path, _)| path)
            .collect();
        app.state::<indexes::Indexes>().warm(&paths);
    });
}

fn scan_library(app: &tauri::AppHandle, run: usize, query: &str) {
    let alive = || SEARCH_RUN.load(Ordering::Relaxed) == run;

    // 見つからない本は引きようがない。冊数にも数えない。
    let books: Vec<(String, String)> = app
        .state::<Store>()
        .library()
        .into_iter()
        .filter(|(path, _)| std::path::Path::new(path).exists())
        .map(|(path, state)| {
            let title = if state.title.is_empty() {
                paths::last_component(&path).to_string()
            } else {
                state.title
            };
            (path, title)
        })
        .collect();

    let total = books.len();
    let report = |searched: usize, building: Option<String>, book: Option<BookHits>, done: bool| {
        let _ = app.emit(
            "library-search",
            SearchProgress {
                run,
                searched,
                total,
                building,
                book,
                done,
            },
        );
    };
    // 何冊を相手にするのかは、1 冊目を引き終わる前に伝える。
    report(0, None, None, false);

    let indexes = app.state::<indexes::Indexes>();
    for (finished, (path, title)) in books.into_iter().enumerate() {
        if !alive() {
            return;
        }
        // 索引がまだ無い本はその場で作る。そのあいだ何も出ないと、止まって見える。
        if indexes.cached(&path).is_none() {
            report(finished, Some(title.clone()), None, false);
        }
        let found = hits_in(&indexes, &path, &title, query);
        if !alive() {
            return;
        }
        report(finished + 1, None, found, false);
    }
    report(total, None, None, true);
}

/// 1 冊を引く。当たりが無ければ何も返さない。
fn hits_in(
    indexes: &indexes::Indexes,
    path: &str,
    title: &str,
    query: &str,
) -> Option<BookHits> {
    // 索引があるうちは書籍を開かない。当たらない本には触らずに済む。
    let mut source = None;
    let index = match indexes.cached(path) {
        Some(index) => index,
        None => {
            let opened = indexes::open_source(path)?;
            let index = indexes.ensure(path, &opened)?;
            source = Some(opened);
            index
        }
    };

    let candidates = index.candidates(query);
    if candidates.as_ref().is_some_and(Vec::is_empty) {
        return None;
    }

    let source = match source {
        Some(source) => source,
        None => indexes::open_source(path)?,
    };
    let (hits, truncated) = match &source {
        indexes::Source::Epub {
            archive,
            publication,
        } => {
            let outcome = search::search_epub_within(
                archive,
                publication,
                query,
                candidates.as_deref(),
                PER_BOOK_LIMIT,
            );
            (epub_hits(outcome.results), outcome.truncated)
        }
        indexes::Source::Pdf { worker } => {
            let found = worker.search_within(query, PER_BOOK_LIMIT, candidates);
            let truncated = found.len() >= PER_BOOK_LIMIT;
            (found.into_iter().map(pdf_hit).collect(), truncated)
        }
    };

    if hits.is_empty() {
        return None;
    }
    Some(BookHits {
        path: path.to_string(),
        title: title.to_string(),
        hits,
        truncated,
    })
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
