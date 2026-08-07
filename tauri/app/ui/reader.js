// 読書の窓。本文そのものは sandbox 付きの iframe に入れ、この文書から DOM を触る。
//
// Tauri では WebView 全体でスクリプトを止めるわけにいかない（この画面が JavaScript なので）。
// 代わりに本文の iframe へ allow-scripts を与えないことで書籍の script を止め、
// 親から contentDocument を辿って手を入れる。成立条件は両者が同じ生成元であること。
// 詳しくは spikes/findings-tauri.md を見よ。
//
// 書棚は別の窓（shelf.html）で、こちらには入っていない。

import {
  $, DEFAULT_SETTINGS, PARAMS, applyTheme, ensureBackend, hideMenu, invoke,
  listenToMenu, loadSettings, saveSettings, saveSettingsSoon, showFailure,
  showMenu, toast, trace, watchForFailures,
} from "./chrome.js";
import * as diagnosis from "./lib/diagnosis.js";
import { hitRow } from "./lib/hit-row.js";
import { aimedAt, markQuery } from "./lib/mark.js";
import { pagedReader } from "./readers/paged.js";
import { reflowableReader } from "./readers/reflowable.js";
import {
  chapterOfHref as chapterOfHrefIn, isFixedBook, isPagedBook, pageAfterStep,
  pageCountOf, pageOfHref as pageOfHrefIn, pagesToShow,
} from "./lib/layout.js";

const state = {
  book: null,
  /// いまの倍率。EPUB では本文全体に、PDF では描画の倍率に効く。
  /// どこにいるか（章の番号・ページ番号）は読み手が持つ。窓は nav.at() で尋ねる。
  zoom: 1,
  settings: { ...DEFAULT_SETTINGS },
  // 移動の履歴。読んだ順ではなく、飛んだ順を覚える。
  back: [],
  forward: [],
  style: { css: "", needsForegroundMarking: false },
  bookmarks: [],
  /// いま強調している当たり。検索から飛ぶたびに置き換わり、検索をやめると消える。
  mark: null,
};

// ---- 小道具 -------------------------------------------------------------

const encodePath = (path) => path.split("/").map(encodeURIComponent).join("/");

// 形式で決まることは lib/layout.js に置き、ここではいまの書籍を当てて呼ぶ。
const isPaged = () => isPagedBook(state.book);
const isFixed = () => isFixedBook(state.book);
const pageOfHref = (href) => pageOfHrefIn(state.book, href);
const chapterOfHref = (href) => chapterOfHrefIn(state.book, href);
// ---- 形式ごとの振る舞い ---------------------------------------------------
//
// spec.md 367 の取り決め：ナビゲータは目次・検索・位置表現を形式共通の形で提供し、
// サイドバー・履歴・書棚は形式を意識しない。新しい形式を足す費用が、ここに閉じる。
//
// リフロー（本文を iframe に入れる）と紙面（PDF と固定レイアウト EPUB）で振る舞いが変わる。
// 違いはこの 2 つの中だけに書き、外は `nav` を通してしか触らない。

/// 書籍を開く前。窓は出ているが、まだ読むものが無い。
///
/// 束ねは文書が入った時点で張られており、書籍が開く前に押されうる。
/// 既定をリフローにしておくと「PDF の窓なのにリフローとして振る舞う」時間ができ、
/// 実害が出ないのは押される順が偶然そうなっているからでしかなくなる。
const emptyReader = {
  paged: false,
  zoomSetting: "epubZoom",
  defaultFit: "custom",
  locate: () => null,
  show: () => {},
  currentHref: () => "",
  position: () => ({ href: "", progression: 0, page: 0, fragment: "", text: "" }),
  reveal: () => {},
  step: () => {},
  scrollBy: () => {},
  applyZoom: () => {},
  markTarget: () => ({ href: "", page: 0 }),
  hitTarget: () => null,
  label: () => "",
  hereHref: () => "",
  paintMark: async () => {},
  prepare: async () => {},
  clearMarks: () => {},
  showThumbs: () => {},
  relayout: () => {},
  refit: () => {},
  defaultZoom: () => 1,
  zoomFor: () => null,
  dismissOverlays: () => {},
  restyle: () => {},
  loading: () => false,
  at: () => "",
  canGoNext: () => false,
};

/// 窓と読み手が分かち合うもの。読み手はこれ以外を窓から取らない。
const shared = {
  state,
  departing: (...args) => departing(...args),
  moved: (...args) => moved(...args),
  setZoom: (...args) => setZoom(...args),
  bookUrl: (...args) => bookUrl(...args),
  focusContent: (...args) => focusContent(...args),
  encodePath,
  /// 本文を読み進めただけ。目次は塗り直さず、位置だけ覚える。
  scrolled: () => rememberSoon(),
  /// 本文の中で押されたキー。出先が上げてきたものを、ここで引き受ける。
  onKeyDown: (event) => onKeyDown(event),
};

const readers = { paged: pagedReader(shared), reflowable: reflowableReader(shared) };

/// いま使っている振る舞い。書籍を開くときに選ぶ。
let nav = emptyReader;

// ---- 書籍を開く ---------------------------------------------------------

/// 書籍を開く。`carried` は検索から渡ってきたもので、
/// 当たった語（query）と、その章での通し番号（nth）、一覧も出すか（list）を持つ。
async function openPath(path, href, fragment, carried = {}) {
  try {
    state.book = await invoke("open_book", { path });
  } catch (error) {
    toast("開けませんでした: " + error);
    return;
  }
  // 形式を見るのはここだけ。以降の振る舞いの違いは nav の中に閉じる。
  nav = isPaged() ? readers.paged : readers.reflowable;

  // 開いた後の支度で転んでも、呼んだ側は待っていないことがある（メニュー、道具帯）。
  // 受け手がいないと「応答が返りませんでした」だけが残る。ここでまとめて受ける。
  try {
    const saved = await invoke("book_state", { path });
    dressChrome(saved);
    aimFromCarried(carried, href);

    await nav.prepare(saved, href, fragment);
    await followCarried(carried);
    warnIfUnsearchable();
  } catch (error) {
    showFailure("書籍を開いたあとの支度で転びました", error);
  }
}

/// 書籍に合わせて窓の飾りを整える。題名、しおり、目次、使えないタブ。
function dressChrome(saved) {
  document.title = state.book.title;
  $("book-title").textContent = state.book.title;
  // ページの一覧は紙面の書籍にしか意味がない。
  $("sidebar-tabs").querySelector('[data-pane="thumbs"]').hidden = !nav.paged;

  state.bookmarks = saved.bookmarks || [];
  renderBookmarks();
  renderToc();
}

/// 検索の当たりから渡ってきた目当てを、本文を配ってもらう前に決めておく。
/// 印は配信時に入るので、開いてから決めたのでは間に合わない。
function aimFromCarried(carried, href) {
  if (!carried.query || carried.list) return;
  state.mark = aimedAt({
    query: carried.query,
    nth: Number(carried.nth),
    target: nav.markTarget(href),
  });
}

/// 本文が出たあとに、渡されたものの残りを当てる。
async function followCarried(carried) {
  if (!carried.query) return;
  if (carried.list) {
    // 全件を見に来た。同じ語句をこの本で引き直す。
    // 1 冊から拾う上限が上がるので、書棚で打ち切られた続きがここで見える。
    $("search-input").value = carried.query;
    await runSearch();
    return;
  }
  await nav.paintMark(carried.query);
}

/// 入稿用にフォントをアウトライン化した PDF は、見た目が鮮明でも文字を持たない。
/// 検索が黙って 0 件になるより、開いた時点で伝えるほうがよい。
function warnIfUnsearchable() {
  if (state.book.format === "pdf" && !state.book.hasTextLayer) {
    toast("この PDF はテキスト層を持たないため検索できません");
  }
}


// ---- 目次 ---------------------------------------------------------------

function renderToc() {
  const box = $("toc");
  box.textContent = "";
  const walk = (entries, depth) => {
    for (const entry of entries) {
      const a = document.createElement("a");
      a.textContent = entry.title;
      a.className = "depth-" + depth;
      a.dataset.href = entry.href || "";
      a.dataset.fragment = entry.fragment || "";
      box.appendChild(a);
      if (entry.children.length) walk(entry.children, depth + 1);
    }
  };
  walk(state.book.toc, 1);
  markCurrentToc();
}

function markCurrentToc() {
  const current = nav.currentHref();
  for (const a of $("toc").children) {
    a.classList.toggle("current", a.dataset.href === current);
  }
}

$("toc").addEventListener("click", (event) => {
  const a = event.target.closest("a");
  if (!a || !a.dataset.href) return;
  // 離れた 2 か所を並べて読むための道具なので、別窓へ回す道は目次にも要る。
  if (event.metaKey || event.ctrlKey) return openTarget(a, true);
  openTarget(a, false);
});

$("toc").addEventListener("contextmenu", (event) => {
  const a = event.target.closest("a");
  if (!a || !a.dataset.href) return;
  event.preventDefault();
  showMenu(event, [
    ["新しいウィンドウで開く", () => openTarget(a, true)],
    ["ここへ移動", () => openTarget(a, false)],
  ]);
});

/// 目次の項目を開く。PDF はページ番号、EPUB は章の経路を持っている。
function openTarget(a, newWindow) {
  const href = a.dataset.href;
  const fragment = a.dataset.fragment || "";
  if (newWindow) {
    return invoke("open_in_new_window", { path: state.book.path, href, fragment });
  }
  const target = nav.locate(href);
  if (target != null) jump(() => nav.show(target, { fragment }));
}


document.addEventListener("click", (event) => {
  if (!$("menu").hidden && !event.target.closest("#menu")) hideMenu();
  if (!$("settings").hidden && !event.target.closest("#settings, #settings-button")) {
    $("settings").hidden = true;
  }
});


// ---- 拡大と縮小 ---------------------------------------------------------

const ZOOM_MIN = 0.4;
const ZOOM_MAX = 6;


function setZoom(value, fit) {
  state.zoom = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, value));
  // PDF と本文では合う倍率が違うので、別々に覚える。
  state.settings[nav.zoomSetting] = state.zoom;
  if (fit && nav.paged) state.settings.fit = fit;
  saveSettingsSoon(state.settings);
  $("zoom-level").textContent = Math.round(state.zoom * 100) + "%";
  $("fit").value = state.settings.fit;
  applyZoom();
}

function applyZoom() {
  if (state.book) nav.applyZoom();
}

function zoomBy(step) {
  if (!state.book) return;
  // 倍率を手で変えたら、合わせ方は「保つ」へ移る。
  setZoom(state.zoom * step, "custom");
  toast("拡大 " + Math.round(state.zoom * 100) + "%");
}

function resetZoom() {
  if (!state.book) return;
  setZoom(nav.defaultZoom(), nav.defaultFit);
  toast("拡大 " + Math.round(state.zoom * 100) + "%");
}

$("zoom-in").addEventListener("click", () => zoomBy(1.25));
$("zoom-out").addEventListener("click", () => zoomBy(1 / 1.25));
$("fit").addEventListener("change", (event) => {
  const fit = event.target.value;
  setZoom(nav.zoomFor(fit) ?? state.zoom, fit);
});

/// トラックパッドのピンチは、Ctrl 付きの wheel として届く。
/// 横スワイプには移動を割り当てていないので、こちらとは衝突しない。
function onWheel(event) {
  if (!event.ctrlKey) return;
  event.preventDefault();
  if (!state.book) return;
  // ピンチ 1 回ぶんの deltaY は小さい。180 で割ると 1 回あたり 0.5% ほどにしかならず、
  // 指を動かしても倍率がほとんど変わらない。
  setZoom(state.zoom * Math.exp(-event.deltaY / 50), "custom");
}
document.addEventListener("wheel", onWheel, { passive: false });


// ---- 検索 ---------------------------------------------------------------

let searchTimer = null;
$("search-input").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(runSearch, 220);
});

async function runSearch() {
  const query = $("search-input").value.trim();
  const box = $("results");
  box.textContent = "";
  // 引き直したら、前の語の強調は用済みになる。空にしたときも消える。
  forgetMark();
  if (!state.book || query.length === 0) return;
  showPane("results");

  const hits = await invoke("search_book", { id: state.book.id, query });
  if (hits.length === 0) {
    const empty = document.createElement("div");
    empty.setAttribute("style", "padding:8px 12px;color:var(--dim)");
    empty.textContent = state.book.hasTextLayer ? "見つかりませんでした" : "この書籍は文字を持ちません";
    box.appendChild(empty);
    return;
  }
  for (const hit of hits) {
    const openHit = (newWindow) => {
      const target = nav.hitTarget(hit);
      if (newWindow) {
        // 紙面はページ番号で、リフローは章の経路で行き先を言う。
        return invoke("open_in_new_window", {
          path: state.book.path,
          href: nav.paged ? String(target) : hit.href,
          fragment: "",
          query,
          nth: hit.nth,
        });
      }
      aimAt(query, hit);
      if (target != null) jump(() => nav.show(target, { goTo: hit.progression }));
    };
    box.appendChild(hitRow(hit, {
      open: openHit,
      menu: (event) => showMenu(event, [
        ["新しいウィンドウで開く", () => openHit(true)],
        ["ここへ移動", () => openHit(false)],
      ]),
    }));
  }
}


// ---- 当たりの強調 -------------------------------------------------------
//
// 一覧に前後の文脈が出ていても、着いた章やページのどこに当たったのかは分からない。
// 飛んだ先で目当ての語を探し直さずに済ませるための印である（spec.md 10.4）。
//
// **本文へ印を入れるのは Rust の仕事**。章を配るときに囲んで返す（core の mark）。
// こちらは「どの当たりを囲むか」を決めて経路に載せ、着いたらそこまで送るだけにする。
// 文字節を切って包む手術をここに置くと、抽出（html_text）と数え方がずれる余地が残る。
//
// 紙面（PDF）は文字を持たない絵なので、こちらだけは当たりの矩形を上に重ねる。

/// 当たりを強調の目当てにする。移動そのものは呼び出し側が行う。
function aimAt(query, hit) {
  state.mark = aimedAt({
    query,
    nth: hit.nth,
    target: nav.paged ? { page: nav.hitTarget(hit) } : { href: hit.href },
    rects: hit.rects,
  });
}



function forgetMark() {
  state.mark = null;
  // 本文に入っている印は配られたものだが、外すだけならこちらでできる。
  // 配り直すと画面がちらつくので、その場で包みを解く。外し方は読み手が知っている。
  nav.clearMarks();
}

/// 本文を配ってもらう経路。当たりを囲んでほしい章（ページ）には、語と通し番号を載せる。
function bookUrl(href, page = null) {
  const url = `/book/${state.book.id}/${encodePath(href)}`;
  const mark = state.mark;
  const wanted = mark && (isFixed() ? page === mark.page : mark.href === href);
  return url + markQuery(mark, wanted);
}

// ---- しおりと位置 -------------------------------------------------------

let rememberTimer = null;
function rememberSoon() {
  clearTimeout(rememberTimer);
  rememberTimer = setTimeout(() => {
    if (!state.book) return;
    invoke("remember_position", { path: state.book.path, position: currentPosition() });
  }, 700);
}

const currentPosition = () => nav.position();

async function toggleBookmark() {
  if (!state.book) return;
  const position = currentPosition();
  const label = nav.label();
  state.bookmarks = await invoke("toggle_bookmark", {
    path: state.book.path,
    bookmark: { ...position, label },
  });
  renderBookmarks();
  toast("しおりを更新しました");
}

function renderBookmarks() {
  const box = $("bookmarks");
  box.textContent = "";
  for (const bookmark of state.bookmarks) {
    const a = document.createElement("a");
    a.textContent = bookmark.label || bookmark.href;
    a.addEventListener("click", () => {
      jump(() => nav.reveal(bookmark));
    });
    box.appendChild(a);
  }
}


// ---- 表示設定 -----------------------------------------------------------

async function refreshStyle() {
  state.style = await invoke("reader_css", { settings: state.settings });
  document.body.classList.toggle("dark", state.settings.theme === "dark");
  nav.restyle();
}

// 表示設定の欄。ここに無い設定（倍率など）は道具帯で扱う。
const SETTING_FIELDS = ["fontSizePercent", "lineHeight", "maxWidthEm", "theme", "codeWrap", "publisherStyle"];

// 設定の欄は #settings の中だけを見る。
// id だけで引くと、zoom や fit のように道具帯の要素と名前がぶつかり、
// 関係ない場所（題名の欄）に値を書き込んでしまう。
const settingField = (name) => document.querySelector("#settings #" + name);

function bindSettings() {
  for (const name of SETTING_FIELDS) {
    const input = settingField(name);
    if (!input) continue;
    const apply = () => {
      state.settings[name] = input.type === "checkbox" ? input.checked
        : input.type === "range" ? Number(input.value) : input.value;
      const label = input.parentElement.querySelector("span");
      if (label) label.textContent = input.value;
      invoke("save_settings", { settings: state.settings });
      refreshStyle();
    };
    input.addEventListener("input", apply);
    input.addEventListener("change", apply);
  }
}

function fillSettings() {
  for (const name of SETTING_FIELDS) {
    const input = settingField(name);
    const value = state.settings[name];
    if (!input) continue;
    if (input.type === "checkbox") input.checked = Boolean(value);
    else input.value = value;
    const label = input.parentElement.querySelector("span");
    if (label) label.textContent = input.value;
  }
}


// ---- 焦点 ---------------------------------------------------------------

// キー入力の行き先を決めておく。
// どこにも焦点が無いと、矢印キーがどの文書にも届かず、章が進まない。
//
// **窓が焦点を得たことを引き金にしてはならない。**
// 下の focus_webview は OS から見た受け手を動かすので、焦点の知らせを呼び返す。
// その知らせで呼び返すと輪になり、毎秒何百回と回って催しの列が詰まる。
// 窓が閉じられなくなり、本文の焦点枠がその速さで明滅する。
// 同じ輪を Rust 側でも踏んで消してある（8342e3d）。こちらはその片割れだった。
//
// 戻すのは名指しのときだけでよい。ダイアログが受け手を持ち去る件は
// 閉じた直後に呼ぶ側で面倒を見ており、他アプリから戻ったときは Win32 も
// AppKit も既定で戻す。
function focusContent() {
  // 2 段ある。
  //
  // 1 段目は OS から見た鍵盤の受け手（macOS の first responder）。
  // 画面側の focus() では動かせず、Rust 側からしか戻せない。
  // ダイアログを開いたあとなどに WebView から外れたまま戻らないことがあり、
  // そうなると画面では焦点が当たって見えるのにキーが 1 つも届かない。
  invoke("focus_webview").catch(() => {});

  // 2 段目は文書の中の焦点。**本文の iframe には移さない。**
  // あちらは allow-scripts を与えていないため、焦点を移すとキーの行き先が無くなる。
  // 親に置いておけば、上下やスペースはこちらから本文へ送れる（scrollContent）。
  if (!state.book) return;
  if (document.activeElement === $("search-input")) return;
  $("stage").focus();
}


// ---- 操作 ---------------------------------------------------------------

// 矢印キーは移動、上下とスペースは読むための送り。軸ごとに意味を 1 つに定める。
function onKeyDown(event) {
  const editing = event.target && /input|textarea/i.test(event.target.tagName || "");
  trace(`key=${event.key} loading=${nav.loading()} at=${nav.at()} `
      + `target=${event.target && event.target.nodeName} `
      + `sameDoc=${event.target && event.target.ownerDocument === document}`);
  const command = event.metaKey || event.ctrlKey;

  if (command && event.key.toLowerCase() === "o") { event.preventDefault(); return pick(); }
  if (command && event.key.toLowerCase() === "n") {
    event.preventDefault();
    return openHere();
  }
  if (command && event.key.toLowerCase() === "l") {
    event.preventDefault();
    return invoke("open_shelf");
  }
  if (command && event.key === "[") { event.preventDefault(); return goBack(); }
  if (command && event.key === "]") { event.preventDefault(); return goForward(); }
  if (command && event.key === "ArrowUp") { event.preventDefault(); return step(-1); }
  if (command && event.key === "ArrowDown") { event.preventDefault(); return step(1); }
  if (command && event.key === "\\") { event.preventDefault(); return toggleSidebar(); }
  if (command && event.key.toLowerCase() === "d") { event.preventDefault(); return toggleBookmark(); }
  if (command && event.key.toLowerCase() === "f") {
    event.preventDefault();
    focusSearch();
    return;
  }
  if (command && event.altKey && event.key.toLowerCase() === "i") { event.preventDefault(); return diagnose(); }
  if (command && (event.key === "+" || event.key === "=")) { event.preventDefault(); return zoomBy(1.25); }
  if (command && event.key === "-") { event.preventDefault(); return zoomBy(1 / 1.25); }
  if (command && event.key === "0") { event.preventDefault(); return resetZoom(); }
  if (event.key === "Escape") {
    hideMenu();
    nav.dismissOverlays();
    return;
  }
  if (editing || command || !state.book) return;

  // 右開きの出版物では左右の意味を入れ替える。
  const back = state.book.direction === "rtl" ? "ArrowRight" : "ArrowLeft";
  const forward = state.book.direction === "rtl" ? "ArrowLeft" : "ArrowRight";
  if (event.key === back) { event.preventDefault(); return step(-1); }
  if (event.key === forward) { event.preventDefault(); return step(1); }

  // 縦の送り。焦点は親に置いてあるので、本文へはこちらから送る。
  // 本文から上がってきたキーは、あちらで既に縦へ送られている。二重に送らない。
  if (event.fromContent) return;
  const step_ = { ArrowDown: 60, ArrowUp: -60, PageDown: 0.9, PageUp: -0.9 }[event.key];
  const space = event.key === " " ? (event.shiftKey ? -0.9 : 0.9) : null;
  if (step_ == null && space == null) return;
  event.preventDefault();
  scrollContent(space != null ? space : step_, space != null || Math.abs(step_) < 1);
}

/// 引くための欄へ焦点を移す。
function focusSearch() {
  $("search-input").focus();
}

/// 本文を送る。割合で渡されたときは 1 画面ぶんとして扱う。
const scrollContent = (amount, byScreen) => nav.scrollBy(amount, byScreen);


// ---- 履歴 ---------------------------------------------------------------
//
// 目次や検索から飛んだあと、元いた場所へ帰れないと読み比べにならない。
// 覚えるのは飛んだ先ではなく飛ぶ直前の場所で、そこがブラウザの戻ると同じ意味になる。

/// 飛ぶ。いまいた場所を履歴へ積んでから動く。
/// これから飛ぶ、という知らせ。いまいた場所を履歴へ積む。
///
/// 本文や紙面の側が「履歴を積め」と命じるのではなく、動くことを知らせるだけにする。
/// 積むかどうかを決めるのは窓の側の仕事で、そうしておけば本文と紙面は
/// 履歴という仕組みを知らずに済む（macOS 版の onNavigated と同じ向き）。
function departing() {
  if (!state.book) return;
  state.back.push(currentPosition());
  if (state.back.length > 100) state.back.shift();
  state.forward.length = 0;
  updateHistoryButtons();
}

/// 着いた、という知らせ。目次の現在地を塗り直し、読書位置を覚える。
function moved() {
  markCurrentToc();
  rememberSoon();
}

function jump(action) {
  departing();
  action();
}

function goBack() {
  const target = state.back.pop();
  if (!target) return;
  state.forward.push(currentPosition());
  reveal(target);
  updateHistoryButtons();
}

function goForward() {
  const target = state.forward.pop();
  if (!target) return;
  state.back.push(currentPosition());
  reveal(target);
  updateHistoryButtons();
}

/// 覚えておいた場所へ戻す。ここでは履歴を積まない。
/// 覚えておいた場所へ戻す。ここでは履歴を積まない。
/// 割合だけでなく書き出しも手掛かりにするので、形式ごとの戻し方は nav が持つ。
const reveal = (position) => nav.reveal(position);

function updateHistoryButtons() {
  $("go-back").disabled = state.back.length === 0;
  $("go-forward").disabled = state.forward.length === 0;
}

/// 1 つ送る。紙面の送りも履歴に載せる。
/// 目次から飛んだあと、元のページへ帰れるようにするため。
function step(delta) {
  trace(`step(${delta}) loading=${nav.loading()} at=${nav.at()}`);
  nav.step(delta);
}

// ---- 道具帯とサイドバー -------------------------------------------------

async function diagnose() {
  if (!state.book || state.book.format === "pdf") return;
  const report = await invoke("diagnose", { id: state.book.id });
  // 目で見るだけでは書き写せない。押した時点で写しておく。
  await navigator.clipboard.writeText(diagnosis.detail(state.book.title, report)).catch(() => {});
  toast(diagnosis.summary(report).join("　") + "（診断をコピーしました）");
}

function toggleSidebar() {
  const sidebar = $("sidebar");
  sidebar.hidden = !sidebar.hidden;
  $("toggle-sidebar").classList.toggle("on", !sidebar.hidden);
}

function showPane(name) {
  for (const button of $("sidebar-tabs").children) {
    button.classList.toggle("on", button.dataset.pane === name);
  }
  for (const id of ["toc", "thumbs", "results", "bookmarks"]) $(id).hidden = id !== name;
  if (name === "thumbs") nav.showThumbs();
  $("sidebar").hidden = false;
}

$("sidebar-tabs").addEventListener("click", (event) => {
  if (event.target.dataset.pane) showPane(event.target.dataset.pane);
});

// ---- 束ね ---------------------------------------------------------------

/// いま読んでいるところを、もう 1 つの窓で開く。
/// 同じ書籍でも構わない。離れた 2 か所を並べて見るための道具である。
function openHere() {
  if (!state.book) return;
  invoke("open_in_new_window", { path: state.book.path, href: nav.hereHref() });
}

async function pick() {
  const path = await invoke("pick_book");
  // ダイアログが鍵盤の受け手を持ち去ったままのことがある。閉じた直後に戻す。
  invoke("focus_webview").catch(() => {});
  if (path) await openPath(path);
  focusContent();
}

$("open-button").addEventListener("click", pick);
$("new-window").addEventListener("click", openHere);
$("shelf-button").addEventListener("click", () => invoke("open_shelf"));
$("toggle-sidebar").addEventListener("click", toggleSidebar);
$("layout").addEventListener("change", (event) => {
  state.settings.pageLayout = event.target.value;
  saveSettingsSoon(state.settings);
  // 組み直してからいまのページへ戻す。並べ方を変えても居場所は変わらない。
  nav.relayout();
});
$("go-back").addEventListener("click", goBack);
$("go-forward").addEventListener("click", goForward);
$("bookmark").addEventListener("click", toggleBookmark);
$("settings-button").addEventListener("click", (event) => {
  event.stopPropagation();
  $("settings").hidden = !$("settings").hidden;
});
document.addEventListener("keydown", onKeyDown);

let resizeTimer = null;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (state.book) nav.refit();
  }, 200);
});


// ---- 起動 ---------------------------------------------------------------

async function main() {
  await ensureBackend();
  state.settings = await loadSettings();
  applyTheme(state.settings);
  fillSettings();
  bindSettings();
  await refreshStyle();

  const path = PARAMS.get("path");
  if (path) {
    return openPath(path, PARAMS.get("href"), PARAMS.get("frag"), {
      query: PARAMS.get("q"),
      nth: PARAMS.get("nth"),
      list: PARAMS.get("list") === "1",
    });
  }

  // 書籍を持たない読書の窓は作らない。ここへ来たら書棚へ回す。
  invoke("open_shelf");
}

// メニューからの呼び出しと、動作確認の治具に渡す入口。
// 画面の中身をそのまま外へ出さず、必要なものだけを名前を付けて渡す。
window.choro = {
  kind: "reader",
  state,
  /// いま使っている読み手。治具が居場所を尋ねるために要る。
  get nav() { return nav; },
  step,
  goBack,
  goForward,
  hideMenu,
  showPane,
  toggleSidebar,
  toggleBookmark,
  diagnose,
  pick,
  openHere,
  zoomBy,
  resetZoom,
  runSearch,
};

watchForFailures();

// 受け取りの登録で転んでも、残りの組み立てを道連れにしない。
// ここが例外を投げると、この後ろの main() が動かず窓が黙って死ぬ。
try {
  listenToMenu({
    open: pick,
    "new-window": openHere,
    shelf: () => invoke("open_shelf"),
    back: goBack,
    forward: goForward,
    prev: () => step(-1),
    next: () => step(1),
    find: focusSearch,
    bookmark: toggleBookmark,
    sidebar: toggleSidebar,
    "zoom-in": () => zoomBy(1.25),
    "zoom-out": () => zoomBy(1 / 1.25),
    "zoom-reset": resetZoom,
    diagnose,
    "sample-reflowable": () => invoke("open_sample", { kind: "reflowable" }),
    "sample-fixed": () => invoke("open_sample", { kind: "fixed" }),
    "sample-pdf": () => invoke("open_sample", { kind: "pdf" }),
    selftest: () => window.choroSelfTest && window.choroSelfTest(),
  });
} catch (error) {
  showFailure("メニューを受け取れません", error);
}

main().catch((error) => showFailure("起動に失敗しました", error));

