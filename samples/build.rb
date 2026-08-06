#!/usr/bin/env ruby
# frozen_string_literal: true

# 動作確認に使うサンプル書籍を作る。
#
# 書籍を 1 冊も持たないマシンでも、アプリ単体で読み方と機能を確かめられるようにする。
# 出来上がりは git に入れ、アプリへ埋め込む。作り直したいときだけこれを走らせる。
#
#   ruby samples/build.rb
#
# 3 形式そろえてあるのは、表示の経路がそれぞれ別だからである。
# リフロー型は本文の iframe、固定レイアウトと PDF は紙面の器を通る。

require "zlib"
require "fileutils"

OUT = File.expand_path(__dir__)

# --- ZIP を書く -----------------------------------------------------------
#
# 依存を増やさないため、格納と deflate だけの最小限の書き出しを自前で持つ。
# mimetype は無圧縮で先頭に置くという決まりがあり、そこも自分で面倒を見る。

class Zip
  Entry = Struct.new(:name, :data, :stored, :offset, :crc, :compressed)

  def initialize
    @entries = []
  end

  def add(name, data, stored: false)
    @entries << Entry.new(name, data.b, stored)
  end

  def write(path)
    body = +"".b
    @entries.each do |entry|
      entry.offset = body.bytesize
      entry.crc = Zlib.crc32(entry.data)
      entry.compressed = entry.stored ? entry.data : deflate(entry.data)
      body << local_header(entry) << entry.compressed
    end

    directory_offset = body.bytesize
    directory = +"".b
    @entries.each { |entry| directory << central_header(entry) }
    body << directory
    body << end_record(@entries.size, directory.bytesize, directory_offset)
    File.binwrite(path, body)
  end

  private

  # Zlib の生 deflate。ZIP はヘッダを持たない形を求める。
  def deflate(data)
    Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS).deflate(data, Zlib::FINISH)
  end

  def method_of(entry) = entry.stored ? 0 : 8

  def local_header(entry)
    ["PK\x03\x04".b, 20, 0, method_of(entry), 0, 0, entry.crc,
     entry.compressed.bytesize, entry.data.bytesize, entry.name.bytesize, 0]
      .pack("a4vvvvvVVVvv") + entry.name.b
  end

  def central_header(entry)
    ["PK\x01\x02".b, 20, 20, 0, method_of(entry), 0, 0, entry.crc,
     entry.compressed.bytesize, entry.data.bytesize, entry.name.bytesize,
     0, 0, 0, 0, 0, entry.offset].pack("a4vvvvvvVVVvvvvvVV") + entry.name.b
  end

  def end_record(count, size, offset)
    ["PK\x05\x06".b, 0, 0, count, count, size, offset, 0].pack("a4vvvvVVv")
  end
end

# --- PNG を書く -----------------------------------------------------------
#
# 固定レイアウトのページに置く単色の絵。ページごとに色を変え、並びを目で追えるようにする。

def png(width, height, rgb)
  row = "\x00".b + (rgb.pack("C3") * width)
  ihdr = [width, height].pack("N2") + [8, 2, 0, 0, 0].pack("C5")
  idat = Zlib::Deflate.deflate(row * height)
  "\x89PNG\r\n\x1a\n".b + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", "".b)
end

def chunk(type, data)
  body = type.b + data.b
  [data.bytesize].pack("N") + body + [Zlib.crc32(body)].pack("N")
end

# --- リフロー型 EPUB ------------------------------------------------------

def reflowable(path)
  css = <<~CSS
    body { margin: 0 1em; line-height: 1.8; }
    h1 { background: #1a1a1a; color: #fff; padding: 0.4em 0.6em; font-size: 1.4em; }
    h2 { border-left: 6px solid #0b5cad; padding-left: 0.5em; }
    pre { background: #f4f4f6; padding: 0.8em 1em; overflow-x: auto; }
    .note { font-size: 0.9em; color: #555; }
    /* 古い書き方をわざと混ぜてある。互換レイヤーが働くかを見るため。 */
    .vertical { -epub-writing-mode: vertical-rl; }
  CSS

  chapters = {
    "OEBPS/text/ch01.xhtml" => chapter("第 1 章　読む", <<~BODY),
      <h1 id="top">第 1 章　読む</h1>
      <p>これは chororeader の動作を確かめるためのサンプルです。上下に送ると本文が動き、
      左右に送ると章が変わります。縦は読む軸、横は移動する軸という決まりです。</p>
      <h2 id="code">コードの塊</h2>
      <p>次の塊にカーソルを重ねると、右上にコピーの押しボタンが出ます。</p>
      <pre>def greet(name)
        puts "こんにちは、\#{name}"
      end

      greet("世界")</pre>
      <h2 id="link">章をまたぐ参照</h2>
      <p><a href="ch02.xhtml#deep">第 2 章の節</a>への参照です。押すと抜粋が出ます。
      抜粋からは移動も、新しいウィンドウで開くこともできます。</p>
      <p>脚注もあります<a id="ref1" href="#fn1" epub:type="noteref">1</a>。</p>
      <aside id="fn1" epub:type="footnote"><p class="note">これが脚注の中身です。
      移動せずにここだけを読めます。</p></aside>
    BODY

    "OEBPS/text/ch02.xhtml" => chapter("第 2 章　探す", <<~BODY),
      <h1>第 2 章　探す</h1>
      <p>道具帯の検索欄に「サンプル」と入れると、この書籍の中を探します。
      結果を押すとその場所へ飛び、右クリックすると新しいウィンドウで開けます。</p>
      <h2 id="deep">深いところの節</h2>
      <p>ここが第 1 章から参照されている場所です。目次からもここへ来られます。</p>
      <p>図版もあります。押すと大きく出ます。</p>
      <p><img src="../images/figure.png" alt="サンプルの図" width="240"/></p>
    BODY

    "OEBPS/text/ch03.xhtml" => chapter("第 3 章　しるしを付ける", <<~BODY),
      <h1>第 3 章　しるしを付ける</h1>
      <p>しおりを付けると、次に開いたときここへ戻ります。
      文字の大きさを変えても同じ段落へ戻るはずです。</p>
      <p class="vertical">この段落には古い書き方の縦組み指定が入れてあります。</p>
      <p>これで最後の章です。</p>
    BODY
  }

  nav = <<~XHTML
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head><title>目次</title></head>
    <body><nav epub:type="toc"><ol>
      <li><a href="text/ch01.xhtml">第 1 章　読む</a>
        <ol>
          <li><a href="text/ch01.xhtml#code">コードの塊</a></li>
          <li><a href="text/ch01.xhtml#link">章をまたぐ参照</a></li>
        </ol>
      </li>
      <li><a href="text/ch02.xhtml">第 2 章　探す</a>
        <ol><li><a href="text/ch02.xhtml#deep">深いところの節</a></li></ol>
      </li>
      <li><a href="text/ch03.xhtml">第 3 章　しるしを付ける</a></li>
    </ol></nav></body></html>
  XHTML

  opf = package("サンプル書籍（リフロー型）", "reflowable", <<~ITEMS, <<~SPINE)
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="style/book.css" media-type="text/css"/>
    <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>
    <item id="fig" href="images/figure.png" media-type="image/png"/>
    <item id="c1" href="text/ch01.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch02.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="text/ch03.xhtml" media-type="application/xhtml+xml"/>
  ITEMS
    <itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/>
  SPINE

  zip = Zip.new
  zip.add("mimetype", "application/epub+zip", stored: true)
  zip.add("META-INF/container.xml", container)
  zip.add("OEBPS/content.opf", opf)
  zip.add("OEBPS/nav.xhtml", nav)
  zip.add("OEBPS/style/book.css", css)
  zip.add("OEBPS/images/cover.png", png(120, 170, [26, 92, 173]))
  zip.add("OEBPS/images/figure.png", png(80, 60, [11, 92, 173]))
  chapters.each { |name, body| zip.add(name, body) }
  zip.write(path)
end

# --- 固定レイアウト EPUB --------------------------------------------------

def fixed(path)
  colors = [[220, 232, 244], [244, 226, 220], [226, 244, 224], [240, 236, 214]]

  pages = colors.each_with_index.map do |rgb, index|
    [<<~XHTML, png(600, 850, rgb)]
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml">
      <head><title>#{index + 1} ページ</title>
      <meta name="viewport" content="width=600, height=850"/></head>
      <body style="margin:0"><img src="../images/p#{index + 1}.png" alt="#{index + 1} ページ" width="600" height="850"/></body>
      </html>
    XHTML
  end

  # 絵ではなく文字を置いたページ。種別の見分けが働くかを見るために混ぜてある。
  text_page = <<~XHTML
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>5 ページ</title><meta name="viewport" content="width=600, height=850"/></head>
    <body style="margin:0;font-family:sans-serif">
      <div style="position:absolute;left:60px;top:120px;font-size:28px">固定レイアウトのサンプル</div>
      <div style="position:absolute;left:60px;top:200px;font-size:16px;line-height:1.9">
        このページだけは絵ではなく文字を座標で置いてあります。<br/>
        絵 1 枚のページと違う扱いになることを確かめられます。
      </div>
    </body></html>
  XHTML

  items = pages.each_index.map do |i|
    %(<item id="p#{i + 1}" href="text/p#{i + 1}.xhtml" media-type="application/xhtml+xml"/>\n) +
      %(<item id="i#{i + 1}" href="images/p#{i + 1}.png" media-type="image/png"/>)
  end.join("\n")
  items += %(\n<item id="p5" href="text/p5.xhtml" media-type="application/xhtml+xml"/>)
  items += %(\n<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>)

  spine = (1..5).map { |i| %(<itemref idref="p#{i}"/>) }.join

  nav = <<~XHTML
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head><title>目次</title></head>
    <body><nav epub:type="toc"><ol>
      #{(1..5).map { |i| %(<li><a href="text/p#{i}.xhtml">#{i} ページ</a></li>) }.join("\n  ")}
    </ol></nav></body></html>
  XHTML

  opf = package("サンプル書籍（固定レイアウト）", "fixed", items, spine, fixed: true)

  zip = Zip.new
  zip.add("mimetype", "application/epub+zip", stored: true)
  zip.add("META-INF/container.xml", container)
  zip.add("OEBPS/content.opf", opf)
  zip.add("OEBPS/nav.xhtml", nav)
  pages.each_with_index do |(xhtml, image), index|
    zip.add("OEBPS/text/p#{index + 1}.xhtml", xhtml)
    zip.add("OEBPS/images/p#{index + 1}.png", image)
  end
  zip.add("OEBPS/text/p5.xhtml", text_page)
  zip.write(path)
end

# --- 共通の部品 -----------------------------------------------------------

def chapter(title, body)
  <<~XHTML
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja">
    <head><title>#{title}</title>
    <link rel="stylesheet" type="text/css" href="../style/book.css"/></head>
    <body>#{body}</body>
    </html>
  XHTML
end

def container
  <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
  XML
end

def package(title, id, items, spine, fixed: false)
  layout = fixed ? %(<meta property="rendition:layout">pre-paginated</meta>) : ""
  <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>#{title}</dc:title>
        <dc:creator>chororeader</dc:creator>
        <dc:language>ja</dc:language>
        <dc:identifier id="pub-id">urn:uuid:chororeader-sample-#{id}</dc:identifier>
        #{layout}
      </metadata>
      <manifest>
        #{items}
      </manifest>
      <spine>#{spine}</spine>
    </package>
  XML
end

# --- PDF ------------------------------------------------------------------
#
# 目次と複数ページとテキスト層を持つ最小の PDF を自前で書く。
# 日本語を出すには字体を埋め込む必要があり、それだけで数メガになる。
# ここで確かめたいのは描画と送りと目次と検索なので、標準の字体で足りる。

def pdf(path)
  pages = [
    ["Sample PDF - Page 1", "This is a sample document for chororeader.",
     "Use the arrow keys to turn pages."],
    ["Sample PDF - Page 2", "Search for the word sample to see hits.",
     "The outline on the left jumps between pages."],
    ["Sample PDF - Page 3", "Zoom with Cmd +, Cmd - and Cmd 0.",
     "Try the spread layout from the toolbar."],
    ["Sample PDF - Page 4", "The page list shows small previews.",
     "Bookmarks remember where you stopped."],
  ]

  objects = []
  add = ->(body) { objects << body; objects.size }

  font = add.call("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

  content_ids = pages.map do |title, *lines|
    stream = +"BT /F1 22 Tf 60 760 Td (#{title}) Tj ET\n"
    lines.each_with_index do |line, i|
      stream << "BT /F1 13 Tf 60 #{710 - i * 26} Td (#{line}) Tj ET\n"
    end
    stream << "0.05 0.36 0.68 rg 60 120 480 240 re f\n"
    add.call("<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream")
  end

  pages_id = objects.size + pages.size + 1
  page_ids = content_ids.map do |content|
    add.call("<< /Type /Page /Parent #{pages_id} 0 R /MediaBox [0 0 595 842] " \
             "/Resources << /Font << /F1 #{font} 0 R >> >> /Contents #{content} 0 R >>")
  end
  add.call("<< /Type /Pages /Kids [#{page_ids.map { |i| "#{i} 0 R" }.join(' ')}] /Count #{page_ids.size} >>")

  # 目次の項目は、この時点の次の番号から順に並ぶ。目次そのものはその後ろに置く。
  # 番号を数え間違えると参照が繋がらず、目次が空のまま出る。
  first_item = objects.size + 1
  outlines_id = first_item + page_ids.size
  item_ids = page_ids.each_with_index.map do |page, index|
    id = first_item + index
    links = +""
    links << " /Prev #{id - 1} 0 R" if index.positive?
    links << " /Next #{id + 1} 0 R" if index < page_ids.size - 1
    add.call("<< /Title (Page #{index + 1}) /Parent #{outlines_id} 0 R#{links} " \
             "/Dest [#{page} 0 R /Fit] >>")
  end
  add.call("<< /Type /Outlines /First #{item_ids.first} 0 R /Last #{item_ids.last} 0 R " \
           "/Count #{item_ids.size} >>")
  catalog = add.call("<< /Type /Catalog /Pages #{pages_id} 0 R /Outlines #{outlines_id} 0 R " \
                     "/PageMode /UseOutlines >>")

  body = +"%PDF-1.4\n"
  offsets = objects.each_with_index.map do |object, index|
    offset = body.bytesize
    body << "#{index + 1} 0 obj\n#{object}\nendobj\n"
    offset
  end

  xref_offset = body.bytesize
  body << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
  offsets.each { |offset| body << format("%010d 00000 n \n", offset) }
  body << "trailer\n<< /Size #{objects.size + 1} /Root #{catalog} 0 R >>\n"
  body << "startxref\n#{xref_offset}\n%%EOF\n"
  File.binwrite(path, body)
end

# --- 書き出し -------------------------------------------------------------

FileUtils.mkdir_p(OUT)
reflowable(File.join(OUT, "sample-reflowable.epub"))
fixed(File.join(OUT, "sample-fixed.epub"))
pdf(File.join(OUT, "sample.pdf"))

Dir[File.join(OUT, "sample*.{epub,pdf}")].sort.each do |file|
  puts format("%-28s %6d バイト", File.basename(file), File.size(file))
end
