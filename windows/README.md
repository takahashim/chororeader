# Windows 実装（C#）

Core と Probe を実装済み。UI は未着手。
スパイクの結果は [../spikes/findings-windows.md](../spikes/findings-windows.md)。

**この実装は一度畳み、戻した。**
Windows 版は Tauri（Rust）へ移したが、Windows での具合が芳しくないため C# へ戻すことを検討している。
いまは契約の 3 つ目の相手として置いてある。戻すかどうかはまだ決めていない。
畳んだ経緯と、戻すときに合わせた差分は findings-windows.md にある。

```sh
cd windows
dotnet build ChoroReader.Probe/ChoroReader.Probe.csproj

cd ../conformance
cp probes.example.json probes.json   # パスを自分の環境に合わせる
./choroconf check csharp                # 期待値との照合
./choroconf diff swift csharp           # 2 実装の突き合わせ
```

仕様は [../spec.md](../spec.md)、実装間の契約は [../conformance/CONTRACT.md](../conformance/CONTRACT.md)。

## コードは共有しない

macOS 版と Windows 版は別々に実装する。
共有するのはコードではなく、仕様と契約と検証用の期待値である。

共通コアを 1 つ置く案は検討して見送った。
共有できる範囲（EPUB パース、Locator、CSS 変換、検索）は言語非依存だが小さく、
そのために FFI 境界とクロスコンパイルを抱えるより、各プラットフォームで最も素直な標準部品を使うほうが短く済む。
macOS では XMLDocument と PDFKit が、Windows では System.IO.Compression と System.Xml.Linq がそれぞれ馴染む形で使える。

## 構成

UI と、UI に依存しないコアを分ける。

```
windows/
├── ChoroReader.Core/     クラスライブラリ。UI に依存しない（EPUB パース、Locator、CSS 変換、検索、診断）
├── ChoroReader.Probe/    コンソールアプリ。probe CLI の実体。Core を参照する
├── ChoroReader.Tests/    Core の検査（xunit）。conformance で見えないものを置く
└── ChoroReader.App/      Windows 専用の UI（WinUI 3 など）。Core を参照する
```

`ChoroReader.Tests` は、実装間の突き合わせでは見えないものを受け持つ。
突き合わせは probe を 1 回ずつ呼んで出力を比べるので、
並行して呼んだときに壊れるかどうかや、閉じたあとに触ったときの振る舞いは映らない。

```sh
dotnet test ChoroReader.Tests/ChoroReader.Tests.csproj
```

**この分け方には実利がある。** .NET は macOS でも動くため、Core と Probe は macOS 上でビルドして実行できる。
つまり Windows マシンを用意しなくても、開発機の Mac で次が回る。

```sh
cd conformance
cp probes.example.json probes.json
./choroconf diff swift csharp                 # 合成フィクスチャで突き合わせ
./choroconf diff swift csharp 手元の本.epub   # 実書籍で突き合わせ
```

Core が Windows 専用 API（WinUI、Win32）に触れると、この検証が Windows でしか回らなくなる。
Core と Probe の TargetFramework は `net10.0` のままにし、`net10.0-windows` にしない。

## .NET のバージョン

**.NET 10（LTS）を使う。**
.NET 8 も LTS だが、サポートが 2026 年 11 月に終わる。新しく始める土台としては残りが短い。
.NET 9 は STS で、すでにサポートが終わっている。

UI（ChoroReader.App）は Windows App SDK に合わせた TFM（`net10.0-windows10.0.x`）になる。
その組み合わせは、UI へ着手する時点の Windows App SDK の対応状況を見て決める。

## PDF の扱い

**MuPDF を使う。** .NET からは [MuPDFCore](https://github.com/arklumpus/MuPDFCore) 経由で呼ぶ。
描画は WPF のネイティブなビューへ行い、WebView2 には載せない。
macOS 版が PDFKit を AppKit のビューで使っているのと同じ形になる。

選んだ理由。

- 描画とテキストの両方を 1 つのライブラリで賄える。Core（妥当性判定、アウトライン、テキスト、検索）と UI（描画）が同じ土台に乗る
- 選択に必要な部品が揃っている。`GetHitAddress` が座標から文字を特定し、`GetHighlightQuads` が文字範囲をハイライト用の矩形へまとめる。自作するのはマウス操作の受け取りと矩形の描画だけで済む
- `MuPDFCore.NativeAssets.Mac-arm64` があるため macOS でもビルドできる。開発機で `choroconf diff` を回す条件が守れる
- OCR（Tesseract）に対応しているので、仕様 第 3 段階のスキャン PDF の検索が後から安く載る

見送った案。

- **WebView2 内蔵の PDF ビューア**：現在ページを取れず読書位置を保存できない。アウトラインも検索結果一覧もサムネイルも作れない
- **PDF.js**：テキスト選択が標準で効く利点はあるが、描画性能が落ち、Core 側に別のライブラリが要る（2 スタックになる）
- **Windows.Data.Pdf**：描画のみでテキストが取れない

承知しておくこと。

- **AGPL**：配布する場合、MuPDF とリンクした Windows 版全体が AGPL になる。リポジトリ全体を AGPL-3.0 にするかは未決（macOS 版は MuPDF を使わないため、理屈の上では分けられる）
- Windows の利用者に MSVC 再頒布可能パッケージが要る
- MuPDF のブロック順は描画順であって読み順とは限らない。多段組の PDF では座標で並べ替える
- アウトライン取得の API は着手時にドキュメントで確認する

この選択は変えうる。描画性能や選択の実装が問題になれば、PDF.js への差し替えを検討する。
その影響は UI に閉じるよう、Core は MuPDF の型を外へ漏らさない設計にしておく。

## 実装の順序

1. ~~Probe の骨組み~~（済）
2. ~~`probe resolve` と `probe css`~~（済）
3. ~~`probe parse`~~（済）
4. ~~`probe detect` と `probe report`~~（済）
5. ~~`probe search`~~（済）
6. ~~WebView2 のスパイク~~（済。前提は成り立つ。[../spikes/findings-windows.md](../spikes/findings-windows.md)）
7. ~~`probe mark`~~（済。`./choroconf check csharp` が 90 件通る）
8. ~~PDF を 1 冊ずつ直列に読む~~（済。MuPDF の context は同時に触ると壊れる）
9. ~~検索の索引~~（済。二字組の転置索引。39 万字・86 章の書籍で 151 KB、作るのに 107 ms）
10. UI（ChoroReader.App）。EPUB のリソースは独自スキームではなく、`https://choro.invalid/` への
    要求を `WebResourceRequested` で横取りして配る（独自スキームは登録できなかった）

まだ無いもの。Rust 版にはあり、UI を作る段で要る。

- PDF の当たりの矩形（`PageHit` に当たる部分）。いまはページ番号と抜粋だけ
- 蔵書の横断検索。索引の上に乗るので、次に着手できる
- 蔵書と読書位置の保存。保存先が UI の方針に依るため保留

各段階で `./choroconf diff swift csharp` を回すと、食い違いがその場で出る。
実際、この突き合わせは macOS 版の目次の不具合を 1 件見つけた（findings-windows.md）。

## 踏みやすいところ

CONTRACT.md の「正規化の規約」に書いてあるが、特に次の 3 点で差が出る。

- **Unicode の正規化形**：macOS のファイルシステムは分解形（NFD）を返すことがある。出力前に NFC へ揃える（C# なら `string.Normalize(NormalizationForm.FormC)`）
- **パス区切り**：Windows で `Path.Combine` を使うと `\` になる。EPUB 内のパスは常に `/` で扱う
- **小数の丸め**：`progression` は小数第 3 位へ丸める。ちょうど半分のときは 0 から遠い側へ寄せる（`MidpointRounding.AwayFromZero`）
- **照合の畳み方**：`CompareInfo`（ICU）に任せない。`Fold` を自分で持つ。
  当たりには章の中での通し番号（`nth`）が付くので、どこを何番目と数えるかまで揃っている必要がある。
  ICU では次に探し始める位置が他の実装とずれ、重なりを持つ語で番号が食い違う
- **文字の数え方**：本文の位置は Unicode スカラーで数える。`string.Length`（UTF-16 の単位数）ではない
