# P3.5 ポータブル CLI end-to-end 記録（2026-10-22）

Linux と Windows で `MacAmbientJevProcessRecording` を ONNX engine で動かし、音声ファイルから確定 transcript までを通した記録。手順と判定は [testing.md](../testing.md) のポータブル full-model の受入の節に従う。

## 結果と判定

受入基準は、正規化 CER `0.15` 以下と、受入 driver のすべての検査（区間、話者ラベル、run と provenance、発話文判定の完了、セッションのファイル、resume の出力一致）。全環境で基準を満たした。

| 環境 | 数値テスト（実行件数） | 受入 driver | 正規化 CER | 区間数 |
| --- | --- | --- | ---: | ---: |
| GitHub Actions `linux-model-e2e`（Linux x64、`swift:6.2-noble`） | Silero 3、Qwen3-ASR 9、Community-1 7、clause tagger 9 | 合格 | 0.1319 | 2 |
| Windows 11 ARM64（VMware Fusion、Apple M4 上） | Silero 3、Qwen3-ASR 8、Community-1 7、clause tagger 9 | 合格 | 0.1319 | 2 |

- 両環境の CER は一致した。
- Windows の通常テストは 1,113 件がすべて通った。
- Windows ARM64 では、Community-1 segmentation の Core ML との差が aarch64 Linux より大きかった。
  - 音声 window の log-probability の差は 3.3e-4。
  - 無音 window では、log-probability の差が 5.49、確率の差が 3.0e-3。
  - argmax、embedding（cosine 0.99991 以上）と engine の話者区間は Core ML と一致した。許容値は [testing.md](../testing.md) の値に広げた。
- Qwen3-ASR の実行件数の違いは、環境変数で有効になる model test の数の差による。

## 入力と構成

| 項目 | 値 |
| --- | --- |
| 音声 | `qwen3_asr_voicevox_long.wav`（18.464 秒、VOICEVOX:ずんだもん）。参照文と SHA-256 は [windows.md](../windows.md) の表 |
| ASR | Qwen3-ASR 0.6B int4（ONNX）、intra-op 2 threads |
| VAD / 話者分離 / 発話文判定 | Silero VAD ONNX、Community-1 ONNX、clause tagger ONNX（state revision `90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9`） |
| CLI | `--keep-session --with-decisions --threads 2` で import、モデルの環境変数を外して inspect、同じ session を resume |
| ONNX Runtime | 1.31.0 CPU EP |

## 実行時間

| 環境 | 内容 | 時間 |
| --- | --- | --- |
| GitHub Actions | `linux-model-e2e` job 全体、model cache なし | 13 分 58 秒 |
| GitHub Actions | 同、model cache あり | 9 分 10 秒 |
| Windows VM | `scripts/test-windows.ps1 -FullModel` 全体（通常テストを含む） | 9 分 25 秒 |

## 測定上の注意

- この CER は 1 本の短い音声での配線確認で、コーパスでの品質ではない。1.7B のコーパス CER は [qwen3-asr-onnx-cer-2026-10-20.md](qwen3-asr-onnx-cer-2026-10-20.md)、話者分離の比較は [p33-diarization-der-2026-10-22.md](p33-diarization-der-2026-10-22.md)、発話文判定の parity は [p34-clause-tagger-onnx-parity-2026-10-22.md](p34-clause-tagger-onnx-parity-2026-10-22.md) にある。
- ピーク RSS は測っていない。
- Windows の結果は ARM64 の VM のもので、Windows x64 では full-model 受入を実行していない。Windows CI（x64）は build と通常テストだけを行う。
