// 本文の上に浮かせて見せる覆い。図版の拡大と、リンク先の抜粋。
//
// どちらも「本文の位置を動かさずに、その場で確かめる」ための道具である。
// 書籍のことは何も知らない。何を見せるか・押したら何が起きるかは、呼ぶ側が渡す。

import { $ } from "../chrome.js";

/// 覆いを作る。`waitUntil` は抜粋の枠が入り終わるのを待つのに使う。
export function overlays({ waitUntil, attachKeys }) {
  /// 図版を大きく見せる。押すか Escape で閉じる。
  function showImage(src) {
    $("lightbox-image").src = src;
    $("lightbox").hidden = false;
  }

  function hideImage() {
    $("lightbox").hidden = true;
    $("lightbox-image").src = "";
  }

  /// リンク先の抜粋を、そのリンクの近くに浮かせる。
  ///
  /// `actions` は `[[名前, すること], ...]`。押すと覆いを閉じてから走る。
  function showPreview(anchor, built, actions) {
    const box = $("popover");
    const body = $("popover-body");
    body.textContent = "";

    // 抜粋も本文と同じく、書籍の script は動かさない。
    const frame = document.createElement("iframe");
    frame.setAttribute("sandbox", "allow-same-origin");
    body.appendChild(frame);
    body.appendChild(buttons(actions));

    place(box, anchor);

    frame.srcdoc = built.html;
    frame.style.height = built.isFootnote ? "auto" : "100%";

    // 抜粋の中に焦点が移ったままでも操作できるようにする。
    waitUntil(() => {
      const doc = frame.contentDocument;
      return doc && doc.readyState === "complete" && doc.body ? doc : null;
    }, "抜粋", 3000).then(attachKeys).catch(() => {});
  }

  function hidePreview() {
    $("popover").hidden = true;
    $("popover-body").textContent = "";
  }

  function buttons(actions) {
    const bar = document.createElement("div");
    bar.setAttribute("style",
      "display:flex;gap:8px;padding:6px 10px;border-top:1px solid var(--line);background:var(--bar)");
    for (const [label, run] of actions) {
      const button = document.createElement("button");
      button.textContent = label;
      button.setAttribute("style",
        "font:inherit;padding:3px 10px;border-radius:5px;cursor:pointer;" +
        "border:1px solid var(--line);background:var(--panel);color:var(--text)");
      button.addEventListener("click", () => { hidePreview(); run(); });
      bar.appendChild(button);
    }
    return bar;
  }

  /// リンクの近くへ置く。画面の外へはみ出さないところまでで止める。
  function place(box, anchor) {
    const rectangle = anchor.getBoundingClientRect();
    const stage = $("stage").getBoundingClientRect();
    box.hidden = false;
    const top = Math.min(stage.height - box.offsetHeight - 10, rectangle.bottom + 8);
    box.style.top = Math.max(8, top) + "px";
    box.style.left = Math.max(8, Math.min(stage.width - box.offsetWidth - 8, rectangle.left)) + "px";
  }

  $("lightbox").addEventListener("click", hideImage);

  return {
    showImage,
    hideImage,
    showPreview,
    hidePreview,
    /// どちらも閉じる。Escape と、本文を離れるときに使う。
    dismiss() {
      hidePreview();
      hideImage();
    },
  };
}
