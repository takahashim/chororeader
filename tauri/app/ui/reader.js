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
import { aimedAt, markQuery, takeApproach } from "./lib/mark.js";
import {
  chapterOfHref as chapterOfHrefIn, isFixedBook, isPagedBook, pageAfterStep,
  pageCountOf, pageOfHref as pageOfHrefIn, pagesToShow,
} from "./lib/layout.js";

const state = {
  book: null,
  index: 0,
  page: 0,
  /// いまの倍率。EPUB では本文全体に、PDF では描画の倍率に効く。
  zoom: 1,
  /// PDF のページの大きさ（ポイント）。合わせ方の計算に要る。
  pageSize: null,
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

// iframe は生成直後に about:blank を持っており、それも readyState は 'complete' を返す。
// load イベントや readyState で待つと空の文書を掴む。目当ての印が現れるまで待つ。
function waitUntil(check, what, timeout = 10000) {
  return new Promise((resolve, reject) => {
    const started = performance.now();
    const tick = () => {
      let value = null;
      try { value = check(); } catch (_) { /* 生成元が違えば例外 */ }
      if (value) return resolve(value);
      if (performance.now() - started > timeout) return reject(new Error(what + " を待って時間切れ"));
      requestAnimationFrame(tick);
    };
    tick();
  });
}

const encodePath = (path) => path.split("/").map(encodeURIComponent).join("/");

// 形式で決まることは lib/layout.js に置き、ここではいまの書籍を当てて呼ぶ。
const isPaged = () => isPagedBook(state.book);
const isFixed = () => isFixedBook(state.book);
const pageOfHref = (href) => pageOfHrefIn(state.book, href);
const chapterOfHref = (href) => chapterOfHrefIn(state.book, href);
const visiblePages = (total) =>
  pagesToShow(state.settings.pageLayout, state.page, total, state.book.spreads);
const isContinuous = () => state.settings.pageLayout === "continuousScroll";

/// 紙面のページ番号へ移す。中身の作り方だけが形式で違う。
function showPage(page) {
  return isFixed() ? showFixed(page) : showPdf(page);
}

/// 紙面を担う要素だけ。当たりの枠も同じ器に入るので、番号を持つものに絞る。
function pageParts(box) {
  return Array.from(box.children).filter((el) => el.dataset.page !== undefined);
}

/// 器の中から、そのページを担う要素を探す。連続以外では並びと番号がずれる。
function pageElement(box, page) {
  return pageParts(box).find((el) => Number(el.dataset.page) === page);
}

// ---- 形式ごとの振る舞い ---------------------------------------------------
//
// spec.md 367 の取り決め：ナビゲータは目次・検索・位置表現を形式共通の形で提供し、
// サイドバー・履歴・書棚は形式を意識しない。新しい形式を足す費用が、ここに閉じる。
//
// リフロー（本文を iframe に入れる）と紙面（PDF と固定レイアウト EPUB）で振る舞いが変わる。
// 違いはこの 2 つの中だけに書き、外は `nav` を通してしか触らない。

/// リフローする本文。章を 1 つずつ iframe に入れる。
const reflowableReader = {
  paged: false,
  /// 倍率を覚える先。紙面と本文では合う倍率が違う。
  zoomSetting: "epubZoom",
  defaultFit: "custom",

  /// 行き先（章の番号）。目次や当たりは経路で言ってくる。
  locate: (href) => chapterOfHref(href),
  show: (index, options = {}) => showChapter(index, options.fragment || null, options.goTo || null),
  currentHref: () => (state.book.chapters[state.index] || {}).href,

  position() {
    const doc = $("page").contentDocument;
    const el = doc && (doc.scrollingElement || doc.documentElement);
    const progression = el && el.scrollHeight > 0 ? el.scrollTop / el.scrollHeight : 0;
    return {
      href: this.currentHref() || "",
      progression,
      page: 0,
      fragment: "",
      // 割合だけだと、文字サイズや本文幅を変えたときに見失う。
      // いま画面の上端に来ている文字を覚えておき、次はそれを手掛かりに戻す。
      text: doc ? topText(doc) : "",
    };
  },

  reveal(position) {
    const index = this.locate(position.href);
    if (index != null) showChapter(index, null, position);
  },

  step(delta) {
    // 読み込み中の分は取っておき、着いてからまとめて動かす。
    if (arriving) { arriving.queuedSteps += delta; return; }
    const index = state.index + delta;
    if (index < 0 || index >= state.book.chapters.length) return;
    jump(() => showChapter(index));
  },

  scrollBy(amount, byScreen) {
    const doc = $("page").contentDocument;
    const el = doc && (doc.scrollingElement || doc.documentElement);
    if (!el) return;
    el.scrollTop += byScreen ? amount * doc.defaultView.innerHeight : amount;
  },

  applyZoom() {
    // リフローする本文は、文字も図も一緒に拡大する。
    const doc = $("page").contentDocument;
    if (doc && doc.documentElement) doc.documentElement.style.zoom = state.zoom;
  },

  /// 当たりの目当て。リフローは章の経路で指す。
  markTarget: (href) => ({ href: href || "", page: 0 }),
  /// 検索の当たりの行き先。
  hitTarget: (hit) => chapterOfHref(hit.href),
  /// しおりに付ける名前。
  label: () => (state.book.chapters[state.index] || {}).title || "",
  /// いま読んでいるところを、別の窓で開くときの言い方。
  hereHref: () => (state.book.chapters[state.index] || {}).href || "",
  /// 別の窓で開いたときの枠。リフローは印が本文に入って配られるので、何も要らない。
  paintMark: async () => {},

  prepare(saved, href, fragment) {
    $("pdf").hidden = true;
    $("page").hidden = false;
    $("fit").hidden = true;
    $("layout").hidden = true;
    state.pageSize = null;
    state.zoom = state.settings.epubZoom || 1;
    $("zoom-level").textContent = Math.round(state.zoom * 100) + "%";
    const index = this.locate(href || saved.position.href) ?? 0;
    // 章を名指しで開くときは、覚えていた場所ではなく、指された場所へ着く。
    return showChapter(index, fragment || null, href ? null : saved.position);
  },
};

/// 紙面。PDF と固定レイアウト EPUB は、綴じ方向も拡大も送り方も同じに振る舞う。
const pagedReader = {
  paged: true,
  zoomSetting: "zoom",
  defaultFit: "width",

  locate: (href) => pageOfHref(href),
  show: (page) => showPage(page),
  currentHref: () =>
    (isFixed() ? (state.book.pages[state.page] || {}).href : String(state.page)),

  position: () => ({ href: "", progression: 0, page: state.page, fragment: "", text: "" }),
  reveal: (position) => showPage(position.page),

  step(delta) {
    jump(() => showPage(pageAfterStep(state.settings.pageLayout, state.page, delta, state.book.spreads)));
  },

  scrollBy(amount, byScreen) {
    const box = $("pdf");
    box.scrollTop += byScreen ? amount * box.clientHeight : amount;
  },

  applyZoom() {
    layoutPdf();
    // 固定レイアウトは元の紙面をそのまま置くので、描き直しが要らない。
    if (!isFixed()) renderPdf();
  },

  /// 当たりの目当て。紙面はページ番号で指す。
  markTarget: (href) => ({ href: "", page: Number(href) || 0 }),
  hitTarget: (hit) => (isFixed() ? pageOfHref(hit.href) : hit.page),
  label: () => `p.${state.page + 1}`,
  hereHref: () => String(state.page),

  /// 紙面の当たりは絵の上に重ねるので、開いてから土台に枠を尋ね直す。
  /// 固定レイアウトは本文が HTML なので、印は配られたものがそのまま入っている。
  async paintMark(query) {
    if (isFixed()) return;
    state.mark.rects = await invoke("page_marks", {
      id: state.book.id, page: state.page, query,
    }).catch(() => []);
    layoutMarks();
  },

  prepare(saved, href) {
    $("page").hidden = true;
    $("pdf").hidden = false;
    $("fit").hidden = false;
    $("layout").hidden = false;
    $("layout").value = state.settings.pageLayout;
    return isFixed() ? this.prepareFixed(saved, href) : this.preparePdf(saved, href);
  },

  async prepareFixed(saved, href) {
    // 寸法は meta viewport から来る。名乗っていない書籍のために当てを置く。
    state.pageSize = state.book.pageSize || [800, 1130];
    this.fitFirst(state.settings.zoom || 1);
    await showFixed(href ? Number(href) : saved.position.page || 0);
  },

  async preparePdf(saved, href) {
    // 合わせ方を計算するにはページの大きさが要る。1 ページ目で代表させる。
    state.pageSize = await invoke("page_size", { id: state.book.id, page: 0 }).catch(() => null);
    this.fitFirst(state.settings.zoom);
    await showPdf(href ? Number(href) : saved.position.page || 0);
  },

  fitFirst(fallback) {
    const fitted = zoomForFit(state.settings.fit);
    setZoom(fitted == null ? fallback : fitted, state.settings.fit);
  },
};

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
};

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
  nav = isPaged() ? pagedReader : reflowableReader;

  const saved = await invoke("book_state", { path });
  dressChrome(saved);
  aimFromCarried(carried, href);

  await nav.prepare(saved, href, fragment);
  await followCarried(carried);
  warnIfUnsearchable();
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


// ---- 本文（EPUB） -------------------------------------------------------

// いま飛んでいる章の読み込み。着いたときにすることを、一緒に持たせる。
//
// 章は iframe に入れるので、入り終わるまで手が付けられない。その間に押された送りは
// 取っておかないと「進まないことがある」になり、送り先を別の変数に置くと、
// 決める側と受け取る側が離れて追えなくなる。1 つの値にまとめて、着いたら捨てる。
//
//   { token: 追い越しの見分け, goTo: 着いたら送る先, queuedSteps: 待たせた送り }
//
// 着いたときにすることは**値で持つ**。関数を持たせると、ここが何にでも使える仕掛けになる。
let arriving = null;
let loadTokens = 0;

const isLoading = () => arriving !== null;

/// 章を出す。`goTo` は着いたときに送る先で、割合の数値か、位置の対象を渡す。
async function showChapter(index, fragment, goTo = null) {
  const chapter = state.book.chapters[index];
  if (!chapter) return;
  const token = ++loadTokens;
  state.index = index;
  arriving = { token, goTo, queuedSteps: 0 };

  const frame = $("page");
  const url = bookUrl(chapter.href);

  // 読み込みのあいだも、入れ替わる文書に手を付け続ける。
  // 空きを作ると、その隙に押されたキーがどこにも届かない。
  const stopWatching = watchDocument(frame);

  let doc;
  try {
    doc = await loadInto(frame, url);
  } catch (error) {
    stopWatching();
    arriving = null;
    toast(String(error.message || error));
    return;
  }
  stopWatching();
  // 後から押された分に追い越されていたら、こちらの後始末はしない。
  // 新しい読み込みが `arriving` を持っているので、こちらは触らずに降りる。
  if (!arriving || arriving.token !== token) return;

  decorate(doc);
  markCurrentToc();

  focusContent();
  applyZoom();

  if (fragment) {
    const target = doc.getElementById(fragment);
    if (target) target.scrollIntoView();
  } else if (arriving.goTo != null) {
    // 数字だけ渡されたときは割合として扱う（検索やしおりからの移動）。
    restorePosition(doc, typeof arriving.goTo === "number"
      ? { progression: arriving.goTo }
      : arriving.goTo);
  } else {
    (doc.scrollingElement || doc.documentElement).scrollTop = 0;
  }
  // 位置を決めたあとで、囲まれている当たりまで送る。順番を逆にできない。
  approachMark(doc);

  const queued = arriving.queuedSteps;
  arriving = null;
  rememberSoon();
  // 待たせた送りは、着いてからまとめて動かす。
  if (queued !== 0) step(queued);
}

/// 目当ての文書が入り終わるまで待つ。
///
/// iframe は生成直後に about:blank を持っており、それも readyState は 'complete' を返す。
/// ファイル名の部分一致で見分けると、名前が似た章どうしで取り違える。経路全体で照合する。
function loadInto(frame, url) {
  const expected = decodeURIComponent(new URL(url, location.href).pathname);
  // 同じ章をもう一度開くことがある（検索結果から、いま読んでいる章の当たりへ飛ぶときなど）。
  // 差し替わるまで前の文書が残っており、経路だけで見分けると捨てられる側を掴む。
  // そちらに手を入れても次の描画で消えるので、別の文書になるまで待つ。
  const previous = frame.contentDocument;
  frame.src = url;
  return waitUntil(() => {
    const doc = frame.contentDocument;
    if (!doc || doc === previous || doc.readyState !== "complete" || !doc.body) return null;
    return decodeURIComponent(doc.location.pathname) === expected ? doc : null;
  }, "本文");
}

/// 入れ替わる文書へ、現れた次の描画で手を付ける。読み込みが終わるまでの繋ぎ。
function watchDocument(frame) {
  let stopped = false;
  let seen = null;
  const tick = () => {
    if (stopped) return;
    const doc = frame.contentDocument;
    if (doc && doc !== seen) {
      seen = doc;
      // 同じ関数を二度足しても増えない。decorate と重なってよい。
      doc.addEventListener("keydown", onKeyDown);
    }
    requestAnimationFrame(tick);
  };
  tick();
  return () => { stopped = true; };
}

/// 本文の文書に手を入れる。注入ではなく、親から直接触る。
function decorate(doc) {
  applyStyle(doc);
  bindFigures(doc);
  addCodeCopyButtons(doc);
  addChapterFooter(doc);

  doc.addEventListener("click", onBodyClick, true);
  doc.addEventListener("keydown", onKeyDown);
  doc.addEventListener("wheel", onWheel, { passive: false });
  doc.addEventListener("scroll", rememberSoon, { passive: true });
  doc.defaultView.addEventListener("scroll", rememberSoon, { passive: true });
}

/// 図版は本文の幅に縮めてあるので、細かい図は読めない。押したら大きく出す。
function bindFigures(doc) {
  for (const img of doc.querySelectorAll("img")) {
    if (img.dataset.choroZoom) continue;
    img.dataset.choroZoom = "1";
    img.style.cursor = "zoom-in";
    img.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      showLightbox(img.src);
    });
  }
}

function showLightbox(src) {
  $("lightbox-image").src = src;
  $("lightbox").hidden = false;
}

function hideLightbox() {
  $("lightbox").hidden = true;
  $("lightbox-image").src = "";
}

function applyStyle(doc) {
  let tag = doc.getElementById("choro-style");
  if (!tag) {
    tag = doc.createElement("style");
    tag.id = "choro-style";
    (doc.head || doc.documentElement).appendChild(tag);
  }
  tag.textContent = state.style.css;

  // 暗いテーマでだけ、背景色を持たない要素に文字色を当てる。
  // 一律に上書きすると、見出しの黒帯のように背景色を持つ要素から文字色を奪う。
  for (const el of doc.querySelectorAll(".choro-fg")) el.classList.remove("choro-fg");
  if (!state.style.needsForegroundMarking) return;
  const view = doc.defaultView;
  const walk = (el) => {
    const background = view.getComputedStyle(el).backgroundColor;
    const painted = background && background !== "transparent" && !background.startsWith("rgba(0, 0, 0, 0)");
    if (painted) return; // ここから内側は出版社の配色に任せる
    el.classList.add("choro-fg");
    for (const child of el.children) walk(child);
  };
  if (doc.body) walk(doc.body);
}

function addCodeCopyButtons(doc) {
  for (const pre of doc.querySelectorAll("pre")) {
    if (pre.dataset.choroCopy) continue;
    pre.dataset.choroCopy = "1";
    pre.style.position = "relative";
    const button = doc.createElement("button");
    // こちらが足したものだと分かる印。当たりを数えるときに本文から外す。
    button.className = "choro-copy";
    button.textContent = "コピー";
    button.setAttribute("style",
      "position:absolute;top:6px;right:6px;font-size:11px;padding:2px 8px;" +
      "border-radius:4px;border:1px solid rgba(127,127,127,.5);background:rgba(255,255,255,.85);" +
      "color:#222;cursor:pointer;opacity:0;transition:opacity .12s");
    pre.addEventListener("mouseenter", () => { button.style.opacity = "1"; });
    pre.addEventListener("mouseleave", () => { button.style.opacity = "0"; });
    button.addEventListener("click", async (event) => {
      event.preventDefault();
      event.stopPropagation();
      const text = Array.from(pre.childNodes)
        .filter((n) => n !== button)
        .map((n) => n.textContent).join("");
      await navigator.clipboard.writeText(text);
      toast("コードをコピーしました");
    });
    pre.appendChild(button);
  }
}

// 縦は読む軸、横は移動する軸。スクロールでは章を跨がないため、章末に導線を置く。
function addChapterFooter(doc) {
  if (doc.getElementById("choro-footer") || !doc.body) return;
  const next = state.book.chapters[state.index + 1];
  if (!next) return;
  const footer = doc.createElement("div");
  footer.id = "choro-footer";
  footer.setAttribute("style", "margin:3em 0 1em;text-align:center");
  const button = doc.createElement("button");
  // 目次に無い章は題が付かず、代わりにファイル名が入る。それを見せても意味がない。
  const named = next.title && next.title !== next.href.split("/").pop();
  button.textContent = named ? "次の章へ： " + next.title : "次の章へ";
  button.setAttribute("style",
    "font:inherit;padding:8px 18px;border-radius:6px;cursor:pointer;" +
    "border:1px solid rgba(127,127,127,.5);background:transparent;color:inherit");
  button.addEventListener("click", () => jump(() => showChapter(state.index + 1)));
  footer.appendChild(button);
  doc.body.appendChild(footer);
}


// ---- リンク -------------------------------------------------------------

function onBodyClick(event) {
  const anchor = event.target.closest && event.target.closest("a[href]");
  if (!anchor) return;
  const raw = anchor.getAttribute("href");
  if (!raw) return;
  event.preventDefault();

  if (/^(https?|mailto):/i.test(raw)) {
    toast("ブラウザで開きます: " + raw);
    invoke("open_external", { url: raw });
    return;
  }

  const [path, fragment] = raw.split("#");
  const href = path ? resolveHref(state.book.chapters[state.index].href, path) : state.book.chapters[state.index].href;

  if (event.metaKey || event.ctrlKey) {
    invoke("open_in_new_window", { path: state.book.path, href });
    return;
  }
  showPopover(anchor, href, fragment || null);
}

// core と同じ規則で畳む。画面側にも同じ規則が要る場面はここだけ。
function resolveHref(base, href) {
  if (href.startsWith("/")) return href.slice(1);
  const parts = base.split("/").slice(0, -1);
  for (const part of decodeURIComponent(href).split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") { parts.pop(); continue; }
    parts.push(part);
  }
  return parts.join("/");
}

async function showPopover(anchor, href, fragment) {
  const built = await invoke("preview_link", {
    id: state.book.id, href, fragment, css: state.style.css,
  });
  if (!built) return toast("参照先を読めませんでした");

  const box = $("popover");
  const body = $("popover-body");
  body.textContent = "";

  const frame = document.createElement("iframe");
  frame.setAttribute("sandbox", "allow-same-origin");
  body.appendChild(frame);

  const actions = document.createElement("div");
  actions.setAttribute("style",
    "display:flex;gap:8px;padding:6px 10px;border-top:1px solid var(--line);background:var(--bar)");
  const go = document.createElement("button");
  go.textContent = "ここへ移動";
  const newWindow = document.createElement("button");
  newWindow.textContent = "新しいウィンドウで開く";
  for (const button of [go, newWindow]) {
    button.setAttribute("style",
      "font:inherit;padding:3px 10px;border-radius:5px;cursor:pointer;" +
      "border:1px solid var(--line);background:var(--panel);color:var(--text)");
  }
  go.addEventListener("click", () => {
    hidePopover();
    const index = chapterOfHref(href);
    if (index != null) jump(() => showChapter(index, fragment));
  });
  newWindow.addEventListener("click", () => {
    hidePopover();
    invoke("open_in_new_window", { path: state.book.path, href });
  });
  actions.append(go, newWindow);
  body.appendChild(actions);

  const rectangle = anchor.getBoundingClientRect();
  const stage = $("stage").getBoundingClientRect();
  box.hidden = false;
  const top = Math.min(stage.height - box.offsetHeight - 10, rectangle.bottom + 8);
  box.style.top = Math.max(8, top) + "px";
  box.style.left = Math.max(8, Math.min(stage.width - box.offsetWidth - 8, rectangle.left)) + "px";

  frame.srcdoc = built.html;
  frame.style.height = built.isFootnote ? "auto" : "100%";

  // 抜粋の中に焦点が移ったままでも操作できるようにする。
  waitUntil(() => {
    const d = frame.contentDocument;
    return d && d.readyState === "complete" && d.body ? d : null;
  }, "抜粋", 3000).then((d) => d.addEventListener("keydown", onKeyDown)).catch(() => {});
}

function hidePopover() {
  $("popover").hidden = true;
  $("popover-body").textContent = "";
}

document.addEventListener("click", (event) => {
  if (!$("menu").hidden && !event.target.closest("#menu")) hideMenu();
  if (!$("popover").hidden && !event.target.closest("#popover")) hidePopover();
  if (!$("settings").hidden && !event.target.closest("#settings, #settings-button")) {
    $("settings").hidden = true;
  }
});


// ---- PDF ----------------------------------------------------------------

function onPdfScroll() {
  // いま画面の上端に来ているページを、位置として覚える。
  const box = $("pdf");
  const top = box.scrollTop;
  for (const img of pageParts(box)) {
    if (img.offsetTop + img.offsetHeight > top) {
      state.page = Number(img.dataset.page);
      break;
    }
  }
  markCurrentToc();
  rememberSoon();
}

/// ページの枠を並べる。中身は後から入る。
function buildPdf() {
  const box = $("pdf");
  const pages = visiblePages(state.book.pageCount);
  // 連続以外では見せるページが変わるたびに組み直す。何を出しているかを鍵にする。
  const key = `${state.book.id}/${state.settings.pageLayout}/${pages.join("-")}`;
  if (box.dataset.key === key) return;
  const fresh = box.dataset.book !== state.book.id;
  box.dataset.key = key;
  box.dataset.book = state.book.id;
  box.textContent = "";
  for (const i of pages) {
    const img = document.createElement("img");
    img.loading = "lazy";
    img.dataset.page = String(i);
    box.appendChild(img);
  }
  box.classList.toggle("spread", state.settings.pageLayout === "spread" && pages.length > 1);
  // 右開きでは見開きの左右が入れ替わる。
  box.classList.toggle("rtl", state.book.direction === "rtl");
  if (fresh) box.addEventListener("scroll", onPdfScroll, { passive: true });
  layoutPdf();
  renderPdf();
}

/// 固定レイアウト EPUB の紙面。
///
/// ページが絵 1 枚でできているならその絵を出す。
/// 文字が座標で置かれているページは、元の XHTML をそのまま埋める。
/// どちらかを見分けるのは core の仕事で、ここは並べるだけにする。
function buildFixed() {
  const box = $("pdf");
  const indices = visiblePages(state.book.pages.length);
  const key = `${state.book.id}/${state.settings.pageLayout}/${indices.join("-")}`;
  if (box.dataset.key === key) return;
  const fresh = box.dataset.book !== state.book.id;
  box.dataset.key = key;
  box.dataset.book = state.book.id;
  box.textContent = "";

  indices.map((i) => state.book.pages[i]).forEach((page, position) => {
    const index = indices[position];
    const url = bookUrl(page.href, index);
    let element;
    if (page.kind === "image") {
      element = document.createElement("img");
      element.loading = "lazy";
      element.src = url;
    } else {
      // 本文のあるページは書籍の script を動かさない。読書の窓と同じ扱いにする。
      element = document.createElement("iframe");
      element.setAttribute("sandbox", "allow-same-origin");
      element.loading = "lazy";
      // 紙面は遅れて入る。入った時点で、囲まれている当たりまで送る。
      element.addEventListener("load", (event) => approachMark(event.target.contentDocument));
      element.src = url;
    }
    element.dataset.page = String(index);
    box.appendChild(element);
  });

  box.classList.toggle("spread", state.settings.pageLayout === "spread" && indices.length > 1);
  box.classList.toggle("rtl", state.book.direction === "rtl");
  if (fresh) box.addEventListener("scroll", onPdfScroll, { passive: true });
  layoutPdf();
}

async function showFixed(page) {
  state.page = Math.max(0, Math.min(state.book.pages.length - 1, page));
  buildFixed();
  refreshMarkedPage();
  const box = $("pdf");
  const target = pageElement(box, state.page);
  if (target) box.scrollTop = isContinuous() ? target.offsetTop - 16 : 0;
  layoutMarks();
  markCurrentToc();
  markCurrentThumb();
  rememberSoon();
}

/// 倍率に合わせて枠の大きさだけを整える。
/// 画像を取り直すより桁違いに軽いので、拡大の手応えはここで出す。
/// 大きさを与えないと画像がすべて同じ位置に積まれ、loading="lazy" が効かない。
function layoutPdf() {
  const box = $("pdf");
  const [width, height] = state.pageSize || [0, 0];
  const parts = pageParts(box);
  if (width <= 0 || parts.length === 0) return;
  const anchor = box.scrollHeight > 0 ? box.scrollTop / box.scrollHeight : 0;
  const w = Math.round(width * state.zoom) + "px";
  const h = Math.round(height * state.zoom) + "px";
  for (const img of parts) {
    img.style.width = w;
    img.style.height = h;
  }
  box.scrollTop = anchor * box.scrollHeight;
  // 枠は紙面と同じ倍率で置いてあるので、大きさが変わったら置き直す。
  layoutMarks();
  updatePannable();
}

/// 実際に描き直す。拡大の途中で毎回呼ぶと追いつかないので、落ち着いてから動かす。
let renderTimer = null;
function renderPdf() {
  clearTimeout(renderTimer);
  renderTimer = setTimeout(() => {
    if (!state.book || state.book.format !== "pdf") return;
    const box = $("pdf");
    for (const img of pageParts(box)) {
      const url = `/pdf/${state.book.id}/${img.dataset.page}/${state.zoom}`;
      if (img.getAttribute("src") !== url) img.src = url;
    }
  }, 160);
}

async function showPdf(page) {
  state.page = Math.max(0, Math.min(state.book.pageCount - 1, page));
  buildPdf();
  const box = $("pdf");
  const target = pageElement(box, state.page);
  if (target) box.scrollTop = isContinuous() ? target.offsetTop - 16 : 0;
  layoutMarks();
  markCurrentToc();
  markCurrentThumb();
  rememberSoon();
}


// ---- 拡大と縮小 ---------------------------------------------------------

const ZOOM_MIN = 0.4;
const ZOOM_MAX = 6;


/// 合わせ方から倍率を決める。PDF でページの大きさが分かっているときだけ計算できる。
function zoomForFit(fit) {
  if (!state.pageSize) return null;
  const [width, height] = state.pageSize;
  const box = $("pdf").getBoundingClientRect();
  switch (fit) {
    case "width": return (box.width - 32) / width;
    case "page": return Math.min((box.width - 32) / width, (box.height - 32) / height);
    case "actual": return 1;
    default: return null;
  }
}

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
  const fit = nav.defaultFit;
  const value = nav.paged ? (zoomForFit("width") || 1) : 1;
  setZoom(value, fit);
  toast("拡大 " + Math.round(state.zoom * 100) + "%");
}

$("zoom-in").addEventListener("click", () => zoomBy(1.25));
$("zoom-out").addEventListener("click", () => zoomBy(1 / 1.25));
$("fit").addEventListener("change", (event) => {
  const fit = event.target.value;
  const value = zoomForFit(fit);
  setZoom(value == null ? state.zoom : value, fit);
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

/// 拡大して端がはみ出したら、掴んで動かせるようにする。
function updatePannable() {
  const box = $("pdf");
  box.classList.toggle("pannable", box.scrollWidth > box.clientWidth + 1);
}

let panning = null;
$("pdf").addEventListener("pointerdown", (event) => {
  const box = $("pdf");
  if (box.scrollWidth <= box.clientWidth + 1) return;
  panning = { x: event.clientX, y: event.clientY, left: box.scrollLeft, top: box.scrollTop };
  box.classList.add("panning");
  box.setPointerCapture(event.pointerId);
});
$("pdf").addEventListener("pointermove", (event) => {
  if (!panning) return;
  const box = $("pdf");
  box.scrollLeft = panning.left - (event.clientX - panning.x);
  box.scrollTop = panning.top - (event.clientY - panning.y);
});
for (const kind of ["pointerup", "pointercancel"]) {
  $("pdf").addEventListener(kind, () => {
    panning = null;
    $("pdf").classList.remove("panning");
  });
}


// ---- ページの一覧 -------------------------------------------------------
//
// 紙面の書籍では、目次より縮小した絵のほうが目当てのページを見つけやすい。
// 原寸で復号すると数百ページで潰れるので、小さく描いたものを遅延で取りに行く。

const THUMB_ZOOM = 0.22;

function renderThumbs() {
  const box = $("thumbs");
  if (!isPaged()) { box.textContent = ""; return; }
  const total = pageCountOf(state.book);
  if (box.dataset.book === state.book.id && box.children.length === total) {
    return markCurrentThumb();
  }
  box.dataset.book = state.book.id;
  box.textContent = "";

  for (let index = 0; index < total; index++) {
    const figure = document.createElement("figure");
    figure.dataset.page = String(index);

    const img = document.createElement("img");
    img.loading = "lazy";
    img.alt = "";
    if (isFixed()) {
      const page = state.book.pages[index];
      // 本文を持つページは絵にできない。枠だけ置いて番号で選ばせる。
      if (page.kind === "image") img.src = `/book/${state.book.id}/${encodePath(page.href)}`;
      else img.style.aspectRatio = String((state.pageSize || [800, 1130])[0] / (state.pageSize || [800, 1130])[1]);
    } else {
      img.src = `/pdf/${state.book.id}/${index}/${THUMB_ZOOM}`;
    }

    const caption = document.createElement("figcaption");
    caption.textContent = String(index + 1);

    figure.append(img, caption);
    figure.addEventListener("click", () => jump(() => showPage(index)));
    box.appendChild(figure);
  }
  markCurrentThumb();
}

function markCurrentThumb() {
  const box = $("thumbs");
  for (const figure of box.children) {
    const on = Number(figure.dataset.page) === state.page;
    figure.classList.toggle("current", on);
    if (on) figure.scrollIntoView({ block: "nearest" });
  }
}


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
  layoutMarks();
  // 本文に入っている印は配られたものだが、外すだけならこちらでできる。
  // 配り直すと画面がちらつくので、その場で包みを解く。
  for (const doc of shownDocuments()) clearMarksIn(doc);
}

/// 本文を配ってもらう経路。当たりを囲んでほしい章（ページ）には、語と通し番号を載せる。
function bookUrl(href, page = null) {
  const url = `/book/${state.book.id}/${encodePath(href)}`;
  const mark = state.mark;
  const wanted = mark && (isFixed() ? page === mark.page : mark.href === href);
  return url + markQuery(mark, wanted);
}

/// 目当てのページを配り直す。印の付き外れは配信時に決まるので、
/// すでに入っている紙面は、経路を変えて取り直さないと印が付かない。
function refreshMarkedPage() {
  if (!isFixed() || !state.mark || !state.book.pages[state.mark.page]) return;
  const part = pageElement($("pdf"), state.mark.page);
  if (!part || part.tagName !== "IFRAME") return;
  const url = bookUrl(state.book.pages[state.mark.page].href, state.mark.page);
  if (part.getAttribute("src") !== url) part.src = url;
}

/// 配られた本文に入っている印まで送る。押した直後の 1 回だけ。
function approachMark(doc) {
  const found = doc && doc.querySelector("mark.choro-found");
  if (!found || !takeApproach(state.mark)) return;
  found.scrollIntoView({ block: "center" });
}

/// いま画面に出ている本文の文書。固定レイアウトでは紙面ごとに分かれる。
function shownDocuments() {
  const docs = [];
  const frame = $("page");
  if (!frame.hidden && frame.contentDocument) docs.push(frame.contentDocument);
  for (const part of pageParts($("pdf"))) {
    if (part.tagName === "IFRAME" && part.contentDocument) docs.push(part.contentDocument);
  }
  return docs;
}

/// 印の包みを解く。入れる側は Rust だが、外すだけならタグを剥がせば済む。
function clearMarksIn(doc) {
  if (!doc || !doc.body) return;
  for (const mark of doc.querySelectorAll("mark.choro-found")) {
    const parent = mark.parentNode;
    while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
    parent.removeChild(mark);
    parent.normalize();
  }
}

/// 紙面の当たりを枠で囲む。絵の上に重ねるだけなので、描き直しとは関わらない。
function layoutMarks() {
  const box = $("pdf");
  for (const old of box.querySelectorAll(".found-frame")) old.remove();
  const mark = state.mark;
  if (!mark || mark.rects.length === 0) return;
  const target = pageElement(box, mark.page);
  if (!target) return;
  for (const [x0, y0, x1, y1] of mark.rects) {
    const frame = document.createElement("div");
    frame.className = "found-frame";
    frame.style.left = `${target.offsetLeft + x0 * state.zoom}px`;
    frame.style.top = `${target.offsetTop + y0 * state.zoom}px`;
    frame.style.width = `${Math.max(2, (x1 - x0) * state.zoom)}px`;
    frame.style.height = `${Math.max(2, (y1 - y0) * state.zoom)}px`;
    box.appendChild(frame);
  }
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

/// 画面の上端にある段落の書き出し。長すぎると当たらなくなるので短く取る。
function topText(doc) {
  try {
    const view = doc.defaultView;
    const element = doc.elementFromPoint(Math.floor(view.innerWidth / 2), 8);
    if (!element) return "";
    return (element.textContent || "").replace(/\s+/g, " ").trim().slice(0, 40);
  } catch (_) {
    return "";
  }
}

/// 覚えておいた場所へ戻す。飛び先、書き出し、割合の順に試す。
function restorePosition(doc, position) {
  if (position.fragment) {
    const target = doc.getElementById(position.fragment);
    if (target) { target.scrollIntoView(); return; }
  }
  if (position.text && scrollToText(doc, position.text)) return;
  const el = doc.scrollingElement || doc.documentElement;
  el.scrollTop = (position.progression || 0) * el.scrollHeight;
}

function scrollToText(doc, text) {
  const needle = text.trim().slice(0, 20);
  if (needle.length < 4) return false;
  const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    if (!walker.currentNode.nodeValue.includes(needle)) continue;
    const element = walker.currentNode.parentElement;
    if (!element) continue;
    element.scrollIntoView({ block: "start" });
    return true;
  }
  return false;
}

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
  const doc = $("page").contentDocument;
  if (doc && doc.body) applyStyle(doc);
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
// 厄介なのは最初の 1 冊で、ファイルダイアログ経由で開くことが多い。
// ダイアログが閉じてから窓が鍵盤の焦点を取り戻すまでには間があり、
// その途中で focus() を呼んでも、あとから来る復帰に打ち消される。
// そのため、窓が焦点を得たときにも当て直す。
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

window.addEventListener("focus", focusContent);


// ---- 操作 ---------------------------------------------------------------

// 矢印キーは移動、上下とスペースは読むための送り。軸ごとに意味を 1 つに定める。
function onKeyDown(event) {
  const editing = event.target && /input|textarea/i.test(event.target.tagName || "");
  trace(`key=${event.key} loading=${isLoading()} index=${state.index} `
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
    hidePopover();
    hideLightbox();
    return;
  }
  if (editing || command || !state.book) return;

  // 右開きの出版物では左右の意味を入れ替える。
  const back = state.book.direction === "rtl" ? "ArrowRight" : "ArrowLeft";
  const forward = state.book.direction === "rtl" ? "ArrowLeft" : "ArrowRight";
  if (event.key === back) { event.preventDefault(); return step(-1); }
  if (event.key === forward) { event.preventDefault(); return step(1); }

  // 縦の送り。焦点は親に置いてあるので、本文へはこちらから送る。
  if (event.target && event.target.ownerDocument !== document) return;
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
function jump(action) {
  if (state.book) {
    state.back.push(currentPosition());
    if (state.back.length > 100) state.back.shift();
    state.forward.length = 0;
  }
  action();
  updateHistoryButtons();
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
  trace(`step(${delta}) loading=${isLoading()} index=${state.index}`);
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
  if (name === "thumbs") renderThumbs();
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
  $("pdf").dataset.key = "";
  showPage(state.page);
});
$("lightbox").addEventListener("click", hideLightbox);
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
    if (!state.book || state.book.format !== "pdf") return;
    const fitted = zoomForFit(state.settings.fit);
    if (fitted != null) setZoom(fitted, state.settings.fit);
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

// 献立からの呼び出しと、動作確認の治具に渡す入口。
// 画面の中身をそのまま外へ出さず、必要なものだけを名前を付けて渡す。
window.choro = {
  kind: "reader",
  state,
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
  showFailure("献立を受け取れません", error);
}

main().catch((error) => showFailure("起動に失敗しました", error));

