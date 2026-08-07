// 書棚の窓。本を配る側で、読書はしない。
//
// 選んだ本は読書の窓（index.html）に開き、この窓は残る。
// どの窓に開くのかを決めておかないと、書棚を窓として分けた意味がなくなる。

import {
  $, invoke, listenToMenu, loadSettings, saveSettings, applyTheme,
  ensureBackend, hideMenu, showFailure, showMenu, watchForFailures,
} from "./chrome.js";
import { hitCountLabel, libraryProgress as progressLabel } from "./lib/format.js";
import { hitRow } from "./lib/hit-row.js";

const state = {
  settings: {},
  books: [],
  /// 一覧で選んでいる行。冊数が増えると鍵盤で辿れることが効いてくる。
  selected: -1,
};


async function showShelf() {
  const books = await invoke("library");
  renderShelf(books);
  applyShelfView();
  // 引かれる前に索引をほどいておく。最初の検索を待たせないため。
  invoke("warm_indexes").catch(() => {});
}

/// 表紙で並べる形と、表で並べる形の両方を作っておく。切り替えは見せ方だけ。
function renderShelf(books) {
  const grid = $("shelf-grid");
  const rows = $("shelf-table").tBodies[0];
  grid.textContent = "";
  rows.textContent = "";

  state.books = books;
  state.selected = -1;
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
  state.selected = Math.max(0, Math.min(rows.length - 1, index));
  for (const row of rows) {
    row.classList.toggle("selected", Number(row.dataset.index) === state.selected);
  }
  rows[state.selected].scrollIntoView({ block: "nearest" });
}

/// 書棚の窓の鍵盤。読書の窓とは操作が別なので、入口で分ける。
function shelfKeys(event) {
  if (state.settings.shelfMode !== "table") return;
  if (event.key === "ArrowDown") { event.preventDefault(); return selectRow(state.selected + 1); }
  if (event.key === "ArrowUp") { event.preventDefault(); return selectRow(state.selected - 1); }
  if (event.key !== "Enter") return;
  event.preventDefault();
  const book = state.books[state.selected];
  if (book) openBook(book);
}

/// 書棚の見せ方を当てる。引いているあいだは、蔵書の代わりに当たりを出す。
function applyShelfView() {
  const searching = librarySearch.query.length > 0;
  const mode = state.settings.shelfMode === "table" ? "table" : "cover";
  $("shelf-grid").hidden = searching || mode !== "cover";
  $("shelf-table").hidden = searching || mode !== "table";
  $("shelf-results").hidden = !searching;
  $("shelf-empty").hidden = searching || state.books.length > 0;
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


// ---- 蔵書を横断して引く -------------------------------------------------
//
// 絞り込みは Rust 側の仕事で、こちらは引き金を引き、届いたものを並べるだけにする。
// 蔵書が増えるほど全部を引き終わるまでが長くなるので、待たせずに 1 冊ずつ受け取る。

const librarySearch = {
  /// この走査の名札。引き直すたびに増やし、古い走査からの便りは捨てる。
  run: 0,
  query: "",
  books: [],
  searched: 0,
  total: 0,
  building: null,
  running: false,
};

/// 蔵書を丸ごと引くのは重い。1 文字ごとには走らせず、確定してから走らせる。
$("shelf-search").addEventListener("keydown", (event) => {
  if (event.key === "Enter") { event.preventDefault(); return runLibrarySearch(); }
  if (event.key === "Escape") { event.preventDefault(); return clearLibrarySearch(); }
});

function runLibrarySearch() {
  const query = $("shelf-search").value.trim();
  if (query.length === 0) return clearLibrarySearch();

  librarySearch.run += 1;
  librarySearch.query = query;
  librarySearch.books = [];
  librarySearch.searched = 0;
  librarySearch.total = 0;
  librarySearch.building = null;
  librarySearch.running = true;

  $("shelf-results").textContent = "";
  applyShelfView();
  $("shelf-progress").textContent = progressLabel(librarySearch);
  invoke("search_library", { query, run: librarySearch.run });
}

function clearLibrarySearch() {
  invoke("stop_library_search");
  // 名札を変えておく。走査が降りるまでのあいだに届く便りを、拾わないようにする。
  librarySearch.run += 1;
  $("shelf-search").value = "";
  librarySearch.query = "";
  librarySearch.books = [];
  librarySearch.building = null;
  librarySearch.running = false;
  $("shelf-results").textContent = "";
  $("shelf-progress").textContent = "";
  applyShelfView();
}

/// 1 冊ぶん終わるたびに届く。名札の違う便りは、引き直す前のものなので捨てる。
function onLibrarySearch(event) {
  const found = event.payload;
  if (!found || found.run !== librarySearch.run) return;

  librarySearch.searched = found.searched;
  librarySearch.total = found.total;
  librarySearch.building = found.building;
  if (found.done) {
    librarySearch.running = false;
    librarySearch.building = null;
  }
  if (found.book) {
    librarySearch.books.push(found.book);
    $("shelf-results").appendChild(foundBook(found.book));
  }
  // 引き終わって 1 件も無ければ、そう言う。途中では言わない。
  if (found.done && librarySearch.books.length === 0) {
    const nothing = document.createElement("p");
    nothing.className = "nothing";
    nothing.textContent = `「${librarySearch.query}」は見つかりませんでした`;
    $("shelf-results").appendChild(nothing);
  }
  $("shelf-progress").textContent = progressLabel(librarySearch);
}

function foundBook(book) {
  const section = document.createElement("section");
  section.className = "found";

  const head = document.createElement("div");
  head.className = "found-head";
  const title = document.createElement("span");
  title.className = "title";
  title.textContent = book.title;
  const count = document.createElement("span");
  count.className = "count";
  count.textContent = hitCountLabel(book);
  head.append(title, count);
  section.appendChild(head);

  for (const hit of book.hits) section.appendChild(foundHit(book, hit));

  // 打ち切った本は、その本を開いて全件を見る道を出す。
  if (book.truncated) {
    const all = document.createElement("button");
    all.className = "found-all";
    all.textContent = "この本の中をすべて見る";
    all.addEventListener("click", () => openAll(book));
    section.appendChild(all);
  }
  return section;
}

function foundHit(book, hit) {
  // 書棚は本を配る側なので、当たりも読書の窓に開く。書棚はそのまま残る。
  const open = () => invoke("open_in_new_window", {
    path: book.path,
    href: hit.href || String(hit.page),
    fragment: "",
    query: librarySearch.query,
    nth: hit.nth,
  });
  return hitRow(hit, {
    open,
    title: book.path,
    menu: (event) => showMenu(event, [
      ["新しいウィンドウで開く", open],
      ["この本の中をすべて見る", () => openAll(book)],
    ]),
  });
}

/// その本を開き、同じ語句で引いた一覧を出す。件数の上限は書籍内検索のものに上がる。
function openAll(book) {
  invoke("open_in_new_window", {
    path: book.path,
    href: "",
    fragment: "",
    query: librarySearch.query,
    list: true,
  });
}

/// 引くための欄へ焦点を移す。書棚では蔵書を横断して引き、読書の窓ではその書籍を引く。
function focusSearch() {
  $("shelf-search").focus();
}



// ---- 操作 ---------------------------------------------------------------

/// 書籍を選ぶ。選んだ本は読書の窓に開く。書棚はここで本を配るだけで、読書はしない。
async function pick() {
  const path = await invoke("pick_book");
  // ダイアログが鍵盤の受け手を持ち去ったままのことがある。閉じた直後に戻す。
  invoke("focus_webview").catch(() => {});
  if (path) invoke("open_in_new_window", { path, href: "", fragment: "" });
}

$("shelf-open").addEventListener("click", pick);
$("shelf-samples").addEventListener("click", (event) => {
  const kind = event.target.dataset.kind;
  if (kind) invoke("open_sample", { kind });
});
$("shelf-modes").addEventListener("click", (event) => {
  const mode = event.target.dataset.mode;
  if (!mode) return;
  state.settings.shelfMode = mode;
  saveSettings(state.settings);
  applyShelfView();
});
$("shelf-search").addEventListener("keydown", (event) => {
  if (event.key === "Enter") { event.preventDefault(); return runLibrarySearch(); }
  if (event.key === "Escape") { event.preventDefault(); return clearLibrarySearch(); }
});

document.addEventListener("keydown", (event) => {
  const command = event.metaKey || event.ctrlKey;
  if (command && event.key.toLowerCase() === "o") { event.preventDefault(); return pick(); }
  if (command && event.key.toLowerCase() === "f") { event.preventDefault(); return focusSearch(); }
  if (event.key === "Escape") return hideMenu();
  // 欄に文字を入れている間は、一覧の送りに矢印を奪わせない。
  if (event.target && /input|textarea/i.test(event.target.tagName || "")) return;
  shelfKeys(event);
});

// ---- 起動 ---------------------------------------------------------------

// 献立からの呼び出しと、動作確認の治具に渡す入口。
// 画面の中身をそのまま外へ出さず、必要なものだけを名前を付けて渡す。
window.choro = {
  kind: "shelf",
  state,
  librarySearch,
  hideMenu,
  pick,
  runLibrarySearch,
  clearLibrarySearch,
};

watchForFailures();

// 受け取りの登録で転んでも、残りの組み立てを道連れにしない。
// ここが例外を投げると、この後ろの main() が動かず窓が黙って死ぬ。
try {
  const events = listenToMenu({
    open: pick,
    shelf: () => {},
    find: focusSearch,
    "sample-reflowable": () => invoke("open_sample", { kind: "reflowable" }),
    "sample-fixed": () => invoke("open_sample", { kind: "fixed" }),
    "sample-pdf": () => invoke("open_sample", { kind: "pdf" }),
    selftest: () => window.choroSelfTest && window.choroSelfTest(),
  });
  // 横断検索は 1 冊ぶん終わるたびに届く。聞くのはこの窓だけでよい。
  events.listen("library-search", onLibrarySearch).catch(() => {});
} catch (error) {
  showFailure("献立を受け取れません", error);
}

async function main() {
  await ensureBackend();
  state.settings = await loadSettings();
  applyTheme(state.settings);
  document.title = "書棚";
  await showShelf();
}

main().catch((error) => showFailure("起動に失敗しました", error));
