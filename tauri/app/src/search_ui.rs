//! 引く。1 冊の中と、蔵書を横断しての 2 つ。
//!
//! 当たりを決めるのは core（search / pdf）で、ここは画面へ渡す形に直し、
//! 横断のときは 1 冊ずつ索引で候補を絞ってから走査し直す。
//!
//! 索引は候補を減らすだけで当たりを決めない。だから絞っても絞らなくても
//! 当たりは変わらない（spec.md 10.4）。索引そのものの置き場所は indexes が持つ。

use std::sync::atomic::{AtomicUsize, Ordering};

use serde::Serialize;
use tauri::{Emitter, Manager};

use chororeader_core::{paths, pdf, search};

use crate::indexes;
use crate::library::{Content, Library};
use crate::store::Store;

/// 1 冊ぶんの当たり。
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct BookHits {
    pub path: String,
    pub title: String,
    pub hits: Vec<Hit>,
    /// 上限で打ち切ったか。打ち切ったときは、その本を開いて全件を見る道を出す。
    pub truncated: bool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Hit {
    pub href: String,
    pub page: i32,
    pub progression: f64,
    pub title: String,
    pub excerpt: String,
    pub is_code: bool,
    /// その章の中で何番目の当たりか。飛んだ先で同じ当たりを選び直すために使う。
    pub nth: usize,
    /// 紙面の当たりを囲む枠。点の座標で、倍率を掛ければ画素になる。EPUB では空。
    pub rects: Vec<[f32; 4]>,
}

#[tauri::command(async)]
pub fn search_book(
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
pub fn page_marks(
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

/// 1 冊から拾う上限。1 冊が結果を埋め尽くさないようにする。
const PER_BOOK_LIMIT: usize = 20;

/// いま生きている走査の名札。名札を付けるのは画面側で、引き直すと変わる。
/// 走っている走査は自分の名札が外れたのを見て、その場で降りる。
static SEARCH_RUN: AtomicUsize = AtomicUsize::new(0);

/// 走査の進み具合。1 冊ぶん終わるたびに画面へ送る。
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SearchProgress {
    pub run: usize,
    pub searched: usize,
    pub total: usize,
    /// いま索引を作っている書籍の題名。作っていないあいだは載せない。
    pub building: Option<String>,
    /// 当たりのあった書籍。当たらなかった本については何も載せない。
    pub book: Option<BookHits>,
    pub done: bool,
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
pub fn search_library(app: tauri::AppHandle, query: String, run: usize) {
    SEARCH_RUN.store(run, Ordering::Relaxed);
    let query = query.trim().to_string();
    if query.is_empty() {
        return;
    }
    std::thread::spawn(move || scan_library(&app, run, &query));
}

/// 引くのをやめる。走っている走査は、次の 1 冊へ移るところで降りる。
#[tauri::command]
pub fn stop_library_search() {
    // 0 は画面が付けない名札なので、どの走査も自分のものだとは思わない。
    SEARCH_RUN.store(0, Ordering::Relaxed);
}

/// 引かれる前に、置いてある索引をほどいておく。最初の検索を待たせないため。
/// 書棚を出すたびに呼ばれるが、ほどくのは一度でよい。
#[tauri::command]
pub fn warm_indexes(app: tauri::AppHandle) {
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
