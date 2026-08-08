# Windows 実装（C#）

Core と Probe と検査に加えて、UI（WPF）も一通り動く。
書棚から本を開き、EPUB と PDF を読み、目次と検索から飛び、位置を覚えるところまで。
スパイクの結果は [../spikes/findings-windows.md](../spikes/findings-windows.md)。

```sh
cd windows
# 引数なしで書棚が開く。同梱の見本が並ぶので、書籍を持たないマシンでも試せる
dotnet run --project ChoroReader.App/ChoroReader.App.csproj

dotnet run --project ChoroReader.App/ChoroReader.App.csproj -- 本.epub   # 1 冊開く
dotnet run --project ChoroReader.App/ChoroReader.App.csproj -- --shelf 本.epub 紙.pdf
dotnet run --project ChoroReader.App/ChoroReader.App.csproj -- 本.epub --selftest
```

見本（リフロー EPUB・固定レイアウト EPUB・PDF の 3 つ、合わせて 11 KB）は
実行ファイルへ埋め込んである。開く前に LocalAppData の下へ写す。
macOS 版も同じ 3 つを束に入れている（Samples.swift）。

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
└── ChoroReader.App/      Windows 専用の UI（WPF）。Core を参照する
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

Core が Windows 専用 API（WPF、Win32）に触れると、この検証が Windows でしか回らなくなる。
Core と Probe の TargetFramework は `net10.0` のままにし、`net10.0-windows` にしない。

## .NET のバージョン

**.NET 10（LTS）を使う。**
.NET 8 も LTS だが、サポートが 2026 年 11 月に終わる。新しく始める土台としては残りが短い。
.NET 9 は STS で、すでにサポートが終わっている。

UI（ChoroReader.App）は WPF で、TFM は `net10.0-windows` にする。
`EnableWindowsTargeting` を付けて、macOS でもコンパイルだけは通す。
実行は Windows でしかできないが、型と API の誤りを開発機で潰せる（WebViewSpike と同じ手）。

WinUI 3（Windows App SDK）は見送った。
Windows 上なら CLI だけで開発できるようになっている（`dotnet new winui` の公式手順がある）が、
**ビルドそのものが Windows を前提とし、macOS では型検査も通らない。**
「macOS で書いて CI で確かめる」というこのリポジトリの回し方から UI だけが外れることになる。
実行時に Windows App SDK ランタイムが要り、配布も MSIX の作法を抱える。
見た目の差は、.NET 9 から WPF に入った Fluent テーマでかなり詰まっている。

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

## UI の設計

**macOS 版の形を写す。Tauri 版の形は採らない。**
殻（書棚・道具帯・目次・検索）はネイティブの XAML で作り、WebView には入れない。
WebView2 は本文専用で、読書の窓 1 つにつき 1 つ持つ。
PDF は WebView2 に載せず、MuPDF が描いた絵をネイティブのビューに出す（前節）。

```
読書の窓（WPF）                     ← 形式によらず 1 つ
├── 殻：道具帯・目次・検索・設定   ← ネイティブ（XAML）
└── 舞台                            ← ここだけ形式で差し替わる
    ├── リフロー EPUB               ← 専用の WebView2（1 窓 1 文書）
    ├── 固定レイアウト EPUB         ← 同上
    └── PDF                         ← ネイティブ描画（WriteableBitmap）
書棚の窓（WPF）                     ← すべてネイティブ
```

### 画面の組み立て

**読書の窓は形式で分けない。**
道具帯・サイドバー・下辺は形式に依らず同じ場所にあり、舞台の中身だけが差し替わる。
macOS 版（`ReaderView` の `content`）と Tauri 版（`#stage`）がどちらもそうしている。

形式ごとに窓を分けると、目次・検索・しおり・表示設定・位置の表示を形式の数だけ作ることになり、
どれか 1 つに機能を足したときに他が置いていかれる。
実際、一度分けて作った `PdfWindow` には道具帯もサイドバーも無く、
PDF を開いた瞬間に別のアプリのようになっていた。

```
┌ ChoroReader ──────────────────────────────┐
│ ☰ ‹ › │ 書名 — 章名      │ 🔍 ☆ Aa ⧉ 書棚 │  ← 道具帯
├──────────┬────────────────────────────────┤
│ 目次 ページ│                               │
│ 検索 しおり│           舞台                │  ← 形式で差し替わる
│──────────│                                │
│ 第1章     │                               │
│ 第2章     │                               │
├──────────┴────────────────────────────────┤
│ 状態                 ‹ ›            42%   │  ← 下辺
└───────────────────────────────────────────┘
```

| ところ | 出すもの | 形式による違い |
| --- | --- | --- |
| 道具帯 | サイドバーの開閉、戻る/進む、書名と章名、検索欄、しおり、表示設定、新しい窓、書棚 | 検索欄は文字の層が無ければ使えない旨を出す |
| サイドバー | 目次・ページ・検索・しおり | 「ページ」は PDF と固定レイアウトのみ。リフローでは札を出さない |
| 舞台 | 本文または紙面 | ここだけが差し替わる |
| 下辺 | 状態、前後（章／ページ）、位置 | 単位が章か紙面かで言い換える |

macOS 版の「関連」（意味の近い箇所）は、Windows 版にはまだ無い。
意味の索引そのものを持っていないので、札も出さない。

表示設定は道具帯の `Aa` から出す。`ReaderStyle` が持つ 6 項目
（テーマ・文字サイズ・行間・本文幅・コードの折り返し・出版社のスタイル）を並べ、
リフローでないときは効くものだけを出す。
道具帯に直接並べると、リフローでない書籍で意味のない部品が居座る。

**書棚は表紙で並べるのを既定にする。**
一覧（表）へ切り替えられ、引いたときだけ結果の面に差し替わる。
表紙は書籍を開いたときに 1 度だけ取り出して縮小し、LocalAppData の下へ置く
（EPUB は OPF が指す表紙、PDF は 1 ページ目）。
書棚を開くたびに数十メガの EPUB を開き直すわけにはいかない。

Tauri 版が iframe と sandbox と CSP nonce を重ねる作りになったのは、
画面と本文が同じ WebView に同居しているからである。
webview 単位で script を切ると画面ごと死ぬので、枠単位で止めるしかなかった。
C# は WebView2 を直接持てるので、macOS 版と同じ
「本文専用の webview を丸ごと止める」形が取れる。
Tauri 版が Windows で踏んだ不具合（findings-tauri.md）は、ほとんどがこの同居に由来していた。

| Tauri 版が Windows で踏んだもの | この形では |
| --- | --- |
| CSP に `choro:` と書くと何にも当たらない | 消える（配信元が普通の https） |
| `event.origin` が処方どおりにならない | 消える（相手がネイティブ） |
| 焦点が殻と本文を往復して命令が遅れる | 消える（殻に DOM が無い） |
| sandbox の文書でリスナが 1 つも発火しない | **残る。止め方の選び方で避ける（下記）** |
| WebView の呼び返し中に窓を作ると真っ白 | **残る。下の規則で守る** |
| 初期化の同期待ちで永久に待つ | **残る。下の規則で守る** |

### 書籍の script の止め方

spec.md 15.1 の不変条件（書籍の script は走らず、こちらの注入だけが走る）を、層で満たす。
前提は WebView2 のスパイク（findings-windows.md）が毎回確かめる。

1. **CSP で止める。** 配信する本文に `script-src 'none'` を付ける。
   応答は自分で組み立てるのでヘッダを足せる。
   配信元が普通の https なので、スキームの書き方で当たらない事故も起きない。
   ブラウザが強制するので、`<script>` 要素・`on…=` 属性・`javascript:` URL・
   `<svg><script>` という書き方の違いに依らない。
   `AddScriptToExecuteOnDocumentCreated` の注入は CSP の外にあり、そのまま走る

   **エンジンの段（`IsScriptEnabled = false`）では止めない。**
   あれは「その文書に紐づく script を走らせない」という意味で、
   **どの realm が登録したかに依らず**、注入したスクリプトが張ったリスナも発火しない。
   読書はリスナ（スクロール・鍵盤・DOMContentLoaded）の上に成り立っているので、
   ここを切ると本文の中で何も動かない。
   Tauri 版が sandbox で踏んだのと同じ性質で、こちらも一度踏んだ
   （spikes/findings-windows.md）。
   **注入そのものは走るので、同期の便りだけを見ていると気付けない。**
   WebView2 のスパイクは、スクロールを含むリスナ越しの便りが届くところまで毎回見る

   逃げ道は無い。WebView2 は isolated world を公開しておらず（`IsScriptEnabled` は
   WebView 単位の全か無か）、催しの一覧にスクロールも無い。
   エンジンの段で止めると、位置の追従はポーリングでしか作れなくなる。
   **二層にはできない。1 層で組む**というのがここでの判断である

   1 層である以上、**配るものすべてに付ける**。種類で見分けて付けると、見分け損ねたものが漏れる。
   SVG は画像の顔をして文書として開かれうるし（固定レイアウトの SVG ページ型、spec.md 3 章）、
   拡張子を持たない章もある。下位資源に付いていても無害なので、条件を挟まない。
   実際、`DeliveredResource` を作る枝のうち 1 つが付け忘れていて、SVG が素通りしていた
2. **配信を許可制にする。** `https://choro.invalid/` へ navigate し、
   `WebResourceRequested` で全要求を横取りする。アーカイブ内のものだけを返し、それ以外は拒む。
   `.invalid` は名前解決に成功しないので、横取りに漏れがあっても外へ出ない。
   読書時にネットワークを使わない不変条件はここで担保する
3. **ナビゲーションを縛る。** `NavigationStarting` で choro.invalid 以外を取り消し、
   外部 URL は OS のブラウザで開く。`NewWindowRequested` も握って、窓の開き方はこちらで決める。
   `about:blank` は通す（WebView2 が初期化のとき自分でここへ移る）
4. **橋は 1 本。** 通信は `WebMessageReceived` だけにし、ネイティブ側が中身を検証する。
   殻がネイティブなので、WebView の中にアプリの DOM がそもそも無い。破られても触る相手がない

そのほか、DevTools は配布時に切り、autofill とパスワード保存を切り、
user data folder は LocalAppData の下に置く。

**macOS 版とは、止める層が逆になっている。**
あちらはエンジンの段（`allowsContentJavaScript = false`）で止めていて、CSP は送っていない。
`WKUserScript` は content JS を切ってもリスナごと生きるので、それで読書が成立する。
WebView2 では乗れないので、こちらは CSP 側に寄せた。
どちらも spec.md 15.1 の不変条件は満たすが、**どちらも 1 層しか持っていない**。

C# 側で二層にできないかは測って諦めた（findings-windows.md）。
エンジンの段で止めると位置の追従がポーリングでしか作れなくなり、代償が大きすぎる。
したがって C# 側は「配るものすべてが CSP を持つ」ことが唯一の要になる。そこを検査で押さえてある。

本文に触る仕事（位置の通知、コードのコピー釦、章末の行き先、図版の拡大、
暗いテーマの文字色の当て先、印への接近）は注入スクリプトが受け持ち、橋で窓と話す。
macOS 版の ReaderScripts と同じ範囲である。
鍵盤は本文に焦点があるとき注入スクリプトが受けて橋で伝える（spec.md 10.2 の
「本文ビューがフォーカスを持っているときだけ処理する」がそのまま実現できる）。
spec.md 15.2 の「出先の言葉」は Tauri 版のもので、ここでは使わない。

### WebView2 の規則

スパイクと Tauri 版の実機の両方で踏んだ、WebView2 そのものの性質。UI の作りに依らず残る。

- **イベントハンドラの中で、次の窓や WebView を同期に作らない。**
  WebView2 は自分の呼び返しの最中に次の WebView を作らせない。枠だけ出来て中身が空になる。
  Dispatcher へ渡してから作る
- **初期化を同期に待たない。** `EnsureCoreWebView2Async` は必ず await する。
  `GetAwaiter().GetResult()` はメッセージポンプを自分で止めて、永久に待つ
- **`CoreWebView2Environment` は全窓で 1 つを共有する。**
  同じ user data folder に複数の環境を作ると衝突する

### 開発の回し方

UI も CLI だけで開発する。Visual Studio は要らない。
XAML はただのテキストで、ビルドは `dotnet build`、起動は `dotnet run`。
macOS ではコンパイル検査まで。実行と動作確認は Windows で行う。

窓の中は目で見ないと分からないので、**動作確認をアプリに組み込む**（`--selftest`）。
書棚を開く → 本を開く → 注入スクリプトが名乗る → 位置の通知が届く、までを自動で辿り、
結果を標準出力と終了コードに出す。CI の Windows ジョブで毎回回す。
窓の数だけ見ていては真っ白を捕まえられない（findings-tauri.md）。

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
10. ~~PDF の当たりの矩形とページの絞り込み~~（済。紙面に囲みを重ねられる）
11. UI（ChoroReader.App）。設計は「UI の設計」の節。中の順序:
    1. ~~配信層~~（済。`WebResourceRequested` で横取りし、CssCompat・Mark.Insert をここで通す）
    2. ~~読書の窓（EPUB）と注入スクリプト~~（済）
    3. ~~`--selftest` と CI の動作確認~~（済。窓の中は目で見られないので、判定をアプリに持たせた）
    4. ~~PDF の窓~~（済。MuPDF の画素をネイティブに出し、`PageHit.Rects` を重ねる）
    5. ~~書棚と蔵書の横断検索~~（済。1 冊ずつ索引で絞り、当たった本から順に並べる）
    6. ~~位置・しおり・設定の保存~~（済。設定の置き場所へ JSON 1 枚。書籍には触れない）
    7. ~~表示設定の画面、目次、窓の中の検索欄~~（済。殻はすべてネイティブ）
    8. ~~画面構成を macOS 版・Tauri 版に揃える~~（済。窓を形式で分けるのをやめ、
       舞台だけが差し替わる形にした。サイドバーは 4 面、道具帯に履歴としおりと表示設定、
       書棚は表紙／一覧の切替。「画面の組み立て」の節）

まだ揃っていないもの:

- **サイドバーの「ページ」に絵が出ない。** いまは番号と章名の一覧である。
  紙面の縮小画像を並べるには PDF を全ページ描くことになり、
  固定レイアウト EPUB では WebView の写しを取ることになる。どちらも別の仕掛けが要る
- **macOS 版の「関連」（意味の近い箇所）が無い。** 意味の索引そのものを持っていない

各段階で `./choroconf diff swift csharp` を回すと、食い違いがその場で出る。
実際、この突き合わせは macOS 版の目次の不具合を 1 件見つけた（findings-windows.md）。

## 踏みやすいところ

CONTRACT.md の「正規化の規約」に書いてあるが、特に次で差が出る。

- **Unicode の正規化形**：macOS のファイルシステムは分解形（NFD）を返すことがある。出力前に NFC へ揃える（C# なら `string.Normalize(NormalizationForm.FormC)`）
- **パス区切り**：Windows で `Path.Combine` を使うと `\` になる。EPUB 内のパスは常に `/` で扱う
- **小数の丸め**：`progression` は小数第 3 位へ丸める。ちょうど半分のときは 0 から遠い側へ寄せる（`MidpointRounding.AwayFromZero`）
- **照合の畳み方**：`CompareInfo`（ICU）に任せない。`Fold` を自分で持つ。
  当たりには章の中での通し番号（`nth`）が付くので、どこを何番目と数えるかまで揃っている必要がある。
  ICU では次に探し始める位置が他の実装とずれ、重なりを持つ語で番号が食い違う
- **文字の数え方**：本文の位置は Unicode スカラーで数える。`string.Length`（UTF-16 の単位数）ではない
