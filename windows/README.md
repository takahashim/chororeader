# Windows 実装（C#）

まだ着手していない。この文書は、始めるときの取り決めを先に固めておくためのもの。

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
├── TZReader.Core/     クラスライブラリ。UI に依存しない（EPUB パース、Locator、CSS 変換、検索、診断）
├── TZReader.Probe/    コンソールアプリ。probe CLI の実体。Core を参照する
└── TZReader.App/      Windows 専用の UI（WinUI 3 など）。Core を参照する
```

**この分け方には実利がある。** .NET は macOS でも動くため、Core と Probe は macOS 上でビルドして実行できる。
つまり Windows マシンを用意しなくても、開発機の Mac で次が回る。

```sh
cd conformance
cp probes.example.json probes.json
./tzconf diff swift csharp                 # 合成フィクスチャで突き合わせ
./tzconf diff swift csharp 手元の本.epub   # 実書籍で突き合わせ
```

Core が Windows 専用 API（WinUI、Win32）に触れると、この検証が Windows でしか回らなくなる。
Core は netstandard か net8.0 のままにしておく。

## 実装の順序

1. **Probe の骨組み**：`probe version` だけ返す。`./tzconf probes` に載ることを確認する
2. **`probe resolve` と `probe css`**：ファイルを読まない部分から始める。期待値と突き合わせて、正規化の規約（NFC、パス区切り、改行）を体で確認する
3. **`probe parse`**：ZIP は `System.IO.Compression.ZipFile`、OPF と目次は `System.Xml.Linq` で読む
4. **`probe detect` と `probe report`**：エラー分類を CONTRACT.md の表に合わせる
5. **`probe search`**：全角半角を区別しない部分一致。`CompareOptions.IgnoreWidth` を使う
6. ここまでで `./tzconf check csharp` が 49 件通る。以後は UI

各段階で `./tzconf diff swift csharp` を回すと、食い違いがその場で出る。

## 踏みやすいところ

CONTRACT.md の「正規化の規約」に書いてあるが、特に次の 3 点で差が出る。

- **Unicode の正規化形**：macOS のファイルシステムは分解形（NFD）を返すことがある。出力前に NFC へ揃える（C# なら `string.Normalize(NormalizationForm.FormC)`）
- **パス区切り**：Windows で `Path.Combine` を使うと `\` になる。EPUB 内のパスは常に `/` で扱う
- **小数の丸め**：`progression` は小数第 3 位へ丸める
