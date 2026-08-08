using System.Text.Json;

namespace ChoroReader.App;

/// <summary>
/// 本文の中で動かすスクリプト。
///
/// <para>
/// 本文に触るのはこれだけにする。殻はネイティブなので、WebView の中にアプリの DOM は無い。
/// 書籍の script はエンジンの段で止まっており（<c>IsScriptEnabled = false</c>）、
/// ここで入れるものだけが動く。CSP に巻き込まれないことは
/// WebView2 のスパイクが毎回確かめている（spikes/findings-windows.md）。
/// </para>
/// <para>
/// macOS 版の ReaderScripts と同じ役割で、送る言葉も揃えてある。
/// </para>
/// </summary>
internal static class ReaderScripts
{
    /// <summary>
    /// 文書が出来た直後に走る。窓へ知らせ、位置と鍵盤を運ぶ。
    ///
    /// <para>
    /// この時点ではまだ head を読んでいないので、文書を読み終えてからする仕事は
    /// <c>DOMContentLoaded</c> を待つ（スパイク 3 で確かめた性質）。
    /// </para>
    /// </summary>
    internal const string Main = """
        (function () {
          if (window.__choroReady) { return; }
          window.__choroReady = true;

          var XHTML = 'http://www.w3.org/1999/xhtml';
          // 便りが出せなかったことを、あとから聞けるように残す。
          // 窓の中は目で見られないので、黙って失敗させない。
          function post(m) {
            try {
              window.chrome.webview.postMessage(JSON.stringify(m));
            } catch (e) {
              window.__choroPostFailed = String(e);
            }
          }

          // 表示設定の CSS を当てる。窓から style で送られてくる。
          window.choroSetStyle = function (css) {
            var el = document.getElementById('choro-style');
            if (!el) {
              el = document.createElementNS(XHTML, 'style');
              el.id = 'choro-style';
              (document.head || document.documentElement).appendChild(el);
            }
            el.textContent = css;
          };

          function height() {
            var d = document.documentElement;
            return Math.max(1, (d.scrollHeight || 0) - (d.clientHeight || 0));
          }
          function progression() {
            var y = window.scrollY || document.documentElement.scrollTop || 0;
            return Math.min(1, Math.max(0, y / height()));
          }
          function atEnd() {
            var d = document.documentElement;
            return (window.scrollY || d.scrollTop || 0) + (d.clientHeight || 0) >= (d.scrollHeight || 0) - 4;
          }

          // 画面の上端にある文字。位置を覚え直すときの手掛かりにする。
          function anchorText() {
            var el = document.elementFromPoint(Math.floor(window.innerWidth / 2), 8);
            while (el && !el.textContent) { el = el.parentElement; }
            return el ? (el.textContent || '').trim().slice(0, 40) : '';
          }

          var pending = 0;
          function tellPosition() {
            if (pending) { return; }
            pending = window.setTimeout(function () {
              pending = 0;
              post({ kind: 'position', progression: progression(), atEnd: atEnd(), text: anchorText() });
            }, 120);
          }
          window.addEventListener('scroll', tellPosition, { passive: true });
          window.addEventListener('resize', tellPosition, { passive: true });

          // 縦は読むための軸、横は移動するための軸（spec.md 10.2）。
          // 本文に焦点があるときだけ処理する。メニューのキー等価にはしない。
          window.addEventListener('keydown', function (e) {
            if (e.metaKey || e.ctrlKey || e.altKey) { return; }
            if (e.key === 'ArrowRight') { post({ kind: 'arrow', side: 'right' }); e.preventDefault(); }
            else if (e.key === 'ArrowLeft') { post({ kind: 'arrow', side: 'left' }); e.preventDefault(); }
          });

          // 窓からの言いつけ。
          window.choroApply = function (m) {
            if (m.kind === 'style') { window.choroSetStyle(m.css); }
            else if (m.kind === 'top') { window.scrollTo(0, 0); }
            else if (m.kind === 'go') {
              if (m.fragment) {
                var target = document.getElementById(m.fragment);
                if (target) { target.scrollIntoView(true); return; }
              }
              if (typeof m.progression === 'number') { window.scrollTo(0, height() * m.progression); }
            } else if (m.kind === 'by') {
              window.scrollBy(0, m.amount);
            } else if (m.kind === 'approach') {
              var mark = document.querySelector('.choro-found');
              if (mark) { mark.scrollIntoView({ block: 'center' }); }
            }
            tellPosition();
          };

          function ready() {
            post({ kind: 'ready', href: location.pathname, title: document.title || '' });
            tellPosition();
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', ready);
          } else {
            ready();
          }
        })();
        """;

    /// <summary>窓から出先への言いつけ。文字列に組んで <c>ExecuteScriptAsync</c> で渡す。</summary>
    internal static string Apply(object message) =>
        $"window.choroApply && window.choroApply({JsonSerializer.Serialize(message)})";
}
