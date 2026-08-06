// 画面に出す文字列。数と状態から決まるので、画面を起こさずに確かめられる。

import assert from "node:assert/strict";
import { test } from "node:test";

import { hitCountLabel, libraryProgress, oneLine } from "../lib/format.js";

test("改行と連なった空白は 1 つの空白に詰める", () => {
  // PDF の本文は行ごとに改行が入っており、そのまま出すと 1 件が何行にもなる。
  assert.equal(oneLine("あ\nい\n\nう"), "あ い う");
  assert.equal(oneLine("a   b"), "a b");
});

test("端の空白は落とさない。落とすと英文で前後の語がくっつく", () => {
  assert.equal(oneLine(" the word "), " the word ");
});

test("引く前は何も言わない", () => {
  assert.equal(libraryProgress({ query: "", books: [] }), "");
});

test("索引を作っている間は、その書名を出す", () => {
  const label = libraryProgress({
    query: "型", building: "型システム入門", running: true, searched: 3, total: 20, books: [],
  });
  assert.equal(label, "索引を作成中：型システム入門");
});

test("引いている間は冊数の進み具合を出す", () => {
  const label = libraryProgress({
    query: "型", building: null, running: true, searched: 3, total: 20, books: [],
  });
  assert.equal(label, "3 / 20 冊");
});

test("引き終わったら当たった冊数と件数を出す", () => {
  const books = [{ hits: [1, 2, 3] }, { hits: [1] }];
  const label = libraryProgress({
    query: "型", building: null, running: false, searched: 20, total: 20, books,
  });
  assert.equal(label, "2 冊 / 4 件");
});

test("1 冊の件数は、打ち切ったときにその先があることを示す", () => {
  assert.equal(hitCountLabel({ hits: [1, 2], truncated: false }), "2 件");
  assert.equal(hitCountLabel({ hits: [1, 2], truncated: true }), "2 件以上");
});
