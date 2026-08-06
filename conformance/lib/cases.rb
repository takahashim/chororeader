# frozen_string_literal: true

require "json"

# 実装に投げる検証項目の定義。
# フィクスチャに依らないもの（パス解決、CSS 変換）と、フィクスチャを開くものがある。
module Cases
  module_function

  # 相対パスの解決。仕様の文章だけでは食い違いが出やすいので、境界を明示的に並べる。
  RESOLVE = [
    ["OEBPS/text", "../images/a.png"],
    ["OEBPS/text", "./ch01.xhtml"],
    ["OEBPS/text", "ch01.xhtml"],
    ["OEBPS", "/absolute.xhtml"],
    ["a/b/c", "../../d.xhtml"],
    ["", "../../etc/passwd"],
    ["OEBPS", "text%2Fch01.xhtml"],
    ["OEBPS", "%E7%AC%AC1%E7%AB%A0.xhtml"],
    ["OEBPS/text", "sub//double.xhtml"],
    ["OEBPS/text", ""],
  ].freeze

  CSS_INPUTS = {
    "prefixed-properties" => <<~CSS,
      .v { -epub-writing-mode: vertical-rl; -epub-text-orientation: upright; }
      .h { -epub-hyphens: auto; }
    CSS
    "text-combine" => ".k { -epub-text-combine: horizontal; }\n",
    "comment-and-string" => <<~CSS,
      /* -epub-writing-mode はコメント */
      .a { content: "-epub-writing-mode: horizontal-tb"; }
      .b { -epub-writing-mode: vertical-rl; }
    CSS
    "webkit-untouched" => ".w { -webkit-writing-mode: vertical-rl; }\n",
    "no-change" => "body { margin: 0; }\n",
  }.freeze

  # 表示設定から作る CSS。境界になる組み合わせを並べる。
  STYLES = {
    "default" => {},
    "dark" => { "theme" => "dark" },
    "sepia-large" => { "theme" => "sepia", "fontSizePercent" => 140, "lineHeight" => 2.2 },
    "publisher" => { "publisherStyle" => true, "theme" => "dark" },
    "code-wrap" => { "codeWrap" => true, "codeFont" => "Menlo", "maxWidthEm" => 0 },
    "body-font" => { "bodyFont" => "Hiragino Mincho ProN", "maxWidthEm" => 60 },
  }.freeze

  # 章のテキスト抽出。検索も診断も抜粋もこの結果に乗っている。
  TEXT = {
    "epub3-basic" => ["OEBPS/text/ch01.xhtml"],
    "legacy-css" => ["OEBPS/text/ch01.xhtml"],
    "malformed-xhtml" => ["OEBPS/text/ch01.xhtml"],
    "footnotes" => ["OEBPS/text/ch01.xhtml"],
  }.freeze

  # リンク先の抜粋。脚注と節と、見つからない fragment を見る。
  PREVIEW = {
    "footnotes" => [
      ["OEBPS/text/ch01.xhtml", "fn1"],
      ["OEBPS/text/ch01.xhtml", "sec2"],
      ["OEBPS/text/ch01.xhtml", "no-such-id"],
      ["OEBPS/text/ch01.xhtml", ""],
    ],
    "epub3-basic" => [["OEBPS/text/ch01.xhtml", "sec1"]],
  }.freeze

  # 固定レイアウトの組み立て。ページの種別と見開きの組み方。
  FIXED = { "fixed-layout" => [0, 1, 4], "epub3-basic" => [0] }.freeze

  SEARCH = {
    # 「章」は 1 つの章に 2 度出る。章の中での通し番号（nth）が揃うことは、
    # これのように同じ章で複数当たる問い合わせでしか確かめられない。
    "epub3-basic" => ["本文", "hello", "章"],
    "legacy-css" => ["本文"],
    "encoded-paths" => ["ファイル名"],
    # 同じ章が読み順に 2 度出る。通し番号を読み順の項目ごとに数え直しているかを見る。
    "repeated-spine" => ["語"],
  }.freeze

  # 検索結果から飛んだ先で、どの語をどこで囲むか。
  # 同じ章に何度も出る語、実体参照を挟むもの、全角と半角の違いを見る。
  MARK = {
    "epub3-basic" => [
      ["OEBPS/text/ch01.xhtml", "章", 0],
      ["OEBPS/text/ch01.xhtml", "章", 1],
      ["OEBPS/text/ch01.xhtml", "本文", 0],
      ["OEBPS/text/ch01.xhtml", "出てこない語", 0],
    ],
    "legacy-css" => [["OEBPS/text/ch01.xhtml", "本文", 0]],
    "footnotes" => [["OEBPS/text/ch01.xhtml", "脚注", 0]],
    "encoded-paths" => [["OEBPS/text/第1章.xhtml", "ファイル名", 0]],
    # 同じ章が読み順に二度出る書籍。番号は読み順の項目ごとに数え直す。
    "repeated-spine" => [["OEBPS/text/ch01.xhtml", "語", 1]],
  }.freeze

  # フィクスチャ 1 つにつき parse と report を取る。
  def for_fixture(name)
    cases = [
      { id: "parse/#{name}", args: ["parse", :fixture] },
      { id: "report/#{name}", args: ["report", :fixture] },
      { id: "detect/#{name}", args: ["detect", :fixture] },
    ]
    (SEARCH[name] || []).each do |query|
      cases << { id: "search/#{name}/#{query}", args: ["search", :fixture, query] }
    end
    (MARK[name] || []).each do |href, query, nth|
      cases << { id: "mark/#{name}/#{query}/#{nth}",
                 args: ["mark", :fixture, href, query, nth] }
    end
    (TEXT[name] || []).each do |href|
      cases << { id: "text/#{name}/#{File.basename(href)}", args: ["text", :fixture, href] }
    end
    (PREVIEW[name] || []).each do |href, fragment|
      label = fragment.empty? ? "(先頭)" : fragment
      cases << { id: "preview/#{name}/#{label}", args: ["preview", :fixture, href, fragment] }
    end
    (FIXED[name] || []).each do |page|
      cases << { id: "fixed/#{name}/#{page}", args: ["fixed", :fixture, page] }
    end
    cases
  end

  def global
    cases = RESOLVE.map do |base, href|
      { id: "resolve/#{base.empty? ? '(root)' : base}/#{href.empty? ? '(empty)' : href}",
        args: ["resolve", base, href] }
    end
    CSS_INPUTS.each do |id, css|
      cases << { id: "css/#{id}", args: ["css"], stdin: css }
    end
    STYLES.each do |id, settings|
      cases << { id: "style/#{id}", args: ["style"], stdin: JSON.generate(settings) }
    end
    cases
  end
end
