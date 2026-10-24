# P3.4 発話文タガー ONNX parity 記録（2026-10-22）

Mac の Core ML 版発話文タガーと、Linux / Windows の `ONNXClauseTagger`（ONNX Runtime）の出力を、同じ token ID と同じ request に対して比較した記録。手順は [testing.md](../testing.md) の発話文モデルの parity と ONNX 書き出しの節に従う。

## 結果と判定

受入基準は各 head の最大絶対誤差 `1e-3` 以下。全項目で基準を満たした。

| 比較 | boundary | span | priority |
| --- | ---: | ---: | ---: |
| 書き出し時：ORT 対 eager PyTorch、長さ 2〜192 の全長（tokenizer 由来と seed 付き乱数 ID） | 2.03e-6 | 2.44e-6 | 7.45e-9 |
| 書き出し時：ORT 対 committed fixture 13 件 | 1.13e-6 | 5.96e-7 | 3.03e-9 |
| Linux：`ONNXClauseTagger` 対 committed fixture 13 件 | 1.67e-6 | 8.34e-7 | 6.98e-9 |
| Linux：boundary request fixture 6 件（応答確率） | 1.07e-6 | — | — |
| Linux：priority batch fixture（確率と confidence） | — | — | 1.12e-8 |

- request fixture の候補、label、token 数、filler 範囲、projected text は完全一致した。`まあ、あの、今日は損失関数の話をします。` は `今日は損失関数の話をします。` になる。
- tokenizer は portable Unigram 実装で、Mac の旧 swift-transformers tokenizer から取った 47 cases・106 pieces の golden と、macOS・Linux・Windows のすべてで完全一致した。
- Mac の Core ML 版は tokenizer 差し替え後も request fixture との差が全 head で 0.0。
- 同じ入力で 2 回書き出すと、`ClauseTagger.onnx` の数値誤差は同じだが、バイト列は一致しなかった（SHA-256 が異なる）。どこが異なるかは調べていない。

## モデルの識別

| 項目 | 値 |
| --- | --- |
| ClauseTagger.onnx | 146,889,561 bytes、SHA-256 `8f9e7d3e4f72f2b7d18db1c59bac6b9506d135f976512ae8afbff1386687b699`、opset 18、507 nodes |
| tokenizer.json | 6,724,873 bytes、SHA-256 `0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062` |
| model state revision | `90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9` |

現在の配布形式とファイル pins は [モデルの同梱と更新](../decision-engine.md#モデルの同梱と更新) を参照。

## 実行環境

| 項目 | Mac | Linux | Windows |
| --- | --- | --- | --- |
| Host / OS | Apple M4、macOS 27.0.1 arm64 | Mac と同じ host 上の Docker（`--cpus 4`）、`swift:6.2-noble`、aarch64 | VMware Fusion 上の Windows 11 ARM64 |
| Swift | 6.4 | 6.2 | 6.2 |
| Engine | Core ML（CPU only、float32） | ONNX Runtime 1.31.0 CPU EP、intra-op 4、inter-op 1、CPU memory arena 無効 | 同左 |
| 書き出し | torch 2.12.0、transformers 5.12.0、Python 3.12、ORT 1.31.0 | — | — |

Windows は `scripts/test-windows.ps1` の全テスト（1,063 件）が通ったことを確認した。Windows での per-head 最大誤差の数値は記録していない。Linux は `scripts/verify_portable.sh` の全テスト（1,046 件）が通った。

## 測定上の注意

- `ONNXClauseTagger` の初期化は、debug build の Linux Docker で約 19 秒かかる。147 MB のモデルファイルの SHA-256 検証と session 作成の内訳、release build での時間は測っていない。
