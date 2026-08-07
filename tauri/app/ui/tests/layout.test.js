// 紙面の並べ方。
//
// 見開きの組み方そのものは core が決め、書籍を開いたときに降ってくる。
// ここで確かめるのは、降ってきた組み方をいまの並べ方でどう使うかだけである。

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  chapterOfHref, isFixedBook, isPagedBook, pageAfterStep, pageCountOf, pageOfHref,
  pagesToShow, spreadWith,
} from "../lib/layout.js";

// 組み方は core が決めて `spreads` として降ってくる。試験では降ってきたつもりの値を渡す。
// 表紙は単独、以降を 2 枚ずつ、という規則そのものは core 側で確かめられている。
const SPREADS = [[0], [1, 2], [3, 4], [5, 6], [7]];

test("降ってきた組み方から、そのページを含む組を選ぶ", () => {
  assert.deepEqual(spreadWith(SPREADS, 0), [0]);
  assert.deepEqual(spreadWith(SPREADS, 2), [1, 2]);
  assert.deepEqual(spreadWith(SPREADS, 7), [7]);
});

test("組み方を持たない書籍では、そのページ 1 枚とみなす", () => {
  assert.deepEqual(spreadWith([], 3), [3]);
  assert.deepEqual(spreadWith(undefined, 3), [3]);
});

test("並べ方ごとに画面へ出すページが変わる", () => {
  assert.deepEqual(pagesToShow("singlePage", 3, 5, SPREADS), [3]);
  assert.deepEqual(pagesToShow("spread", 3, 5, SPREADS), [3, 4]);
  assert.deepEqual(pagesToShow("continuousScroll", 3, 5, SPREADS), [0, 1, 2, 3, 4]);
});

test("見開きでは組ごと送る", () => {
  assert.equal(pageAfterStep("spread", 1, 1, SPREADS), 3, "1-2 の次は 3");
  assert.equal(pageAfterStep("spread", 3, -1, SPREADS), 2, "3-4 の前は 2（1-2 の組）");
  assert.equal(pageAfterStep("singlePage", 3, 1, SPREADS), 4);
});

test("先頭より前へは送らない", () => {
  assert.equal(pageAfterStep("spread", 0, -1, SPREADS), 0);
});

test("紙面かどうかは形式で決まる", () => {
  assert.equal(isPagedBook({ format: "pdf" }), true);
  assert.equal(isPagedBook({ format: "fixedEPUB" }), true);
  assert.equal(isPagedBook({ format: "reflowableEPUB" }), false);
  assert.equal(isPagedBook(null), false);
  assert.equal(isFixedBook({ format: "pdf" }), false);
});

test("固定レイアウトの目次はページ番号へ読み替える", () => {
  const book = {
    format: "fixedEPUB",
    pages: [{ href: "p1.xhtml" }, { href: "p2.xhtml" }],
    chapters: [{ href: "p1.xhtml" }, { href: "p2.xhtml" }],
  };
  assert.equal(pageOfHref(book, "p2.xhtml"), 1);
});

test("絵に置き換えたページでも、読み順の番号がそのまま使える", () => {
  // ページの名前は絵の側に変わるが、ページは読み順の 1 項目から 1 枚ずつ作られる。
  const book = {
    format: "fixedEPUB",
    pages: [{ href: "images/p1.png" }, { href: "images/p2.png" }],
    chapters: [{ href: "p1.xhtml" }, { href: "p2.xhtml" }],
  };
  assert.equal(pageOfHref(book, "p2.xhtml"), 1);
});

test("PDF では目次が持つ番号をそのまま使う", () => {
  assert.equal(pageOfHref({ format: "pdf" }, "4"), 4);
});

test("紙面の総数は形式ごとの数え方に従う", () => {
  assert.equal(pageCountOf({ format: "pdf", pageCount: 12 }), 12);
  assert.equal(pageCountOf({ format: "fixedEPUB", pages: [1, 2, 3] }), 3);
});

test("経路から章の番号を引く", () => {
  const book = { chapters: [{ href: "a.xhtml" }, { href: "b.xhtml" }] };
  assert.equal(chapterOfHref(book, "b.xhtml"), 1);
});

test("見つからない章は null で返す。0 章に落とさない", () => {
  // 黙って先頭へ飛ぶと、別の版から来た位置で「なぜか 1 章に戻る」ことになる。
  const book = { chapters: [{ href: "a.xhtml" }] };
  assert.equal(chapterOfHref(book, "無い.xhtml"), null);
  assert.equal(chapterOfHref({}, "a.xhtml"), null);
});
