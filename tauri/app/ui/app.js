// 画面側。本文そのものは sandbox 付きの iframe に入れ、この文書から DOM を触る。
//
// Tauri では WebView 全体でスクリプトを止めるわけにいかない（この画面が JavaScript なので）。
// 代わりに本文の iframe へ allow-scripts を与えないことで書籍の script を止め、
// 親から contentDocument を辿って手を入れる。成立条件は両者が同じ生成元であること。
// 詳しくは spikes/findings-tauri.md を見よ。

const invoke = window.__TAURI__.core.invoke;
const $ = (id) => document.getElementById(id);

const DEFAULT_SETTINGS = {
  fontSizePercent: 100,
  lineHeight: 1.8,
  maxWidthEm: 42,
  theme: "light",
  bodyFont: "",
  codeFont: "SF Mono",
  codeWrap: false,
  publisherStyle: false,
};

const state = {
  book: null,
  index: 0,
  page: 0,
  zoom: 1.25,
  settings: { ...DEFAULT_SETTINGS },
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

function toast(message) {
  const box = $("toast");
  box.textContent = message;
  box.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { box.hidden = true; }, 1800);
}

// ---- 書籍を開く ---------------------------------------------------------

async function openPath(path, href) {
  try {
    state.book = await invoke("open_book", { path });
  } catch (error) {
    toast("開けませんでした: " + error);
    return;
  }

  document.title = state.book.title;
  $("book-title").textContent = state.book.title;
  $("welcome").hidden = true;

  const saved = await invoke("book_state", { path });
  state.bookmarks = saved.bookmarks || [];
  renderBookmarks();
  renderToc();

  if (state.book.format === "pdf") {
    $("page").hidden = true;
    $("pdf").hidden = false;
    await showPdf(href ? Number(href) : saved.position.page || 0);
  } else {
    $("pdf").hidden = true;
    $("page").hidden = false;
    const target = href || saved.position.href;
    const index = Math.max(0, state.book.chapters.findIndex((c) => c.href === target));
    state.restoring = href ? null : saved.position.progression;
    await showChapter(index);
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
  const current = state.book.format === "pdf"
    ? String(state.page)
    : (state.book.chapters[state.index] || {}).href;
  for (const a of $("toc").children) {
    a.classList.toggle("current", a.dataset.href === current);
  }
}

$("toc").addEventListener("click", (event) => {
  const a = event.target.closest("a");
  if (!a || !a.dataset.href) return;
  if (state.book.format === "pdf") return showPdf(Number(a.dataset.href));
  const index = state.book.chapters.findIndex((c) => c.href === a.dataset.href);
  if (index >= 0) showChapter(index, a.dataset.fragment || null);
});

// ---- 本文（EPUB） -------------------------------------------------------

async function showChapter(index, fragment) {
  const chapter = state.book.chapters[index];
  if (!chapter) return;
  state.index = index;

  const frame = $("page");
  const url = `/book/${state.book.id}/${encodePath(chapter.href)}`;
  frame.src = url;

  let doc;
  try {
    doc = await waitUntil(() => {
      const d = frame.contentDocument;
      return d && d.readyState === "complete" && d.body && d.location.href.includes(encodePath(chapter.href).split("/").pop())
        ? d : null;
    }, "本文");
  } catch (error) {
    toast(String(error.message || error));
    return;
  }

  decorate(doc);
  markCurrentToc();

  if (fragment) {
    const target = doc.getElementById(fragment);
    if (target) target.scrollIntoView();
  } else if (state.restoring != null) {
    const el = doc.scrollingElement || doc.documentElement;
    el.scrollTop = state.restoring * el.scrollHeight;
    state.restoring = null;
  } else {
    (doc.scrollingElement || doc.documentElement).scrollTop = 0;
  }
  rememberSoon();
}

/// 本文の文書に手を入れる。注入ではなく、親から直接触る。
function decorate(doc) {
  applyStyle(doc);
  addCodeCopyButtons(doc);
  addChapterFooter(doc);

  doc.addEventListener("click", onBodyClick, true);
  doc.addEventListener("keydown", onKeyDown);
  doc.addEventListener("scroll", rememberSoon, { passive: true });
  doc.defaultView.addEventListener("scroll", rememberSoon, { passive: true });
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
  button.addEventListener("click", () => showChapter(state.index + 1));
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
    if (index >= 0) showChapter(index, fragment);
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
}

function hidePopover() {
  $("popover").hidden = true;
  $("popover-body").textContent = "";
}

document.addEventListener("click", (event) => {
  if (!$("popover").hidden && !event.target.closest("#popover")) hidePopover();
  if (!$("settings").hidden && !event.target.closest("#settings, #settings-button")) {
    $("settings").hidden = true;
  }
});

// ---- PDF ----------------------------------------------------------------

async function showPdf(page) {
  state.page = Math.max(0, Math.min(state.book.pageCount - 1, page));
  const box = $("pdf");
  if (box.dataset.book !== state.book.id || box.dataset.zoom !== String(state.zoom)) {
    box.dataset.book = state.book.id;
    box.dataset.zoom = String(state.zoom);
    box.textContent = "";
    for (let i = 0; i < state.book.pageCount; i++) {
      const img = document.createElement("img");
      img.loading = "lazy";
      img.dataset.page = String(i);
      img.src = `/pdf/${state.book.id}/${i}/${state.zoom}`;
      box.appendChild(img);
    }
    box.addEventListener("scroll", () => {
      // いま画面の上端に来ているページを、位置として覚える。
      const top = box.scrollTop;
      for (const img of box.children) {
        if (img.offsetTop + img.offsetHeight > top) {
          state.page = Number(img.dataset.page);
          break;
        }
      }
      markCurrentToc();
      rememberSoon();
    }, { passive: true });
  }
  const target = box.children[state.page];
  if (target) box.scrollTop = target.offsetTop - 16;
  markCurrentToc();
  rememberSoon();
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
    a.addEventListener("click", (event) => {
      if (event.metaKey || event.ctrlKey) {
        return invoke("open_in_new_window", { path: state.book.path, href: hit.href });
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
  if (state.book.format === "pdf") {
    return { href: "", progression: 0, page: state.page };
  }
  const doc = $("page").contentDocument;
  const el = doc && (doc.scrollingElement || doc.documentElement);
  const progression = el && el.scrollHeight > 0 ? el.scrollTop / el.scrollHeight : 0;
  return { href: (state.book.chapters[state.index] || {}).href || "", progression, page: 0 };
}

async function toggleBookmark() {
  if (!state.book) return;
  const position = currentPosition();
  const label = state.book.format === "pdf"
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
      if (state.book.format === "pdf") return showPdf(bookmark.page);
      const index = state.book.chapters.findIndex((c) => c.href === bookmark.href);
      if (index >= 0) {
        state.restoring = bookmark.progression;
        showChapter(index);
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

function bindSettings() {
  const fields = ["fontSizePercent", "lineHeight", "maxWidthEm", "theme", "codeWrap", "publisherStyle"];
  for (const name of fields) {
    const input = $(name);
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
  for (const [name, value] of Object.entries(state.settings)) {
    const input = $(name);
    if (!input) continue;
    if (input.type === "checkbox") input.checked = Boolean(value);
    else input.value = value;
    const label = input.parentElement.querySelector("span");
    if (label) label.textContent = input.value;
  }
}

// ---- 操作 ---------------------------------------------------------------

// 矢印キーは移動、上下とスペースは読むための送り。軸ごとに意味を 1 つに定める。
function onKeyDown(event) {
  const editing = event.target && /input|textarea/i.test(event.target.tagName || "");
  const command = event.metaKey || event.ctrlKey;

  if (command && event.key.toLowerCase() === "o") { event.preventDefault(); return pick(); }
  if (command && event.key === "\\") { event.preventDefault(); return toggleSidebar(); }
  if (command && event.key.toLowerCase() === "d") { event.preventDefault(); return toggleBookmark(); }
  if (command && event.key.toLowerCase() === "f") {
    event.preventDefault();
    $("search-input").focus();
    return;
  }
  if (command && event.altKey && event.key.toLowerCase() === "i") { event.preventDefault(); return diagnose(); }
  if (command && (event.key === "+" || event.key === "=")) { event.preventDefault(); return zoom(0.25); }
  if (command && event.key === "-") { event.preventDefault(); return zoom(-0.25); }
  if (event.key === "Escape") { hidePopover(); return; }
  if (editing || command || !state.book) return;

  // 右開きの出版物では左右の意味を入れ替える。
  const back = state.book.direction === "rtl" ? "ArrowRight" : "ArrowLeft";
  const forward = state.book.direction === "rtl" ? "ArrowLeft" : "ArrowRight";
  if (event.key === back) { event.preventDefault(); return step(-1); }
  if (event.key === forward) { event.preventDefault(); return step(1); }
}

function step(delta) {
  if (state.book.format === "pdf") return showPdf(state.page + delta);
  const index = state.index + delta;
  if (index < 0 || index >= state.book.chapters.length) return;
  showChapter(index);
}

function zoom(delta) {
  if (!state.book || state.book.format !== "pdf") return;
  state.zoom = Math.max(0.5, Math.min(4, Math.round((state.zoom + delta) * 100) / 100));
  showPdf(state.page);
  toast("拡大 " + Math.round(state.zoom * 100) + "%");
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
  toast(lines.join("　"));
  console.log(report);
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
  for (const id of ["toc", "results", "bookmarks"]) $(id).hidden = id !== name;
  $("sidebar").hidden = false;
}

$("sidebar-tabs").addEventListener("click", (event) => {
  if (event.target.dataset.pane) showPane(event.target.dataset.pane);
});

async function pick() {
  const path = await invoke("pick_book");
  if (path) openPath(path);
}

$("open-button").addEventListener("click", pick);
$("welcome-open").addEventListener("click", pick);
$("toggle-sidebar").addEventListener("click", toggleSidebar);
$("bookmark").addEventListener("click", toggleBookmark);
$("settings-button").addEventListener("click", (event) => {
  event.stopPropagation();
  $("settings").hidden = !$("settings").hidden;
});
document.addEventListener("keydown", onKeyDown);

// ---- 起動 ---------------------------------------------------------------

async function main() {
  const saved = await invoke("settings");
  state.settings = { ...DEFAULT_SETTINGS, ...(saved && typeof saved === "object" ? saved : {}) };
  fillSettings();
  bindSettings();
  await refreshStyle();

  const parameters = new URLSearchParams(location.search);
  const path = parameters.get("path");
  if (path) return openPath(path, parameters.get("href"));

  const recent = await invoke("recent_books");
  const box = $("recent");
  for (const book of recent) {
    const a = document.createElement("a");
    a.textContent = book.name;
    a.title = book.path;
    if (!book.exists) a.className = "missing";
    else a.addEventListener("click", () => openPath(book.path));
    box.appendChild(a);
  }
}

main();
