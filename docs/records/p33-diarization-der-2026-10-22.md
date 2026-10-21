# P3.3 話者分離 DER 計測記録（2026-10-22）

Mac の FluidAudio（Core ML）と、Linux / Windows の `ONNXCommunity1DiarizationEngine`（ONNX Runtime）を、同一の canonical CAF バイト列に対して比較した記録。手順は [話者分離 DER の計測](../testing.md#話者分離-der-の計測) に従う。

## 結果と判定

標準 DER（`MacAmbientJevEvaluateDiarization` の `standard`、`--min-clean-speech-ms 500`）と raw 話者数。基準は Mac の 1 回目の run。Mac self-disagreement は Mac の 3 回の run の全順序組（6 組）の最大 DER。

| シナリオ | 音声（秒） | 実際の話者数 | Mac self-disagreement | Mac 対 Linux | Mac 対 Windows | Linux 対 Windows | raw 話者数（Mac / Linux / Windows） |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `speakers-2` | 8.629 | 2 | 0.00% | 0.00% | 0.00% | 0.00% | 1 / 1 / 1 |
| `speakers-4` | 15.553 | 4 | 0.00% | 0.00% | 0.00% | 0.00% | 1 / 1 / 1 |
| `speakers-7` | 26.621 | 7 | 0.00% | 0.06%（miss 17 ms / 26,520 ms） | 0.06%（同） | 0.00% | 3 / 3 / 3 |
| `speakers-8` | 29.904 | 8 | 0.00% | 0.00% | 0.00% | 0.00% | 3 / 3 / 3 |
| `speakers-10` | 40.775 | 10 | 0.00% | 0.00% | 0.00% | 0.00% | 3 / 3 / 3 |
| 1 時間 run | 3,644.423 | 8 相当 | 未測定（1 回のみ） | 0.00% | 未実行 | 未実行 | 8 / 8 / — |

- portable の DER が Mac self-disagreement を 1 percentage point 超えて上回るシナリオはない。最大差は `speakers-7` の 0.06 pt。raw 話者数が Mac と portable で食い違うシナリオもない。
- 全シナリオで Mac 自身が実際の話者数より少なく数える（2→1、4→1、7/8/10→3）。これは Mac と portable に共通で、portable 固有の差ではない。実際の話者との DER は採点していない。各話者は 1 発話（約 3〜6 秒）だけなので、短い単発発話を独立の話者として分離できない挙動が共通して出ている可能性があるが、原因は調べていない。
- `speakers-7` の 17 ms の差は、最後の 1 span（`S2`）の終端だけである。Mac は frame 424312、Linux / Windows は frame 424041 で 271 サンプル（16.9 ms、segmentation の 1 frame 相当）の差。span の数、話者割り当て、他の境界は一致する。Linux と Windows は完全に一致するので、差は Core ML と ONNX Runtime の数値差に由来する。

## 実行環境

| 項目 | Mac | Linux | Windows |
| --- | --- | --- | --- |
| Host / OS | Apple M4、10 CPU、16 GiB、macOS 27.0.1 arm64 | Mac と同じ host 上の Docker（`--cpus 4`）。`swift:6.2-noble` image ID `sha256:d6f8f6112e9a63da0a4a151d6b93acd16699d35c0b82531ac1a245f5af210197`、Linux 6.12.76-linuxkit aarch64、Docker の割当 7.75 GiB | VMware Fusion 上の Windows 11 ARM64（NT 10.0.26200）、4 論理 CPU、約 6.5 GiB |
| Swift | 6.4（`swift-driver 1.168.6`） | 6.2.4 | 6.2 |
| Engine | FluidAudio 0.15.8（`OfflineDiarizerConfig.default`、最小 0.3 秒）、Core ML | ONNX Runtime 1.31.0 CPU EP、`--threads 2`（intra-op 2、inter-op 1、CPU memory arena 無効） | 同左 |
| CLI | `MacAmbientJevDiarizeFileOracle`（release） | `MacAmbientJevDiarizeFile`（release） | 同左 |

Linux / Windows の ONNX Runtime SDK は `scripts/fetch_onnxruntime.py` が取得済みの 1.31.0 を使った。Windows では release の exe の隣へ `onnxruntime.dll` をコピーしないと、System32 の 1.17.1 が読まれてバージョン不一致で起動に失敗する（`scripts/test-windows.ps1` と同じ手順）。

モデルの revision（[manifest](../../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Resources/community1_diarization_models.json)）。

| 役割 | repository | revision | SHA-256 |
| --- | --- | --- | --- |
| segmentation（`segmentation-3.0.onnx`） | `avencera/speakrs-models` | `67f963b6a1d94fcd4678948237b3cc8bd69bf1d8` | `038b9717…8ad9` |
| embedding（`wespeaker-multimask-tail.onnx`） | `avencera/speakrs-models` | `67f963b6a1d94fcd4678948237b3cc8bd69bf1d8` | `3695eeb2…c64ea` |
| PLDA（`plda-parameters.json`） | `FluidInference/speaker-diarization-coreml` | `df2625ac79a7ac6b65ad868fee6d80f320da4232` | `38ee28d4…de8f` |
| xvector（`xvector-transform.json`） | `FluidInference/speaker-diarization-coreml` | `df2625ac79a7ac6b65ad868fee6d80f320da4232` | `f7cd5cc1…8688` |

Mac の Core ML モデルは FluidAudio 0.15.8 の Core ML diarizer（`FluidInference/speaker-diarization-coreml`）を `--coreml-directory` で渡した。Windows VM にはこの 2 つの ONNX モデルがなかったため、取得せず、Mac 側で manifest の SHA-256 と一致を確認した 4 ファイルを `scp` で VM に複製し、VM 側でも SHA-256 を照合した。

## 入力

シナリオ音声は VOICEVOX engine 0.25.2（ローカルの macOS arm64 binary `engine/macos-arm64/run`、`/version` の返り値）で [`voicevox-ja-core-v1.json`](../../tools/corpora/voicevox-ja-core-v1.json) の `diarization_scenarios` から生成した。話者は `/speakers` の順に 1 キャラクター 1 スタイルずつ取る。

| 話者 | キャラクター | Style (ID) |
| --- | --- | --- |
| 1 | 四国めたん | ノーマル (2) |
| 2 | ずんだもん | ノーマル (3) |
| 3 | 春日部つむぎ | ノーマル (8) |
| 4 | 雨晴はう | ノーマル (10) |
| 5 | 波音リツ | ノーマル (9) |
| 6 | 玄野武宏 | ノーマル (11) |
| 7 | 白上虎太郎 | ふつう (12) |
| 8 | 青山龍星 | ノーマル (13) |
| 9 | 冥鳴ひまり | ノーマル (14) |
| 10 | 九州そら | ノーマル (16) |

`speakers-N` は先頭の N 人を使う。各話者は発話 1 つ。

| シナリオ | 秒 | サンプル数 | 実測 overlap 比 | canonical CAF の SHA-256 |
| --- | ---: | ---: | ---: | --- |
| `speakers-2` | 8.629 | 138,064 | 0.0000 | `5a2cd991e3005b6436d3633e95898b1afec00b1413a67044ecf815d28978f787` |
| `speakers-4` | 15.553 | 248,843 | 0.0087 | `6050ab0af66939c57e57b0e6560c4ede65bb29beecda5b2f6493e498639cd047` |
| `speakers-7` | 26.621 | 425,931 | 0.0130 | `35ea035b3e52abac53524a0471b4ef79f9a19b3f30401c1c8ddb75fd18446706` |
| `speakers-8` | 29.904 | 478,459 | 0.0115 | `d99de1814a299a2efbb14202299ea4010b7ff58401a41e8af4d55697a7848089` |
| `speakers-10` | 40.775 | 652,395 | 0.1046 | `cb243581241359537020330ffc44939714f18bbffccd8a914de74806b23d901d` |
| 1 時間 run | 3,644.423 | 58,310,760 | — | `a8b949c28ef7b1007fff68854b28c8e66803567d98e5f29f6d5d89247afad3e7` |

各 run JSON の `audio.sha256` は 3 プラットフォームで一致し、Windows に複製した CAF の SHA-256 も Mac の値と一致した。

1 時間 run の入力は、`speakers-2`、`4`、`7`、`8`、`10` の `audio.wav` をこの順に連結し、これを 30 回繰り返した WAV（5 本の合計 121.48 秒 × 30）を `prepare_canonical_caf.py` で変換したもの。同じ声が繰り返されるため、DER ではなくメモリと時間の確認に使う。

## 実行時間とピークメモリ

`wall_time_seconds`（diarize 1 回、モデル読み込みを除く）、`prepare_seconds`（モデル読み込み）、`peak_rss_bytes`（MiB）。Mac は 3 回の run の範囲、Linux / Windows は 1 回。短い run は 1 回ずつで、反復の分散は測っていない。

| シナリオ | Mac wall (s) | Mac RSS | Linux wall (s) | Linux RSS | Windows wall (s) | Windows RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `speakers-2` | 0.100〜0.116 | 120〜128 | 1.08 | 125.9 | 1.28 | 113.0 |
| `speakers-4` | 0.133〜0.139 | 138〜139 | 1.87 | 124.8 | 2.24 | 112.7 |
| `speakers-7` | 0.226〜0.236 | 181〜182 | 3.45 | 124.9 | 4.17 | 113.1 |
| `speakers-8` | 0.242〜0.244 | 188 | 3.72 | 125.1 | 4.40 | 113.1 |
| `speakers-10` | 0.316〜0.329 | 190〜194 | 5.44 | 124.9 | 6.03 | 113.2 |
| 1 時間 run | 17.60 | 400.2 | 538.00 | 125.6 | 未実行 | 未実行 |

`prepare_seconds` は Mac が 0.12〜0.13 秒（初回 0.90 秒）、1 時間 run が 0.45 秒、Linux が 0.17〜0.21 秒、Windows が 0.26〜0.30 秒。Windows の `peak_rss_bytes` は 0 でない。

- Linux のピーク RSS は 40 秒でも 3,644 秒でも 125 MiB 前後で増えない。Mac は音声長に応じて 120 MiB から 400 MiB に増える。portable の 1 時間 run のメモリは 125.6 MiB で済んだ。
- Linux の 1 時間 run は 538 秒で、RTF は 0.148（`--cpus 4`、ONNX Runtime 2 thread）。Mac は 17.6 秒（RTF 0.0048）で約 30 倍速い。短い run でも Linux は Mac の約 10〜17 倍の時間がかかる。この比は Core ML（Neural Engine / GPU）と ONNX Runtime CPU 2 thread の差で、最適化はしていない。
- この時間は同じ host 上の Docker と VM の値で、bare-metal の Linux / Windows の値ではない。Windows は Linux より 11〜21% 遅い。VM の 4 論理 CPU、Docker の `--cpus 4` と割当が違うので、OS 間の速度差とは言えない。

## 再現コマンド

作業 directory は `/Users/pokojaka/ml/p33-diarization/der`（`$WORK`）。音声、CAF、run JSON は commit しない。

```bash
# 1. シナリオ音声と canonical CAF
voicevox/run --host 127.0.0.1 --port 50021 &
python3 tools/linux-audio/generate_voicevox_diarization_scenarios.py \
  --base-url http://127.0.0.1:50021 --manifest tools/corpora/voicevox-ja-core-v1.json \
  --output-root "$WORK/scenarios" --scenario speakers-2 --scenario speakers-4 \
  --scenario speakers-7 --scenario speakers-8 --scenario speakers-10
python3 scripts/prepare_canonical_caf.py --wav "$WORK/scenarios/speakers-4/audio.wav" --output "$WORK/speakers-4.caf"   # 5 本とも

# 2. Mac（シナリオごとに 3 回）
swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevDiarizeFileOracle --jobs 4
app/MacAmbientJev/.build/release/MacAmbientJevDiarizeFileOracle --audio "$WORK/speakers-4.caf" \
  --coreml-directory "$COREML" --output "$WORK/mac-4-1.json"

# 3. Linux（Docker 1 container、事後に git checkout -- app/MacAmbientJev/Package.resolved）
docker run --rm --cpus 4 -v "$PWD:/repo" -v "$WORK:/der" -v "$MODELS:/models/community1:ro" \
  -w /repo swift:6.2-noble bash /der/linux-run.sh
#  linux-run.sh: MAC_AMBIENT_JEV_SILERO_MODEL / MAC_AMBIENT_JEV_QWEN3_TOKENIZER を設定し、
#  swift build -c release --product MacAmbientJevDiarizeFile --scratch-path /tmp/lb --jobs 4 の後、
#  MacAmbientJevDiarizeFile --audio /der/speakers-4.caf --model-directory /models/community1 --threads 2 --output /der/linux-4.json

# 4. Windows（CAF とモデルを VM へ scp、Windows PowerShell）
winvm run . -- 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\codextest\j13b-run.ps1'
#  j13b-run.ps1: swift build -c release --product MacAmbientJevDiarizeFile --jobs 4、onnxruntime.dll を bin にコピー、
#  各 CAF を --threads 2 で実行

# 5. 1 時間 run
python3 -I concat_long.py "$WORK/long-1h.wav" 30 speakers-2.wav speakers-4.wav speakers-7.wav speakers-8.wav speakers-10.wav
python3 scripts/prepare_canonical_caf.py --wav "$WORK/long-1h.wav" --output "$WORK/long-1h.caf"

# 6. 採点
python3 scripts/compare_diarization_runs.py --min-clean-speech-ms 500 \
  --runs "$WORK/mac-4-1.json" "$WORK/mac-4-2.json" "$WORK/mac-4-3.json" --output "$WORK/cmp-4-macself.json"
python3 scripts/compare_diarization_runs.py --min-clean-speech-ms 500 \
  --reference-run "$WORK/mac-4-1.json" --hypothesis-run "$WORK/linux-4.json" --output "$WORK/cmp-4-mac-linux.json"
```

## 所見と限界

- 3 プラットフォームの出力は実質同一で、standard DER の差は最大 0.06 pt。`speakers-7` の 1 span の終端が 1 frame ずれたことが唯一の差。
- 比較に使ったシナリオは 8.6〜40.8 秒と短く、各話者は 1 発話である。話者が複数回交代する会議音声、重なりの多い音声、実録音での parity はこの記録では測っていない。DER が 0 になるのは、双方が同じ（過少な）クラスタリングに到達したからでもある。
- 実際の話者との DER（speaker-reference.json に対する採点）は行っていない。Mac も portable も 2→1、4→1、7/8/10→3 と過少に数えている。
- 1 時間 run の Mac と Linux は 8 話者・DER 0.00% で一致した。ただし同じ 121 秒を 30 回繰り返した入力であり、実音声の 1 時間ではない。Windows の 1 時間 run は測っていない。
- ピーク RSS はプロセス全体の値で、Linux は Docker 内、Windows は VM 内の値。
