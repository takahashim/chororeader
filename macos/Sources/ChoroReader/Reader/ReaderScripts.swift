import Foundation

/// WebView へ注入するスクリプトとスタイル。
/// 書籍側の JavaScript は無効のまま、これらのアプリ由来スクリプトだけが動く。
enum ReaderScripts {
    /// アプリ由来の UI（コードブロックの操作ボタンなど）のスタイル。
    static let chromeCSS = """
    .choro-code-actions {
        position: absolute; top: 4px; right: 6px;
        display: none; gap: 4px; z-index: 10;
    }
    pre:hover > .choro-code-actions { display: inline-flex; }
    .choro-code-button {
        font-family: -apple-system, sans-serif; font-size: 11px; line-height: 1.4;
        padding: 2px 8px; border-radius: 5px; cursor: pointer;
        border: 1px solid rgba(128,128,128,0.4);
        background: rgba(250,250,250,0.94); color: #333;
        -webkit-appearance: none; appearance: none;
    }
    .choro-code-button:hover { background: #fff; }
    #choro-chapter-end {
        margin: 3em 0 1em; padding-top: 1.5em;
        border-top: 1px solid rgba(128,128,128,0.25);
        text-align: center;
    }
    .choro-chapter-end-button {
        font-family: -apple-system, sans-serif; font-size: 0.95em;
        padding: 8px 20px; border-radius: 7px; cursor: pointer;
        border: 1px solid rgba(128,128,128,0.35);
        background: rgba(128,128,128,0.08); color: inherit;
        -webkit-appearance: none; appearance: none;
    }
    .choro-chapter-end-button:hover { background: rgba(128,128,128,0.18); }
    /* 検索結果から飛んだ先で、当たった語を囲む印。書籍の配色に負けない濃さにする。 */
    mark.choro-found {
        background: rgba(255,196,0,0.55); color: inherit; border-radius: 2px;
    }
    """

    /// スタイル注入だけを先に済ませ、本文が素のまま一瞬見える状態を避ける。
    static func styleScript(css: String) -> String {
        """
        (function () {
          var XHTML = 'http://www.w3.org/1999/xhtml';
          window.choroMake = function (tag) { return document.createElementNS(XHTML, tag); };
          window.choroSetStyle = function (css) {
            var el = document.getElementById('choro-style');
            if (!el) {
              el = window.choroMake('style');
              el.id = 'choro-style';
              (document.head || document.documentElement).appendChild(el);
            }
            el.textContent = css;
          };
          window.choroSetStyle(\(quote(css)));
        })();
        """
    }

    static let mainScript = """
    (function () {
      if (window.__choroReady) return;
      window.__choroReady = true;

      function post(m) {
        try { window.webkit.messageHandlers.choro.postMessage(m); } catch (e) {}
      }
      function scrollMax() {
        return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      }
      function progression() {
        var max = scrollMax();
        return max <= 0 ? 0 : Math.max(0, Math.min(1, window.scrollY / max));
      }
      function atEnd() {
        return window.scrollY >= scrollMax() - 4;
      }
      // 位置復元の最後の手がかりとして、画面上部にある本文の断片を拾う。
      function anchorText() {
        var els = document.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6, pre, td, dd');
        for (var i = 0; i < els.length; i++) {
          var r = els[i].getBoundingClientRect();
          if (r.bottom > 8 && r.top < window.innerHeight * 0.6) {
            var t = (els[i].textContent || '').trim().replace(/\\s+/g, ' ');
            if (t.length >= 8) return t.slice(0, 60);
          }
        }
        return null;
      }
      function report() {
        post({ kind: 'position', progression: progression(), atEnd: atEnd(), text: anchorText() });
      }

      var timer = null;
      window.addEventListener('scroll', function () {
        if (timer) return;
        timer = setTimeout(function () { timer = null; report(); }, 150);
      }, { passive: true });
      window.addEventListener('resize', function () { report(); }, { passive: true });

      // 縦は読むための軸、横は移動するための軸と決めている。
      // スクロールで章が変わると、読んでいるつもりが移動してしまうため、縦では章を跨がない。
      document.addEventListener('keydown', function (e) {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        var t = e.target;
        if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
        if (e.key === 'ArrowRight') { post({ kind: 'arrow', side: 'right' }); e.preventDefault(); }
        else if (e.key === 'ArrowLeft') { post({ kind: 'arrow', side: 'left' }); e.preventDefault(); }
      });

      // 章末に、次の章への行き先を置く。境界を跨ぐことを目に見える形にする。
      window.choroSetChapterEnd = function (label) {
        var existing = document.getElementById('choro-chapter-end');
        if (existing) { existing.remove(); }
        if (!label) return;
        var box = window.choroMake('div');
        box.id = 'choro-chapter-end';
        var button = window.choroMake('button');
        button.setAttribute('class', 'choro-chapter-end-button');
        button.textContent = label;
        button.addEventListener('click', function (e) {
          e.preventDefault();
          post({ kind: 'nextChapter' });
        });
        box.appendChild(button);
        document.body.appendChild(box);
      };

      function decorateCode() {
        var pres = document.querySelectorAll('pre');
        for (var i = 0; i < pres.length; i++) {
          var pre = pres[i];
          if (pre.getAttribute('data-choro')) continue;
          pre.setAttribute('data-choro', '1');
          if (!pre.style.position) pre.style.position = 'relative';

          var bar = window.choroMake('span');
          bar.setAttribute('class', 'choro-code-actions');

          (function (pre, bar) {
            var copy = window.choroMake('button');
            copy.setAttribute('class', 'choro-code-button');
            copy.textContent = 'コピー';
            copy.addEventListener('click', function (e) {
              e.preventDefault(); e.stopPropagation();
              var clone = pre.cloneNode(true);
              var junk = clone.querySelectorAll('.choro-code-actions');
              for (var k = 0; k < junk.length; k++) { junk[k].remove(); }
              post({ kind: 'copyCode', text: clone.innerText || clone.textContent });
              copy.textContent = 'コピーしました';
              setTimeout(function () { copy.textContent = 'コピー'; }, 1200);
            });
            var wrap = window.choroMake('button');
            wrap.setAttribute('class', 'choro-code-button');
            wrap.textContent = '折り返し';
            wrap.addEventListener('click', function (e) {
              e.preventDefault(); e.stopPropagation();
              var on = pre.style.whiteSpace === 'pre-wrap';
              pre.style.whiteSpace = on ? 'pre' : 'pre-wrap';
              pre.style.wordBreak = on ? 'normal' : 'break-all';
            });
            bar.appendChild(copy);
            bar.appendChild(wrap);
          })(pre, bar);

          pre.appendChild(bar);
        }
      }

      // 内部リンクにしばらく触れていたら、移動せずに中身を見せる。
      // 参照を確かめるだけのために本文の位置を失わないようにするための仕掛け。
      var hoverTimer = null;
      var hoverLink = null;

      function internalHref(a) {
        if (!a) return null;
        var href = a.getAttribute('href');
        if (!href) return null;
        if (/^[a-z][a-z0-9+.-]*:/i.test(href) && href.indexOf('chororeader:') !== 0) return null;
        return href;
      }
      function closestAnchor(node) {
        while (node && node.nodeType !== 1) { node = node.parentNode; }
        if (!node) return null;
        return node.closest ? node.closest('a') : null;
      }
      function cancelHover(notify) {
        if (hoverTimer) { clearTimeout(hoverTimer); hoverTimer = null; }
        if (hoverLink && notify) { post({ kind: 'previewCancel' }); }
        hoverLink = null;
      }

      document.addEventListener('mouseover', function (e) {
        var a = closestAnchor(e.target);
        var href = internalHref(a);
        if (!href) { return; }
        if (a === hoverLink) return;
        cancelHover(false);
        hoverLink = a;
        hoverTimer = setTimeout(function () {
          hoverTimer = null;
          var r = a.getBoundingClientRect();
          var type = (a.getAttribute('epub:type') || a.getAttribute('role') || '');
          post({
            kind: 'preview',
            href: href,
            noteref: type.indexOf('noteref') >= 0 || type.indexOf('doc-noteref') >= 0,
            rect: { x: r.left, y: r.top, w: r.width, h: r.height }
          });
        }, 420);
      }, true);

      document.addEventListener('mouseout', function (e) {
        var a = closestAnchor(e.target);
        if (a && a === hoverLink) { cancelHover(true); }
      }, true);

      // クリックしたリンクの位置を、移動の判断より先に渡す。
      // 脚注ならポップオーバーで見せるため、吹き出しを出す位置が要る。
      document.addEventListener('click', function (e) {
        var a = closestAnchor(e.target);
        if (!internalHref(a)) return;
        var r = a.getBoundingClientRect();
        post({ kind: 'linkRect', rect: { x: r.left, y: r.top, w: r.width, h: r.height } });
      }, true);

      window.addEventListener('scroll', function () { cancelHover(true); }, { passive: true });

      // 暗いテーマで文字色を当てる先を選ぶ。
      // 出版社が背景色を敷いた要素（見出しの帯、注意書きの箱）は、文字色も一緒に決めている。
      // そこへ踏み込むと配色が壊れるので、背景を持つ枝には触れない。
      window.choroApplyForeground = function (enabled) {
        var marked = document.getElementsByClassName('choro-fg');
        while (marked.length) { marked[0].classList.remove('choro-fg'); }
        if (!enabled || !document.body) return 0;

        function hasOwnBackground(el) {
          var bg = window.getComputedStyle(el).backgroundColor;
          if (!bg) return false;
          if (bg === 'transparent') return false;
          return !/^rgba\\(\\s*0,\\s*0,\\s*0,\\s*0\\s*\\)$/.test(bg);
        }

        var count = 0;
        var stack = [];
        for (var i = 0; i < document.body.children.length; i++) { stack.push(document.body.children[i]); }
        while (stack.length) {
          var el = stack.pop();
          if (el.nodeType !== 1) continue;
          var tag = el.tagName;
          if (tag === 'SCRIPT' || tag === 'STYLE') continue;
          // コードは色付けを残したいので、内側へは入らずに枠だけ読めるようにする。
          if (tag === 'PRE' || tag === 'CODE') { el.classList.add('choro-fg'); count++; continue; }
          if (hasOwnBackground(el)) continue;
          el.classList.add('choro-fg');
          count++;
          for (var j = 0; j < el.children.length; j++) { stack.push(el.children[j]); }
        }
        return count;
      };

      window.choroScrollToProgression = function (p) {
        window.scrollTo(0, scrollMax() * p);
        return true;
      };
      window.choroScrollToFragment = function (id) {
        var el = document.getElementById(id);
        if (!el) {
          var named = document.getElementsByName(id);
          el = named.length ? named[0] : null;
        }
        if (!el) return false;
        el.scrollIntoView(true);
        window.scrollBy(0, -20);
        return true;
      };
      window.choroScrollToText = function (needle) {
        if (!needle) return false;
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var node;
        while ((node = walker.nextNode())) {
          var idx = (node.nodeValue || '').indexOf(needle);
          if (idx < 0) continue;
          var range = document.createRange();
          range.setStart(node, idx);
          range.setEnd(node, Math.min((node.nodeValue || '').length, idx + needle.length));
          var rect = range.getBoundingClientRect();
          window.scrollBy(0, rect.top - window.innerHeight * 0.25);
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
          return true;
        }
        return false;
      };
      window.choroSelectedText = function () {
        return (window.getSelection() || '').toString();
      };

      // 検索結果から飛んだ先で、当たった語を囲む。
      //
      // 一覧に前後の文脈が出ていても、着いた章のどこに当たったのかは分からない。
      // 章の中で nth 番目のものを選ぶ。同じ語が何度も出る章があるためである。
      //
      // 畳み方は DocumentSearch.options と同じ規則にしてある
      // （全角と半角、大文字と小文字、濁点の合成を区別しない）。
      var COMBINING = [[0x0300, 0x036f], [0x1ab0, 0x1aff], [0x1dc0, 0x1dff],
                       [0x20d0, 0x20ff], [0xfe20, 0xfe2f], [0x3099, 0x309a]];

      function foldChar(c) {
        var code = c.codePointAt(0);
        for (var i = 0; i < COMBINING.length; i++) {
          if (code >= COMBINING[i][0] && code <= COMBINING[i][1]) return '';
        }
        var folded = c;
        if (code >= 0xff01 && code <= 0xff5e) folded = String.fromCodePoint(code - 0xfee0);
        else if (code === 0x3000) folded = ' ';
        // 小文字にすると 2 文字に増える字がある。1 文字が 1 文字に写る畳み方だけを使う。
        return Array.from(folded.toLowerCase())[0] || c;
      }

      function foldText(s) {
        var out = '';
        var chars = Array.from(s || '');
        for (var i = 0; i < chars.length; i++) { out += foldChar(chars[i]); }
        return out;
      }

      // 本文でないものを外す。書籍の script と style に加えて、
      // こちらが足したもの（コードのコピーボタン、章末の行き先）も数えない。
      // 抽出（HTMLText）に入らないものを数えると、当たりの順番がずれる。
      function isFurniture(node) {
        for (var el = node; el && el.nodeType === 1; el = el.parentNode) {
          var name = (el.nodeName || '').toLowerCase();
          if (name === 'script' || name === 'style') return true;
          if (el.id && String(el.id).indexOf('choro') === 0) return true;
          var cls = el.getAttribute ? el.getAttribute('class') : null;
          if (cls && (' ' + cls + ' ').indexOf(' choro') >= 0) return true;
        }
        return false;
      }

      // 畳んだ本文と、畳んだ 1 単位ごとの居場所（節、節の中の位置、元の文字の長さ）。
      // 添字は畳んだ文字列のものに合わせる。基本多言語面の外の字で 2 単位になるため。
      function foldBody() {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var folded = '';
        var places = [];
        var node;
        while ((node = walker.nextNode())) {
          if (isFurniture(node.parentNode)) continue;
          var chars = Array.from(node.nodeValue || '');
          var at = 0;
          for (var i = 0; i < chars.length; i++) {
            var one = foldChar(chars[i]);
            for (var u = 0; u < one.length; u++) { places.push([node, at, chars[i].length]); }
            folded += one;
            at += chars[i].length;
          }
        }
        return { folded: folded, places: places };
      }

      window.choroClearMarks = function () {
        var marks = document.querySelectorAll('mark.choro-found');
        for (var i = 0; i < marks.length; i++) {
          var parent = marks[i].parentNode;
          while (marks[i].firstChild) { parent.insertBefore(marks[i].firstChild, marks[i]); }
          parent.removeChild(marks[i]);
          // 切った文字節を繋ぎ直す。残すと、次に畳んだときの居場所がずれる。
          parent.normalize();
        }
      };

      window.choroMark = function (query, nth, scroll) {
        window.choroClearMarks();
        var needle = foldText(query);
        if (!needle || !document.body) return false;

        var body = foldBody();
        var at = -1;
        for (var n = 0; n <= nth; n++) {
          at = body.folded.indexOf(needle, at + 1);
          if (at < 0) return false;
        }

        var from = body.places[at];
        var to = body.places[at + needle.length - 1];
        if (!from || !to) return false;

        // 節をまたぐ当たりは、始まりの節までを囲む。
        var node = from[0];
        var start = from[1];
        var end = node === to[0] ? to[1] + to[2] : (node.nodeValue || '').length;
        var tail = node.splitText(start);
        if (end - start < (tail.nodeValue || '').length) { tail.splitText(end - start); }

        var mark = window.choroMake('mark');
        mark.setAttribute('class', 'choro-found');
        tail.parentNode.replaceChild(mark, tail);
        mark.appendChild(tail);

        if (scroll) {
          var rect = mark.getBoundingClientRect();
          window.scrollBy(0, rect.top - window.innerHeight * 0.3);
        }
        return true;
      };

      decorateCode();
      report();
    })();
    """

    static func quote(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}
