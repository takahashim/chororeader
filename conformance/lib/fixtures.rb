# frozen_string_literal: true

require "zip"
require "fileutils"
require "zlib"

# 実装差が出やすい箇所を狙った合成 EPUB を組み立てる。
# 実書籍は再配布できないため、エッジケースはここで作って git に入れる。
module Fixtures
  module_function

  def build_all(dir)
    FileUtils.mkdir_p(dir)
    builders.each do |name, builder|
      path = File.join(dir, "#{name}.epub")
      File.delete(path) if File.exist?(path)
      builder.call(path)
    end
    builders.keys
  end

  def builders
    {
      "epub3-basic" => method(:epub3_basic),
      "epub2-ncx" => method(:epub2_ncx),
      "legacy-css" => method(:legacy_css),
      "encoded-paths" => method(:encoded_paths),
      "broken-refs" => method(:broken_refs),
      "malformed-xhtml" => method(:malformed_xhtml),
      "nonlinear-spine" => method(:nonlinear_spine),
      "fixed-layout" => method(:fixed_layout),
      "rtl" => method(:rtl),
      "footnotes" => method(:footnotes),
    }
  end

  # 脚注と章内リンク。移動せずに中身を見せる仕掛けの検証対象。
  def footnotes(path)
    body = <<~BODY
      <h1 id="top">第 1 章</h1>
      <p>本文の途中に脚注がある<a id="ref1" href="#fn1" epub:type="noteref">1</a>。</p>
      <p>さらに<a href="#sec2">後の節</a>への参照もある。</p>
      <h2 id="sec2">1.2 後の節</h2>
      <p>ここが参照先の節である。</p>
      <p>節の 2 段落目。</p>
      <aside id="fn1" epub:type="footnote"><p>これは脚注の中身です。</p></aside>
    BODY

    chapter = <<~XHTML
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja">
      <head><title>第 1 章</title><link rel="stylesheet" type="text/css" href="../style/book.css"/></head>
      <body>#{body}</body>
      </html>
    XHTML

    write_epub(path,
               "META-INF/container.xml" => container,
               "OEBPS/content.opf" => simple_opf("脚注のある書籍", "footnotes"),
               "OEBPS/nav.xhtml" => simple_nav,
               "OEBPS/style/book.css" => "body { margin: 0; }\n",
               "OEBPS/text/ch01.xhtml" => chapter)
  end

  # --- 書き出しの下ごしらえ ---

  # mimetype は先頭に無圧縮で置く決まりになっている。この順序と圧縮方式も検証対象。
  def write_epub(path, entries)
    Zip::File.open(path, create: true) do |zip|
      zip.get_output_stream("mimetype", compression_method: Zip::COMPRESSION_METHOD_STORE) do |io|
        io.write("application/epub+zip")
      end
      entries.each do |name, content|
        zip.get_output_stream(name) { |io| io.write(content) }
      end
    end
  end

  def container(opf_path = "OEBPS/content.opf")
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
          <rootfile full-path="#{opf_path}" media-type="application/oebps-package+xml"/>
        </rootfiles>
      </container>
    XML
  end

  def chapter(title, body)
    <<~XHTML
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">
      <head><title>#{title}</title><link rel="stylesheet" type="text/css" href="../style/book.css"/></head>
      <body>#{body}</body>
      </html>
    XHTML
  end

  # 単色の PNG を組み立てる。
  # 依存を増やさないため、stdlib の Zlib だけで最小限のチャンクを書く。
  # ページ画像は目で見て区別できる必要があるので、ページごとに色を変えて使う。
  def png(width = 1, height = 1, rgb = [0, 0, 0])
    row = "\x00".b + (rgb.pack("C3") * width)
    idat = Zlib::Deflate.deflate(row * height)
    ihdr = [width, height].pack("N2") + [8, 2, 0, 0, 0].pack("C5")

    "\x89PNG\r\n\x1a\n".b + png_chunk("IHDR", ihdr) + png_chunk("IDAT", idat) + png_chunk("IEND", "".b)
  end

  def png_chunk(type, data)
    body = type.b + data.b
    [data.bytesize].pack("N") + body + [Zlib.crc32(body)].pack("N")
  end

  # ページごとに見分けがつく色。見開きの並びや送り方向を目で確かめるために使う。
  PAGE_COLORS = [
    [220, 232, 244], [244, 226, 220], [226, 244, 224],
    [240, 236, 214], [232, 222, 244], [244, 240, 230],
  ].freeze

  # --- 個々のフィクスチャ ---

  def epub3_basic(path)
    opf = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>基本の書籍</dc:title>
          <dc:creator>山田 太郎</dc:creator>
          <dc:language>ja</dc:language>
          <dc:identifier id="pub-id">urn:uuid:epub3-basic</dc:identifier>
        </metadata>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="cover-img" href="images/cover.png" media-type="image/png" properties="cover-image"/>
          <item id="css" href="style/book.css" media-type="text/css"/>
          <item id="c1" href="text/ch01.xhtml" media-type="application/xhtml+xml"/>
          <item id="c2" href="text/ch02.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine>
          <itemref idref="c1"/>
          <itemref idref="c2"/>
        </spine>
      </package>
    XML

    nav = <<~XHTML
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>目次</title></head>
      <body>
        <nav epub:type="toc">
          <ol>
            <li><a href="text/ch01.xhtml">第 1 章</a>
              <ol><li><a href="text/ch01.xhtml#sec1">1.1 節</a></li></ol>
            </li>
            <li><a href="text/ch02.xhtml">第 2 章</a></li>
          </ol>
        </nav>
      </body>
      </html>
    XHTML

    write_epub(path,
               "META-INF/container.xml" => container,
               "OEBPS/content.opf" => opf,
               "OEBPS/nav.xhtml" => nav,
               "OEBPS/style/book.css" => "body { line-height: 1.7; }\n",
               "OEBPS/images/cover.png" => png,
               "OEBPS/text/ch01.xhtml" => chapter("第 1 章", <<~BODY),
                 <h1>第 1 章</h1><p id="sec1">本文です。</p>
                 <pre><code>puts "hello"</code></pre>
                 <p><img src="../images/cover.png" alt="表紙"/></p>
               BODY
               "OEBPS/text/ch02.xhtml" => chapter("第 2 章", "<h1>第 2 章</h1><p>続きの本文です。</p>"))
  end

  def epub2_ncx(path)
    opf = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="pub-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
          <dc:title>EPUB2 の書籍</dc:title>
          <dc:language>ja</dc:language>
          <dc:identifier id="pub-id">urn:uuid:epub2-ncx</dc:identifier>
          <meta name="cover" content="cover-img"/>
        </metadata>
        <manifest>
          <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          <item id="cover-img" href="images/cover.png" media-type="image/png"/>
          <item id="css" href="style/book.css" media-type="text/css"/>
          <item id="c1" href="text/ch01.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine toc="ncx">
          <itemref idref="c1"/>
        </spine>
      </package>
    XML

    ncx = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head><meta name="dtb:uid" content="urn:uuid:epub2-ncx"/></head>
        <docTitle><text>EPUB2 の書籍</text></docTitle>
        <navMap>
          <navPoint id="np1" playOrder="1">
            <navLabel><text>第 1 章</text></navLabel>
            <content src="text/ch01.xhtml"/>
            <navPoint id="np1-1" playOrder="2">
              <navLabel><text>1.1 節</text></navLabel>
              <content src="text/ch01.xhtml#sec1"/>
            </navPoint>
          </navPoint>
        </navMap>
      </ncx>
    XML

    write_epub(path,
               "META-INF/container.xml" => container,
               "OEBPS/content.opf" => opf,
               "OEBPS/toc.ncx" => ncx,
               "OEBPS/images/cover.png" => png,
               "OEBPS/style/book.css" => "body { margin: 0; }\n",
               "OEBPS/text/ch01.xhtml" => chapter("第 1 章", '<h1>第 1 章</h1><p id="sec1">本文。</p>'))
  end

  # -epub- プレフィックスと非 UTF-8 の CSS。互換レイヤーの中心的な検証対象。
  def legacy_css(path)
    css = <<~CSS
      /* -epub-writing-mode はコメントなので変えない */
      .v { -epub-writing-mode: vertical-rl; -epub-text-orientation: upright; }
      .k { -epub-text-combine: horizontal; }
      .w { -webkit-writing-mode: vertical-rl; }
      .s::after { content: "-epub-hyphens: auto"; }
      .h { -epub-hyphens: auto; }
    CSS

    sjis_css = "/* 日本語のコメント */\n.a { color: #333; }\n".encode("Shift_JIS")

    opf = simple_opf("旧記法の書籍", "legacy-css", extra_manifest: <<~ITEMS)
      <item id="css2" href="style/sjis.css" media-type="text/css"/>
    ITEMS

    write_epub(path,
               "META-INF/container.xml" => container,
               "OEBPS/content.opf" => opf,
               "OEBPS/nav.xhtml" => simple_nav,
               "OEBPS/style/book.css" => css,
               "OEBPS/style/sjis.css" => sjis_css,
               "OEBPS/text/ch01.xhtml" => chapter("第 1 章", <<~BODY))
                 <style>.inline { -epub-writing-mode: vertical-rl; }</style>
                 <p>本文に -epub-writing-mode と書いてあっても変えない。</p>
               BODY
  end

  # パーセントエンコードされた href と、日本語のファイル名。
  def encoded_paths(path)
    opf = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>符号化されたパス</dc:title>
          <dc:language>ja</dc:language>
          <dc:identifier id="pub-id">urn:uuid:encoded-paths</dc:identifier>
        </metadata>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="css" href="style/book.css" media-type="text/css"/>
          <item id="c1" href="text/%E7%AC%AC1%E7%AB%A0.xhtml" media-type="application/xhtml+xml"/>
          <item id="c2" href="text/second%20chapter.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
      </package>
    XML

    nav = <<~XHTML
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>目次</title></head>
      <body><nav epub:type="toc"><ol>
        <li><a href="text/%E7%AC%AC1%E7%AB%A0.xhtml">第 1 章</a></li>
        <li><a href="text/second%20chapter.xhtml">Second</a></li>
      </ol></nav></body></html>
    XHTML

    write_epub(path,
               "META-INF/container.xml" => container,
               "OEBPS/content.opf" => opf,
               "OEBPS/nav.xhtml" => nav,
               "OEBPS/style/book.css" => "body { margin: 0; }\n",
               "OEBPS/text/第1章.xhtml" => chapter("第 1 章", "<p>日本語のファイル名。</p>"),
               "OEBPS/text/second chapter.xhtml" => chapter("Second", "<p>空白を含むファイル名。</p>"))
  end

  # 参照先が存在しない画像と、目次が指す先が無い項目。診断レポートの検証対象。
  def broken_refs(path)
    nav = <<~XHTML
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>目次</title></head>
      <body><nav epub:type="toc"><ol>
        <li><a href="text/ch01.xhtml">第 1 章</a></li>
        <li><a href="text/missing.xhtml">存在しない章</a></li>
      </ol></nav></body></html>
    XHTML

    write_epub(path,
               "META-INF/container.xml" => container,
               "OEBPS/content.opf" => simple_opf("参照の壊れた書籍", "broken-refs"),
               "OEBPS/nav.xhtml" => nav,
               "OEBPS/style/book.css" => "body { margin: 0; }\n",
               "OEBPS/text/ch01.xhtml" => chapter("第 1 章", <<~BODY))
                 <p><img src="../images/none.png" alt="無い画像"/></p>
                 <p><a href="https://example.com/">外部リンク</a></p>
               BODY
  end

  # XML として通らない章。text/html へ落として表示を続けられるかの検証対象。
  def malformed_xhtml(path)
    broken = <<~HTML
      <!DOCTYPE html>
      <html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"><title>壊れた章</title></head>
      <body><p>閉じていない段落<br>と、閉じていない meta。</body></html>
    HTML

    write_epub(path,
               "META-INF/container.xml" => container,
               "OEBPS/content.opf" => simple_opf("壊れた XHTML", "malformed-xhtml"),
               "OEBPS/nav.xhtml" => simple_nav,
               "OEBPS/style/book.css" => "body { margin: 0; }\n",
               "OEBPS/text/ch01.xhtml" => broken)
  end

  # linear="no" の項目は読み順から外し、目次からは開けるままにする。
  def nonlinear_spine(path)
    opf = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>補助ページのある書籍</dc:title>
          <dc:language>ja</dc:language>
          <dc:identifier id="pub-id">urn:uuid:nonlinear</dc:identifier>
        </metadata>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="css" href="style/book.css" media-type="text/css"/>
          <item id="c1" href="text/ch01.xhtml" media-type="application/xhtml+xml"/>
          <item id="aux" href="text/aux.xhtml" media-type="application/xhtml+xml"/>
          <item id="c2" href="text/ch02.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine>
          <itemref idref="c1"/>
          <itemref idref="aux" linear="no"/>
          <itemref idref="c2"/>
        </spine>
      </package>
    XML

    nav = <<~XHTML
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>目次</title></head>
      <body><nav epub:type="toc"><ol>
        <li><a href="text/ch01.xhtml">第 1 章</a></li>
        <li><a href="text/aux.xhtml">付録</a></li>
        <li><a href="text/ch02.xhtml">第 2 章</a></li>
      </ol></nav></body></html>
    XHTML

    write_epub(path,
               "META-INF/container.xml" => container,
               "OEBPS/content.opf" => opf,
               "OEBPS/nav.xhtml" => nav,
               "OEBPS/style/book.css" => "body { margin: 0; }\n",
               "OEBPS/text/ch01.xhtml" => chapter("第 1 章", "<p>本文。</p>"),
               "OEBPS/text/aux.xhtml" => chapter("付録", "<p>補助ページ。</p>"),
               "OEBPS/text/ch02.xhtml" => chapter("第 2 章", "<p>本文。</p>"))
  end

  # ページが画像になっている固定レイアウト。見開きの組み方や送り方向の検証対象。
  def fixed_layout(path)
    count = 5
    manifest = (1..count).map do |i|
      n = format("%03d", i)
      "<item id=\"p#{i}\" href=\"text/p#{n}.xhtml\" media-type=\"application/xhtml+xml\"/>" \
        "<item id=\"img#{i}\" href=\"images/p#{n}.png\" media-type=\"image/png\"/>"
    end.join("\n          ")
    spine = (1..count).map { |i| "<itemref idref=\"p#{i}\"/>" }.join

    opf = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>固定レイアウトの書籍</dc:title>
          <dc:language>ja</dc:language>
          <dc:identifier id="pub-id">urn:uuid:fixed</dc:identifier>
          <meta property="rendition:layout">pre-paginated</meta>
        </metadata>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          #{manifest}
        </manifest>
        <spine>#{spine}</spine>
      </package>
    XML

    entries = {
      "META-INF/container.xml" => container,
      "OEBPS/content.opf" => opf,
      "OEBPS/nav.xhtml" => simple_nav("text/p001.xhtml", "1 ページ"),
    }
    (1..count).each do |i|
      n = format("%03d", i)
      entries["OEBPS/text/p#{n}.xhtml"] = <<~XHTML
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>#{i}</title><meta name="viewport" content="width=1200, height=1700"/></head>
        <body style="margin:0"><img src="../images/p#{n}.png" alt=""/></body>
        </html>
      XHTML
      entries["OEBPS/images/p#{n}.png"] = png(600, 850, PAGE_COLORS[(i - 1) % PAGE_COLORS.size])
    end

    write_epub(path, entries)
  end

  def rtl(path)
    opf = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>右開きの書籍</dc:title>
          <dc:language>ja</dc:language>
          <dc:identifier id="pub-id">urn:uuid:rtl</dc:identifier>
        </metadata>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="css" href="style/book.css" media-type="text/css"/>
          <item id="c1" href="text/ch01.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine page-progression-direction="rtl"><itemref idref="c1"/></spine>
      </package>
    XML

    write_epub(path,
               "META-INF/container.xml" => container,
               "OEBPS/content.opf" => opf,
               "OEBPS/nav.xhtml" => simple_nav,
               "OEBPS/style/book.css" => "body { -epub-writing-mode: vertical-rl; }\n",
               "OEBPS/text/ch01.xhtml" => chapter("第 1 章", "<p>縦書きの本文。</p>"))
  end

  # --- 共通部品 ---

  def simple_opf(title, id, extra_manifest: "")
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>#{title}</dc:title>
          <dc:language>ja</dc:language>
          <dc:identifier id="pub-id">urn:uuid:#{id}</dc:identifier>
        </metadata>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="css" href="style/book.css" media-type="text/css"/>
          <item id="c1" href="text/ch01.xhtml" media-type="application/xhtml+xml"/>
          #{extra_manifest}
        </manifest>
        <spine><itemref idref="c1"/></spine>
      </package>
    XML
  end

  def simple_nav(href = "text/ch01.xhtml", label = "第 1 章")
    <<~XHTML
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>目次</title></head>
      <body><nav epub:type="toc"><ol><li><a href="#{href}">#{label}</a></li></ol></nav></body></html>
    XHTML
  end
end
