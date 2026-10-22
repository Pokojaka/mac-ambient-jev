# 検証と計測

検証記述は build / test target と実行した test の範囲を示し、製品 process の受入を意味しません。Windows の現行 target、保存規則、対象外機能は [windows.md](windows.md)、capture の境界は [capture.md](capture.md) を参照してください。macOS app bundle の plist 生成を確認する Bash テストは Windows では実行しません。

自動検証、実モデルによるファイル処理、計測結果の意味を分けて扱う。実マイク・システム音声の capture や画面の確認は fake 入力やファイル処理だけでは検証できない。Linux の artifact・corpus・CI 実推論は [linux.md](linux.md)、処理経路は [final.md](final.md)、保存と公開結果は [storage.md](storage.md) を参照する。

以下のコマンドはリポジトリルートから実行する。実データのファイル名、セッション ID、保存先を示す環境変数には、自分の実在するデータを設定する。個人録音は Git に入れず、ローカル録音用の領域に置く。配置の案内は `test-data/recordings/README.md` にある。

## 現行 EngineProtocol / EngineHost の検証範囲

`MacAmbientJevEngineProtocol` と `MacAmbientJevEngineHost` は portable な library target で、macOS・Linux・Windows の build / test 対象です。[MacAmbientJevEngineProtocolTests](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/) は NDJSON v1 の strict codec、lexical validation、全 command / event の golden corpus を検証します。[MacAmbientJevEngineHostTests](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/) は scripted byte source / sink と fake handlers を使い、framing、queue/backpressure、request admission、dispatcher、settings store / lock を検証します。これらは portable な protocol / host unit tests で、実 engine process を起動しません。

```bash
swift test --package-path app/MacAmbientJev --filter 'MacAmbientJevEngineProtocolTests|MacAmbientJevEngineHostTests'
```

この focused command は macOS での手動確認用です。`EngineTransportPipeTests.swift` は POSIX pipe integration test で `#if !os(Windows)` により Windows では除外されます。Windows で fake source / sink tests が通ることを POSIX pipe integration の実行と取り違えません。

`MacAmbientJevEngine` executable product は Windows 専用で、Linux に engine executable product はありません。Windows runner は package build に加えて `--product MacAmbientJevEngine` を明示して build します。package / product build と portable unit tests は engine process を実行せず、process acceptance を確立しません。

| OS / 手順 | 現行 build / test 範囲 |
| --- | --- |
| macOS | `MacAmbientJevEngineProtocol` / `MacAmbientJevEngineHost` の portable tests を実行できます。上の focused command はこの手動確認用です。通常の macOS 検証は後述の AGENTS 指定コマンドを変更せず実行します。 |
| Linux | [`verify_portable.sh`](../scripts/verify_portable.sh) は fetch / check の後、manifest dump と unfiltered build / test を実行します。EngineProtocol / EngineHost と PortableRuntime 等を含みますが、`MacAmbientJevWindowsSupport` と `MacAmbientJevEngine` product は Linux target ではありません。通常の Linux CI fast job は同じ fetch/check 後に直接 package build / test を実行し、`linux-model-e2e` job の範囲は変わりません。 |
| Windows | [`scripts/test-windows.ps1`](../scripts/test-windows.ps1) は EngineProtocol / EngineHost / WindowsSupport / PortableRuntime 等を build し、`MacAmbientJevEngine` product も明示 build します。native injected C tests の後、Swift tests は以下の2 passで実行し、Windows で適用される全 suite（新しい portable fast suites を含む）を各1回実行します。runner は ONNX Runtime DLL と必要な pinned test assets / 環境変数を用意します。 |

Windows runner の Swift test command は次の順で fail-fast に実行します。

```powershell
swift test --package-path app/MacAmbientJev --filter MacAmbientJevEngineHostTests
swift test --package-path app/MacAmbientJev --skip-build --skip MacAmbientJevEngineHostTests
```

最初の pass は `--filter` で EngineHost を実行し、test targets を build します。続く `--skip-build` pass はその build を再利用し、`--skip` で EngineHost を除いた applicable suites を実行します。2 pass で EngineProtocol / WindowsSupport / PortableRuntime / Core / Pipeline / ONNX 等を含む Windows の test set 全体を重複なくカバーします。EngineHost の transport tests は fake sink を意図的に block したまま短い write deadline を使うため、model / tokenizer workload とは別に先行実行します。

Linux CI fast job の package command は次のとおりです（先行する fetch / check step の後に実行します）。

```bash
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev
```

Linux / Windows の PortableRuntime tests が使う pinned asset path は runner が fetch して既存の必須環境変数に設定します。WindowsSupport の fake capture tests と native injected C tests は実 audio hardware を使わず、実機 WASAPI の動作を保証しません。現在の `test-windows.ps1` には `Fake-capture acceptance integration point (job 7A)` というコメントだけがあり、fake-capture acceptance は実行しません。`-FullModel` は既存の model numerical tests と ProcessRecording acceptance driver を追加実行しますが、host / fake-capture acceptance ではありません。

### Windows native capture-safety injected C test

Windows runner はすべての実行で（`-FullModel` を含む）native C test を Swift tests と別に compile / run します。compiler は解決した `swift.exe` と同じ toolchain directory の `clang.exe`、出力先は `swift build --show-bin-path` で解決した debug `binDir` です。実際の compile command は次の形です。

```text
<clang.exe> app/MacAmbientJev/Tests/CMiniaudioInjected/WindowsCaptureSafetyInjectedTests.c -o <binDir>/WindowsCaptureSafetyInjectedTests.exe -lole32
```

runner は生成 exe の存在を検証してから起動し、compile / run の非 0 exit code は失敗です。test source は production [C implementation](../app/MacAmbientJev/Sources/CMiniaudio/WindowsCaptureSafety.c) を include し、Win32 / COM 呼び出しを local substitutions で差し替えます。SetEvent 解放失敗時に join しないこと、成功時の power cleanup、active probe の再利用と invalidation、GetState failure による invalidation、session-enumerator error の伝播を検証します。音声 hardware は使いません。

### macOS から Windows VM で検証

リポジトリルートから `winvm test .` を実行すると、作業ツリーを VM に自動同期し、Windows test runner [`scripts/test-windows.ps1`](../scripts/test-windows.ps1) を実行します。VM は 6.8 GB のため、test run は同時に1つだけにします。

```bash
( until mkdir /private/tmp/winvm-p4.lock 2>/dev/null; do sleep 30; done; winvm test .; rc=$?; rmdir /private/tmp/winvm-p4.lock; exit $rc )
```

### Linux Docker で portable 検証

Linux で portable 検証をローカル実行する場合は、次のコマンドを使います。bind mount 上で SwiftPM が macOS `Package.resolved` を削除・変更する場合があるため、使い捨て checkout / worktree で実行します。

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2-noble bash -lc 'apt-get update && apt-get install -y python3 flac && bash scripts/verify_portable.sh'
```

[`verify_portable.sh`](../scripts/verify_portable.sh) は pinned assets を fetch し、portable checker の self-test と import check を行い、SwiftPM manifest を dump してから unfiltered `swift build` / `swift test` を実行します。test は Core / Pipeline / EngineProtocol / EngineHost / PortableRuntime / ONNX 等を含みますが、Linux には WindowsSupport と `MacAmbientJevEngine` product はありません。Linux CI fast job は同じ検証内容の一部を fetch/check step 後の直接の `swift build` / `swift test` で実行し、この shell script 自体は呼びません。`linux-model-e2e` は既存の separate job です。

[`check_portable_core.py`](../scripts/check_portable_core.py) の default roots には Core / Pipeline に加えて EngineProtocol / EngineHost、Diarization / DiarizationMeasurement、ONNX、PortableRuntime が含まれます。portable root から Windows-only `MacAmbientJevEngine` の import を拒否し、WindowsSupport 自体は portable scan roots に含めず、`MacAmbientJevWindowsSupport` import には `#if os(Windows)` を要求します。portable-core workflow の path filter は新しい engine source / test / executable target、native injected test、runner と docs の変更を対象にします。path filter のない macOS CI の対象は変更しません。

## 共通 Core / Pipeline テストの現状

[MacAmbientJevPipelineTests](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/) は Windows・Linux で実行する portable な状態・調整ロジックのテストです。[RecordingLifecycleTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingLifecycleTests.swift) は録音・import の lifecycle、[SessionProcessingQueueTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingQueueTests.swift) は FIFO・重複再処理の抑止・thermal hold/resume を検証します。queue の保存整理 state と app 上の完了・失敗表示および整理中の export 制御は、macOS 専用の [LaunchMaintenanceStatusTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LaunchMaintenanceStatusTests.swift) と [ExportDuringMaintenanceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/ExportDuringMaintenanceTests.swift) が検証します。[SavedSessionOperationsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SavedSessionOperationsTests.swift) は保存済みセッションの選択と export 状態、[LiveTranscriptionStateTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveTranscriptionStateTests.swift) は FIFO batch・最新 checkpoint・failure・cleanup、[ThermalMonitoringTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/ThermalMonitoringTests.swift) は Windows の `WindowsNoThermalMonitoring` が熱状態を読み取らず、`isCritical == false` と `liveASRDecision == .processNow` を返すことを確認します。

[SessionProcessingCoordinatorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingCoordinatorTests.swift) は critical 時の hold / resume と FIFO、pause 時の claim 維持と completion 後の release、recovery filtering を検証します。[LiveTranscriptionCoordinatorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveTranscriptionCoordinatorTests.swift) は fake engines と注入 sleep を使い、thermal wait 中の FIFO、registration await failure と failure / cleanup 後の idle・backlog 状態、cleanup 時に進行中 batch を cancel せず完了させること、遅れて返る failure を公開しないこと、古い drain が置換後の同一 session state を上書きしないこと、VAD progress が ASR 区間登録より先に通知される順序を検証します。[ThermalLineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ThermalLineTests.swift) は Foundation の 4 state（`nominal`、`fair`、`serious`、`critical`）で完全な JSONL 行を直列化することを確認します。ここで挙げた Core / Pipeline tests は portable で、ThermalLineTests は Mac 専用 CLI test です。

```bash
swift test --package-path app/MacAmbientJev --filter MacAmbientJevPipelineTests
```

テストに付ける `timeLimit` は hang guard としてのみ使い、値はすべて10分です。Swift Testing は全テストを並列に開始するため、各テストの経過時間には suite 全体の待ち時間が含まれ、負荷の高い CI ランナーでは2分を超えます。上限は suite 全体の実行時間より長くし、意味上の条件や実行時間予算には使いません。

Windows の [`scripts/test-windows.ps1`](../scripts/test-windows.ps1) は同じ Pipeline test target を EngineHost を除く2番目の pass で実行します。これらは portable な調整・状態ロジックの検証です。WindowsSupport の capture unit tests と native injected C test は別に実行しますが、実 audio hardware を使う検証ではありません。

[CaptureSafetyTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/CaptureSafetyTests.swift) は startup/stall/silence、disk threshold と error rules、oversized mono buffer を検証します。[TimestampedMonoSinkTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/TimestampedMonoSinkTests.swift) は raw-meter の 100ms windows、channels 間の clipping、gaps/reset、metering 前後で audio が変わらないことを検証します。AudioCaptureEngine/CoreMedia/IOKit との実 integration は macOS 専用 AppTests（[AudioCaptureEngineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/AudioCaptureEngineTests.swift)、[CaptureSafetyTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/CaptureSafetyTests.swift)）で扱います。

## macOS の基本検証

```bash
python3 -B scripts/check_portable_core.py
python3 scripts/check_doc_references.py
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev
bash scripts/verify_v1.sh
```

`verify_v1.sh` は `RUN_MODEL_TESTS` と `ASR_SMOKE_AUDIO` を引き継ぎ、`scripts/verify_v1_tests.sh`、続けて `scripts/verify_v1_app.sh` の順に実行する。`RUN_MODEL_TESTS=1` の場合は、Swift コマンドを始める前に `ASR_SMOKE_AUDIO` が読み取り可能な絶対パスであることを検査する。`scripts/verify_v1_tests.sh` は次の1〜6を行い、`scripts/verify_v1_app.sh` は7を行う。

1. `scripts/test_doc_references.py` でドキュメント参照 checker の自己テストを、`scripts/check_doc_references.py` で参照検査を実行する。`scripts/test_japanese_numeral_exclusions.py` で漢数字表示の除外句一覧の生成規則と、コミット済みの生成物が `labels.tsv` と一致することを検査する。`scripts/test_session_artifacts.py` で計測・capture summary の artifact 検査を合成セッションで実行する（処理・capture は開始しない）。イベント・処理 metadata の schema version 3 と、未対応・欠損・型不正の version の拒否も検証する。Python の `regex` package が必要。
2. SwiftPM の依存を解決し、`swift build --build-tests` で package とテストをまとめて build する。
3. `env -u RUN_MODEL_TESTS swift test --skip-build` で、事前に build したテストを再利用して通常の Swift test を実行する。
4. `MacAmbientJevProcessRecording` を build し、`scripts/verify_cli_inputs.py` で不正入力、ローカル3段階の成功0件を公開した named folder の inspect、イベント・処理 metadata の未対応・欠損・型不正 version の拒否、resume 出力先の containment と保存ファイルの不変性を確認する。
5. `MacAmbientJevEvaluateSession` を build する。
6. モデル検証を指定した場合は Swift test 一覧に ASRIntegrationTests があることと Runtime test bundle の存在を確認し、その bundle を `xcrun xctest` で実行する。
7. `scripts/build_app.sh` で発話文判定モデルを release asset から取得して SHA-256 を検証し、app bundle に同梱する。MLX の Metal shader library は Swift Build backend で生成するため、その backend で build し、Apple Silicon 専用の arm64 のみを対象にする。続けてアプリアイコンの CFBundleIconFile 指定と `.icns` の読み込み、最小・最大解像度の収録、MLX Metal shader library、同梱した発話文判定モデルの2ファイル、codesign の検証、利用者が選んだファイルへの read/write と app-scope bookmark の2つの entitlement を確認する。

アプリの build は行うが GUI を起動しない。通常の検証は実 ASR モデルを実行せず、認識精度やライブ録音の合格根拠にはならない。`.github/workflows/ci.yml` は draft PR を除き、`macos-26` 上で `verify-v1-tests` と `verify-v1-app` の2 job を並列に実行する。前者は Python 3.13 と `regex` package を用意して `bash scripts/verify_v1_tests.sh` を実行し、後者は `bash scripts/verify_v1_app.sh` を実行する。両 job は GitHub Actions の cache で、SwiftPM の依存ソース（`.build/checkouts/`、`.build/repositories/`、`.build/artifacts/`、`.build/workspace-state.json`）を cache する。key は runner OS と `Package.resolved` の hash で、`restore-keys` は指定しないため、完全一致する cache だけを復元する。build products は 4 GB を超えるため cache しない。

cache の有無にかかわらず依存解決と build・test は実行する。`verify-v1-app` job だけが MLX の Metal shader library を build するため `xcodebuild -downloadComponent MetalToolchain` を実行し、実行ごとに「MacAmbientJev Local Signing」という自己署名コード署名証明書を一時 keychain に作って署名に使う。発話文判定モデルの release asset は `GH_TOKEN`（`github.token`）を使い `gh` から取得する。

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

実行 smoke は一時 harness で実 SessionWriter／NativeSessionProcessor／reader／metadata／export を通します。複数の保存 raw 区間から跨ぎ節と行内別節を作り、混在した優先度判定、finishInput、各 run の保存済み F・B除去範囲をそれぞれの原文に適用し、削除後の本文を区切りなしで連結した UTF-8 bytes が完全一致する場合の priority のみの carry（live の F・B除去範囲は final にコピーしない）、判定失敗の保留、設定と同じ再試行経路、metadata 再読込、txt 実出力、purpose 別 usage を観測します。判定無効（`ContentPriorityAccess.disabled`）では判定呼出し0・無分割通常表示・ローカル公開を確認し、ASR raw と `display_text` が一致します。この経路では F・B除去範囲を評価せず、F・B除去を行いません。保存済み F・B除去範囲の表示・export は共通 Swift の範囲検証で別に確認します。harness は検証後に除去します。この smoke はモデルの精度・GUI・録音権限を検証しません。

### ローカル発話文モデルの parity

発話文判定テストでは、通常の `swift test` で実 Core ML モデルを使うテストだけが skip され、model-free tests は通常の suite で実行対象です（他の suite や benchmark の gate は別途適用されます）。fixture 比較器、環境変数の検証、BOM を含む JSON reader の回帰テストも gated な実モデル実行なしで動きます。実モデル parity は macOS 15 以降で CPU only・float32 を使います。リポジトリルートから実行します。

```bash
RUN_CLAUSE_TAGGER_TESTS=1 CLAUSE_TAGGER_MODEL_DIRECTORY=/absolute/path/to/exported-model swift test --package-path app/MacAmbientJev --filter 'LocalClauseTaggerTests|DecisionProviderFactoryTests|ClauseTaggerParityFixtureTests|ClauseTagger'
```

`/absolute/path/to/exported-model` は placeholder です。学習済み ClauseTagger.mlpackage と tokenizer.json が直下にある実在ディレクトリの絶対パスへ置き換えてください。`scripts/build_app.sh` の後は、app bundle の Contents/Resources/clause-tagger の絶対パスを指定すると同梱モデルを検証できます。gated run では `RUN_CLAUSE_TAGGER_TESTS=1` と明示的な `CLAUSE_TAGGER_MODEL_DIRECTORY` が必要です。環境変数の未設定・空値、相対パス、存在しないパス、ディレクトリでないパスはエラーになります。`MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY=1` を `RUN_CLAUSE_TAGGER_TESTS=1` なしで指定する場合もエラーです。既定パス、モデルの自動取得、fallback はありません。学習済みモデル package は Git に含めず、production tokenizer はアプリ release に同梱します。test-only の hash-pinned tokenizer JSON は Git に含めます。

fixture は production dependency を持たない all-platform の test-only SwiftPM target `MacAmbientJevClauseTaggerFixtures` に置き、reader と resources を共有します。[reader](../app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/ClauseTaggerFixtures.swift) は元 fixture を JSONDecoder で読みます。leading U+FEFF を含む値は、現行 runtime の JSONSerialization が decode 時に除くため、scalar を保つ reader/comparator regression も実行します。

[ClauseTaggerFixtures.json](../app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerFixtures.json) は13件の元入力、厳密な token ID、boundary・span・priority の参照確率を持ち、移動前と byte-identical（SHA-256 `2a359e7f416da5a431c35fe89d6abf8ed413c457c330763b64a59296d273294a`）です。実モデル capture より先に、model ID・revision `90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9`・tokenizer SHA と、元13件すべての literal input ID、candidate/junction index、三 head の形と確率を照合します。期待 token ID を Swift の誤った tokenization に合わせて変更してはいけません。`training_status` が `trained` 以外の package はアプリ判定に使用できません。

[ClauseTaggerTokenizerFixtures.json](../app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerTokenizerFixtures.json) は47 cases・106 pieces を持ち、release tokenizer SHA-256 `0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062` を固定します。元13件に加え、BOM、composed/decomposed Unicode、OOV、emoji modifiers、whitespace、全18 added token、2つの埋め込み synthetic tokenizer config と SHA-256 による8件の exact Float32 tie cases を含みます。fixture の `tokenizer_backend` は capture provenance で、runtime dependency ではありません。現行の `MacAmbientJevCore` の [ClauseTaggerTokenizer.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerTokenizer.swift) は Foundation-only の scalar trie と Float32 Unigram lattice 実装で、`swift-transformers` を runtime import しません。swift-transformers 1.3.4 release は tokenizer algorithm の provenance です（[1.3.4 release](https://github.com/huggingface/swift-transformers/releases/tag/1.3.4)）。

[ClauseTaggerTokenizerTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerTokenizerTests.swift) は CoreTests の全 platform で無条件に実行される model-free tests です。5 tests が現在の47 cases・106 pieces・8 ties、77個の不正・未対応 configuration mutation、誤 hash・読取・parse error、byte-distinct Unicode、Float32 加算順序（比較前に Float32 へ加算）、byte fallback witness、および BOM・空白・unknown-run の raw UTF-16 範囲 regression を検証します。この回帰テストはサポート対象の埋め込み synthetic tokenizer prefix（byte ID 固定）を使います。test-only resource [ClauseTaggerTokenizer.json](../app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerTokenizer.json) は pinned release tokenizer と byte-identical（6,724,873 bytes、SHA-256 `0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062`）です。期待 token ID・範囲と request の golden fixtures は変更せずに照合します。既知 scalar を含む lattice で隣接する unknown pieces の再構成失敗が `.unrepresentableText` となることも検証し、通常の OOV は byte fallback で表現します。この Core tokenizer tests にモデル weights、download、環境変数は不要です。この JSON は test resource 専用で、app fallback には使いません。

```bash
swift test --package-path app/MacAmbientJev --filter ClauseTaggerTokenizer
```

[ClauseTaggerRequestFixtures.json](../app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerRequestFixtures.json) は同じモデル identity の Core ML・CPU only・float32 による request parity を保存します。6 boundary cases・10 raw model calls と、3 targets / 3 calls の priority batch を含みます。multi-window、short/long continuation、候補なしの終端 `まあ。`、filler、backchannel を扱います。filler の必須 projection は入力 `まあ、あの、今日は損失関数の話をします。` から出力 `今日は損失関数の話をします。` です。backchannel は元コーパスの F/B owned-span argmax witness を確認します。priority batch では192-token truncation も確認します。各 request の source、candidates、`next`、全 window の input IDs・ownership・UTF-16 ranges、junction/span indices、raw 3 heads、実際の `LocalClauseTagger` response と projected text を記録します。raw model snapshots は同じ既存 encoder/model sequence の決定的 replay であり、production trace hook ではありません。fixture を書く前に replay と public response を照合します。

保存済み request の replay と実モデル capture は別の検証です。[ClauseTaggerDecisionLogicFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerDecisionLogicFixtureTests.swift) は CoreTests の3件で、同じ target の [ClauseTaggerRequestReplaySupport.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerRequestReplaySupport.swift) を使い、不変の request fixture 6 boundary cases・10 calls と、priority batch 3 targets・3 calls の計13 raw calls を、Core の pinned tokenizer と同期 decision logic で再生します。fake throwing closure は各 `inputID` の内容・順序・呼び出し数を照合し、想定外の呼び出しを throw します。すべての呼び出しがちょうど一度消費され、欠落・余分・未消費がないことと、fake throwing closure が記録済み snapshot の3 heads の raw 出力を返すことを確認します。唯一の request encoder を使って事前符号化した ownership・ranges・windows・junctions・candidates は完全一致で比較し、最終結果の keys・labels・counts・tokens・ranges・projected text の UTF-8 bytes も完全一致で比較します。probabilities と confidence は絶対誤差 `1e-3` 以下、raw head の shape・値と確率和（`1e-5` 以内）も検証します。filler の結果は `今日は損失関数の話をします。` と完全一致します。

```bash
swift test --package-path app/MacAmbientJev --filter 'DecisionProviderFactoryTests|ClauseTaggerDecisionLogic|ClauseTaggerEncodingTests|ClauseTaggerSpanProjectionTests'
```

[ClauseTaggerDecisionLogicTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerDecisionLogicTests.swift) の10件は不正 batch・keys・probabilities・malformed heads、primary tie と confidence、error propagation、および entry・windows 間・continuation 前・final return での cancellation と priority 処理を model-free で検証します。これらと上記 fixture replay、DecisionProviderFactoryTests の計20件は CoreTests で model・download・環境変数・OS gate を使わず、通常の `swift test` で実行対象です。

[ClauseTaggerParityFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/ClauseTaggerParityFixtureTests.swift) は shape を確認してから値を比較します。object key sets、array counts、IDs、ranges、candidate/label/token totals、projected text などは完全一致し、文字列は UTF-8 bytes で比較して Unicode の byte-distinct 表記を区別します。確率と confidence は各値の絶対誤差 `1e-3` 以下、head の shape は `boundary_probs` `[1,L,2]`、`span_probs` `[1,L,4]`、`priority_probs` `[1,2]`、各確率 row の和は `1e-5` 以内です。

変換 artifact の Python 受け入れ基準では、Python reference と Core ML MLProgram を dynamic `input_ids` int32 `[1,L]` で比較し、通常入力と randomized inputs の各整数長 `L=2...192` のすべてで `boundary_probs`、`span_probs`、`priority_probs` 各 head の最大絶対誤差を `1e-3` 以下とします。mask support は長さ `2, 64, 65, 66, 128, 192` で確認します。これは Python conversion acceptance sweep の基準であり、Swift の選定 corpus が全191長を網羅するという意味ではありません。tokenizer config は Metaspace の `prepend_scheme=never` と `split=false`、正確な UTF-8 byte fallback を要求し、この契約に違反する config は拒否します。

fixture の生成と check は次のとおりです。placeholder は上記と同じ要件の絶対 model directory に置き換えます。`MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY` が未設定または `1` 以外なら committed golden と比較するだけで、書き換えません。生成時だけ `MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY=1` を指定します。

```bash
MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY=1 RUN_CLAUSE_TAGGER_TESTS=1 CLAUSE_TAGGER_MODEL_DIRECTORY=/absolute/path/to/exported-model swift test --package-path app/MacAmbientJev --filter ClauseTaggerParityFixtureTests
RUN_CLAUSE_TAGGER_TESTS=1 CLAUSE_TAGGER_MODEL_DIRECTORY=/absolute/path/to/exported-model swift test --package-path app/MacAmbientJev --filter ClauseTaggerParityFixtureTests
```

Linux / Windows の `ONNXClauseTagger`（[ONNXClauseTaggerTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXClauseTaggerTests.swift)）は実モデルの parity テストを持ち、通常の portable CI で必ず実行します。`RUN_MODEL_TESTS` のような opt-in はありません。必須の環境変数 `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` に `python3 scripts/fetch_clause_tagger.py` が出力する絶対 directory を設定します（`scripts/verify_portable.sh`、`scripts/test-windows.ps1`、`.github/workflows/portable-core.yml` が設定します）。未設定・空・相対 path・存在しない directory はテストの失敗で、skip しません。

- `ClauseTaggerFixtures.json` の13件は literal な `input_ids` をそのまま推論し、`boundary_probs`、`span_probs`、`priority_probs` の head ごとに最大絶対誤差を `1e-3` 以下とします。head ごとの最大値は fixture ごとと全体でログに出ます。
- `ClauseTaggerRequestFixtures.json` の境界 6 case と優先度 batch は `ONNXClauseTagger` の public API へ実 request を渡し、response を Core ML 由来の保存値と比較します。key、candidate、label、token 数、除去範囲、投影後の文字列は完全一致、確率と confidence は `1e-3` 以下です。`まあ、あの、今日は損失関数の話をします。` は `今日は損失関数の話をします。` になります。
- model への不正入力（空、1 token、193 token、CLS・SEP 欠落、負・語彙外の ID）、最短2 token と最長192 token の推論、取り消し済み request、非正の thread 数（ロード前に失敗）、相対・存在しない directory のテストと、`DecisionProviderFactory` が一度だけロードして manifest の identity を返すテストも含みます。thread 数と directory のテストは model を使いません。

```bash
CLAUSE_TAGGER="$(python3 scripts/fetch_clause_tagger.py)"
MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY="$CLAUSE_TAGGER" swift test --package-path app/MacAmbientJev --filter 'ONNXClauseTagger|ClauseTaggerAssets'
```

Core ML の入力は dynamic `input_ids` int32 `[1,L]`（`2...192`）、出力は `boundary_probs` `[1,L,2]`、`span_probs` `[1,L,4]`、`priority_probs` `[1,2]` です。Core ML 変換器は scratch の外部ツールで、このリポジトリに変換 script はありません。export artifact は base model、trained weights、明示した output directory を使って生成し、この入出力契約を満たす必要があります。ポータブル ONNX の書き出しは次節の repository script で行います。変換実験の Python package version は PyTorch `2.14.1`、transformers `5.19`、coremltools `9.0` で、converter は unsupported PyTorch version warning を出します。Core ML Tools [9.0 release notes](https://github.com/apple/coremltools/releases/tag/9.0) には Torch `2.7` のサポートが記載されています。新しい Torch で変換が成功したことを公式サポートの根拠とは扱わず、artifact ごとに実際の installed version と warning を記録してください。

[DecisionProviderFactoryTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/DecisionProviderFactoryTests.swift) は全 platform の CoreTests にある model-free 7件で、fake providers を使い、環境変数・filesystem・モデルなしで実行します。成功・失敗時の single-flight と同時要求での identity/coordinator 共有、同じ failure と load の CancellationError の cache、完全な identity/provenance、identity の lookup/確認だけでは判定 request も usage も発生しないこと、synthetic token accounting、provider cancellation が attempt-only で cache を再利用することを検証します。実 token usage や実モデル推論を測るテストではありません。これらは単体テストであり、GUI 操作、マイク／システム音声の権限、画面表示の確認にはなりません。

### 合成イベントによる回帰検証とライブ滞留計測

```bash
swift test --package-path app/MacAmbientJev --filter 'catalogRejectsUnreadableEventLog|validatedEmptyVADCompletesWithoutSpeechInference|recordingPreservesCaptureAndReleaseFailures|coolingDrainsLiveBacklogWithLatestCheckpointAndStopReleasesState'
LIVE_ASR_REGISTRATION_MEASUREMENT=1 swift test --package-path app/MacAmbientJev --filter measureLiveRegistrationCost
LIVE_ASR_BACKLOG_MEASUREMENT=1 swift test --package-path app/MacAmbientJev --filter measureLatestCheckpointRetentionDuringThermalStall
MATERIALIZER_BENCHMARK=1 swift test --package-path app/MacAmbientJev --filter materializerTenThousandSegmentBenchmark
swift test --package-path app/MacAmbientJev --filter 'liveASR|liveRows|stoppingRecordingCancels'
swift test --package-path app/MacAmbientJev --filter 'appRecordingShowsLiveRowsWhileDecisionsWait|appRecordingShowsDecisionFactoryFailureReason|liveRowsShowAtOnce|nativeTakeover'
CLAUSE_INCREMENTAL_BENCHMARK=1 swift test --package-path app/MacAmbientJev --filter liveClauseIncrementalBenchmark
```

registration、backlog、materializer の計測 test は、それぞれ `LIVE_ASR_REGISTRATION_MEASUREMENT`、`LIVE_ASR_BACKLOG_MEASUREMENT`、`MATERIALIZER_BENCHMARK` が厳密に `1` の場合だけ有効です。環境変数が未設定または `1` 以外なら Swift Testing の `.enabled(if:)` が test を無効にします。portable CI は Swift 6.2 を使います。条件付き test の仕様は [Swift Testing の有効化と無効化](https://docs.swift.org/latest/documentation/testing/enablinganddisabling/)を参照してください。通常の `materializerHandlesTenThousandSegmentLog` は 10,000 件の count と最終本文だけを確認します。benchmark は materialization の経過時間を出力しますが、時間閾値は設けません。

correctness test は読み取れないイベントログ、検証済み VAD の空結果、録音障害と停止時の資源解放障害、冷却後のライブ認識再開の境界を合成イベントで検証する。計測 test は 5 秒ごとに一発話とした 10 分・1 時間・4 時間相当の合成イベントを使い、再登録の中央値時間と critical 時に保持する ASR バッチ・区間参照・checkpoint・chunk 一覧の項目数を出力する。計測 test の成功は性能合格を意味しない。時間はモデル推論を含まず、保持数は RSS ではない。実キャプチャ、GUI 起動、権限要求は行わない。

`measureLiveRegistrationCost` は debug 構成で、登録 setup を計測から除外し、各 120・720・2880 件の pending 履歴に対して同じ ID を 100 回再登録する標本を 7 個取り、一呼出しあたりの中央値を µs で出力します。登録 progress はセッション内の materialized 行と ID 数を使い、pending 履歴全体を再構築しません。判定目安は 4 時間相当の中央値 ≤ 50 µs かつ 10 分相当の ≤ 3 倍です。時間の単体テスト assertion は置きません。比率が timer noise で外れた場合は全 7 標本を報告し、同じ標本数で逐次に一度再計測します。認識済み行の更新 projection、モデル推論、アプリのキュー保持量はこの計測の対象外です。測定結果は [live registration 計測記録](records/2026-10-04-live-registration.md) を参照してください。

`measureLatestCheckpointRetentionDuringThermalStall` は portable な `LiveTranscriptionCoordinator` を直接動かし、fake executor、注入 sleep、critical 熱状態を使って、5 秒ごとに一発話とした 10 分・1 時間・4 時間相当を計測します。120・720・2880 発話で checkpoint の保持数はセッションあたり 1 件、保持 chunk 項目数は最新 checkpoint の 120・720・2880 件だけです。区間参照は全件保持します。AppState、filesystem、model は使わず、計測 harness は時間の assertion を置きません。`coolingDrainsLiveBacklogWithLatestCheckpointAndStopReleasesState` は実 `AppState.startRecording` / `stopRecording`、注入 VAD polling、合成の保存済み PCM、injected ASR を使い、critical 中の認識停止と最新 checkpoint の保持、冷却後の全区間を一度だけ順次認識すること、録音停止後のキュー・checkpoint 解放を確認します。portable な `criticalLiveDrainWaitsWithoutDequeueThenResumesFIFOUsingLatestCheckpoint` は、後から更新された最新 checkpoint が FIFO の各 batch に使われることを検証します。実モデル、マイク、GUI は使いません。

[LiveASRThermalQueueTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LiveASRThermalQueueTests.swift) は共有 [LivePollTestSupport.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LivePollTestSupport.swift) の手動進行する VAD poll gate と thermal-recheck gate を分け、thermal gate の停止を待ってから ASR 未実行・熱停止 status を確認し、冷却後は recheck を進めて drain 完了を待ちます。`ThermalMonitoring` は `@MainActor observeChanges` を必須とし、購読寿命を表す token を返します。`AppState` は初期化時に購読し、本番 composition の [MacAmbientJevApp.swift](../app/MacAmbientJev/Sources/MacAmbientJev/MacAmbientJevApp.swift) だけが `MacThermalMonitor` を渡します。`MacThermalMonitor` は token の寿命に合わせて host observer を設置・解除し、[TestThermalMonitor.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/TestThermalMonitor.swift) は合成変更を駆動します。熱状態の読み取りと再開判断は同じ注入 monitor を使います。`coolingResumesThermallyHeldFinalization` は直接 resume せず fair を通知し、coordinator の完了を待って durable な completed metadata を確認します。portable な [LiveTranscriptionCoordinatorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveTranscriptionCoordinatorTests.swift) の `criticalHeatSuspendsLiveRecognitionUntilCooled` も注入 sleep gate と drain 完了で同期します。

ライブ ASR regression は認識後の新規 pending 登録・重複 ID、ASR 完了・空本文・失敗の ordered snapshot、同一 run の保存済み節更新と active run 切替、登録・完了・失敗・終了イベントの保存障害、並行登録・終了を検証します。取得済み行配列は後の認識や節更新で変わりません。判定待機中も全行が即時表示されること、時間順、無効・初期化失敗・失敗した batch ごとの保留、空区間のテキスト列終端、ASR gap 後の未解決先頭を注入 provider で検証します。`LiveASRSession` の writer は必須の `SessionEventAppending` であり、並行登録 test は本番 `SessionWriter` を包む fake writer で最初の `segment.created` append を gate し、append 開始を待って二つ目を登録し、最初を解放して worker の完了を待ち、本番 test hook なしで durable event が一件であることを確認します。

[LiveClauseIncrementalTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveClauseIncrementalTests.swift) は通常の全履歴 materializer と増分更新の行・projection・保存 JSON を照合し、長い跨ぎ節、空区間、ASR gap、不正 batch の rollback、取得済み snapshot の不変性を検証します。[LiveClauseIncrementalBenchmark.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveClauseIncrementalBenchmark.swift) は一時音声と注入 ASR で実 `LiveASRSession.applyClauseEvents` を動かし、40・400・2500 区間で境界・節閉鎖・優先度を反映する時間を、テスト専用の全履歴再構築 actor と比較します。各規模で warmup 1 回と標本 20 回を使い、結果の同一性は計測区間外で照合します。通常 test では計測を無効とし、時間閾値を correctness の合否にしません。[測定記録](records/2026-10-09-clause-incremental.md) を参照してください。

[PriorityBatchPersistenceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/PriorityBatchPersistenceTests.swift) と [LiveContentPriorityGatingTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveContentPriorityGatingTests.swift) は注入 provider と一時イベントログで、81 節の確定・優先度再試行・ライブを検証します。失敗した batch をそれぞれ 40/40/1 件の保留として保存すること、境界判定の失敗がその区間だけを保留にして優先度判定を続けること、coordinator 取得中・判定待ち中の取り消しを扱います。LiveContentPriorityGatingTests の fixture は request・row・status の条件を continuation 通知で待ち、worker の終了後に `SessionWriter.readDurableLog(eventsURL:)` でwriter と同じ排他ロック下の durable snapshot を一度だけ読み、各 assertion と reader の再読込で同じ bytes を使います（取消しの基準 snapshot は fake provider の gate で worker を保持した状態で読みます）。全テストの `timeLimit` は hang guard のみで、意味上の条件や実行時間予算ではありません。各テストは worker の終了後に一時 root を削除します。[NativeSessionProcessorLiveTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/NativeSessionProcessorLiveTests.swift) の finalization takeover fixture は provider gate、transcript update 通知、保持した live worker の終了を待って late response を確認するため、経過時間に依存しません。意味上の coordinator tests も明示 gate を持つ fake effects と注入 sleep で同期し、性能予算を置きません。実行全体の上限は既存の portable CI job timeout（Linux 20 分、Windows 30 分）です。実モデルは使いません。

`appRecordingShowsLiveRowsWhileDecisionsWait` は実 `AppState.startRecording`、checkpoint の VAD polling、区間登録、ライブ ASR drain、判定 queue、画面用 projection を通します。capture・VAD・ASR・判定 provider は合成入力に置き換え、応答を止めている間も通常行が表示され、保存済み判定だけが反映されることを確認します。`appRecordingShowsDecisionFactoryFailureReason` は分類器生成時の合成エラーを使い、理由が状態表示に残り、通常行を表示して録音と ASR を継続することを確認します。実モデル、マイク、GUI は使いません。

ライブ ASR drain の完了は、独立して動く判定キューの完了を保証しません。AppState はライブ処理の sleep を必須引数で受け取り、本番は Task.sleep、[LiveDecisionRecordingTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LiveDecisionRecordingTests.swift) と [MicInputStatusTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/MicInputStatusTests.swift) は手動で進める poll gate を渡します。ライブ判定の regression は起動時の保存整理 task を await し、VAD poll を一回進めて区間登録を確認した後、fake tagger の request 通知と画面用 rows・エラー状態の publisher 通知を待ちます。保存済み LOW 判定の反映も rows の通知で確認します。

`NativeSessionProcessor` → `FinalTranscriptPipeline` の pacing sleep も必須注入です。本番 composition は Task.sleep を渡し、[FluidFinalTranscriptIntegrationTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/FluidFinalTranscriptIntegrationTests.swift) の `finalTranscriptPipelineForwardsPacingAndPauseToASR` は fake sleep recorder で正確な `.seconds(2)` と pause 判定の順序を確認します。sleep closure は実時間待機せず記録するため、この pacing test は時間経過に依存しません。

[MicInputStatusTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/MicInputStatusTests.swift) の fake VAD は指定した batch 数の到達を continuation で通知します。各 poll の次の sleep gate まで待つことで、AppState が音声レベルを取り込んだ後に状態を検証します。入力音量の書込みは fake volume の通知、poll 中の VAD 障害は状態表示の通知を待ち、開始時の VAD 障害は `startRecording` の完了で確認します。これらの待機は中断時に条件名を含むエラーを投げ、`timeLimit` は hang guard としてのみ使います。実時間の待機間隔や期限は同期条件にしません。

[IdleReleaseTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/IdleReleaseTests.swift) は startup maintenance、processing coordinator の drain、model preparation/release task の完了を待ってから検証します。[RecordingFailureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/RecordingFailureTests.swift) は failure-stop task を await し、同じ session の重複 failure が完了前後で stop と finalization を二重実行しないことを確認します。両テストの `timeLimit` は hang guard のみで、経過時間は同期条件ではありません。

保存済みセッション catalog は active ASR run のイベントログ・payload を読み取り専用で検証し、欠損・不正・不完全な末尾を持つログを破損として表示する。合成 catalog regression は malformed / missing / directory の各ケースで非 exportable 状態、再処理可否、manifest と metadata の不変性を確認する。

Linux 音声正規化は入力と出力が同一ファイル（シンボリックリンク解決後を含む）なら、出力先を変更する前に拒否し、原音声を保持する。`tools/linux-audio/tests/test_audio.py` は実 ffmpeg を使う同一パス・symlink の境界と、正常変換・変換失敗時の出力処理を検証する。

`validatedEmptyVADCompletesWithoutSpeechInference` は 1 秒の合成無音を 2 回確定し、検証済み VAD の空結果が話者分離の準備失敗・推論失敗に依存しないことを確認する。ASR 準備も呼ばれず、原音声の bytes、読み取れる空 transcript、3 段階の provenance と成功 0 件完了、`complete` metadata、終端の無発話表示、復旧対象外の分類を検証する。VAD 自体の失敗と発話ありの推論失敗は `failed` のまま公開済み run を保持する。これは orchestration の検証であり、実 FluidAudio モデルの無音成功・クラッシュを測った結果ではない。

[CanonicalAudioIngressTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/CanonicalAudioIngressTests.swift) は device-rate の合成 tone を irregular / 512-frame block に分けて実 drain とディスクへ通す。48 kHz・44.1 kHz の累積 duration、block 境界の single-stream reference との sample 差、997 / 3101 Hz の波形誤差、16 kHz identity、4-channel import 平均、fractional-ratio の gap・overlap・overflow・stop tail、部分 append failure 後の retry と並行 finish / snapshot を検証する。fixture を保存前に preconvert しない。EOS 後の全体長は正確な長さの floor か ceil で、gap は公開範囲へ切り詰める。

`captureStartReservesStoredPCMNotDeviceRate` は injected tap の実 capture start を 48 kHz・44.1 kHz・16 kHz で実行し、601,600,000 bytes の受理と 601,599,999 bytes の拒否を確認する。hardware・permission prompt は使わない。[CanonicalEngineInputTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/CanonicalEngineInputTests.swift) は既存 CAF の実 samples を複数の bounded random range で読み、音声コピーを作らない source path と Qwen の非 canonical 入力拒否を検証する。同じファイルの `finalizationEnginesReceiveCanonicalAudioForRecordedAndImportedSessions` は、48 kHz の録音を irregular block で実 drain に通した session と 44.1 kHz stereo の import を実 `NativeSessionProcessor` で確定し、injected VAD・話者分離・ASR が受け取る形式（16 kHz・mono・float32、CAF 長、ASR sample 数）と original の bytes 不変を検証する。

### 保存音声のテスト

[SessionAudioStorageFormatTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/SessionAudioStorageFormatTests.swift) は `storage.json` の 4 つの形を bytes で固定する（[保存形式](storage.md)の例はこの出力）。[RecordingAudioCompactorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingAudioCompactorTests.swift) は 16-bit FLAC への変換を、4,096 フレーム前後を含む長さ、クリップ・端点・非有限値、破損・欠落・余剰フレームの FLAC、全 `Boundary` での中断と再実行の収束で確認する。[LaunchMaintenanceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/LaunchMaintenanceTests.swift) は起動時の保存整理が全セッションを収束させ、失敗したセッションをフォルダー名付きで返すことを確認する。[SessionStorageFinalizationTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/SessionStorageFinalizationTests.swift) は全結果での一時音声の削除、変換・削除の失敗報告、一時停止中の削除失敗、FLAC からの再処理（再符号化なし）、整理後の古い音声ソースを使わないことを、音声から結果を導く注入エンジンで確認する。[SessionExportTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionExportTests.swift) は portable な PipelineTests で、全 OS で FLAC の無変換コピー、読み込み音声の原本コピー、PCM 状態の拒否、破損 FLAC での失敗と既存書き出しの保持、置き換えの失敗時の復元と復元失敗・作業用フォルダー削除失敗・置き換え前フォルダー削除失敗の報告、中断された置き換えの回復、書き出しが内部音声を変更しないことを確認する。マイク・システム音声の権限や GUI の起動時整理の表示は、これらでは確認できない。

共通 Core の codec tests は [RecordingFLACEncoderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/RecordingFLACEncoderTests.swift)、[FLACTimelineReaderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACTimelineReaderTests.swift)、[FLACFrameDecoderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACFrameDecoderTests.swift)、[FLACMD5Tests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACMD5Tests.swift)、[FLACBitstreamTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACBitstreamTests.swift) にあります。reader の round-trip は noise・silence・clipped alternating signal・sine の 4 種と 1、4,095、4,096、4,097、12,305 frame の 5 長さを組み合わせた 20 ケースで、任意範囲読み取り（block 境界をまたぐ範囲を含む）も比較します。encoder の無音テストは全 sample の完全一致 round-trip とコンパクトな出力を確認し、単一 sample では VERBATIM と同サイズ以下、複数 sample では VERBATIM より小さいことを検証します。CRC、metadata・frame の切り詰め、長さ・MD5 の不一致、末尾 bytes を拒否し、handcrafted frame で FIXED 次数 0〜4、LPC、Rice2、escape coding、wasted bits を検証します。埋め込みの 16-sample frame は FIXED 次数 2・partition order 3 とし、先頭 partition の残差数が 0 となる境界も検証します。MD5 は RFC 1321 の既知 vector と signed 16-bit little-endian sample を使った vector で確認します。

`flac` CLI は codec tests の参照 oracle です。ローカル環境（VM を含む）では任意で、テストは `PATH` 上の実行可能ファイルだけを検索します。実行可能ファイルが見つからない場合は Swift Testing の `.enabled(if:)` gate により該当する interop tests を無効にします（[無効化可能なテスト](https://docs.swift.org/latest/documentation/testing/enablinganddisabling/)）。portable CI では `flac` を必須にします。Linux CI は Ubuntu noble の distro package を install し、Windows CI は公式 1.5.0 zip を SHA-256 `53f1500f0d6e7c61379d7fee50d4a9f7f504c650009506d9ba015530d76c0dde` で検証して展開し、Win64 を `PATH` に加えます。両 CI job は `flac --version` を確認し、実行可能ファイルがない場合または version check が失敗した場合は job が失敗します。公式情報は [FLAC 1.5.0 release](https://github.com/xiph/flac/releases/tag/1.5.0) と [release API](https://api.github.com/repos/xiph/flac/releases/tags/1.5.0) を参照してください。参照エンコーダーを使う reader テストは、`-0` による FIXED、`-8` による LPC、全 sample が 8 の倍数となる wasted-bits 入力、`--lax -b 65535 -l 32` で符号化した入力の 65,535 sample 境界をまたぐ範囲読み取りの4ケースを検証します。参照 CLI の仕様は [flac 1.5.0 manual](https://raw.githubusercontent.com/xiph/flac/1.5.0/man/flac.md) を参照してください。[RecordingAudioCompactorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingAudioCompactorTests.swift) は portable な PipelineTests で、全 OS で compactor を検証します。一方、session reader・symlink 境界の integration tests（[SessionAudioReadersTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionAudioReadersTests.swift)、[SessionAudioSymlinkTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionAudioSymlinkTests.swift)）は macOS 専用の AppleSupportTests で、Core codec を通して検証します。

[CanonicalCAFReaderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/CanonicalCAFReaderTests.swift) は全 OS で `CanonicalCAFReader` を検証します。Mac AVFoundation の期待 sample を固定した不変のコミット済み [Mac CAF fixture](../app/MacAmbientJev/Tests/MacAmbientJevCAFFixtures/Resources/canonical-mac-16k.caf) は 4,800 frame・23,296 bytes で、`desc` と `data` の間に `free` chunk による 4,016 bytes の padding を持ちます。この fixture を全体・先頭・末尾・空・block 境界をまたぐ範囲で期待 sample と bit 単位で比較します。手組みの CAF bytes では、`free` / `info` / 未知 chunk の読み飛ばしと data 後の chunk の無視、非有限値をそのまま返すこと（reader は sample を検証せず、有限性の検査は読み出し側の責務）、空の data、範囲外の読み取り、正規 file の全 byte 長での切り詰め、CAF でない file・未対応 version・非0 flags、desc が先頭でない・欠落・data が欠落・desc の重複・desc のサイズ違い、不正な chunk size・int64 を超える chunk size・data size -1（未確定）・宣言より短い data・編集カウントや4 bytes 単位に満たない data、サンプルレート・format・flags・channel 数・bit 数・packet 構成が正規と異なる desc、セッション外の file を拒否することを確認します。期待値は f32le sample bytes です。Core の Foundation-only writer は canonical 16 kHz mono float32LE を、`desc` と `data` だけの最小 68-byte header（`free` なし）で出力し、同じ sample では 19,268 bytes になります。`CanonicalCAFReader` は両方の chunk 配置を受け付け、Mac AVFoundation も両方を読み取って期待 sample と sample-bit 単位で一致します。

[ProcessingTimelineAudioExporterTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ProcessingTimelineAudioExporterTests.swift) は 13 test functions・合計17 cases（通常 test 11件＋3-case の parameterized test 2関数）で Core writer を検証します。bounded な連続 block 読み出し、正確な header・payload・sample bits（有限値の極値、signed zero、subnormal を含む）、空 CAF、offset 付き short/long read error、nonfinite 値、reader failure、mutation 前の tooManyFrames 判定、malformed/truncated PCM、atomic replacement、既存 destination の保持、一時 file cleanup、session 境界を扱います。コミット済み fixture との比較は framesPerBuffer 1・1,000・48,000 の3ケースで行い、fixture と Core 出力の sample bits を照合します。

Mac 専用の [CanonicalCAFFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/CanonicalCAFFixtureTests.swift) は不変 fixture と Core writer の異なる CAF layout の両方を `CanonicalCAFReader` と AVFoundation で読み、期待 sample との sample-bit parity を検証します。fixture の bytes と Core writer 出力の byte equality は要求しません。Mac 専用の [CanonicalCAFReaderParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/CanonicalCAFReaderParityTests.swift) は `CanonicalCAFReader` と Mac の `CanonicalCAFAudioSource` が、fixture と 128,000 frame の file の任意範囲・8,192 frame の読み出し block 境界・最終の部分範囲で同じ sample を返すことを確認します。

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

### 話者分離の parity fixtures

[test-only の fixture reader](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/DiarizationParityFixture.swift) と [portable fixture tests](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/DiarizationParityFixtureTests.swift) は、全 OS で参照データの読み込み・形式・構造を検査します。7つの parity fixtures は [parameters.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/parameters.json)、[reconstruction.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/reconstruction.json)、[ahc.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/ahc.json)、[assignment.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/assignment.json)、[vbx.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/vbx.json)、[plda-rho.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/plda-rho.json)、[frontend.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/frontend.json) です。[plda-parameters.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/plda-parameters.json) と [xvector-transform.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/xvector-transform.json) は別個の、PLDA parity が使うライセンス付き JSON tensor assets で、parity fixtures には数えません。fixture reader の allowlist はこの9 resource と下記の6つの fbank fixtures の計15 resource で、各 1 MiB 以下、合計 8 MiB 以下であることを検証します。portable tests は fixture の encoding / structure、[Community1ProfileTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1ProfileTests.swift) による profile parameter parity、および各 portable algorithm の parity を検証します。Linux・Windows の通常 test に FluidAudio や diarization model は不要です。

portable な実装は [Community1ReconstructionTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1ReconstructionTests.swift) の reconstruction、[Community1Centroids.swift](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1Centroids.swift) の centroid 計算、[Community1Assignment.swift](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1Assignment.swift) の constrained assignment、[Community1VBx.swift](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1VBx.swift) の VBx、および [Community1AHC.swift](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1AHC.swift) の AHC です。AHC は Foundation-only の portable port で、参照元は pinned FluidAudio 0.15.8 の [FastClusterWrapper.cpp](https://github.com/FluidInference/FluidAudio/blob/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FastClusterWrapper/FastClusterWrapper.cpp) と [fastcluster_internal.hpp](https://github.com/FluidInference/FluidAudio/blob/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FastClusterWrapper/fastcluster_internal.hpp) です。benchmark もこの Swift port を計測し、FluidAudio のコードを直接 benchmark するものではありません。

AHC は有限な Double 入力を行ごとに L2 正規化し、zero vector は zero のまま保持します。AHC 内では embedding L2 floor を適用しません。merge centroid は source の重み付き式 `(pi*mi + pj*mj)/(mi+mj)` で計算します。indexed heap と昇順の active-node scan を使い、`N×N` 距離行列や全 pair の sort は作りません。作業領域は `O(ND)+O(N)` です。heap と scan の tie behavior は pinned `generic_linkage_vector_alternative` に対応しますが、正規化の scalar Double 演算は vDSP reduction と一般に bitwise 一致するとは主張しません。

返す linkage は既存 node ID を含む全 merge tree です。height を並べ替えたり threshold で merge を早期終了したりせず、root-first cut で訪れた subtree のみ `height <= 0.6` を判定します。そのため centroid inversion では descendant の merge height が threshold を超えていても root subtree を受理します。cut traversal は left、right の順に stack へ push し、LIFO で処理した後、入力中の最初の出現順に cluster label を振り直します。cancellation は entry、入力・初期化 row、merge 境界で確認し、malformed shape、非有限値、overflow は明示的な error にします。資源 meter、budget、fallback はありません。

[Community1AHCTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1AHCTests.swift) は全36 fixture の labels を完全一致で照合し、linkage structure、analytic tie sequence、invalid input / shape / overflow、cancellation を検証します。これらは内部 cluster labels であり、公開 speaker labels（Speaker 1–7、OTHER、UNKNOWN）は変更しません。これは fixture 上の AHC labels parity であり、end-to-end 話者分離 parity を主張しません。ほかの portable algorithm の単体テストは centroid と assignment が [Community1CentroidsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1CentroidsTests.swift) と [Community1AssignmentTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1AssignmentTests.swift)、VBx が [Community1VBxTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1VBxTests.swift)、fixture parity が [Community1AssignmentParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1AssignmentParityTests.swift) と [Community1VBxParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1VBxParityTests.swift) で検証します。assignment API は constrained-stage の primitive であり、end-to-end manager port ではありません。

7つの parity fixture の metadata は FluidAudio version・revision、入力構成、比較規則を記録します。fixture 内の Float32 / Float64 tensor は dtype と shape を明示し、IEEE 754 の little-endian bit pattern を base64 に格納します。portable tests は fixture ごとの比較規則を使い、assignment の source index と centroid Double bit pattern の厳密比較は維持し、VBx の gamma・pi・ELBO は最大絶対誤差で比較します。PLDA の `expectedRho` は各値の絶対誤差 `1e-4` 以内で比較し、それ以外の fixture fields は generator ごとの規則で検証します。設定値などの numeric metadata は JSON number のままです。一般の有限 float tensor reader は非有限値を受け付けません。`assignment.json` の非有限 score は、有限値 0 の tensor 座標に対する一意な sparse patch（index と `nan` / `positiveInfinity` / `negativeInfinity` の kind）で表し、reader は復元前に patch を検証します。不正な dtype・shape・base64、サイズ超過も拒否します。

Mac の最初の5つの model-free golden generator は通常の debug `MacAmbientJevRuntimeTests` に置き、FluidAudio を `@testable import` して直接呼びます: [DiarizationParityFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/DiarizationParityFixtureTests.swift)、[DiarizationReconstructionParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/DiarizationReconstructionParityTests.swift)、[DiarizationAHCParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/DiarizationAHCParityTests.swift)、[DiarizationAssignmentParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/DiarizationAssignmentParityTests.swift)、[DiarizationVBxParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/DiarizationVBxParityTests.swift)。Model-backed generator は [DiarizationPLDAParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/DiarizationPLDAParityTests.swift) と [DiarizationFrontendParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/DiarizationFrontendParityTests.swift) です。Mac の package は FluidAudio `0.15.8` / revision `87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc` に直接依存し、generator は `Package.resolved` の pin も検証します。assignment oracle は pinned [HungarianAssignment.swift](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/Diarizer/HungarianAssignment.swift) を含む FluidAudio 実装を呼び、VBx oracle は pinned [VBxClustering.swift](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/Diarizer/Offline/Clustering/VBxClustering.swift) を呼びます。最初の5 generator は実モデル asset を読み込まず推論せず、fixture check と generation にモデルを必要としません。これらは FluidAudio の実装を呼ぶ Mac 専用の test oracle であり、portable algorithm の実装ではありません。

- `parameters.json` は FluidAudio の OfflineDiarizerConfig.default を出発点に、embedding.minSegmentDurationSeconds だけを `0.3` に変更してから validate した有効設定を記録します。portable profile test は numeric / fixed fields を各 field で完全一致比較します。Boolean・rounding・fixed-choice・dither selectors は profile constants として公開する調整値ではなく、algorithm choices は固定です。
- `reconstruction.json` は 13 ケースで overlap、`-2` の unassigned local speaker、複数 local speaker の同一 global cluster、nearest-even rounding の 0.5 / 1.5 / 2.5、0.1 秒 gap の Float32 境界変換の下側・上側、0.3 秒 minimum、exclusive trim による quality と drop、final padded window の EOF overrun を照合します。2.5 のケースは triple-local binary internal input を使い、segmentation graph の出力ではありません。oracle の `buildSegments` は `sampleCount` を受け取らず EOF clamp もしないため、overrun は raw output に残り、`sampleCount` は fixture metadata のみです。golden 生成前の guard は、異なる speaker の開始時刻が同じ Float32 値になる入力を拒否します。FluidAudio 内の Dictionary / Set 順序に依存して hash-dependent になるケースは fixture に含めず、FluidAudio の hash order を変更・修正する約束ではありません。
- `ahc.json` は36ケースで、4つの基本ケース（separated groups、angular chain、threshold pairs、centroid inversion）に、singleton、two-merge、two-no-merge、all-merge、no-merge、tied-neighbors、tied-duplicates、realistic-256d（48×256、8 groups × 6 rows）と、24個の angular / elevation 3D stress case を加えます。24 case は SplitMix64 seed `0xC011000000000010` を共有し、angle 係数 `0.4`、elevation 係数 `0.12` を使います。stress cases には少なくとも2 clusterを持つ異なる label array が4種類あります。fixture は 168,989 bytes です。expected labels は pinned FluidAudio 0.15.8 revision `87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc` の実装から得た値であり、portable AHC の出力を oracle として作ったものではありません。centroid-inversion witness は leaf distances `0.62` / `0.63` / `0.64`、最初の merge `0.62 > 0.6`、root distance `0.5542111510967639 < 0.6` で、FluidAudio の root-first labels `[0,0,0]` と monotone-cut の比較 labels `[0,1,2]` を記録します。fixture は linkage 値を export しません。
- `assignment.json` は score assignment の257ケース（1〜3行、K=1〜40、seed 固定の擬似乱数による連続値・tie、完全一致する行・列、sub-micro 量子化、exact half と nextDown / nextUp、非有限値）と、rows=1〜3・K=1〜4 の12 shape にわたる binary matrix 全5,050個の exhaustive case を含みます。後者の oracle は FluidAudio の assignment です。score は直接丸めず、`max-score` に定数 scale `1e6` を掛けた cost を nearest-away-from-zero で丸めます。さらに centroid の9ケースは gamma 加重 original vector、`pi > 1e-7` の active speaker を source index 昇順で選ぶ規則、centroid を正規化しないこと、順序を保った fused daxpy accumulation、cutoff の隣接値・cancellation・zero vector と次元1・2・3・8・256を照合します。21 embedding/slot ケースは実際の manager cosine / constrained path を通り、finite / nonfinite の active candidate は manager cosine でスコアリングされ、nonfinite は finite より下位に順位付けされます。inactive slot と padded dummy column にマッチした row は `-2` になり、nonfinite の active row は割り当てられたままの場合があります。`K > 1` のときだけ default manager が constrained branch を有効にするため、embedding oracle は `K >= 2` を使い、`K=1` rectangular case は pinned [ConstrainedClusterAssignment](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/Diarizer/Offline/Clustering/ConstrainedClusterAssignment.swift) / Hungarian stage を直接検証します。portable tests は全 assignment・source index と centroid の Double bit pattern を完全一致比較します。
- `vbx.json` は12ケースです。`synthetic-k2`〜`synthetic-k8` は `N=3K`、`D_rho=128`、`D_embedding=256` で、決定的な synthetic PLDA-like rho / embedding と正の減衰 `phi[d]=0.05+4*exp(-d/24)` を使います。`scalar-x3` / `x4` / `x4.5` / `x5` は収束 stress、`collapsed-pi` は最小 pi が約 `2.48e-24` になるケースです。入力と保存スペクトルはすべて合成値で、実際の PLDA transform はこの parity の対象外です。早期収束と20 iteration完了の両方を含みます。

#### AHC の合成 benchmark

[Community1AHCBenchmark.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1AHCBenchmark.swift) は `MAC_AMBIENT_JEV_RUN_AHC_BENCHMARK=1` の場合だけ有効です。有効化には Release build と、default のない `MAC_AMBIENT_JEV_AHC_BENCHMARK_N`（正の整数で160の倍数）が必須です。条件付き test は Swift Testing の[有効化と無効化](https://docs.swift.org/latest/documentation/testing/enablinganddisabling/)を使い、10分 `timeLimit` は hang guard とします。入力は D=256、8つの合成 center に uniform jitter 0.025 を加え、各 speaker を20 rowsずつ巡回させます。SplitMix64 seed は `0xA8C0160002560008` です。Swift の単調時計で input generation と AHC clustering を別々に計り、結果が想定した8 partition の全 labels と一致することを検証します。これは portable Swift AHC の合成 benchmark であり、FluidAudio の実コードや実音声・full engine の benchmark ではありません。

外側の `/usr/bin/time -l` で得る process peak RSS は、生成した input、AHC の scratch / result、test harness、load 済み libraries を含み、allocator-only の値ではありません。測定は Release build の後、生成済み test bundle を filter して単独実行します。完全な build・helper command と測定記録は [P3.3 AHC 合成 benchmark 計測記録](records/p33-ahc-benchmark.md) を参照してください。この現状説明では実測値を報告しません。

VBx portable contract は、pinned [FluidAudio 0.15.8 VBxClustering.swift](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/Diarizer/Offline/Clustering/VBxClustering.swift) に対応します。各 iteration は `N×K` gamma を保持せず sufficient statistics を streaming し、scratch は `O(N+K*D_rho)` です。返す posterior は最後の E-step parameters とその入力 prior を保持し、返す `pi` は最後の M-step 後の prior です。centroid pass は各 row の responsibility を replay し、gamma-weighted original embedding の和と融合して累積します。追加 scratch は `O(K*D_embedding+K+D_rho)`、出力 source cluster は `pi > 1e-7` を満たす index の昇順です。profile は one-hot gamma の softmax smoothing `7`、`Fa=0.07`、`Fb=0.8`、最大20 iteration、`abs(ΔELBO) < 1e-4`、phi floor `1e-12`、inverse-precision denominator floor `1e-12`、log-prior floor `1e-8` です。各 iteration で cancellation を確認し、不正入力・非有限値・overflow は明示的なエラーになります。壊れた状態からの recovery はしません。

portable VBx parity は全 fixture の gamma / pi / ELBO を最大絶対誤差 `1e-6` 以内、iteration count を完全一致で照合します。streamed centroid は fixture gamma を既存の `Community1Centroids.compute(trainingEmbeddings:gamma:pi:)` に渡した結果と `1e-9` 以内で比較します。assignment parity は Double bit pattern を厳密比較します。

[Community1PLDA.swift](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1PLDA.swift) は JSON tensor assets を caller から受け取ったバイト列として読み込む portable path です。private decoder は Foundation の [JSONDecoder](https://developer.apple.com/documentation/Foundation/JSONDecoder) を使い、asset を取得せず hash manifest も読みません。malformed / missing JSON、tensor 名・shape・dtype・layout の不一致、不正または非 canonical base64、bytes 数の不一致、非有限値、特異な行列、psi が0以下の場合は明示的なエラーになります。

PLDA setup は Double の Cholesky factorization / solves で W=(trᵀtr)⁻¹ と B=(trᵀdiag(1/psi)tr)⁻¹ を作り、一般化固有値問題を解きます。決定的 cyclic Jacobi は最大64 sweeps、relative off-diagonal residual 1e-12 以下を収束条件とし、未収束はエラーです。固有値は降順に並べ、固有ベクトル行は最大絶対値座標（同率なら最小 index）で符号を正規化し、manifest [community1_diarization_models.json](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Resources/community1_diarization_models.json) の128個の座標符号を適用します。この符号は実 Core ML graph から導いた値で、manifest が唯一の保持者です。rho は Float32 graph boundary を保ち、両 L2 normalization の squared-norm floor は 1e-12（norm floor 1e-6）、scale は sqrt(256) / sqrt(128)、最後に projection と sqrt(setupEigenvalues) を乗じて、Float32 出力を Double に widen します。VBx の phi は JSON の psi を Double に widen した値で、setup eigenvalues ではありません。

[Community1PLDATests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1PLDATests.swift) は committed signed-rho fixture と synthetic identity assets を検証し、座標符号は manifest から読みます。[plda-rho.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/plda-rho.json) は27入力を3群で保持します: 6 normalized deterministic sin/cos vectors、8 first-floor inputs（実 graph の `mean1` と小さな perturbations）、13 edge inputs（zero と、軸 [0, 1, 63, 127, 128, 255] 上の signed unit vectors）。first-floor 群の期待値は実 Core ML graph から生成しています。second normalization floor の入力は実モデル golden ではなく、synthetic identity-asset tests が両方の floor を検証します。比較は manifest の符号向きを使う各座標の signed absolute error `<= 1e-4` で、sign-invariant 比較ではありません。fixture 自体は符号を保持しません。

[Runtime の PLDA oracle](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/DiarizationPLDAParityTests.swift) は `@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))` のときに実行します（[Swift Testing の有効化と無効化](https://developer.apple.com/documentation/Testing/EnablingAndDisabling)）。有効時は `MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY` に絶対パスの既存ディレクトリを指定し、その直下に PldaRho.mlmodelc、`plda-parameters.json`、`xvector-transform.json` を置きます。欠落、相対パス、存在しないパス、ディレクトリでないパスは環境変数名を含む明確な error になります。既定値・自動 download・fallback はありません。oracle は実際の PldaRho.mlmodelc を [Core ML MLModel API](https://developer.apple.com/documentation/coreml/mlmodel) の `.cpuOnly` でロードし、pinned FluidAudio 0.15.8 の PLDATransform.transform を呼びます。dummy graph は使いません。両 JSON の SHA-256 は manifest の pin と照合し、graph の射影行から導いた128個の座標符号が manifest の `coordinateSigns` と完全に一致することを検査します（不一致なら失敗し、manifest を更新するのは符号を再導出して確認した人です）。

[Community1AssetsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1AssetsTests.swift) は全 OS で、同梱 manifest の4ファイルの pin（revision、byte 数、SHA-256）と、テスト資源の2つの JSON がその pin と一致することを検査します。model directory の検証は、小さな stand-in の ONNX と本物の JSON で作った一時 directory と注入した manifest で行い、欠落・サイズ違い・同サイズで内容が違う hash 違い・通常ファイルの代わりの directory・存在しない directory・空白と非 ASCII を含む path・不正な manifest（role の欠落と重複、符号の長さと値、未知の source、path を含む名前、大文字の hash、サイズ0）を確認します。実モデルは不要です。[FileSHA256Tests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FileSHA256Tests.swift) は標準ベクトルと padding 境界、chunk 境界をまたぐ file digest（chunk 1〜1 MiB）、1 chunk を超えるファイルと Data digest の一致、存在しないファイルのエラーを検査します。取得 script の自己 test は `python3 -B scripts/test_fetch_community1_diarization.py` で、取得元と pin は [windows.md](windows.md#community-1-話者分離モデルの取得) にあります。

`plda-parameters.json` と `xvector-transform.json` は、[FluidInference の pinned source revision](https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/df2625ac79a7ac6b65ad868fee6d80f320da4232) から変更せずコピーした JSON tensor assets です。JSON の source fields は、それぞれ upstream の *plda/plda.npz* と *plda/xvec_transform.npz* を示します。Community-1 の [upstream model](https://huggingface.co/pyannote/speaker-diarization-community-1) の attribution は pyannote、WeSpeaker、BUT Speech@FIT、Fluid Inference です。これらの asset は [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) で提供されます。

[Community1Frontend.swift](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1Frontend.swift) は Foundation-only の frontend です。[Community1FrontendTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1FrontendTests.swift) は固定の入力検査を行い、4つの test を持つ [Community1FrontendParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1FrontendParityTests.swift) は [frontend.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/frontend.json) と照合します。parity は離散出力、mask の Float32 bit pattern、window scheduling / padding、pooling geometry を検証します。`PowersetScores` は有限 Float32 の 589×7 値を要求し、各 frame の strict `>` argmax は同率時に最初の class を選びます。powerset class と speaker bitmask の対応（bit 0〜2 は local speaker slot 0〜2）は次のとおりです。

| powerset class | speaker bitmask |
| --- | --- |
| 0 | `0b000` (`0`) |
| 1 | `0b001` (`1`) |
| 2 | `0b010` (`2`) |
| 3 | `0b100` (`4`) |
| 4 | `0b011` (`3`) |
| 5 | `0b101` (`5`) |
| 6 | `0b110` (`6`) |

`Community1WindowPlan` は constant-space で音声全体を保持せず、160,000 sample window を32,000 sample stepで、開始位置が EOF より前にある分だけ計画します。reader から取得した有効 prefix を検証し、不足する末尾だけを zero padding します。plan と Mac adapter の clamp は [DiarizationFinalWindowPadding.swift](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/DiarizationFinalWindowPadding.swift) の共有 final-window start 計算を使います。空音声の plan は0 windowsで、no-speech の判定は plan ではなく engine の責務です。window 境界で cancellation を確認し、形状・有限値・reader の返却 count の不正は明示的なエラーになります。

Mask selection は speaker ごとに base weight sum が正であることを確認し、各 frame で `> 1e-3` の speaker が複数なら overlap として全 speaker のその frame を除外します。clean mask の受理条件は Float32 sum が `Float(589) * 0.2` 以上であることです。0.3秒 minimum からの frame gate は `max(1, ceil(0.3 / (10 / 589))) = 18` frames ですが、118 clean binary frames を要する20% gateの方が支配的です。original mask の別経路はなく、出力 bounds は mask の最初と最後の active frame を inclusive に示します。[Community1ProfileTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1ProfileTests.swift) は fractional mask にも適用される Float32 clean-weight threshold relation を検証します。fractional mask を実際に入力した選択結果は [Community1FrontendTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1FrontendTests.swift) と [Community1FrontendParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1FrontendParityTests.swift) で検証します。

`ActivityMask` と `PoolingMask` は別型で、raw activity mask から pooling mask を直接初期化できません。pooling は `j=0..<125` について `Double(j) * 588 / 124` の align-corners 座標を線形 Float32 係数で補間し、結果を整数 index `j * 589 / 125` に scatter します。125 index は互いに異なり、最後は584で、それ以外の位置は0です。これは FluidAudio の WeightInterpolation による589→589 identity や125-point half-pixel 補間とは別の幾何です。parity fixture は zero、ones、ramp、alternating、scattered、endpoints の6入力で式どおりの Float32 幾何を厳密比較しますが、Core ML FP16 graph の数値出力との bitwise 一致は主張しません。frontend.json は Kaldi fbank を含まず、fbank は下記の専用 fixtures が検証します。[frontend.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/frontend.json) は341,785 bytesです。decode は1ケースで7 powerset classes、21 pairwise ties、all-equal tie を含み、window は8 sample counts（1、31,999、32,000、32,001、159,999、160,000、160,001、192,000）、mask は16ケースです。mask cases は0〜3 active slots、overlap threshold の nextDown / exact / nextUp、17・18-frame rejection、117・118 clean frames、20% ratio の below / exact / above を含みます。parity は6 pooling / interpolation inputs も検証します。

[Runtime frontend oracle](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/DiarizationFrontendParityTests.swift) は PLDA oracle と同じ `RUN_MODEL_TESTS=1` gate で実行します。`MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY` に絶対パスの既存ディレクトリを指定し、直下に Segmentation.mlmodelc、Embedding.mlmodelc、FBank.mlmodelc、PldaRho.mlmodelc の4 bundle と `plda-parameters.json` を置きます。各 bundle の `model.mil` と weights/weight.bin、および JSON asset の hash を fixture に記録します。oracle は毎回 UUID 所有の temporary `speaker-diarization` cache layout、symlink、revision marker を構成し、public OfflineDiarizerModels.load の間 ModelHub.offlineMode を有効にして download・purge・recovery 経路を止め、自身の検証済み staging root だけを除去します。source model directory は変更しません。

oracle は test-only model subclass から決定的 segmentation logits を返し、実際の OfflineSegmentationProcessor に class 選択・postprocessing・window scheduling を実行させます。mask ケースでは public SegmentationOutput を渡して実際の OfflineEmbeddingExtractor を通し、real FBank・Embedding・PLDA models をロードして、戻った TimedEmbedding の slot、mask、inclusive bounds を fixture に採ります。mask selector の再実装は使いません。model の embedding・rho・log-probability の数値出力は保存せず、保存する fields は決定的な入力、source mask metadata / bounds / math、および source asset hashes です。そのため frontend generator は fixture 全体の canonical JSON bytes を厳密一致で確認できます。全16 mask cases は最後の scheduled window（offset 2.0 s）に32001-sample音声（実音声1 sample＋159999 zeros padding）を与え、EOFでselector maskが切り詰められないことを確認し、実際のframe weightsはTimedEmbedding経由で観測します。この oracle は Core ML の segmentation / embedding 数値 parity や end-to-end diarization parity を主張しません。

[Community1Fbank.swift](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1Fbank.swift) は FluidAudio が使う FBank.mlmodelc の op 順（×32768、400 sample frame、frame ごとの DC 除去、先頭 sample を複製した preemphasis 0.97、symmetric Hamming、512点へ zero padding、power spectrum、80 bin mel bank、`log(max(energy + 1e-6, 1e-6))`、998 frame の bin ごとの mean 正規化）を Foundation だけで再現します。framing と windowing は Float32、radix-2 FFT は Double、power と正規化は Float32 で、twiddle・window・mel bank は初回利用時に一度だけ作る不変テーブルです。入力は `WindowAudio`（160,000 sample）で、出力は 998×80 の frame-major 値を持つ `Community1FbankFeatures` だけです。定数は `Community1Profile` に出典付きで置きます。

fbank の fixtures は [fbank-graph.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/fbank-graph.json)（graph の `_fbank_window` と `_fbank_mel_weight`）と、ケースごとの [fbank-speech.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/fbank-speech.json)、[fbank-clipping.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/fbank-clipping.json)、[fbank-silence.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/fbank-silence.json)、[fbank-short.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/fbank-short.json)、[fbank-dc-offset.json](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Resources/fbank-dc-offset.json) の6ファイルで、各ファイルは1 MiB 未満です。入力は固定 seed の LCG と回転 oscillator だけで生成する 10 秒の合成 window（multi-tone と noise の speech 風信号、±1 に張り付く clipping、digital silence で log floor を通すもの、3 秒の実音声風信号を zero padding した short、DC offset）で、fixture には seed ではなく生成式を `construction` に、期待値として Core ML FBank.mlmodelc を CPU only で実行した 998×80 の Float32 grid をそのまま保存します。生成式は [Runtime の generator](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/DiarizationFbankParityTests.swift) と [portable test](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1FbankTests.swift) に同じ内容で置き、`construction` 文字列の一致と誤差判定が両者のずれを検出します。

[Community1FbankTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1FbankTests.swift) は全 OS で、5ケースそれぞれについて 998×80 の全 grid の最大絶対誤差が 3e-3 以下であることを確認します（測定値は silence 1.2e-4、short 3.2e-4、dc-offset 5.6e-4、speech 5.9e-4、clipping 8.0e-4）。加えて、window と mel bank が graph の重みと一致すること（window 1e-6、mel bank 2e-5 以内）、FFT が Double の素朴 DFT と一致すること、Hamming window が左右対称であること、mel bank の端が 20 Hz〜8 kHz の内側に収まり Nyquist bin の重みが0であること、bin ごとの平均が0になることを検査します。debug build で5ケース並列の fbank 全体が約2秒です。

Mac の fbank generator（`fbankMatchesCoreML`）は他の model-backed generator と同じ `RUN_MODEL_TESTS=1` gate と `MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY` を使い、直下の FBank.mlmodelc だけを読みます。環境変数が無い場合は明確なエラーで失敗し、既定 path はありません。check モードは新しく実行した Core ML 出力を committed grid と最大絶対誤差 1e-3 以下で照合し、byte 一致は要求しません。Core ML の float 出力は環境間で変わるためです。

VBx の保存形状はソース上で `O(N+K*D_rho)` で、`N×K` gamma を作りません。単体 probe のプロセス全体の peak RSS は [P3.3 VBx メモリ確認記録](records/p33-vbx-memory.md) にあります。

assignment の Hungarian primitive は最大3 real rows で使い、memory は `O(rows*K + K)`、time は `O(rows²*max(rows,K))` で、`K×K` scratch を作りません。5,000-column test と exhaustive objective tests で長い rectangular input と最適性を検証します。source が後から追加する dummy zero rows は、unmatched `v=0`、feasible reduced cost `>= 0`、strict predecessor update により既存 real match を変えません。invalid shape、nonfinite training data、active speaker なし、zero posterior mass、unsafe arithmetic は明確に失敗し、recovery は行いません。nonfinite candidate embedding は scoring のため保持して finite candidate より下に順位付けしますが、finite training vector としては使いません。

以下はリポジトリルートから実行します。`MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY=1` の場合だけ test harness が canonical JSON を source fixture へ書き込みます。それ以外の値では generator output を committed fixture と照合します。この WRITE gate は test harness 専用で runtime は参照しません。最初の5 generator は model-free で常時 fixture を照合し、PLDA と frontend の model-backed generator は `RUN_MODEL_TESTS=1` のときに実行します。PLDA check は `cases[*].expectedRho` 以外の全フィールドを完全一致させ、rho は dtype と値数を一致させて各値を設計契約の絶対誤差 `1e-4` 以内で比較します。frontend check は model asset hashes を含む canonical JSON 全体を完全一致させます。zsh では各環境変数 assignment に実値を直接書き、`MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY` は実在する絶対パスに置き換えます。model-backed command 後に `frontendMatchesFluidAudio` または PLDA test が skip ではなく実行されたことを test output で確認します。

```bash
# Ordinary portable fixtures; do not enable model-backed generators
env -u RUN_MODEL_TESTS swift test --package-path app/MacAmbientJev --jobs 4 --filter Diarization
# Focused portable frontend tests in both suites
swift test --package-path app/MacAmbientJev --jobs 4 --filter 'Community1FrontendTests|Community1FrontendParityTests'
# Mac: generate and check the first five model-free parity fixtures
env -u RUN_MODEL_TESTS MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY=1 swift test --package-path app/MacAmbientJev --jobs 4 --filter 'MacAmbientJevRuntimeTests.DiarizationParityFixtureTests'
env -u RUN_MODEL_TESTS swift test --package-path app/MacAmbientJev --jobs 4 --filter 'MacAmbientJevRuntimeTests.DiarizationParityFixtureTests|MacAmbientJevDiarizationTests'
# Check host load before each model-backed run; execute one at a time
uptime
# Generate PLDA rho fixture with the real Core ML graph
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY=/absolute/path/to/coreml MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY=1 swift test --package-path app/MacAmbientJev --jobs 4 --filter pldaRhoMatchesCoreML
uptime
# Check canonical PLDA fixture without writing
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY=/absolute/path/to/coreml swift test --package-path app/MacAmbientJev --jobs 4 --filter pldaRhoMatchesCoreML
uptime
# Generate frontend fixture through the real diarization frontend path
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY=/absolute/path/to/coreml MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY=1 swift test --package-path app/MacAmbientJev --jobs 4 --filter frontendMatchesFluidAudio
uptime
# Check canonical frontend fixture without writing
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY=/absolute/path/to/coreml swift test --package-path app/MacAmbientJev --jobs 4 --filter frontendMatchesFluidAudio
# Generate fbank fixtures with the real Core ML FBank graph
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY=/absolute/path/to/coreml MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY=1 swift test --package-path app/MacAmbientJev --jobs 4 --filter fbankMatchesCoreML
uptime
# Check fbank fixtures against a fresh Core ML run without writing
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY=/absolute/path/to/coreml swift test --package-path app/MacAmbientJev --jobs 4 --filter fbankMatchesCoreML
# Focused assignment oracle generation and canonical-byte check
MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY=1 swift test --package-path app/MacAmbientJev --jobs 4 --filter assignmentMatchesFluidAudio
swift test --package-path app/MacAmbientJev --jobs 4 --filter assignmentMatchesFluidAudio
# Focused VBx oracle generation and canonical-byte check
MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY=1 swift test --package-path app/MacAmbientJev --jobs 4 --filter vbxMatchesFluidAudio
swift test --package-path app/MacAmbientJev --jobs 4 --filter vbxMatchesFluidAudio
# Portable reconstruction, centroid, assignment, PLDA, and VBx tests
swift test --package-path app/MacAmbientJev --jobs 4 --filter 'Community1ReconstructionTests|Community1CentroidsTests|Community1AssignmentTests|Community1AssignmentParityTests|Community1PLDATests|Community1VBxTests|Community1VBxParityTests'
```

fixture 内の reconstruction ID（例: `S1`）は oracle の speaker ID であり、公開表示ラベルは別契約です。[SpeakerDisplayMapper.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerDisplayMapper.swift) は変更しておらず、公開ラベルは Speaker 1–7、OTHER、UNKNOWN のままです。

#### Community-1 kernel の全体動作

[Community1Diarizer.swift](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1Diarizer.swift) の `diarize(sampleCount:readFrames:inference:)` は、window ごとに segmentation、powerset decode、mask 選択、fbank、embedding を実行し、結果を run 単位の観測表 [Community1Observations.swift](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1Observations.swift) に1回ずつ追加します。観測表は各 window の589個の speaker bitmask と3 slot の結果（未抽出、非有限、有限 embedding）を時系列順に持ち、有限 embedding と rho は row-major の flat table に `(window, slot)` と1対1で置きます。学習集合は有限 row の全体で、第2のコピーを持ちません。

embedding の2操作は `Community1Inference` が持ちます。実装が返す256次元 vector は未正規化でよく、kernel が profile の floor 1e-4 で L2 正規化してから PLDA rho を計算します。`SpeakerMask` は cleaned activity（segmentation 解像度）と pooling 位置に sample 済みの `PoolingMask` を両方持ち、内部で補間する graph（Core ML の Embedding.mlmodelc）は前者、補間しない graph（ONNX tail）は後者を使います。非有限 vector の slot は学習に使わず、assignment では最下位に順位付けして残します。window 内の slot 位置は assignment まで保持します。

終了条件は次のとおりです。サンプル数0、またはどの window のどの slot も embedding を抽出しなかった場合は `noSpeechDetected`、抽出はあるが有限 embedding が1つもない場合は `noFiniteTrainingEmbeddings` で失敗します。embedding の個数や次元が要求と合わない場合は `invalidModelOutput`、reader が要求と異なるサンプル数を返す場合は `FrontendError` で失敗し、いずれも代替経路を持ちません。有限 embedding が2個以上のとき AHC を実行し、1個のときは全 row を cluster 0 とします。centroid が1個のときは FluidAudio と同じく制約付き assignment を使わず、抽出済みの全 slot を cluster 0 に割り当てます。cluster 数は pi が active の centroid 数で、cluster ID は centroid の並び順です。

キャンセルは window 境界、AHC の merge、VBx の iteration、centroid の row、reconstruction の flush 境界で確認し、途中の spans は返しません。`diarize` は呼び出しごとに観測表を作り、呼び出し間で状態を共有しないため、同じ入力と同じ inference の2回の実行は同一の spans を返します。spans は FluidAudio の Float 秒を `SpeakerSpanMapper` で frame に丸め、最終 window の padding 内に収まる終端だけを音声長へ切り詰め、開始・終端が音声外の span は `invalidSpeakerSpan` で失敗します。

[Community1DiarizerTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1DiarizerTests.swift) は全 OS で、決定的な fake inference（サンプル振幅で2つの声を区別し、声ごとの local slot を window の偶奇で入れ替える）を使い、slot の入れ替えを越えた話者の同一性、2回の実行と別入力を挟んだ実行の同一性、短い入力の padding と終端 clamp、無音・非有限・構造不一致の失敗、window 境界と最終 window 後のキャンセル、観測表の対応関係を検証します。

Mac では [Community1DiarizerCoreMLParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/Community1DiarizerCoreMLParityTests.swift) が portable kernel と FluidAudio の OfflineDiarizerManager を、同じ Core ML model（公開 loader を offline mode で使い、同じ MLModel を共有）と同じサンプルで比較します。test 専用の Core ML inference は portable fbank の出力を Embedding.mlmodelc へ mask ごとに1回ずつ渡します。入力は MacAmbientJevPortableRuntimeTests の Resources にある `qwen3_asr_voicevox_long.wav`（16 kHz mono PCM16 を /32768 で Float にする。test は `#filePath` から辿り、無ければ失敗する）と、test 実行時に `/usr/bin/say`（Kyoko と Rocko の日本語 voice）で作る2話者の clip です。後者は一時 directory に交互の4発話を合成し、`/usr/bin/afconvert` で 16 kHz mono PCM16 にして連結し、終了後に削除します。voice が無ければ `say` が失敗してそのまま test が失敗し、代わりの voice は使いません。Apple の合成音声は再配布の可否を確認していないため repository には置きません。VOICEVOX の clip は1話者だったため、2話者の clip を足しています。比較は、話者数の一致、最適なラベル対応の後の時間分割の一致（不一致の長さ）、span 数と各境界の差が1 frame（10/589 秒、272 sample）以内であることを確認します。

```bash
swift test --package-path app/MacAmbientJev --jobs 4 --filter 'Community1DiarizerTests|Community1ObservationTableTests'
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY=/absolute/path/to/coreml swift test --package-path app/MacAmbientJev --jobs 4 --filter portableKernelMatchesFluidAudio
```

#### ONNX 話者分離の stage テスト

Linux / Windows の `ONNXCommunity1DiarizationEngine`（[ONNXCommunity1DiarizationEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/ONNXCommunity1DiarizationEngine.swift)）と ONNX 推論の [Community1ONNXInference.swift](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Community1ONNXInference.swift) は、Core ML の stage 出力と FluidAudio の spans を保存した fixture [diarization_onnx_stages.json](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/diarization_onnx_stages.json)（1 MiB 以下、Float32 は little-endian の base64）と比較します。

Mac の generator は `onnxStageFixtureMatchesCoreML`（[Community1ONNXStageFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/Community1ONNXStageFixtureTests.swift)）です。他の model-backed generator と同じ `RUN_MODEL_TESTS=1` と必須の `MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY` で動き、既定値はありません。`MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY=1` のときだけ fixture を書き、それ以外は Core ML と FluidAudio を再実行して committed fixture と許容誤差で照合します（バイト一致では比べません）。fixture に入れるのは、VOICEVOX の長い clip（`qwen3_asr_voicevox_long.wav`、295,424 sample）の window 0・2・4・6 の Segmentation 出力（589×7 の log-probability）、全 0 の無音 window の Segmentation 出力、kernel が選んだ各 mask の cleaned activity とその Core ML Embedding 出力、散在 mask（`(7 * frame + 3) % 10 < 3` の frame が 1、window 0 の fbank）の Embedding 出力、clip 全体に対する FluidAudio の spans です。mask の選択は FluidAudio と完全一致を検証済みの kernel の `selectMasks` で行います。照合の許容は Segmentation が最大絶対誤差 `1e-3` かつ argmax 一致、Embedding が cosine `0.999` 以上、spans が数・話者 ID の一致と各境界 272 sample 以内です。

```bash
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY=1 MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY=/absolute/path/to/coreml swift test --package-path app/MacAmbientJev --jobs 4 --filter onnxStageFixtureMatchesCoreML
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY=/absolute/path/to/coreml swift test --package-path app/MacAmbientJev --jobs 4 --filter onnxStageFixtureMatchesCoreML
```

Linux / Windows の model テスト（[Community1ONNXStageTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Community1ONNXStageTests.swift)）は `RUN_MODEL_TESTS=1` と、`scripts/fetch_community1_diarization.py` が出力した directory を指す必須の `MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY` で動きます。環境変数に既定値はなく、未設定・相対 path・存在しない directory は skip ではなく失敗です。比較と許容誤差は次のとおりです。

| 対象 | 許容 | 測定値（ONNX Runtime 1.31.0、Linux aarch64 / Windows 11 ARM64） |
| --- | --- | --- |
| 音声 window の Segmentation（log-probability） | 最大絶対誤差 `5e-4`、argmax 一致 100 % | 最大 `1.2e-4` / `3.3e-4`、argmax 100 % |
| 無音 window の Segmentation | argmax 一致 100 %、log-probability の最大絶対誤差 `8.0`、確率の最大絶対誤差 `5e-3` | log-probability `2.45` / `5.49`、確率 `3.1e-4` / `3.0e-3`、argmax 100 % |
| 選ばれた各 mask の Embedding | Core ML との cosine `0.995` 以上 | `0.99991` 以上 |
| 散在 mask の Embedding | cosine `0.995` 以上 | `0.99993` |
| end-to-end の spans | 話者数・span 数・話者 ID の一致、各境界 272 sample（1 frame）以内 | FluidAudio の spans と完全一致 |

無音 window は全クラスにほぼ質量がなく、log-probability では2つの runtime が大きく食い違うため、確率での許容を併記します。散在 mask の回帰では、mask を `SpeakerMask.pooling` で pooling 位置に sample して渡すことが前提です（生の 589 frame mask を渡すと、probe では cosine が 0.89 前後まで下がった）。multimask の行の対応は、散在 mask と window mask を2個・3個で並べた呼び出しの各行が、単独呼び出しの参照と一致し、順序を入れ替えても行が追従することで検査します。mask 数が0または4以上のとき `embed` は `invalidModelOutput` で失敗します。

end-to-end のテストは VOICEVOX の clip から正規 CAF を作り、engine を `prepare`（2回）、`diarize`（2回）、`unload`（2回）の順に使い、2回の `diarize` が同じ spans を返すこと、`unload` 後の `diarize` が `notPrepared` で失敗することも確認します。

model を使わない単体テスト（[ONNXCommunity1DiarizationEngineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXCommunity1DiarizationEngineTests.swift)）は環境変数なしで実行できます。prepare の2回呼び出しで load が1回だけであること、unload の2回呼び出しと再 prepare、prepare 前・unload 後の `diarize` の失敗、canonical CAF の bounded read、非 canonical sample rate と CAF でないファイルの拒否、5本の同時 `diarize` が重ならず直列に実行されること、`unload` が実行中の `diarize` を待つこと、存在しない・破損した model directory での `prepare` の失敗（fetch command を含む）、provenance が pin の revision と4ファイルの SHA-256 を持つことを検証します。

```bash
swift test --package-path app/MacAmbientJev --jobs 4 --filter ONNXCommunity1DiarizationEngine
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY="$MODELS" swift test --package-path app/MacAmbientJev --jobs 4 --filter Community1ONNX
```

#### F・B除去範囲と表示 projection

[ClauseTaggerSpanProjectionTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerSpanProjectionTests.swift) は `span_probs` の4列を O=0、F=1、D=2、B=3 と解釈し、各 token の argmax と同率時に最小 index を選ぶことを検証する。O/F、F/D、O/B、D/B の tie と4 label 全ての tie を含み、token 範囲と生成される F・B除去範囲は原文の end-exclusive UTF-16 offset で表す。UTF-8 byte fallback の複数 token が一つの Unicode scalar を表す場合、それぞれがその scalar 全体の UTF-16 範囲を指し、UTF-8 byte offset にはしない（BOM は `[0,1)`、emoji の byte token は各々 `[1,3)`）。token 範囲を順に適用し、重なる位置は後の token の label で上書きする。純粋な B と隣接する F+B は除去し、連続する除去文字は一つの範囲にまとめる。kana・decomposed character・emoji を構成する scalar が F/B 混在でも Character 全体を除去し、O/D が含まれる Character はどちらの scalar 順でも全体を残す。テストは surrogate pair、decomposed scalar、token overlap、無効な shape・確率範囲・range も扱う。

[TranscriptTextProjectionTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/TranscriptTextProjectionTests.swift) は明示された F・B除去範囲だけを削除し、接続した句読点も削除する一方、無関係な空白・改行、開き括弧・引用符を保ち、本文を削除位置をまたいで連結し、retainedRuns/displayRanges は写像用の別々の run として保持することを確認する。入力範囲は重なり・隣接・未整列を許さず、句読点拡張後の除去範囲だけを結合する。F・B除去範囲が空なら `まあ、あの、今日は損失関数の話をします。` のようなフィラーらしい文字列も変えない。UTF-16 範囲が surrogate pair／Unicode Character の途中を割る場合や、範囲が空・重複・隣接・未整列・範囲外の場合は拒否する。

`materializerAppliesFillerRemovalOnlyAfterSavedAssessment` は ASR 原文 `えー、資料を配ります。` が assessment 前と boundary pending（request failed）時にはそのまま表示され、保存済み assessment の F 範囲 `[0,2)` を適用した後だけ表示本文が `資料を配ります。` となることを検証する。保存後も `text` と ASR event は原文のまま。tagger 初期化失敗も raw 表示と pending を保ち request は0件（`failedTaggerLoadKeepsLiveRowsUnsplitAndPendingWithoutRequests`）。[LiveClauseIncrementalTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveClauseIncrementalTests.swift) は保存済み F・B除去範囲の到着で対象行の projection cache が更新され、古い raw projection が残らないこと、増分結果が全履歴 materializer・row projection・JSON と一致することを照合する。不正な event batch は assembly・clause・priority の状態と公開 row を部分変更せず transaction rollback し、その後の正しい batch でだけ更新する。

`boundaryAssessmentRequiresAndCarriesFillerRanges` は assessment JSON の必須 `filler_ranges` 欠落を decode error にし、encode/decode と run carry で範囲が保持されること、F・B除去範囲が異なれば decision は同一でないことを検証する。event reader／coordinator は原文外の範囲を拒否する。`savedTranscriptLoaderKeepsRawFillerTextForPresentationAndExport` は保存済み ASR event を `SavedTranscriptLoader` で読み、assessment 保存前後も原文と event bytes が変わらず、保存済み F 範囲の後だけ表示 projection と実際の `transcript.txt` が `今日は公開鍵暗号を説明します。` になることを確認する。GUI の選択コピーとアクセシビリティ読み上げは別途、画面上で検証する。

節優先度の回帰検証は注入 `DecisionProvider` で決定的に行い、モデル品質の正解とは分ける。厳密な `> 0.5` と LOW 採用 `≥ 0.90`（直前の Double を含む）、候補の raw UTF-16 座標、候補なし・無句読点・連続句読点と末尾除外、跨ぎ節と終端、再利用対象を除いた後の40/41節の batch 境界を対象とする。候補が空の終端境界も boundary request として送信・計数し、input token を持つ。boundary と priority の request 数は独立して数え、この境界テスト単独の priority request は0件だが、全処理では非空の閉じた節を通常どおり priority request で分類する。最初の回答が有効でも後続の回答欠落・余分・不正な優先度判定で全batchを拒否し、一requestの失敗として数える。確定処理では、各 run の保存済み F・B除去範囲をそれぞれの原文に適用して得た部分を区切りなしで連結し、その UTF-8 bytes が完全一致する場合に限り durable な priority 判定を再利用する。比較では trim・句読点・Unicode byte差を同一視せず、未公開 retry の回答も使わない。carry するのは priority 判定だけであり、live の F・B除去範囲を final にコピーしない。schema・参照・coverage の破損、保留再試行と公開 snapshot、request 単位の token 計数、takeover 時の保存済み LOW の除去と判定待ち行の本文表示を確認する。LOW＋続き待ちは閉じた LOW 部分だけを除き、待機本文を保持する。画面 projection・txt・`display_text` は混在 PRIMARY/LOW（LOW を除いた本文）、全 LOW（行なし）、待機・保留・再試行待ち（本文を表示）、F・B除去後に本文が空になる実 slice で本文と行集合を確認する。文言・内部配線・コピーした設定値を固定するテストは根拠にしない。

実ファイルの受入smokeは一時harnessで `NativeSessionProcessor` → `SessionWriter` → metadata・readerの再読込 → `SavedSessionCatalog` → `SessionExporter` を通す。注入ASRの `えー、週末の設計を確認します。そうですね。` からPRIMARY/LOW混在を作り、rawの保持、LOWを除いた表示本文と実txt出力、全LOW行の非表示を確認する。注入した判定失敗ではpriority保留の本文を表示し、priorityだけのtargeted retryで公開boundaryを維持・非対象pendingをcarryする。boundaryの失敗では無分割行を保持し、boundary retryで両runとpendingを一括公開する。判定結果の前の再読込では直前の公開snapshotのままであることを確認する。2つのlive区間から1つのfinal区間への再利用は、各 run 自身の保存済み F・B除去範囲を適用した本文を区切りなしで連結し、UTF-8 bytes が完全一致する場合に priority だけを carry し、live の F・B除去範囲を final にコピーしないことを確認する。event appendとmetadata公開をそれぞれ実ファイルで失敗させ、ローカルのdurable本文・本文表示・3段公開を保持し、未公開の任意段を採用しないことを確認する。注入値はモデル精度の証拠ではない。harnessと一時セッションは受入後に削除する。

ASR gap の smoke は実ファイルに非空本文・ASR 欠落・成功した空 ASR・後続本文を保存し、`DecisionEnrichmentCoordinator` → metadata 公開 → reader/materializer の再読込を通す。前半本文を未解決のまま残し、空 ASR より後の本文だけを一回の優先度判定で分類し、保存 snapshot と再読込が一致することを確認する。空 ASR の後に新たな gap がある場合に先頭を推測しないことは回帰テストで扱う。

ライブ状態表示の実ファイル smoke は、注入 ASR で2区間を保存し、判定 coordinator の生成で初期化エラーを投げる。`LiveASRSession` と `LiveContentPrioritySession` の実装を通して、ASR 原文と通常表示を維持し、両区間の durable 保留理由と最後の状態表示に同じ失敗原因が残り、境界・優先度の判定呼出しが0であることを確認する。App の状態への反映は回帰テストで扱い、実 GUI の検証とは分ける。

### 録音しない受入と実画面での確認

授業など録音できない環境では、マイク・システム音声を開始せず、システム音量や出力装置にも触れない。既存ファイルのCLI処理とディスクだけの注入 smoke を行う。CLI の隔離 root で `--keep-session` の実処理を完了した後、JSON の `text` と参照先 ASR event の raw、`display_text`、`source`、`clause_state`、空 slice を照合する。CLI は発話文判定が無効なので、3つの local active run があっても判定 request は0件。認識済み source ごとに boundary pending があり、priority pending は空で、`text` と `display_text` は raw と一致する。終端行を含め F・B除去範囲の評価・除去は行わない。これは判定無効による0件であり、実モデルの終端境界は候補なしでも request を送信する。inspect → resume の再書き出しで event bytes と metadata が変わらないことも確認する。CLI の出力を F・B除去の証拠にはしない。

bundleは `scripts/run_app.sh` でbuildして起動する。プロセスの生存だけでは画面の合格にしない。GUI操作の権限がない場合は、設定・表示・exportボタンの確認を未観察として報告する。録音可能な時の手動受入では次を確認する。

- 「モデルを確認」で同梱モデルの ID と revision が表示されること、録音元・書き出し先、マイク／システム音声の実権限。
- 14秒超の実ASR原文をイベントで確認し、第一行の「発話文の続き待ち」、後続行の可視性、跨ぎpartsと確率を照合。
- PRIMARY＋LOWでLOW本文が消えること、全LOW行が消えること、LOW＋待機／保留の本文表示、選択copy/paste・accessibilityがLOWを除いた表示本文と一致すること、行単位の時刻popover・話者見出し。
- 録音停止後のASR drain・finishInputとfinal takeover、late結果不採用、実live/final本文が完全一致する場合だけのcarryと判定削減。
- priority障害で保存済みboundaryを維持し、ローカル公開が続くこと。
- 設定の保留再試行ボタン、二種targetの判定、atomic metadata切替、診断のrequest・token・pending内訳。
- 保存済み録音の再選択とGUI「書き出す」の実txt再読込、時刻・話者・改行処理、F・B除去後に本文が残る全行とLOWの保持、イベントraw不変。GUI exportにJSONは含まれない。

`MacAmbientJevEvaluateSession`, `MacAmbientJevEvaluateASR`, and `MacAmbientJevEvaluateDiarization` consume explicit artifact files only; none locate or create saved sessions, so these artifact-only modes do not require `--sessions-root`. Every mode of the capture, file-processing, and live-latency CLIs requires an explicit root that rejects protected app data/cache roots, their ancestors/descendants, and symlink aliases.

```bash
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateSession
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateASR
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateDiarization
bash scripts/verify_portable.sh
```

`verify_portable.sh` は `scripts/check_portable_core.py` の default portable roots と test import check を使い、SwiftPM manifest を評価してから unfiltered build / test を実行します。検査対象 roots と禁止 import / platform guard の正本は [checker](../scripts/check_portable_core.py) です。これは import 境界の検査であり、Linux 上で macOS runtime が実行できることを意味しません。

## 話者分離 DER の計測

Mac の FluidAudio と Linux / Windows の `ONNXCommunity1DiarizationEngine` を、同一の canonical CAF バイト列に対して比較します。比較には標準 DER（`MacAmbientJevEvaluateDiarization` の `standard`）と raw 話者数だけを使います。表示用に畳んだ `collapsed` は、公開ラベルの仮説を持たないため採点しません。

| 道具 | 対象 OS | 役割 |
| --- | --- | --- |
| [`prepare_canonical_caf.py`](../scripts/prepare_canonical_caf.py) | 全 OS | 16 kHz mono 16-bit PCM の WAV を、`CanonicalCAFReader` と Mac の `CanonicalCAFAudioSource` が読む 16 kHz mono Float32 CAF（値は `sample / 32768`）に変換し、出力先が存在すれば失敗する。パス、サンプル数、CAF の SHA-256 を JSON で表示する |
| `MacAmbientJevDiarizeFileOracle` | macOS | 本番と同じ `FluidOfflineDiarizationEngine`（FluidAudio の既定 config、最小 0.3 秒、アプリの span 変換）で実行する |
| `MacAmbientJevDiarizeFile` | Linux / Windows | `ONNXCommunity1DiarizationEngine` で実行する |
| [`compare_diarization_runs.py`](../scripts/compare_diarization_runs.py) | 全 OS | 2 つの run を採点する。`--runs` を使うと同じ engine の複数回実行の全組み合わせを採点し、self-disagreement を出す |

両 CLI は canonical CAF だけを受け取り、VAD や ASR は使いません。オプションはそれぞれ 1 回ずつ必須で、`--help` だけが単独で使えます。

```text
MacAmbientJevDiarizeFile --audio <canonical.caf> --model-directory <dir> --threads <n> --output <run.json>
MacAmbientJevDiarizeFileOracle --audio <canonical.caf> --coreml-directory <dir> --output <run.json>
```

Linux / Windows 側のモデル directory は fetcher が表示する directory を渡します。Mac 側は FluidAudio の Core ML diarizer モデル（Segmentation、Embedding、FBank、PldaRho の各 mlmodelc と `plda-parameters.json`、`xvector-transform.json`）を直接含む directory を渡します。`--output` は存在しないファイルでなければならず、一時ファイルに書いてから移動するため既存ファイルを置き換えません。不正な引数、存在しない入力、非 canonical な CAF、モデルの欠落・破損は 0 以外の終了コードとメッセージで失敗します。

### 手順

```bash
# 1. シナリオ WAV（generate_scenario が <output_root>/<scenario_id>/audio.wav を作る）を canonical CAF にする
python3 scripts/prepare_canonical_caf.py --wav "$SCENARIO/audio.wav" --output "$WORK/speakers-4.caf"

# 2. Mac: 同じ CAF で oracle を 3 回実行する
swift run --package-path app/MacAmbientJev -c release MacAmbientJevDiarizeFileOracle \
  --audio "$WORK/speakers-4.caf" --coreml-directory "$COREML" --output "$WORK/mac-1.json"

# 3. Linux / Windows: 同じ CAF を使う
swift run --package-path app/MacAmbientJev -c release MacAmbientJevDiarizeFile \
  --audio "$WORK/speakers-4.caf" --model-directory "$MODELS" --threads 2 --output "$WORK/portable.json"

# 4. 採点する
python3 scripts/compare_diarization_runs.py --reference-run "$WORK/mac-1.json" \
  --hypothesis-run "$WORK/portable.json" --min-clean-speech-ms 500 --output "$WORK/parity.json"
python3 scripts/compare_diarization_runs.py --runs "$WORK/mac-1.json" "$WORK/mac-2.json" "$WORK/mac-3.json" \
  --min-clean-speech-ms 500 --output "$WORK/mac-self.json"
```

`--min-clean-speech-ms` は計測者が指定する値で、既定値はありません。比較 script は評価器を `swift run` で呼ぶため、Swift toolchain が必要です。2 つの run の音声 SHA-256 またはサンプル数が違う場合は失敗します。出力ファイルも既存ファイルを置き換えません。

### VOICEVOX シナリオの生成と実測

[`generate_voicevox_diarization_scenarios.py`](../tools/linux-audio/generate_voicevox_diarization_scenarios.py) は、起動済みの VOICEVOX engine から `voicevox-ja-core-v1.json` の `diarization_scenarios` を生成する。`--base-url`、`--manifest`、`--output-root`、`--scenario`（複数指定可）はすべて必須で、既定値はない。出力は `<output-root>/<scenario_id>/audio.wav` と `scenario.json` で、`audio.wav` を `prepare_canonical_caf.py` に渡す。

2026-10-22 の実測（2 / 4 / 7 / 8 / 10 話者、Mac 3 回の self-disagreement、Mac 対 Linux / Windows の DER と raw 話者数、実行時間とピーク RSS、1 時間 run）は [p33-diarization-der-2026-10-22.md](records/p33-diarization-der-2026-10-22.md) にある。

### run ファイルの形式

`schema_version: 1`。`audio`（`sha256`、`sample_count`、`sample_rate`）、`provenance`（engine 自身が報告する `engine`、`model`、`version`、`configuration`）、`raw_spans`（`speaker_id`、`start_frame`、`end_frame`、`confidence`。表示用の畳み込み前の raw cluster ID とサンプル位置）、`raw_speaker_count`、`prepare_seconds`（モデル読み込み）、`wall_time_seconds`（diarize 1 回）、`peak_rss_bytes`（プロセス全体のピーク。macOS は `getrusage`、Linux は `getrusage` の KiB 換算、Windows は process memory counters のピーク working set）を持ちます。`wall_time_seconds` はモデルの読み込みを含みません。

比較では frame を 16 で割った整数 ms（半分は偶数側へ丸める）に変換して評価器へ渡します。話者数は変換前の raw span から数えます。出力は `audio`、両 provenance、`reference_speaker_count`、`hypothesis_speaker_count`、`standard`（DER と内訳）です。ミリ秒に変換して長さ 0 になる span はエラーです。

CLI の単体テストは [DiarizationMeasurementTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevDiarizationMeasurementTests/DiarizationMeasurementTests.swift) にあり、引数の検査、run の形式、音声 identity、不正 span の拒否、既存出力を置き換えないことを、モデルなしで全 OS で検査します。Python 側は `python3 -B scripts/test_compare_diarization_runs.py` と `python3 -B scripts/test_prepare_canonical_caf.py` です。`MacAmbientJevDiarizeFile` は ONNX Runtime を使うため macOS では build されず、`MacAmbientJevDiarizeFileOracle` は FluidAudio を使うため Linux / Windows では build されません。

## ファイル入力 CLI

`MacAmbientJevProcessRecording` は全 OS で使えるファイル処理 CLI です。マイクや GUI を使わず、音声を import して VAD・話者分離・ASR を含む full-session finalization を実行し、session の inspect / resume にも対応します。発話文判定は既定で無効です。`--with-decisions` を指定した場合だけ、Mac の Core ML または Linux / Windows の ONNX provider で境界・優先度を判定します。

以下は **Mac の実行例**です。macOS は `--threads` を受け付けないため指定しません。Portable の正確な Linux / Windows コマンドと model 設定は [Linux の ProcessRecording 使用方法](linux.md#セッション全体のファイル処理-cli) と [Windows の ProcessRecording 使用方法](windows.md#セッション全体のファイル処理-cli) を参照してください。

```bash
# macOS: --threads は指定しない
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --sessions-root "$SESSIONS_ROOT" "$AUDIO_FILE" "$SEGMENTS_OUTPUT"
```

出力先を省略すると音声と同じディレクトリに `segments.json` を作ります。入力と出力が symlink 解決後に同一となる場合は拒否します。`--keep-session` を指定しない import の一時 session は成功・失敗のいずれでも処理後に削除し、調査・復旧のため保持する場合にだけ指定します。

```bash
# macOS: --threads は指定しない
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --sessions-root "$SESSIONS_ROOT" --keep-session --low-heat "$AUDIO_FILE" "$SEGMENTS_OUTPUT"
```

Portable の import / resume は `--threads N` が必須です（export-only resume を含む）。`N` は `1...min(4, logicalCPUCount)` で、ASR・diarizer・tagger の ONNX session は N、VAD は常に1 thread です。Mac は `--threads` を拒否します。`--low-heat` は Portable では ASR 区間間の pacing のみを行い、thermal monitor / start gate / pause はありません。Mac では推論が必要な import / resume の開始時に nominal / fair を要求し、critical 時は処理を pause します。resource を作る Mac run の `--low-heat` は pacing に加えて MLX cache 上限を抑えます。measurement option と thermal / memory sampling は Mac 専用です。これらは短い fixture の成功から長時間のメモリ条件やライブ遅延を推定するものではありません。

`--with-decisions` の実行時に Mac は `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` に実在する絶対 directory を要求し、その直下の ClauseTagger.mlpackage と tokenizer.json を Core ML provider が使います。Portable は `MAC_AMBIENT_JEV_SILERO_MODEL`（既存 absolute model file）、`QWEN3_ASR_ONNX_MODEL_DIRECTORY`（既存 absolute directory）、`QWEN3_ASR_ONNX_MODEL_SIZE`（`0.6b` または `1.7b`）、`MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY`（既存 absolute directory）を必要とし、decisions を有効にすると `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY`（既存 absolute directory）も必要です。default、暗黙 download、fallback はありません。設定は推論に必要な import / resume の前処理段階で検証され、inspect と推論不要の export-only resume は model environment を読みません。Portable の decision-only retry は ASR / diarizer 推論を再実行しませんが、base engine bundle を構成するため基本4項目の environment が必要です。

### inspect と resume

```bash
# macOS: --threads は指定しない
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --inspect-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT"

# macOS: --threads は指定しない
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --resume-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT" \
  --low-heat "$SEGMENTS_OUTPUT"
```

inspect は read-only で、session action と保存整理 `maintenance`（`compactRecording`、`removeTransients`、`null`）を JSON で返します。`--with-decisions` と `--threads` を含む処理 option、位置引数は受け付けません。action は `finalize`、未公開の判定 run がある場合の `recoverDecisionRun`、判定の保留だけがある場合の `retryContentPriority`、`none`、音声が復旧できない場合の `unrecoverable` です。ID は UUID、root は必須です。manifest の完全 ID から実 folder を特定し、不在・複数一致・名前の検証不整合は明示エラーになります。

resume は最初に output containment / session lookup の safety 検査と read-only inspection を行います。初回 inspection の action が推論を必要とする場合に限り、model configuration / resources を解決し、`--with-decisions` が有効なら decision provider preflight も session maintenance より前に行います。その後に必要な保存整理（FLAC 変換または一時音声削除）を行い、再走査した action で finalize または decision retry を dispatch します。`--with-decisions` なしの decision-only recovery は新たな判定を行わず公開済み local transcript を export します。要求された mode をすでに満たす session は model / environment を必要とせず、推論 event を追加しません（Portable の CLI 引数として `--threads` はなお必須です）。finalize は保存済み音声から全段階を再実行し、pending ASR だけを再投入する経路ではありません。

認識テキストがある `--with-decisions` export は、clause-boundary と content-priority の両 run が公開済みで、boundary / priority retry target および `pendingDecisionTargets` が空の場合に限り成功します。判定 request が失敗した場合は既存 session の公開済み local transcript と保留状態を維持し、export を作らず CLI は非0で終了します。import の決定 preflight が session 作成前に失敗した場合は local transcript を約束しません。処理開始後に失敗した一時 import session は `--keep-session` がなければ削除対象のままです。認識テキストがない場合は判定 run なしで空の `[]` を export できます。

成功 export は全 session から materialize した `MaterializedTranscriptSegment` 配列を pretty-printed / sorted-key JSON として出力し、segment schema を変えたり TranscribeFile / CER artifact の envelope に包んだりしません。失敗・pause は completed として扱いません。実モデルでの VAD 成功や実 end-to-end 処理を fake service tests で保証するものではありません。

### CLI の portable service tests

[SessionFileProcessingServiceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionFileProcessingServiceTests.swift) の9つの fake-service test functions は、注入 engine / provider と一時 session を使い、実モデルや実 CLI end-to-end を実行せず service の処理・export・cleanup を検証します。

- `importKeepsCanonicalSessionAndPublishesTranscriptWithoutStdoutDependency` は import original、必須3段階の公開、materialized transcript と export の一致を確認します。
- `inspectReportsDecisionRetryWithExactJSONAndDoesNotTouchEventsOrCreateResources` は read-only inspection、exact JSON、event 不変、resource factory 未呼出しを確認します。
- `resumeOfDisabledOrSatisfiedTranscriptExportsWithoutResources` は判定無効または要求済み判定が完了済みの場合に resources を作らず、event を追加せず同じ配列を export することを確認します。
- `interruptedImportedFinalizationResumesFromRunningMetadata` は中断した finalization を再走査後に全量再実行し、complete metadata と export を確認します。
- `decisionOnlyResumeRetriesPublishedTargetsAndRecoversUnpublishedRuns` は公開済み retry target と未公開 decision run の双方を復旧し、ASR / VAD / diarizer を再実行しないことを確認します。
- `failedDecisionRequestRejectsDecisionExportButKeepsPublishedLocalTranscript` は strict decision export failure、保持された local transcript / pending target、出力なしを確認します。
- `failedImportCleansTemporarySessionOnlyWhenNotRetained` は失敗時に `keepSession` がない一時 session を削除し、指定時は保持することを確認します。
- `invalidAliasesAndMissingAudioAreRejectedBeforeResourceCreation` は同一 path、missing audio、session 内 resume output を resources 作成前に拒否します。
- `noSpeechWithDecisionsExportsEmptyArrayWithoutDecisionRuns` は無発話の空配列 export と decision run 不要を確認します。

[ProcessRecordingArgumentsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ProcessRecordingArgumentsTests.swift) は同じ CLI test target から `.macOS` / `.portable` policy を指定して parser を検査する9 test functions です。

- `macOSAcceptsCompleteMeasurementOptionsForImportAndResume` と `macOSRejectsThreads` は Mac の計測 option 全指定と `--threads` 拒否を確認します。
- `portableImportAndResumeRequireBoundedPositiveThreads` と `portableRejectsMeasurementOptionsWithoutFilesystemSideEffects` は import / resume の必須 thread 範囲と、measurement option の副作用前拒否を確認します。
- `inspectAcceptsWithoutProcessingOptionsAndRejectsDisallowedOptions` は両 policy で inspect の decision / thread / pacing / measurement / position option を拒否します。
- `decisionsAndImportFlagsArePreservedOnBothPlatforms` は両 policy で `--with-decisions`、`--keep-session`、`--low-heat` と resume の option parsing を確認します。
- `duplicateFlagsOptionsAndUnknownFlagsAreRejected`、`missingInvalidAndEmptyValuesAndPositionalsAreRejected`、`malformedOptionsCannotBeHealedByRemovingFlags` は重複・未知 option、値と位置引数の不備、flag 除去で malformed option が通らないことを検査します。

parser policy の simulation は portable runtime / CLI composition を macOS 上で compile したことを示すものではありません。

[ProcessRecordingSafetyTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ProcessRecordingSafetyTests.swift) の measurement destination / sampling failure cases と [ThermalLineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ThermalLineTests.swift) は macOS 専用です。これらは RunMonitor の出力 alias、安全な書込み失敗、thermal JSONL を扱います。portable parser / fake service tests は測定済み run、実 model の end-to-end、または CI の実行内容変更を意味しません。

### 不正入力の smoke

`scripts/verify_cli_inputs.py` は build 済み CLI のパスを一つ受け取り、重複 flag、未知 option、inspect/resume の余分な位置引数、計測引数の欠落等の 10 ケースを実行します。不正入力の非 0 終了に加えて、出力・計測ファイル・セッションが作成されないことを確認します。さらに実 named folder で inspect の正常・不在・完全 UUID の重複・同じ先頭 8 桁の別 ID・名前/日時/suffix/stem の不整合を検証し、実セッション内（symlink・大文字小文字の違いを含む）への resume 出力を拒否して原ファイルが変わらないことを確認します。これは実モデルの正常推論とは別の safety smoke です。

## ポータブル full-model の受入

Linux / Windows の `MacAmbientJevProcessRecording` は、実モデルで音声ファイルから最終 transcript までを通す受入 driver [`process_recording_acceptance.py`](../tools/linux-audio/process_recording_acceptance.py) で検査します。入力は公開 fixture `qwen3_asr_voicevox_long.wav`（18.464 秒）だけで、参照文と WAV の SHA-256・sample 数は [windows.md](windows.md#日本語音声-fixture) の表から読みます。fixture が表と一致しなければ失敗します。

driver は release の CLI と `MacAmbientJevEvaluateASR` の絶対 path、fixture を引数で受け取り（既定値なし）、次を実行します。

1. 一時 sessions root へ `--keep-session --with-decisions --threads 2` で import する。
2. 全モデル環境変数を除いた環境で `--inspect-session` を実行する。
3. 完了済みセッションを `--resume-session --with-decisions --threads 2` で再開し、出力を import と比較する。

必須の環境変数は `MAC_AMBIENT_JEV_SILERO_MODEL`（ファイル）、`QWEN3_ASR_ONNX_MODEL_DIRECTORY`、`QWEN3_ASR_ONNX_MODEL_SIZE`（`0.6b` か `1.7b`）、`MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY`、`MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` です。いずれも未設定・空・相対 path・存在しない path は失敗で、skip しません。各コマンドには timeout があり、import と resume は 300 秒です。

検査内容は次のとおりです。

- 全コマンドの終了コードが 0 で、import の stdout に `session_id:` 行がちょうど 1 つある。
- 出力 JSON は 2 件以上の segment を時系列・重なりなし・音声長以内で持ち、各 `text` は日本語を含む。`clause_state` は `classified` で、clause slice は priority を持ち再試行待ちがない。
- `text` を時刻順に連結した raw 文を `MacAmbientJevEvaluateASR`（製品の正規化と CER 評価）で参照文と比較し、正規化後 CER が 0.15 以下。
- 話者の raw id が空でなく span が音声長に収まる。`SpeakerDisplayMapper` と同じ規則（先頭 start 順に Speaker 1–7、8 人目以降は OTHER、重なりがなければ UNKNOWN、80% 以上を占める話者の単独表示）で得た表示ラベルが Speaker 1–7、OTHER、UNKNOWN のどれかである。話者数は固定しない。
- セッション folder に `session.json`、末尾まで完結した `events.jsonl`、`processing_metadata.json`、`storage.json`（imported original と import 時のフレーム数）があり、`audio/original.*` が入力と byte 単位で同一である。`audio` 以下に CAF が残らず、`recording.flac` がない。
- `active_runs` の segmentation・asr・diarization・clause_boundary・content_priority が全てあり、それぞれ `processing.run.started` / `processing.run.completed`（成功、失敗数 0）が 1 つずつある。provenance の engine は Silero・Qwen3-ASR・Community-1 の ONNX engine で、ASR の model は [qwen3_asr_models.json](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/qwen3_asr_models.json) の `repository@commit`、`intra_op_threads` は 2 である。判定 run の engine は ONNX で、Core ML を名乗らない。境界・優先度の判定 event が active run にあり、保留中の判定対象がない。
- 出力 segment と active ASR run の認識済み `asr.completed` event が segment ID と本文で一致する。
- inspect は `action` が `none`、`maintenance` が `null` で、resume は `events.jsonl` を変えず、出力が import と同一である。

driver 自身のテストは実モデルを使わず、偽の CLI と evaluator が作る session で、誤った transcript、欠けた stage、不正な話者、欠けたファイル、残った CAF、Core ML を名乗る判定 engine、import と異なる resume 出力が各々失敗することを確認します。POSIX のみで実行します。

```bash
cd tools/linux-audio
uv run --python 3.12 --with pytest python -m pytest -q tests/test_process_recording_acceptance.py
```

### full-model モード

`bash scripts/verify_portable.sh --full-model` は通常の検証とは別の opt-in モードで、フラグがなければ従来どおりの build と test だけを実行します。このモードは次を順に行います。

1. ONNX Runtime、Silero、Qwen3-ASR tokenizer、clause tagger に加えて Qwen3-ASR 0.6B（int4、保存先 `.build/qwen3-asr-models`）と Community-1 diarization を既存の fetcher で取得し、5 つの環境変数を設定する。
2. `RUN_MODEL_TESTS=1` で 4 engine の数値 suite（[SileroVADParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/SileroVADParityTests.swift)、[ONNXQwen3ASRModelTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXQwen3ASRModelTests.swift)、[Community1ONNXStageTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Community1ONNXStageTests.swift)、[ONNXClauseTaggerTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXClauseTaggerTests.swift)）を 1 つずつ実行する。実行された test 名と skip された test 名を出力し、1 件も実行されなかった suite は失敗とする。
3. `MacAmbientJevProcessRecording` と `MacAmbientJevEvaluateASR` を release で build し、受入 driver を実行する。

fixture 入力の Qwen3-ASR は 0.6B で、1.7B の製品品質ではなく経路の接続を検査します。1.7B の CER は別の記録で扱います。

Windows では `./scripts/test-windows.ps1 -FullModel` が通常の build / test の後に同じ取得・数値 suite・release build を行い、ONNX Runtime の DLL を release の CLI の隣に置いて同じ driver を実行します。Windows 上の実モデル受入は手動で実行し、通常の Windows CI には含まれません。

### CI の `linux-model-e2e`

[portable-core.yml](../.github/workflows/portable-core.yml) の `linux-model-e2e` は `linux` と同じ trigger と draft の扱いで動く必須 job です（`swift:6.2-noble`、timeout 45 分）。まず driver の自己テストを実行し、続けて `verify_portable.sh --full-model` を実行します。モデル directory（`.build/` 以下の Qwen3-ASR 0.6B、tokenizer、Silero、Community-1、clause tagger）は OS・arch と、各 manifest と fetcher・`pinned_download.py` の hash を key に GitHub Actions の cache action へ保存します。broad な restore key はありません。cache が hit しても fetcher が全ファイルの SHA-256 を再検証し、破損した cache は別モデルで代替せず失敗します。ONNX Runtime は毎回取得します。

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

## macOS のファイル処理長時間計測

この長時間計測は macOS 専用です。`scripts/measure_v1_run.sh` は Mac release CLI の MLX memory / thermal sampling と `/usr/bin/time -l` を使い、音声 import または保存済み session の resume を一回計測します。Portable CLI は measurement options を拒否し、thermal / memory sampling を持ちません。事前に Mac release product を build し、必要空き容量は 4 GiB 以上です。

計測後は root 直下の manifest の完全 UUID を正規化して検索し、ちょうど一つの実フォルダーを解決します。ID 不在・複数一致・一致したフォルダーの名前/日時/suffix/source stem の不整合は明示エラーです。stem の Swift Character 境界での切り詰めを検査するため、実行する `python3` に `regex` package が必要です（`python3 -m pip install regex`）。日時は `created_at` から再計算しません。events、metadata、checkpoint、original は同じ解決済みフォルダーから読み、original が複数なら失敗します。import がセッション作成前に失敗して stdout に ID がない場合は、セッションの欠測理由を残します。ID がある場合は lookup の失敗を欠測扱いにしません。

`scripts/test_session_artifacts.py` は shell script 内の実 artifact Python を抽出して合成セッションで実行し、成功・不在・重複・不正 suffix/stem・合成文字の切り詰め・original の重複を検査します。capture summary の実 path が指定 root 直下であること、完全 UUID、systemAudio source、録音フォルダー名も検査します。capture/playback 部分は実行せず、実音声・権限・GUI の検証根拠にはなりません。単独実行は `python3 scripts/test_session_artifacts.py` です。

```bash
# macOS measurement build; the CLI has no --threads option on Mac
swift build --package-path app/MacAmbientJev -c release \
  --product MacAmbientJevProcessRecording

# macOS only: uses Mac thermal / MLX metrics and /usr/bin/time -l
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

### macOS CLI に直接計測引数を渡す場合

Mac の import / resume には `--run-id`、`--metrics-output`、`--thermal-output`、`--memory-output` を四つすべて指定します。run ID は空でなく `/` を含まないもの。三つの計測出力先は互いに異なり、既存ファイルがないことが必要です。Portable CLI はこれらを filesystem side effect より前に拒否します。通常は上の Mac 専用 script を使います。

## 原速 replay のライブ遅延計測

```bash
bash scripts/measure_live_latency.sh "$AUDIO_FILE"
bash scripts/measure_live_latency.sh --sample-rate 48000 --channels 1 "$AUDIO_FILE"
```

`MacAmbientJevMeasureLiveLatency` は既存音声を原速で投入し、VAD 区間終了から最初の非空な RAW ASR 更新までを計測する。発話文判定は無効で、最初の `displayText` は未評価の ASR 原文。空白・改行だけの本文は除外するが、認識されたフィラーだけの非空 raw 行も最初の更新として数える。CLI は tagger を実行せず F・B除去範囲を適用しないため、これは F・B除去後の更新時間ではない。report に記録する本文も raw で、空白・句読点の変更や正規化を行わない。次区間待ちと境界・優先度判定の時間は測らない。投入は遅延計測と同じ時計の起点からの絶対予定で行い、各 0.5 秒の塊はその末尾の音声時刻まで待ってから durable append する。変換や append の処理時間は後続の塊へ累積しない。report の `replay_max_feed_lag_seconds` は、各 append の完了時刻から、それまでに投入した replay input の音声秒数を引いた値の最大値である。この値が大きい場合は投入が原速に追いついておらず、遅延値に投入の遅れが含まれる。replay の入力形式は既定でファイル形式、明示指定時はその device 相当形式に変換する。sample rate は 1000〜768000 Hz、channels は 1〜32。durable append 前に同じ ingress converter を通し、保存と VAD / ASR は常に 16 kHz mono。report の `source_*`、`replay_input_*` と `processing_*` は別形式を表し、frame 座標は保存 timeline を参照する。`--match-default-input` は既定入力 format を読むだけで capture を開始しないが、sample rate/channels の明示指定とは併用できない。

Qwen と VAD のキャッシュ済みモデルが必要。閉じた VAD 区間、または最長 14 秒分割が表示単位であり、長い発話は初表示まで待つ。測るのは非空更新までで、実画面描画、マイク入力の実時間、全発話の精度を保証する指標ではない。

### 保存整理のテスト

Runtime の保存整理テストは、確定処理の全結果（成功・発話なし・VAD／話者分離／ASR の失敗・話者分離中のキャンセル・一時停止）と録音・import の組で、話者分離入力 CAF と import の処理タイムラインが残らないこと、開始失敗でも古い一時ファイルが消えること、削除失敗・変換失敗のメッセージ、変換後の再処理が PCM 由来と同じ文字起こしを返し FLAC を変えないこと、失敗した再処理が公開結果と FLAC を保つことを、音声から結果を導く fake engine で確認する。AppleSupport の起動時整理テストは、全セッションの整理が収束し、整理に失敗したセッションをフォルダー名付きで返し、録音中のセッションに触れないことを確認する。App テストは、起動時の保存整理中に、音声がまだ `recordingPCM` の録音の書き出しが、書き出し先へ触れる前に整理中のメッセージで止まることを確認する。

## ポータブル ONNX の書き出しと受入

[export_clause_tagger_onnx.py](../scripts/export_clause_tagger_onnx.py) の純粋な helper（引数・入力 path・出力先の検証、入出力契約、入力 ID、fixture document、license 文、state revision）は [test_export_clause_tagger_onnx.py](../scripts/test_export_clause_tagger_onnx.py) が torch なしで検証します。このテストは portable-core workflow の Linux と Windows で実行します。

```bash
python3 -B scripts/test_export_clause_tagger_onnx.py
```

実際の書き出しと受入は、モデルと checkpoint が必要なためリポジトリのルートで手動実行します。重い処理なので、他の重い job と同時に動かさないでください。出力先は存在しない新規ディレクトリで、親ディレクトリは先に作ります。`<models>` は modernbert-ja-30m と multi-30m-bc2 を置いたディレクトリの絶対パスに置き換えます。

```bash
mkdir -p .build/clause-tagger-onnx-export
uv run --project tools/clause-tagger-export python scripts/export_clause_tagger_onnx.py \
  --base-dir <models>/modernbert-ja-30m \
  --checkpoint <models>/multi-30m-bc2/multitagger.pt \
  --tokenizer <models>/modernbert-ja-30m/tokenizer.json \
  --fixture app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerFixtures.json \
  --output-dir .build/clause-tagger-onnx-export/clause-tagger-onnx
```

`--tokenizer` には SHA-256 `0a94ac9a...` の tokenizer.json を指定します。multi-30m-bc2 ディレクトリの tokenizer.json は再保存された別 bytes なので使えません。受入検査の内容は [判定](decision-engine.md) の「ポータブル ONNX の書き出し」に従い、失敗した検査と測定値を標準エラーに出して非 0 で終了します。成功時は stdout の最後の行に ClauseTagger.onnx の SHA-256・サイズと head ごとの最大誤差を JSON で出し、全長の誤差は export.json の `parity` に残ります。

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
