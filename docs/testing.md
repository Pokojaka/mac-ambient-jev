# 検証と計測

自動検証、実モデルによるファイル処理、計測結果の意味を分けて扱う。マイク・システム音声の実キャプチャや画面の確認は、ファイル入力の結果だけでは検証できない。Linux の artifact・corpus・CI 実推論は [linux.md](linux.md)、処理経路は [final.md](final.md)、保存と公開結果は [storage.md](storage.md) を参照する。

以下のコマンドはリポジトリルートから実行する。実データのファイル名、セッション ID、保存先を示す環境変数には、自分の実在するデータを設定する。個人録音は Git に入れず、ローカル録音用の領域に置く。配置の案内は `test-data/recordings/README.md` にある。

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
   `scripts/test_session_artifacts.py` で計測・capture summary の artifact 検査を合成セッションで実行する（処理・capture は開始しない）。Python の `regex` package が必要。
2. SwiftPM の依存を解決し、package を build する。
3. `RUN_MODEL_TESTS` を外して通常の Swift test を実行する。
4. `MacAmbientJevProcessRecording` を build し、`scripts/verify_cli_inputs.py` で不正入力、named folder の inspect、resume 出力先の containment を確認する。
5. `MacAmbientJevEvaluateSession` を build する。
6. モデル検証を指定した場合は Runtime test bundle を実行する。
7. `scripts/build_app.sh` で app bundle を作り、MLX Metal shader library と、利用者が選んだファイルへの read/write・app-scope bookmark entitlement を確認する。

アプリの build は行うが GUI を起動しない。通常の検証は実 ASR モデルを実行せず、認識精度やライブ録音の合格根拠にはならない。`.github/workflows/ci.yml` の macos-15 job も通常の `verify_v1.sh` を実行する。

通常の Swift test は実 Keychain にアクセスしません。`keychainStoreRoundTripsAndDeletesValue` は `RUN_KEYCHAIN_TESTS=1` を明示した場合だけ実行する integration test で、専用のランダム service 名でテスト値を保存・削除します。アプリの Jev API キーは使いません。実 Keychain へのアクセスを許可しない検証では、この環境変数を設定しません。ライブ Jev regression は注入した分類器 factory を使います。

`scripts/check_doc_references.py` は `README.md`、`AGENTS.md`、docs 配下の Markdown（records を除く）のリポジトリパス、script、既知 CLI の flag、Swift 型の参照を検査する。

### Jevの型付きAPI契約

```bash
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev --filter 'JevDecisionTests|JevEnrichmentCoordinatorTests|JevFailureHandlingTests|ClauseAssemblyTests|TranscriptPriorityPresentationTests|LiveContentPriorityGatingTests|LiveJevRecordingTests|FinalTranscriptPipelineTests|nativeTakeoverFinishesWithoutWaitingForLiveNetworkAndReusesOnlyFrozenDurableAnswers'
swift test --package-path app/MacAmbientJev --filter JevTransportContractTests
```

[JevTransportContractTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/JevTransportContractTests.swift) は実 `JevClient` にHTTPTransportを注入し、複数Noul候補と継続の一HTTP送信、終端のnext省略、原文のCharacter／UTF-16座標、候補印衝突、次原文60 Character上限、source IDや不要本文の非送信、40対象Choiceと回答key対応を検証します。空・重複・本文なし・41対象を送信前に拒否し、missing answer、余分な回答、type mismatch、unknown choice、確率／confidenceの範囲外・非有限値、不正model／usage／tokenで部分結果を公開しないことを確認します。未報告tokenと既知の0 tokenは区別します。Noul採用は0.5直前・同値・直後、LOW採用はconfidence 0.90を境に検証します。

計数・consumerの回帰検証は purpose 別の実 request 計数と合計、session + 境界区間／優先度節の保留 identity、401／403／429／5xx の停止と未送信保留、cancel の attempt-only、通信成功後の保存失敗、低 confidence 応答・metadata 保持を対象にします。接続確認や実 API の品質を合成応答で証明したとは扱いません。

実行 smoke は一時 harness で実 SessionWriter／NativeSessionProcessor／reader／metadata／export を通します。複数の保存 raw 区間から跨ぎ節と行内別節を作り、混在 Choice、finishInput、確定 ASR の異なる区間配置への byte 完全一致 carry、通信失敗保留、設定と同じ retry API、metadata 再読込、txt 実出力、purpose 別 usage を観測します。Jev.disabled では外部送信0・無分割通常表示・ローカル公開を確認します。raw に残ったフィラーが表示と txt から消えることも確認し、harness は検証後に除去します。この smoke は外部 API の精度・GUI・録音権限を検証しません。

### 合成イベントによる回帰検証とライブ滞留計測

```bash
swift test --package-path app/MacAmbientJev --filter 'catalogRejectsUnreadableEventLog|validatedEmptyVADCompletesWithoutSpeechInference|recordingPreservesCaptureAndReleaseFailures|coolingDrainsLiveBacklogWithLatestCheckpointAndStopReleasesState'
swift test --package-path app/MacAmbientJev --filter measureLiveRegistrationCost
swift test --package-path app/MacAmbientJev --filter measureLatestCheckpointRetentionDuringThermalStall
swift test --package-path app/MacAmbientJev --filter 'liveASR|liveRows|liveAuthorization|stoppingRecordingCancels'
swift test --package-path app/MacAmbientJev --filter 'appRecordingShowsLiveRowsWhileJevWaits|appRecordingShowsJevFactoryFailureReason|liveRowsShowAtOnce|nativeTakeover'
```

correctness test は読み取れないイベントログ、検証済み VAD の空結果、録音障害と停止時の資源解放障害、冷却後のライブ認識再開の境界を合成イベントで検証する。計測 test は 5 秒ごとに一発話とした 10 分・1 時間・4 時間相当の合成イベントを使い、再登録の中央値時間と critical 時に保持する ASR バッチ・区間参照・checkpoint・chunk 一覧の項目数を出力する。計測 test の成功は性能合格を意味しない。時間はモデル推論を含まず、保持数は RSS ではない。実キャプチャ、GUI 起動、権限要求は行わない。

`measureLiveRegistrationCost` は debug 構成で、登録 setup を計測から除外し、各 120・720・2880 件の pending 履歴に対して同じ ID を 100 回再登録する標本を 7 個取り、一呼出しあたりの中央値を µs で出力します。登録 progress はセッション内の materialized 行と ID 数を使い、pending 履歴全体を再構築しません。判定目安は 4 時間相当の中央値 ≤ 50 µs かつ 10 分相当の ≤ 3 倍です。時間の単体テスト assertion は置きません。比率が timer noise で外れた場合は全 7 標本を報告し、同じ標本数で逐次に一度再計測します。認識済み行の更新 projection、モデル推論、アプリのキュー保持量はこの計測の対象外です。測定結果は [live registration 計測記録](records/2026-10-04-live-registration.md) を参照してください。

`measureLatestCheckpointRetentionDuringThermalStall` は実 `AppState` の区間登録・enqueue と強制 critical を使い、一発話につき 5 秒の合成 chunk 一覧項目を追加する（音声ファイルは作らない）。120・720・2880 発話で checkpoint の保持数はセッションあたり 1 件、保持 chunk 項目数は最新 checkpoint の 120・720・2880 件だけとなる。区間参照は全件保持する。`coolingDrainsLiveBacklogWithLatestCheckpointAndStopReleasesState` は保存済み合成 PCM と injected ASR を使い、critical 中の認識停止、最新 checkpoint の保持、冷却後の全区間の一度だけの順次認識、録音停止後のキュー・checkpoint 解放を確認する。計測 harness は時間の assertion を置かない。

ライブ ASR regression は認識後の新規 pending 登録・重複 ID、ASR 完了・空本文・失敗の ordered snapshot、同一 run の保存済み節更新と active run 切替、登録・完了・失敗・終了イベントの保存障害、並行登録・終了を検証します。取得済み行配列は後の認識や節更新で変わりません。Jev 待機中も全行が即時表示されること、時間順、無効・失敗・停止、空区間のテキスト列終端、ASR gap 後の未解決先頭を注入 provider で検証します。

`appRecordingShowsLiveRowsWhileJevWaits` は実 `AppState.startRecording`、checkpoint の VAD polling、区間登録、ライブ ASR drain、Jev queue、画面用 projection を通します。capture・VAD・ASR・Jev は合成入力に置き換え、応答を止めている間も通常行が表示され、保存済み判定だけが反映されることを確認します。`appRecordingShowsJevFactoryFailureReason` は分類器生成時の合成エラーを使い、理由が状態表示に残り、通常行を表示して録音と ASR を継続することを確認します。実 Keychain、外部 API、マイク、GUI は使いません。

ライブ ASR drain の完了は、独立して動く Jev キューの完了を保証しません。分類器生成エラーの regression は、2 行の表示と先頭行の `boundaryPending` を同じ 5 秒の期限内で待ちます。この保留行の公開はエラー状態表示の通知後なので、その時点で理由の保持を検証します。待機間隔は 10 ms とし、固定 sleep の延長や失敗後のリトライでは同期しません。

保存済みセッション catalog は active ASR run のイベントログ・payload を読み取り専用で検証し、欠損・不正・不完全な末尾を持つログを破損として表示する。合成 catalog regression は malformed / missing / directory の各ケースで非 exportable 状態、再処理可否、manifest と metadata の不変性を確認する。

Linux 音声正規化は入力と出力が同一ファイル（シンボリックリンク解決後を含む）なら、出力先を変更する前に拒否し、原音声を保持する。`tools/linux-audio/tests/test_audio.py` は実 ffmpeg を使う同一パス・symlink の境界と、正常変換・変換失敗時の出力処理を検証する。

`validatedEmptyVADCompletesWithoutSpeechInference` は 1 秒の合成無音を 2 回確定し、検証済み VAD の空結果が話者分離の準備失敗・推論失敗に依存しないことを確認する。ASR 準備も呼ばれず、原音声の bytes、読み取れる空 transcript、5 段階の provenance と成功 0 件完了、`complete` metadata、終端の無発話表示、復旧対象外の分類を検証する。VAD 自体の失敗と発話ありの推論失敗は `failed` のまま旧公開 run を保持する。これは orchestration の検証であり、実 FluidAudio モデルの無音成功・クラッシュを測った結果ではない。

[CanonicalAudioIngressTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/CanonicalAudioIngressTests.swift) は device-rate の合成 tone を irregular / 512-frame block に分けて実 drain とディスクへ通す。48 kHz・44.1 kHz の累積 duration、block 境界の single-stream reference との sample 差、997 / 3101 Hz の波形誤差、16 kHz identity、4-channel import 平均、fractional-ratio の gap・overlap・overflow・stop tail、部分 append failure 後の retry と並行 finish / snapshot を検証する。fixture を保存前に preconvert しない。EOS 後の全体長は正確な長さの floor か ceil で、gap は公開範囲へ切り詰める。

`captureStartReservesStoredPCMNotDeviceRate` は injected tap の実 capture start を 48 kHz・44.1 kHz・16 kHz で実行し、601,600,000 bytes の受理と 601,599,999 bytes の拒否を確認する。hardware・permission prompt は使わない。[CanonicalEngineInputTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/CanonicalEngineInputTests.swift) は既存 CAF の実 samples を複数の bounded random range で読み、音声コピーを作らない source path と Qwen の非 canonical 入力拒否を検証する。同じファイルの `finalizationEnginesReceiveCanonicalAudioForRecordedAndImportedSessions` は、48 kHz の録音を irregular block で実 drain に通した session と 44.1 kHz stereo の import を実 `NativeSessionProcessor` で確定し、injected VAD・話者分離・ASR が受け取る形式（16 kHz・mono・float32、CAF 長、ASR sample 数）と original の bytes 不変を検証する。

### 保存音声のテスト

[SessionAudioStorageFormatTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/SessionAudioStorageFormatTests.swift) は `storage.json` の 4 つの形を bytes で固定する（[保存形式](storage.md)の例はこの出力）。[RecordingAudioCompactorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/RecordingAudioCompactorTests.swift) は 16-bit FLAC への変換を、4,096 フレーム前後を含む長さ、クリップ・端点・非有限値、破損・欠落・余剰フレームの FLAC、全 `Boundary` での中断と再実行の収束で確認する。[LaunchMaintenanceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/LaunchMaintenanceTests.swift) は起動時の保存整理が全セッションを収束させ、失敗したセッションをフォルダー名付きで返すことを確認する。[SessionStorageFinalizationTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/SessionStorageFinalizationTests.swift) は全結果での一時音声の削除、変換・削除の失敗報告、一時停止中の削除失敗、FLAC からの再処理（再符号化なし）、整理後の古い音声ソースを使わないことを、音声から結果を導く注入エンジンで確認する。[SessionExportTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionExportTests.swift) は FLAC の無変換コピー、PCM 状態の拒否、破損 FLAC での失敗と既存書き出しの保持、書き出しが内部音声を変更しないことを確認する。マイク・システム音声の権限や GUI の起動時整理の表示は、これらでは確認できない。

[SessionFileAccessTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/SessionFileAccessTests.swift) と [SessionAudioSymlinkTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionAudioSymlinkTests.swift) は一時ディレクトリだけを使い、イベント writer の初回 open と初期化後の置換、manifest・metadata の読込みと書込み、audio 親ディレクトリ、chunk・original・FLAC・partial・derived CAF の symlink を拒否することを検証します。セッション外の sentinel の bytes・ディレクトリ内容を比較し、descriptor を開いた後の URL 置換が元のファイルの読み書きを保つことと、通常セッションの成功経路も検証します。catalog・復旧はリンクされたセッションをエラーとして返します。選択 root の symlink 拒否は [AppPathsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/AppPathsTests.swift) が対象です。

AppState の合成テストに注入する `temporaryDefaults()` はインスタンス内の辞書だけを使う UserDefaults test double です。実 UserDefaults の標準 domain・suite domain を読み書きせず、Keychain・音声デバイス・実ネットワークも使いません。

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

フィラーの回帰検証は UTF-16 座標、Unicode Character の境界、単語内部の類似文字列、後続本文と接続した先頭フィラー、隣接する句読点、フィラーだけの行、画面 projection と `transcript.txt` の本文一致を扱う。materializer は ASR の原文を保持する。`savedTranscriptLoaderKeepsRawFillerTextForPresentationAndExport` は保存済み ASR イベントを `SavedTranscriptLoader` で読み、原文の保持と画面・テキストの除去済み本文、イベントの不変性を確認する。保存済みセッションの smoke は入力 `えー、今日は公開鍵暗号を説明します。` を使い、`SavedTranscriptLoader` → 共通 projection → `SessionExporter` の実際の `transcript.txt` 書き込み・再読込を通して本文が `今日は公開鍵暗号を説明します。` となり、イベントが原文のままであることを確認する。GUI の選択コピーとアクセシビリティ読み上げは別途、画面上で検証する。

節優先度の回帰検証は注入 `DecisionProvider` / `JevHTTPTransport` で決定的に行い、モデル品質の正解とは分ける。厳密な `> 0.5` と LOW 採用 `≥ 0.90`（直前の Double を含む）、候補の raw UTF-16 座標、全no・無句読点・連続句読点と末尾除外、跨ぎ節と終端、再利用対象を除いた後の40/41節の batch 境界を対象とする。最初の回答が有効でも後続の回答欠落・type不一致・不正Choiceで全batchを拒否し、一HTTPの失敗として数える。UTF-8 byte 完全一致の再利用では、trim・句読点・Unicode byte差を同一視せず、未公開retryのdurable回答も使わない。schema・参照・coverageの破損、保留再試行と公開snapshot、request単位のtoken計数、takeover時の保存済みLOWと通信中の通常行を確認する。LOW＋続き待ちは閉じたLOW部分だけ淡色で、待機本文も保持し、行を畳まない。画面projectionとtxtは混在PRIMARY/LOW、全LOW、待機・保留、フィラーのみを含む実sliceで本文と行集合を確認する。文言・内部配線・コピーした設定値を固定するテストは根拠にしない。

実ファイルの受入smokeは一時harnessで `NativeSessionProcessor` → `SessionWriter` → metadata・readerの再読込 → `SavedSessionCatalog` → `SessionExporter` を通す。注入ASRの `えー、週末の設計を確認します。そうですね。` からPRIMARY/LOW混在を作り、rawの保持、除去後本文、LOWを含む実txt出力、全LOW行の畳みを確認する。注入401/429ではpriority保留を通常表示し、priorityだけのtargeted retryで公開boundaryを維持・非対象pendingをcarryする。boundaryの429では無分割行を保持し、boundary retryで両runとpendingを一括公開する。provider応答前の再読込では直前の公開snapshotのままであることを確認する。2つのlive区間から1つのfinal区間への除去後本文完全一致carryはChoiceの再送なしで確認する。event appendとmetadata公開をそれぞれ実ファイルで失敗させ、ローカルのdurable本文・通常表示・5段公開を保持し、未公開の任意段を採用しないことを確認する。注入値は実APIの精度・ネットワーク課金の証拠ではない。harnessと一時セッションは受入後に削除する。

ASR gap の smoke は実ファイルに非空本文・ASR 欠落・成功した空 ASR・後続本文を保存し、`JevEnrichmentCoordinator` → metadata 公開 → reader/materializer の再読込を通す。前半本文を未解決のまま残し、空 ASR より後の本文だけを一回の Choice で分類し、保存 snapshot と再読込が一致することを確認する。空 ASR の後に新たな gap がある場合に先頭を推測しないことは回帰テストで扱う。

ライブ状態表示の実ファイル smoke は、注入 ASR で2区間を保存し、分類器の生成で資格情報エラーを投げる。`LiveASRSession` と `LiveContentPrioritySession` の実装を通して、ASR 原文と通常表示を維持し、両区間の durable 保留理由と最後の状態表示に同じ失敗原因が残り、境界・優先度の外部送信が0であることを確認する。App の状態への反映は回帰テストで扱い、実 GUI の検証とは分ける。

### 録音しない受入と実画面での確認

授業など録音できない環境では、マイク・システム音声を開始せず、システム音量や出力装置にも触れない。既存ファイルのCLI処理とディスクだけの注入smokeを行う。CLIの隔離rootで `--keep-session` の実処理を完了した後、JSONの `text` と参照先ASRイベントのraw、`display_text`、`source`、`clause_state`、空sliceを照合する。Jev disabledでは5つのローカルactive run、境界保留、priority保留なし、Jev requestなしを確認する。inspect → resumeの再書き出しでイベントbytesとmetadataが変わらないことも確認する。フィラーが実ASR結果に含まれなければ、そのファイルをフィラー削除の証拠にしない。

実API観測は実 `JevClient` と通常のtransportを使い、録音ではなく新しいテキストを境界→組立て→除去後本文のChoiceへ送る。キーは `security find-generic-password -s app.mac-ambient-jev.jev -w` のstdoutをメモリだけで取得し、端末・ログ・ファイルへ出さない。候補のraw UTF-16位置、確率、返却model、purpose別HTTP数、reported input token、HTTP時間を記録する。next到着待ち、consumerの反映処理、GUI描画をHTTP時間と混ぜず、未計測は未計測とする。新規テキストの観測と限界は [節API受入記録](records/2026-10-09-clause-acceptance.md) を参照する。利用者報告の13行の試作を再測定した値ではなく、CSJ全認定の一致率でもない。

bundleはREADMEの手順でbuildして `open .build/MacAmbientJev.app` で起動する。プロセスの生存だけでは画面の合格にしない。GUI操作の権限がない場合は、設定・表示・exportボタンの確認を未観察として報告する。録音可能な時の手動受入では次を確認する。

- Jev有効化・Keychain読取・録音元・書き出し先、マイク／システム音声の実権限。
- 14秒超の実ASR原文をイベントで確認し、第一行の「節の続き待ち」、後続行の可視性、跨ぎpartsと確率を照合。
- PRIMARY＋LOWの淡色、全LOWだけの初期畳み、LOW＋待機／保留の非畳み、展開後の全文、選択copy/paste・accessibilityのclean全文とLOW保持、行単位の時刻popover・話者見出し。
- 録音停止後のASR drain・finishInputとfinal takeover、late応答不採用、実live/final本文が完全一致する場合だけのcarryと送信削減。
- 未設定／設定停止／不正キー／通信失敗でもローカル公開が続くこと、priority障害で保存済みboundaryを維持すること。
- 設定の保留再試行ボタン／キー保存トリガー、二種targetの送信、atomic metadata切替、診断のrequest・pending内訳。
- 保存済み録音の再選択とGUI「書き出す」の実txt再読込、時刻・話者・改行処理・背景行除外、clean全文とLOW保持、イベントraw不変。GUI exportにJSONは含まれない。

`MacAmbientJevEvaluateSession`, `MacAmbientJevEvaluateASR`, and `MacAmbientJevEvaluateDiarization` consume explicit artifact files only; none locate or create saved sessions, so these artifact-only modes do not require `--sessions-root`. Every mode of the capture, file-processing, and live-latency CLIs requires an explicit root that rejects protected app data/cache roots, their ancestors/descendants, and symlink aliases.

```bash
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateSession
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateASR
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateDiarization
bash scripts/verify_portable.sh
```

`verify_portable.sh` は `scripts/check_portable_core.py` による Apple framework import 検査、SwiftPM manifest 評価、`MacAmbientJevCoreTests` を実行する。禁止 import は AVFoundation、AppKit、CoreAudio、CoreML、Security、SwiftUI。これは Core の境界検査であり、Linux 上で macOS runtime が実行できることを意味しない。

## ファイル入力 CLI の smoke

`MacAmbientJevProcessRecording` は macOS 専用で、マイクや GUI を使わず既存の音声を処理する。Jev は disabled で、API キーを使わない。

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

ID は UUID、root は必須。inspect は位置引数・`--keep-session`・`--low-heat`・計測引数を受け付けず、指定対象の action と保存整理 `maintenance`（`compactRecording`、`removeTransients`、`null`）を JSON で出す。action は `finalize`、`retryContentPriority`、`none`、音声が復旧できない場合の `unrecoverable`。読めない metadata 等の別のエラーは失敗として報告する。

UUID は manifest の完全 ID です。root 直下の manifest を検索して実フォルダーを解決し、不在・複数一致・名前の検証不整合は明示エラーにします。`none` は存在する正常セッションに復旧 action がない場合だけです。

resume は先にそのセッションの保存整理（FLAC 変換または一時音声の削除）を実行し、再走査した action で動く。resume は音声ファイルではなく対象 UUID と、セッション外の出力先を一つ指定する。録音・import の両方が対象で、finalize は共通確定処理を全量実行する。pending ASR だけを再投入する経路ではない。`retryContentPriority` または action なしの場合、CLI は Jev を再試行せず公開済みの結果を書き出す。resume が常に再処理を始めるわけではない。確定処理の失敗・一時停止では直前の正常な active run を保持する。

引数 parser は構文だけを検査します。resume の出力先 containment は実行時に実フォルダーを解決した後、symlink 解決・大文字小文字の同一視を保って検査します。実セッション内への出力は拒否し、lookup と containment の失敗は production engine の構築・処理より前に返します。

### 不正入力の smoke

`scripts/verify_cli_inputs.py` は build 済み CLI のパスを一つ受け取り、重複 flag、未知 option、inspect/resume の余分な位置引数、計測引数の欠落等の 10 ケースを実行する。不正入力の非 0 終了に加えて、出力・計測ファイル・セッションが作成されないことを確認する。さらに実 named folder で inspect の正常・不在・完全 UUID の重複・同じ先頭 8 桁の別 ID・名前/日時/suffix/stem の不整合を検証し、実セッション内（symlink・大文字小文字の違いを含む）への resume 出力を拒否して原ファイルが変わらないことを確認する。実モデルの正常推論とは別の検査である。

## セッションの CER と場面振動数

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

入力する `segments.json` の各要素から `start_ms`、`text`、`scene` を読む。保存順に本文を改行で連結して CER を求める。レポートは `id`、`asr_evaluation`（raw/normalized CER と normalizer version）、`scene_oscillation_count`。振動数は連続した同じ場面をまとめた後、30 秒以内の A→B→A を数える。これは人手の場面転換正解との誤差ではない。保持必須語・誤低優先度・誤背景の注釈評価は行わない。

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
- `memory.jsonl` は run ID、UTC 時刻、phase、`footprint_bytes`、MLX の active/cache/peak/cache-limit bytes。footprint 取得失敗は null と `footprint_error` の理由を持つ。sample 書き込み失敗も CLI の失敗になる。
- `thermal.jsonl` は run ID、UTC 時刻、state。サンプルは開始・終了・約 5 秒ごと、および phase 変更時に取る。critical は確定処理を一時停止する。
- マイクの dropout、Jev 利用件数、クラッシュ復旧の音声喪失窓は、このオフライン計測では測れず null と理由を記録する。

メモリ判定は ASR phase の有効な phys_footprint サンプルを使う。最初と最後の重ならない各 5 分窓で 48 件以上、全体で少なくとも 96 件・600 秒の範囲が必要。最後の中央値 − 最初の中央値が 512 MiB 以下、かつ `/usr/bin/time -l` の peak memory footprint が 12 GiB 以下で正常終了なら `VERIFIED`。サンプル不足、peak 欠測、途中失敗等は `INCONCLUSIVE`、条件を評価できて閾値超過なら `FAILED`。max RSS と peak footprint は別に記録する。短時間 run の INCONCLUSIVE は精度や処理成功の判定とは別で、ライブ録音全体のメモリ合格を意味しない。

### CLI に直接計測引数を渡す場合

import/resume には `--run-id`、`--metrics-output`、`--thermal-output`、`--memory-output` を四つすべて指定する。run ID は空でなく `/` を含まないもの。三つの計測出力先は互いに異なり、既存ファイルがないことが必要。通常は上の script に任せる。

## 原速 replay のライブ遅延計測

```bash
bash scripts/measure_live_latency.sh "$AUDIO_FILE"
bash scripts/measure_live_latency.sh --sample-rate 48000 --channels 1 "$AUDIO_FILE"
```

`MacAmbientJevMeasureLiveLatency` は既存音声を原速で投入し、VAD 区間終了から最初のフィラー除去後の非空更新までを計測する。フィラーだけの行は非空更新として数えず、report の本文は除去後本文の空白・句読点を変更しない。Jev は disabled なので次区間待ち・Noul・Choice の時間は測らない。replay の入力形式は既定でファイル形式、明示指定時はその device 相当形式に変換する。sample rate は 1000〜768000 Hz、channels は 1〜32。durable append 前に同じ ingress converter を通し、保存と VAD / ASR は常に 16 kHz mono。report の `source_*`、`replay_input_*` と `processing_*` は別形式を表し、frame 座標は保存 timeline を参照する。`--match-default-input` は既定入力 format を読むだけで capture を開始しないが、sample rate/channels の明示指定とは併用できない。

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
