# Tauri スパイクの結果

Windows 版を C# + WinUI + WebView2 で作るか、Tauri（Rust + OS 標準の WebView）で作るかを決めるために測った。
2026-08-06、macOS 15 / Apple Silicon。

動かしたもの:

- `spikes/rust-mupdf/` — MuPDF の Rust バインディングだけを単体で試すコマンド
- `spikes/tauri-spike/` — Tauri アプリ。独自スキーム、iframe の sandbox、PDF の描画をまとめて判定する

## 判定したかったこと

C# 版で成り立っていた前提が、Tauri でも成り立つかどうか。

1. 書籍由来の JavaScript を止めたまま、アプリ側のコードで本文の DOM を触れるか
2. EPUB を展開せずに ZIP から独自スキームで配れるか
3. MuPDF で描いたページを WebView へ渡したとき、拡大しながらの連続再描画に耐えるか
4. MuPDF の Rust バインディングが、MuPDFCore と同じ API を備えているか

## スパイク 5：MuPDF の Rust バインディング（spikes/rust-mupdf）

`mupdf` クレートは C のソースからビルドされる。
macOS arm64 で問題なく通り、**素の状態から 30 秒**（release、8 コア並列、後述の削った機能構成）。以後の増分ビルドは 2 秒。

実書籍（技評『関数プログラミング実践入門』401 ページ）に対する実測:

| 項目 | Rust の mupdf 0.8 | C# の MuPDFCore 2.0.1 |
| --- | --- | --- |
| 開く（2 回目以降） | 0 ms | 0 ms |
| 本文抽出（1 ページ） | 28 ms | 10 ms |
| 検索（先頭 20 ページ、124 件） | 37 ms | 11 ms |
| 描画（1.5 倍、630x893） | 58 ms | 72 ms |
| 目次 | 第 1 階層 18 項目 | 27 項目（PDFKit と一致） |

抽出と検索は Rust 側が遅く見えるが、測り方が違う（C# は 1 ページあたり、こちらは初回を含む）ため、この表から優劣は言えない。
どちらも実用の範囲に収まっている、という以上のことはこの数字からは読み取らない。

API は必要なものが揃っていた。ページ数、目次（`down` で階層をたどれる）、本文抽出、`search`、`to_pixmap`、`write_to` による PNG 符号化。
加えて `TextPage` から文字ごとの矩形と縦書きの別が取れる（実書籍の 1 ページで 51 行 2812 文字、うち縦書き 2 行）。
PDF.js が既製で持つ「選択できるテキスト層」を自前で組み立てられる、ということである。

落とし穴が 3 つあった。

- `Pixmap::get_image_data` は非公開。PNG にするには `write_to` を使う。
- `Document` はスレッドを跨げない。開いたスレッドに閉じ込め、チャネル越しに描画を依頼する形にした。
- `WriteMode` は `text_page` からは見えない。クレート直下から使う。

## スパイク 6：Tauri（spikes/tauri-spike）

Tauri 2.11、`WebviewWindowBuilder` でウィンドウを作り、`register_asynchronous_uri_scheme_protocol` で `choro` スキームを配る。
判定は画面側の JavaScript が行い、結果を `invoke` で Rust へ返して JSON を標準出力へ書く。

### 前提 1・4：書籍の JavaScript を止められるか

**Tauri では、macOS 版・WebView2 版と同じ手は使えない。**
アプリの画面そのものが JavaScript でできているため、WebView 全体でスクリプトを止めるわけにいかない。

代わりに、本文を `sandbox="allow-same-origin"` を付けた iframe に入れる。
`allow-scripts` を与えなければ、その iframe の中でスクリプトは動かない。

測った結果:

- sandbox 付きの iframe：書籍の `<script>` は**動かない**
- sandbox 無しの iframe（対照）：同じ文書で `<script>` は**動く**

対照を並べたのは、動かなかった理由が sandbox 以外（CSP など）でないことを示すため。

**アプリ側のコードは、注入ではなく親から直接触る形になる。**
親の文書から `iframe.contentDocument` を辿り、要素の追加、本文の書き換え、`scrollHeight` の読み取りができることを確認した。
macOS 版は本文の文書へスクリプトを注入していたが、Tauri ではその必要がない。

これが成り立つのは、**画面と本文を同じ生成元から配ったとき**に限る。
アプリの画面を `frontendDist` から（`tauri://localhost`）、本文を `choro://localhost` から配ると生成元が分かれ、親から `contentDocument` に届かない。
そこで画面自体も `choro://localhost/app/index.html` として独自スキームから配った。実測した生成元は `choro://localhost`。

> **この結論は 2026-08-07 に取り消した。**
> 「親から直接触る」形は、本文の中で**あらゆるリスナが発火しない**という代償を伴っていた。
> `allow-scripts` の無い文書ではその文書に紐づく script が一切走らず、
> 親が張ったリスナも、親が作った釦のリスナも動かない。
> 本文のリンク、章末の行き先、コードのコピー釦、図版の拡大、本文側の鍵盤とスクロールが、
> **一度も働いていなかった**。詳しくは下の「本文の中では何も動いていなかった」を見よ。

### 前提 2：EPUB を展開せずに配れるか

`zip` クレートでアーカイブを開いたまま持ち、要求のたびに該当エントリだけを展開して返す。
実書籍の章を ZIP から取り出して iframe に表示できた（330 文字）。macOS 版の自前 ZIP リーダーと同じ方式が取れる。

### 前提 3：拡大しながらの連続再描画に耐えるか

`X-Render-Ms` ヘッダで MuPDF の描画時間を返し、画面側で測る往復時間との差から内訳を出した。
release ビルドでの中央値（ミリ秒）:

| 操作 | 合計 | 描画 | 転送 | 表示 |
| --- | --- | --- | --- | --- |
| ページ送り 10 回（1.5 倍） | 29 | 23 | 1 | 5 |
| 拡大 10 回（1.0〜1.9 倍） | 30 | 22 | 1 | 6 |
| 拡大 20 回（1.0〜3.85 倍） | 91 | 71 | 1 | 14 |

最初の 1 ページが出るまでは 130 ms。

**転送が 1 ms である**ことが重要だった。
独自スキームで PNG を渡す経路は費用にならず、時間はほぼ MuPDF の描画そのものである。
つまり、速さの上限を決めるのは Tauri ではなく MuPDF であり、この点で C# + WebView2 と差が付く理由はない。

倍率を上げると描画は重くなる（3.85 倍で 71 ms）が、拡大の途中は CSS の変倍で見せ、指を離してから描き直せばよい。
読む倍率の範囲（1.0〜1.9 倍）では 30 ms に収まっている。

なお debug ビルドでは同じ操作が 207 ms かかった。MuPDF は C のソースからビルドされるため、profile の影響を強く受ける。計測は release で行う。

## 分かったこと

4 つの前提はすべて成り立つ。Tauri で Windows 版を作れる。

C# + WinUI と比べたときの違いは、速さではなく次の 2 点にある。

- **開発を macOS で進められる**。Rust と Web の資産は OS に依らない。Windows 実機が要るのは、WebView2 での確認とビルドの最終確認だけになる。
- **書籍の JavaScript を止める仕組みが変わる**。WebView 全体の設定ではなく枠ごとの指定になる。
  （当初は「親からの直接操作になる」と結論したが、後に取り消した。下記を見よ。）

**Windows でも同じだった（2026-08-06、実行 31024070987）**。
windows-latest の CI で同じスパイクを走らせ、4 つの前提がすべて成り立った。

```json
{ "assumptionHolds": true,
  "origin": "http://choro.localhost",
  "bookScriptRanInSandbox": false,
  "bookScriptRanWithoutSandbox": true,
  "parentCanReachSandboxedFrame": true,
  "appCanEditBookDom": true }
```

生成元の書き方だけが違う。Tauri は Windows では独自スキームを `http://<スキーム名>.localhost` に割り当てる。
sandbox の効き方も、親から `contentDocument` に届くことも、WKWebView と変わらない。

## Windows でのビルドが失敗した（2026-08-06）

上の CI ジョブを初めて走らせたところ、MuPDF のビルドで転んだ。
懸念していた「C のソースからビルドすること」が、そのまま失敗として出た形になる。

```
bin2coff.targets(76,5): error MSB3721: The command
  "Release\bin2coff.exe "...\resources\fonts\droid\DroidSansFallback.ttf"
   "x64\Release\libresources\DroidSansFallback_ttf.obj" ..." exited with code 1.
```

**原因は mupdf-sys 0.5.0 の同梱漏れである。**
このクレートはパッケージを小さくするためフォントの `.ttf` を同梱していない。
Unix 側の Makefile は `TOFU_CJK` などの定義でフォントの埋め込みを飛ばすため気付かないが、
MSVC 側の `libresources.vcxproj` はファイル一覧に基づいて `bin2coff` を回すので、
存在しない `DroidSansFallback.ttf` を埋め込もうとして落ちる。
macOS でだけ通っていたのはこのためで、機能の差ではなく経路の差である。

**0.8.0 で解決していた。**
フォントを `.ttf` ではなく生成済みの `.c`（`mupdf/generated/resources/fonts/urw/`）として持つようになり、
`bin2coff` を回す段階そのものが無くなっている。
CJK のフォールバックフォントは同梱されないままだが、`system-fonts` 機能が OS のフォントを使うため、
日本語の表示は macOS でも Windows でも OS 側から供給される（リーダーとしてはむしろ望ましい）。

あわせて既定の機能を切った。

```toml
mupdf = { version = "0.8", default-features = false, features = ["system-fonts"] }
```

既定には OCR（tesseract と leptonica）、XPS、SVG、CBZ、EPUB の版面エンジンが含まれる。
chororeader はどれも使わない。CI のログではビルド時間の大半をこれらが占めていた。
素のビルドは 69 秒から **30 秒**に減り、実書籍に対する結果（目次 18 項目、抽出 31 ms、検索 36 ms、描画 52 ms、
PNG 69153 バイト）は 0.5 と 1 バイトも変わらなかった。

**Windows では機能を切ってもビルドは軽くならない。**
`make_bool` は Make のときだけ効き、MSBuild では何もしない（`build.rs` の `Build::make_bool`）。
つまり `FZ_ENABLE_*` の `#ifdef` は渡るが、`mupdf.sln` は tesseract と leptonica を変わらず全部コンパイルする。
実際 windows-latest でのビルドは 17 分 37 秒かかり、ログには `libtesseract.vcxproj` が並んでいる。
Windows でこれを短くする手は、いまのところキャッシュしかない。

0.5 から 0.8 への移行で 3 か所直した。

- `Outline::page` が無くなり、`dest: Option<LinkDestination>` になった。通しページ番号は `dest.loc.page_number`。
- `Page::to_text` が `Page::text(TextExtractOptions)` になった。
- `TextPageOptions` が `TextPageFlags` に改名された。

## 再現の仕方

```sh
cd spikes/rust-mupdf
cargo run --release -- <PDF のパス> 型

cd spikes/tauri-spike/src-tauri
cargo build --release
CHORO_EPUB=<EPUB のパス> CHORO_PDF=<PDF のパス> ./target/release/app
```

環境変数を省くと、その部分の判定を飛ばす。書籍が無くても前提 1・4 は測れる。

## 本文の中では何も動いていなかった（2026-08-07）

本文をクリックすると鍵盤が効かなくなる、という報告から追ったところ、
**`sandbox="allow-same-origin"`（`allow-scripts` 無し）の文書では、
親が張ったリスナも含めてリスナが 1 つも発火しない**ことが分かった。

実測（動作確認の中で走らせた）:

```
合成 doc=0 body=0 ／ 釦の click()=0 ／ defaultView=true 同一=true
```

親から `document` にも `body` にも、親が作った `<button>` にも `click` が届かない。
sandbox の scripting フラグは「その文書に紐づく script を走らせない」ことを意味し、
リスナが親の realm の関数であっても変わらない。

したがって次のものは、Tauri 版では最初から働いていなかった。

- 本文のリンク（内部リンクの抜粋、外部 URL をブラウザで開く、⌘クリックで別窓）
- 章末の「次の章へ」
- コードブロックのコピー釦
- 図版を押して拡大
- 本文側の `keydown` / `wheel` / `scroll`

「押した拍子に本文が黙る」のはこの帰結である。押すと焦点が本文の枠へ移り、
移った先に鍵盤の行き先が無い。押されたことを知る手立ても無いので、戻すこともできない。

### 置き換え

sandbox で止めるのをやめ、**生成元を切り離したうえで CSP で止める**形にした。

```
枠   sandbox="allow-scripts"          （allow-same-origin は与えない）
配信 Content-Security-Policy: default-src 'none'; script-src 'nonce-…'; …
差込 <script nonce="…" src="/app/agent.js"></script>
```

実測:

```
名乗り=true ／ href=/book/b1/OEBPS/text/ch02.xhtml ／ 往復=true
本文=第 2 章　探す 道具帯の検索欄に「サン ／ 親から直接触れる=false
キー(ArrowLeft) 2→1 届く ／ 章末の釦=true
親の張り doc=1 釦=1 ／ 書籍の script が走った=false
```

- 生成元を持たない文書からでも、独自スキームの下位資源（出先の script）は読める
- nonce を持つ 1 本だけが走り、書籍の script は走らない
- 親 ⇄ 出先の postMessage が両方向で通る
- 親からは `contentDocument` に触れない（狙いどおり）

本文に触る仕事はすべて出先（`tauri/app/ui/agent.js`）へ移し、
窓とは決めた言葉でやり取りする。言葉の一覧は spec.md 第 15.2 節にある。
**macOS 版と同じ形**（書籍の script は止め、注入したものだけが動き、通信は 1 本に限る）になった。

### 気をつけること

`location.origin` は `choro://localhost` と出る。生成元を持たない文書なら `"null"` のはずで、
独自スキームでは WebKit の扱いが違う。**`event.origin` で相手を見分けてはならない。**
窓は `event.source` が本文の枠かどうかで、出先は `event.source === parent` で見分ける。

出先はモジュールにできない。module の取得は CORS を伴い、生成元を持たない文書からは読めない。

## 同期の命令の中で窓を作ると、枠だけ出来て中身が空になる（2026-08-07）

Windows 実機で「書棚は開くが、本を押しても真っ白な窓しか出ない」となった。
macOS では起きない。CI の動作確認も通っていた。

同期の命令（`#[tauri::command]`）は主スレッドで、しかも **WebView の便りを
受けている最中**に走る。Windows の WebView2 は自分の呼び返しの最中に次の
WebView を作らせない。呼び返しは外側が返るまで届かず、窓の枠だけが残る。

切り分けは窓の作り元で並べると出る。

```
setup（起動引数・最初の書棚）        → 出る
献立（サンプルを開く）               → 出る    ← WebView の呼び返しの外
同期の命令（open_in_new_window）     → 真っ白
同期の命令（open_shelf）             → 真っ白
```

**窓を作る命令は `#[tauri::command(async)]` にする。** 別のスレッドから
頼むことになり、要求は催しの列を通って落ち着いたところで捌かれる。
ダイアログを待たない形にしたのと同じ筋である（`pick_book`）。
落とし込みの知らせも WebView から届くので、そこも受けた場をすぐ離れる。

**窓の数だけを見ていては捕まらない。** 枠は出来ているので数は増える。
動作確認では、開いた窓の画面が土台へ名乗るところまで見る（`note_awake`）。

## CSP に `choro:` と書くと Windows では何にも当たらない（2026-08-07）

独自スキームは Windows では `http://choro.localhost` に割り当てられる。
`img-src choro:` は当たらず、`default-src 'none'` が効いて、本文の枠に入った
書籍の画像も CSS も落ちる。書籍の CSS が効かず図版が抜けた本文が出る。

同じ書籍を CSP だけ変えて並べて確かめた。

```
img-src choro:                     → 画像は壊れた枠、書籍の CSS も効かない
img-src http://choro.localhost     → どちらも出る
```

許し先は経路を組み立てるのと同じところ（`protocol::origin`）から取る。

なお同梱の固定レイアウトのサンプルでは気付けない。ページが画像 1 枚だけの
本文は core が `kind: "image"` と見なし、窓の側が `<img>` を直に置くので、
本文の枠を通らず CSP に掛からない（`core/fixed_layout.rs`）。

## 焦点の輪の片割れが残っていた（2026-08-07）

読書の窓が閉じられず、本文の周りの焦点枠が高速に明滅した。書棚では起きない。

`focus_webview`（Rust 側で `set_focus` を呼ぶ）は OS から見た受け手を動かすので、
**焦点の知らせを呼び返す**。画面側がその知らせで呼び返していた。

```
window の focus → invoke("focus_webview") → set_focus() → window の focus → …
```

実測で毎秒 265 回。催しの列が詰まるので窓が閉じられなくなり、
`#stage` の焦点枠がその速さで点いたり消えたりする。

同じ輪は Rust 側にもあり、8342e3d で消してある（95 秒に 22,077 回）。
**画面側の片割れが残っていた。** 消せたのは、それまで Windows で読書の窓が
真っ白で、そもそもこの輪を見る機会が無かったためである。

戻すのは名指しのときだけでよい。ダイアログが受け手を持ち去る件は閉じた直後に
呼ぶ側で面倒を見ており、他アプリから戻ったときは Win32 も AppKit も既定で戻す。

焦点そのものは人が押さないと確かめられないが、**回った回数なら数えられる**。
放っておいた 1 秒の `focus_webview` の回数を動作確認に入れた（輪があると 303 回）。
