// リフローする本文の窓。章を 1 つずつ iframe に入れる。
//
// 本文の iframe には allow-scripts を与えない。書籍の script を止めたうえで、
// 親から contentDocument を辿って手を入れる（spikes/findings-tauri.md）。
// 図版の拡大やリンクの抜粋も、この文書に紐づくのでここが持つ。
//
// 読書の窓（reader.js）とは `nav` の形で話す。あちらは形式を意識しない。
// 動いたことは departing / moved で知らせるだけで、履歴や読書位置には手を出さない。

import { $, invoke, showMenu, toast } from "../chrome.js";
import { chapterOfHref as chapterOfHrefIn } from "../lib/layout.js";
import { scrollToMark, unwrapMarks } from "../lib/mark.js";

/// 本文の振る舞いを作る。窓と分かち合うものは `shared` で受け取る。
export function reflowableReader(shared) {
  const { state, departing, moved, scrolled, bookUrl, focusContent, onKeyDown, onWheel } = shared;

  /// 行き先（章の番号）。目次や当たりは経路で言ってくる。
  const chapterOfHref = (href) => chapterOfHrefIn(state.book, href);

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
    focusContent();
    nav.applyZoom();

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
    scrollToMark(doc, state.mark);

    const queued = arriving.queuedSteps;
    arriving = null;
    moved();
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
    doc.addEventListener("scroll", scrolled, { passive: true });
    doc.defaultView.addEventListener("scroll", scrolled, { passive: true });
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
    button.addEventListener("click", () => { departing(); showChapter(state.index + 1); });
    footer.appendChild(button);
    doc.body.appendChild(footer);
  }



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
      if (index != null) { departing(); showChapter(index, fragment); }
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


  $("lightbox").addEventListener("click", hideLightbox);


  const nav = {
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
      departing();
      showChapter(index);
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
    /// 印を外す。本文は 1 つの文書なので、そこだけ見ればよい。
    clearMarks: () => unwrapMarks($("page").contentDocument),
    /// ページの一覧はリフローには無い。並べ方も窓の大きさも本文には効かない。
    showThumbs: () => {},
    relayout: () => {},
    refit: () => {},
    /// 倍率を戻したときの値。本文は等倍に戻す。
    defaultZoom: () => 1,
    /// 合わせ方から決まる倍率。本文には紙面のような「収める」寸法が無い。
    zoomFor: () => null,

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

    /// 印を外す。本文は 1 つの文書なので、そこだけ見ればよい。
    clearMarks: () => unwrapMarks($("page").contentDocument),
    /// 覆いを閉じる。図版の拡大とリンクの抜粋は、本文から開いたもの。
    dismissOverlays() {
      hidePopover();
      hideLightbox();
    },
    /// 表示設定が変わった。いま出ている本文へ当て直す。
    restyle() {
      const doc = $("page").contentDocument;
      if (doc && doc.body) applyStyle(doc);
    },
    /// 章の読み込みが飛んでいるか。様子を記録するときに使う。
    loading: () => isLoading(),

    /// ページの一覧はリフローには無い。並べ方も窓の大きさも本文には効かない。
    showThumbs: () => {},
    relayout: () => {},
    refit: () => {},
    /// 倍率を戻したときの値。本文は等倍に戻す。
    defaultZoom: () => 1,
    /// 合わせ方から決まる倍率。本文には紙面のような「収める」寸法が無い。
    zoomFor: () => null,
  };

  return nav;
}
