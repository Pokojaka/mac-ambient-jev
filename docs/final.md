# 確定処理・復旧・再処理

録音停止後、ライブ処理が継続できなかった録音、音声ファイルの読み込み、保存済みセッションの再処理、クラッシュ復旧、CLI の再開は、共通の確定パイプラインを使います。ライブ文字起こしは暫定結果であり、確定本文や区間、発話文境界の入力にはしません。優先度の再利用では、各 run 固有の保存済み F・B除去範囲を各自の発話文 parts に適用して区切り文字なしで連結し、UTF-8 bytes が完全一致する場合だけライブ判定を確定発話文へ引き継ぎます。ライブの F・B除去範囲を確定側の原文へ移しません。

## 共通パイプライン

```text
保存音声の処理タイムライン
  → VAD
  → 録音全体のオフライン話者分離
  → VAD 区間ごとの Qwen3-ASR
  → 必須ローカル3段階の結果と全区間の境界保留を一括公開
  → Core ML 発話文モデルによる境界判定（任意）
  → BTSJ 発話文の組み立て
  → Core ML 発話文モデルによる優先度判定（任意。閉じた発話文を最大 40 件ずつ）
  → 境界判定 run・優先度 run・両保留を一括公開
```

境界・優先度の判定単位は BTSJ 発話文です。保存 key や内部名の `clause` / `節` はその発話文を識別し、別の節 splitter を意味しません。必須ローカル処理は segmentation・diarization・ASR の3段階だけです。Core ML 判定は任意の後段推論であり、必須3段階を増やしません。

音声は `storage.json` を確定処理の開始時に読んで決めます。`recordingPCM` は processing ディレクトリの PCM、`recordingFLAC` は `recording.flac` を全復号して検証した読み取り元として使います。FLAC 状態の録音では PCM が残っていても読みません。保存済みの音声がなければ「保存済みの音声がありません」で開始に失敗します。読み込み音声はアプリ内に保存した original から処理タイムラインを作るため、外部の読み込み元ファイルが残っている必要はありません。

読み込み音声の確定処理は、毎回既存の処理タイムラインを削除し、保存済み original からゼロから作り直してから始まります。作り直した処理タイムラインの長さと欠落記録は `storage.json` に保存し、確定処理の終了時に処理タイムラインを削除します。

VAD はライブと同じ `FluidVADSegmentationEngine` で区間を作ります。閾値、14 秒での分割位置、0.5 秒未満の独立区間の除外は[ライブ](live.md#vad-と-asr-の区切り)と同じです。

エンジン入力は **16,000 Hz・mono・float32 PCM** だけを受け付けます。VAD は保存済み floats を直接読み、ASR loader は区間の canonical samples を変更せず Qwen に 16000 とモデルが定義する言語指定 `language=Japanese` を渡します。20 ms 未満の ASR 入力を推論しない規則は変わりません。source frame は original や device ではなく保存タイムラインの座標です。

話者分離は既存の canonical CAF と FluidAudio の OfflineDiarizerConfig.segmentation.sampleRate を検証し、`OfflineDiarizerManager.process(audioSource:audioLoadingSeconds:progressCallback:)` を呼びます。`CanonicalCAFAudioSource` が lock 付きの bounded random read を行い、SRC や別の whole-audio raw PCM temporary file は作りません。FluidAudio が末尾で要求する固定長のモデル window には、CAF に存在する sample だけをコピーし、呼び出し元が 0 初期化した残りを変更しません。保存タイムラインの長さ・音声・区間座標には padding を加えず、実ファイルの予期しない EOF・不正 sample はエラーです。発話のある確定処理の CAF 自体は derived 内に保存します。

FluidAudio の話者時刻はゼロ padding を含むモデル window の grid 上の値です。`FluidOfflineDiarizationEngine` は CAF の実 sample 数を使い、`SpeakerSpanMapper` が canonical frame に変換した時点で、実音声内に開始し、最終 window の padding 内で終了する span の終端だけを EOF に合わせます。window 開始位置は `0, samplesPerStep, ... < sampleCount` なので、最終開始位置は `floor((sampleCount - 1) / samplesPerStep) * samplesPerStep`、許容 padding は `max(0, samplesPerWindow - (sampleCount - 最終開始位置))` です。EOF ちょうどで開始する span、padding を超える終端、負の開始位置、逆転・ゼロ長は明示エラーにします。音声自体の長さは変えず、保存イベントには実音声内の span だけを渡します。他の話者分離 engine や下流の確定処理で範囲外 span を切り詰めません。

話者分離の設定は OfflineDiarizerConfig.default のうち `embedding.minSegmentDurationSeconds` だけを 0.3 秒にしたものです。FluidAudio はこの値を埋め込みの抽出と最終 span の除外の両方に使うので、0.3 秒以上の短い発話にも話者 span が付きます。

VAD、ASR、話者分離には新しい run ID を付け、各段階の `processing.run.started` に、その実行の engine、model、version、configuration を保存します。以前の run の来歴を新しい実行へ引き継ぎません。

検証済み VAD 結果が 0 区間なら、話者分離用の音声を書き出さず、話者分離と ASR のモデル準備・推論、Core ML tagger のロード・判定を実行しません。保留も空です。3 段階すべてに provenance を持つ開始と `succeeded: true`、`completed_count: 0`、`failed_count: 0` の完了を保存し、同じ公開前検証を通して空の確定文字起こしを `complete` として公開します。これは処理対象がないことの完了であり、推論した話者 span を作りません。ASR 計測値はすべて 0、終端表示は「発話区間は検出されませんでした」です。保存音声は変更しません。

VAD の失敗・不正な区間、発話がある場合の話者分離・ASR の失敗を空の成功結果へ変換しません。これらは `failed` として以前の公開結果を保持します。空の成功結果は自動復旧の対象ではなく、明示的な再処理では新しい 3 段階の run で同じ空の結果を公開します。

録音停止では、ライブ ASR の残りを処理した後に判定キューへテキスト列の終端を伝えます。確定処理は開始時にイベントログから保存済みのライブ classified 結果だけを固定して、直ちにキューを取り消します。推論を待たず、固定後に保存された結果は確定処理の表示や再利用に使いません。確定の全区間についてモデルで境界を判定し、ライブ境界判定自体は確定区間へ移しません。優先度の再利用時は、ライブ run ごとにその run の保存済み `clause_boundaries.assessed.filler_ranges` を使い、その run の `clauses.closed` parts を区切り文字なしで連結します。確定側も確定 run 自身の F・B除去範囲と parts から本文を作り、両者の UTF-8 bytes が完全一致する場合だけ carry-over します。ライブの F・B除去範囲を確定側の source に適用しません。再利用するのは、確定処理で判定に使う tagger と同じ `model_revision` のライブ run の判定だけです。元の優先度 run・イベント・発話文参照を保ち、再利用判定を現在のモデルが生成したかのように書き換えません。候補がない終端 source の境界要求でも source-only window の span 推論を実行し、その request の入力 token 数を記録します。carry-over は新たな判定要求ではなく、carry-over だけの結果は inference 呼出しも request record も持ちません。残りの発話文を原文順に最大 40 件ずつ分類し、結果全体を検証してから batch ごとに一イベントで保存します。確定 run の `processing.run.started` provenance は run 開始時に実際にロードしたモデルの identity を示し、carry-over した判定のモデルは元の run の provenance が示します。境界保留の区間へライブ発話文を持ち込みません。ライブ判定の読取・保存破損は明確なエラーにし、空の再利用で全量再分類しません。その場合も成功したローカル結果の公開は取り消しません。[発話文判定](decision-engine.md)

## ローカル公開と任意の発話文判定

開始時に `processing_metadata.json` の finalization attempt を `running` にし、公開済みの `active_runs` は保持します。途中で得た話者 span、本文を、それぞれ独立に画面の現在値へ切り替えることはしません。

必須のローカル segmentation・diarization・ASR がすべて成功し、保存イベントの run 開始・成功完了、区間 ID・範囲・件数の整合性を確認した後、`active_runs`、finalization の `complete`、全ての非空区間の境界保留を同じ atomic write で保存します。その組から生成した確定表示（境界未判定の通常行）を一括で渡します。Core ML 発話文モデルによる境界・優先度判定は任意の後段です。利用可能なら両 run の pointer と両保留を一回の atomic write で公開してから表示を更新します。この保存に失敗した場合は未公開の結果を表示せず、直前に公開したローカル結果を保持してエラーを表示します。

モデルの初期化失敗・判定失敗（符号化エラーや判定結果の検証エラーを含む）の場合は判定対象を保留し、成功した必須3段階の公開結果を保持します。初期化失敗では判定 run を公開せず、全区間が境界保留のまま残ります。

CLI の `ContentPriorityAccess.disabled` は Core ML tagger の判定を行いません。必須ローカル3段階は通常どおり実行し、全区間を境界保留としたローカル transcript を公開します。この CLI 処理には保存済み境界評価・優先度評価がないため、`display_text` は ASR 原文です。

`processing.run.started` は判定 run の engine/model/revision を provenance に保存します。request record は実際の推論要求の request ID と入力 token 数を記録し、モデル identity は run の provenance が示します。候補のない終端 source の境界要求も source-only window の span 推論を実行し、使用 token 数を記録します。carry-over は新たな推論要求ではなく、それだけの結果には request record や推論呼出しがありません。carry-over 判定の元 run・イベント・発話文参照を保持し、そのモデルは元の run の provenance で示します。

ASR の計測 phase は推論完了時に終了します。その後の `postprocessing` phase は保存済み結果の検証、表示の組み立て、metadata の公開、および**任意の Core ML 発話文判定**を含みます。これは必須ローカル推論段階ではなく、必須の segmentation・diarization・ASR の3段階は変わりません。

保存済み判定・origin 参照の破損、不整合、イベントログ破損、イベント保存・metadata 公開失敗は保留に変換せず、処理エラーとして報告します。ローカル3段階が既に公開されていれば、その表示と境界保留を保持し、エラーを成功完了で上書きしません。

| 結果 | 永続状態と表示 |
| --- | --- |
| 成功 | `complete` と新しい全 run を公開 |
| 熱による一時停止・ローカル公開前の型付きキャンセル | `paused` を durable に保存し、公開済み run と以前の確定結果を保持 |
| ローカル公開後、任意判定中のキャンセル | finalization metadata は `complete` のまま、公開済みローカル `active_runs`・transcript・判定保留 metadata を維持。処理呼び出しは `paused` を返す |
| ローカル公開後、録音 compaction 中のキャンセル | `complete` と公開済み `active_runs` を維持。音声整理だけを次回起動時に再開 |
| 必須ローカル処理失敗・ローカル公開失敗 | `failed` と理由。公開済み run を保持 |
| 発話文判定の失敗 | 対象判定を保留し、公開済みローカル結果を保持 |
| 判定ログ・イベント保存・metadata 公開失敗 | 処理結果はエラー。公開済みローカル run・表示・保留 metadata は保持 |

型付きキャンセルがローカル結果の公開前に起きた場合は、推論失敗に分類せず `paused` の保存を試みます。保存に成功した場合、公開前の結果は表示・公開せず、以前の正常な確定結果があれば保持します。初回録音で確定結果がなければ、終了処理が得たライブ暫定結果を保持します。保持できる結果がなければ文字は表示しません。以前の結果自体が読めない場合は、その読取失敗も明示します。熱による一時停止も同じ永続状態・保持規則です。停止中の `paused` は次回起動時に scanner が `finalize` として再投入し、確定処理全体を新しい attempt/run で再実行します。一時停止 metadata の保存に失敗した場合は、明示的な処理エラー結果として元の中断理由（熱による一時停止を含む）と保存エラーの両方を報告し、`failFinalization` による `failed` metadata への書き換えは行いません。既存の `running` / `paused` metadata は保たれ、次回 scanner が `finalize` として再投入します。`paused` が durable なのは metadata 保存に成功した場合に限られます。

ローカル transcript の公開後、任意の境界・優先度判定中にキャンセルされた場合は、処理呼び出しは `paused` を返しますが、finalization metadata は既に保存した `complete` のままです。公開済みのローカル `active_runs` と transcript、および判定の保留 metadata を維持し、`complete` を `paused` に書き換えません。判定イベントや run がまだ保存されていなければ scanner は `retryContentPriority` を返しますが、これは起動時の自動復旧キューには入らず、利用者が判定を再試行するまで保留されます。公開済み snapshot より新しい final / retry の判定 run が保存された後、その run の snapshot 公開前に中断した場合は `recoverDecisionRun` を返し、起動時に判定復旧をキューへ入れます。どちらも公開済み snapshot を入力に判定だけを再実行し、VAD・話者分離・ASR はやり直しません。これは、次回起動時に録音の storage maintenance を再開する compaction 中断とは異なります。

必須ローカル結果を公開した後、録音の FLAC compaction がキャンセルされた場合は、処理呼び出しは一時停止を報告しても、永続状態は `complete` のまま `active_runs` と公開済み transcript を保持します。起動時は推論復旧ではなく `compactRecording` の maintenance を再開するため、VAD・話者分離・ASR をやり直しません。通常の完了録音も同じ手順で `recording.flac` に変換し、FLAC を検証してから `storage.json` の音声の正本を切り替え、その後に PCM を削除します。finalization の親 task のキャンセルは detached compactor に転送され、符号化・検証・公開・削除の各キャンセル境界でも、正本になっている PCM または検証済み FLAC を失いません。FLAC の録音の再処理は再符号化しません。

セッション情報を読めない開始失敗を除く全ての結果で、確定処理は終了時に一度だけ一時音声（話者分離入力の CAF、import の処理タイムライン、FLAC の partial）を削除します。型付きキャンセル以外の変換・一時音声削除エラーは成功結果も `failed` とし、公開済み transcript と元の run error があればその両方を保持・報告します。一時停止後の削除失敗は `paused` を維持し、元の一時停止理由と cleanup error の両方を状態文へ残します。詳細は [保存形式](storage.md) を参照してください。

途中失敗・一時停止でも、ASR 段階で得た計測値を処理結果に残します。ASR 開始前の失敗・キャンセルでは ASR 計測値はありません。

## 発熱による一時停止と再開

アプリは critical の間、確定処理の開始をキューに保留します。実行中は各 ASR 区間の処理前に critical を確認し、中断した attempt を `paused` として保存します。「発熱のため確定処理を一時停止中」と表示し、`failed` にはしません。

熱状態が critical を下回ると、アプリは保留した要求をキューの先頭に戻して自動再開します。利用者が文字起こし処理を一時停止している場合は再開しません。再開は未完了の ASR 区間だけを続けるのではなく、新しい attempt と run で確定処理全体を実行します。進行中のモデル推論を途中で強制中断するものでも、VAD・話者分離の各処理に区間ごとの熱中断を設けるものでもありません。

`MacAmbientJevProcessRecording` の file import、`--inspect-session`、`--resume-session` の全てで `--sessions-root DIRECTORY` は必須です。CLI は保存場所を暗黙に選ばず、root を検証してからセッション検索・作成・モデル処理を始めます。

CLI は開始時の熱状態が nominal / fair 以外なら開始を拒否します。処理中の critical では `paused` を保存して非 0 終了します。冷却後、`--resume-session` で再開できます。CLI のプロセスが冷却を待って自動再開するわけではありません。

## リソース監視による確定処理の保留

Windows Engine の [`EngineProcess`](../app/MacAmbientJev/Sources/MacAmbientJevEngine/EngineProcess.swift) は [`WindowsInferenceResourceMonitor`](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/WindowsInferenceResourceMonitor.swift) を生成し、[`SessionProcessingCoordinator`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingCoordinator.swift) に渡します。[`EngineApplication`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineApplication.swift) はリソース保護による一時停止後、`releaseResources` から gateway の `releaseIdleResources()` を呼びます。Mac GUI の [`AppState`](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift) は `resourceMonitor: nil` を明示し、`.healthy` を観測した意味ではありません。

resourcePressure / monitorFailed のとき、coordinator は確定要求を開始前に held queue へ保留し、実行中なら「メモリ不足のため確定処理を一時停止中」「リソース監視に失敗したため確定処理を一時停止中」と表示します。実行中の処理は安全な ASR 区間境界まで進み、native execution を途中で中断しません。境界で一時停止した後は `paused` metadata を保存し、公開済み結果を保持して `releaseResources` を実行し、表示から「（実行中の処理の終了待ち）」を外します。

monitor が healthy に戻ると held 要求を FIFO 順でキュー先頭へ戻し、cursor 続行ではなく保存音声全体を新しい attempt / run で処理します。`resources.preflight(finalization)` は表示用 assessment だけで、確定処理の preflight / acknowledge は不要です。shutdown cancellation は別経路で、shutdown 後に healthy へ戻っても自動再開しません。

`resource_protection.hold_reasons` は既存 schema のまま、live の latch・実行中の一時停止・held queue の理由を示します。空配列は健全性を意味しません。熱状態・熱制御は変更ありません。詳細は [processing queue](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingQueue.swift)、[processing status presentation](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineApplication+Processing.swift)、[resource admission](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineApplication+Resources.swift)、[Windows のリソース保護 schema](windows.md#プロファイル評価とリソース保護) を参照してください。

## 復旧と明示的な再処理

復旧判定は保存音声と処理 metadata を基準にします。

| 保存状態 | 復旧 action |
| --- | --- |
| finalization が `running` / `paused` | `finalize` |
| finalization 未作成、公開済み run なし、保存音声あり | `finalize` |
| finalization が `failed` | 自動復旧しない。利用者の再処理待ち |
| `complete`、公開済み snapshot より新しい未公開の確定・再試行の判定 run あり | `recoverDecisionRun` |
| `complete`、公開済み run と判定の保留（境界判定の区間または優先度の発話文）あり | `retryContentPriority`。自動復旧しない。利用者の再試行待ち |
| その他 | 復旧対象なし |

停止前にクラッシュした録音は durable checkpoint の保存範囲を使います。録音・読み込みのどちらも、復旧時の確定処理は VAD、話者分離、ASR の全量を新しい run で実行します。復旧は保存された `asr.pending` の区間に限定しません。

`recoverDecisionRun` と `retryContentPriority` はどちらも公開済みの保留を判定し直す action です。起動時の復旧は `finalize` と `recoverDecisionRun` だけを処理キューへ入れます。判定は同じ入力に同じ結果を返すため、`retryContentPriority` は設定の「保留中の判定を再試行」だけが実行します。判定の再実行では ASR・VAD・話者分離を含む必須ローカル3段階を再実行しません。保留一覧をイベントログで検証し、公開済み snapshot から新しい run を作って、同梱の Core ML モデルで判定します。再試行 run の `processing.run.started` は実際にロードしたモデルの identity を記録します。公開済みより新しい未公開 run がログに残っていても、その部分結果は採用しません。ライブの未完了 run は確定の再試行対象と見なしません。

読めないセッションは理由付きで報告します。イベントと `processing_metadata.json` は `schema_version: 3` が必須で、version の欠落や未対応の値は明示的な再処理でも拒否します。自動復旧は読めない `processing_metadata.json` を上書きしません。アプリの保存済み一覧で利用者が明示的に「再処理」を選ぶ場合だけ、未対応 version 以外の破損した処理 metadata を置き換えられます。派生結果が「破損」でも対応する保存形式と保存音声が利用可能なら再処理できます。原音声や録音タイムラインまで壊れている場合、metadata を置き換えても音声の問題は解消しません。

復旧 scanner は非表示・manifest 欠損を含む root 直下の全ディレクトリを調べ、保存フォルダー名と manifest を検証します。同じ完全 UUID が複数フォルダーにある場合は全て復旧失敗として報告し、自動処理へ投入しません。`paused` は `finalize` として再処理し、`complete` でも録音 PCM や一時ファイルが残る場合は transcript 推論と別に `compactRecording` / `removeTransients` の maintenance を返します。起動時は maintenance を先に実行し、そのセッションの maintenance が成功するまで inference recovery から除外します。maintenance の実エラーは `SessionMaintenanceIssue.failed`、shutdown cancellation で未完了の現在 item と残りの item は `interruptedByShutdown` として UUID と理由を記録し、成功済み item は結果に含めません。中断理由は終了処理による中断と次回起動時の再実行を明示し、disk error として扱いません。どちらの種類も maintenance 成功までは inference recovery から除外され、次回起動で必要な maintenance を再検出し、実際に成功した後でのみ推論復旧へ進みます。詳細は [保存形式](storage.md) を参照してください。

### CLI の復旧インターフェース

実行 target は `MacAmbientJevProcessRecording` です。セッション UUID を SESSION_ID、セッション保存ルートを SESSIONS_ROOT、セッション内部とは異なる出力先を SEGMENTS_OUTPUT に設定して使います。

```bash
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --inspect-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT"

swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --resume-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT" "$SEGMENTS_OUTPUT"
```

`--inspect-session` は読み取り専用で、JSON に `action`（`finalize`、`recoverDecisionRun`、`retryContentPriority`、`none`、`unrecoverable`）と `maintenance`（`compactRecording`、`removeTransients`、`null`）を出します。音声欠損は `unrecoverable`、その他の読取不整合はエラーになります。`--resume-session` は先に保存整理（`maintenance`）を実行し、もう一度調べた結果の `action` に従います。`finalize`（録音・読み込み）は再開します。CLI の `ContentPriorityAccess.disabled` は Core ML tagger による判定を無効にし、必須のローカル3段階だけを実行するため、`recoverDecisionRun` と `retryContentPriority` は判定せず公開済みの結果を書き出します。通常処理・再開とも `--low-heat` で ASR 区間の間に 2 秒の待機を入れられます。

ID は manifest の完全 UUID から実フォルダー URL に解決します。不在・複数一致・フォルダー名の不整合はエラーで、`none` は存在する正常セッションの action がない場合に限ります。resume は実行時に実フォルダーを解決して出力先を検査し、symlink と大文字小文字の違いを考慮してセッション内部への出力を production engine の処理前に拒否します。

## ASR 区間と話者時刻

ASR は VAD が作った区間の音声を、そのまま一回ずつ認識します。話者交代や短い相づちの時刻で VAD 区間を細分化しません。授業の説明・質問の前後にある音声文脈を同じ認識入力へ保ちます。最大 14 秒と静音での切断、短い continuation の保持はライブと共通です。

話者分離は録音全体に対して実行し、各話者の詳細 span を保持します。一つの ASR 行に複数話者が含まれる場合は、以下の 80% ルールで話者見出しを付けます。行の開始・終了は VAD 区間の時刻であり、本文内の各語を特定話者へ対応付ける時刻ではありません。話者間の空白も VAD 区間内の音声として保持し、独立した UNKNOWN gap 行は作りません。

空の話者 ID、非有限または 0〜1 の範囲外の confidence、負の開始位置、逆転・ゼロ長、音声全体の範囲外の話者 span は明示エラーです。FluidAudio adapter が最終 window padding を処理した後も、確定パイプラインは音声範囲を厳密に検証し、範囲内へ黙って切り詰めません。

重なり発話を話者分離したことは、混合音声から各人の声を分離したことを意味しません。本文を文字数比で二人へ配分する処理もありません。

## 話者ラベルと見出し

話者ラベルは確定 run の raw 話者 ID を最初の開始フレーム順に並べ、同時刻なら raw ID の辞書順で決めます。最初の 7 人を `Speaker 1`〜`Speaker 7`、8 人目以降を `OTHER` とします。`OTHER` は一人の人物を意味しません。番号は同一確定 run 内で固定し、再処理では振り直せます。

話者分離前のライブには見出しを出しません。話者分離後の行の見出しは次の **80% ルール**を使います。

1. 行と重なる話者 span の時間を話者 ID ごとに足します。
2. 全話者の重なり時間の合計を分母にし、一人が 80% 以上ならその人だけを見出しにします。分母は行全体の長さではありません。同時発話の時間は各話者の分として数えます。
3. 80% 未満なら、該当するラベルを登場順に「Speaker 1 / Speaker 2」のように併記します。同じ表示ラベルは重複させません。
4. 重なる有効な span がなければ `UNKNOWN` です。

画面では同じラベル集合が連続する行の見出しを繰り返しません。`transcript.txt` は画面と同じ行集合・話者ラベルを使い、各発話を「[mm:ss] Speaker 1 / Speaker 2: 本文」の一行で書き出します。本文内改行は空白にし、フィラー・相槌除去と保存済み LOW 発話文の除去を反映した表示本文を書き出します。表示本文がある認識済み行はすべて表示・書き出しの対象です。ASR の原文と CLI JSON の `text` は表示用の除去で変更しません。話者分離前の暫定本文はこの形式では書き出せません。

## ASR の成功・空本文・失敗

`asr.completed` は `outcome: recognized` または `empty` を持ちます。空白・改行・句読点（Unicode の句読点文字）だけなら `empty` です。空本文区間もイベントには残りますが、画面、`transcript.txt`、`segments.json` の公開ビューには出しません。特定の失敗定型文との文字列一致では除外しません。

`asr.failed` は `engine_unavailable`、`audio_unreadable`、`transcription_failed` の kind と原因メッセージを持ちます。モデル準備、音声読取、認識、イベント保存の失敗は確定 run の公開失敗につながります。ASR 区間ごとのタイムアウトを独立した失敗 kind として保存する仕組みはありません。

## 実装の根拠

- [確定パイプラインと FinalTranscriptVADSegmenter](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift)、[確定 VAD adapter](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidFinalTranscriptVADSegmenter.swift)、[共通 VAD engine](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADSegmentationEngine.swift)、[共通入口・公開・保持](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)、[ASR の一時停止・失敗・計測](../app/MacAmbientJev/Sources/MacAmbientJevCore/PipelineCoordinator.swift)、[区間組み立て](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift)、[FluidAudio 0.15.8 のストリーミング VAD](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/VAD/VadManager+Streaming.swift)
- [処理 metadata](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)、[復旧判定](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecoveryScanner.swift)、[音声 maintenance とキャンセル時の partial 保護](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/RecordingAudioCompactor.swift)、[maintenance の失敗・未完了 item と inference 除外](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingCoordinator.swift)、[finalization の pause・公開・cleanup](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)、[CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)。関連テスト: [型付きキャンセルと compaction 復旧](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/FinalTranscriptPipelineTests.swift)、[detached compactor へのキャンセル転送と音声正本の保護](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingAudioTests.swift)、[maintenance の中断・未処理 item](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingAudioCompactorTests.swift)、[pause 中 cleanup 失敗](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/SessionStorageFinalizationTests.swift)、[起動時 maintenance 失敗の報告と recovery 除外](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LaunchMaintenanceStatusTests.swift)
- [判定 run の provenance・境界／優先度処理・batch](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionEnrichmentCoordinator.swift)、[provider factory とモデル cache](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionProviderFactory.swift)、[Core ML tagger](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)
- [読み込み音声のタイムライン準備](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[話者ラベル](../app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerDisplayMapper.swift)、[FluidAudio 話者分離設定](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidOfflineDiarizationEngine.swift)、[FluidAudio 0.15.8 の OfflineDiarizerConfig](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerTypes.swift)
- [表示 projection](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[画面の見出し](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift)、[テキスト書き出し](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/TranscriptTextRenderer.swift)、[構造化 ASR 結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
