# Live transcription latency measurement

The measurements in this document's earlier revision used provisional rolling ASR. That path has since been removed, so those numbers do **not** describe the current application and must not be used as current latency evidence. In particular, the historical 1.935s P95 is not a measurement of closed-VAD transcription.

## Current measurement

`scripts/measure_live_latency.sh` replays an existing audio file at original playback speed into `DurableAudioWriter`, then uses `LiveVADSession`, `LiveASRSession` through `NativeSessionProcessor`, and `processFinalTranscript` at stop. It records the first nonempty transcript update delivered to the replay view-model callback. Per-segment latency is computed from `SegmentReference.endFrame / processingSampleRate` (end of the VAD speech segment) to that first update. It reports P50/P95/maximum, individual measured latencies, segment count, update count, missing count and IDs, transcript text, input and processing formats, timeline duration, and the final-processing disposition.

The default processing format is the audio file's decoded processing sample rate and channel count. `--match-default-input` reads the default capture device's `activeFormat` to select matching sample rate and channels; this is a read-only format lookup and **does not start capture or record microphone audio**. Explicit `--sample-rate` and `--channels` options can select another processing format. When source and target formats differ, the replay converts the audio while preserving playback duration and speed.

The metric starts at the end frame detected by VAD, so it excludes microphone hardware and VAD's wait to commit a durable audio checkpoint. It includes checkpoint polling, VAD segment closure availability, live ASR queue/inference, and callback delivery. No audio files are bundled with the application or distribution archive.

### 30-second 青空朗読スモーク計測

2026-09-25、[「よだかの星」](https://aozoraroudoku.jp/voice/rdp/rd001.html)の冒頭30秒を元速度で投入した。元音声と処理タイムラインはどちらも 44,100 Hz・1 ch で、30秒に相当する 1,323,000 フレームを保存した。6区間のすべてで非空本文が届き、未表示は0件だった。発話終了から最初の非空更新までの P50 は **3.804秒**、P95 は **5.789秒**。3秒の目標には達していない。なお、マイク機器からの取得と画面描画時間は含まれない。

## Reproduction

The implementation task's planned fixtures are the full-length `ごん狐` recording, the two-reader `よだかの星` recording after its actual speaker changes are listened to and annotated, and an A→B→A→B constructed excerpt from the distinct-reader recordings. Run the same source once using its native decoded format and, when available, once using the machine's read-only default-input format:

```bash
scripts/measure_live_latency.sh /private/tmp/mac-ambient-jev-gongitsune-full.wav
scripts/measure_live_latency.sh --match-default-input /private/tmp/mac-ambient-jev-gongitsune-full.wav
scripts/measure_live_latency.sh /private/tmp/mac-ambient-jev-two-readers-abab.wav
scripts/measure_live_latency.sh --match-default-input /private/tmp/mac-ambient-jev-two-readers-abab.wav
```

The command requires cached Qwen and FluidAudio VAD models. It prints one JSON object to stdout. Keep stdout as the machine-readable measurement record and capture compiler/model progress from stderr separately. A missing segment counts against coverage and is excluded only from the latency percentile; `latency_sample_count`, `segment_count`, and `missing_count` make the percentile denominator explicit. Do not compare its numbers with the historical provisional-ASR table.

## Historical provisional-ASR measurements (superseded)

These results are retained solely to preserve the prior experiment record. They used `LivePartialASRSession` and measured speech onset to provisional update, which is a different metric and a code path no longer used:

| Historical fixture and change | Audio | Attempts | Utterances / first updates | No first update | First-visible P50 | P95 / max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `_smoke/audio.wav`, 1s chunk / 1s poll | 20s | 9 | 2 / 2 | 0 | 2.459s | 3.831s |
| `_smoke/audio.wav`, 0.5s chunk / 0.25s poll | 20s | 9 | 2 / 2 | 0 | 1.438s | 2.195s |
| Conversation excerpt, before bounded snapshots | 75s | 35 | 6 / 5 | 1 | 2.812s | 11.703s |
| Conversation excerpt, 4s rolling snapshots and first-snapshot priority | 75s | 35 | 6 / 6 | 0 | 1.159s | 1.935s |

The old 75-second result had six utterances and used 4-second rolling provisional snapshots at 2-second cadence. Those details explain the historical figures only; they are not current pipeline behavior or a 3-second P95 claim for the current pipeline.
