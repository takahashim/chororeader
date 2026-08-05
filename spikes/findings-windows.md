# Windows 実装のスパイク結果

実施日：2026-08-05
環境：Apple Silicon Mac（macOS 26 / arm64）、.NET 10.0.302

Windows 実装（C#）に着手する前に、判断の土台になる不明点を確かめた。
UI に依存しない部分は macOS 上で検証できるため、Windows 機を用意せずにここまで進めた。

## 結論

- **実装間の契約は機能する。** C# の Core と Probe を書き、`tzconf check csharp` が 49 件すべて一致した。
  `tzconf diff swift csharp` も、合成フィクスチャと手元の実書籍 2 冊で完全に一致する。
- **突き合わせは実バグを見つけた。** macOS 版の目次に、語が繋がる不具合があった（後述）。
- **MuPDF は Windows 版の PDF に足りている。** 描画、テキスト抽出、目次、検索のいずれも実用的な速さで動く。
- **WebView2 の検証だけは Windows 機が要る。** ここは未実施のまま残る。

## スパイク 1：C# 実装と契約の突き合わせ（windows/）

`TZReader.Core`（UI 非依存のクラスライブラリ）と `TZReader.Probe`（コンソールアプリ）を作り、
契約（conformance/CONTRACT.md）の 7 コマンドを実装した。

実装した範囲は、ZIP の読み出し（`System.IO.Compression`）、OPF と目次の解析（`System.Xml.Linq`）、
CSS 互換レイヤー、本文とコードの抽出、検索、書籍の診断レポート、形式判定である。

```
$ ./tzconf check csharp
csharp: 49 件すべて一致しました

$ ./tzconf diff swift csharp
swift ↔ csharp: 49 件すべて一致しました
```

**.NET が macOS で動くことの利点は実証された。** 2 実装の突き合わせが開発機だけで完結する。

### 揃えるのに手当てが要った点

- **null の扱い**：macOS 版の JSONEncoder は nil のプロパティを出力しない。
  C# 側は明示的な null を出していたため、比較で 20 件が差になった。出力前に null のキーを落として解決した。
- **符号化**：Shift_JIS は .NET では既定で使えない。`System.Text.Encoding.CodePages` を登録する。
- **全角半角の非区別**：`CompareOptions.IgnoreWidth` で macOS 版の `.widthInsensitive` と揃う。
  照合した範囲の長さは、全角半角で変わりうるので元の文字列側で数え直す必要がある。

### 突き合わせが見つけた macOS 版のバグ

実書籍（技術評論社『関数プログラミング実践入門』）で 1 件だけ食い違った。

```
tableOfContents[193].title:
  期待 "Column　場合分けの構文糖衣──実は、全部case"
  実際 "Column　場合分けの構文糖衣 ──実は、全部case"
```

元の目次はこうなっている。

```html
<a ...>Column　<strong>場合分けの構文糖衣</strong> <span class="small">──実は、全部case</span></a>
```

`</strong>` と `<span>` の間に空白があり、**C# 側が正しく、macOS 版が空白を落としていた**。

原因は Foundation の `XMLDocument` が、要素間の空白だけのテキストノードを捨てることである。
`.nodePreserveWhitespace` を付けても戻らないことを実験で確かめた。

| 解析手段 | 結果 |
| --- | --- |
| XMLDocument（既定） | `Column　糖衣──実は`（空白が落ちる） |
| XMLDocument + nodePreserveWhitespace | 同上 |
| XMLDocument の xmlString | 解析時点で既に空白が無い |
| XMLParser（SAX） | `Column　糖衣 ──実は`（正しい） |

macOS 版の目次解析を SAX（`XMLParser`）へ置き換えて解決した（`macos/Sources/TZReader/Document/TOCParser.swift`）。

**これは実装間の突き合わせでしか見つからない種類の不具合である。**
片方だけを見ていても「そういうものだ」と流れてしまう。

## スパイク 2：MuPDF（MuPDFCore）

`MuPDFCore` 2.0.1（MuPDF 1.25.2 ベース）を macOS arm64 で動かした。
検証には『n月刊ラムダノート Vol.4 No.3』（98 ページ、テキスト層あり）を使った。

| 項目 | 結果 |
| --- | --- |
| 開く | 1 回目 19 ms（ネイティブライブラリの読み込み込み）、2 回目 0 ms |
| 目次 | 27 項目を階層とページ番号つきで取得。macOS 版（PDFKit）と同数 |
| テキスト層の判定 | 正しく「あり」 |
| 本文抽出 | 10 ms／ページ。日本語も正しい |
| 検索 | 20 件を 11 ms（正規表現で照合） |
| 描画 | 1.5 倍で 72 ms、420x595pt のページ |

判定：**PDF は MuPDF で進める。**

確認できた API は次のとおりで、当初の不明点は解消した。

- `MuPDFDocument.Outline`（着手前に未確認だった目次の取得）→ `MuPDFOutlineItem` に `Title` と `PageNumber` と `Children`
- `GetStructuredTextPage` → ブロック、行、文字。文字は `BoundingQuad` を持つ
- `Search(Regex)` → ヒット範囲。`GetHighlightQuads` でハイライト用の矩形へ変換できる
- `GetHitAddress` / `GetClosestHitAddress` → 座標から文字を特定。テキスト選択の当たり判定に使える
- `Render` → ページのラスタライズ

### 実装時に効く注意点

- **ブロックの順は描画順であって読み順ではない。** 段組の書籍で抽出順が崩れるため、
  座標（Y0、X0）で並べ替えてから連結する。この処理は今回の実装にも入れてある
- MuPDF は解析上の警告を標準エラーへ書く（`invalid marked content and clip nesting` など）。
  Probe は標準出力に JSON だけを書く決まりなので影響は無いが、アプリ側ではログへ回す
- 初回呼び出しにネイティブライブラリの読み込みが乗る。起動直後の 1 冊目だけ僅かに遅い

## スパイク 3：WebView2 の前提（用意済み、実行待ち）

確かめる問いは、macOS 版でスパイク 4 として確かめたのと同じである。

> 書籍由来の JavaScript を止めたまま、アプリが注入したスクリプトとメッセージは動くか。

macOS では成立した。Windows で崩れると、スクロール位置の通知、コードのコピーボタン、
章末の行き先、位置復元、暗いテーマでの文字色の当て先の判定を、別の手段へ置き換える必要がある。

**検証プログラムは書き終えている**（`windows/TZReader.WebViewSpike/`）。
見ているのは 5 点で、独自スキームでの配信、書籍側 script の抑止、注入スクリプトの実行、
`postMessage` の到達、`ExecuteScriptAsync` の可否である。

### 実行はまだできていない

WebView2 は Windows でしか動かない。ただし次の 2 点は済ませてある。

- **macOS でコンパイルは通る。** `EnableWindowsTargeting` を立てることで、型と API の誤りは
  開発機で潰せた。CI へ出す前の空振りを減らせる
- **CI で自動実行できる形にした。** `.github/workflows/ci.yml` の `webview2-spike` ジョブが
  windows-latest 上でこれを走らせる。判定は終了コードで返るので、通れば緑、崩れれば赤になる

**リポジトリを GitHub へ push すれば、Windows 機を用意せずに答えが出る。**
ランナーで GUI コンポーネントを作れるか、WebView2 ランタイムが入っているかは、実際に走らせるまで
確実とは言えない。作れなかった場合は、ローカルの Windows 仮想機で同じプログラムを動かす。

結果が出たら、この節に判定と数値を追記する。
