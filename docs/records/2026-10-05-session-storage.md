# セッション保存容量の合成計測

## 条件

- macOS arm64、`xcrun --show-sdk-version`: **27.0**。
- 実行: `python3 scripts/measure_session_storage.py --sessions-root /private/tmp/mac-ambient-jev-storage-measure --seconds 600`。
- 600 秒の 48 kHz stereo float32 CAF。seed 固定の振幅変調した低域 noise。録音は二 channel の平均を mono float32 durable writer へ書く。
- VAD・話者分離・ASR は injected engine。最初の 1 秒を一発話として返す。durable writer、original コピー、import timeline builder、共通確定処理、CAF 生成、export は実装を実行。
- microphone・system audio・GUI・実モデル・権限要求なし。
- bytes は session/export 内の通常ファイルの論理長の合計。metadata を含み、filesystem の割当容量ではない。

## 測定値（ベースライン、コミット ed5d874）

当時の device-rate PCM 保存と 24-bit FLAC export で、同じコマンドを二回実行して同じ bytes を得た。

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

## 測定値（16 kHz・16-bit FLAC 保存後、コミット aa90100）

内部音声を 16 kHz mono float32 PCM にし、確定した録音を 16-bit FLAC へ変換して PCM を削除する実装で、同じコマンドを二回実行した。session・export の全ての bytes が二回で一致した。

| 対象 | 時点 | 600 秒の bytes | 内訳 |
| --- | --- | ---: | --- |
| 録音 session | 録音終了・確定前 | 38,465,201 | PCM 9,600,000 フレーム × 4 byte = 38,400,000 と metadata・索引 65,201 |
| 録音 session | 確定後 | 12,605,358 | `recording.flac` 12,598,092 と metadata 7,266 |
| 録音 export | transcript と FLAC | 12,598,139 | `recording.flac` の無変換コピーと transcript 47 |
| import session | original コピーと処理 timeline 構築直後 | 268,811,048 | original 230,404,096、処理 timeline 38,400,000、metadata |
| import session | 確定後 | 230,411,376 | original 230,404,096 と metadata 7,280 |
| import export | transcript と original | 230,404,143 | original 230,404,096 と transcript 47 |

数値の確認。

- 生の 16-bit mono 16 kHz は 32,000 B/s で、600 秒は 19,200,000 bytes。FLAC は 12,598,092 bytes でこれ以下（約 65.6%）。録音 session の確定後に processing ディレクトリ、derived ディレクトリ、partial はない。残るのは session.json、processing_metadata.json、events.jsonl、`recording.flac`、`storage.json` だけ。
- 1 時間あたりに換算すると 75.6 MB で、生の 16-bit の上限 115.2 MB/h より小さい。fixture は低域 noise で、人声の録音ではない。製品の目安（音声で 1 時間 60〜80 MB、600 秒で 10〜13.3 MB）をこの値で達成したとは主張しない。
- import の確定後は original のコピーに metadata 7,280 bytes を足した大きさで、import の処理 timeline は削除されている。構築直後の 268,811,048 は original と処理 timeline の合計で、確定中の peak ではない。
- ベースラインの録音確定後 230,478,679 に対して 12,605,358、録音 export は 66,362,348 に対して 12,598,139。

レポート: `/private/tmp/mac-ambient-jev-storage-measure/storage-u0biqe39/disk-usage.json`（初回）、`/private/tmp/mac-ambient-jev-storage-measure/storage-aiwww3we/disk-usage.json`（再実行）。いずれも実ファイル・session・export を保持。この測定は 16-bit FLAC の符号化と復号検証を実行している。

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
