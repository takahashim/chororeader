// 画面に出す文字列を組み立てる。数と状態から決まるだけで、DOM には触れない。

/// 改行と連なった空白を 1 つの空白に詰める。
/// PDF の本文は行ごとに改行が入っており、そのまま出すと 1 件が何行にもなる。
/// 端の空白は落とさない。落とすと英文で前後の語がくっつく。
export const oneLine = (text) => String(text).replace(/\s+/g, " ");

/// 横断検索の進み具合。索引を作っている間、引いている間、引き終えた後で言うことが変わる。
export function libraryProgress({ query, building, running, searched, total, books }) {
  if (!query) return "";
  if (building) return `索引を作成中：${building}`;
  if (running) return `${searched} / ${total} 冊`;
  const hits = books.reduce((sum, book) => sum + book.hits.length, 0);
  return `${books.length} 冊 / ${hits} 件`;
}

/// 1 冊ぶんの当たりの数。上限で打ち切ったときは、その先があることを示す。
export const hitCountLabel = (book) => (book.truncated ? `${book.hits.length} 件以上` : `${book.hits.length} 件`);
