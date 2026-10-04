# アーキテクチャ

Mac Ambient Jev は、保存音声を基にローカルで文字起こしを作る Swift アプリです。音声保存と推論を分離し、認識・話者分離・場面・音響範囲・優先度の結果をイベントとして保持します。画面や書き出しは、公開済み run のイベントから組み立てます。保存形式の詳細は [storage.md](storage.md) を参照してください。

## パッケージとモジュール

定義の正本は [Package.swift](../app/MacAmbientJev/Package.swift) です。Swift tools version は 6.0、macOS の最低バージョンは 15 です。

### 共通ターゲット

macOS 以外でも定義されるターゲットには外部 Swift パッケージ依存がありません。

| ターゲット | 種類 | 責務・直接依存 |
| --- | --- | --- |
| `MacAmbientJevCore` | library | セッション・イベント・タイムラインの型、保存と復旧、推論の protocol、段階 coordinator、materialization、場面と音響範囲の判定、Jev 通信と優先度処理、CER・話者分離の評価。外部ターゲット依存なし |
| `MacAmbientJevEvaluateSession` | executable | 参照文付きセッションの ASR 評価と場面振動数。Core に依存 |
| `MacAmbientJevEvaluateASR` | executable | ASR artifact の CER 評価。Core に依存 |
| `MacAmbientJevEvaluateDiarization` | executable | 話者分離 artifact の評価。Core に依存 |
| `MacAmbientJevCoreTests` | test | Core に依存 |

### macOS 限定ターゲット

| ターゲット | 種類 | 責務・直接依存 |
| --- | --- | --- |
| `MacAmbientJevAppleSupport` | library | Keychain、AVFoundation によるファイルデコード・音声変換、保存済み文字起こし読取と書き出し。Core に依存 |
| `MacAmbientJevCapture` | library | マイク・システム音声入力、Core Audio tap、権限、入力音量制御、タイムスタンプ付き mono 入力と録音寿命管理。Core と AppleSupport に依存 |
| `MacAmbientJevPlatformAudio` | target | `VADResampler` による AVFoundation と FluidAudio の入力変換。FluidAudio に依存。独立した library product はない |
| `MacAmbientJevRuntime` | library | FluidAudio VAD・offline diarization、Qwen3-ASR、ライブ認識、共通確定処理、近接度の音響 evidence。Core、AppleSupport、PlatformAudio、FluidAudio、Qwen3ASR に依存 |
| `MacAmbientJev` | executable | SwiftUI 画面、`AppState`、録音・処理キュー・設定・保存済みセッション操作。Core、AppleSupport、Capture、Runtime に依存 |
| `MacAmbientJevCaptureSystemAudio` | executable | システム音声のキャプチャと確定処理。Core、Capture、Runtime、MLX に依存 |
| `MacAmbientJevProcessRecording` | executable | ファイル処理、セッションの inspect と resume、JSON と計測の出力。Core、AppleSupport、Runtime、MLX に依存 |
| `MacAmbientJevMeasureLiveLatency` | executable | 音声ファイルの再生速度に合わせたライブ処理の遅延計測。Core と Runtime に依存 |

macOS 限定の test target は `MacAmbientJevProcessRecordingTests`、`MacAmbientJevMeasureLiveLatencyTests`、`MacAmbientJevAppTests`、`MacAmbientJevCaptureTests`、`MacAmbientJevCaptureSystemAudioTests`、`MacAmbientJevAppleSupportTests`、`MacAmbientJevRuntimeTests` です。

macOS の外部依存は FluidAudio 0.15.8、speech-swift の revision `c4c2fabbe825a9290c19e2f45d54ca3eae96b003`、mlx-swift 0.31.6 です。Runtime が speech-swift の Qwen3ASR product を使い、音声認識の外部モデル ID は aufklarer/Qwen3-ASR-1.7B-MLX-8bit です（リポジトリパスではありません）。

## Portable Core の境界

Core は Apple 専用 framework の adapter を持ちません。[scripts/check_portable_core.py](../scripts/check_portable_core.py) は Core 内の Swift ファイルを走査し、AVFoundation、AppKit、CoreAudio、CoreML、Security、SwiftUI の import を禁止しています。Foundation、Synchronization による保存・同期や、FoundationNetworking を使う Jev 通信は Core に置かれます。**portable は「純粋関数だけ」「ネットワークを一切使わない」という意味ではありません。**

実推論は Core の `ASREngine` と `DiarizationEngine` に対する Runtime の実装です。確定 VAD の `FinalTranscriptVADSegmenter` は Runtime の protocol です。Apple の音声変換は AppleSupport / PlatformAudio、入力装置や権限は Capture、SwiftUI の状態は App に分離します。Linux のモデル runner は [tools/linux-audio](../tools/linux-audio) にあり、Swift アプリの Runtime 依存には入りません。

根拠: [ASR.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASR.swift)、[Diarization.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Diarization.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[VADResampler.swift](../app/MacAmbientJev/Sources/MacAmbientJevPlatformAudio/VADResampler.swift)、[JevClient.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevClient.swift)。

## 録音とライブ表示のデータフロー

```text
マイク / システム音声
  → TimestampedMonoSink（全入力 channel の平均）
  → AudioBlockRing
  → AudioCaptureDrain → DurableAudioWriter → 保存済み PCM chunk / checkpoint
                                              ↓
                                      LiveVADSession
                                              ↓ 閉じた VAD 区間
                                       LiveASRSession
                                              ↓ segment.created / asr.completed 等
                                       events.jsonl
                                              ↓ TranscriptMaterializer
                                        暫定のライブ表示
```

入力 callback と保存側はリングで分離します。保存処理はライブ ASR の完了を待ちません。タイムスタンプ上の欠落は gap として記録し、無音で埋めるため、保存音声と後段の時刻座標が一致します。

ライブ VAD は閉じた発話区間を渡し、連続発話は最大 14 秒で分割します。分割の端数 continuation も保持します。長い発話は区間が閉じるまで初表示が遅れます。ライブ中は話者分離を行わず、結果は暫定です。

非空のライブ ASR 本文は `LiveContentPrioritySession` の独立キューへ渡し、判定が届くまで（Jev 無効・失敗・保留・停止を除く）その行と時間順で後続の行を表示しません。`JevEnrichmentCoordinator` のバッチ停止規則を使い、保存した優先度イベントを進行中の ASR イベントへ追加します。Jev の待機・失敗は ASR drain に伝播しません。録音停止時に外部分類を取り消し、確定処理は開始時点で保存済みのライブ判定だけを本文の完全一致で再利用します。[ライブ](live.md)・[Jev](jev.md)

根拠: [TimestampedMonoSink.swift](../app/MacAmbientJev/Sources/MacAmbientJevCapture/TimestampedMonoSink.swift)、[AudioBlockRing.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioBlockRing.swift)、[AudioCaptureDrain.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioCaptureDrain.swift)、[DurableAudioWriter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DurableAudioWriter.swift)、[Segmentation.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift)、[LiveASRSession.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveASRSession.swift)。

## ファイル入力と共通確定処理

ファイル入力では `AudioImporter` が元ファイルをセッション内に無再圧縮コピーします。`AudioFileTimelineBuilder` はデコードした元の sample rate / channel 数の float PCM を処理タイムラインに保存します。録音の保存音声は mono ですが、import の元ファイルと処理タイムラインは入力の channel 数を保持します。ASR 入力を読む際に必要なら全 channel を平均して mono にします。

録音停止、ライブ失敗後の保存音声、import、利用者による再処理、クラッシュ復旧、CLI resume は、`NativeSessionProcessor` の共通確定処理を使います。

```text
保存音声
  → 新しい VAD run
  → offline diarization（保存タイムラインから CAF を生成）
  → SpeakerTurnSegmenter（VAD 区間を話者 turn で分割）
  → ASR
  → 音響による場面判定
  → 音響範囲判定
  → ローカル全段階の成功を検証
  → active_runs を一括公開
  → App で許可された場合だけ Jev 優先度分類
```

区間は保存タイムラインの frame index による半開区間です。話者間 gap は中点で分割します。話者 span が負または保存音声範囲外なら明示エラーにします。

確定処理開始時に `finalization_attempt` を running として保存し、処理中のイベントは既存ログへ追記します。全ローカル段階が成功するまでは公開済み `active_runs` を変更しません。失敗・熱による一時停止では直前の正常な結果を維持し、再開は新しい確定 run の全量実行です。原音声は後段の失敗で削除しません。

根拠: [AudioImporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioImporter.swift)、[AudioFileTimelineBuilder.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[SpeakerTurnSegmenter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerTurnSegmenter.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[ProcessingMetadata.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)。

## ローカル処理と外部通信

場面判定は話者の音響的活動だけを使い、手がかりのない冒頭を lecture とします。近接度は音響範囲専用の evidence であり、場面判定には使いません。Jev は認識済みテキストの優先度分類にだけ使い、音声・話者 embedding は送りません。Jev が利用できなくてもローカルの確定結果を公開し、未分類の発話は保留して PRIMARY 相当で残します。

App は `ContentPriorityAccess.jev` を渡します。ファイル処理・システム音声キャプチャ・ライブ遅延計測の CLI は `.disabled` を渡し、Jev を呼びません。初回のローカルモデル取得には通信が必要ですが、ASR と話者分離の推論はローカルです。

## 待機中のモデル解放

App は録音・ライブ認識・確定処理の待ち行列・発熱による保留・実行中の確定処理がすべてなくなった時点で `NativeSessionProcessor.releaseIdleResources()` を呼び、Qwen3-ASR と話者分離のモデルを解放し、MLX のバッファキャッシュを空にします。モデル状態は「録音開始時に準備します」に戻ります。解放中に始まったモデル準備・ライブ認識・確定処理は解放の完了を待ちます。次の録音や確定処理ではモデルを読み込み直すため、録音開始直後のライブ表示は読み込みの数秒だけ遅れます。CLI はプロセス終了で解放されるため、この解放を呼びません。

根拠: [AppState+Processing.swift](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+Processing.swift)、[NativeQwen3ASREngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeQwen3ASREngine.swift)、[FluidOfflineDiarizationEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidOfflineDiarizationEngine.swift)。

根拠: [SceneCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SceneCoordinator.swift)、[ScopeCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ScopeCoordinator.swift)、[JevEnrichmentCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevEnrichmentCoordinator.swift)、[AppState.swift](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift)、[ファイル処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)、[システム音声 CLI](../app/MacAmbientJev/Sources/MacAmbientJevCaptureSystemAudio/main.swift)、[遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)。
