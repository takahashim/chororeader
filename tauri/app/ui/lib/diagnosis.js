// 書籍の診断を、人が読む文字にする。
//
// 数を並べるだけなので、画面も土台も要らない。
// 出す先（帯に短く / クリップボードに詳しく）は呼ぶ側が決める。

/// 帯に出す 1 行ずつの要約。
export function summary(report) {
  return [
    `章 ${report.spineCount} / 目次 ${report.tocEntryCount}（深さ ${report.tocMaxDepth}）`,
    `CSS ${report.cssFileCount}（旧記法 ${report.legacyCSSFileCount}）`,
    `XHTML ${report.xhtmlCount}（不正 ${report.malformedXHTMLCount}）`,
    `画像 ${report.imageCount} / フォント ${report.fontCount}`,
    "欠落: "
      + `リソース ${report.missingResources.length} / `
      + `目次 ${report.missingTOCTargets.length} / `
      + `章 ${report.missingSpineItems.length}`,
  ];
}

/// 書き写すための詳しい形。目で見るだけでは写せないので、名前まで並べる。
export function detail(title, report) {
  const list = (label, items) => (items.length ? `${label}:\n  ${items.join("\n  ")}` : "");
  return [
    `書籍: ${title}`,
    ...summary(report),
    list("欠落リソース", report.missingResources),
    list("欠落した目次の参照先", report.missingTOCTargets),
    list("欠落した章", report.missingSpineItems),
    list("CSS の変換", report.cssChanges.map((c) => `${c.from} → ${c.to} (${c.count})`)),
  ].filter(Boolean).join("\n");
}
