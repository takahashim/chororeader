// 本文の中で動く出先。書籍の文書に入る唯一の script である。
//
// 本文の枠は sandbox="allow-scripts" で、allow-same-origin を与えていない。
// その文書は生成元を持たないので、窓（親）からは DOM に一切触れない。
// 触る仕事はすべてここが引き受け、窓とは決めた言葉だけでやり取りする。
//
// 書籍が持つ script は配信時の CSP（script-src 'nonce-…'）で止まる。
// nonce を持って配られるのはこの 1 本だけなので、走るのもこれに限られる。
//
// **モジュールにはできない。** module の取得は CORS を伴うので、
// 生成元を持たない文書からは読めない。素の script として書く。
//
// 話す言葉は spec.md「本文の出先と窓の言葉」に一覧がある。
// 窓の側の相手は readers/reflowable.js と readers/paged.js。

(function () {
  "use strict";

  /// 窓へ知らせる。相手を名指しできない（生成元が無い）ので "*" で投げる。
  /// 窓の側は event.source が本文の枠かどうかで見分ける。
  function tell(message) {
    parent.postMessage(message, "*");
  }

  // ---- 窓からの言いつけ -----------------------------------------------------

  window.addEventListener("message", (event) => {
    // 言いつけは窓からしか来ない。他所から届いたものは聞かない。
    if (event.source !== parent) return;
    const said = event.data;
    if (!said || typeof said.choro !== "string") return;
    try {
      obey(said);
    } catch (error) {
      tell({ choro: "stumbled", what: said.choro, why: String((error && error.message) || error) });
    }
  });

  function obey(said) {
    switch (said.choro) {
      case "style": return applyStyle(said.css, said.foreground);
      case "dress": return dress(said.next);
      case "go": return go(said.to);
      case "top": scroller().scrollTop = 0; return;
      case "by": return scrollBy(said.amount, said.byScreen);
      case "zoom": return applyZoom(said.zoom);
      case "approach": return approach();
      case "unmark": return unmark();
      case "report": return report();
      case "press": return press(said.key);
    }
  }

  /// 本文の中でキーを押してみせる。
  ///
  /// 窓から本文の DOM に触れないので、鍵盤の経路を外から通すことができない。
  /// 押してみるまで分からない、という状態を残さないための言いつけである
  /// （Rust 側の ping_menu と同じ位置づけ）。
  function press(key) {
    document.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true }));
  }

  /// 中の様子を伝える。窓からは DOM に触れないので、確かめる口はこれだけになる。
  /// 動作確認（selftest）がここを見る。
  function report() {
    tell({
      choro: "report",
      href: location.pathname,
      text: (document.body ? document.body.textContent : "").trim().length,
      styled: !!document.getElementById("choro-style"),
      marks: document.querySelectorAll("mark.choro-found").length,
      footer: !!document.getElementById("choro-footer"),
      copies: document.querySelectorAll(".choro-copy").length,
      links: document.querySelectorAll("a[href]").length,
      bookScriptRuns: bookScriptRuns(),
    });
  }

  /// 書籍が持ち込んだ script が走るか。**走ってはいけない。**
  ///
  /// nonce を持たない script を 1 本置いてみる。配信時の CSP が効いていれば走らない。
  /// 安全側の前提そのものなので、確かめる道を残しておく。
  function bookScriptRuns() {
    try {
      const probe = document.createElement("script");
      probe.textContent = "window.__choroBookScriptRan = true";
      document.documentElement.appendChild(probe);
      probe.remove();
      return window.__choroBookScriptRan === true;
    } catch (_) {
      return false;
    }
  }

  const scroller = () => document.scrollingElement || document.documentElement;

  // ---- 見た目 ---------------------------------------------------------------

  function applyStyle(css, foreground) {
    let tag = document.getElementById("choro-style");
    if (!tag) {
      tag = document.createElement("style");
      tag.id = "choro-style";
      (document.head || document.documentElement).appendChild(tag);
    }
    tag.textContent = css || "";

    // 暗いテーマでだけ、背景色を持たない要素に文字色を当てる。
    // 一律に上書きすると、見出しの黒帯のように背景色を持つ要素から文字色を奪う。
    for (const el of document.querySelectorAll(".choro-fg")) el.classList.remove("choro-fg");
    if (!foreground || !document.body) return;
    const walk = (el) => {
      const background = getComputedStyle(el).backgroundColor;
      const painted = background && background !== "transparent"
        && !background.startsWith("rgba(0, 0, 0, 0)");
      if (painted) return; // ここから内側は出版社の配色に任せる
      el.classList.add("choro-fg");
      for (const child of el.children) walk(child);
    };
    walk(document.body);
  }

  function applyZoom(zoom) {
    // リフローする本文は、文字も図も一緒に拡大する。
    if (document.documentElement) document.documentElement.style.zoom = zoom;
  }

  /// 本文に無いものを足す。図版の拡大、コードのコピー、章末の行き先。
  /// `next` は章末に出す呼び名。無ければ足さない（終端か、紙面のページ）。
  function dress(next) {
    bindFigures();
    addCodeCopyButtons();
    addChapterFooter(next);
  }

  /// 図版は本文の幅に縮めてあるので、細かい図は読めない。押したら大きく出す。
  function bindFigures() {
    for (const img of document.querySelectorAll("img")) {
      if (img.dataset.choroZoom) continue;
      img.dataset.choroZoom = "1";
      img.style.cursor = "zoom-in";
      img.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        tell({ choro: "image", src: img.src });
      });
    }
  }

  function addCodeCopyButtons() {
    for (const pre of document.querySelectorAll("pre")) {
      if (pre.dataset.choroCopy) continue;
      pre.dataset.choroCopy = "1";
      pre.style.position = "relative";
      const button = document.createElement("button");
      // こちらが足したものだと分かる印。当たりを数えるときに本文から外す。
      button.className = "choro-copy";
      button.textContent = "コピー";
      button.setAttribute("style",
        "position:absolute;top:6px;right:6px;font-size:11px;padding:2px 8px;" +
        "border-radius:4px;border:1px solid rgba(127,127,127,.5);background:rgba(255,255,255,.85);" +
        "color:#222;cursor:pointer;opacity:0;transition:opacity .12s");
      pre.addEventListener("mouseenter", () => { button.style.opacity = "1"; });
      pre.addEventListener("mouseleave", () => { button.style.opacity = "0"; });
      button.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        // 写すのは窓の仕事。生成元を持たない文書から clipboard は触れない。
        const text = Array.from(pre.childNodes)
          .filter((node) => node !== button)
          .map((node) => node.textContent).join("");
        tell({ choro: "copy", text });
      });
      pre.appendChild(button);
    }
  }

  // 縦は読む軸、横は移動する軸。スクロールでは章を跨がないため、章末に導線を置く。
  function addChapterFooter(next) {
    if (!next || !document.body || document.getElementById("choro-footer")) return;
    const footer = document.createElement("div");
    footer.id = "choro-footer";
    footer.setAttribute("style", "margin:3em 0 1em;text-align:center");
    const button = document.createElement("button");
    button.textContent = next;
    button.setAttribute("style",
      "font:inherit;padding:8px 18px;border-radius:6px;cursor:pointer;" +
      "border:1px solid rgba(127,127,127,.5);background:transparent;color:inherit");
    button.addEventListener("click", () => tell({ choro: "next" }));
    footer.appendChild(button);
    document.body.appendChild(footer);
  }

  // ---- 居場所 ---------------------------------------------------------------

  function scrollBy(amount, byScreen) {
    scroller().scrollTop += byScreen ? amount * innerHeight : amount;
  }

  /// 覚えておいた場所へ戻す。飛び先、書き出し、割合の順に試す。
  function go(to) {
    if (!to) return;
    if (to.fragment) {
      const target = document.getElementById(to.fragment);
      if (target) { target.scrollIntoView(); return; }
    }
    if (to.text && scrollToText(to.text)) return;
    const el = scroller();
    el.scrollTop = (to.progression || 0) * el.scrollHeight;
  }

  function scrollToText(text) {
    const needle = text.trim().slice(0, 20);
    if (needle.length < 4) return false;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      if (!walker.currentNode.nodeValue.includes(needle)) continue;
      const element = walker.currentNode.parentElement;
      if (!element) continue;
      element.scrollIntoView({ block: "start" });
      return true;
    }
    return false;
  }

  /// 配られた本文に入っている印まで送る。押した直後の 1 回だけ窓が言ってくる。
  function approach() {
    const found = document.querySelector("mark.choro-found");
    if (found) found.scrollIntoView({ block: "center" });
  }

  /// 印の包みを解く。入れるのは配信時（core の mark）だが、外すだけならここで済む。
  /// 配り直すと画面がちらつくので、消すときはこちらでやる。
  function unmark() {
    for (const mark of document.querySelectorAll("mark.choro-found")) {
      const holder = mark.parentNode;
      while (mark.firstChild) holder.insertBefore(mark.firstChild, mark);
      holder.removeChild(mark);
      holder.normalize();
    }
  }

  /// 画面の上端にある段落の書き出し。長すぎると当たらなくなるので短く取る。
  function topText() {
    try {
      const element = document.elementFromPoint(Math.floor(innerWidth / 2), 8);
      if (!element) return "";
      return (element.textContent || "").replace(/\s+/g, " ").trim().slice(0, 40);
    } catch (_) {
      return "";
    }
  }

  /// 居場所を窓へ押し出す。
  ///
  /// 窓は position() を同期で答える約束になっている。尋ねて待つ形にすると、
  /// 履歴も読書位置も往復を待つことになり、nav の形が全部変わる。
  /// こちらから送っておけば、窓は最後に受けた値を持っているだけでよい。
  function tellPosition() {
    const el = scroller();
    tell({
      choro: "at",
      progression: el.scrollHeight > 0 ? el.scrollTop / el.scrollHeight : 0,
      text: topText(),
    });
  }

  let pending = null;
  function tellPositionSoon() {
    if (pending) return;
    pending = setTimeout(() => { pending = null; tellPosition(); }, 120);
  }

  // ---- 出来事 ---------------------------------------------------------------

  document.addEventListener("click", (event) => {
    const anchor = event.target.closest && event.target.closest("a[href]");
    if (!anchor) return;
    const raw = anchor.getAttribute("href");
    if (!raw) return;
    // 行き先を決めるのは窓。ここは押されたことと、どこを指していたかだけを伝える。
    event.preventDefault();
    const box = anchor.getBoundingClientRect();
    tell({
      choro: "link",
      href: raw,
      meta: event.metaKey || event.ctrlKey,
      rect: { left: box.left, top: box.top, right: box.right, bottom: box.bottom },
    });
  }, true);

  // キーは窓が引き受ける。章送りも献立の割り当ても、窓の側にしかない。
  // 縦の送りはこの文書が自前で動くので、押さえずに通す。
  document.addEventListener("keydown", (event) => {
    tell({
      choro: "key",
      key: event.key,
      meta: event.metaKey,
      ctrl: event.ctrlKey,
      shift: event.shiftKey,
      alt: event.altKey,
    });
  });

  // ピンチは Ctrl を伴う wheel として届く。倍率は窓が持っているので、そちらへ回す。
  document.addEventListener("wheel", (event) => {
    if (!event.ctrlKey) return;
    event.preventDefault();
    tell({ choro: "wheel", deltaY: event.deltaY });
  }, { passive: false });

  document.addEventListener("scroll", tellPositionSoon, { passive: true });
  window.addEventListener("scroll", tellPositionSoon, { passive: true });

  // ---- 名乗り ---------------------------------------------------------------

  // 窓は「目当ての文書が入ったか」をこれで見る。
  // 生成元を持たない相手の location は窓から読めないので、こちらから名乗るしかない。
  tell({ choro: "ready", href: location.pathname });
})();
