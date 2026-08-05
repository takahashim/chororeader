//! Tauri が、tzreader の Windows 版の土台として使えるかを確かめる。
//!
//! 答えを出したい問いは 4 つある。
//!
//! 1. 書籍由来の JavaScript を止めたまま、アプリ側のコードで本文の DOM を触れるか。
//!    macOS 版は WKWebView の `allowsContentJavaScript = false`、
//!    Windows の WebView2 版は `IsScriptEnabled = false` でこれを満たしていた。
//!    Tauri は画面そのものが JavaScript でできているため、同じ手は使えない。
//!    代わりに iframe の sandbox で止められるかを見る。
//! 2. EPUB の中身を、展開せずに ZIP から独自スキームで配れるか。
//!    macOS 版の WKURLSchemeHandler、WebView2 版の WebResourceRequested に当たるもの。
//! 3. MuPDF で描いたページを WebView へ渡したとき、拡大しながらの連続再描画に耐えるか。
//! 4. 1 と 2 で使う仕組みが、アプリの画面と同じ生成元に載るか。
//!    載らないと親から iframe の DOM を触れず、1 の答えが変わる。
//!
//! 画面は出るが操作は要らない。判定が終わると JSON を標準出力へ書いて終了する。

use std::io::Read;
use std::sync::mpsc;
use std::sync::Mutex;
use std::time::Instant;

use tauri::http::{Request, Response};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

const SCHEME: &str = "tzr";

/// 判定が終わらないまま画面を占有しないための上限。
const DEADLINE_SECS: u64 = 120;

/// 書籍に見立てた章。自前の script が動いたかどうかを見分けられるようにしてある。
const PROBE_CHAPTER: &str = r#"<!DOCTYPE html>
<html lang="ja"><head><meta charset="utf-8"><title>original</title></head>
<body>
<p id="p">untouched</p>
<script>
  document.title = "CONTENT-JS-RAN";
  document.getElementById('p').textContent = "CONTENT-JS-RAN";
</script>
</body></html>
"#;

/// 描画の依頼。MuPDF の Document は別スレッドへ渡せないため、
/// 開いたスレッドに閉じ込めてチャネル越しに使う。
struct RenderJob {
    page: i32,
    scale: f32,
    reply: mpsc::Sender<Result<Vec<u8>, String>>,
}

struct Spike {
    epub: Option<Mutex<zip::ZipArchive<std::fs::File>>>,
    /// EPUB の中で最初に見つかった XHTML。実書籍を配れることの証拠に使う。
    epub_chapter: Option<String>,
    renderer: Option<mpsc::Sender<RenderJob>>,
    pdf_pages: i32,
}

pub fn run() {
    let epub_path = std::env::var("TZR_EPUB").ok();
    let pdf_path = std::env::var("TZR_PDF").ok();

    let (epub, epub_chapter) = match epub_path.as_deref() {
        Some(path) => open_epub(path),
        None => (None, None),
    };
    let (renderer, pdf_pages) = match pdf_path.as_deref() {
        Some(path) => start_renderer(path),
        None => (None, 0),
    };

    let state = Spike { epub, epub_chapter, renderer, pdf_pages };

    tauri::Builder::default()
        .manage(state)
        .invoke_handler(tauri::generate_handler![report])
        .register_asynchronous_uri_scheme_protocol(SCHEME, |ctx, request, responder| {
            let app = ctx.app_handle().clone();
            // 描画で画面を止めないため、要求ごとに別スレッドで応える。
            std::thread::spawn(move || {
                responder.respond(serve(&app, &request));
            });
        })
        .setup(|app| {
            // 画面そのものも独自スキームから配る。
            // こうしないと本文の iframe と生成元が分かれ、親から DOM を触れない。
            let base = if cfg!(windows) {
                format!("http://{SCHEME}.localhost")
            } else {
                format!("{SCHEME}://localhost")
            };
            let url = format!("{base}/app/index.html");

            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url.parse()?))
                .title("tzreader spike")
                .inner_size(900.0, 700.0)
                .build()?;

            let handle = app.handle().clone();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_secs(DEADLINE_SECS));
                eprintln!("{DEADLINE_SECS} 秒以内に判定が終わらなかった");
                handle.exit(1);
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Tauri の起動に失敗した");
}

/// 画面からの報告を受け取る。これが届いた時点でスパイクは終わり。
#[tauri::command]
fn report(app: tauri::AppHandle, result: serde_json::Value) {
    let ok = result.get("assumptionHolds").and_then(|v| v.as_bool()).unwrap_or(false);
    println!("{}", serde_json::to_string_pretty(&result).unwrap());
    app.exit(if ok { 0 } else { 1 });
}

fn open_epub(path: &str) -> (Option<Mutex<zip::ZipArchive<std::fs::File>>>, Option<String>) {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(e) => {
            eprintln!("EPUB を開けなかった: {e}");
            return (None, None);
        }
    };
    let mut archive = match zip::ZipArchive::new(file) {
        Ok(archive) => archive,
        Err(e) => {
            eprintln!("ZIP として読めなかった: {e}");
            return (None, None);
        }
    };
    // 目次から辿るのはここの目的ではない。配れることさえ分かればよい。
    let chapter = (0..archive.len()).find_map(|i| {
        let name = archive.by_index(i).ok()?.name().to_string();
        let lower = name.to_ascii_lowercase();
        (lower.ends_with(".xhtml") || lower.ends_with(".html")).then_some(name)
    });
    (Some(Mutex::new(archive)), chapter)
}

/// PDF を開いたまま持つスレッドを起こす。MuPDF の型はスレッドを跨げない。
fn start_renderer(path: &str) -> (Option<mpsc::Sender<RenderJob>>, i32) {
    let (tx, rx) = mpsc::channel::<RenderJob>();
    let (ready_tx, ready_rx) = mpsc::channel::<Result<i32, String>>();
    let path = path.to_string();

    std::thread::spawn(move || {
        let document = match mupdf::Document::open(&path).and_then(|d| {
            let n = d.page_count()?;
            Ok((d, n))
        }) {
            Ok((document, pages)) => {
                let _ = ready_tx.send(Ok(pages));
                document
            }
            Err(e) => {
                let _ = ready_tx.send(Err(e.to_string()));
                return;
            }
        };

        let colorspace = mupdf::Colorspace::device_rgb();
        while let Ok(job) = rx.recv() {
            let result = render(&document, &colorspace, job.page, job.scale);
            let _ = job.reply.send(result);
        }
    });

    match ready_rx.recv() {
        Ok(Ok(pages)) => (Some(tx), pages),
        Ok(Err(e)) => {
            eprintln!("PDF を開けなかった: {e}");
            (None, 0)
        }
        Err(_) => (None, 0),
    }
}

fn render(
    document: &mupdf::Document,
    colorspace: &mupdf::Colorspace,
    page: i32,
    scale: f32,
) -> Result<Vec<u8>, String> {
    let page = document.load_page(page).map_err(|e| e.to_string())?;
    let matrix = mupdf::Matrix::new_scale(scale, scale);
    let pixmap = page
        .to_pixmap(&matrix, colorspace, false, true)
        .map_err(|e| e.to_string())?;
    let mut png = Vec::new();
    pixmap.write_to(&mut png, mupdf::ImageFormat::PNG).map_err(|e| e.to_string())?;
    Ok(png)
}

fn serve(app: &tauri::AppHandle, request: &Request<Vec<u8>>) -> Response<Vec<u8>> {
    let uri = request.uri();
    let path = uri.path().trim_start_matches('/').to_string();
    let state = app.state::<Spike>();

    if path == "app/index.html" {
        return html(include_str!("../../ui/index.html").as_bytes().to_vec());
    }
    if path == "probe/chapter.xhtml" {
        return html(PROBE_CHAPTER.as_bytes().to_vec());
    }
    if path == "probe/info.json" {
        let body = serde_json::json!({
            "epubChapter": state.epub_chapter,
            "pdfPages": state.pdf_pages,
        });
        return json(body.to_string().into_bytes());
    }
    if let Some(href) = path.strip_prefix("book/") {
        return serve_book(&state, href);
    }
    if let Some(rest) = path.strip_prefix("pdf/") {
        return serve_pdf(&state, rest);
    }
    not_found()
}

fn serve_book(state: &Spike, href: &str) -> Response<Vec<u8>> {
    let Some(epub) = &state.epub else { return not_found() };
    let Ok(mut archive) = epub.lock() else { return not_found() };
    let Ok(mut entry) = archive.by_name(href) else { return not_found() };
    let mut bytes = Vec::new();
    if entry.read_to_end(&mut bytes).is_err() {
        return not_found();
    }
    // 書籍側の XHTML は text/html として渡す。
    // 名前空間の宣言が無い断片を XHTML 扱いすると解析に失敗するのは macOS 版で踏んだ通り。
    html(bytes)
}

/// `pdf/<ページ番号>/<倍率>` を描いて PNG で返す。末尾のクエリはキャッシュ避けに使う。
fn serve_pdf(state: &Spike, rest: &str) -> Response<Vec<u8>> {
    let Some(renderer) = &state.renderer else { return not_found() };
    let mut parts = rest.split('/');
    let page: i32 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    let scale: f32 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(1.0);

    let (reply, answer) = mpsc::channel();
    let started = Instant::now();
    if renderer.send(RenderJob { page, scale, reply }).is_err() {
        return not_found();
    }
    match answer.recv() {
        // 描画にかかった時間を添える。画面側で測る往復時間との差が、WebView へ渡す費用になる。
        Ok(Ok(png)) => Response::builder()
            .header("Content-Type", "image/png")
            .header("Cache-Control", "no-store")
            .header("X-Render-Ms", started.elapsed().as_millis().to_string())
            .header("Access-Control-Expose-Headers", "X-Render-Ms")
            .body(png)
            .unwrap(),
        _ => not_found(),
    }
}

fn html(body: Vec<u8>) -> Response<Vec<u8>> {
    Response::builder()
        .header("Content-Type", "text/html; charset=utf-8")
        .body(body)
        .unwrap()
}

fn json(body: Vec<u8>) -> Response<Vec<u8>> {
    Response::builder()
        .header("Content-Type", "application/json; charset=utf-8")
        .body(body)
        .unwrap()
}

fn not_found() -> Response<Vec<u8>> {
    Response::builder().status(404).body(Vec::new()).unwrap()
}
