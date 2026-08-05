# frozen_string_literal: true

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

  SEARCH = {
    "epub3-basic" => ["本文", "hello"],
    "legacy-css" => ["本文"],
    "encoded-paths" => ["ファイル名"],
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
    cases
  end
end
