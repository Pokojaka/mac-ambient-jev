# アーキテクチャ

Mac Ambient Jev は、保存音声を基にローカルで文字起こしを作る Swift アプリです。音声保存と推論を分離し、認識・話者分離・BTSJ 発話文の境界・優先度の結果をイベントとして保持します。画面や書き出しは、公開済み run のイベントから組み立てます。保存形式の詳細は [storage.md](storage.md) を参照してください。

## パッケージとモジュール

定義の正本は [Package.swift](../app/MacAmbientJev/Package.swift) です。Swift tools version は 6.0、macOS の最低バージョンは 15 です。

### 共通ターゲット

macOS 以外でも定義される共通 Core / Pipeline ターゲットには外部 Swift パッケージ依存がありません。Windows の Core は、リポジトリ内の `CWindowsSession` target を使って OS のファイル API を呼び出します。Windows / Linux の target 構成は後述します。

| ターゲット | 種類 | 責務・直接依存 |
| --- | --- | --- |
| `MacAmbientJevCore` | library | セッション・イベント・タイムラインの型、保存と復旧、`DecisionProvider` protocol と共有判定型、段階 coordinator、materialization、判定 batch と優先度処理、純粋な `ClauseTaggerEncoding`、CER・話者分離の評価、純粋な Swift / Foundation による録音 FLAC（16 kHz mono 16-bit）の streaming encoder / decoder、CRC / MD5 検証、bounded random-access frame index、共通の `CanonicalAudioConverting` contract と `ImportedAudioTimelineWriter`。Windows でのみ `CWindowsSession` に依存 |
| `MacAmbientJevPipeline` | library | Core のみ依存。`LiveASRSession` / `LiveContentPrioritySession` / `LiveVADSession` / `VADTimelineProcessor` / `NativeSessionProcessor` / `FinalTranscriptPipeline` の orchestration と `FinalTranscriptVADSegmenter` / `SessionProcessingAudioHandling` / `VADChunkSegmenting`、検証済み録音 reader と `RecordingAudioCompactor`、[CaptureSafety](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/CaptureSafety.swift) / `TimestampedMonoSink` / `RawInputMeter` / `CaptureFrameTimestampMapper` / `SystemAudioOutputMonitor` / `MicInputVolumeController`、`LiveTranscriptionState` / `LiveTranscriptionCoordinator` / `SessionProcessingCoordinator` とその Effects / Executing protocols、`RecordingLifecycle` / `SessionProcessingQueue` / `SavedSessionOperations`、`ThermalMonitoring` を所有 |
| `MacAmbientJevEvaluateSession` | executable | 参照文付きセッションの ASR 評価。Core に依存 |
| `MacAmbientJevPipelineTests` | test | Pipeline と Core に依存 |
| `MacAmbientJevEvaluateASR` | executable | ASR artifact の CER 評価。Core に依存 |
| `MacAmbientJevEvaluateDiarization` | executable | 話者分離 artifact の評価。Core に依存 |
| `MacAmbientJevCoreTests` | test | Core に依存 |

### Windows ターゲット

Windows の OS file adapter は [CWindowsSession.c](../app/MacAmbientJev/Sources/CWindowsSession/CWindowsSession.c) と [SessionFileAccessWindows.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionFileAccessWindows.swift) にあります。audio decoder / resampler の詳細と実行範囲は [windows.md](windows.md) を参照してください。

| ターゲット | 種類 | 責務・直接依存 |
| --- | --- | --- |
| `CWindowsSession` | C target | 固定した Windows handle を基点にした session file access と storage API。Windows の Core が利用 |
| `CWindowsAudio` | C++ target | read-only IStream byte stream 上で Media Foundation AAC Source Reader を動かす。`CWindowsAudio` から元 URL を再オープンしない |
| `CMiniaudio` | C target | 同梱 miniaudio 0.11.23 と狭い C wrapper。WindowsSupport が WAV / FLAC / MP3 decode と linear LPF8 SRC に利用。Linux にも同 target を定義し、macOS では定義しない |
| `MacAmbientJevWindowsSupport` | library | bounded streaming audio import / canonical timeline builder と miniaudio resampler。Core、`CMiniaudio`、`CWindowsAudio` に依存 |
| `MacAmbientJevWindowsSupportTests` | test | WindowsSupport の decoder、timeline writer、SRC のテスト。Core、WindowsSupport、`CMiniaudio` に依存 |

WindowsSupport は import API までで、live capture、UI、engine を含む処理 pipeline には接続されていません。WASAPI backend は capture path 向けに `CMiniaudio` にコンパイルされますが、Windows capture 実装はありません。

### Linux ターゲット

| ターゲット | 種類 | 責務・直接依存 |
| --- | --- | --- |
| `CMiniaudio` | C target | `Package.swift` が Linux でも定義する miniaudio target。macOS 固有 framework に依存しない。WindowsSupport / `CWindowsSession` / `CWindowsAudio` は Linux target では定義しない |

### macOS 限定ターゲット

macOS の Package は `CMiniaudio` と Windows targets を定義せず、AVFoundation の decoder / converter を AppleSupport に保持します。共通コアと評価 CLI の実行範囲・ビルド手順は [windows.md](windows.md) を参照してください。

| ターゲット | 種類 | 責務・直接依存 |
| --- | --- | --- |
| `MacAmbientJevAppleSupport` | library | 判定 provider factory、Core ML 発話文 tagger と tokenizer、AVFoundation による import 音声の bounded decode と stateful canonical SRC、処理タイムラインからの CAF 書き出し、保存済み文字起こし読取と SessionExport.swift。Core の FLAC codec と import timeline writer を利用する。Core と swift-transformers Tokenizers / Hub に依存 |
| `MacAmbientJevCapture` | library | Apple のマイク・システム音声 capture、Core Audio tap、権限、OS adapter と入力音量制御。Core、Pipeline、AppleSupport に依存 |
| `MacAmbientJevRuntime` | library | Mac 推論 engine と adapter。FluidAudio VAD・offline diarization、Qwen3-ASR、`MacSessionProcessingAudio` / `MacLiveVADSessionFactory` / `MacThermalMonitor` を提供する。Core、Pipeline、AppleSupport、FluidAudio、Qwen3ASR、MLX に依存 |
| `MacAmbientJev` | executable | SwiftUI 表示と platform effects。Core、Pipeline、AppleSupport、Capture、Runtime に依存 |
| `MacAmbientJevCaptureSystemAudio` | executable | システム音声のキャプチャと確定処理。Core、Pipeline、Capture、Runtime、MLX に依存 |
| `MacAmbientJevProcessRecording` | executable | ファイル処理、セッションの inspect と resume、JSON と計測の出力。Core、Pipeline、AppleSupport、Runtime、MLX に依存 |
| `MacAmbientJevMeasureLiveLatency` | executable | 音声ファイルの再生速度に合わせたライブ処理の遅延計測。Core、Pipeline、AppleSupport、Runtime に依存 |

macOS 限定の test target は `MacAmbientJevProcessRecordingTests`、`MacAmbientJevMeasureLiveLatencyTests`、`MacAmbientJevAppTests`、`MacAmbientJevCaptureTests`、`MacAmbientJevCaptureSystemAudioTests`、`MacAmbientJevAppleSupportTests`、`MacAmbientJevRuntimeTests` です。共通の `MacAmbientJevPipelineTests` は Windows / Linux でも定義されます。

macOS の外部依存は FluidAudio 0.15.8、speech-swift の revision `c4c2fabbe825a9290c19e2f45d54ca3eae96b003`、mlx-swift 0.31.6、swift-transformers 1.3.4 です。Runtime が speech-swift の Qwen3ASR product を使い、音声認識の外部モデル ID は aufklarer/Qwen3-ASR-1.7B-MLX-8bit です（リポジトリパスではありません）。発話文 tokenizer は AppleSupport が swift-transformers Tokenizers 1.3.4 を直接使います。

## Portable Core の境界

Core と Pipeline は Apple 専用 framework adapter を持ちません。[scripts/check_portable_core.py](../scripts/check_portable_core.py) は両 target の Swift ファイルを走査し、AVFoundation、AppKit、CoreAudio、CoreML、Security、SwiftUI、AudioToolbox、CryptoKit、IOKit、CoreMedia、Combine、ScreenCaptureKit、FluidAudio、MLX / Qwen3ASR、AppleSupport、Runtime、Capture などの import を禁止します。Darwin・Glibc・WinSDK は対応する OS / canImport の正の条件分岐内に限ります。Windows の OS file API は条件付きの `CWindowsSession` target に隔離します。Foundation、Synchronization による保存・同期は Core に置かれます。録音 FLAC codec の `RecordingFLAC`、`FLACTimelineReader` と bitstream / frame decoder / MD5 実装も Core にあり、Foundation と `SessionFileAccess` を使い、Apple framework や外部 Swift package に依存しません。Encoder は bounded block 単位で書き込み、reader は CRC / MD5 を検証し bounded random-access frame index を構築します。Core に置く音声 import API は platform-neutral な `CanonicalAudioConverting` contract、mean-channel `ImportedAudioPCM.downmix`、5 秒 chunk を使う `ImportedAudioTimelineWriter` です。音声 decoder / SRC 実装は Core に OS import を追加せず、AppleSupport の AVFoundation converter と WindowsSupport の miniaudio converter に分離します。`DecisionProvider` は Core ML tagger が実装する判定 protocol で、Core 内の `ClauseTaggerEncoding` は tokenizer を受け取る純粋な符号化ロジックです。Core ML と tokenizer の実装・依存は AppleSupport に置き、Core は portable のまま維持します。**portable は「純粋関数だけ」という意味ではありません。**

実推論は Core の `ASREngine` と `DiarizationEngine` に対する Mac Runtime の実装です。Windows engine は未実装です。[`SessionProcessingAudioHandling`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift)、確定 VAD の [`FinalTranscriptVADSegmenter`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift)、live / final の VAD chunk 入力を表す [`VADChunkSegmenting`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/VADTimelineProcessor.swift) の protocol は Pipeline が所有し、Mac Runtime にそれぞれ [`MacSessionProcessingAudio`](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/MacSessionProcessingAudio.swift)、[`FluidFinalTranscriptVADSegmenter`](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidFinalTranscriptVADSegmenter.swift)、[`FluidVADSegmentationEngine`](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADSegmentationEngine.swift) の実装があります。`MacSessionProcessingAudio` は import の timeline 作成を `AudioFileTimelineBuilder` に依頼し、import timeline metadata を保存します。録音 reader と compaction は Pipeline の検証済み reader / `RecordingAudioCompactor` を使い、diarization 用 CAF 書き出しは AppleSupport の `ProcessingTimelineAudioExporter` に委譲します。AVFoundation による import decode / SRC と CAF exporter は AppleSupport にあり、portable な録音 reader / compactor とは分離されています。WindowsSupport の音声 import は Windows engine や確定処理へ接続されていません。Core の音声 ingress は Foundation-only の `CanonicalAudioConverting` を受け取り、stateful AVAudioConverter adapter は AppleSupport、Windows import の miniaudio resampler は WindowsSupport に置きます。`ThermalMonitoring` は Pipeline の protocol で、`isCritical` と live ASR の `liveASRDecision` policy を公開します。Runtime の `MacThermalMonitor` は nonoptional な `state: ProcessInfo.ThermalState` と `pressure: ThermalPressure` を持ち、`@unknown default` の pressure は live policy 用に `.critical` となります。一方 `isCritical` は raw state が `.critical` の場合だけ true となり、確定処理の pause / resume に使います。Windows の `WindowsNoThermalMonitoring` は熱状態を読み取らず、`isCritical == false` と `.processNow` を返します（nominal state を偽装しません）。Mac の `MacThermalStateObservation` は Apple の要件に従い、notification 登録の直前に実際の `ProcessInfo.processInfo.thermalState` を読みます。AppState は通知を受けて coordinator に再開を依頼し、thermal state を直接読みません（[Apple API](https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification)）。入力装置や権限は Capture、SwiftUI と platform effects は App に分離します。Linux のモデル runner は [tools/linux-audio](../tools/linux-audio) にあり、Swift アプリの Runtime 依存には入りません。

根拠: [CanonicalAudio.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/CanonicalAudio.swift)、[ASR.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASR.swift)、[Diarization.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Diarization.swift)、[ClauseTypes.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTypes.swift)、[ClauseTaggerEncoding.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerEncoding.swift)、[LocalClauseTagger.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)、[ClauseTaggerTokenizer.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerTokenizer.swift)、[ClauseTaggerModel.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerModel.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift)、[CanonicalAudioResampler.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/CanonicalAudioResampler.swift)。

録音 FLAC codec の Core 実装: [RecordingFLAC.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/RecordingFLAC.swift)、[FLACTimelineReader.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/FLACTimelineReader.swift)、[FLACFrameDecoder.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/FLACFrameDecoder.swift)、[FLACBitstream.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/FLACBitstream.swift)、[FLACMD5.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/FLACMD5.swift)。検証済み recording reader と compactor は Core API を利用する Pipeline にあります: [RecordingAudioCompactor.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/RecordingAudioCompactor.swift)、[SessionAudioReaders.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionAudioReaders.swift)。SessionExport.swift と AVFoundation の import decode / SRC、CAF exporter は AppleSupport にあります: [SessionExport.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/SessionExport.swift)、[AudioFileTimelineBuilder.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[CanonicalAudioResampler.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/CanonicalAudioResampler.swift)、[ProcessingTimelineAudioExporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ProcessingTimelineAudioExporter.swift)。FLAC format specification: [RFC 9639 (December 2024)](https://www.rfc-editor.org/rfc/rfc9639.html).

## 録音とライブ表示のデータフロー

```text
マイク / システム音声
  → TimestampedMonoSink（全入力 channel の平均）
  → AudioBlockRing
  → AudioCaptureDrain（連続 SRC → 16 kHz mono float32）
  → DurableAudioWriter → 保存済み PCM chunk / checkpoint（確定後は 16-bit FLAC へ変換）
                                              ↓
                                      LiveVADSession
                                              ↓ 閉じた VAD 区間
                                       LiveASRSession
                                              ↓ segment.created / asr.completed 等
                                       events.jsonl
                                              ↓ TranscriptMaterializer
                                        暫定のライブ表示（初期値は ASR 原文）
```

入力 callback と保存側はリングで分離します。保存処理はライブ ASR の完了を待ちません。タイムスタンプ上の欠落は gap として記録し、無音で埋めるため、保存音声と後段の時刻座標が一致します。

ライブ VAD は閉じた発話区間を渡し、連続発話は最大 14 秒で分割します。分割の端数 continuation も保持します。長い発話は区間が閉じるまで初表示が遅れます。ライブ中は話者分離を行わず、結果は暫定です。

`LiveASRSession` はセッション内で materialized 行の配列を保持します。`segment.created` の保存と ID による重複登録排除だけでは認識済み行を再構築しません。待ち件数は durable 登録済み ID 数から ASR 完了・失敗が durable になった ID 数を引き、集合差を作らずに求めます。`process` は同じ登録処理を使いますが、登録だけの中間 progress は作りません。行は `asr.completed` / `asr.failed` の保存後、または durable な発話文イベント適用時に `TranscriptMaterializer` で更新します。ASR 完了後は判定応答を待たず原文を表示し、境界 assessment が未保存・保留・失敗なら原文のままです。ライブの境界判定 run と優先度 run はライブセッションの開始時に決まり、そのセッションの active run として扱います。snapshot と completion もこの配列を使い、保存に失敗したイベントは行・件数に反映しません。オフラインの materialization とアプリのライブキュー所有はこのキャッシュとは独立です。

ライブ ASR の結果は保存直後に原文で表示し、区間の順序と結果（空・失敗を含む）を `LiveContentPrioritySession` の独立キューへ渡します。キューは次区間の保存またはテキスト列の終端を待って区間ごとに境界を判定し、成功した assessment の保存後に限り F 範囲を表示へ反映します。`ClauseBoundaryAssembly` で閉じた BTSJ 発話文を保存してから最大40発話文の batch で優先度を判定し、再試行待ちでない保存済み LOW slice を表示から除きます。境界・優先度の待機や失敗は ASR drain・原文表示へ伝播しません。録音停止ではテキスト列の終端をキューに伝え、確定処理は開始時点で保存済みのライブ判定を固定してからキューを取り消します。確定・再試行の優先度再利用では、比較する各 run 自身の保存済み F 範囲をその run の発話文 parts に適用して区切りなしで連結し、UTF-8 byte 列が完全一致する場合だけ再利用します。ライブの F 範囲を確定側・再試行側の原文へ移しません。[ライブ](live.md)・[発話文判定](decision-engine.md)

[`LiveTranscriptionState`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveTranscriptionState.swift) は Pipeline の状態保持型で、session ごとの FIFO batch、最新音声 checkpoint、failure、content-priority status、VAD の segment count / failure だけを保持し、ASR task や VAD session / polling task は所有しません。[`LiveTranscriptionCoordinator`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveTranscriptionCoordinator.swift) は `@MainActor` で ASR task と task ID、VAD session と polling task を所有し、ASR drain、thermal wait、VAD polling を実行します。[`SessionProcessingCoordinator`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingCoordinator.swift) は `@MainActor` で、処理の dequeue・hold / resume・begin・run・pause、完了と idle drain の開始、および recovery request の filter を調整します。再処理 claim は AppState が enqueue 前に `SessionProcessingQueue` で行い、coordinator が処理後に release します。`SessionProcessingExecuting` / `LiveTranscriptionExecuting` は処理 engine の境界、`SessionProcessingEffects` / `LiveTranscriptionEffects` は App 側の効果境界で、テストは executor を fake にできます。本番の live sleep として、[`AppState`](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift) が Task.sleep を coordinator へ明示的に渡します。AppState は両 effects protocol を実装し、`RecordingLifecycle` / `SessionProcessingQueue` / `SavedSessionOperations` を `@Published` 値として公開します。キューと再処理 claim の状態は保存済み録音一覧へ即時反映されます。status・transcript の更新、export、capture checkpoint / mic speech window の提供も担います。NSOpenPanel / NSWorkspace は App に置きます。ライブ文字起こしの view と view model は App target の [`LiveTranscriptView`](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift) と [`LiveTranscriptViewModel`](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptViewModel.swift) にあります。

根拠: [TimestampedMonoSink.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/TimestampedMonoSink.swift)（`RawInputMeter` と `CaptureFrameTimestampMapper` を含む）、[CaptureSafety.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/CaptureSafety.swift)、[SystemAudioOutputMonitor.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SystemAudioOutputMonitor.swift)、[MicInputVolumeController.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/MicInputVolumeController.swift)、[AudioBlockRing.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioBlockRing.swift)、[AudioCaptureDrain.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioCaptureDrain.swift)、[DurableAudioWriter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DurableAudioWriter.swift)、[Segmentation.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift)、[LiveASRSession.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveASRSession.swift)、[LiveContentPrioritySession.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveContentPrioritySession.swift)、[LiveVADSession.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveVADSession.swift)、[VADTimelineProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/VADTimelineProcessor.swift)、[FluidVADSegmentationEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADSegmentationEngine.swift)、[MacLiveVADSessionFactory.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/MacLiveVADSessionFactory.swift)。

## ファイル入力と共通確定処理

ファイル入力では `AudioImporter` が元ファイルをセッション内に無再圧縮コピーします。`AudioFileTimelineBuilder` は bounded buffer で original を読み、全 channel の平均後に連続 SRC して 16 kHz mono float32 の処理タイムラインを保存します。original の bytes は保持します。録音・import の VAD、ASR、話者分離は canonical 入力を直接消費し、処理段階で SRC や downmix は行いません。

録音停止、ライブ失敗後の保存音声、import、利用者による再処理、クラッシュ復旧、CLI resume は、`NativeSessionProcessor` の共通確定処理を使います。

```text
保存音声
  → 新しい VAD run
  → offline diarization（保存タイムラインから CAF を生成）
  → SpeakerTurnSegmenter（VAD 区間を話者 turn で分割）
  → ASR
  → 必須のローカル3段階の保存済み結果を検証・公開
  → Core ML tagger による境界判定（任意）
  → BTSJ 発話文の組み立て
  → Core ML tagger による優先度判定（任意）
  → 判定 run・保留一覧を一括公開
```

確定処理の必須ローカル段階は segmentation・diarization・ASR です。これらの成功後、同梱の Core ML tagger で境界と優先度を判定します。判定段階は任意で、モデルの初期化・判定の失敗では、必須3段階の結果を保ち、未成立の判定を保留します。

区間は保存タイムラインの frame index による半開区間です。話者間 gap は中点で分割します。FluidAudio adapter だけは実音声内から最終モデル window の padding 内へ延びる終端を EOF に合わせます（[終端の規則](final.md)）。EOF 以降の開始、padding を超える終端は adapter で明示エラーにし、確定パイプラインでも全 span の実音声範囲を厳密に検証します。

確定処理開始時に `finalization_attempt` を running として保存し、処理中のイベントは既存ログへ追記します。必須ローカル段階が成功するまでは公開済み `active_runs` を変更しません。ローカル段階の公開と判定結果の公開は、それぞれ一回の metadata write で行います。判定 snapshot の保存に失敗しても公開済みのローカル結果を保持します。失敗・熱による一時停止では直前の正常な結果を維持し、再開は新しい確定 run の全量実行です。原音声は後段の失敗で削除しません。

根拠: [AudioImporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioImporter.swift)、[AudioFileTimelineBuilder.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[SpeakerTurnSegmenter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerTurnSegmenter.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)、[FinalTranscriptVADSegmenter protocol](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift)、[FluidFinalTranscriptVADSegmenter.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidFinalTranscriptVADSegmenter.swift)、[SessionProcessingAudioHandling protocol](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift)、[MacSessionProcessingAudio.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/MacSessionProcessingAudio.swift)、[RecordingLifecycle.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/RecordingLifecycle.swift)、[SessionProcessingQueue.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingQueue.swift)、[SavedSessionOperations.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SavedSessionOperations.swift)、[ThermalMonitoring.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/ThermalMonitoring.swift)、[MacThermalMonitor.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/MacThermalMonitor.swift)、[ProcessingMetadata.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)。

## 発話文判定

境界と優先度の単位は BTSJ 発話文です。接続表現で節が完結しても続く場合や倒置・後置・付け足しが続く場合は同じ発話文として扱い、フィラーや言い直しだけでは境界にしません。モデルの `span_probs` を O=0 / F=1 / D=2 の argmax で分類し、除去するのは F だけです。O と D は保持します。形態素解析、辞書、規則による別分割・判定は行いません。ASR・話者分離・発話文判定はすべてローカル処理で、判定テキストをネットワークへ送りません。フィラー除去後に本文がある認識済み行は表示・書き出しの対象です。

判定モデル（package と tokenizer JSON）は `scripts/build_app.sh` が固定した GitHub release asset を SHA-256 検証して app bundle の Resources 内 `clause-tagger` ディレクトリに入れ、アプリはその固定位置から読み込みます。実行時のダウンロードやパス override はありません。欠損・不正モデルは明確な初期化エラーとなり、判定を保留します。Core ML は CPU only・float32 で推論し、tokenizer は swift-transformers Tokenizers 1.3.4 を使います。具体的なファイル名、形状・入出力、tokenizer 検証、符号化と履歴要件は [発話文判定](decision-engine.md) を参照してください。

`ContentPriorityAccess` はアプリと CLI が使う共有 access enum です。アプリは `.localTagger(factory, usageCounter:)` 経由で coordinator を取得します。factory は `DecisionProviderFactory.makeCoordinator()` で、tagger を一度だけロードして cache します。ファイル処理・システム音声キャプチャ・ライブ遅延計測 CLI は `.disabled` を渡して任意の判定段階を省略し、tagger をロードしません。

Core の `DecisionProvider` が判定の境界で、Core ML tagger とテスト用 provider が同じ要求・応答型を使います。`DecisionCoordinator` と共有 `DecisionUsageCounter` は provider 呼出し一回ごとに1 request として計数し、モデルが読んだ入力 token を記録します。境界の一 request は候補と全 source token を網羅する source-only 窓、および後続区間があれば任意の継続入力を含みます。窓の数によらず一 request と数え、全窓と継続入力の token 数を合計します。優先度判定は最大40 sequence の一 batch 呼出しを一 request とし、実入力 ID 数を合計します。

境界要求は raw ASR text を入力にします。本文のある終端区間は候補がなくても F 範囲を判定する source-only 推論を実行し、成功時は実際の request と `clause_boundaries.assessed.filler_ranges` を保存します。優先度要求は F 除去後本文の最大40件です。設定の「モデルを確認」は cache した tagger の identity を表示するだけで、判定 request・利用回数・token を発生させません。

ASR 原文とイベントは変更しません。保存済み境界 assessment の F 範囲だけを原文の raw UTF-16 座標へ適用し、materialization は保存済み範囲と再試行待ちでない保存済み LOW slice を表示本文へ投影するだけで、辞書もモデルも使いません。画面、コピー、accessibility、文字起こし txt、CLI JSON の `display_text` は共通の表示本文を使います。判定無効の CLI は assessment や F 範囲を作らず、`display_text` に原文を出します。

開始 run の provenance は engine、model、version と設定を保存します。run には実際にロードした model ID と state hash revision を記録し、成功した各 request record には request ID と入力 token 数を保存します。request を処理したモデルはその run の provenance が示します。共通の `DecisionProvider`、型、portable encoding と F 範囲 projection は [ClauseTypes.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTypes.swift)、[ClauseTaggerEncoding.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerEncoding.swift)、[ClauseTaggerSpanProjection.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerSpanProjection.swift)、materialization は [Materialization.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift) と [TranscriptTextProjection.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptTextProjection.swift)、factory と tagger は [DecisionProviderFactory.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/DecisionProviderFactory.swift) と [LocalClauseTagger.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)、provenance と計数は [DecisionEnrichmentCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionEnrichmentCoordinator.swift) と [DecisionUsageCounter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionUsageCounter.swift) を参照してください。

## 待機中のモデル解放

App は録音・ライブ認識・確定処理の待ち行列・発熱による保留・実行中の確定処理がすべてなくなった時点で `NativeSessionProcessor.releaseIdleResources()` を呼び、Qwen3-ASR と話者分離のモデルを解放し、MLX のバッファキャッシュを空にします。この解放は Core ML 発話文 tagger を対象にしません。正常にロードした tagger は provider factory の寿命中 cache され、idle release 後も保持されます。ASR model 状態は「録音開始時に準備します」に戻ります。解放中に始まったモデル準備・ライブ認識・確定処理は解放の完了を待ちます。次の録音や確定処理では ASR と話者分離を読み込み直すため、録音開始直後のライブ表示は読み込みの数秒だけ遅れます。CLI はプロセス終了で解放されるため、この解放を呼びません。

根拠: [AppState+Processing.swift](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+Processing.swift)、[NativeQwen3ASREngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeQwen3ASREngine.swift)、[FluidOfflineDiarizationEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidOfflineDiarizationEngine.swift)。

根拠: [DecisionEnrichmentCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionEnrichmentCoordinator.swift)、[AppState.swift](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift)、[ファイル処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)、[システム音声 CLI](../app/MacAmbientJev/Sources/MacAmbientJevCaptureSystemAudio/main.swift)、[遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)。
