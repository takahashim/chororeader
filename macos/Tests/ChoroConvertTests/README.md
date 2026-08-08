# choroconvert の検査について

## 2 段構え

**1 段目（ここの XCTest）** — 組み上げた bytes を、検査側に別に持った読み手でほどく。
書き手の裏返しではなく、protobuf の仕様から独立に組んである。
番号・慣例・型の付け方を、実行のたびに守る。

**2 段目（下の治具）** — coremltools（本家の読み手）でほどいて構造を見る。
1 段目の期待値はここから写した。番号を写し間違えたときに気付けるのはこちらである。
毎回は回さない。**MIL の組み立てを変えたときに 1 度通す。**

## 治具の回し方

```sh
# 変換器から MIL を書き出す（検査を 1 つ足して /tmp へ出す）
swift test --filter <書き出す検査>

# 本家の読み手でほどく
python3 -m venv /tmp/mil-venv
/tmp/mil-venv/bin/pip install coremltools
/tmp/mil-venv/bin/python - <<'PY'
from coremltools.proto import MIL_pb2
p = MIL_pb2.Program()
p.ParseFromString(open('/tmp/mil-sample.bin','rb').read())
print('版:', p.version)
for name, f in p.functions.items():
    print('関数:', name, '/ opset:', f.opset)
    block = f.block_specializations[f.opset]
    print('  入力:', [i.name for i in f.inputs], '出力:', list(block.outputs))
    for op in block.operations:
        print(' ', op.type,
              {k: [b.name for b in v.arguments] for k, v in op.inputs.items()},
              [(o.name, o.type.tensorType.dataType) for o in op.outputs])
PY
```

`libcoremlpython` が無いという警告は出るが、protobuf を読むだけなので構わない。

## ONNX の治具

ONNX 側も同じ 2 段構えである。1 段目はここの XCTest（別に持った読み手でほどく）。
2 段目は **ONNX Runtime に読ませる**。本家の読み手なので、番号を写し間違えていれば読めない。

**Swift からは ONNX Runtime を回せない**ので、C# 側を治具に使う。

```sh
# 見本を書き出す（環境変数を置いたときだけ書く）
CHORO_ONNX_SAMPLE=/tmp/choro-onnx-sample.onnx swift test --filter test_見本を書き出す

# 本家の読み手で開いて回す
cd ../spikes/onnx-jig && dotnet run -- /tmp/choro-onnx-sample.onnx --run
```

治具は `spikes/onnx-jig` に置いた。**probe には入れない。**
あれは突き合わせに使うので、native を抱えさせたくない。

出入口の形と、計算した値が出る。**毎回は回さない。組み立てを変えたときに 1 度通す。**

数の審判は下と同じで、実物を変換して凍結済みの期待値に通す
（`windows/ChoroReader.Tests/OnnxEmbedderTests.cs` の置き場所を自作の変換物へ向ける）。

## いちばん強い審判（実物）

上の 2 つは**形**しか見ない。数が合っているかは見ない。
数の審判は実物のモデルが要るので、検査には入れず、手順として残す。

```sh
SNAP=$(dirname $(find ~/.cache/huggingface/hub -name "model.safetensors" -path "*ruri-v3-130m*" | head -1))

# 変換する（材料の取得と写しは道具がやる）
swift build -c release
.build/release/choro-convert --model-id cl-nagoya/ruri-v3-130m --out-dir /tmp/mine

# 凍結済みの期待値（kohagi の変換物で作ったもの）を、自作の束で通す
#   Tests/ChoroReaderTests/CoreMLEmbedderTests.swift の置き場所を /tmp/mine に向けて実行
```

**Hugging Face の置き場所は symlink である。** Core ML のコンパイラは辿れないので、
kohagi の束と比べるときは実体を写す（`cp -RL`）。

### PyTorch との突き合わせ

kohagi との一致だけでは足りない。**両方が同じように間違っている**ことがある（下記）。
本家（transformers）を oracle に置く。`torch` と `transformers` を入れた venv で、
`AutoModel.from_pretrained(...)` の `last_hidden_state` を JSON に書き出し、
変換物の出力と突き合わせる。

**詰め物のある入力で測ること。** 詰め物の無い入力では、後述の欠陥が出ない。

### 通した結果（2026-08-08、ruri-v3-130m）

| | |
|---|---|
| 隠れ状態（seq 64/128/256/512、CPU） | **cosine 1.000000・最大の差 0.0000** |
| 凍結済みの期待値 10 件 | **最小の cosine 0.999994** |
| `weight.bin` の大きさ | 完全に同じ（264,793,600 バイト） |
| `Manifest.json` | **バイト一致** |
| `weight.bin` のバイト | **一致しない** |

**`weight.bin` のバイト一致は成り立たない。** 設計にはそう書いていたが、誤りだった。
135 個の中身は集まりとして完全に一致し、**並べる順だけが違う**（確かめた）。
MIL の const はそれぞれの位置を指しているので、これで正しい。
順まで揃えるのは参照実装に合わせるための作業であって、正しさの条件ではない。

### PyTorch との一致（詰め物あり、本物の位置のみ）

| | seq_64 | seq_128 | seq_256 | seq_512 |
|---|---|---|---|---|
| CPU | 0.99993 | 0.99919 | 0.99611 | 0.99974 |
| ANE | 0.99996 | 0.99987 | 0.99990 | 0.99995 |

fp16 の丸めの範囲である。

### kohagi と同じように間違っていた件（直した）

**塞ぐ値に `-inf` を使うと、CPU で本物の位置まで NaN になる。**

完全に塞がれた行は実際に出る（詰め物の位置が、局所注意の窓から本物の外れた
ところにあるとき）。`-inf` だと `exp(-inf) = 0` が並び、softmax が `0/0 = NaN`
を返す。その NaN は次の層で本物の位置へ移る（重み 0 を掛けても `0 × NaN = NaN`）。

| | seq_64 | seq_128 | seq_256 | seq_512 |
|---|---|---|---|---|
| 直す前・CPU | 0% | 0% | **100%** | **100%** |
| 直す前・ANE | 0% | 0% | 0% | 0% |
| 直した後・CPU/ANE | 0% | 0% | 0% | 0% |

ANE で出ないのは `-inf` の扱いが違うだけで、頼れる性質ではない。
アプリは `.cpuAndNeuralEngine` を指定するが、これは「ANE を使ってよい」であって
保証ではない。CPU へ落ちるとベクトルが静かに NaN になる。

**PyTorch は最小の有限値（fp32 で -3.4e38）を使い、NaN を出さない。**
有限値なら、全部塞がれた行は一様分布になるだけで済む。こちらは fp16 の
最小の有限値（-65504）に揃えた。

kohagi にも同じ欠陥がある（2026-08-08 時点）。あちらのコメントは
「参照実装は fp16 の -inf を使う」と読んでいるが、いま確かめた transformers は
有限値を使っている。

### 埋めた穴（2026-08-08）

「まだ測っていない」と書いていた 3 つを潰した。

| | 結果 |
|---|---|
| **seq 1024・2048** | PyTorch と cosine 0.9986〜0.9999・NaN なし |
| **30m（層 10・hidden 256）** | 0.99998〜0.99999・NaN なし |
| **silu を使う設定** | 0.9999（gelu も同じ条件で 0.9999） |

silu を使う ModernBERT は実物に無い（調べた範囲では全部 gelu）ので、
transformers でその場で小さなモデルを作って確かめた。

### 照合の道具で 2 度つまずいた（どちらも道具の側）

**1. 入力を道具の側で作り直していた。** 語彙 200 のモデルへ `% 90000` の
トークン ID を流していて、cosine 0.14 が出た。位置 0 だけ偶然一致するので
（`11 % 90000 == 11 % 200`）、変換器の欠陥だと思い込んで半日追った。

→ **入力そのものを期待値の JSON に入れる。** 道具の側で作り直さない。

**2. 重みが小さすぎた。** transformers の既定の初期化（標準偏差 0.0175）だと、
層を通ってもノルムがほとんど動かず（45.6 → 45.6）、出力が埋め込みの正規化
そのものになる。それを比べても丸め誤差しか見ていない。

→ 合成モデルは**重みを実物並みの大きさにする**（標準偏差 0.3 程度）。
層ごとにノルムが伸びること（45 → 373）を確かめてから使う。

切り分けの手順として有効だったのは、**層の重みを 0 にして埋め込みだけを比べる**
こと。そこで合わなければ、注意でも中間層でもないと分かる。

## 分類頭（reranker）の照合

胴体と同じ形で、oracle は transformers の
`AutoModelForSequenceClassification`。**組の詰め方も推測しない**
（tokenizer に実際に詰めさせて `input_ids` ごと持ち帰る）。

```sh
/tmp/rr/bin/python - <<'PY'
from transformers import AutoTokenizer, AutoModelForSequenceClassification
import torch, json
name = "hotchpotch/japanese-reranker-xsmall-v2"
tok = AutoTokenizer.from_pretrained(name)
m = AutoModelForSequenceClassification.from_pretrained(name, dtype=torch.float32).eval()
out = []
for query, body in [("架空の問い", "架空の本文。")]:
    enc = tok(query, body, return_tensors="pt", padding="max_length", max_length=256, truncation=True)
    with torch.no_grad():
        out.append({"ids": enc["input_ids"][0].tolist(),
                    "mask": enc["attention_mask"][0].tolist(),
                    "score": float(m(**enc).logits[0][0])})
json.dump(out, open("/tmp/rr-scores.json", "w"))
PY
```

### 通した結果（2026-08-08、japanese-reranker-xsmall-v2）

| | 最大の差 |
|---|---|
| score（5 組、CPU） | **0.023** |
| score（5 組、ANE） | **0.014** |

fp16 の刻み（この幅では ±0.008 程度）の範囲である。

**並び替えの結果も一致した。** 8 件を並べて、PyTorch と同じ順になった
（2 位と 3 位が 0.001 差の場面も含む）。score そのものより、こちらが本題である。

### 確かめた形（推測しない）

- 組は `<s> 問い </s><s> 本文 </s>`（tokenizer に詰めさせて確認）
- 胴体の重みに **`model.` が付く**（埋め込みモデルには付かない）
- 頭は **プーリング → `head.dense`（bias なし）→ 活性 → `head.norm` → `classifier`（bias あり）**
- `classifier_pooling` は **cls**（先頭のトークンだけ）。config から読む
