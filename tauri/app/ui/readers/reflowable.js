// リフローする本文の窓。章を 1 つずつ iframe に入れる。
//
// 本文の枠は sandbox="allow-scripts" で、allow-same-origin を与えていない。
// その文書は生成元を持たないので、ここからは DOM に一切触れない。
// 本文に触る仕事は出先（agent.js）が引き受け、こちらとは決めた言葉で話す
// （spec.md「本文の出先と窓の言葉」）。
//
// 読書の窓（reader.js）とは `nav` の形で話す。あちらは形式を意識しない。
// 動いたことは departing / moved で知らせるだけで、履歴や読書位置には手を出さない。

import { $, invoke, showFailure, toast } from "../chrome.js";
import { chapterOfHref as chapterOfHrefIn } from "../lib/layout.js";
import { takeApproach } from "../lib/mark.js";
import { overlays } from "./overlays.js";
import { rectInWindow, talkTo } from "./talk.js";

/// 本文の振る舞いを作る。窓と分かち合うものは `shared` で受け取る。
export function reflowableReader(shared) {
  const { state, departing, moved, scrolled, bookUrl, focusContent, setZoom, onKeyDown } = shared;

  /// 本文の上に浮かせる覆い。図版の拡大とリンク先の抜粋。
  const overlay = overlays();

  /// いま出している章の番号。本文だけが持つ。
  /// 窓は「どこにいるか」を at() と position() で尋ねる。
  /// 局所の index と紛れないよう、持ち物の側に別の名前を付けておく。
  let shownIndex = 0;

  /// 出先が押し出してくる居場所。窓は position() を同期で答える約束なので、
  /// 尋ねて待つのではなく、送られてきた最後の値を持っておく。
  let here = { progression: 0, text: "" };

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

  /// 名乗りを待っているあいだの受け皿。待っていなければ null。
  let waitingFor = null;

  /// 出先との口。枠は 1 つきりなので、口も 1 つで足りる。
  const page = talkTo($("page"), (said) => hear(said));


  // ---- 章を出す -------------------------------------------------------------

  /// 章を出す。転んだら知らせる。呼ぶ側は着くのを待たないので、ここで受け止める。
  ///
  /// 待たない相手へ投げると、誰も受けずに「応答が返りませんでした」だけが残る。
  /// 待ち切れなかっただけならその場に短く出し、それ以外は原因が要るので画面に残す。
  async function showChapter(index, fragment, goTo = null) {
    try {
      await openChapter(index, fragment, goTo);
    } catch (error) {
      arriving = null;
      if (error && error.name === "Timeout") toast(error.message);
      else showFailure("本文を出せませんでした", error);
    }
  }

  /// `goTo` は着いたときに送る先で、割合の数値か、位置の対象を渡す。
  async function openChapter(index, fragment, goTo) {
    const chapter = state.book.chapters[index];
    if (!chapter) return;
    const token = ++loadTokens;
    shownIndex = index;
    arriving = { token, goTo, queuedSteps: 0 };

    await loadInto($("page"), bookUrl(chapter.href));

    // 後から押された分に追い越されていたら、こちらの後始末はしない。
    // 新しい読み込みが `arriving` を持っているので、こちらは触らずに降りる。
    if (!arriving || arriving.token !== token) return;

    dress();
    focusContent();
    nav.applyZoom();

    if (fragment) {
      page.say({ choro: "go", to: { fragment } });
    } else if (arriving.goTo != null) {
      // 数字だけ渡されたときは割合として扱う（検索やしおりからの移動）。
      page.say({
        choro: "go",
        to: typeof arriving.goTo === "number" ? { progression: arriving.goTo } : arriving.goTo,
      });
    } else {
      page.say({ choro: "top" });
    }
    // 位置を決めたあとで、囲まれている当たりまで送る。順番を逆にできない。
    if (takeApproach(state.mark)) page.say({ choro: "approach" });

    const queued = arriving.queuedSteps;
    arriving = null;
    moved();
    // 待たせた送りは、着いてからまとめて動かす。
    // 窓へ上げずにここで送る。待たせたのはこちらの都合で、窓は何も知らない。
    if (queued !== 0) nav.step(queued);
  }

  /// 目当ての文書が入り終わるまで待つ。
  ///
  /// 枠は生成直後に about:blank を持っており、load も readyState も当てにならない。
  /// 中身を覗くこともできないので、**出先が名乗るのを待つ**。
  /// 同じ章をもう一度開くこともある（当たりへ飛ぶときなど）ので、
  /// 名乗りが目当ての経路かどうかまで見る。
  function loadInto(frame, url) {
    const expected = decodeURIComponent(new URL(url, location.href).pathname);
    let arrived = null;
    waitingFor = (said) => {
      if (said.choro === "ready" && decodeURIComponent(said.href) === expected) arrived = said;
    };
    frame.src = url;
    return waitUntil(() => arrived, "本文").finally(() => { waitingFor = null; });
  }

  /// 本文に無いものを足してもらう。章末の行き先は、次の章の呼び名まで決めて渡す。
  function dress() {
    page.say({
      choro: "style",
      css: state.style.css,
      foreground: state.style.needsForegroundMarking,
    });
    page.say({ choro: "dress", next: nextChapterLabel() });
  }

  /// 章末に出す呼び名。次が無ければ null。
  /// 目次に無い章は題が付かず、代わりにファイル名が入る。それを見せても意味がない。
  function nextChapterLabel() {
    if (!nav.canGoNext()) return null;
    const next = state.book.chapters[shownIndex + 1];
    const named = next.title && next.title !== next.href.split("/").pop();
    return named ? "次の章へ： " + next.title : "次の章へ";
  }


  // ---- 出先が言ってきたこと ---------------------------------------------------

  function hear(said) {
    if (waitingFor) waitingFor(said);
    switch (said.choro) {
      case "at": return heardPosition(said);
      case "link": return heardLink(said);
      case "image": return overlay.showImage(said.src);
      case "copy": return heardCopy(said.text);
      case "next": departing(); showChapter(shownIndex + 1); return;
      case "key": return onKeyDown(keyFromContent(said));
      case "wheel": return heardWheel(said.deltaY);
      case "stumbled":
        return showFailure("本文の出先が転びました", `${said.what}: ${said.why}`);
    }
  }

  function heardPosition(said) {
    here = { progression: said.progression, text: said.text };
    scrolled();
  }

  function heardCopy(text) {
    // 生成元を持たない文書から clipboard は触れない。写すのはこちら。
    navigator.clipboard.writeText(text)
      .then(() => toast("コードをコピーしました"))
      .catch(() => toast("コピーできませんでした"));
  }

  function heardWheel(deltaY) {
    // ピンチ 1 回ぶんの deltaY は小さい。50 で割ると指の動きに付いてくる。
    if (state.book) setZoom(state.zoom * Math.exp(-deltaY / 50), "custom");
  }

  /// 本文から上がってきたキーを、窓の受け手が読める形にする。
  ///
  /// 縦の送りは本文の側で既に動いている。`fromContent` を立てておくと、
  /// 窓はそれを見て二重に送らない。
  function keyFromContent(said) {
    return {
      key: said.key,
      metaKey: said.meta,
      ctrlKey: said.ctrl,
      shiftKey: said.shift,
      altKey: said.alt,
      fromContent: true,
      target: null,
      preventDefault() {},
    };
  }

  /// 本文のリンクが押された。行き先を決めるのはこちら。
  function heardLink(said) {
    const raw = said.href;
    if (/^(https?|mailto):/i.test(raw)) {
      toast("ブラウザで開きます: " + raw);
      invoke("open_external", { url: raw });
      return;
    }

    const [path, fragment] = raw.split("#");
    const from = state.book.chapters[shownIndex].href;
    const href = path ? resolveHref(from, path) : from;

    if (said.meta) {
      invoke("open_in_new_window", { path: state.book.path, href });
      return;
    }
    showPreview(rectInWindow($("page"), said.rect), href, fragment || null);
  }

  /// リンク先を、移動せずにその場で見せる。押したときにすることも一緒に渡す。
  async function showPreview(rect, href, fragment) {
    const built = await invoke("preview_link", {
      id: state.book.id, href, fragment, css: state.style.css,
    });
    if (!built) return toast("参照先を読めませんでした");

    overlay.showPreview(rect, built, [
      ["ここへ移動", () => {
        const index = chapterOfHref(href);
        if (index != null) { departing(); showChapter(index, fragment); }
      }],
      ["新しいウィンドウで開く", () => invoke("open_in_new_window", { path: state.book.path, href })],
    ]);
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


  /// 目当てのものが現れるまで待つ。
  function waitUntil(check, what, timeout = 10000) {
    return new Promise((resolve, reject) => {
      const started = performance.now();
      const tick = () => {
        const value = check();
        if (value) return resolve(value);
        if (performance.now() - started > timeout) {
          // 待ち切れなかっただけか、思わぬ躓きか。受ける側が見分けられるようにする。
          const error = new Error(what + " を待って時間切れ");
          error.name = "Timeout";
          return reject(error);
        }
        requestAnimationFrame(tick);
      };
      tick();
    });
  }


  // ---- 窓との約束 -----------------------------------------------------------

  const nav = {
    paged: false,
    /// 倍率を覚える先。紙面と本文では合う倍率が違う。
    zoomSetting: "epubZoom",
    defaultFit: "custom",

    /// 行き先（章の番号）。目次や当たりは経路で言ってくる。
    locate: (href) => chapterOfHref(href),
    show: (index, options = {}) => showChapter(index, options.fragment || null, options.goTo || null),
    currentHref: () => (state.book.chapters[shownIndex] || {}).href,

    position() {
      return {
        href: this.currentHref() || "",
        progression: here.progression,
        page: 0,
        fragment: "",
        // 割合だけだと、文字サイズや本文幅を変えたときに見失う。
        // いま画面の上端に来ている文字を覚えておき、次はそれを手掛かりに戻す。
        text: here.text,
      };
    },

    reveal(position) {
      const index = this.locate(position.href);
      if (index != null) showChapter(index, null, position);
    },

    step(delta) {
      // 読み込み中の分は取っておき、着いてからまとめて動かす。
      if (arriving) { arriving.queuedSteps += delta; return; }
      const index = shownIndex + delta;
      if (index < 0 || index >= state.book.chapters.length) return;
      departing();
      showChapter(index);
    },

    scrollBy: (amount, byScreen) => page.say({ choro: "by", amount, byScreen }),
    applyZoom: () => page.say({ choro: "zoom", zoom: state.zoom }),

    /// 当たりの目当て。リフローは章の経路で指す。
    markTarget: (href) => ({ href: href || "", page: 0 }),
    /// 検索の当たりの行き先。
    hitTarget: (hit) => chapterOfHref(hit.href),
    /// しおりに付ける名前。
    label: () => (state.book.chapters[shownIndex] || {}).title || "",
    /// いま読んでいるところを、別の窓で開くときの言い方。
    hereHref: () => (state.book.chapters[shownIndex] || {}).href || "",
    /// 別の窓で開いたときの枠。リフローは印が本文に入って配られるので、何も要らない。
    paintMark: async () => {},
    /// いまどこにいるか。本文は章の番号で言う。
    at: () => String(shownIndex),
    /// 次の章があるか。章末の行き先を出すかどうかも、これで決まる。
    canGoNext: () => shownIndex + 1 < (state.book.chapters || []).length,

    prepare(saved, href, fragment) {
      $("pdf").hidden = true;
      $("page").hidden = false;
      $("fit").hidden = true;
      $("layout").hidden = true;
      state.zoom = state.settings.epubZoom || 1;
      $("zoom-level").textContent = Math.round(state.zoom * 100) + "%";
      const index = this.locate(href || saved.position.href) ?? 0;
      // 章を名指しで開くときは、覚えていた場所ではなく、指された場所へ着く。
      return showChapter(index, fragment || null, href ? null : saved.position);
    },

    /// 印を外す。本文は 1 つの文書なので、そこだけ見ればよい。
    clearMarks: () => page.say({ choro: "unmark" }),
    /// 覆いを閉じる。図版の拡大とリンクの抜粋は、本文から開いたもの。
    dismissOverlays: () => overlay.dismiss(),
    /// 表示設定が変わった。いま出ている本文へ当て直す。
    restyle: () => page.say({
      choro: "style",
      css: state.style.css,
      foreground: state.style.needsForegroundMarking,
    }),
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
