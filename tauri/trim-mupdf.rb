#!/usr/bin/env ruby
# frozen_string_literal: true

# Windows のビルドから OCR（tesseract と leptonica）を外す。
#
# chororeader は OCR を使わない。にもかかわらず Windows では毎回コンパイルされる。
# mupdf-sys の機能指定は Make のときだけ効き、MSBuild では何もしないためである
# （build.rs の Build::make_bool を見よ）。
# libmupdf.vcxproj が無条件に両者を参照しているので、そこを外す。
#
# 冷えた状態の Windows ビルドは 24 分かかり、その相当部分がこれである。
# upstream を直すのが本筋だが、手元で完結させたいのでここで削る。
#
#   ruby tauri/trim-mupdf.rb
#
# 何度実行してもよい。当てる先が見つからないときは、黙って通さずに失敗する。
# 版が上がって形が変われば気付けるようにするためである。

require "json"

TARGETS = %w[libtesseract libleptonica].freeze
DEFINES = %w[HAVE_TESSERACT HAVE_LEPTONICA].freeze

# 置き場所は cargo に聞く。
#
# 登録先の経路を自分で組み立てて探すと、CARGO_HOME の置き方や OS の違いで外れる。
# 実際 Windows の CI で見つけられなかった。
# cargo metadata は解決のためにソースを展開するので、置き場所を答えられる状態にもなる。
def registry_roots
  manifest = File.expand_path("Cargo.toml", __dir__)
  out = IO.popen(["cargo", "metadata", "--format-version", "1",
                  "--manifest-path", manifest], &:read)
  abort("cargo metadata を実行できませんでした") unless $?.success?

  JSON.parse(out)["packages"]
      .select { |pkg| pkg["name"] == "mupdf-sys" }
      .map { |pkg| File.dirname(pkg["manifest_path"]) }
      .select { |dir| Dir.exist?(dir) }
end

def patch(path)
  before = File.read(path)
  after = before.dup

  # ページの参照を丸ごと落とす。これで msbuild が作りに行かなくなる。
  TARGETS.each do |name|
    after = after.gsub(
      %r{[ \t]*<ProjectReference Include="#{name}\.vcxproj">.*?</ProjectReference>\s*\n}m, ""
    )
  end

  # 定義も外す。残すと MuPDF 側が呼び出しを持ったままになり、繋がらなくなる。
  DEFINES.each { |name| after = after.gsub("#{name};", "") }

  return :done if after == before

  File.write(path, after)
  :patched
end

def check(path)
  text = File.read(path)
  left = TARGETS.count { |n| text.include?("#{n}.vcxproj\">") } +
         DEFINES.count { |n| text.include?("#{n};") }
  left.zero?
end

roots = registry_roots
abort("依存に mupdf-sys がありません。") if roots.empty?

touched = 0
roots.each do |root|
  path = File.join(root, "mupdf", "platform", "win32", "libmupdf.vcxproj")
  unless File.exist?(path)
    warn "見当たらないので飛ばします: #{path}"
    next
  end

  result = patch(path)
  abort("削り切れていません: #{path}") unless check(path)

  puts format("%-8s %s", result == :patched ? "削った" : "済み", root.split("/").last)
  touched += 1
end

abort("当てる先が 1 つもありませんでした。mupdf-sys の版が変わった可能性があります。") if touched.zero?
puts "Windows のビルドから OCR を外しました（#{touched} か所）"
