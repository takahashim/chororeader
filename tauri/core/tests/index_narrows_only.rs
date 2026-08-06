//! 索引で絞った検索が、絞らない検索と一字も変わらないこと。
//!
//! spec.md 10.4 の「索引は候補を絞るだけで、当たりを決めない」を機械で押さえる。
//! ここが崩れると、検索結果が索引の有無で変わり、conformance の
//! 「検索のヒット位置、件数、順序」を索引の導入で動かしてしまう。
//!
//! macOS 版の SearchIndexTests と対になる検査である。
//! 片方の実装にしか無いと、もう一方が黙って崩れる。

use chororeader_core::archive::{EpubArchive, ResourceProvider};
use chororeader_core::index::Index;
use chororeader_core::publication::Publication;
use chororeader_core::{css_compat, epub_parser, html_text, search};

/// 当たるもの、当たらないもの、1 文字、全角と半角の混ざったものを並べる。
const QUERIES: &[&str] = &[
    "本文", "章", "の", "語", "hello", "ファイル名", "第 1 章", "出てこない語", "a", "",
];

const BOOKS: &[&str] = &[
    "epub3-basic.epub",
    "epub2-ncx.epub",
    "footnotes.epub",
    "legacy-css.epub",
    "encoded-paths.epub",
    "rtl.epub",
    "nonlinear-spine.epub",
    "repeated-spine.epub",
];

fn fixture(name: &str) -> String {
    format!("{}/../../conformance/fixtures/{name}", env!("CARGO_MANIFEST_DIR"))
}

/// 索引に載せる本文。app の indexes::unit_texts と同じ切り方にしてある。
fn unit_texts(archive: &EpubArchive, publication: &Publication) -> Vec<String> {
    publication
        .reading_order
        .iter()
        .map(|link| {
            archive
                .read(&link.href)
                .map(|data| html_text::extract(&css_compat::decode_text(&data)).text)
                .unwrap_or_default()
        })
        .collect()
}

/// 本文そのものから問い合わせを作る。書き並べた語だけでは、当てる場所が偏る。
///
/// 特に単位の末尾は落としやすい。二字組は文字の対で作るため、最後の 1 文字は
/// 対の相手がおらず、番人（SENTINEL）と組ませる作りに頼っている。
/// 末尾に当たる問い合わせを入れておかないと、そこが壊れても検査が黙って通る。
fn queries_from(units: &[String]) -> Vec<String> {
    let mut queries = Vec::new();
    for unit in units {
        let chars: Vec<char> = unit.chars().collect();
        if chars.len() < 3 {
            continue;
        }
        let take = |from: usize, len: usize| chars[from..(from + len).min(chars.len())].iter().collect::<String>();
        queries.push(take(0, 2));                       // 頭
        queries.push(take(chars.len() / 2, 3));         // 中ほど
        queries.push(take(chars.len() - 2, 2));         // 末尾
        queries.push(take(chars.len() - 1, 1));         // 末尾の 1 文字
    }
    queries
}

/// 当たりは生成のたびに同じとは限らないので、中身だけを比べる。
fn digest(results: &[search::SearchResult]) -> Vec<String> {
    results
        .iter()
        .map(|r| {
            format!(
                "{}|{:.3}|{}|{}|{}",
                r.locator.href.as_deref().unwrap_or(""),
                r.locator.progression,
                r.matched,
                r.is_code,
                r.nth
            )
        })
        .collect()
}

#[test]
fn 索引ありと索引なしで当たりが変わらない() {
    // 索引が一度も絞らなければ、この検査は何も確かめていないことになる。
    let mut narrowed_at_least_once = false;

    // フィクスチャは生成物で、追跡していない。無い環境では飛ばす（macOS 版の検査と同じ扱い）。
    if !std::path::Path::new(&fixture(BOOKS[0])).exists() {
        eprintln!("フィクスチャがありません。conformance/choroconf generate を先に走らせてください");
        return;
    }

    for name in BOOKS {
        let path = fixture(name);
        let archive = EpubArchive::open(&path)
            .unwrap_or_else(|_| panic!("{name} を開けない。conformance/choroconf generate で作る"));
        let publication = epub_parser::parse(&archive).unwrap_or_else(|_| panic!("{name} を解けない"));
        let units = unit_texts(&archive, &publication);
        let index = Index::build(&units);

        let mut queries: Vec<String> = QUERIES.iter().map(|q| q.to_string()).collect();
        queries.extend(queries_from(&units));

        for query in &queries {
            let candidates = index.candidates(query);
            if candidates
                .as_ref()
                .is_some_and(|c| c.len() < index.unit_count())
            {
                narrowed_at_least_once = true;
            }

            let full = search::search_epub(&archive, &publication, query);
            let narrow = search::search_epub_within(
                &archive,
                &publication,
                query,
                candidates.as_deref(),
                search::RESULT_LIMIT,
            );

            assert_eq!(
                digest(&full.results),
                digest(&narrow.results),
                "{name} の「{query}」で索引ありと索引なしが食い違った"
            );
            assert_eq!(full.truncated, narrow.truncated, "{name} の「{query}」で打ち切りが違う");
        }
    }

    assert!(narrowed_at_least_once, "索引が一度も候補を絞っていない");
}
