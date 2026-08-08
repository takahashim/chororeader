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

## いちばん強い審判（実物）

上の 2 つは**形**しか見ない。数が合っているかは見ない。
数の審判は実物のモデルが要るので、検査には入れず、手順として残す。

```sh
SNAP=$(dirname $(find ~/.cache/huggingface/hub -name "model.safetensors" -path "*ruri-v3-130m*" | head -1))

# 変換する
swift build -c release
.build/release/choro-convert --model-path "$SNAP/model.safetensors" \
  --config-path "$SNAP/config.json" \
  --sequence-lengths 64,128,256,512,1024,2048 --out-dir /tmp/mine
cp "$SNAP/tokenizer.json" "$SNAP/config.json" /tmp/mine/
mkdir -p /tmp/mine/1_Pooling && cp "$SNAP/1_Pooling/config.json" /tmp/mine/1_Pooling/

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
