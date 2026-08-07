// 当たりの目当て。形を組む場所が 1 つであることを確かめる。

import assert from "node:assert/strict";
import { test } from "node:test";

import { aimedAt, markQuery, takeApproach } from "../lib/mark.js";

test("リフローは章の経路で、紙面はページ番号で指す", () => {
  const chapter = aimedAt({ query: "型", nth: 2, target: { href: "ch01.xhtml" } });
  assert.equal(chapter.href, "ch01.xhtml");
  assert.equal(chapter.page, 0);

  const page = aimedAt({ query: "型", nth: 0, target: { page: 4 } });
  assert.equal(page.href, "");
  assert.equal(page.page, 4);
});

test("欠けている項目は既定で埋める", () => {
  const mark = aimedAt({ query: "型", target: {} });
  assert.equal(mark.nth, 0);
  assert.deepEqual(mark.rects, []);
});

test("送るのは 1 度きり。聞いた時点で消える", () => {
  const mark = aimedAt({ query: "型", target: {} });
  assert.equal(takeApproach(mark), true);
  assert.equal(takeApproach(mark), false, "2 度目は送らない");
  assert.equal(takeApproach(null), false);
});

test("囲む先でなければ、配信に何も添えない", () => {
  const mark = aimedAt({ query: "型 と 空白", nth: 3, target: { href: "a" } });
  assert.equal(markQuery(mark, true), "?q=%E5%9E%8B%20%E3%81%A8%20%E7%A9%BA%E7%99%BD&nth=3");
  assert.equal(markQuery(mark, false), "");
  assert.equal(markQuery(null, true), "");
});
