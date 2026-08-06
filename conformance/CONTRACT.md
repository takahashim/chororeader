# 実装間の契約

実装が同じ振る舞いをすることを、機械的に確かめるための取り決め。
いまは macOS 版（Swift）と Windows 版（Rust）の 2 つがある。

Swift と Rust は独立して書かれており、XML の解析も ZIP の読み出しも正規表現も別物である。
両方が同じ誤り方をすることは考えにくい、というのがこの突き合わせの拠り所になっている。

## 揃えるもの

入力から出力が一意に決まる部分だけを対象とする。

- EPUB のパース結果（読み順、目次の階層、href の正規化結果、書誌情報、レイアウト種別、綴じ方向）
- 相対パスの解決規則
- CSS 互換レイヤーの変換結果と変更内訳
- 章から取り出す本文と、その中でコードが占める範囲
- 検索のヒット位置、件数、順序
- 形式判定とエラーの分類
- 書籍の診断レポート
- 表示設定から作る CSS
- リンク先の抜粋として、どこを切り出すか
- 固定レイアウトのページ種別と、見開きの組み方

## 揃えないもの

- 本文のレンダリング結果（WKWebView とシステムの WebView は別物である）
- 性能の数値
- UI の見た目とウィンドウ管理
- エラーの表示文言（分類名だけを揃える）

## プローブ

各実装は、次の CLI を提供する。
出力は UTF-8 の JSON 1 個だけを標準出力へ書き、終了コード 0 で終わる。
引数が足りないなど呼び出し側の誤りは終了コード 2 とし、標準エラーへ出す。

```
<probe> probe version
<probe> probe parse   <epub>
<probe> probe report  <epub>
<probe> probe text    <epub> <href>
<probe> probe preview <epub> <href> [fragment]
<probe> probe fixed   <epub> [ページ番号]
<probe> probe resolve <base> <href>
<probe> probe css                     # 標準入力から CSS を受け取る
<probe> probe style                   # 標準入力から表示設定を JSON で受け取る
<probe> probe search  <epub> <query>
<probe> probe detect  <file>
```

`style` が受け取る設定。欠けているキーは既定値で補う。

```json
{"fontSizePercent": 100, "lineHeight": 1.8, "maxWidthEm": 42, "theme": "light",
 "bodyFont": "", "codeFont": "SF Mono", "codeWrap": false, "publisherStyle": false}
```

`preview` は整形の細部ではなく、切り出した範囲を揃える。
出力の `text` は抜粋からタグとスタイルを除いたもので、注入した CSS は含めない。

各実装の実体は次のとおり。起動方法は `conformance/probes.json` に書く。

```
macos/build/ChoroReader.app/Contents/MacOS/ChoroReader probe parse foo.epub
tauri/target/release/choroprobe probe parse foo.epub
```

## 正規化の規約

比較で偽の差分を出さないため、プローブ側で次を済ませてから出力する。

- **Unicode**：すべての文字列を NFC に正規化する。macOS は分解形を返すことがあり、Windows は合成形を返すため。
- **パス**：区切りは常に `/`。アーカイブ先頭からの相対パスとし、先頭に `/` を付けない。パーセントエンコードは解く。
- **改行**：CSS の出力は `\n` に統一する。
- **小数**：`progression` は小数第 3 位へ丸める。丸め方の差で落ちないようにするため。
- **順序**：`readingOrder` と `tableOfContents` は書籍が定める順のまま。`changes` と診断レポートの配列は辞書順に整列する。
- **値の無いキー**：出力しない。「キーが無い」と「キーがあって null」を揃えないと差になる。

## エラーの分類

`error.kind` に次のいずれかを入れる。文言は実装ごとに自由でよい。

| kind | 意味 |
| --- | --- |
| `unsupportedFormat` | 拡張子から対応形式と判定できない |
| `brokenArchive` | ZIP として読めない |
| `missingContainer` | `META-INF/container.xml` が無い、または rootfile を取り出せない |
| `missingOPF` | container が指す OPF がアーカイブに無い |
| `cannotParseOPF` | OPF を解析できない |
| `emptySpine` | spine に linear な項目が 1 つも無い |
| `cannotOpenPDF` | PDF として開けない |

## スキーマ版数

すべての出力に `schema` を含める。現在は `1`。
出力の意味を変える変更をするときは版数を上げ、ランナーは版数が一致しないことを差分ではなくエラーとして報告する。
