// 動作確認。ヘルプメニューから呼ぶ。
//
// Windows の実機に触れないまま作っている部分が多いので、
// 「作ったつもり」と「動いている」の差を機械的に潰すための治具である。
//
// ここは走らせ方と結果の見せ方だけを持つ。何を確かめるかは selftest-checks.js。

import {
  applies, automatic, manual, manualState, shelfChecks, until,
} from "./selftest-checks.js";

const invoke = window.__TAURI__.core.invoke;
const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const headless = () => new URLSearchParams(location.search).get("selftest") === "1";

const results = [];

async function run() {
  const panel = open();
  const list = $("selftest-list");

  // 書棚の窓には本文が無い。確かめられることが違うので、別の並びを使う。
  // 窓ごとに文書が分かれているので、どちらに居るかは画面側が名乗る。
  // 書籍を 1 冊も持たないマシンで最初に開くのがこの窓であり、
  // ここが黙って死ぬと「窓は出るが何も操作できない」という形になる。
  if (window.choro.kind === "shelf") {
    for (const check of shelfChecks) {
      let outcome;
      try {
        outcome = await check.run();
      } catch (error) {
        outcome = { ok: false, detail: String(error && error.message || error) };
      }
      record(list, { name: check.name, ...outcome });
      await sleep(120);
    }
    finish(panel);
    return;
  }

  for (const check of automatic) {
    if (!applies(check)) {
      record(list, { name: check.name, ok: null, detail: "この書籍では確かめない" });
      continue;
    }
    let outcome;
    try {
      outcome = await check.run();
    } catch (error) {
      outcome = { ok: false, detail: String(error && error.message || error) };
    }
    record(list, { name: check.name, ...outcome });
    await sleep(120);
  }

  // 引数から走らせたときは人がいない。操作をお願いする分は飛ばす。
  if (!headless()) {
    for (const check of manual) {
      const outcome = await askUser(check, panel);
      record(list, { name: check.name, ...outcome });
    }
  } else {
    for (const check of manual) {
      record(list, { name: check.name, ok: null, detail: "人の操作が要るので飛ばした" });
    }
  }

  finish(panel);
}

/// 操作をお願いして待つ。飛ばすことも、失敗として記録することもできる。
function askUser(check, panel) {
  return new Promise(async (resolve) => {
    if (check.before) await check.before();

    const ask = $("selftest-ask");
    ask.hidden = false;
    $("selftest-ask-text").textContent = check.ask;

    let done = false;
    const settle = (outcome) => {
      if (done) return;
      done = true;
      ask.hidden = true;
      if (check.after) { try { check.after(); } catch (_) { /* 後始末は失敗しても構わない */ } }
      resolve(outcome);
    };

    $("selftest-skip").onclick = () => settle({ ok: null, detail: "飛ばした" });
    $("selftest-fail").onclick = () => settle({ ok: false, detail: "動かないと報告された" });

    const started = performance.now();
    const tick = async () => {
      if (done) return;
      if (await check.wait()) return settle({ ok: true, detail: "確かめた" });
      const left = Math.ceil((60000 - (performance.now() - started)) / 1000);
      if (left <= 0) return settle({ ok: null, detail: "待って時間切れ" });
      $("selftest-left").textContent = `のこり ${left} 秒`;
      setTimeout(tick, 200);
    };
    tick();
  });
}

// ---- 見せ方 -------------------------------------------------------------

function open() {
  let panel = $("selftest");
  if (panel) panel.remove();
  panel = document.createElement("div");
  panel.id = "selftest";
  panel.innerHTML = `
    <div id="selftest-bar">
      <strong>動作確認</strong>
      <span id="selftest-count"></span>
      <span class="spacer"></span>
      <button id="selftest-copy" title="結果を文字にしてクリップボードへ入れる">結果をコピー</button>
      <button id="selftest-close">閉じる</button>
    </div>
    <div id="selftest-list"></div>
    <div id="selftest-ask" hidden>
      <span id="selftest-ask-text"></span>
      <span id="selftest-left"></span>
      <button id="selftest-skip">飛ばす</button>
      <button id="selftest-fail">動かない</button>
    </div>`;
  document.body.appendChild(panel);
  $("selftest-close").onclick = () => panel.remove();
  $("selftest-copy").onclick = async () => {
    const button = $("selftest-copy");
    try {
      await navigator.clipboard.writeText(asText());
      // 押しても画面は変わらない。何が起きたかを押しボタン自身に出す。
      button.textContent = "コピーしました";
    } catch (_) {
      button.textContent = "コピーできません";
    }
    setTimeout(() => { button.textContent = "結果をコピー"; }, 1600);
  };
  return panel;
}

function record(list, outcome) {
  results.push(outcome);
  const row = document.createElement("div");
  row.className = "row " + (outcome.ok === true ? "ok" : outcome.ok === false ? "ng" : "skip");
  row.innerHTML = `<span class="mark"></span><span class="name"></span><span class="detail"></span>`;
  row.querySelector(".mark").textContent = outcome.ok === true ? "✓" : outcome.ok === false ? "✕" : "—";
  row.querySelector(".name").textContent = outcome.name;
  row.querySelector(".detail").textContent = outcome.detail || "";
  list.appendChild(row);
  list.scrollTop = list.scrollHeight;
  count();
}

function count() {
  const ok = results.filter((r) => r.ok === true).length;
  const ng = results.filter((r) => r.ok === false).length;
  const skip = results.filter((r) => r.ok == null).length;
  $("selftest-count").textContent = `合格 ${ok} ／ 不合格 ${ng} ／ 飛ばした ${skip}`;
}

function asText() {
  return results
    .map((r) => `${r.ok === true ? "OK  " : r.ok === false ? "NG  " : "--  "}${r.name}  ${r.detail || ""}`)
    .join("\n");
}

function finish(panel) {
  $("selftest-ask").hidden = true;
  const ng = results.filter((r) => r.ok === false).length;
  $("selftest-count").textContent += ng === 0 ? "　（すべて通った）" : "　（不合格あり）";
  // 引数から走らせたときは結果を返して終わる。CI ではこちらを使う。
  if (headless()) invoke("selftest_report", { results }).catch(() => {});
  const _ = panel;
}

window.choroSelfTest = run;
// 引数から走らせたときは、開いた直後に自分で始める。
if (headless()) setTimeout(run, 1500);
