// 紙面をどう並べて、どう送るか。
//
// 見開きの組み方そのものは core が決め、書籍を開いたときに `spreads` として降ってくる。
// ここにあるのは「降ってきた組み方をいまの並べ方でどう使うか」だけで、規則は持たない。
// 数え直すと、実装ごとに違う並びになりうる（conformance/CONTRACT.md）。

/// 紙面として扱う書籍かどうか。PDF と固定レイアウト EPUB はページで数える。
/// 綴じ方向も拡大も送り方も、この 2 つでは同じに振る舞う。
export const isPagedBook = (book) => !!book && (book.format === "pdf" || book.format === "fixedEPUB");

export const isFixedBook = (book) => !!book && book.format === "fixedEPUB";

/// 紙面の総数。固定レイアウトはページの一覧、PDF は枚数を持っている。
export const pageCountOf = (book) => (isFixedBook(book) ? (book.pages || []).length : book.pageCount || 0);

/// そのページを含む組。組み方を持たない書籍では、そのページ 1 枚とみなす。
export const spreadWith = (spreads, page) => (spreads || []).find((group) => group.includes(page)) || [page];

/// その並べ方で画面に出すページ。
export function pagesToShow(layout, page, total, spreads) {
  switch (layout) {
    case "singlePage": return [page];
    case "spread": return spreadWith(spreads, page);
    default: return Array.from({ length: total }, (_, i) => i);
  }
}

/// 送り先のページ。見開きでは組ごと動く。
/// 並べ方が変わっても「次の単位へ」という意味は変えない。
export function pageAfterStep(layout, page, delta, spreads) {
  if (layout !== "spread") return page + delta;
  const current = spreadWith(spreads, page);
  const next = delta > 0 ? current[current.length - 1] + 1 : current[0] - 1;
  return next < 0 ? 0 : next;
}

/// 経路からリフローの章番号を引く。見つからなければ null。
///
/// 見つからないことは普通に起きる（別の版の書籍から来た位置、消えた章）。
/// 扱いを 1 つに決めておかないと、呼ぶ場所ごとに黙って 0 章へ飛んだり
/// 何も起きなかったりと、振る舞いが分かれる。
export function chapterOfHref(book, href) {
  const index = (book.chapters || []).findIndex((chapter) => chapter.href === href);
  return index >= 0 ? index : null;
}

/// 目次や別の窓は章の経路で行き先を言う。紙面ではページ番号へ読み替える。
///
/// ページは読み順の 1 項目から 1 枚ずつ作られるので、読み順の何番目かがそのまま番号になる。
/// `pages` の href から探すと、絵に置き換えたページでは名前が変わっていて当たらない。
export function pageOfHref(book, href) {
  if (!isFixedBook(book)) return Number(href);
  return Math.max(0, (book.chapters || []).findIndex((chapter) => chapter.href === href));
}
