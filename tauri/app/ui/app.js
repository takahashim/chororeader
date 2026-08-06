// 画面側。本文そのものは sandbox 付きの iframe に入れ、この文書から DOM を触る。
//
// Tauri では WebView 全体でスクリプトを止めるわけにいかない（この画面が JavaScript なので）。
// 代わりに本文の iframe へ allow-scripts を与えないことで書籍の script を止め、
// 親から contentDocument を辿って手を入れる。成立条件は両者が同じ生成元であること。
// 詳しくは spikes/findings-tauri.md を見よ。

const invoke = window.__TAURI__.core.invoke;

// 不具合を追うときだけ記録する。TZR_DEBUG=1 を付けて起動すると有効になり、
// キーがどこへ届いたかが標準エラーに出る。常時は何もしない。
const PARAMS = new URLSearchParams(location.search);
const DEBUG = PARAMS.get("debug") === "1";
// この窓が書棚かどうか。書棚は本を配る側で、読書はしない。
const SHELF = PARAMS.get("shelf") === "1";
const trace = (message) => { if (DEBUG) invoke("ui_log", { message }).catch(() => {}); };
const $ = (id) => document.getElementById(id);

const DEFAULT_SETTINGS = {
  /// PDF で倍率を手で決めたときの値。
  zoom: 1,
  /// PDF の合わせ方。
  fit: "width",
  /// 本文（リフロー）の倍率。PDF とは別に覚える。
  epubZoom: 1,
  fontSizePercent: 100,
  lineHeight: 1.8,
  maxWidthEm: 42,
  theme: "light",
  bodyFont: "",
  codeFont: "SF Mono",
  codeWrap: false,
  publisherStyle: false,
  /// 書棚の見せ方。cover は表紙を並べ、table は表で並べる。
  shelfMode: "cover",
  /// 紙面の並べ方。連続スクロール、単ページ、見開き。
  pageLayout: "continuousScroll",
};

const state = {
  book: null,
  index: 0,
  page: 0,
  /// いまの倍率。EPUB では本文全体に、PDF では描画の倍率に効く。
  zoom: 1,
  /// PDF のページの大きさ（ポイント）。合わせ方の計算に要る。
  pageSize: null,
  settings: { ...DEFAULT_SETTINGS },
  shelfBooks: [],
  shelfSelected: -1,
  // 移動の履歴。読んだ順ではなく、飛んだ順を覚える。
  back: [],
  forward: [],
  style: { css: "", needsForegroundMarking: false },
  bookmarks: [],
  restoring: null,
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

/// 紙面として扱う書籍かどうか。PDF と固定レイアウト EPUB はページで数える。
/// 綴じ方向も拡大も送り方も、この 2 つでは同じに振る舞う。
const isPaged = () => !!state.book && (state.book.format === "pdf" || state.book.format === "fixedEPUB");
const isFixed = () => !!state.book && state.book.format === "fixedEPUB";

/// 紙面のページ番号へ移す。中身の作り方だけが形式で違う。
function showPage(page) {
  return isFixed() ? showFixed(page) : showPdf(page);
}

/// 見開きの組み方。表紙は単独で見せ、以降を 2 枚ずつまとめる。
/// core の fixed_layout::spreads と同じ規則にしてある。
function spreadOf(page, total) {
  if (page <= 0) return [0];
  const start = page % 2 === 1 ? page : page - 1;
  return start + 1 < total ? [start, start + 1] : [start];
}

/// いまの並べ方で画面に出すページ。
function visiblePages(total) {
  switch (state.settings.pageLayout) {
    case "singlePage": return [state.page];
    case "spread": return spreadOf(state.page, total);
    default: return Array.from({ length: total }, (_, i) => i);
  }
}

const isContinuous = () => state.settings.pageLayout === "continuousScroll";

/// 器の中から、そのページを担う要素を探す。連続以外では並びと番号がずれる。
function pageElement(box, page) {
  return Array.from(box.children).find((el) => Number(el.dataset.page) === page);
}

/// 固定レイアウトでは目次が章の経路を指す。ページ番号へ読み替える。
function pageOfHref(href) {
  if (!isFixed()) return Number(href);
  const index = state.book.pages.findIndex((p) => p.href === href);
  if (index >= 0) return index;
  // 絵に置き換えたページは href が絵の側になる。読み順の側でも探す。
  return Math.max(0, state.book.chapters.findIndex((c) => c.href === href));
}

function toast(message) {
  const box = $("toast");
  box.textContent = message;
  box.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { box.hidden = true; }, 1800);
}

// ---- 書籍を開く ---------------------------------------------------------

async function openPath(path, href, fragment) {
  try {
    state.book = await invoke("open_book", { path });
  } catch (error) {
    toast("開けませんでした: " + error);
    return;
  }

  document.title = state.book.title;
  $("book-title").textContent = state.book.title;
  // ページの一覧は紙面の書籍にしか意味がない。
  $("sidebar-tabs").querySelector('[data-pane="thumbs"]').hidden =
    !(state.book.format === "pdf" || state.book.format === "fixedEPUB");

  const saved = await invoke("book_state", { path });
  state.bookmarks = saved.bookmarks || [];
  renderBookmarks();
  renderToc();

  if (state.book.format === "fixedEPUB") {
    $("page").hidden = true;
    $("pdf").hidden = false;
    $("fit").hidden = false;
    $("layout").hidden = false;
    $("layout").value = state.settings.pageLayout;
    // 寸法は meta viewport から来る。名乗っていない書籍のために当てを置く。
    state.pageSize = state.book.pageSize || [800, 1130];
    const fitted = zoomForFit(state.settings.fit);
    setZoom(fitted == null ? state.settings.zoom || 1 : fitted, state.settings.fit);
    await showFixed(href ? Number(href) : saved.position.page || 0);
  } else if (state.book.format === "pdf") {
    $("page").hidden = true;
    $("pdf").hidden = false;
    $("fit").hidden = false;
    $("layout").hidden = false;
    $("layout").value = state.settings.pageLayout;
    // 合わせ方を計算するにはページの大きさが要る。1 ページ目で代表させる。
    state.pageSize = await invoke("page_size", { id: state.book.id, page: 0 }).catch(() => null);
    const fitted = zoomForFit(state.settings.fit);
    setZoom(fitted == null ? state.settings.zoom : fitted, state.settings.fit);
    await showPdf(href ? Number(href) : saved.position.page || 0);
  } else {
    $("pdf").hidden = true;
    $("page").hidden = false;
    $("fit").hidden = true;
    $("layout").hidden = true;
    state.pageSize = null;
    state.zoom = state.settings.epubZoom || 1;
    $("zoom-level").textContent = Math.round(state.zoom * 100) + "%";
    const target = href || saved.position.href;
    const index = Math.max(0, state.book.chapters.findIndex((c) => c.href === target));
    state.restoring = href ? null : saved.position;
    await showChapter(index, fragment || null);
  }

  if (state.book.format === "pdf" && !state.book.hasTextLayer) {
    // 入稿用にフォントをアウトライン化した PDF は、見た目が鮮明でも文字を持たない。
    // 検索が黙って 0 件になるより、開いた時点で伝えるほうがよい。
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
  const current = isPaged()
    ? (isFixed() ? (state.book.pages[state.page] || {}).href : String(state.page))
    : (state.book.chapters[state.index] || {}).href;
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
  if (isPaged()) return jump(() => showPage(pageOfHref(href)));
  const index = state.book.chapters.findIndex((c) => c.href === href);
  if (index >= 0) jump(() => showChapter(index, fragment || null));
}

// ---- 右クリックの献立 ---------------------------------------------------

/// 献立を出す。WebView 既定の献立は目次と検索結果では邪魔になるので抑える。
function showMenu(event, items) {
  const menu = $("menu");
  menu.textContent = "";
  for (const [label, action] of items) {
    const button = document.createElement("button");
    button.textContent = label;
    button.addEventListener("click", () => { hideMenu(); action(); });
    menu.appendChild(button);
  }
  menu.hidden = false;
  // 画面の外へはみ出さないところへ置く。
  const left = Math.min(event.clientX, window.innerWidth - menu.offsetWidth - 8);
  const top = Math.min(event.clientY, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, left) + "px";
  menu.style.top = Math.max(4, top) + "px";
}

function hideMenu() {
  $("menu").hidden = true;
}

// ---- 本文（EPUB） -------------------------------------------------------

// 読み込み中の状態。章の送りはここを見て振る舞いを変える。
let loadToken = 0;
let loading = false;
// 読み込み中に押された分を取っておく。取りこぼすと「進まないことがある」になる。
let pendingStep = 0;

async function showChapter(index, fragment) {
  const chapter = state.book.chapters[index];
  if (!chapter) return;
  const token = ++loadToken;
  state.index = index;
  loading = true;

  const frame = $("page");
  const url = `/book/${state.book.id}/${encodePath(chapter.href)}`;

  // 読み込みのあいだも、入れ替わる文書に手を付け続ける。
  // 空きを作ると、その隙に押されたキーがどこにも届かない。
  const stopWatching = watchDocument(frame);

  let doc;
  try {
    doc = await loadInto(frame, url);
  } catch (error) {
    stopWatching();
    loading = false;
    toast(String(error.message || error));
    return;
  }
  stopWatching();
  // 後から押された分に追い越されていたら、こちらの後始末はしない。
  if (token !== loadToken) return;

  decorate(doc);
  markCurrentToc();

  focusContent();
  applyZoom();

  if (fragment) {
    const target = doc.getElementById(fragment);
    if (target) target.scrollIntoView();
  } else if (state.restoring != null) {
    // 数字だけ渡されたときは割合として扱う（検索やしおりからの移動）。
    restorePosition(doc, typeof state.restoring === "number"
      ? { progression: state.restoring }
      : state.restoring);
    state.restoring = null;
  } else {
    (doc.scrollingElement || doc.documentElement).scrollTop = 0;
  }
  loading = false;
  rememberSoon();
  flushPendingStep();
}

/// 目当ての文書が入り終わるまで待つ。
///
/// iframe は生成直後に about:blank を持っており、それも readyState は 'complete' を返す。
/// ファイル名の部分一致で見分けると、名前が似た章どうしで取り違える。経路全体で照合する。
function loadInto(frame, url) {
  const expected = decodeURIComponent(new URL(url, location.href).pathname);
  frame.src = url;
  return waitUntil(() => {
    const doc = frame.contentDocument;
    if (!doc || doc.readyState !== "complete" || !doc.body) return null;
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

function flushPendingStep() {
  const delta = pendingStep;
  pendingStep = 0;
  if (delta !== 0) step(delta);
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
    if (img.dataset.tzrZoom) continue;
    img.dataset.tzrZoom = "1";
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
  let tag = doc.getElementById("tzr-style");
  if (!tag) {
    tag = doc.createElement("style");
    tag.id = "tzr-style";
    (doc.head || doc.documentElement).appendChild(tag);
  }
  tag.textContent = state.style.css;

  // 暗いテーマでだけ、背景色を持たない要素に文字色を当てる。
  // 一律に上書きすると、見出しの黒帯のように背景色を持つ要素から文字色を奪う。
  for (const el of doc.querySelectorAll(".tzr-fg")) el.classList.remove("tzr-fg");
  if (!state.style.needsForegroundMarking) return;
  const view = doc.defaultView;
  const walk = (el) => {
    const background = view.getComputedStyle(el).backgroundColor;
    const painted = background && background !== "transparent" && !background.startsWith("rgba(0, 0, 0, 0)");
    if (painted) return; // ここから内側は出版社の配色に任せる
    el.classList.add("tzr-fg");
    for (const child of el.children) walk(child);
  };
  if (doc.body) walk(doc.body);
}

function addCodeCopyButtons(doc) {
  for (const pre of doc.querySelectorAll("pre")) {
    if (pre.dataset.tzrCopy) continue;
    pre.dataset.tzrCopy = "1";
    pre.style.position = "relative";
    const button = doc.createElement("button");
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
  if (doc.getElementById("tzr-footer") || !doc.body) return;
  const next = state.book.chapters[state.index + 1];
  if (!next) return;
  const footer = doc.createElement("div");
  footer.id = "tzr-footer";
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
    const index = state.book.chapters.findIndex((c) => c.href === href);
    if (index >= 0) jump(() => showChapter(index, fragment));
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
  for (const img of box.children) {
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
    const url = `/book/${state.book.id}/${encodePath(page.href)}`;
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
  const box = $("pdf");
  const target = pageElement(box, state.page);
  if (target) box.scrollTop = isContinuous() ? target.offsetTop - 16 : 0;
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
  if (width <= 0 || box.children.length === 0) return;
  const anchor = box.scrollHeight > 0 ? box.scrollTop / box.scrollHeight : 0;
  const w = Math.round(width * state.zoom) + "px";
  const h = Math.round(height * state.zoom) + "px";
  for (const img of box.children) {
    img.style.width = w;
    img.style.height = h;
  }
  box.scrollTop = anchor * box.scrollHeight;
  updatePannable();
}

/// 実際に描き直す。拡大の途中で毎回呼ぶと追いつかないので、落ち着いてから動かす。
let renderTimer = null;
function renderPdf() {
  clearTimeout(renderTimer);
  renderTimer = setTimeout(() => {
    if (!state.book || state.book.format !== "pdf") return;
    const box = $("pdf");
    for (const img of box.children) {
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
  markCurrentToc();
  markCurrentThumb();
  rememberSoon();
}

// ---- 拡大と縮小 ---------------------------------------------------------

const ZOOM_MIN = 0.4;
const ZOOM_MAX = 6;

let saveTimer = null;
function saveSettingsSoon() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => invoke("save_settings", { settings: state.settings }), 400);
}

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
  if (isPaged()) {
    state.settings.zoom = state.zoom;
    if (fit) state.settings.fit = fit;
  } else {
    state.settings.epubZoom = state.zoom;
  }
  saveSettingsSoon();
  $("zoom-level").textContent = Math.round(state.zoom * 100) + "%";
  $("fit").value = state.settings.fit;
  applyZoom();
}

function applyZoom() {
  if (!state.book) return;
  if (isPaged()) {
    layoutPdf();
    if (!isFixed()) renderPdf();
    return;
  }
  // リフローする本文は、文字も図も一緒に拡大する。
  const doc = $("page").contentDocument;
  if (doc && doc.documentElement) doc.documentElement.style.zoom = state.zoom;
}

function zoomBy(step) {
  if (!state.book) return;
  // 倍率を手で変えたら、合わせ方は「保つ」へ移る。
  setZoom(state.zoom * step, "custom");
  toast("拡大 " + Math.round(state.zoom * 100) + "%");
}

function resetZoom() {
  if (!state.book) return;
  const fit = isPaged() ? "width" : "custom";
  const value = isPaged() ? (zoomForFit("width") || 1) : 1;
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
  const total = isFixed() ? state.book.pages.length : state.book.pageCount;
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
    const a = document.createElement("a");
    a.className = "hit" + (hit.isCode ? " code" : "");
    const where = document.createElement("span");
    where.className = "where";
    where.textContent = hit.title;
    const excerpt = document.createElement("span");
    excerpt.className = "excerpt";
    excerpt.textContent = hit.excerpt;
    a.append(where, excerpt);
    const openHit = (newWindow) => {
      if (newWindow) {
        return invoke("open_in_new_window", {
          path: state.book.path,
          href: isPaged() && !isFixed() ? String(hit.page) : hit.href,
          fragment: "",
        });
      }
      if (isFixed()) return jump(() => showPage(pageOfHref(hit.href)));
      if (isPaged()) return jump(() => showPage(hit.page));
      const index = state.book.chapters.findIndex((c) => c.href === hit.href);
      if (index >= 0) {
        jump(() => {
          state.restoring = hit.progression;
          showChapter(index);
        });
      }
    };
    a.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      showMenu(event, [
        ["新しいウィンドウで開く", () => openHit(true)],
        ["ここへ移動", () => openHit(false)],
      ]);
    });
    a.addEventListener("click", (event) => {
      if (event.metaKey || event.ctrlKey) {
        return openHit(true);
      }
      if (state.book.format === "pdf") return showPdf(hit.page);
      const index = state.book.chapters.findIndex((c) => c.href === hit.href);
      if (index >= 0) {
        state.restoring = hit.progression;
        showChapter(index);
      }
    });
    box.appendChild(a);
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

function currentPosition() {
  if (isPaged()) {
    return { href: "", progression: 0, page: state.page, fragment: "", text: "" };
  }
  const doc = $("page").contentDocument;
  const el = doc && (doc.scrollingElement || doc.documentElement);
  const progression = el && el.scrollHeight > 0 ? el.scrollTop / el.scrollHeight : 0;
  return {
    href: (state.book.chapters[state.index] || {}).href || "",
    progression,
    page: 0,
    fragment: "",
    // 割合だけだと、文字サイズや本文幅を変えたときに見失う。
    // いま画面の上端に来ている文字を覚えておき、次はそれを手掛かりに戻す。
    text: doc ? topText(doc) : "",
  };
}

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
  const label = isPaged()
    ? `p.${state.page + 1}`
    : (state.book.chapters[state.index] || {}).title || "";
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
      if (isPaged()) return jump(() => showPage(bookmark.page));
      const index = state.book.chapters.findIndex((c) => c.href === bookmark.href);
      if (index >= 0) {
        jump(() => {
          state.restoring = bookmark;
          showChapter(index);
        });
      }
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

// ---- 書棚 ---------------------------------------------------------------
//
// 読んでいる途中でも戻れるようにする。読み比べる道具なので、
// 「次はどれを開くか」を選ぶ場面は読書の最中にも来る。

async function showShelf() {
  const books = await invoke("library");
  $("shelf-empty").hidden = books.length > 0;
  renderShelf(books);
  applyShelfMode();
}

/// 表紙で並べる形と、表で並べる形の両方を作っておく。切り替えは見せ方だけ。
function renderShelf(books) {
  const grid = $("shelf-grid");
  const rows = $("shelf-table").tBodies[0];
  grid.textContent = "";
  rows.textContent = "";

  state.shelfBooks = books;
  state.shelfSelected = -1;
  books.forEach((book, index) => {
    grid.appendChild(coverCard(book));
    rows.appendChild(tableRow(book, index));
  });
}

function coverCard(book) {
  const card = document.createElement("div");
  card.className = "book" + (book.exists ? "" : " missing");
  card.title = book.path;

  const art = document.createElement("div");
  art.className = "art";
  art.appendChild(coverImage(book, () => art.replaceChildren(blankArt(book))) || blankArt(book));

  const name = document.createElement("div");
  name.className = "name";
  name.textContent = book.title;

  card.append(art, name);
  if (book.authors.length > 0) {
    const by = document.createElement("div");
    by.className = "by";
    by.textContent = book.authors.join("、");
    card.appendChild(by);
  }
  const kind = document.createElement("div");
  kind.className = "kind";
  kind.textContent = book.format === "pdf" ? "PDF" : "EPUB";
  card.appendChild(kind);

  // 表紙は的が大きく、押しボタンとして扱える。ここは押せば開く。
  if (book.exists) card.addEventListener("click", () => openBook(book));
  return card;
}

function tableRow(book, index) {
  const row = document.createElement("tr");
  row.dataset.index = String(index);
  if (!book.exists) row.className = "missing";
  row.title = book.path;

  const thumb = document.createElement("td");
  thumb.className = "thumb";
  const small = coverImage(book, () => thumb.textContent = "");
  if (small) thumb.appendChild(small);

  const cells = [book.title, book.authors.join("、"),
                 book.format === "pdf" ? "PDF" : "EPUB", book.progress];
  row.appendChild(thumb);
  for (const value of cells) {
    const cell = document.createElement("td");
    cell.textContent = value;
    row.appendChild(cell);
  }

  // 一覧は探すための画面なので、押しただけでは開かない。
  // 見比べているあいだに窓が増えるのは邪魔になる。Finder と Explorer の作法にも合う。
  if (book.exists) {
    row.addEventListener("click", () => selectRow(index));
    row.addEventListener("dblclick", () => openBook(book));
  }
  return row;
}

function coverImage(book, onError) {
  if (!book.cover) return null;
  const img = document.createElement("img");
  img.src = "/cover/" + encodeURIComponent(book.cover);
  img.alt = "";
  img.loading = "lazy";
  // 表紙が消えていたら、代わりの枠を出す。
  img.addEventListener("error", onError);
  return img;
}

/// 選んだ本は読書の窓に開く。書棚は残る。
/// どの窓に開くのかを決めておかないと、書棚を窓として分けた意味がなくなる。
function openBook(book) {
  if (!book.exists) return;
  invoke("open_in_new_window", { path: book.path, href: "", fragment: "" });
}

/// 一覧の行を選ぶ。冊数が増えると鍵盤で辿れることが効いてくる。
function selectRow(index) {
  const rows = $("shelf-table").tBodies[0].rows;
  if (rows.length === 0) return;
  state.shelfSelected = Math.max(0, Math.min(rows.length - 1, index));
  for (const row of rows) {
    row.classList.toggle("selected", Number(row.dataset.index) === state.shelfSelected);
  }
  rows[state.shelfSelected].scrollIntoView({ block: "nearest" });
}

/// 書棚の窓の鍵盤。読書の窓とは操作が別なので、入口で分ける。
function shelfKeys(event) {
  if (state.settings.shelfMode !== "table") return;
  if (event.key === "ArrowDown") { event.preventDefault(); return selectRow(state.shelfSelected + 1); }
  if (event.key === "ArrowUp") { event.preventDefault(); return selectRow(state.shelfSelected - 1); }
  if (event.key !== "Enter") return;
  event.preventDefault();
  const book = state.shelfBooks[state.shelfSelected];
  if (book) openBook(book);
}

function applyShelfMode() {
  const mode = state.settings.shelfMode === "table" ? "table" : "cover";
  $("shelf-grid").hidden = mode !== "cover";
  $("shelf-table").hidden = mode !== "table";
  for (const button of $("shelf-modes").children) {
    button.classList.toggle("on", button.dataset.mode === mode);
  }
}

function blankArt(book) {
  const blank = document.createElement("div");
  blank.className = "blank";
  blank.textContent = book.exists ? "表紙なし" : "見つかりません";
  return blank;
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
  trace(`key=${event.key} loading=${loading} pending=${pendingStep} index=${state.index} `
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
    $("search-input").focus();
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

/// 本文を送る。割合で渡されたときは 1 画面ぶんとして扱う。
function scrollContent(amount, byScreen) {
  if (isPaged()) {
    const box = $("pdf");
    box.scrollTop += byScreen ? amount * box.clientHeight : amount;
    return;
  }
  const doc = $("page").contentDocument;
  const el = doc && (doc.scrollingElement || doc.documentElement);
  if (!el) return;
  el.scrollTop += byScreen ? amount * doc.defaultView.innerHeight : amount;
}

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
function reveal(position) {
  if (isPaged()) return showPage(position.page);
  const index = state.book.chapters.findIndex((c) => c.href === position.href);
  if (index < 0) return;
  // 履歴から戻すときも、割合だけでなく書き出しを手掛かりにする。
  state.restoring = position;
  showChapter(index);
}

function updateHistoryButtons() {
  $("go-back").disabled = state.back.length === 0;
  $("go-forward").disabled = state.forward.length === 0;
}

function step(delta) {
  trace(`step(${delta}) loading=${loading} index=${state.index}`);
  // 紙面の送りも履歴に載せる。目次から飛んだあと元のページへ帰れるようにするため。
  //
  // 見開きでは 2 枚ずつ動く。並べ方が変わっても「次の単位へ」という意味は変えない。
  if (isPaged()) {
    const total = isFixed() ? state.book.pages.length : state.book.pageCount;
    if (state.settings.pageLayout === "spread") {
      const current = spreadOf(state.page, total);
      const next = delta > 0 ? current[current.length - 1] + 1 : current[0] - 1;
      return jump(() => showPage(next < 0 ? 0 : next));
    }
    return jump(() => showPage(state.page + delta));
  }
  // 読み込み中の分は取っておき、終わってからまとめて動かす。
  if (loading) { pendingStep += delta; return; }
  const index = state.index + delta;
  if (index < 0 || index >= state.book.chapters.length) return;
  jump(() => showChapter(index));
}

async function diagnose() {
  if (!state.book || state.book.format === "pdf") return;
  const report = await invoke("diagnose", { id: state.book.id });
  const lines = [
    `章 ${report.spineCount} / 目次 ${report.tocEntryCount}（深さ ${report.tocMaxDepth}）`,
    `CSS ${report.cssFileCount}（旧記法 ${report.legacyCSSFileCount}）`,
    `XHTML ${report.xhtmlCount}（不正 ${report.malformedXHTMLCount}）`,
    `画像 ${report.imageCount} / フォント ${report.fontCount}`,
    `欠落: リソース ${report.missingResources.length} / 目次 ${report.missingTOCTargets.length} / 章 ${report.missingSpineItems.length}`,
  ];
  // 目で見るだけでは書き写せない。押した時点で写しておく。
  const detail = [
    `書籍: ${state.book.title}`,
    ...lines,
    report.missingResources.length ? "欠落リソース:\n  " + report.missingResources.join("\n  ") : "",
    report.missingTOCTargets.length ? "欠落した目次の参照先:\n  " + report.missingTOCTargets.join("\n  ") : "",
    report.missingSpineItems.length ? "欠落した章:\n  " + report.missingSpineItems.join("\n  ") : "",
    report.cssChanges.length
      ? "CSS の変換:\n  " + report.cssChanges.map((c) => `${c.from} → ${c.to} (${c.count})`).join("\n  ")
      : "",
  ].filter(Boolean).join("\n");
  await navigator.clipboard.writeText(detail).catch(() => {});
  toast(lines.join("　") + "（診断を写しました）");
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

/// いま読んでいるところを、もう 1 つの窓で開く。
/// 同じ書籍でも構わない。離れた 2 か所を並べて見るための道具である。
function openHere() {
  if (!state.book) return;
  const href = isPaged()
    ? String(state.page)
    : (state.book.chapters[state.index] || {}).href || "";
  invoke("open_in_new_window", { path: state.book.path, href });
}

async function pick() {
  const path = await invoke("pick_book");
  // ダイアログが鍵盤の受け手を持ち去ったままのことがある。閉じた直後に戻す。
  invoke("focus_webview").catch(() => {});
  if (path) await openPath(path);
  focusContent();
}

$("open-button").addEventListener("click", pick);
$("shelf-open").addEventListener("click", pick);
$("shelf-modes").addEventListener("click", (event) => {
  const mode = event.target.dataset.mode;
  if (!mode) return;
  state.settings.shelfMode = mode;
  invoke("save_settings", { settings: state.settings });
  applyShelfMode();
});
$("new-window").addEventListener("click", openHere);
$("shelf-button").addEventListener("click", () => invoke("open_shelf"));
$("toggle-sidebar").addEventListener("click", toggleSidebar);
$("layout").addEventListener("change", (event) => {
  state.settings.pageLayout = event.target.value;
  saveSettingsSoon();
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
  const saved = await invoke("settings");
  state.settings = { ...DEFAULT_SETTINGS, ...(saved && typeof saved === "object" ? saved : {}) };
  fillSettings();
  bindSettings();
  await refreshStyle();

  // 書棚の窓は本を配るだけで、読書はしない。道具帯も本文も出さない。
  if (SHELF) {
    document.body.classList.add("shelf-window");
    document.title = "書棚";
    return showShelf();
  }

  $("shelf").hidden = true;
  const path = PARAMS.get("path");
  if (path) return openPath(path, PARAMS.get("href"), PARAMS.get("frag"));

  // 書籍を持たない読書の窓は作らない。ここへ来たら書棚へ回す。
  invoke("open_shelf");
}

main();
