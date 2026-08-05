# フェーズ 0 スパイク結果

実施日：2026-08-05
環境：Apple Silicon Mac（macOS 26 / arm64）、Swift 6.3.3、Xcode 26.6

## 結論

- EPUB 表示は WKWebView + `WKURLSchemeHandler` の自前ナビゲータで成立する。組版品質は出版社 CSS 込みで Safari 相当を確認した。
- Readium Swift Toolkit のパース層（ReadiumShared / ReadiumStreamer）は macOS でビルドできない。EPUB パーサは自前実装で確定する。
- PDF は PDFKit で成立する。ロード、アウトライン、テキスト層、日本語検索をすべて確認した。

## スパイク 1：EPUB 表示（spikes/epub-view）

実 EPUB 2 冊で検証した。
2014 年の技術評論社『関数プログラミング実践入門』（EPUB、spine 86 項目、4.8MB）と、Re:VIEW 生成の FirstStepReVIEW-v3（spine 16 項目、34MB）である。

計測値：

| 項目 | 技評 EPUB | Re:VIEW EPUB |
|---|---|---|
| unzip（初回のみ） | 3724 ms | 331 ms |
| 章の初回表示 | 2212 ms | 322 ms |
| 隣接章への切り替え | 11 ms | 24 ms |

- 章切り替え 11〜24 ms は、性能目標（300 ms 以内に応答開始）に対して 1 桁以上の余裕がある。
- 技評 EPUB の初回 2212 ms には WebContent プロセスの起動が含まれる。実アプリでは WKWebView の事前ウォームアップで短縮できる。
- unzip は書籍ごとに一度だけ必要な処理であり、展開キャッシュを持てば「登録済み書籍の本文表示 1 秒以内」の目標は成立する見込み。

表示品質（results/ のスクリーンショット参照）：

- 出版社 CSS が完全に再現された。章見出しの黒帯、コードブロックの背景、ターミナル表示の暗色ブロック、インラインコードの装飾、図版、リンク色まで崩れなし。
- 明朝体の日本語本文、コード内の日本語コメント、等幅表示も正確。
- `allowsContentJavaScript = false`（EPUB 内 JS 無効）のまま、アプリ注入の `evaluateJavaScript` が動作することを確認した。コードコピーボタンやスクロール制御など、アプリ由来の JS 注入という設計が成立する。

## スパイク 2：Readium の macOS ビルド（spikes/readium-macos）

swift-toolkit 3.11.0 に依存する最小パッケージで検証した。

1. 素の状態では、swift-toolkit が platforms に iOS しか宣言していないため、マニフェスト解決の段階でエラーになる（macOS の最低バージョンが既定の 10.13 に落ち、依存の SwiftSoup が要求する 10.15、ReadiumZIPFoundation が要求する 11.0 と矛盾する）。
2. Package.swift に `.macOS("13.0")` を足すパッチを当てて再ビルドしたところ、コンパイルエラー 373 件。原因は UIKit 依存で、ReadiumShared の 10 ファイルと ReadiumStreamer の 1 ファイルが `import UIKit` している。
3. 依存は周辺機能に限局しておらず、`UIImage` が公開 API に露出している（CoverService の戻り値など 8 箇所以上）。他に AudioSession、NowPlayingInfo、DefaultHTTPClient も iOS 前提。

つまり流用には公開 API の改変を含むフォーク保守が必要で、「軽微なパッチ」に収まらない。
一方、スパイク 1 では container.xml と OPF のパースを約 60 行で書けており、仕様が要求するパース範囲（container / OPF / 目次 / spine）の自前実装は現実的な規模である。
よって spec.md 第 13 章の条件分岐は「自前実装」で確定する。

再現方法：spikes/readium-macos で `.build/checkouts/swift-toolkit` を `swift-toolkit-patched` へコピーし、Package.swift の platforms に macOS を追加してビルドする（検証後のコピーと build 産物は削除済み）。

## スパイク 3：PDFKit（spikes/pdf-probe）

『n月刊ラムダノート Vol.4 No.3』（98 ページ、テキスト層あり）で検証した。

- オープン：56.8 ms
- アウトライン：27 項目を階層とページ番号付きで取得（目次ソースとしてそのまま使える）
- テキスト層：ページ単位の抽出が正常（検索と引用コピーの基盤になる）
- 日本語検索：「型」704 ヒットを 348.9 ms で同期取得

検索 349 ms は書籍全体の同期検索の値であり、目標（初回表示 200 ms 以内）に合わせるには `beginFindString` による逐次通知を使えばよい。
判定：PDF ナビゲータは PDFKit で確定。

## スパイク 4：注入スクリプトの可否（spikes/js-probe）

`allowsContentJavaScript = false` の下で、アプリ由来の WKUserScript とメッセージハンドラが動くかを確認した。
スクロール位置の通知方式が、この結果で決まるためである。

- アプリ注入の WKUserScript は実行され、`window.webkit.messageHandlers` へのメッセージも届く（スクロールイベントの受信も確認）
- 書籍側の `<script>` は実行されない（`document.title` と本文が書き換わらないことで確認）

判定：仕様 15 章の「書籍由来 HTML とアプリ由来 JavaScript の境界」は、この構成でそのまま実装できる。
スクロール通知、コードブロックのコピーボタン、位置復元はすべて注入スクリプトで賄える。

補足：最初の測定では XHTML として不正な HTML を配信していたためパースエラーで結論が出せず、正しい XHTML に直して測り直した。

## 仕様への反映

- spec.md 第 13 章：EPUB パーサは自前実装で確定（条件分岐を解消）。
- 性能目標（第 16 章）：スパイク実測により達成可能性を確認。WKWebView の事前ウォームアップと展開キャッシュを実装方針に含める。
