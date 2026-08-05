# Tauri 版

Rust と OS 標準の WebView で作る実装。Windows を主対象にするが、コードは OS に依らない。

いまあるのは UI に触れない部分だけである。

```
tauri/
├── core/    書籍を読むための中身（EPUB の解析、CSS 互換、抽出、検索、診断、PDF）
└── probe/   実装間の突き合わせに使う CLI
```

## なぜ先に core を作ったか

Tauri へ移るかどうかは、画面が動くかどうかでは決まらない。
macOS 版（Swift）と Windows 版（C#）が同じ振る舞いをすることは、
`conformance/` の 68 件で機械的に確かめられる状態になっている。
Rust 版がその 68 件を同じように通るなら、少なくとも画面の外側は移せたと言える。
通らないうちに UI を書き始めると、どこがずれているのか分からなくなる。

いまは 3 実装すべてが同じ値を返す。

```
swift ↔ rust: 68 件すべて一致しました
csharp ↔ rust: 68 件すべて一致しました
```

## 動かし方

```sh
cargo build --release
cargo test --release

# 契約との照合（conformance/probes.json に rust を登録してある）
cd ../conformance
bundle exec ./tzconf check rust
bundle exec ./tzconf diff swift rust
```

## 移してみて分かったこと

- **ZIP の項目名は UTF-8 として読む**。`zip` クレートは UTF-8 のフラグが立っていない項目を
  CP437 として解くが、そのフラグを立てない道具（rubyzip など）は珍しくなく、
  日本語のファイル名が化ける。Swift 版も C# 版も UTF-8 で読んでいる。
- **本文の位置は Unicode スカラーで数える**。C# 版は UTF-16 の符号単位、Swift 版は書記素で数えており、
  基本多言語面の文字しか出てこないあいだは 3 つとも一致する。
- **正規表現に先読みが無い**。C# 版の `(?=\s*:)` は、区切りを取り込んで書き戻す形に置き換えた。
- **抜粋は木から書き戻さず、元の断片をそのまま切る**。空白や実体参照の書き方が変わらないため、
  C# の `XElement.ToString` より素直に一致する。

## まだ無いもの

画面。EPUB ナビゲータ、PDF の表示、複数ウィンドウ、しおり、設定。
`spikes/tauri-spike/` に、独自スキームでの配信と iframe の sandbox、
MuPDF の描画を確かめた最小のアプリがある。
