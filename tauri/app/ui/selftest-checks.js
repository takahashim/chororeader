// 何を確かめるか。
//
// 検査は 2 種類に分かれる。
// 画面の中だけで完結するものは自動で確かめる。
// 右クリックや二度押しのように OS の入力が要るものは、操作をお願いして結果を見る。
// 合成した出来事では、本当に届いているかを確かめたことにならないためである。
//
// 走らせ方と結果の見せ方は selftest.js が持つ。ここは並びだけを書く。

const invoke = window.__TAURI__.core.invoke;
const $ = (id) => document.getElementById(id);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/// 条件が満たされるまで待つ。満たされなければ偽を返す。
export async function until(check, timeout = 4000) {
  const started = performance.now();
  for (;;) {
    try { if (await check()) return true; } catch (_) { /* まだ整っていない */ }
    if (performance.now() - started > timeout) return false;
    await sleep(50);
  }
}

export const manualState = {};

/// 自動で確かめられるもの。画面の中だけで完結する。
export const automatic = [
  {
    name: "書籍が開いている",
    run: () => ({ ok: !!window.choro.state.book, detail: window.choro.state.book?.title || "開いていない" }),
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
      const style = doc && doc.getElementById("choro-style");
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
      // 終端で閉じた本は、そこから先へは進めない。逆向きに送って確かめる。
      const forward = !atEnd();
      const before = place();
      window.choro.step(forward ? 1 : -1);
      const moved = await until(() => place() !== before);
      const after = place();
      if (moved) window.choro.step(forward ? -1 : 1);
      return { ok: moved, detail: `${before} → ${after}${forward ? "" : "（終端なので逆へ）"}` };
    },
  },
  {
    name: "目次から飛べる",
    run: async () => {
      const entries = Array.from($("toc").children).filter((a) => a.dataset.href);
      if (entries.length < 2) return { ok: false, detail: "目次の項目が足りない" };
      const before = place();
      // いまいる場所を指す項目を押しても動かない。遠い方の端を選ぶ。
      (atEnd() ? entries[0] : entries[entries.length - 1]).click();
      const moved = await until(() => place() !== before);
      return { ok: moved, detail: `${before} → ${place()}` };
    },
  },
  {
    name: "戻るで元の場所に帰る",
    run: async () => {
      const before = place();
      window.choro.goBack();
      const moved = await until(() => place() !== before);
      return { ok: moved, detail: `${before} → ${place()}` };
    },
  },
  {
    name: "検索が当たる",
    run: async () => {
      const word = await searchWord();
      const hits = await invoke("search_book", { id: window.choro.state.book.id, query: word });
      return { ok: hits.length > 0, detail: `「${word}」で ${hits.length} 件` };
    },
  },
  {
    name: "検索結果から飛ぶと当たりが強調される",
    run: async () => {
      $("search-input").value = await searchWord();
      await window.choro.runSearch();
      const row = $("results").querySelector('[data-role="hit"]');
      if (!row) return { ok: false, detail: "当たりが無い" };
      row.click();

      // PDF は絵の上に枠を重ね、本文が HTML のものは語そのものを囲む。
      const framed = () => document.querySelectorAll("#pdf .found-frame").length;
      const wrapped = () => Array.from(document.querySelectorAll("iframe"))
        .filter((frame) => frame.contentDocument
          && frame.contentDocument.querySelector("mark.choro-found")).length;
      const marked = await until(() => framed() || wrapped(), 8000);
      // 元いた場所へ帰しておく。ここで動いたままだと、読書位置として覚えられ、
      // 次に走らせたときの出発点が変わってしまう。
      window.choro.goBack();

      // 囲めなかったときは目当てと居場所を出す。どちらがずれたのかが分からないため。
      return {
        ok: marked,
        detail: marked
          ? `枠 ${framed()} ／ 語 ${wrapped()}`
          : `囲めない（目当て ${JSON.stringify(window.choro.state.mark)}`
            + ` 居場所 ${window.choro.nav.currentHref()} / ${window.choro.nav.at()}）`,
      };
    },
  },
  {
    name: "表示設定の CSS が作れる",
    run: async () => {
      const style = await invoke("reader_css", { settings: window.choro.state.settings });
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
  {
    name: "読み込み中に重ねた送りも届く",
    run: async () => {
      // 章が入り終わる前にもう一度送る。待たせた分は着いてからまとめて動く。
      // 1 回ずつ送っているうちは、送りを取っておく道（queuedSteps）を一度も通らない。
      const delta = atEnd() ? -1 : 1;
      const before = place();
      window.choro.step(delta);
      window.choro.step(delta);
      const settled = await until(() => !window.choro.nav.loading() && place() !== before, 8000);
      const after = place();
      if (settled) {
        window.choro.step(-delta);
        await until(() => !window.choro.nav.loading());
        window.choro.step(-delta);
        await until(() => !window.choro.nav.loading());
      }
      return { ok: settled, detail: `${before} → ${after}` };
    },
    only: "reflowable",
  },
  {
    name: "取りこぼした出来事が無い",
    run: () => {
      // 誰も受けなかった例外や約束は、chrome.js が枠に書き出す。
      // 枠があるということは、ここまでの検査のどこかが黙って転んでいる。
      // 個々の検査は自分の判定しか見ないので、最後にまとめて見る。
      const box = document.getElementById("boot-failure-text");
      const written = box ? box.textContent.trim() : "";
      return { ok: !written, detail: written || "取りこぼしなし" };
    },
  },
];

/// 書棚の窓で確かめるもの。本文が無いぶん、土台とつながっているかを重点的に見る。
export const shelfChecks = [
  {
    name: "土台に届く",
    run: async () => {
      const settings = await invoke("settings");
      return { ok: settings !== undefined, detail: "命令が通った" };
    },
  },
  {
    name: "献立の道が通っている",
    run: async () => {
      // 窓の権限が足りないと、ここだけが黙って効かなくなる。
      window.choroLastMenu = null;
      await invoke("ping_menu");
      const arrived = await until(() => window.choroLastMenu === "selftest-ping", 3000);
      return { ok: arrived, detail: arrived ? "受け取れた" : "受け取れない（窓の権限を疑う）" };
    },
  },
  {
    name: "書棚が描けている",
    run: () => {
      const rows = $("shelf-grid").children.length;
      const empty = !$("shelf-empty").hidden;
      return { ok: rows > 0 || empty, detail: rows > 0 ? `${rows} 冊` : "空の知らせが出ている" };
    },
  },
  {
    name: "蔵書を横断して引ける",
    run: async () => {
      const books = await invoke("library");
      if (books.length === 0) return { ok: null, detail: "蔵書が無いので確かめない" };

      // 索引がまだ無い本はその場で作る。1 冊目は書籍を丸ごと読むので待ちが長い。
      // 日本語の書籍なら助詞が必ず出る。書棚には本文が無いので、語は決め打ちにする。
      $("shelf-search").value = "の";
      window.choro.runLibrarySearch();
      // 引き終わると、進み具合の出方が「n / m 冊」から「n 冊 / m 件」に変わる。
      const done = await until(() => / 件$/.test($("shelf-progress").textContent), 60000);
      const found = $("shelf-results").querySelectorAll(".found").length;
      window.choro.clearLibrarySearch();
      return { ok: done, detail: done ? `${found} 冊で当たった` : "引き終わらない" };
    },
  },
  {
    name: "サンプルを開ける",
    run: async () => {
      const before = await invoke("window_count");
      await invoke("open_sample", { kind: "reflowable" });
      const opened = await until(async () => (await invoke("window_count")) > before, 8000);
      return { ok: opened, detail: opened ? "窓が増えた" : "窓が増えない" };
    },
  },
  {
    name: "画面で例外が起きていない",
    run: () => {
      const box = document.getElementById("boot-failure");
      return { ok: !box, detail: box ? box.textContent.slice(0, 120) : "無し" };
    },
  },
];

/// 操作をお願いするもの。OS の入力が本当に届いているかは、これでしか分からない。
export const manual = [
  {
    name: "目次の右クリックで献立が出る",
    ask: "左の目次のどれかを右クリックしてください。",
    wait: () => !$("menu").hidden,
    after: () => { window.choro.hideMenu(); },
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

const headless = () => new URLSearchParams(location.search).get("selftest") === "1";

/// いまどこにいるか。章の番号かページ番号かは読み手が決める。
export function place() {
  return window.choro.state.book ? window.choro.nav.at() : "";
}

/// いま終端にいるか。
///
/// この治具の結果は、その本を前回どこで閉じたかに左右される。
/// 最後まで読んだ本を開くと、そこから先へは進めず、検査が「動かない」と言う。
/// 動かないのは正しい振る舞いなので、終端では向きを変えて確かめる。
export function atEnd() {
  return !!window.choro.state.book && !window.choro.nav.canGoNext();
}

/// この書籍で必ず当たる語。日本語の書籍なら助詞が必ず出る。
/// 同梱のサンプル PDF は英語なので、紙面では 1 ページ目から語を 1 つ借りる。
export async function searchWord() {
  const state = window.choro.state;
  if (state.book.format !== "pdf") return "の";
  const text = await invoke("page_text", { id: state.book.id, page: 0 }).catch(() => "");
  return (String(text).match(/[A-Za-z]{4,}/) || ["の"])[0];
}

export function applies(check) {
  if (!check.only) return true;
  const format = window.choro.state.book?.format;
  return check.only === "reflowable" ? format === "reflowableEPUB" : format !== "reflowableEPUB";
}
