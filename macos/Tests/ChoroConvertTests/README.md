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
