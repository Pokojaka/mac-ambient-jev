# アーキテクチャ

Mac Ambient Jev は、保存音声を基にローカルで文字起こしを作る Swift アプリです。音声保存と推論を分離し、認識・話者分離・節の境界・優先度の結果をイベントとして保持します。画面や書き出しは、公開済み run のイベントから組み立てます。保存形式の詳細は [storage.md](storage.md) を参照してください。

## パッケージとモジュール

定義の正本は [Package.swift](../app/MacAmbientJev/Package.swift) です。Swift tools version は 6.0、macOS の最低バージョンは 15 です。

### 共通ターゲット

macOS 以外でも定義されるターゲットには外部 Swift パッケージ依存がありません。

| ターゲット | 種類 | 責務・直接依存 |
| --- | --- | --- |
| `MacAmbientJevCore` | library | セッション・イベント・タイムラインの型、保存と復旧、推論の protocol、段階 coordinator、materialization、Jev 通信と優先度処理、CER・話者分離の評価。外部ターゲット依存なし |
| `MacAmbientJevEvaluateSession` | executable | 参照文付きセッションの ASR 評価。Core に依存 |
| `MacAmbientJevEvaluateASR` | executable | ASR artifact の CER 評価。Core に依存 |
| `MacAmbientJevEvaluateDiarization` | executable | 話者分離 artifact の評価。Core に依存 |
| `MacAmbientJevCoreTests` | test | Core に依存 |

### macOS 限定ターゲット

| ターゲット | 種類 | 責務・直接依存 |
| --- | --- | --- |
| `MacAmbientJevAppleSupport` | library | Keychain、AVFoundation による bounded ファイルデコードと stateful canonical SRC、保存済み文字起こし読取と書き出し。Core に依存 |
| `MacAmbientJevCapture` | library | マイク・システム音声入力、Core Audio tap、権限、入力音量制御、タイムスタンプ付き mono 入力と録音寿命管理。Core と AppleSupport に依存 |
| `MacAmbientJevRuntime` | library | FluidAudio VAD・offline diarization、Qwen3-ASR、ライブ認識、共通確定処理。Core、AppleSupport、FluidAudio、Qwen3ASR、MLX に依存 |
| `MacAmbientJev` | executable | SwiftUI 画面、`AppState`、録音・処理キュー・設定・保存済みセッション操作。Core、AppleSupport、Capture、Runtime に依存 |
| `MacAmbientJevCaptureSystemAudio` | executable | システム音声のキャプチャと確定処理。Core、Capture、Runtime、MLX に依存 |
| `MacAmbientJevProcessRecording` | executable | ファイル処理、セッションの inspect と resume、外部 ASR 用の plan 書き出しとテキスト取り込み、JSON と計測の出力。Core、AppleSupport、Runtime、MLX に依存 |
| `MacAmbientJevMeasureLiveLatency` | executable | 音声ファイルの再生速度に合わせたライブ処理の遅延計測。Core、AppleSupport、Runtime に依存 |

macOS 限定の test target は `MacAmbientJevProcessRecordingTests`、`MacAmbientJevMeasureLiveLatencyTests`、`MacAmbientJevAppTests`、`MacAmbientJevCaptureTests`、`MacAmbientJevCaptureSystemAudioTests`、`MacAmbientJevAppleSupportTests`、`MacAmbientJevRuntimeTests` です。

macOS の外部依存は FluidAudio 0.15.8、speech-swift の revision `c4c2fabbe825a9290c19e2f45d54ca3eae96b003`、mlx-swift 0.31.6 です。Runtime が speech-swift の Qwen3ASR product を使い、音声認識の外部モデル ID は aufklarer/Qwen3-ASR-1.7B-MLX-8bit です（リポジトリパスではありません）。

## Portable Core の境界

Core は Apple 専用 framework の adapter を持ちません。[scripts/check_portable_core.py](../scripts/check_portable_core.py) は Core 内の Swift ファイルを走査し、AVFoundation、AppKit、CoreAudio、CoreML、Security、SwiftUI の import を禁止しています。Foundation、Synchronization による保存・同期や、FoundationNetworking を使う Jev 通信は Core に置かれます。**portable は「純粋関数だけ」「ネットワークを一切使わない」という意味ではありません。**

実推論は Core の `ASREngine` と `DiarizationEngine` に対する Runtime の実装です。確定 VAD の `FinalTranscriptVADSegmenter` は Runtime の protocol です。確定処理は ASR の前に `ASREngine.begin(plan:audio:)` へ ASR リクエストの一覧（`ASRPlan`）を渡します。通常のエンジンは何もせず、`ASRPlanExportEngine` は入力クリップを書き出して処理を止め、`ASRPlanReplayEngine` は外部で得たテキストを返します。Core の drain は Foundation-only の `CanonicalAudioConverting` を受け取り、stateful AVAudioConverter adapter は AppleSupport に置きます。入力装置や権限は Capture、SwiftUI の状態は App に分離します。Linux のモデル runner は [tools/linux-audio](../tools/linux-audio) にあり、Swift アプリの Runtime 依存には入りません。

根拠: [CanonicalAudio.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/CanonicalAudio.swift)、[ASR.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASR.swift)、[Diarization.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Diarization.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[ASRPlan.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASRPlan.swift)、[ASRPlanExportEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/ASRPlanExportEngine.swift)、[ASRPlanReplayEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/ASRPlanReplayEngine.swift)、[CanonicalAudioResampler.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/CanonicalAudioResampler.swift)、[JevClient.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevClient.swift)。

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
                                        暫定のライブ表示
```

入力 callback と保存側はリングで分離します。保存処理はライブ ASR の完了を待ちません。タイムスタンプ上の欠落は gap として記録し、無音で埋めるため、保存音声と後段の時刻座標が一致します。

ライブ VAD は閉じた発話区間を渡し、連続発話は最大 14 秒で分割します。分割の端数 continuation も保持します。長い発話は区間が閉じるまで初表示が遅れます。ライブ中は話者分離を行わず、結果は暫定です。

`LiveASRSession` はセッション内で materialized 行の配列を保持します。`segment.created` の保存と ID による重複登録排除だけでは認識済み行を再構築しません。待ち件数は durable 登録済み ID 数から ASR 完了・失敗が durable になった ID 数を引き、集合差を作らずに求めます。`process` は同じ登録処理を使いますが、登録だけの中間 progress は作りません。行は `asr.completed` / `asr.failed` の保存後、または durable な Jev 節イベントの適用時に `TranscriptMaterializer` で更新します。ライブの境界判定 run と優先度 run はライブセッションの開始時に決まり、そのセッションの active run として扱います。snapshot と completion もこの配列を使い、保存に失敗したイベントは行・件数に反映しません。オフラインの materialization とアプリのライブキュー所有はこのキャッシュとは独立です。

ライブ ASR の結果は保存直後に通常色で表示し、区間の順序と結果（空・失敗を含む）を `LiveContentPrioritySession` の独立キューへ渡します。キューは次区間の保存を待って一区間一回の境界判定を送り、`ClauseBoundaryAssembly` で閉じた節を保存してから 40 節までの batch で優先度を判定します。保存した節イベントだけを進行中の ASR イベントへ追加します。Jev の待機・失敗は ASR drain に伝播しません。録音停止ではテキスト列の終端をキューに伝え、確定処理は開始時点で保存済みのライブ判定を固定してからキューを取り消し、節本文の完全一致で再利用します。[ライブ](live.md)・[Jev](jev.md)

根拠: [TimestampedMonoSink.swift](../app/MacAmbientJev/Sources/MacAmbientJevCapture/TimestampedMonoSink.swift)、[AudioBlockRing.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioBlockRing.swift)、[AudioCaptureDrain.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioCaptureDrain.swift)、[DurableAudioWriter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DurableAudioWriter.swift)、[Segmentation.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift)、[LiveASRSession.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveASRSession.swift)。

## ファイル入力と共通確定処理

ファイル入力では `AudioImporter` が元ファイルをセッション内に無再圧縮コピーします。`AudioFileTimelineBuilder` は bounded buffer で original を読み、全 channel の平均後に連続 SRC して 16 kHz mono float32 の処理タイムラインを保存します。original の bytes は保持します。録音・import の VAD、ASR、話者分離は canonical 入力を直接消費し、処理段階で SRC や downmix は行いません。

録音停止、ライブ失敗後の保存音声、import、利用者による再処理、クラッシュ復旧、CLI resume は、`NativeSessionProcessor` の共通確定処理を使います。

```text
保存音声
  → 新しい VAD run
  → offline diarization（保存タイムラインから CAF を生成）
  → SpeakerTurnSegmenter（VAD 区間を話者 turn で分割）
  → ASR
  → ローカル3段階の保存済み結果を検証
  → active_runs と全区間の境界保留を一括公開
  → App で許可された場合だけ Jev 境界判定 → 節の組み立て → Jev 優先度判定
  → 境界判定 run・優先度 run・両保留を一括公開
```

区間は保存タイムラインの frame index による半開区間です。話者間 gap は中点で分割します。FluidAudio adapter だけは実音声内から最終モデル window の padding 内へ延びる終端を EOF に合わせます（[終端の規則](final.md)）。EOF 以降の開始、padding を超える終端は adapter で明示エラーにし、確定パイプラインでも全 span の実音声範囲を厳密に検証します。

確定処理開始時に `finalization_attempt` を running として保存し、処理中のイベントは既存ログへ追記します。全ローカル段階が成功するまでは公開済み `active_runs` を変更しません。ローカルの公開と Jev の公開はそれぞれ一回の metadata write で、Jev の snapshot の保存に失敗しても公開済みのローカル結果を保持します。失敗・熱による一時停止では直前の正常な結果を維持し、再開は新しい確定 run の全量実行です。原音声は後段の失敗で削除しません。

根拠: [AudioImporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioImporter.swift)、[AudioFileTimelineBuilder.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[SpeakerTurnSegmenter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerTurnSegmenter.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[ProcessingMetadata.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)。

## ローカル処理と外部通信

Jev は認識済みテキストの節の境界判定と優先度判定にだけ使い、音声・話者 embedding は送りません。Jev が利用できなくてもローカルの確定結果を公開し、未判定の発話は分割しない通常行として保留します。フィラー除去後に本文がある認識済み行はすべて表示・書き出しの対象です。

App は `ContentPriorityAccess.jev` を渡します。ファイル処理・システム音声キャプチャ・ライブ遅延計測の CLI は `.disabled` を渡し、Jev を呼びません。初回のローカルモデル取得には通信が必要ですが、ASR と話者分離の推論はローカルです。

外部判定の注入境界は Core の `DecisionProvider` です。`NativeSessionProcessor` の factory と AppState が用意する `JevDecisionCoordinator` は、`JevClient` または注入 provider を受け取り、HTTP リクエストごとに一回計数します。`ContentPriorityAccess.jev` は factory と共有の `JevUsageCounter` を持ち、provider がなくても保留の計数を更新します。Settings の接続確認は一対象の Choice で、固定テスト文だけを送り usage を計数しません。

輸送は型付きNoulと複数Choiceを扱います。Noul は一区間の候補印付き raw text と必要な次原文先頭だけを送り、全候補・継続の確率を一 HTTP で返します。候補列挙・マーカー衝突回避・閾値比較・節の組み立てはコード、意味判定は Jev の責務です。Choice は最大40個の request-local key とフィラー除去後の節本文を state object に置き、各質問がその key を直接指定します。全回答と model／usage の検証が成功してから結果を保存し、metadata をリクエスト単位で一回だけ保存します。確定と再試行の snapshot は `JevEnrichmentCoordinator`、ライブは `LiveContentPrioritySession` が作り、どちらも `ClauseBoundaryAssembly` と同じ保存 payload（[ClauseRecords.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseRecords.swift)）を使います。保存結果は `EventLogTranscriptReader` の共通 decoder が組み立て直して検証します。

共有source・候補・確率・metadata型は [ClauseTypes.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTypes.swift)、HTTPと質問type別decodeは [JevClient.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevClient.swift)、request purpose 別計数と区間・節の保留管理は [JevUsageCounter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevUsageCounter.swift) にあります。計数と保存イベントへの反映を分離し、保存障害を通信failureへ変換しません。

## 待機中のモデル解放

App は録音・ライブ認識・確定処理の待ち行列・発熱による保留・実行中の確定処理がすべてなくなった時点で `NativeSessionProcessor.releaseIdleResources()` を呼び、Qwen3-ASR と話者分離のモデルを解放し、MLX のバッファキャッシュを空にします。モデル状態は「録音開始時に準備します」に戻ります。解放中に始まったモデル準備・ライブ認識・確定処理は解放の完了を待ちます。次の録音や確定処理ではモデルを読み込み直すため、録音開始直後のライブ表示は読み込みの数秒だけ遅れます。CLI はプロセス終了で解放されるため、この解放を呼びません。

根拠: [AppState+Processing.swift](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+Processing.swift)、[NativeQwen3ASREngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeQwen3ASREngine.swift)、[FluidOfflineDiarizationEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidOfflineDiarizationEngine.swift)。

根拠: [JevEnrichmentCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevEnrichmentCoordinator.swift)、[AppState.swift](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift)、[ファイル処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)、[システム音声 CLI](../app/MacAmbientJev/Sources/MacAmbientJevCaptureSystemAudio/main.swift)、[遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)。
