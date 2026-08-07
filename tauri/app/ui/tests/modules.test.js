// 画面のモジュールが読み込めること。
//
// 取り込みの綴りや、同じ名前の二重宣言は、実機で走らせるまで分からない。
// しかも読み込みで落ちると**その窓は黙って何もしない**（治具ごと動かない）ので、
// 動作確認では原因が見えない。ここで先に捕まえる。

import assert from "node:assert/strict";
import { test } from "node:test";

/// 画面が触る土台の代わり。読み込みの時点で参照されるものだけを置く。
function stubWindow() {
  const element = () => ({
    setAttribute() {}, addEventListener() {}, append() {}, appendChild() {},
    replaceChildren() {}, remove() {}, classList: { toggle() {}, add() {}, remove() {} },
    style: {}, dataset: {}, children: [], querySelectorAll: () => [],
  });
  globalThis.window = {
    __TAURI__: { core: { invoke: async () => ({}) }, event: { listen: async () => {} } },
    addEventListener() {}, location: { search: "" }, innerWidth: 800, innerHeight: 600,
  };
  globalThis.document = {
    getElementById: () => element(),
    createElement: element,
    querySelector: () => null,
    querySelectorAll: () => [],
    addEventListener() {},
    body: element(),
  };
  globalThis.location = window.location;
  globalThis.performance = { now: () => 0 };
}

for (const name of ["chrome.js", "reader.js", "shelf.js", "selftest.js",
                    "readers/paged.js", "readers/reflowable.js", "readers/overlays.js"]) {
  test(`${name} を読み込める`, async () => {
    stubWindow();
    await assert.doesNotReject(() => import(`../${name}`));
  });
}
