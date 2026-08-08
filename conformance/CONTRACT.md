# 実装間の契約

実装が同じ振る舞いをすることを、機械的に確かめるための取り決め。
いまは macOS 版（Swift）、Windows 版（Rust）、Windows 版（C#）の 3 つがある。

3 つは独立して書かれており、XML の解析も ZIP の読み出しも正規表現も別物である。
どれかが誤ったときに残り 2 つが同じ誤り方をすることは考えにくい、
というのがこの突き合わせの拠り所になっている。

C# 版は Tauri へ移ったときに一度畳んだが、Windows での Tauri の具合を受けて戻した。
経緯は spikes/findings-windows.md にある。

## 揃えるもの

入力から出力が一意に決まる部分だけを対象とする。

- EPUB のパース結果（読み順、目次の階層、href の正規化結果、書誌情報、レイアウト種別、綴じ方向）
- 相対パスの解決規則
- CSS 互換レイヤーの変換結果と変更内訳
- 章から取り出す本文と、その中でコードが占める範囲（head・script・style は本文に混ぜない）
- 検索のヒット位置、件数、順序、章の中での通し番号（`nth`）
- 検索結果から飛んだ先で、どの語をどこで囲むか
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
<probe> probe mark    <epub> <href> <query> [nth]
<probe> probe detect  <file>
```

`style` が受け取る設定。欠けているキーは既定値で補う。

```json
{"fontSizePercent": 100, "lineHeight": 1.8, "maxWidthEm": 42, "theme": "light",
 "bodyFont": "", "codeFont": "SF Mono", "codeWrap": false, "publisherStyle": false}
```

`mark` は囲んだ HTML を丸ごと比べない。実装ごとの細部で偽の差分が出るためである。
囲んだ語（`marked`）と、その直前にある本文（`before`、元の HTML から最大 20 文字）で示す。
置いた場所が同じかどうかは、これで分かる。囲めなかったときは `found` を偽にし、
`marked` と `before` は出さない。

`preview` は整形の細部ではなく、切り出した範囲を揃える。
出力の `text` は抜粋からタグとスタイルを除いたもので、注入した CSS は含めない。

各実装の実体は次のとおり。起動方法は `conformance/probes.json` に書く。

```
macos/build/ChoroReader.app/Contents/MacOS/ChoroReader probe parse foo.epub
tauri/target/release/choroprobe probe parse foo.epub
dotnet windows/ChoroReader.Probe/bin/Debug/net10.0/choroprobe.dll probe parse foo.epub
```

## 正規化の規約

比較で偽の差分を出さないため、プローブ側で次を済ませてから出力する。

- **文字の数え方**：位置と長さは **Unicode スカラーで数える**。
  書記素クラスタ（結合文字を 1 つに束ねた単位）ではない。
  「か + 濁点」は 2 と数える。Swift の `String` は既定で書記素クラスタを数えるので、
  そのまま書くとここから外れる。
- **重なる当たり**：照合が当たったら **1 スカラーだけ進めて**続きを探す。
  当たった長さのぶん進めると「ままま」から「まま」が 1 件しか出ず、重なりを落とす。
  件数と `nth` の両方が変わるので、走査と印入れは同じ進め方でなければならない。
- **Unicode**：すべての文字列を NFC に正規化する。macOS は分解形を返すことがあり、Windows は合成形を返すため。
- **パス**：区切りは常に `/`。アーカイブ先頭からの相対パスとし、先頭に `/` を付けない。パーセントエンコードは解く。
- **改行**：CSS の出力は `\n` に統一する。
- **小数**：`progression` は小数第 3 位へ丸める。丸め方の差で落ちないようにするため。
  ちょうど半分のときは 0 から遠い側へ寄せる（四捨五入）。
  寄せ方を決めていなかったころ、境目に当たる値が出るまで実装の違いが隠れていた。
- **順序**：`readingOrder` と `tableOfContents` は書籍が定める順のまま。`changes` と診断レポートの配列は辞書順に整列する。
- **値の無いキー**：出力しない。「キーが無い」と「キーがあって null」を揃えないと差になる。

## まだ揃っていないところ

いまは無い。3 実装とも揃っている。

揃っていない箇所が出たときは `conformance/known-differences.json` に事例ごとに載せる。
`choroconf check` と `choroconf diff` はそれを不一致として数えず、差の中身だけを毎回出す。
別々の組に居る実装どうしのときにしか見逃さないので、
同じ組の中で新しく壊れたものは、これまでどおり不一致として落ちる。

上の「文字の数え方」と「重なる当たり」は、C# を 3 つめの実装として並べたときに
食い違いとして現れ、Swift を契約へ寄せて揃えた（`counting` フィクスチャが踏む）。

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

すべての出力に `schema` を含める。現在は `2`。
`2` で検索の当たりに `nth` が加わった。飛んだ先で当たりを強調するとき、
どの当たりを押したのかをこの番号で選び直すため、実装どうしで揃っている必要がある。
出力の意味を変える変更をするときは版数を上げ、ランナーは版数が一致しないことを差分ではなくエラーとして報告する。
