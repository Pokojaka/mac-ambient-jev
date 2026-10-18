# 検証と計測

共通 Core / Pipeline と評価 CLI は Windows・Linux の常設 CI でビルドし、portable な Core / Pipeline tests を実行します。WindowsSupport の build / tests は Windows で実行します。Windows の手順と対象外のアプリ機能は [windows.md](windows.md) を参照してください。macOS app bundle の plist 生成を確認する Bash テストは Windows では実行しません。

自動検証、実モデルによるファイル処理、計測結果の意味を分けて扱う。マイク・システム音声の実キャプチャや画面の確認は、ファイル入力の結果だけでは検証できない。Linux の artifact・corpus・CI 実推論は [linux.md](linux.md)、処理経路は [final.md](final.md)、保存と公開結果は [storage.md](storage.md) を参照する。

以下のコマンドはリポジトリルートから実行する。実データのファイル名、セッション ID、保存先を示す環境変数には、自分の実在するデータを設定する。個人録音は Git に入れず、ローカル録音用の領域に置く。配置の案内は `test-data/recordings/README.md` にある。

## 共通 Core / Pipeline テストの現状

[MacAmbientJevPipelineTests](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/) は Windows・Linux で実行する portable な状態・調整ロジックのテストです。[RecordingLifecycleTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingLifecycleTests.swift) は録音・import の lifecycle、[SessionProcessingQueueTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingQueueTests.swift) は FIFO・重複再処理の抑止・thermal hold/resume を検証します。queue の保存整理 state と app 上の完了・失敗表示および整理中の export 制御は、macOS 専用の [LaunchMaintenanceStatusTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LaunchMaintenanceStatusTests.swift) と [ExportDuringMaintenanceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/ExportDuringMaintenanceTests.swift) が検証します。[SavedSessionOperationsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SavedSessionOperationsTests.swift) は保存済みセッションの選択と export 状態、[LiveTranscriptionStateTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveTranscriptionStateTests.swift) は FIFO batch・最新 checkpoint・failure・cleanup、[ThermalMonitoringTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/ThermalMonitoringTests.swift) は Windows の `WindowsNoThermalMonitoring` が熱状態を読み取らず、`isCritical == false` と `liveASRDecision == .processNow` を返すことを確認します。

[SessionProcessingCoordinatorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingCoordinatorTests.swift) は critical 時の hold / resume と FIFO、pause 時の claim 維持と completion 後の release、recovery filtering を検証します。[LiveTranscriptionCoordinatorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveTranscriptionCoordinatorTests.swift) は fake engines と注入 sleep を使い、thermal wait 中の FIFO、registration await failure と failure / cleanup 後の idle・backlog 状態、cleanup 時に進行中 batch を cancel せず完了させること、遅れて返る failure を公開しないこと、古い drain が置換後の同一 session state を上書きしないこと、VAD progress が ASR 区間登録より先に通知される順序を検証します。[ThermalLineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ThermalLineTests.swift) は Foundation の 4 state（`nominal`、`fair`、`serious`、`critical`）で完全な JSONL 行を直列化することを確認します。ここで挙げた Core / Pipeline tests は portable で、ThermalLineTests は Mac 専用 CLI test です。

```bash
swift test --package-path app/MacAmbientJev --filter MacAmbientJevPipelineTests
```

Windows の [`scripts/test-windows.ps1`](../scripts/test-windows.ps1) は同じ Pipeline test target を含みます。これらのテストは portable な調整・状態ロジックの検証であり、Windows の inference や capture の実装・検証を意味しません。

[CaptureSafetyTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/CaptureSafetyTests.swift) は startup/stall/silence、disk threshold と error rules、oversized mono buffer を検証します。[TimestampedMonoSinkTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/TimestampedMonoSinkTests.swift) は raw-meter の 100ms windows、channels 間の clipping、gaps/reset、metering 前後で audio が変わらないことを検証します。AudioCaptureEngine/CoreMedia/IOKit との実 integration は macOS 専用 AppTests（[AudioCaptureEngineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/AudioCaptureEngineTests.swift)、[CaptureSafetyTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/CaptureSafetyTests.swift)）で扱います。

## macOS の基本検証

```bash
python3 -B scripts/check_portable_core.py
python3 scripts/check_doc_references.py
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev
bash scripts/verify_v1.sh
```

`verify_v1.sh` は次を行う。

1. ドキュメント参照 checker の自己テストと参照検査を実行する。
   `scripts/test_session_artifacts.py` で計測・capture summary の artifact 検査を合成セッションで実行する（処理・capture は開始しない）。イベント・処理 metadata の schema version 3 と、未対応・欠損・型不正の version の拒否も検証する。Python の `regex` package が必要。
2. SwiftPM の依存を解決し、package を build する。
3. `RUN_MODEL_TESTS` を外して通常の Swift test を実行する。
4. `MacAmbientJevProcessRecording` を build し、`scripts/verify_cli_inputs.py` で不正入力、ローカル3段階の成功0件を公開した named folder の inspect、イベント・処理 metadata の未対応・欠損・型不正 version の拒否、resume 出力先の containment と保存ファイルの不変性を確認する。
5. `MacAmbientJevEvaluateSession` を build する。
6. モデル検証を指定した場合は Runtime test bundle を実行する。
7. `scripts/build_app.sh` で発話文判定モデルを取得・SHA-256 検証して同梱した app bundle を作り（MLX の Metal shader library は Swift Build backend だけが作るため、このスクリプトは `swift build` を Swift Build backend で実行する。アプリは Apple Silicon 専用のため arm64 だけを build する）、アプリアイコンの CFBundleIconFile 指定と `.icns` の読み込み、最小・最大解像度の収録、MLX Metal shader library、同梱した発話文判定モデルの2ファイル、署名の検証、利用者が選んだファイルへの read/write・app-scope bookmark entitlement を確認する。

アプリの build は行うが GUI を起動しない。通常の検証は実 ASR モデルを実行せず、認識精度やライブ録音の合格根拠にはならない。`.github/workflows/ci.yml` の macos-26 job も通常の `verify_v1.sh` を実行する。この job は MLX の Metal shader library を build するため Xcode の Metal toolchain を `xcodebuild -downloadComponent MetalToolchain` で入れ、実行ごとに「MacAmbientJev Local Signing」という自己署名のコード署名証明書を一時 keychain に作り、`scripts/build_app.sh` の署名に使う。発話文判定モデルの release asset は job の `GH_TOKEN`（`github.token`）で `gh` から取得する。

ライブ判定の regression は注入した判定 coordinator factory を使います。

[MicInputVolumeTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCaptureTests/MicInputVolumeTests.swift) は fake HAL のバックグラウンド通知と手動発火する確認期限を使い、要求した 50 ms と書込み失敗理由・effective/unresolved を実時間待機なしで検証します。本番の main queue `asyncAfter` による期限設定は変更しません。

`scripts/check_doc_references.py` は `README.md`、`AGENTS.md`、docs 配下の Markdown（records を除く）のリポジトリパス、script、既知 CLI の flag、Swift 型の参照を検査する。

### 発話文判定の契約

```bash
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev --filter 'DecisionTests|DecisionContractTests|DecisionEnrichmentCoordinatorTests|ClauseAssemblyTests|MaterializerTests|LiveContentPriorityGatingTests|LiveDecisionRecordingTests|FinalTranscriptPipelineTests|nativeTakeoverFinishesWithoutWaitingForLiveDecisionsAndReusesOnlyFrozenDurableAnswers'
```

[DecisionContractTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/DecisionContractTests.swift) は共有判定型の JSON 形、境界の厳密な `> 0.5`、確率の有限 0..1 検証、優先度判定の和（tagger と同じ `1e-5`）・confidence の完全一致と同率の扱い、不正な優先度判定を保存済み優先度の保留にすることを検証します。[DecisionTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/DecisionTests.swift) は回答の不足・余分でリクエスト全体が失敗し、失敗理由が保留の message になることを検証します。

計数・consumerの回帰検証は purpose 別の実 request 計数と合計、成功した判定だけの入力 token、session + 境界区間／優先度節の保留 identity、失敗した batch ごとの保留、cancel の attempt-only、判定成功後の保存失敗、低 confidence 判定・metadata 保持を対象にします。モデルの品質を合成結果で証明したとは扱いません。

実行 smoke は一時 harness で実 SessionWriter／NativeSessionProcessor／reader／metadata／export を通します。複数の保存 raw 区間から跨ぎ節と行内別節を作り、混在した優先度判定、finishInput、各 run の保存済み F 範囲をそれぞれの原文に適用し、削除後の本文を区切りなしで連結した UTF-8 bytes が完全一致する場合の priority のみの carry（live の F 範囲は final にコピーしない）、判定失敗の保留、設定と同じ再試行経路、metadata 再読込、txt 実出力、purpose 別 usage を観測します。判定無効（`ContentPriorityAccess.disabled`）では判定呼出し0・無分割通常表示・ローカル公開を確認し、ASR raw と `display_text` が一致します。この経路ではフィラー範囲を評価せず、フィラー除去を行いません。saved F assessment の表示・export は共通 Swift のフィラー検証で別に確認します。harness は検証後に除去します。この smoke はモデルの精度・GUI・録音権限を検証しません。

### ローカル発話文モデルの parity

通常の `swift test` では実 Core ML モデルを使う次のテストは skip されますが、encoding、fixture metadata、BOM token、tokenizer・package・モデル欠損の検証は毎回実行されます。実モデルテストは macOS 15 以降で CPU only・float32 を使います。リポジトリルートから実行します。

```bash
RUN_CLAUSE_TAGGER_TESTS=1 CLAUSE_TAGGER_MODEL_DIRECTORY=/absolute/path/to/exported-model swift test --package-path app/MacAmbientJev --filter 'LocalClauseTaggerTests|DecisionProviderFactoryTests'
```

`/absolute/path/to/exported-model` は例示用 placeholder です。学習済み ClauseTagger.mlpackage と tokenizer.json が直下にある実在ディレクトリの絶対パスへ置き換えてください。`scripts/build_app.sh` の後は、app bundle の Contents/Resources/clause-tagger の絶対パスを指定すると同梱モデルを検証できます。テストを有効にした状態で環境変数が未設定、相対パス、存在しないパス、またはディレクトリでないパスを指定するとセットアップエラーになります。既定パス、モデルの自動取得、fallback はありません。モデル package と tokenizer は Git に含めません。

[ClauseTaggerFixtures.json](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/Resources/ClauseTaggerFixtures.json) は SwiftPM の小さな test resource で、13件の入力文、厳密な token ID、boundary・span・priority の参照確率を持ちます。fixture の `model_revision` と `tokenizer_sha256` はテスト対象の学習済み package と tokenizer に一致しなければなりません。新しい学習済み export を作ったら、その export から fixture を再生成します。Swift の誤った tokenization を観測した値に合わせて期待 ID を書き換えてはいけません。`training_status` が `trained` 以外の package はアプリ判定に使用できません。

Parity の受け入れ基準は次のとおりです。

- Python の参照出力と Core ML reference MLProgram package を、`input_ids` が int32、shape が `[1,L]` の dynamic sequence 入力で照合します。全整数長 `L=2...192` の通常入力と randomized input について、`boundary_probs`・`span_probs`・`priority_probs` の各 head の最大絶対誤差が `1e-3` 以下であること。mask 対応は長さ 2、64、65、66、128、192 で確認します。これは Python 側が全長を検証する受入基準です。
- Swift fixture の全13文について、token ID と候補・junction index が完全一致し、三 head の確率誤差が `1e-3` 以下であること。句読点、連続句読点、Unicode、空白、190 token を超える長文の窓分割、continuation を含みます。raw `[CLS, SEP]` の2 token 入力と192 token 入力も検証します。優先度判定では、192 token を超える本文が先頭190 token への切り詰めで判定されること、句読点だけの本文がモデルで判定されることも検証します。Swift fixture は選定した入力群であり、全191長の確認を意味しません。
- Core ML は macOS 15 以降、CPU only・float32。Tokenizer は swift-transformers Tokenizers `1.3.4` の Unigram semantics を piecewise に使い、`prepend_scheme=never`、`split=false`、UTF-8 byte fallback を正確に実装します。要求と異なる tokenizer config は失敗させます。モデル入力は dynamic `input_ids` int32 `[1,L]`（`2...192`）、出力は `boundary_probs` `[1,L,2]`、`span_probs` `[1,L,3]`、`priority_probs` `[1,2]` です。

`RUN_CLAUSE_TAGGER_TESTS=1` と必須の `CLAUSE_TAGGER_MODEL_DIRECTORY` で有効になる実モデル境界テストは、`まあ、あの、今日は損失関数の話をします。` を評価し、フィラー範囲を適用した本文が正確に `今日は損失関数の話をします。` となることを受入条件にします。長文の窓分割では、全候補の UTF-16 offset が欠落・重複なく窓全体へ一度ずつ割り当てられ、長文 fixture の全 span token が重複なく割り当てられ、その UTF-16 範囲にも穴がないことを検証します。各応答確率は対応する token の model output と一致し、input token 数は全窓分を含みます。終端の `まあ。` は候補が空でも実モデルへ境界 request を送り、input token を計上します。このテストは指定した実モデルを使う受入基準であり、この文書は実行済み結果の報告ではありません。

Core ML 変換器は scratch の外部ツールで、このリポジトリに変換 script はありません。export artifact は base model、trained weights、明示した output directory を使って生成し、上記の MLProgram 入出力契約を満たす必要があります。変換実験の Python package version は PyTorch `2.14.1`、transformers `5.19`、coremltools `9.0` で、converter は unsupported PyTorch version warning を出します。Core ML Tools [9.0 release notes](https://github.com/apple/coremltools/releases/tag/9.0) には Torch `2.7` のサポートが記載されています。新しい Torch で変換が成功したことを公式サポートの根拠とは扱わず、artifact ごとに実際の installed version と warning を記録してください。

[DecisionProviderFactoryTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/DecisionProviderFactoryTests.swift) は tagger のロード結果（失敗を含む）を factory の寿命中 cache すること、同時要求が一つのロードを共有すること、実 token usage、request record の request ID と input token 数、provenance の model/model revision を記録することを検証します。これらは単体テストであり、GUI 操作、マイク／システム音声の権限、画面表示の確認にはなりません。

### 合成イベントによる回帰検証とライブ滞留計測

```bash
swift test --package-path app/MacAmbientJev --filter 'catalogRejectsUnreadableEventLog|validatedEmptyVADCompletesWithoutSpeechInference|recordingPreservesCaptureAndReleaseFailures|coolingDrainsLiveBacklogWithLatestCheckpointAndStopReleasesState'
swift test --package-path app/MacAmbientJev --filter measureLiveRegistrationCost
swift test --package-path app/MacAmbientJev --filter measureLatestCheckpointRetentionDuringThermalStall
swift test --package-path app/MacAmbientJev --filter 'liveASR|liveRows|stoppingRecordingCancels'
swift test --package-path app/MacAmbientJev --filter 'appRecordingShowsLiveRowsWhileDecisionsWait|appRecordingShowsDecisionFactoryFailureReason|liveRowsShowAtOnce|nativeTakeover'
CLAUSE_INCREMENTAL_BENCHMARK=1 swift test --package-path app/MacAmbientJev --filter liveClauseIncrementalBenchmark
```

correctness test は読み取れないイベントログ、検証済み VAD の空結果、録音障害と停止時の資源解放障害、冷却後のライブ認識再開の境界を合成イベントで検証する。計測 test は 5 秒ごとに一発話とした 10 分・1 時間・4 時間相当の合成イベントを使い、再登録の中央値時間と critical 時に保持する ASR バッチ・区間参照・checkpoint・chunk 一覧の項目数を出力する。計測 test の成功は性能合格を意味しない。時間はモデル推論を含まず、保持数は RSS ではない。実キャプチャ、GUI 起動、権限要求は行わない。

`measureLiveRegistrationCost` は debug 構成で、登録 setup を計測から除外し、各 120・720・2880 件の pending 履歴に対して同じ ID を 100 回再登録する標本を 7 個取り、一呼出しあたりの中央値を µs で出力します。登録 progress はセッション内の materialized 行と ID 数を使い、pending 履歴全体を再構築しません。判定目安は 4 時間相当の中央値 ≤ 50 µs かつ 10 分相当の ≤ 3 倍です。時間の単体テスト assertion は置きません。比率が timer noise で外れた場合は全 7 標本を報告し、同じ標本数で逐次に一度再計測します。認識済み行の更新 projection、モデル推論、アプリのキュー保持量はこの計測の対象外です。測定結果は [live registration 計測記録](records/2026-10-04-live-registration.md) を参照してください。

`measureLatestCheckpointRetentionDuringThermalStall` は portable な `LiveTranscriptionCoordinator` を直接動かし、fake executor、注入 sleep、critical 熱状態を使って、5 秒ごとに一発話とした 10 分・1 時間・4 時間相当を計測します。120・720・2880 発話で checkpoint の保持数はセッションあたり 1 件、保持 chunk 項目数は最新 checkpoint の 120・720・2880 件だけです。区間参照は全件保持します。AppState、filesystem、model は使わず、計測 harness は時間の assertion を置きません。`coolingDrainsLiveBacklogWithLatestCheckpointAndStopReleasesState` は実 `AppState.startRecording` / `stopRecording`、注入 VAD polling、合成の保存済み PCM、injected ASR を使い、critical 中の認識停止と最新 checkpoint の保持、冷却後の全区間を一度だけ順次認識すること、録音停止後のキュー・checkpoint 解放を確認します。portable な `criticalLiveDrainWaitsWithoutDequeueThenResumesFIFOUsingLatestCheckpoint` は、後から更新された最新 checkpoint が FIFO の各 batch に使われることを検証します。実モデル、マイク、GUI は使いません。

ライブ ASR regression は認識後の新規 pending 登録・重複 ID、ASR 完了・空本文・失敗の ordered snapshot、同一 run の保存済み節更新と active run 切替、登録・完了・失敗・終了イベントの保存障害、並行登録・終了を検証します。取得済み行配列は後の認識や節更新で変わりません。判定待機中も全行が即時表示されること、時間順、無効・初期化失敗・失敗した batch ごとの保留、空区間のテキスト列終端、ASR gap 後の未解決先頭を注入 provider で検証します。

[LiveClauseIncrementalTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveClauseIncrementalTests.swift) は通常の全履歴 materializer と増分更新の行・projection・保存 JSON を照合し、長い跨ぎ節、空区間、ASR gap、不正 batch の rollback、取得済み snapshot の不変性を検証します。[LiveClauseIncrementalBenchmark.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveClauseIncrementalBenchmark.swift) は一時音声と注入 ASR で実 `LiveASRSession.applyClauseEvents` を動かし、40・400・2500 区間で境界・節閉鎖・優先度を反映する時間を、テスト専用の全履歴再構築 actor と比較します。各規模で warmup 1 回と標本 20 回を使い、結果の同一性は計測区間外で照合します。通常 test では計測を無効とし、時間閾値を correctness の合否にしません。[測定記録](records/2026-10-09-clause-incremental.md) を参照してください。

[PriorityBatchPersistenceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/PriorityBatchPersistenceTests.swift) と [LiveContentPriorityGatingTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveContentPriorityGatingTests.swift) は注入 provider と一時イベントログで、81 節の確定・優先度再試行・ライブを検証します。失敗した batch をそれぞれ 40/40/1 件の保留として保存すること、境界判定の失敗がその区間だけを保留にして優先度判定を続けること、coordinator 取得中・判定待ち中の取り消しを扱います。LiveContentPriorityGatingTests の fixture は request・row・status の条件を continuation 通知で待ち、worker の終了後に `SessionWriter.readDurableLog(eventsURL:)` でwriter と同じ排他ロック下の durable snapshot を一度だけ読み、各 assertion と reader の再読込で同じ bytes を使います（取消しの基準 snapshot は fake provider の gate で worker を保持した状態で読みます）。全テストの2分 `timeLimit` は hang guard のみで、意味上の条件や実行時間予算ではありません。各テストは worker の終了後に一時 root を削除します。[NativeSessionProcessorLiveTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/NativeSessionProcessorLiveTests.swift) の finalization takeover fixture は provider gate、transcript update 通知、保持した live worker の終了を待って late response を確認するため、経過時間に依存しません。意味上の coordinator tests も明示 gate を持つ fake effects と注入 sleep で同期し、性能予算を置きません。実行全体の上限は既存の portable CI job timeout（Linux 20 分、Windows 30 分）です。実モデルは使いません。

`appRecordingShowsLiveRowsWhileDecisionsWait` は実 `AppState.startRecording`、checkpoint の VAD polling、区間登録、ライブ ASR drain、判定 queue、画面用 projection を通します。capture・VAD・ASR・判定 provider は合成入力に置き換え、応答を止めている間も通常行が表示され、保存済み判定だけが反映されることを確認します。`appRecordingShowsDecisionFactoryFailureReason` は分類器生成時の合成エラーを使い、理由が状態表示に残り、通常行を表示して録音と ASR を継続することを確認します。実モデル、マイク、GUI は使いません。

ライブ ASR drain の完了は、独立して動く判定キューの完了を保証しません。AppState はライブ処理の sleep を必須引数で受け取り、本番は Task.sleep、[LiveDecisionRecordingTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LiveDecisionRecordingTests.swift) と [MicInputStatusTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/MicInputStatusTests.swift) は手動で進める poll gate を渡します。ライブ判定の regression は起動時の保存整理 task を await し、VAD poll を一回進めて区間登録を確認した後、fake tagger の request 通知と画面用 rows・エラー状態の publisher 通知を待ちます。保存済み LOW 判定の反映も rows の通知で確認します。

[MicInputStatusTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/MicInputStatusTests.swift) の fake VAD は指定した batch 数の到達を continuation で通知します。各 poll の次の sleep gate まで待つことで、AppState が音声レベルを取り込んだ後に状態を検証します。入力音量の書込みは fake volume の通知、poll 中の VAD 障害は状態表示の通知を待ち、開始時の VAD 障害は `startRecording` の完了で確認します。これらの待機は中断時に条件名を含むエラーを投げ、1分の `timeLimit` は hang guard としてのみ使います。実時間の待機間隔や期限は同期条件にしません。

保存済みセッション catalog は active ASR run のイベントログ・payload を読み取り専用で検証し、欠損・不正・不完全な末尾を持つログを破損として表示する。合成 catalog regression は malformed / missing / directory の各ケースで非 exportable 状態、再処理可否、manifest と metadata の不変性を確認する。

Linux 音声正規化は入力と出力が同一ファイル（シンボリックリンク解決後を含む）なら、出力先を変更する前に拒否し、原音声を保持する。`tools/linux-audio/tests/test_audio.py` は実 ffmpeg を使う同一パス・symlink の境界と、正常変換・変換失敗時の出力処理を検証する。

`validatedEmptyVADCompletesWithoutSpeechInference` は 1 秒の合成無音を 2 回確定し、検証済み VAD の空結果が話者分離の準備失敗・推論失敗に依存しないことを確認する。ASR 準備も呼ばれず、原音声の bytes、読み取れる空 transcript、3 段階の provenance と成功 0 件完了、`complete` metadata、終端の無発話表示、復旧対象外の分類を検証する。VAD 自体の失敗と発話ありの推論失敗は `failed` のまま公開済み run を保持する。これは orchestration の検証であり、実 FluidAudio モデルの無音成功・クラッシュを測った結果ではない。

[CanonicalAudioIngressTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/CanonicalAudioIngressTests.swift) は device-rate の合成 tone を irregular / 512-frame block に分けて実 drain とディスクへ通す。48 kHz・44.1 kHz の累積 duration、block 境界の single-stream reference との sample 差、997 / 3101 Hz の波形誤差、16 kHz identity、4-channel import 平均、fractional-ratio の gap・overlap・overflow・stop tail、部分 append failure 後の retry と並行 finish / snapshot を検証する。fixture を保存前に preconvert しない。EOS 後の全体長は正確な長さの floor か ceil で、gap は公開範囲へ切り詰める。

`captureStartReservesStoredPCMNotDeviceRate` は injected tap の実 capture start を 48 kHz・44.1 kHz・16 kHz で実行し、601,600,000 bytes の受理と 601,599,999 bytes の拒否を確認する。hardware・permission prompt は使わない。[CanonicalEngineInputTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/CanonicalEngineInputTests.swift) は既存 CAF の実 samples を複数の bounded random range で読み、音声コピーを作らない source path と Qwen の非 canonical 入力拒否を検証する。同じファイルの `finalizationEnginesReceiveCanonicalAudioForRecordedAndImportedSessions` は、48 kHz の録音を irregular block で実 drain に通した session と 44.1 kHz stereo の import を実 `NativeSessionProcessor` で確定し、injected VAD・話者分離・ASR が受け取る形式（16 kHz・mono・float32、CAF 長、ASR sample 数）と original の bytes 不変を検証する。

### 保存音声のテスト

[SessionAudioStorageFormatTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/SessionAudioStorageFormatTests.swift) は `storage.json` の 4 つの形を bytes で固定する（[保存形式](storage.md)の例はこの出力）。[RecordingAudioCompactorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingAudioCompactorTests.swift) は 16-bit FLAC への変換を、4,096 フレーム前後を含む長さ、クリップ・端点・非有限値、破損・欠落・余剰フレームの FLAC、全 `Boundary` での中断と再実行の収束で確認する。[LaunchMaintenanceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/LaunchMaintenanceTests.swift) は起動時の保存整理が全セッションを収束させ、失敗したセッションをフォルダー名付きで返すことを確認する。[SessionStorageFinalizationTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/SessionStorageFinalizationTests.swift) は全結果での一時音声の削除、変換・削除の失敗報告、一時停止中の削除失敗、FLAC からの再処理（再符号化なし）、整理後の古い音声ソースを使わないことを、音声から結果を導く注入エンジンで確認する。[SessionExportTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionExportTests.swift) は FLAC の無変換コピー、PCM 状態の拒否、破損 FLAC での失敗と既存書き出しの保持、書き出しが内部音声を変更しないことを確認する。マイク・システム音声の権限や GUI の起動時整理の表示は、これらでは確認できない。

共通 Core の codec tests は [RecordingFLACEncoderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/RecordingFLACEncoderTests.swift)、[FLACTimelineReaderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACTimelineReaderTests.swift)、[FLACFrameDecoderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACFrameDecoderTests.swift)、[FLACMD5Tests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACMD5Tests.swift)、[FLACBitstreamTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACBitstreamTests.swift) にあります。reader の round-trip は noise・silence・clipped alternating signal・sine の 4 種と 1、4,095、4,096、4,097、12,305 frame の 5 長さを組み合わせた 20 ケースで、任意範囲読み取り（block 境界をまたぐ範囲を含む）も比較します。encoder の無音テストは全 sample の完全一致 round-trip とコンパクトな出力を確認し、単一 sample では VERBATIM と同サイズ以下、複数 sample では VERBATIM より小さいことを検証します。CRC、metadata・frame の切り詰め、長さ・MD5 の不一致、末尾 bytes を拒否し、handcrafted frame で FIXED 次数 0〜4、LPC、Rice2、escape coding、wasted bits を検証します。埋め込みの 16-sample frame は FIXED 次数 2・partition order 3 とし、先頭 partition の残差数が 0 となる境界も検証します。MD5 は RFC 1321 の既知 vector と signed 16-bit little-endian sample を使った vector で確認します。

`flac` 1.5.0 CLI は任意の参照 oracle です。テストは `PATH` から実行可能ファイルを解決し、固定 path は使いません。見つからない場合は Swift Testing の `@Test(.enabled(if: ...))` で該当テストを skip します（[無効化可能なテスト](https://docs.swift.org/latest/documentation/testing/enablinganddisabling/)）。参照エンコーダーを使う reader テストは、`-0` による FIXED、`-8` による LPC、全 sample が 8 の倍数となる wasted-bits 入力、`--lax -b 65535 -l 32` で符号化した入力の 65,535 sample 境界をまたぐ範囲読み取りの4ケースを検証します。参照 CLI の仕様は [flac 1.5.0 manual](https://raw.githubusercontent.com/xiph/flac/1.5.0/man/flac.md) を参照してください。[RecordingAudioCompactorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingAudioCompactorTests.swift) は portable な PipelineTests で、全 OS で compactor を検証します。一方、session reader・export・symlink 境界の integration tests（[SessionAudioReadersTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionAudioReadersTests.swift)、[SessionExportTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionExportTests.swift)、[SessionAudioSymlinkTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionAudioSymlinkTests.swift)）は macOS 専用の AppleSupportTests で、Core codec を通して検証します。

[SessionFileAccessTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/SessionFileAccessTests.swift) と [SessionAudioSymlinkTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionAudioSymlinkTests.swift) は一時ディレクトリだけを使い、イベント writer の初回 open と初期化後の置換、manifest・metadata の読込みと書込み、audio 親ディレクトリ、chunk・original・FLAC・partial・derived CAF の symlink を拒否することを検証します。セッション外の sentinel の bytes・ディレクトリ内容を比較し、descriptor を開いた後の URL 置換が元のファイルの読み書きを保つことと、通常セッションの成功経路も検証します。catalog・復旧はリンクされたセッションをエラーとして返します。選択 root の symlink 拒否は [AppPathsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/AppPathsTests.swift) が対象です。

AppState の合成テストに注入する `temporaryDefaults()` はインスタンス内の辞書だけを使う UserDefaults test double です。実 UserDefaults の標準 domain・suite domain を読み書きせず、音声デバイス・実ネットワークも使いません。

### セッション保存容量の合成計測

```bash
python3 scripts/measure_session_storage.py --sessions-root /private/tmp/mac-ambient-jev-storage-measure --seconds 600
```

`--sessions-root` と `--seconds`（正の整数。既定値なし）は必須。明示した scratch root に実行ごとの新規ディレクトリを作り、録音・import の保存、共通確定処理、書き出しを順次実行する。root は GUI の sandbox 内と CLI の非 sandbox の実データ・cache 領域、およびその祖先・子孫を指定できない。マイク、システム音声、GUI、実モデル、権限要求を使わない。Swift test はこの計測一つだけを実行し、通常の suite では無効にする。

fixture は seed 固定の `--seconds` 秒・48 kHz stereo float32 CAF の再現可能な低域 noise。録音は device-rate channel 平均を 512-frame block で ring / 実 capture drain の converter に渡し、16 kHz mono PCM を保存する。import は byte-for-byte original のコピーから同じ canonical timeline を毎回構築する。VAD・話者分離・ASR の injected engine は 16 kHz mono を検証し、最初の 1 秒を一発話として返す。音声全体の保存・CAF 生成・export は実装を実行する。これは保存容量の計測であり、音声認識精度・実 hardware capture・人声の圧縮率の根拠ではない。

`disk-usage.json` は録音終了時の session 全体、確定後の session 全体、import の処理タイムライン構築直後、各 export フォルダーの bytes を報告する。bytes は metadata を含む通常ファイルの論理長の合計で、filesystem の割当容量ではない。import の構築直後は original とタイムラインだけを含む snapshot で、確定中の CAF 生成時の peak ではない。600 秒を一時間へ換算するときは 6 倍する。fixture・session・export・レポートは調査用に保持し、削除は利用者が行う。

### 実 ASR モデルの smoke

Apple Silicon / macOS で、明示的な WAV ファイルを指定する。

```bash
RUN_MODEL_TESTS=1 ASR_SMOKE_AUDIO="$AUDIO_WAV_ABSOLUTE" \
  bash scripts/verify_v1.sh
```

`ASR_SMOKE_AUDIO` は絶対パスの読み取り可能なファイルが必須。Runtime の ASRIntegrationTests はさらに 16 kHz、mono、0 秒超〜60 秒以下を要求する。日本語音声を使う。モデルをロードして認識し、trim 後の本文が非空で日本語文字を含むことを確認するが、参照文との一致率は測らない。初回にはモデルの取得が必要。

`verify_v1.sh` は integration test の検出と Runtime test bundle の存在も確認し、指定時だけその bundle を xctest で実行する。`RUN_MODEL_TESTS=1` だけで fixture を指定しない手順は使えない。

## 共通 Swift の検証

#### フィラー範囲と表示 projection

[ClauseTaggerSpanProjectionTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerSpanProjectionTests.swift) はモデル token の `span_probs` 3列を O=0、F=1、D=2 と解釈し、各 token の argmax を使い、同率なら先頭の添字を選ぶことを検証する。token 範囲と生成されるフィラー範囲は原文の end-exclusive UTF-16 offset で表す。UTF-8 byte fallback の複数 token が一つの Unicode scalar を表す場合、それぞれがその scalar 全体の UTF-16 範囲を指し、UTF-8 byte offset にはしない（BOM は `[0,1)`、emoji の byte token は各々 `[1,3)`）。token 範囲を順に適用し、重なる位置は後の token の label で上書きする。F のみをフィラー範囲にし、隣接 F をまとめる。D、O、token 範囲で覆われない文字は残す。テストは surrogate pair、decomposed scalar、token overlap、無効な shape／probability／range も扱う。

[TranscriptTextProjectionTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/TranscriptTextProjectionTests.swift) は明示された F 範囲だけを削除し、フィラーに接続した句読点は削除する一方、無関係な空白・改行、開き括弧・引用符を保ち、本文を削除位置をまたいで連結し、retainedRuns/displayRanges は写像用の別々の run として保持することを確認する。隣接 F 範囲は一体として扱う。F 範囲が空なら `まあ、あの、今日は損失関数の話をします。` のようなフィラーらしい文字列も変えない。UTF-16 範囲が surrogate pair／Unicode Character の途中を割る場合や、範囲が空・重複・未整列・範囲外の場合は拒否する。

`materializerAppliesFillerRemovalOnlyAfterSavedAssessment` は ASR 原文 `えー、資料を配ります。` が assessment 前と boundary pending（request failed）時にはそのまま表示され、保存済み assessment の F 範囲 `[0,2)` を適用した後だけ表示本文が `資料を配ります。` となることを検証する。保存後も `text` と ASR event は原文のまま。tagger 初期化失敗も raw 表示と pending を保ち request は0件（`failedTaggerLoadKeepsLiveRowsUnsplitAndPendingWithoutRequests`）。[LiveClauseIncrementalTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveClauseIncrementalTests.swift) は保存済み範囲の到着で対象行の projection cache が更新され、古い raw projection が残らないこと、増分結果が全履歴 materializer・row projection・JSON と一致することを照合する。不正な event batch は assembly・clause・priority の状態と公開 row を部分変更せず transaction rollback し、その後の正しい batch でだけ更新する。

`boundaryAssessmentRequiresAndCarriesFillerRanges` は assessment JSON の必須 `filler_ranges` 欠落を decode error にし、encode/decode と run carry で範囲が保持されること、F 範囲が異なれば decision は同一でないことを検証する。event reader／coordinator は原文外の範囲を拒否する。`savedTranscriptLoaderKeepsRawFillerTextForPresentationAndExport` は保存済み ASR event を `SavedTranscriptLoader` で読み、assessment 保存前後も原文と event bytes が変わらず、保存済み F 範囲の後だけ表示 projection と実際の `transcript.txt` が `今日は公開鍵暗号を説明します。` になることを確認する。GUI の選択コピーとアクセシビリティ読み上げは別途、画面上で検証する。

節優先度の回帰検証は注入 `DecisionProvider` で決定的に行い、モデル品質の正解とは分ける。厳密な `> 0.5` と LOW 採用 `≥ 0.90`（直前の Double を含む）、候補の raw UTF-16 座標、候補なし・無句読点・連続句読点と末尾除外、跨ぎ節と終端、再利用対象を除いた後の40/41節の batch 境界を対象とする。候補が空の終端境界も boundary request として送信・計数し、input token を持つ。boundary と priority の request 数は独立して数え、この境界テスト単独の priority request は0件だが、全処理では非空の閉じた節を通常どおり priority request で分類する。最初の回答が有効でも後続の回答欠落・余分・不正な優先度判定で全batchを拒否し、一requestの失敗として数える。確定処理では、各 run の保存済み F 範囲をそれぞれの原文に適用して得た部分を区切りなしで連結し、その UTF-8 bytes が完全一致する場合に限り durable な priority 判定を再利用する。比較では trim・句読点・Unicode byte差を同一視せず、未公開 retry の回答も使わない。carry するのは priority 判定だけであり、live の F 範囲を final にコピーしない。schema・参照・coverage の破損、保留再試行と公開 snapshot、request 単位の token 計数、takeover 時の保存済み LOW の除去と判定待ち行の本文表示を確認する。LOW＋続き待ちは閉じた LOW 部分だけを除き、待機本文を保持する。画面 projection・txt・`display_text` は混在 PRIMARY/LOW（LOW を除いた本文）、全 LOW（行なし）、待機・保留・再試行待ち（本文を表示）、フィラーのみを含む実 slice で本文と行集合を確認する。文言・内部配線・コピーした設定値を固定するテストは根拠にしない。

実ファイルの受入smokeは一時harnessで `NativeSessionProcessor` → `SessionWriter` → metadata・readerの再読込 → `SavedSessionCatalog` → `SessionExporter` を通す。注入ASRの `えー、週末の設計を確認します。そうですね。` からPRIMARY/LOW混在を作り、rawの保持、LOWを除いた表示本文と実txt出力、全LOW行の非表示を確認する。注入した判定失敗ではpriority保留の本文を表示し、priorityだけのtargeted retryで公開boundaryを維持・非対象pendingをcarryする。boundaryの失敗では無分割行を保持し、boundary retryで両runとpendingを一括公開する。判定結果の前の再読込では直前の公開snapshotのままであることを確認する。2つのlive区間から1つのfinal区間への再利用は、各 run 自身の保存済み F 範囲を適用した本文を区切りなしで連結し、UTF-8 bytes が完全一致する場合に priority だけを carry し、live の F 範囲を final にコピーしないことを確認する。event appendとmetadata公開をそれぞれ実ファイルで失敗させ、ローカルのdurable本文・本文表示・3段公開を保持し、未公開の任意段を採用しないことを確認する。注入値はモデル精度の証拠ではない。harnessと一時セッションは受入後に削除する。

ASR gap の smoke は実ファイルに非空本文・ASR 欠落・成功した空 ASR・後続本文を保存し、`DecisionEnrichmentCoordinator` → metadata 公開 → reader/materializer の再読込を通す。前半本文を未解決のまま残し、空 ASR より後の本文だけを一回の優先度判定で分類し、保存 snapshot と再読込が一致することを確認する。空 ASR の後に新たな gap がある場合に先頭を推測しないことは回帰テストで扱う。

ライブ状態表示の実ファイル smoke は、注入 ASR で2区間を保存し、判定 coordinator の生成で初期化エラーを投げる。`LiveASRSession` と `LiveContentPrioritySession` の実装を通して、ASR 原文と通常表示を維持し、両区間の durable 保留理由と最後の状態表示に同じ失敗原因が残り、境界・優先度の判定呼出しが0であることを確認する。App の状態への反映は回帰テストで扱い、実 GUI の検証とは分ける。

### 録音しない受入と実画面での確認

授業など録音できない環境では、マイク・システム音声を開始せず、システム音量や出力装置にも触れない。既存ファイルのCLI処理とディスクだけの注入 smoke を行う。CLI の隔離 root で `--keep-session` の実処理を完了した後、JSON の `text` と参照先 ASR event の raw、`display_text`、`source`、`clause_state`、空 slice を照合する。CLI は発話文判定が無効なので、3つの local active run があっても判定 request は0件。認識済み source ごとに boundary pending があり、priority pending は空で、`text` と `display_text` は raw と一致する。終端行を含め F 範囲の評価・除去は行わない。これは判定無効による0件であり、実モデルの終端境界は候補なしでも request を送信する。inspect → resume の再書き出しで event bytes と metadata が変わらないことも確認する。CLI の出力をフィラー除去の証拠にはしない。

bundleは `scripts/run_app.sh` でbuildして起動する。プロセスの生存だけでは画面の合格にしない。GUI操作の権限がない場合は、設定・表示・exportボタンの確認を未観察として報告する。録音可能な時の手動受入では次を確認する。

- 「モデルを確認」で同梱モデルの ID と revision が表示されること、録音元・書き出し先、マイク／システム音声の実権限。
- 14秒超の実ASR原文をイベントで確認し、第一行の「発話文の続き待ち」、後続行の可視性、跨ぎpartsと確率を照合。
- PRIMARY＋LOWでLOW本文が消えること、全LOW行が消えること、LOW＋待機／保留の本文表示、選択copy/paste・accessibilityがLOWを除いた表示本文と一致すること、行単位の時刻popover・話者見出し。
- 録音停止後のASR drain・finishInputとfinal takeover、late結果不採用、実live/final本文が完全一致する場合だけのcarryと判定削減。
- priority障害で保存済みboundaryを維持し、ローカル公開が続くこと。
- 設定の保留再試行ボタン、二種targetの判定、atomic metadata切替、診断のrequest・token・pending内訳。
- 保存済み録音の再選択とGUI「書き出す」の実txt再読込、時刻・話者・改行処理、フィラー除去後に本文が残る全行とLOWの保持、イベントraw不変。GUI exportにJSONは含まれない。

`MacAmbientJevEvaluateSession`, `MacAmbientJevEvaluateASR`, and `MacAmbientJevEvaluateDiarization` consume explicit artifact files only; none locate or create saved sessions, so these artifact-only modes do not require `--sessions-root`. Every mode of the capture, file-processing, and live-latency CLIs requires an explicit root that rejects protected app data/cache roots, their ancestors/descendants, and symlink aliases.

```bash
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateSession
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateASR
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateDiarization
bash scripts/verify_portable.sh
```

`verify_portable.sh` は `scripts/check_portable_core.py` による Apple framework import 検査、SwiftPM manifest 評価、`MacAmbientJevCoreTests` を実行する。禁止 import は AVFoundation、AppKit、CoreAudio、CoreML、Security、SwiftUI。これは Core の境界検査であり、Linux 上で macOS runtime が実行できることを意味しない。

## ファイル入力 CLI の smoke

`MacAmbientJevProcessRecording` は macOS 専用で、マイクや GUI を使わず既存の音声を処理する。発話文判定は無効で、Core ML tagger をロードしない。

```bash
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --sessions-root "$SESSIONS_ROOT" "$AUDIO_FILE" "$SEGMENTS_OUTPUT"
```
出力先を省略すると音声と同じディレクトリに `segments.json` を作る。明示的な出力先は入力音声と異なるものにする。シンボリックリンクを解決して同一になる入力・出力は拒否する。通常は処理用セッションを終了時に削除する。調査・復旧・計測に必要な場合だけ `--keep-session` を付ける。

```bash
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --sessions-root "$SESSIONS_ROOT" --keep-session --low-heat "$AUDIO_FILE" "$SEGMENTS_OUTPUT"
```

`--low-heat` は import と resume に対応し、ASR 区間処理の pacing と MLX cache 上限を抑える。通常処理と比較する場合は出力先・セッションを分け、本文と処理状態を確認する。短い fixture の成功だけで長時間のメモリ条件やライブ遅延を合格にしない。

開始時の熱状態は nominal/fair を要求する。確定処理中の ASR 区間処理前に critical を検出すると paused となり、CLI は非 0 で終了する。failed/paused を completed と扱わない。VAD が正常に完了して空結果を返す場合は、音声書き出し・話者分離・ASR 推論なしで空の確定結果を成功として公開する。実モデルでの VAD 成功は合成回帰だけでは保証しない。

### inspect と resume

```bash
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --inspect-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT"

swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --resume-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT" \
  --low-heat "$SEGMENTS_OUTPUT"
```

ID は UUID、root は必須。inspect は位置引数・`--keep-session`・`--low-heat`・計測引数を受け付けず、指定対象の action と保存整理 `maintenance`（`compactRecording`、`removeTransients`、`null`）を JSON で出す。action は `finalize`、未公開の判定 run がある場合の `recoverDecisionRun`、判定の保留だけがある場合の `retryContentPriority`、`none`、音声が復旧できない場合の `unrecoverable`。読めない metadata 等の別のエラーは失敗として報告する。

UUID は manifest の完全 ID です。root 直下の manifest を検索して実フォルダーを解決し、不在・複数一致・名前の検証不整合は明示エラーにします。`none` は存在する正常セッションに復旧 action がない場合だけです。

resume は先にそのセッションの保存整理（FLAC 変換または一時音声の削除）を実行し、再走査した action で動く。resume は音声ファイルではなく対象 UUID と、セッション外の出力先を一つ指定する。録音・import の両方が対象で、finalize は共通確定処理を全量実行する。pending ASR だけを再投入する経路ではない。`recoverDecisionRun`、`retryContentPriority`、または action なしの場合、CLI は発話文判定を実行せず公開済みの結果を書き出す。resume が常に再処理を始めるわけではない。確定処理の失敗・一時停止では直前の正常な active run を保持する。

引数 parser は構文だけを検査します。resume の出力先 containment は実行時に実フォルダーを解決した後、symlink 解決・大文字小文字の同一視を保って検査します。実セッション内への出力は拒否し、lookup と containment の失敗は production engine の構築・処理より前に返します。

### 不正入力の smoke

`scripts/verify_cli_inputs.py` は build 済み CLI のパスを一つ受け取り、重複 flag、未知 option、inspect/resume の余分な位置引数、計測引数の欠落等の 10 ケースを実行する。不正入力の非 0 終了に加えて、出力・計測ファイル・セッションが作成されないことを確認する。さらに実 named folder で inspect の正常・不在・完全 UUID の重複・同じ先頭 8 桁の別 ID・名前/日時/suffix/stem の不整合を検証し、実セッション内（symlink・大文字小文字の違いを含む）への resume 出力を拒否して原ファイルが変わらないことを確認する。実モデルの正常推論とは別の検査である。

## セッションの CER

`MacAmbientJevEvaluateSession` は portable で、二つの位置引数だけを受け取る。

```bash
swift run --package-path app/MacAmbientJev MacAmbientJevEvaluateSession \
  "$SESSION_MANIFEST" "$SEGMENTS_JSON"
```

結果は標準出力の JSON。manifest の形式は次のとおり。

```json
{
  "id": "japanese-speech",
  "audio": "audio.wav",
  "reference": { "text": "今日は音声認識の動作を確認します。" }
}
```

`reference` は `text` または `file` のどちらか一つ。file は UTF-8 の参照文で、相対パスなら manifest のディレクトリから解決する。audio は manifest の必須項目だが、この CLI は音声を読み込んだり認識したりしない。

入力する `segments.json` の各要素から `start_ms` と `text` を読む。保存順に本文を改行で連結して CER を求める。レポートは `id` と `asr_evaluation`（raw/normalized CER と normalizer version）を持つ。

Linux runner の全音声一つの ASR artifact には `MacAmbientJevEvaluateASR`、話者分離 artifact には `MacAmbientJevEvaluateDiarization` を使う。どちらも参照・artifact の二位置引数と任意の末尾 `--output` を受け取る。詳細は [linux.md](linux.md) を参照する。

## ファイル処理の長時間計測

`scripts/measure_v1_run.sh` は release CLI を使い、音声 import または保存済みセッションの resume を一回計測する。事前に release product を build する。必要空き容量は 4 GiB 以上。

計測後は root 直下の manifest の完全 UUID を正規化して検索し、ちょうど一つの実フォルダーを解決します。ID 不在・複数一致・一致したフォルダーの名前/日時/suffix/source stem の不整合は明示エラーです。stem の Swift Character 境界での切り詰めを検査するため、実行する `python3` に `regex` package が必要です（`python3 -m pip install regex`）。日時は `created_at` から再計算しません。events、metadata、checkpoint、original は同じ解決済みフォルダーから読み、original が複数なら失敗します。import がセッション作成前に失敗して stdout に ID がない場合は、セッションの欠測理由を残します。ID がある場合は lookup の失敗を欠測扱いにしません。

`scripts/test_session_artifacts.py` は shell script 内の実 artifact Python を抽出して合成セッションで実行し、成功・不在・重複・不正 suffix/stem・合成文字の切り詰め・original の重複を検査します。capture summary の実 path が指定 root 直下であること、完全 UUID、systemAudio source、録音フォルダー名も検査します。capture/playback 部分は実行せず、実音声・権限・GUI の検証根拠にはなりません。単独実行は `python3 scripts/test_session_artifacts.py` です。

```bash
swift build --package-path app/MacAmbientJev -c release \
  --product MacAmbientJevProcessRecording

bash scripts/measure_v1_run.sh \
  --id lecture-ja \
  --audio "$AUDIO_FILE" \
  --sessions-root "$SESSIONS_ROOT" \
  --keep-session --low-heat \
  --output "$SEGMENTS_OUTPUT"
```

import と resume の両方で `--sessions-root` が必須です。import は `--audio` と `--keep-session` を指定し、resume は `--resume-session` を指定して `--audio` を省略します。

```bash
bash scripts/measure_v1_run.sh \
  --id lecture-ja \
  --resume-session "$SESSION_ID" \
  --sessions-root "$SESSIONS_ROOT" \
  --low-heat --output "$SEGMENTS_OUTPUT"
```

共通の必須引数は `--id` と `--output`。id は英数字・ハイフン・underscore のみ。run ID は id と UTC 時刻から作り、segments 出力先の親に run 用のディレクトリを作る。

保存物は `run.json`、`engine-metrics.json`、`thermal.jsonl`、`memory.jsonl`、stdout.log、stderr.log、source-snapshot.tar.gz、成功時の `segments.json`。入力・イベント・source snapshot・依存解決ファイル・差分の hash、実行コマンド、環境、終了コードを記録する。計測値はこの起動の範囲であり、過去の run の ASR 時間を引き継がない。

- `run.json` の対象キーは `recording_id`。`status` は `completed` / `failed` / `paused`。
- `asr_rtf` は ASR 呼び出し時間 ÷ 処理済み音声秒数。モデルロード、pacing 待機、処理全体の wall time を混ぜない。
- 欠落・破損した engine metrics、thermal/memory sample、run ID 不一致は失敗。欠測を 0 として補完しない。
- 読み取るイベントと processing metadata は `schema_version: 3` が必須。版が異なるか欠落している場合は計測を失敗とする。
- `memory.jsonl` は run ID、UTC 時刻、phase、`footprint_bytes`、MLX の active/cache/peak/cache-limit bytes。footprint 取得失敗は null と `footprint_error` の理由を持つ。sample 書き込み失敗も CLI の失敗になる。
- `thermal.jsonl` は run ID、UTC 時刻、state。サンプルは開始・終了・約 5 秒ごと、および phase 変更時に取る。critical は確定処理を一時停止する。
- マイクの dropout、発話文判定の件数（`decision_success_count` など）、クラッシュ復旧の音声喪失窓は、このオフライン計測では測れず null と理由を記録する。

メモリ判定は ASR phase の有効な phys_footprint サンプルを使う。最初と最後の重ならない各 5 分窓で 48 件以上、全体で少なくとも 96 件・600 秒の範囲が必要。最後の中央値 − 最初の中央値が 512 MiB 以下、かつ `/usr/bin/time -l` の peak memory footprint が 12 GiB 以下で正常終了なら `VERIFIED`。サンプル不足、peak 欠測、途中失敗等は `INCONCLUSIVE`、条件を評価できて閾値超過なら `FAILED`。max RSS と peak footprint は別に記録する。短時間 run の INCONCLUSIVE は精度や処理成功の判定とは別で、ライブ録音全体のメモリ合格を意味しない。

### CLI に直接計測引数を渡す場合

import/resume には `--run-id`、`--metrics-output`、`--thermal-output`、`--memory-output` を四つすべて指定する。run ID は空でなく `/` を含まないもの。三つの計測出力先は互いに異なり、既存ファイルがないことが必要。通常は上の script に任せる。

## 原速 replay のライブ遅延計測

```bash
bash scripts/measure_live_latency.sh "$AUDIO_FILE"
bash scripts/measure_live_latency.sh --sample-rate 48000 --channels 1 "$AUDIO_FILE"
```

`MacAmbientJevMeasureLiveLatency` は既存音声を原速で投入し、VAD 区間終了から最初の非空な RAW ASR 更新までを計測する。発話文判定は無効で、最初の `displayText` は未評価の ASR 原文。空白・改行だけの本文は除外するが、認識されたフィラーだけの非空 raw 行も最初の更新として数える。CLI は tagger を実行せず F 範囲を除去しないため、これはフィラー除去後の更新時間ではない。report に記録する本文も raw で、空白・句読点の変更や正規化を行わない。次区間待ちと境界・優先度判定の時間は測らない。投入は遅延計測と同じ時計の起点からの絶対予定で行い、各 0.5 秒の塊はその末尾の音声時刻まで待ってから durable append する。変換や append の処理時間は後続の塊へ累積しない。report の `replay_max_feed_lag_seconds` は、各 append の完了時刻から、それまでに投入した replay input の音声秒数を引いた値の最大値である。この値が大きい場合は投入が原速に追いついておらず、遅延値に投入の遅れが含まれる。replay の入力形式は既定でファイル形式、明示指定時はその device 相当形式に変換する。sample rate は 1000〜768000 Hz、channels は 1〜32。durable append 前に同じ ingress converter を通し、保存と VAD / ASR は常に 16 kHz mono。report の `source_*`、`replay_input_*` と `processing_*` は別形式を表し、frame 座標は保存 timeline を参照する。`--match-default-input` は既定入力 format を読むだけで capture を開始しないが、sample rate/channels の明示指定とは併用できない。

Qwen と VAD のキャッシュ済みモデルが必要。閉じた VAD 区間、または最長 14 秒分割が表示単位であり、長い発話は初表示まで待つ。測るのは非空更新までで、実画面描画、マイク入力の実時間、全発話の精度を保証する指標ではない。

### 保存整理のテスト

Runtime の保存整理テストは、確定処理の全結果（成功・発話なし・VAD／話者分離／ASR の失敗・話者分離中のキャンセル・一時停止）と録音・import の組で、話者分離入力 CAF と import の処理タイムラインが残らないこと、開始失敗でも古い一時ファイルが消えること、削除失敗・変換失敗のメッセージ、変換後の再処理が PCM 由来と同じ文字起こしを返し FLAC を変えないこと、失敗した再処理が公開結果と FLAC を保つことを、音声から結果を導く fake engine で確認する。AppleSupport の起動時整理テストは、全セッションの整理が収束し、整理に失敗したセッションをフォルダー名付きで返し、録音中のセッションに触れないことを確認する。App テストは、起動時の保存整理中に、音声がまだ `recordingPCM` の録音の書き出しが、書き出し先へ触れる前に整理中のメッセージで止まることを確認する。

## Linux Python の単体テストと suite

uv を使う場合は `tools/linux-audio` を作業ディレクトリにして実行する。

```bash
cd tools/linux-audio
uv run --python 3.12 --with pytest python -m pytest -q tests
```

suite はリポジトリルートで実行する。

```bash
bash scripts/verify_linux_audio.sh --smoke
```

Python unit test は artifact、baseline、CSJ parser、VOICEVOX、overflow resolver、runner 等のロジックを検証する。suite はさらに portable Swift と依存の有無を確認する。full の必須 fixture、device、参照種別、Nemotron の明示指定と CI のモデル別実推論は [linux.md](linux.md) のとおり。依存欠落や未実行を PASS と解釈しない。
