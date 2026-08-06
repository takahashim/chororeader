#!/usr/bin/env ruby
# frozen_string_literal: true

# アプリのアイコンを、原画から各プラットフォームの形に焼き直す。
#
# 出来上がりは git に入れ、macOS 版と Tauri 版のそれぞれが読む場所へ置く。
# 原画を差し替えたいときだけこれを走らせる。CI では走らせない（ImageMagick が要るため）。
#
#   ruby assets/icon/build.rb
#
# 原画が 2 枚あるのは、角の扱いが場所によって違うからである。
# macOS は角を丸めてくれないので、丸めた絵をこちらで用意する。
# Windows のタイルは四角い枠に収まるので、角を落とさない絵を使う。

require "fileutils"
require "tmpdir"

SRC = __dir__
ROOT = File.expand_path("../..", __dir__)
ROUNDED = File.join(SRC, "rounded-1024.png")
SQUARE = File.join(SRC, "square-1024.png")

def run(*command)
  system(*command, exception: true)
end

def magick(*args)
  run("magick", *args)
end

abort "ImageMagick が要る（brew install imagemagick）" unless system("which magick > /dev/null 2>&1")
[ROUNDED, SQUARE].each { |f| abort "原画が無い: #{f}" unless File.exist?(f) }

# --- macOS のアイコン -----------------------------------------------------
#
# macOS の絵は、1024 の画布いっぱいには描かない。
# Apple の下敷きでは角丸の四角が 824 角で、周りに余白が空く。
# 縁まで塗ると、Dock で他のアプリより一回り大きく見える。

ICNS_SIZES = {
  "icon_16x16" => 16, "icon_16x16@2x" => 32,
  "icon_32x32" => 32, "icon_32x32@2x" => 64,
  "icon_128x128" => 128, "icon_128x128@2x" => 256,
  "icon_256x256" => 256, "icon_256x256@2x" => 512,
  "icon_512x512" => 512, "icon_512x512@2x" => 1024
}.freeze

def build_icns(destination)
  Dir.mktmpdir do |tmp|
    inset = File.join(tmp, "inset.png")
    magick(ROUNDED, "-resize", "824x824",
           "-background", "none", "-gravity", "center", "-extent", "1024x1024", inset)

    iconset = File.join(tmp, "icon.iconset")
    FileUtils.mkdir_p(iconset)
    ICNS_SIZES.each do |name, size|
      magick(inset, "-resize", "#{size}x#{size}", File.join(iconset, "#{name}.png"))
    end

    FileUtils.mkdir_p(File.dirname(destination))
    run("iconutil", "-c", "icns", iconset, "-o", destination)
  end
end

# --- 書き出し先 -----------------------------------------------------------

TAURI = File.join(ROOT, "tauri/app/icons")
# app を組み立てるときに Contents/Resources へ写す。実行中に読むものではないので、
# SwiftPM の資源には入れない。
MACOS_ICNS = File.join(ROOT, "macos/ChoroReader.icns")

# 角を丸めた絵を使うもの。窓やタスクバーに 1 枚で出る。
ROUNDED_PNGS = {
  "32x32.png" => 32,
  "128x128.png" => 128,
  "128x128@2x.png" => 256,
  "icon.png" => 512
}.freeze

# Windows のタイル。四角い枠に収まるので角を落とさない。
SQUARE_PNGS = {
  "Square30x30Logo.png" => 30, "Square44x44Logo.png" => 44,
  "Square71x71Logo.png" => 71, "Square89x89Logo.png" => 89,
  "Square107x107Logo.png" => 107, "Square142x142Logo.png" => 142,
  "Square150x150Logo.png" => 150, "Square284x284Logo.png" => 284,
  "Square310x310Logo.png" => 310, "StoreLogo.png" => 50
}.freeze

FileUtils.mkdir_p(TAURI)

ROUNDED_PNGS.each do |name, size|
  magick(ROUNDED, "-resize", "#{size}x#{size}", File.join(TAURI, name))
end

SQUARE_PNGS.each do |name, size|
  magick(SQUARE, "-resize", "#{size}x#{size}", File.join(TAURI, name))
end

# Windows の .ico は 1 枚に複数の大きさを畳んで持つ。
# 16 から 256 まで入れておかないと、大きな表示で拡大された 32 が出る。
magick(SQUARE, "-define", "icon:auto-resize=256,128,64,48,32,16", File.join(TAURI, "icon.ico"))

build_icns(File.join(TAURI, "icon.icns"))
build_icns(MACOS_ICNS)

puts "アイコンを書き出した:"
puts "  #{TAURI}/ （16 個）"
puts "  #{MACOS_ICNS}"
