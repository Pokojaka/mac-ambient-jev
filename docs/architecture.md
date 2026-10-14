# アーキテクチャ

Mac Ambient Jev は、保存音声を基にローカルで文字起こしを作る Swift アプリです。音声保存と推論を分離し、認識・話者分離・BTSJ 発話文の境界・優先度の結果をイベントとして保持します。画面や書き出しは、公開済み run のイベントから組み立てます。保存形式の詳細は [storage.md](storage.md) を参照してください。

## パッケージとモジュール

定義の正本は [Package.swift](../app/MacAmbientJev/Package.swift) です。Swift tools version は 6.0、macOS の最低バージョンは 15 です。

### 共通ターゲット

macOS 以外でも定義されるターゲットには外部 Swift パッケージ依存がありません。

| ターゲット | 種類 | 責務・直接依存 |
| --- | --- | --- |
| `MacAmbientJevCore` | library | セッション・イベント・タイムラインの型、保存と復旧、`DecisionProvider` protocol と共有判定型、段階 coordinator、materialization、判定 batch と優先度処理、純粋な `ClauseTaggerEncoding`、CER・話者分離の評価。外部ターゲット依存なし |
| `MacAmbientJevEvaluateSession` | executable | 参照文付きセッションの ASR 評価。Core に依存 |
| `MacAmbientJevEvaluateASR` | executable | ASR artifact の CER 評価。Core に依存 |
| `MacAmbientJevEvaluateDiarization` | executable | 話者分離 artifact の評価。Core に依存 |
| `MacAmbientJevCoreTests` | test | Core に依存 |

### macOS 限定ターゲット

| ターゲット | 種類 | 責務・直接依存 |
| --- | --- | --- |
| `MacAmbientJevAppleSupport` | library | 判定 provider factory、Core ML 発話文 tagger と tokenizer、AVFoundation による bounded ファイルデコードと stateful canonical SRC、保存済み文字起こし読取と書き出し。Core と swift-transformers Tokenizers / Hub に依存 |
| `MacAmbientJevCapture` | library | マイク・システム音声入力、Core Audio tap、権限、入力音量制御、タイムスタンプ付き mono 入力と録音寿命管理。Core と AppleSupport に依存 |
| `MacAmbientJevRuntime` | library | FluidAudio VAD・offline diarization、Qwen3-ASR、ライブ認識、共通確定処理。Core、AppleSupport、FluidAudio、Qwen3ASR、MLX に依存 |
| `MacAmbientJev` | executable | SwiftUI 画面、`AppState`、録音・処理キュー・設定・保存済みセッション操作。Core、AppleSupport、Capture、Runtime に依存 |
| `MacAmbientJevCaptureSystemAudio` | executable | システム音声のキャプチャと確定処理。Core、Capture、Runtime、MLX に依存 |
| `MacAmbientJevProcessRecording` | executable | ファイル処理、セッションの inspect と resume、JSON と計測の出力。Core、AppleSupport、Runtime、MLX に依存 |
| `MacAmbientJevMeasureLiveLatency` | executable | 音声ファイルの再生速度に合わせたライブ処理の遅延計測。Core、AppleSupport、Runtime に依存 |

macOS 限定の test target は `MacAmbientJevProcessRecordingTests`、`MacAmbientJevMeasureLiveLatencyTests`、`MacAmbientJevAppTests`、`MacAmbientJevCaptureTests`、`MacAmbientJevCaptureSystemAudioTests`、`MacAmbientJevAppleSupportTests`、`MacAmbientJevRuntimeTests` です。

macOS の外部依存は FluidAudio 0.15.8、speech-swift の revision `c4c2fabbe825a9290c19e2f45d54ca3eae96b003`、mlx-swift 0.31.6、swift-transformers 1.3.4 です。Runtime が speech-swift の Qwen3ASR product を使い、音声認識の外部モデル ID は aufklarer/Qwen3-ASR-1.7B-MLX-8bit です（リポジトリパスではありません）。発話文 tokenizer は AppleSupport が swift-transformers Tokenizers 1.3.4 を直接使います。

## Portable Core の境界

Core は Apple 専用 framework の adapter を持ちません。[scripts/check_portable_core.py](../scripts/check_portable_core.py) は Core 内の Swift ファイルを走査し、AVFoundation、AppKit、CoreAudio、CoreML、Security、SwiftUI の import を禁止しています。Foundation、Synchronization による保存・同期は Core に置かれます。`DecisionProvider` は Core ML tagger が実装する判定 protocol で、Core 内の `ClauseTaggerEncoding` は tokenizer を受け取る純粋な符号化ロジックです。Core ML と tokenizer の実装・依存は AppleSupport に置き、Core は portable のまま維持します。**portable は「純粋関数だけ」という意味ではありません。**

実推論は Core の `ASREngine` と `DiarizationEngine` に対する Runtime の実装です。確定 VAD の `FinalTranscriptVADSegmenter` は Runtime の protocol です。Core の drain は Foundation-only の `CanonicalAudioConverting` を受け取り、stateful AVAudioConverter adapter は AppleSupport に置きます。入力装置や権限は Capture、SwiftUI の状態は App に分離します。Linux のモデル runner は [tools/linux-audio](../tools/linux-audio) にあり、Swift アプリの Runtime 依存には入りません。

根拠: [CanonicalAudio.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/CanonicalAudio.swift)、[ASR.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASR.swift)、[Diarization.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Diarization.swift)、[ClauseTypes.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTypes.swift)、[ClauseTaggerEncoding.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerEncoding.swift)、[LocalClauseTagger.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)、[ClauseTaggerTokenizer.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerTokenizer.swift)、[ClauseTaggerModel.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerModel.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[CanonicalAudioResampler.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/CanonicalAudioResampler.swift)。

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

`LiveASRSession` はセッション内で materialized 行の配列を保持します。`segment.created` の保存と ID による重複登録排除だけでは認識済み行を再構築しません。待ち件数は durable 登録済み ID 数から ASR 完了・失敗が durable になった ID 数を引き、集合差を作らずに求めます。`process` は同じ登録処理を使いますが、登録だけの中間 progress は作りません。行は `asr.completed` / `asr.failed` の保存後、または durable な発話文イベント適用時に `TranscriptMaterializer` で更新します。ライブの境界判定 run と優先度 run はライブセッションの開始時に決まり、そのセッションの active run として扱います。snapshot と completion もこの配列を使い、保存に失敗したイベントは行・件数に反映しません。オフラインの materialization とアプリのライブキュー所有はこのキャッシュとは独立です。

ライブ ASR の結果は保存直後に表示し、区間の順序と結果（空・失敗を含む）を `LiveContentPrioritySession` の独立キューへ渡します。キューは次区間の保存を待って一区間一回の境界判定を行い、`ClauseBoundaryAssembly` で閉じた BTSJ 発話文を保存してから最大40発話文の batch で優先度を判定します。保存した発話文イベントだけを進行中の ASR イベントへ追加します。判定の待機・失敗は ASR drain に伝播しません。録音停止ではテキスト列の終端をキューに伝え、確定処理は開始時点で保存済みのライブ判定を固定してからキューを取り消し、発話文本文の完全一致で優先度を再利用します。[ライブ](live.md)・[発話文判定](decision-engine.md)

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
  → 必須のローカル3段階の保存済み結果を検証・公開
  → Core ML tagger による境界判定（任意）
  → BTSJ 発話文の組み立て
  → Core ML tagger による優先度判定（任意）
  → 判定 run・保留一覧を一括公開
```

確定処理の必須ローカル段階は segmentation・diarization・ASR です。これらの成功後、同梱の Core ML tagger で境界と優先度を判定します。判定段階は任意で、モデルの初期化・判定の失敗では、必須3段階の結果を保ち、未成立の判定を保留します。

区間は保存タイムラインの frame index による半開区間です。話者間 gap は中点で分割します。FluidAudio adapter だけは実音声内から最終モデル window の padding 内へ延びる終端を EOF に合わせます（[終端の規則](final.md)）。EOF 以降の開始、padding を超える終端は adapter で明示エラーにし、確定パイプラインでも全 span の実音声範囲を厳密に検証します。

確定処理開始時に `finalization_attempt` を running として保存し、処理中のイベントは既存ログへ追記します。必須ローカル段階が成功するまでは公開済み `active_runs` を変更しません。ローカル段階の公開と判定結果の公開は、それぞれ一回の metadata write で行います。判定 snapshot の保存に失敗しても公開済みのローカル結果を保持します。失敗・熱による一時停止では直前の正常な結果を維持し、再開は新しい確定 run の全量実行です。原音声は後段の失敗で削除しません。

根拠: [AudioImporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioImporter.swift)、[AudioFileTimelineBuilder.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[SpeakerTurnSegmenter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerTurnSegmenter.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[ProcessingMetadata.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)。

## 発話文判定

境界と優先度の単位は BTSJ 発話文です。接続表現で節が完結しても続く場合や倒置・後置・付け足しが続く場合は同じ発話文として扱い、フィラーや言い直しだけでは境界にしません。形態素解析、辞書、規則による別分割・判定は行いません。ASR・話者分離・発話文判定はすべてローカル処理で、判定テキストをネットワークへ送りません。フィラー除去後に本文がある認識済み行は表示・書き出しの対象です。

判定モデル（package と tokenizer JSON）は `scripts/build_app.sh` が固定した GitHub release asset を SHA-256 検証して app bundle の Resources 内 `clause-tagger` ディレクトリに入れ、アプリはその固定位置から読み込みます。実行時のダウンロードやパス override はありません。欠損・不正モデルは明確な初期化エラーとなり、判定を保留します。Core ML は CPU only・float32 で推論し、tokenizer は swift-transformers Tokenizers 1.3.4 を使います。具体的なファイル名、形状・入出力、tokenizer 検証、符号化と履歴要件は [発話文判定](decision-engine.md) を参照してください。

`ContentPriorityAccess` はアプリと CLI が使う共有 access enum です。アプリは `.localTagger(factory, usageCounter:)` 経由で coordinator を取得します。factory は `DecisionProviderFactory.makeCoordinator()` で、tagger を一度だけロードして cache します。ファイル処理・システム音声キャプチャ・ライブ遅延計測 CLI は `.disabled` を渡して任意の判定段階を省略し、tagger をロードしません。

Core の `DecisionProvider` が判定の境界で、Core ML tagger とテスト用 provider が同じ要求・応答型を使います。`DecisionCoordinator` と共有 `DecisionUsageCounter` は provider 呼出し一回ごとに1 request として計数し、モデルが読んだ入力 token を記録します。境界判定は候補・継続の二推論を含み得ますが一 request と数え、両 sequence の実入力 token 数を合計します。優先度判定は最大40 sequence の一 batch 呼出しを一 request とし、実入力 ID 数を合計します。

境界要求は raw ASR text と候補・必要な次区間先頭を含み、候補判定・継続判定を一 request にまとめます。優先度要求はフィラー除去後本文の最大40件です。設定の「モデルを確認」は cache した tagger の identity を表示するだけで、判定 request・利用回数・token を発生させません。

開始 run の provenance は engine、model、version と設定を保存します。run には実際にロードした model ID と state hash revision を記録し、成功した各 request record には request ID と入力 token 数を保存します。request を処理したモデルはその run の provenance が示します。共通の `DecisionProvider`、型、portable encoding は [ClauseTypes.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTypes.swift) と [ClauseTaggerEncoding.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerEncoding.swift)、factory と tagger は [DecisionProviderFactory.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/DecisionProviderFactory.swift) と [LocalClauseTagger.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)、provenance と計数は [DecisionEnrichmentCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionEnrichmentCoordinator.swift) と [DecisionUsageCounter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionUsageCounter.swift) を参照してください。

## 待機中のモデル解放

App は録音・ライブ認識・確定処理の待ち行列・発熱による保留・実行中の確定処理がすべてなくなった時点で `NativeSessionProcessor.releaseIdleResources()` を呼び、Qwen3-ASR と話者分離のモデルを解放し、MLX のバッファキャッシュを空にします。この解放は Core ML 発話文 tagger を対象にしません。正常にロードした tagger は provider factory の寿命中 cache され、idle release 後も保持されます。ASR model 状態は「録音開始時に準備します」に戻ります。解放中に始まったモデル準備・ライブ認識・確定処理は解放の完了を待ちます。次の録音や確定処理では ASR と話者分離を読み込み直すため、録音開始直後のライブ表示は読み込みの数秒だけ遅れます。CLI はプロセス終了で解放されるため、この解放を呼びません。

根拠: [AppState+Processing.swift](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+Processing.swift)、[NativeQwen3ASREngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeQwen3ASREngine.swift)、[FluidOfflineDiarizationEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidOfflineDiarizationEngine.swift)。

根拠: [DecisionEnrichmentCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionEnrichmentCoordinator.swift)、[AppState.swift](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift)、[ファイル処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)、[システム音声 CLI](../app/MacAmbientJev/Sources/MacAmbientJevCaptureSystemAudio/main.swift)、[遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)。
