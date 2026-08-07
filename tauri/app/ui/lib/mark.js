// 検索結果から飛んだ先で囲む、当たりの目当て。
//
// 本文へ印を入れるのは Rust の仕事（core の mark）。ここが持つのは
// 「どの当たりを囲んでほしいか」だけで、形を組む場所を 1 つにまとめる。
//
// 組む場所が分かれると、どの項目がどこで決まるのか追えなくなる。

/// 当たりを目当てにする。`target` は形式ごとの行き先（章の経路か、ページ番号）。
export function aimedAt({ query, nth, target, rects = [] }) {
  return {
    query,
    /// その章の中で何番目の当たりか。同じ語が何度も出る章で、押したものを選び直す。
    nth: nth || 0,
    href: target.href || "",
    page: target.page || 0,
    /// 紙面の当たりを囲む枠。絵の上に重ねるので、本文の印とは別に持つ。
    rects,
    /// まだ、その場所まで送っていない。押した直後の 1 回だけ送る。
    pending: true,
  };
}

/// 送る番が来たか。1 度きりなので、聞いた時点で消える。
export function takeApproach(mark) {
  if (!mark || !mark.pending) return false;
  mark.pending = false;
  return true;
}

/// 本文を配ってもらうときに添える、囲んでほしい当たりの指定。
/// 囲む先でないときは何も添えない。
export function markQuery(mark, wanted) {
  if (!mark || !mark.query || !wanted) return "";
  return `?q=${encodeURIComponent(mark.query)}&nth=${mark.nth}`;
}
