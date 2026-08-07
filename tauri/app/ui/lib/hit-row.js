// 検索の当たりを 1 行で見せる。読書の窓と書棚の窓が同じ形で並べる。
//
// 見た目の決まり（章名の欄と抜粋、コードには別の字面）は CSS の .hit が持っている。
// 組み立てを 2 か所に分けると、片方に足したものがもう片方に入らないまま気付けない。

import { oneLine } from "./format.js";

/// 当たり 1 件の行。押したときの振る舞いは呼ぶ側が決める。
///
/// `open()` は押したとき、`menu()` は右クリックしたときに出す献立
/// （`[[名前, すること], ...]` の並び）を返す。
export function hitRow(hit, { open, menu, title }) {
  const row = document.createElement("a");
  row.className = "hit" + (hit.isCode ? " code" : "");
  // 治具はここを見て当たりを押す。見た目の名前（.hit）に頼らせない。
  row.dataset.role = "hit";
  if (title) row.title = title;

  const where = document.createElement("span");
  where.className = "where";
  where.textContent = oneLine(hit.title);

  const excerpt = document.createElement("span");
  excerpt.className = "excerpt";
  excerpt.textContent = oneLine(hit.excerpt);

  row.append(where, excerpt);
  row.addEventListener("click", (event) => open(event.metaKey || event.ctrlKey));
  if (menu) {
    row.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      menu(event);
    });
  }
  return row;
}
