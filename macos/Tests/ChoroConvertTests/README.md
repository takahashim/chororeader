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

## いちばん強い審判は別にある

上の 2 つは**形**しか見ない。数が合っているかは見ない。

数の審判は「同じモデルを kohagi と両方で変換し、既存の `CoreMLEmbedderTests`
（凍結済みの fixture、cosine ≥ 0.9999）を両方の束で通す」ことである。
`weight.bin` はバイト一致も見る。

そこまで通って初めて、この変換器は正しいと言える。
