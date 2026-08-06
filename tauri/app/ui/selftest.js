// 動作確認。ヘルプの献立から呼ぶ。
//
// Windows の実機に触れないまま作っている部分が多いので、
// 「作ったつもり」と「動いている」の差を機械的に潰すための治具である。
//
// 検査は 2 種類に分かれる。
// 画面の中だけで完結するものは自動で確かめる。
// 右クリックや二度押しのように OS の入力が要るものは、操作をお願いして結果を見る。
// 合成した出来事では、本当に届いているかを確かめたことにならないためである。

(() => {
  const invoke = window.__TAURI__.core.invoke;
  const $ = (id) => document.getElementById(id);

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  /// 条件が満たされるまで待つ。満たされなければ偽を返す。
  async function until(check, timeout = 4000) {
    const started = performance.now();
    for (;;) {
      try { if (check()) return true; } catch (_) { /* まだ整っていない */ }
      if (performance.now() - started > timeout) return false;
      await sleep(50);
    }
  }

  // ---- 検査の並び ---------------------------------------------------------

  /// 自動で確かめられるもの。画面の中だけで完結する。
  const automatic = [
    {
      name: "書籍が開いている",
      run: () => ({ ok: !!window.tzr.state.book, detail: window.tzr.state.book?.title || "開いていない" }),
    },
    {
      name: "本文が入っている",
      run: () => {
        const doc = $("page").contentDocument;
        const length = doc && doc.body ? doc.body.textContent.trim().length : 0;
        return { ok: length > 0, detail: `${length} 文字` };
      },
      only: "reflowable",
    },
    {
      name: "本文の枠に allow-scripts を与えていない",
      run: () => {
        // これが崩れると書籍側の script が動く。安全側の前提そのものなので必ず見る。
        const sandbox = Array.from($("page").sandbox || []);
        const ok = sandbox.includes("allow-same-origin") && !sandbox.includes("allow-scripts");
        return { ok, detail: sandbox.join(" ") || "指定なし" };
      },
      only: "reflowable",
    },
    {
      name: "アプリの CSS が本文に入っている",
      run: () => {
        const doc = $("page").contentDocument;
        const style = doc && doc.getElementById("tzr-style");
        return { ok: !!style && style.textContent.length > 0, detail: style ? "入っている" : "無い" };
      },
      only: "reflowable",
    },
    {
      name: "目次が並んでいる",
      run: () => {
        const count = $("toc").children.length;
        return { ok: count > 0, detail: `${count} 項目` };
      },
    },
    {
      name: "→ で次へ進む",
      run: async () => {
        const before = place();
        window.tzr.step(1);
        const moved = await until(() => place() !== before);
        const after = place();
        if (moved) window.tzr.step(-1);
        return { ok: moved, detail: `${before} → ${after}` };
      },
    },
    {
      name: "目次から飛べる",
      run: async () => {
        const entries = Array.from($("toc").children).filter((a) => a.dataset.href);
        if (entries.length < 2) return { ok: false, detail: "目次の項目が足りない" };
        const before = place();
        entries[entries.length - 1].click();
        const moved = await until(() => place() !== before);
        return { ok: moved, detail: `${before} → ${place()}` };
      },
    },
    {
      name: "戻るで元の場所に帰る",
      run: async () => {
        const before = place();
        window.tzr.goBack();
        const moved = await until(() => place() !== before);
        return { ok: moved, detail: `${before} → ${place()}` };
      },
    },
    {
      name: "検索が当たる",
      run: async () => {
        const hits = await invoke("search_book", { id: window.tzr.state.book.id, query: searchWord() });
        return { ok: hits.length > 0, detail: `「${searchWord()}」で ${hits.length} 件` };
      },
    },
    {
      name: "表示設定の CSS が作れる",
      run: async () => {
        const style = await invoke("reader_css", { settings: window.tzr.state.settings });
        return { ok: (style.css || "").includes("font-size"), detail: `${(style.css || "").length} 文字` };
      },
    },
    {
      name: "書棚に書籍が並ぶ",
      run: async () => {
        const books = await invoke("library");
        return { ok: books.length > 0, detail: `${books.length} 冊` };
      },
    },
  ];

  /// 操作をお願いするもの。OS の入力が本当に届いているかは、これでしか分からない。
  const manual = [
    {
      name: "目次の右クリックで献立が出る",
      ask: "左の目次のどれかを右クリックしてください。",
      wait: () => !$("menu").hidden,
      after: () => { window.tzr.hideMenu(); },
    },
    {
      name: "目次の ⌘/Ctrl クリックで新しいウィンドウが開く",
      ask: "目次のどれかを ⌘（Windows は Ctrl）を押しながらクリックしてください。",
      before: async () => { manualState.windows = await invoke("window_count"); },
      wait: async () => (await invoke("window_count")) > manualState.windows,
    },
    {
      name: "← → で章やページが動く",
      ask: "本文の上をクリックしてから、→ を 1 回押してください。",
      before: () => { manualState.place = place(); },
      wait: () => place() !== manualState.place,
    },
    {
      name: "書籍を落として開ける",
      ask: "この窓に EPUB か PDF を 1 つ落としてください。",
      before: async () => { manualState.windows = await invoke("window_count"); },
      wait: async () => (await invoke("window_count")) > manualState.windows,
    },
  ];

  const manualState = {};

  const headless = () => new URLSearchParams(location.search).get("selftest") === "1";

  function place() {
    const state = window.tzr.state;
    if (!state.book) return "";
    return state.book.format === "reflowableEPUB" ? String(state.index) : String(state.page);
  }

  function searchWord() {
    // 日本語の書籍なら助詞が必ず出る。英語の書籍でも当たるものを混ぜる。
    return window.tzr.state.book.format === "pdf" ? "の" : "の";
  }

  function applies(check) {
    if (!check.only) return true;
    const format = window.tzr.state.book?.format;
    return check.only === "reflowable" ? format === "reflowableEPUB" : format !== "reflowableEPUB";
  }

  // ---- 進め方 -------------------------------------------------------------

  const results = [];

  async function run() {
    const panel = open();
    const list = $("selftest-list");

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

  window.tzrSelfTest = run;
  // 引数から走らせたときは、開いた直後に自分で始める。
  if (headless()) setTimeout(run, 1500);
})();
