//! MuPDF の Rust バインディングが、Windows 版の要求を満たすかを確かめる。
//!
//! 見るのは C# の MuPDFCore で確かめたのと同じ 4 点。
//! ビルドの重さ、目次の取得、テキストの抽出、ページの描画である。
//! 加えて、描いた結果を WebView へ渡すときに要る符号化の費用も測る。

use std::time::Instant;

fn main() {
    let mut args = std::env::args().skip(1);
    let path = match args.next() {
        Some(path) => path,
        None => {
            eprintln!("usage: rust-mupdf-spike <pdf> [検索語]");
            std::process::exit(2);
        }
    };
    let needle = args.next().unwrap_or_else(|| "型".to_string());

    if let Err(error) = run(&path, &needle) {
        eprintln!("失敗: {error}");
        std::process::exit(1);
    }
}

fn run(path: &str, needle: &str) -> Result<(), Box<dyn std::error::Error>> {
    // 1 回目にはネイティブライブラリの初期化が混ざる。2 回目が 1 冊あたりの費用。
    let first = Instant::now();
    {
        let warm = mupdf::Document::open(path)?;
        let _ = warm.page_count()?;
    }
    let first = first.elapsed();

    let opened = Instant::now();
    let document = mupdf::Document::open(path)?;
    let page_count = document.page_count()?;
    let opened = opened.elapsed();
    println!(
        "開く: 1 回目 {} ms / 2 回目 {} ms  ページ数: {page_count}",
        first.as_millis(),
        opened.as_millis()
    );

    // 目次
    let outline = document.outlines()?;
    println!("目次: 第 1 階層 {} 項目", outline.len());
    for item in outline.iter().take(6) {
        println!("   {}  [p.{}]", item.title, item.page.unwrap_or(0) + 1);
        for child in item.down.iter().take(2) {
            println!("     {}  [p.{}]", child.title, child.page.unwrap_or(0) + 1);
        }
    }

    // テキスト抽出
    let index = (page_count - 1).min(10);
    let page = document.load_page(index)?;
    let extracted = Instant::now();
    let text = page.to_text()?;
    let extracted = extracted.elapsed();
    let sample: String = text.replace('\n', " ").chars().take(80).collect();
    println!("本文抽出: {} ms  {sample}", extracted.as_millis());

    // 検索
    let searched = Instant::now();
    let mut hits = 0;
    for i in 0..page_count.min(20) {
        let page = document.load_page(i)?;
        hits += page.search(needle, 20)?.len();
    }
    let searched = searched.elapsed();
    println!(
        "検索「{needle}」: 先頭 20 ページで {hits} 件  {} ms",
        searched.as_millis()
    );

    // 文字ごとの位置。PDF.js が既製で持っている「選択できるテキスト層」を
    // MuPDF で自前に作れるかどうかは、ここが取れるかで決まる。
    let structured = Instant::now();
    let text_page = page.to_text_page(mupdf::TextPageOptions::empty())?;
    let mut chars = 0;
    let mut sample = Vec::new();
    let mut vertical = 0;
    let mut lines = 0;
    for block in text_page.blocks() {
        for line in block.lines() {
            lines += 1;
            if line.wmode() == mupdf::WriteMode::Vertical {
                vertical += 1;
            }
            for ch in line.chars() {
                chars += 1;
                if sample.len() < 4 {
                    if let Some(c) = ch.char() {
                        let q = ch.quad();
                        sample.push(format!(
                            "{c}({:.0},{:.0})-({:.0},{:.0})",
                            q.ul.x, q.ul.y, q.lr.x, q.lr.y
                        ));
                    }
                }
            }
        }
    }
    println!(
        "文字ごとの位置: {} ms  {lines} 行 {chars} 文字（縦書きの行 {vertical}）  {}",
        structured.elapsed().as_millis(),
        sample.join(" ")
    );

    // 描画。WebView へ渡すことを想定して、符号化までの費用を分けて測る。
    let matrix = mupdf::Matrix::new_scale(1.5, 1.5);
    let rendered = Instant::now();
    let pixmap = page.to_pixmap(&matrix, &mupdf::Colorspace::device_rgb(), false, true)?;
    let rendered = rendered.elapsed();

    let encoded = Instant::now();
    let mut png = Vec::new();
    pixmap.write_to(&mut png, mupdf::ImageFormat::PNG)?;
    let encoded = encoded.elapsed();

    println!(
        "描画: {} ms  {}x{}  生データ {} バイト",
        rendered.as_millis(),
        pixmap.width(),
        pixmap.height(),
        pixmap.samples().len()
    );
    println!(
        "PNG 符号化: {} ms  {} バイト（WebView へ渡すときに要る手間）",
        encoded.as_millis(),
        png.len()
    );

    Ok(())
}
