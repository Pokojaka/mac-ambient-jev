# セッション保存容量の合成計測

## 条件

- macOS arm64、`xcrun --show-sdk-version`: **27.0**。
- 実行: `python3 scripts/measure_session_storage.py --sessions-root /private/tmp/mac-ambient-jev-storage-measure --seconds 600`。
- 600 秒の 48 kHz stereo float32 CAF。seed 固定の振幅変調した低域 noise。録音は二 channel の平均を mono float32 durable writer へ書く。
- VAD・話者分離・ASR は injected engine。最初の 1 秒を一発話として返す。durable writer、original コピー、import timeline builder、共通確定処理、CAF 生成、export は実装を実行。
- microphone・system audio・GUI・実モデル・権限要求なし。
- bytes は session/export 内の通常ファイルの論理長の合計。metadata を含み、filesystem の割当容量ではない。

## 測定値

現行の device-rate PCM 保存と 24-bit FLAC export で、同じコマンドを二回実行して同じ bytes を得た。

| 対象 | 時点 | 600 秒の bytes |
| --- | --- | ---: |
| 録音 session | 録音終了・確定前 | 115,267,578 |
| 録音 session | 確定後 | 230,478,679 |
| 録音 export | transcript と FLAC | 66,362,348 |
| import session | original コピーと処理 timeline 構築直後 | 460,811,245 |
| import session | 確定後 | 691,222,346 |
| import export | transcript と original | 230,404,143 |

import の構築直後は CAF 生成中の peak ではない。source fixture は session 外にあり、session bytes には含めない。noise の圧縮率は人声の容量・認識精度の測定ではない。

再実行のレポート: `/private/tmp/mac-ambient-jev-storage-measure/storage-3bsyeesp/disk-usage.json`。初回: `/private/tmp/mac-ambient-jev-storage-measure/storage-lvfs_sx7/disk-usage.json`。いずれも実ファイル・session・export を保持。

## SDK API の根拠

SDK 27.0 を確認してから Apple の現行文書を読んだ。

- [kAudioFormatFLAC](https://developer.apple.com/documentation/coreaudiotypes/kaudioformatflac): macOS 10.13 以降、source bit depth を flags で表す FLAC format ID。
- [AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile): PCM buffer による encode/decode、framePosition によるランダムアクセス、close と sequential read/write。
- [AVAudioConverter](https://developer.apple.com/documentation/avfaudio/avaudioconverter): PCM sample-rate/bit-depth 変換、compressed encode/decode。sample-rate/codec 変換には input block を使う API が必要。

測定の録音 export は現行 ProcessingTimelineAudioExporter の AVAudioFile + kAudioFormatFLAC + 24-bit settings を実行し、エラーなく完了した。この測定は 16-bit FLAC の動作確認ではない。

## 検証

リポジトリルートから逐次実行し、すべて終了コード 0。

- `python3 -B scripts/check_portable_core.py`
- `python3 scripts/check_doc_references.py`
- `swift build --package-path app/MacAmbientJev`
- `swift test --package-path app/MacAmbientJev`（通常 suite の容量 harness と real-model smoke は無効）
- `bash scripts/verify_v1.sh`（app bundle は build/sign のみ、起動なし）
- 容量 harness の二回目は Swift Testing 1 test 成功、37.787 秒。driver 全体 68.09 秒。

既存の Swift region-isolation warning、LiveTranscriptViewTests の actor-isolation warning、MLX bundle build warning が出た。CAF writer の non-interleaved setting を無視する AVFoundation warning も出た。終了失敗はない。Linux-audio は変更せず、その pytest は実行していない。
