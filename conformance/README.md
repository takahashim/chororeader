# 実装間の検証ツール

macOS 版（Swift）と Windows 版（Rust・C#）が同じ振る舞いをすることを確かめる。
取り決めは [CONTRACT.md](CONTRACT.md) にある。

## 準備

```sh
cd conformance
bundle install
cp probes.example.json probes.json   # 実装の起動方法を書く（macOS 版だけなら不要）
```

Ruby は mise で固定する。macOS の `/usr/bin/ruby` は古く、Apple が非推奨としているため使わない。

## 使い方

```sh
./choroconf generate     # 合成 EPUB フィクスチャを作る
./choroconf record       # Swift 版の出力を期待値として記録する
./choroconf check        # 期待値と照合する（CI で回すのはこれ）
./choroconf probes       # 登録されている実装を一覧する

./choroconf diff swift rust                 # フィクスチャ全件で 2 実装を突き合わせる
./choroconf diff swift csharp               # 相手は入れ替えられる
./choroconf diff swift rust 手元の本.epub   # 期待値を持たない実書籍で突き合わせる
```

## 既知の差

まだ揃っていないと分かっている事例は [known-differences.json](known-differences.json) に載せる。
不一致としては数えないが、差の中身は毎回出る。
別々の組に居る実装どうしのときにしか見逃さないので、同じ組の中で新しく壊れたものは落ちる。

```
rust: 90 件中 85 件が一致、5 件は既知の差
```

ツール自身のテスト:

```sh
bundle exec ruby test/runner_test.rb
```

比較器が壊れると実装が食い違っていても全件「一致」と報告されてしまうため、ここは必ず通しておく。

## 三つのモード

**check** は合成フィクスチャを凍結した期待値と突き合わせる。実装を変えたときの回帰検出に使う。

**diff** は期待値を持たず、2 つの実装の出力を直接比べる。実書籍は再配布できないので、手元の本での食い違いはこのモードで見つける。実質的にこれがいちばん効く。

**record** は期待値を作り直す。基準は今のところ Swift 版だが、生成された内容には必ず目を通す。片方の誤りをそのまま凍結すると、それが仕様になってしまう。

## フィクスチャ

実装差が出やすい箇所を狙った合成 EPUB を `lib/fixtures.rb` が組み立てる。

| 名前 | 狙い |
| --- | --- |
| `epub3-basic` | EPUB3 の nav、階層目次、表紙、コードブロック |
| `epub2-ncx` | EPUB2 の NCX 目次、`meta name="cover"` |
| `legacy-css` | `-epub-` プレフィックス、Shift_JIS の CSS、コメントと文字列リテラルの保護 |
| `encoded-paths` | パーセントエンコードされた href、日本語と空白を含むファイル名 |
| `broken-refs` | 存在しない画像への参照、目次が指す先の欠落 |
| `malformed-xhtml` | XML として通らない章 |
| `nonlinear-spine` | `linear="no"`（読み順から外し、目次からは開ける） |
| `fixed-layout` | `rendition:layout` による固定レイアウト判定 |
| `rtl` | 右開き |

## 検証する項目

契約の 11 コマンドを、合成フィクスチャに対して 68 通り実行して突き合わせる。
内訳は、パス解決 10、CSS 変換 5、表示設定 6、書籍ごとの parse・report・detect・text・preview・fixed・search である。

生成物と `probes.json` は追跡しない。ZIP は生成のたびにバイト列が変わり、`probes.json` は環境ごとに違うため。
`expected/` は追跡する。これが実装間の合意そのものだから。
