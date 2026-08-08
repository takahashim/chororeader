# WebView2 の前提を確かめるスパイク

## 何を確かめるか

macOS 版は、WKWebView で次が成り立つことを確認したうえで設計してある（[../../spikes/findings.md](../../spikes/findings.md) のスパイク 4）。

> 書籍由来の JavaScript は動かない。アプリが注入したスクリプトとメッセージだけが動く。

この前提の上に、スクロール位置の通知、コードブロックのコピーボタン、章末の行き先、位置復元、
そして暗いテーマでの文字色の当て先の判定が乗っている。

**WebView2 で同じことが成り立つかどうかで、Windows 版の EPUB ナビゲータの作りが変わる。**
崩れる場合、上の仕組みを別の手段（ネイティブ側からの定期的な問い合わせなど）へ置き換える必要がある。

## 何を見ているか

1. 独自スキーム（`choro://`）の要求を横取りして、メモリ上の文書を返せるか
   （WKURLSchemeHandler に当たる仕組みがあるか）
2. `IsScriptEnabled = false` のとき、書籍側の `<script>` が実行されないか
3. 同じ状態で、`AddScriptToExecuteOnDocumentCreated` で入れたスクリプトが実行されるか
4. 同じ状態で、注入スクリプトからの `chrome.webview.postMessage` が届くか
5. 同じ状態で、`ExecuteScriptAsync` が使えるか

4 つすべてが期待どおりなら、macOS 版と同じ設計で組める。

## 動かし方

**Windows でしか実行できない。** macOS ではコンパイルまで通る（`EnableWindowsTargeting`）。

```sh
# Windows で
cd windows
dotnet run --project ChoroReader.WebViewSpike/ChoroReader.WebViewSpike.csproj
```

Windows 機が無い場合は、GitHub Actions の Windows ランナーで動く。
`.github/workflows/ci.yml` の `webview2-spike` ジョブがこれを実行する。
リポジトリを GitHub へ push するか、`workflow_dispatch` から手で起こす。

結果は JSON で標準出力へ出る。前提が成り立てば終了コード 0、崩れれば 1 を返す。

```json
{
  "webView2Version": "...",
  "navigationSucceeded": true,
  "customSchemeServed": true,
  "injectedScriptRan": true,
  "bookScriptRan": false,
  "webMessageArrived": true,
  "executeScriptWorks": true,
  "assumptionHolds": true,
  "conclusion": "macOS 版と同じ前提が成り立つ。注入スクリプトとメッセージで組める。"
}
```

## 結果が出たら

[../../spikes/findings-windows.md](../../spikes/findings-windows.md) に追記する。
前提が崩れていた場合は、代わりの手段を決めてから UI に着手する。
