// 読書の窓と書棚の窓が、どちらも使う道具。
//
// 窓ごとに文書を分けてあるので（index.html と shelf.html）、
// 片方にしか無い要素をここから触らない。触るのは両方に置いてあるものだけにする。

export const invoke = window.__TAURI__.core.invoke;

export const PARAMS = new URLSearchParams(location.search);

// 不具合を追うときだけ記録する。CHORO_DEBUG=1 を付けて起動すると有効になり、
// キーがどこへ届いたかが標準エラーに出る。常時は何もしない。
export const DEBUG = PARAMS.get("debug") === "1";
export const trace = (message) => { if (DEBUG) invoke("ui_log", { message }).catch(() => {}); };

export const $ = (id) => document.getElementById(id);

export const DEFAULT_SETTINGS = {
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

/// 覚えてある設定。欠けている項目は既定値で補う。
export async function loadSettings() {
  const saved = await invoke("settings");
  return { ...DEFAULT_SETTINGS, ...(saved && typeof saved === "object" ? saved : {}) };
}

export function saveSettings(settings) {
  invoke("save_settings", { settings });
}

let saveTimer = null;
export function saveSettingsSoon(settings) {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => saveSettings(settings), 400);
}

/// 明暗のテーマ。本文の見た目は core が作る CSS に任せ、ここは器の側だけ当てる。
export function applyTheme(settings) {
  document.body.classList.toggle("dark", settings.theme === "dark");
}

export function toast(message) {
  const box = $("toast");
  if (!box) return;
  box.textContent = message;
  box.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { box.hidden = true; }, 1800);
}

/// 献立を出す。WebView 既定の献立は目次や当たりの上では邪魔になるので抑える。
export function showMenu(event, items) {
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

export function hideMenu() {
  $("menu").hidden = true;
}

/// 献立の受け取り。効く項目は窓によって違うので、割り当ては呼ぶ側が渡す。
///
/// ここが例外を投げると窓の組み立てが道連れになるので、呼ぶ側で囲って使う。
export function listenToMenu(actions) {
  const events = window.__TAURI__ && window.__TAURI__.event;
  if (!events || typeof events.listen !== "function") {
    throw new Error("window.__TAURI__.event が無い");
  }
  events.listen("menu", (event) => {
    // 治具が「献立の道が通っているか」を見るための印。
    window.choroLastMenu = event.payload;
    const action = actions[event.payload];
    if (action) action();
  }).catch((error) => showFailure("献立を受け取れません", error));
  return events;
}

// 画面が黙って死ぬのを防ぐ。
//
// 何かの拍子に土台へ届かなくなると、窓は出るのに何を押しても反応しない状態になる。
// 手元と違う OS では原因が見えないので、起きたことをその場に書き出す。
// 目で見るだけでは書き写せない（診断と同じ）。溜めておいて、押されたら全部を写す。
const failures = [];

export function showFailure(what, error) {
  const detail = String((error && (error.stack || error.message)) || error || "");
  failures.push(`${what}\n${detail}`);
  failureBox().textContent = failures.join("\n\n");
}

/// 起きたことを書き出す枠。溜めた文だけを持ち、写す釦は外に出しておく。
function failureBox() {
  const found = document.getElementById("boot-failure-text");
  if (found) return found;

  const box = document.createElement("div");
  box.id = "boot-failure";
  box.setAttribute("style",
    "position:fixed;left:0;right:0;top:0;z-index:99;padding:10px 14px;" +
    "background:#7a1c1c;color:#fff;font:12px/1.6 ui-monospace,Menlo,monospace;" +
    "max-height:50vh;overflow:auto;user-select:text;-webkit-user-select:text");

  const written = document.createElement("div");
  written.id = "boot-failure-text";
  written.setAttribute("style", "white-space:pre-wrap");

  const copy = document.createElement("button");
  copy.textContent = "コピー";
  copy.setAttribute("style",
    "float:right;font:inherit;padding:2px 10px;border-radius:5px;cursor:pointer;" +
    "border:1px solid #fff6;background:#0003;color:#fff");
  copy.addEventListener("click", () => {
    navigator.clipboard.writeText(failures.join("\n\n")).then(
      () => { copy.textContent = "コピーしました"; },
      // 写せない設定のこともある。せめて選んでおけば、あとは手で写せる。
      () => { selectAll(written); copy.textContent = "選びました"; });
  });

  box.appendChild(copy);
  box.appendChild(written);
  document.body.appendChild(box);
  return written;
}

function selectAll(element) {
  const range = document.createRange();
  range.selectNodeContents(element);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

/// 出来事の取りこぼしを画面へ出す。窓の種類によらず同じ扱いにする。
export function watchForFailures() {
  window.addEventListener("error", (event) => showFailure("画面で例外が起きました", event.error || event.message));
  window.addEventListener("unhandledrejection", (event) => showFailure("応答が返りませんでした", event.reason));
}

/// 土台と話せることを確かめる。ここで落ちれば、あとは何を押しても動かない。
export async function ensureBackend() {
  try {
    await invoke("settings");
  } catch (error) {
    showFailure("土台に届きません（命令が拒まれました）", error);
    throw error;
  }
}
