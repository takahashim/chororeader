// 本文の枠の中にいる出先（agent.js）と話すための口。
//
// 本文は生成元を持たない文書なので、こちらから DOM に触れない。
// できるのは postMessage だけで、この口がその 1 本を包む。

/// `frame` の中の出先と話す。`hear` は届いた出来事を受ける。
export function talkTo(frame, hear) {
  const listen = (event) => {
    // **生成元では見分けられない。** 相手は生成元を持たず、独自スキームでは
    // event.origin の中身が処方どおりにならない。窓の同一性で見る。
    if (!frame.contentWindow || event.source !== frame.contentWindow) return;
    const said = event.data;
    if (!said || typeof said.choro !== "string") return;
    hear(said);
  };
  window.addEventListener("message", listen);

  return {
    /// 言いつける。まだ入っていなければ何も起きない。
    say(message) {
      const window_ = frame.contentWindow;
      if (window_) window_.postMessage(message, "*");
    },
    /// 聞くのをやめる。枠を捨てるときに呼ぶ。
    stop() {
      window.removeEventListener("message", listen);
    },
  };
}

/// 出先が言ってきた枠を、窓から見た位置に直す。
///
/// 出先の座標はその文書の中のもので、枠が画面のどこにあるかを知らない。
export function rectInWindow(frame, rect) {
  const box = frame.getBoundingClientRect();
  return {
    left: box.left + rect.left,
    top: box.top + rect.top,
    right: box.left + rect.right,
    bottom: box.top + rect.bottom,
  };
}
