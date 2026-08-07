// 紙面の窓。PDF と固定レイアウト EPUB を、ページで数えて並べる。
//
// 綴じ方向も拡大も送り方も、この 2 つでは同じに振る舞う。違いは
// 「絵を描いてもらうか、元の紙面をそのまま置くか」だけで、その分岐はここに閉じる。
//
// 読書の窓（reader.js）とは `nav` の形で話す。あちらは形式を意識しない。
// 動いたことは departing / moved で知らせるだけで、履歴や読書位置には手を出さない。

import { $, invoke, toast } from "../chrome.js";
import {
  isFixedBook, pageAfterStep, pageCountOf, pageOfHref as pageOfHrefIn, pagesToShow,
} from "../lib/layout.js";
import { scrollToMark, unwrapMarks } from "../lib/mark.js";

/// 紙面の振る舞いを作る。窓と分かち合うものは `shared` で受け取る。
export function pagedReader(shared) {
  const { state, departing, moved, setZoom, bookUrl, encodePath } = shared;

  /// いま出しているページと、その寸法。紙面だけが持つ。
  /// 窓は「どこにいるか」を at() と position() で尋ねる。
  /// 引数の page と紛れないよう、持ち物の側に別の名前を付けておく。
  let shownPage = 0;
  let shownSize = null;

  // 固定レイアウトかどうかは、この中でだけ効く違い。
  const isFixed = () => isFixedBook(state.book);
  /// 目次や当たりは経路で言ってくる。いまの書籍を当ててページ番号へ読み替える。
  const pageOfHref = (href) => pageOfHrefIn(state.book, href);
  const visiblePages = (total) =>
    pagesToShow(state.settings.pageLayout, shownPage, total, state.book.spreads);
  const isContinuous = () => state.settings.pageLayout === "continuousScroll";

  function onPdfScroll() {
    // いま画面の上端に来ているページを、位置として覚える。
    const box = $("pdf");
    const top = box.scrollTop;
    for (const img of pageParts(box)) {
      if (img.offsetTop + img.offsetHeight > top) {
        shownPage = Number(img.dataset.page);
        break;
      }
    }
    moved();
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
        element.addEventListener("load", (event) => scrollToMark(event.target.contentDocument, state.mark));
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


  function showFixed(page) {
    shownPage = Math.max(0, Math.min(state.book.pages.length - 1, page));
    buildFixed();
    refreshMarkedPage();
    const box = $("pdf");
    const target = pageElement(box, shownPage);
    if (target) box.scrollTop = isContinuous() ? target.offsetTop - 16 : 0;
    layoutMarks();
    markCurrentThumb();
    moved();
  }


  /// 倍率に合わせて枠の大きさだけを整える。
  /// 画像を取り直すより桁違いに軽いので、拡大の手応えはここで出す。
  /// 大きさを与えないと画像がすべて同じ位置に積まれ、loading="lazy" が効かない。
  function layoutPdf() {
    const box = $("pdf");
    const [width, height] = shownSize || [0, 0];
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


  function showPdf(page) {
    shownPage = Math.max(0, Math.min(state.book.pageCount - 1, page));
    buildPdf();
    const box = $("pdf");
    const target = pageElement(box, shownPage);
    if (target) box.scrollTop = isContinuous() ? target.offsetTop - 16 : 0;
    layoutMarks();
    markCurrentThumb();
    moved();
  }



  /// 合わせ方から倍率を決める。PDF でページの大きさが分かっているときだけ計算できる。
  function zoomForFit(fit) {
    if (!shownSize) return null;
    const [width, height] = shownSize;
    const box = $("pdf").getBoundingClientRect();
    switch (fit) {
      case "width": return (box.width - 32) / width;
      case "page": return Math.min((box.width - 32) / width, (box.height - 32) / height);
      case "actual": return 1;
      default: return null;
    }
  }


  /// 拡大して端がはみ出したら、掴んで動かせるようにする。
  function updatePannable() {
    const box = $("pdf");
    box.classList.toggle("pannable", box.scrollWidth > box.clientWidth + 1);
  }


  function renderThumbs() {
    const box = $("thumbs");
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
        else img.style.aspectRatio = String((shownSize || [800, 1130])[0] / (shownSize || [800, 1130])[1]);
      } else {
        img.src = `/pdf/${state.book.id}/${index}/${THUMB_ZOOM}`;
      }

      const caption = document.createElement("figcaption");
      caption.textContent = String(index + 1);

      figure.append(img, caption);
      figure.addEventListener("click", () => { departing(); showPage(index); });
      box.appendChild(figure);
    }
    markCurrentThumb();
  }


  function markCurrentThumb() {
    const box = $("thumbs");
    for (const figure of box.children) {
      const on = Number(figure.dataset.page) === shownPage;
      figure.classList.toggle("current", on);
      if (on) figure.scrollIntoView({ block: "nearest" });
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


  /// 目当てのページを配り直す。印の付き外れは配信時に決まるので、
  /// すでに入っている紙面は、経路を変えて取り直さないと印が付かない。
  function refreshMarkedPage() {
    if (!isFixed() || !state.mark || !state.book.pages[state.mark.page]) return;
    const part = pageElement($("pdf"), state.mark.page);
    if (!part || part.tagName !== "IFRAME") return;
    const url = bookUrl(state.book.pages[state.mark.page].href, state.mark.page);
    if (part.getAttribute("src") !== url) part.src = url;
  }


  /// 紙面のページ番号へ移す。中身の作り方だけが形式で違う。
  ///
  /// どちらも待つものを持たない。ここを async にすると、送りや目次から呼ばれたときに
  /// 誰も待たない約束ができ、転んでも「応答が返りませんでした」しか残らなくなる。
  function showPage(page) {
    if (isFixed()) showFixed(page);
    else showPdf(page);
  }


  /// 紙面を担う要素だけ。当たりの枠も同じ器に入るので、番号を持つものに絞る。
  function pageParts(box) {
    return Array.from(box.children).filter((el) => el.dataset.page !== undefined);
  }


  /// 器の中から、そのページを担う要素を探す。連続以外では並びと番号がずれる。
  function pageElement(box, page) {
    return pageParts(box).find((el) => Number(el.dataset.page) === page);
  }


  /// 実際に描き直す。拡大の途中で毎回呼ぶと追いつかないので、落ち着いてから動かす。
  let renderTimer = null;

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



  const nav = {
    paged: true,
    zoomSetting: "zoom",
    defaultFit: "width",

    locate: (href) => pageOfHref(href),
    show: (page) => showPage(page),
    currentHref: () =>
      (isFixed() ? (state.book.pages[shownPage] || {}).href : String(shownPage)),

    position: () => ({ href: "", progression: 0, page: shownPage, fragment: "", text: "" }),
    reveal: (position) => showPage(position.page),

    step(delta) {
      departing();
      showPage(pageAfterStep(state.settings.pageLayout, shownPage, delta, state.book.spreads));
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
    label: () => `p.${shownPage + 1}`,
    hereHref: () => String(shownPage),

    /// 紙面の当たりは絵の上に重ねるので、開いてから土台に枠を尋ね直す。
    /// 固定レイアウトは本文が HTML なので、印は配られたものがそのまま入っている。
    async paintMark(query) {
      if (isFixed()) return;
      state.mark.rects = await invoke("page_marks", {
        id: state.book.id, page: shownPage, query,
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

    prepareFixed(saved, href) {
      // 寸法は meta viewport から来る。名乗っていない書籍のために当てを置く。
      shownSize = state.book.pageSize || [800, 1130];
      this.fitFirst(state.settings.zoom || 1);
      showFixed(href ? Number(href) : saved.position.page || 0);
    },

    async preparePdf(saved, href) {
      // 合わせ方を計算するにはページの大きさが要る。1 ページ目で代表させる。
      shownSize = await invoke("page_size", { id: state.book.id, page: 0 }).catch(() => null);
      this.fitFirst(state.settings.zoom);
      showPdf(href ? Number(href) : saved.position.page || 0);
    },

    fitFirst(fallback) {
      const fitted = zoomForFit(state.settings.fit);
      setZoom(fitted == null ? fallback : fitted, state.settings.fit);
    },

    /// 印を外す。紙面の枠と、紙面に入っている本文の印の両方。
    clearMarks() {
      layoutMarks();
      for (const part of pageParts($("pdf"))) {
        if (part.tagName === "IFRAME") unwrapMarks(part.contentDocument);
      }
    },

    /// いまどこにいるか。紙面はページ番号で言う。
    at: () => String(shownPage),
    /// 次があるか。終端では送っても動かない。
    canGoNext: () => shownPage < pageCountOf(state.book) - 1,

    /// 覆いは本文の側のもの。紙面には無い。
    dismissOverlays: () => {},
    /// 表示設定は本文の見た目に効く。紙面は絵なので当てるものが無い。
    restyle: () => {},
    /// 紙面は章の読み込みを持たない。
    loading: () => false,

    /// ページの一覧。紙面の書籍だけが持つ。
    showThumbs: () => renderThumbs(),

    /// 並べ方が変わった。組み直してからいまのページへ戻す。
    relayout() {
      $("pdf").dataset.key = "";
      showPage(shownPage);
    },

    /// 合わせ方から決まる倍率。
    zoomFor: (fit) => zoomForFit(fit),

    /// 倍率を戻したときの値。紙面は横幅に合わせる。
    defaultZoom: () => zoomForFit("width") || 1,

    /// 窓の大きさが変わった。合わせ方を保つのは PDF だけでよい。
    refit() {
      if (isFixed()) return;
      const fitted = zoomForFit(state.settings.fit);
      if (fitted != null) setZoom(fitted, state.settings.fit);
    },
  };

  return nav;
}
