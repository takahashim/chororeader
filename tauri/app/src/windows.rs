//! 窓と献立の組み立て。
//!
//! 書籍の中身には触れない。どの窓にどの文書を出すか、どの旗を渡すか、
//! 落とされたものをどう配るか、という OS 寄りの仕事だけを持つ。
//!
//! 窓ごとに文書が違う（読書は index.html、書棚は shelf.html）ので、
//! 経路の組み立てもここに集める。窓を増やすときに書き分けを 1 か所で済ませるため。

use std::sync::atomic::{AtomicUsize, Ordering};

use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

use chororeader_core::publication::detect_format;

use crate::protocol;

/// 落とされた経路のうち、開ける形式のものを 1 つずつ窓に開く。
///
/// 落とされた知らせは WebView から届くこともある。その最中に窓を作ると、
/// Windows では枠だけ出来て中身が空になる（lib.rs「窓を増やす」）。
/// 知らせを受けた場をすぐ離れ、窓は別のスレッドから頼む。
pub fn open_dropped(app: &tauri::AppHandle, paths: &[std::path::PathBuf]) {
    let opening: Vec<String> = paths
        .iter()
        .filter_map(|path| path.to_str())
        .filter(|path| detect_format(path).is_some())
        .map(|path| path.to_string())
        .collect();
    if opening.is_empty() {
        return;
    }

    let app = app.clone();
    std::thread::spawn(move || {
        for path in opening {
            let label = next_label("book");
            let query = format!("path={}", urlencode(&path));
            if let Err(error) = open_window(&app, &label, &query) {
                eprintln!("落とされた書籍を開けなかった: {error}");
            }
        }
    });
}

pub fn build_menu(app: &tauri::AppHandle) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
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

pub fn open_window(
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
pub fn open_shelf_window(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
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

pub fn urlencode(value: &str) -> String {
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

/// 窓の名札。閉じた窓の番号を使い回さないよう、単調に増やす。
static NEXT_WINDOW: AtomicUsize = AtomicUsize::new(1);

/// 次の窓の名札。同じ書籍を何度開いても別の窓になる。
pub fn next_label(kind: &str) -> String {
    format!("{kind}-{}", NEXT_WINDOW.fetch_add(1, Ordering::Relaxed))
}
