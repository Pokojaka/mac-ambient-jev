# 確定処理・復旧・再処理

最新の durable `pipeline.started` が処理 generation と初期選択 run 群を定めます。録音中に保存した区間・成功 ASR 行は直ちにその generation の transcript に反映され、録音停止・確定処理は同じ generation を完了します。必要な場合、未完了 segmentation は封印済み音声を sample 0 から再生し、保存済み区間 prefix と照合してから不足分だけを保存します。ASR は durable な成功行を再実行せず、未成功区間だけを処理します。任意判定の再試行はイベントログへ新しい run と選択イベントを追記し、既存イベントを書き換えません。

## 共通パイプライン

```text
保存音声の処理タイムライン
  → VAD
  → speech range 群を外側 span 30 秒以内にまとめ、segment.created を保存
  → segment ごとの ASR（Mac: Haas-ja-v1.0 / ONNX Runtime CPU）。成功行は直ちに保存・表示
  → 同じ選択 run pair の任意な境界判定・BTSJ 発話文の組み立て
  → 閉じた発話文を最大 40 件ずつ任意に優先度判定
  → sealed source の segmentation / ASR 完了を確認し generation を complete
```

境界・優先度の判定単位は BTSJ 発話文です。保存 key や内部名の `clause` / `節` はその発話文を識別し、別の節 splitter を意味しません。必須ローカル処理は segmentation・ASR の2段階だけです。Core ML 判定は任意の後段推論であり、必須2段階を増やしません。

音声は `storage.json` を確定処理の開始時に読んで決めます。`recordingPCM` は processing ディレクトリの PCM、`recordingFLAC` は `recording.flac` を全復号して検証した読み取り元として使います。FLAC 状態の録音では PCM が残っていても読みません。保存済みの音声がなければ「保存済みの音声がありません」で開始に失敗します。読み込み音声はアプリ内に保存した original から処理タイムラインを作るため、外部の読み込み元ファイルが残っている必要はありません。

読み込み音声の確定処理は、毎回既存の処理タイムラインを削除し、保存済み original からゼロから作り直してから始まります。作り直した処理タイムラインの長さと欠落記録は `storage.json` に保存し、確定処理の終了時に処理タイムラインを削除します。

ライブと確定処理は共通の `VADSegmentationState` を使い、同じ 4096-sample VAD probability stream chunking（settle・finish を含む）で区間と segment を作ります。確定処理だけの別 regrouping は行いません。VAD threshold はライブと同じです。speech range の規則もライブと同じで、pre-roll 0.10 秒、14 秒到達時の静音位置分割、0.5 秒未満の独立 speech range の除外は変更しません。

エンジン入力は **16,000 Hz・mono・float32 PCM** だけを受け付けます。VAD は保存済み floats を直接読み、ASR loader は speech range のサンプルを変更せず連結し、range 間の gap 音声を含めません。Mac の Haas-ja-v1.0（モデル ID [Sanami/haas-ja-onnx/int8dyn](https://huggingface.co/Sanami/haas-ja-onnx/tree/354baedfd9612b00e74cc1ae87dff7f2c558db6f/int8dyn)、engine `onnxruntime-haas-tdt`）は ONNX Runtime の CPU で固定 4 演算スレッドを使い、16,000 Hz の入力を受け取ります。日本語専用モデルです。20 ms 未満の入力は推論せず空本文を返し、30 秒を超える入力は分割せず拒否します。source frame は original や device ではなく保存タイムラインの座標です。

ASR 区間の実行はライブ・確定処理・ファイル評価で同じ [`PipelineCoordinator.execute`](../app/MacAmbientJev/Sources/MacAmbientJevCore/PipelineCoordinator.swift) を使い、音声読取・認識・pacing・計測・区間結果保存を共有します。録音の live と finalization は `LiveASRSession.finish` が ASR run の完了を保存し、standalone file evaluation は `PipelineCoordinator.run` が完了を保存します。

新 generation の初期 run ID 群は `pipeline.started` に保存します。各 segmentation / ASR run の `processing.run.started` は実際に実行した engine、model、version、configuration を記録します。同じ generation の停止・再開では run ID と既存 provenance を維持し、新 generation へ来歴を引き継ぎません。

検証済み VAD が 0 区間なら segmentation と ASR はそれぞれ成功・件数 0 で完了し、ASR model prepare・推論は行いません。空の transcript も `complete` で、終端表示は「発話区間は検出されませんでした」です。任意判定の対象がないため、判定保留はありません。

VAD の失敗・不正な区間、発話がある場合の ASR の失敗を空の成功結果へ変換しません。最初の ASR 失敗でその処理 attempt を止め、先行して保存済みの成功行は同じ generation に残します。失敗行は pending として起動時に自動再試行しません。録音中の live ASR が失敗していた場合も、停止は処理状態を failed として保存し（`complete` にしません）、失敗区間を未完了のまま残します。明示的な CLI resume は成功済み行を保ち、不足区間だけを処理できます。利用者が再処理を選ぶと空の新 generation を先に durable に選択し、旧 generation の表示行を復元しません。

録音停止は live VAD の入力を封印して残りと EOF tail を処理させた後、`finalize(.reject)` を一件だけ enqueue します。live 専用の要求や live 結果と確定結果を選ぶ分岐はありません。録音が ASR・判定の live worker を保持し、その generation の segmentation が live で完了していれば、同じ worker のまま drain します。保持していない場合（再開、import、復旧、CLI、live VAD の失敗・resource 停止・開始失敗の後）は、同じ drain を event log から開き直した worker で行います。入力の正確な frame count を `segmentation.input.sealed` として固定し、未完了 segmentation だけを sample 0 から再生成して保存済み prefix を検証します（この場合 live worker は使わず、再生成後に開き直します）。segmentation が完了済みなら再実行しません。続いて ASR run の durable な `asr.completed` がない区間だけを処理し、成功済み行は再推論しません。ASR が完了すると、初期 `pipeline.started` の境界・優先度 run pair を同じ incremental worker（live の判定 session、なければ開き直した session）で `finishInput` し、終端を解放して drain します。新しい確定 batch pass はありません。任意判定の失敗・保留は local transcript の `complete` を遅らせず、pending target として残ります。本文のある終端 source は候補境界がなくても F・B除去用 source-only 推論を行います。各 `processing.run.started` provenance は実際にロードした model identity を示し、request record は実推論 request の ID と入力 token 数を記録します。[発話文判定](decision-engine.md)

## 増分保存と任意の発話文判定

`pipeline.started` は generation の初期 run ID 群を durable に選びます。`processing_metadata.json` は `generation_id`・status・failure reason を管理し、scanner / 状態表示にだけ使います。run や transcript は選択しません。保存済みイベントと最新の generation marker から作る行は、segment 登録・ASR 成功ごとに materialize して表示します。公開待ちの別 transcript はありません。

segmentation と ASR の完了・sealed frame count・run 完了数を検証してから generation を `complete` にします。任意の境界・優先度判定は同じ初期 run pair の増分 worker が保存した結果を順次表示し、pending target が残っても成功したローカル transcript を無効にしません。イベント保存や metadata 書込の失敗はエラーで、durable な選択済み行を巻き戻しません。

モデル初期化・符号化・判定結果検証の失敗は該当する任意判定を pending にし、成功した ASR 行と transcript を保持します。境界 pending は分割を作らず、優先度 pending は本文を除きません。任意判定の失敗は segmentation / ASR の完了状態を取り消しません。

CLI の `ContentPriorityAccess.disabled` は判定 run pair を作らず、必須 segmentation / ASR のみを実行します。この処理には保存済み境界評価・優先度評価がないため、`display_text` はフィラー・相槌や LOW を除かず、RAW ASR 原文に表示用の数字表記変換を適用した本文です。ASR とイベントは変更しません。任意判定 pending は通常の transcript 表示・書き出しを妨げません。判定込みの `segments.json` 書き出しは、選択済み run pair が完了し pending target がない場合だけ成功します（[書き出し](export.md)）。

任意判定は初期 pair を増分使用します。判定の再試行は別 run を作り、その結果が `pipeline.decisions.replaced` として durable になった時点で選択を切り替えます。以前の run / event は不変で、未選択の replacement 結果を表示しません。各 `processing.run.started` provenance は実際にロードした engine/model/revision、request record は実推論 request の ID と入力 token 数を示します。候補のない終端 source も source-only window で推論します。

ASR の計測 phase は推論完了時に終了します。その後の `postprocessing` phase は保存済み結果の検証、表示の組み立て、metadata の公開、および**任意の Core ML 発話文判定**を含みます。これは必須ローカル推論段階ではなく、必須の segmentation・ASR の2段階は変わりません。

保存済み判定・origin 参照の破損、不整合、イベントログ破損、イベント保存・metadata 書込失敗は pending に変換せず処理エラーとして報告します。既に durable な選択済み行・判定イベントは保持し、未保存の結果や未選択 replacement を表示しません。

| 結果 | 永続状態と表示 |
| --- | --- |
| segmentation / ASR 成功 | 同じ generation を `complete` にし、成功した行と任意判定の現在状態を表示 |
| 熱による一時停止・型付きキャンセル | `paused` を durable に保存し、同 generation の保存済み行を保持。再開時は不足段階だけを進める |
| 必須段階の失敗 | `failed` と理由。保存済み部分行は残り、起動時に自動再試行しない |
| 任意発話文判定の失敗・pending | 必須処理の `complete` と表示行を維持し、pending target を利用者の再試行まで保持 |
| 完了後の録音 compaction 中断 | `complete` と transcript を維持。検証済み音声の切替・PCM 整理を次回起動時に再開 |
| イベント保存・metadata 書込失敗 | エラーを報告。既に durable な選択済み行・判定状態は保持 |

型付きキャンセルや熱による一時停止は推論失敗に分類せず、`paused` metadata の保存を試みます。現在選択中 generation の durable な segmentation・ASR 行を保持し、未公開の推論結果は表示しません。起動時 scanner は `running` / `paused` を同じ generation の `finalize` として再投入し、segmentation が未完了なら封印済み音声から再生成して prefix を照合し、成功済み ASR 行を保ったまま不足区間を処理します。metadata の保存に失敗した場合は中断理由と保存エラーを報告し、既存 metadata を `failed` に書き換えません。`paused` が durable なのは metadata 保存に成功した場合に限られます。

任意判定の pending は必須 transcript の完了を妨げず、起動時に自動再試行しません。利用者の再試行は durable な選択済み結果を入力に新しい decision run を追記し、replacement event が保存された後だけ最新 run pair を切り替えます。開始済みだが未選択の decision run で中断した場合は scanner が `recoverDecisionRun` を返し、起動時に判定だけを回復します。pending snapshot の `retryContentPriority` は設定からの明示操作だけで実行します。いずれも segmentation・ASR はやり直しません。

録音の PCM compaction は、必須 segmentation / ASR が完了し、sealed source と frame count を検証して generation を `complete` にした後だけ行います。ライブ中・未完了 generation は compact しません。compaction 中断時も `complete` と transcript を保ち、起動時は `compactRecording` maintenance を再開して VAD・ASR をやり直しません。完了録音を `recording.flac` へ変換し、FLAC を検証してから `storage.json` の音声正本を切り替え、その後 PCM を削除します。finalization の親 task のキャンセルは detached compactor に転送され、各境界で PCM または検証済み FLAC を保持します。FLAC の録音の再処理は再符号化しません。

セッション情報を読めない開始失敗を除く全ての結果で、確定処理は終了時に一度だけ一時音声（FLAC の partial と、import の処理タイムライン）を削除します。型付きキャンセル以外の変換・一時音声削除エラーは成功結果も `failed` とし、公開済み transcript と元の run error があればその両方を保持・報告します。一時停止後の削除失敗は `paused` を維持し、元の一時停止理由と cleanup error の両方を状態文へ残します。詳細は [保存形式](storage.md) を参照してください。

途中失敗・一時停止でも、ASR 段階で得た計測値を処理結果に残します。ASR 開始前の失敗・キャンセルでは ASR 計測値はありません。

## 発熱による一時停止と再開

アプリは critical の間、確定処理の開始をキューに保留します。ただし同じ generation に durable な ASR 失敗があるときは保留せず、処理へ進めて `failed` を保存します（推論は走りません）。失敗の有無を読めないときは保留します。実行中は各 ASR 区間で、ライブ ASR と同じ共有 gate（`ThermalMonitoring.inferenceGate`、判定は `LiveASRThermalPolicy`）を2点で通します。区間境界（`InferenceGatePoint.segmentBoundary`）では音声を読む前に、待機せず有効な保留だけを確かめます。保留中ならその区間の音声を読まず、読めない chunk があっても `asr.failed` にせず止まります。音声を読み込んだ後、推論の直前（`dispatch`）が唯一の待機つき判定で、`serious` は 750 ms 待機してから判定し直します。どちらの点でも `critical` または状態不明は中断した attempt を実際の理由つきで `paused` として保存します。境界を通った区間の読み込みで実際の I/O エラーが起きたときは、その場で `audioUnreadable` の失敗になります。保留の理由は公開する直前に決め、その時点でキャンセルかアプリの一時停止が効いていれば、熱や resource の理由があっても `paused` として保留します（dequeue 時の失敗確認中に届いた一時停止も同じです）。保留へ移すとき、その理由が既に終わっていれば（冷却済みなど）次の熱変化を待たずに再開します。dequeue 後に熱が上がり live worker が冷却待ちになった場合、確定処理は live worker を残したまま `thermal` 保留にして、キューの後続を止めません（冷却後は再び live worker の drain を待ちます）。保留中に live worker が durable な ASR 失敗を報告したら、その確定処理を保留から戻して判定し直し、推論なしで `failed` にします。報告が保留を決めている最中に届いた場合も、保留へ移した直後に同じく戻します。「発熱のため確定処理を一時停止中」と表示し、`failed` にはしません。

確定処理（`finalize`）は ASR と VAD の2モデルが ready になるまで開始しません。未取得・取得中・照合中・読み込み中・失敗の間は要求を `modelHeld` に保留し、reprocess claim と FIFO 順を保持します。熱の保留だけは取り出した時点で判定し、live worker を残したまま保留します。それ以外の保留は、live ASR task の終了を待った後の一点で一度だけ判定します。まず同じ generation の durable な ASR 失敗を読み、失敗があれば保留せず処理へ進めて `failed` を保存・表示します（shutdown のキャンセルでも `paused` にしません）。読み取りに失敗した場合は失敗とみなさず、次の判定へ進みます。その後でキャンセル・一時停止・resource 圧力・model 準備を読み、該当すれば保留先へ入れてから live worker を後始末し、VAD を始めません（model 未準備は `modelHeld`）。後始末中に model が ready になれば、同じ drain がその要求を処理します。model 待ちは処理の結果ではないため、要求の完了を待つ呼び出し（Windows の `session.reprocess` など）は実際に処理されるまで待ち続けます。どれにも該当しなければ処理へ進み、処理が event log を読み直して途切れた末尾を修復するか、読み取りエラーを失敗として報告します。処理結果はエラーの種類で決まり、キャンセルのエラーだけが `paused` になります。読み取り・検証のエラーは、途中で shutdown のキャンセルが届いても `failed` です。live VAD が失敗した録音は segmentation を完了扱いにせず、stop が保存済み VAD を再実行します。live worker は ASR・segment の状態が event log と一致するときだけ保持します。PCM 録音の checkpoint が無い場合はエラー、frame 数 0 の有効な checkpoint は空の録音として扱います（復旧 scanner も同じ規則です）。再開時はイベントログの最新 generation から開き直します。ready 後は同じ generation の保存済み結果を使い、未完了段階だけを進めます。取得・照合・読み込みの失敗は理由を表示し、自動再試行しません。再試行は設定の「モデルを取得」だけです。熱による保留とは別の queue で、両方の条件を満たしたときだけ実行します。

熱状態が critical を下回ると、アプリは熱で保留した要求を元の順序で自動再開します。別の要求を処理中でも、保留していた要求はその場で `pending` の先頭へ移り、保留後に積まれた要求より先に処理されます（2本目の drain は始めません）。利用者が文字起こし処理を一時停止している場合は再開しません。キャンセルやアプリの一時停止で止まった要求は `paused` という別の理由で保留し、熱や resource の状態が変わっても動かさず、明示的な再開（`resumeHeldProcessing`）でだけ戻します。同じ generation の segmentation が未完了なら封印済み音声を再生して保存 prefix を照合し、ASR は成功済み行を再実行せず不足区間だけを処理します。進行中のモデル推論を途中で強制中断するものでも、VAD の処理に区間ごとの熱中断を設けるものでもありません。

`MacAmbientJevProcessRecording` の file import、`--inspect-session`、`--resume-session` の全てで `--sessions-root DIRECTORY` は必須です。CLI は保存場所を暗黙に選ばず、root を検証してからセッション検索・作成・モデル処理を始めます。

Mac の CLI に開始時の熱 gate はありません。通常の import / resume は各 ASR 区間の直前にアプリと同じ共有 gate を通し、`serious` では 750 ms 待機して判定し直し、`critical` または状態不明では `paused` を保存して非 0 終了します。計測 run（`--run-id`、`--metrics-output`、`--thermal-output`、`--memory-output` の4つを指定）は計測結果を変えないよう `RunMonitor` の判定を使い、`critical` の間だけ同じく pause します。どちらも冷却後に `--resume-session` で再開します。CLI のプロセスが冷却を待って自動再開するわけではありません。

## リソース監視による確定処理の保留

`SessionProcessingCoordinator` は初期化時に optional `resourceMonitor` と optional `releaseResources` closure を受け取ります。`resourceMonitor` が設定されている場合、監視状態は新しい確定要求をモデル準備前に通すか決めます。`resourceMonitor: nil` は monitor 未設定であり、`.healthy` を観測した意味ではありません。保留は推論の理由（`thermal`・`resourcePressure`・`monitorFailed`）またはキャンセル・一時停止による `paused` を持つ単一の held queue に入ります。熱と resource の状態変化、drain の終了時の再判定は、理由が終わった推論の保留だけを動かします。
resourcePressure / monitorFailed の表示はそれぞれ「メモリ不足のため確定処理を一時停止中」「リソース監視に失敗したため確定処理を一時停止中」です。実行中の処理は既存の安全な ASR 区間境界で一時停止し、decoder step や VAD window の途中では中断しません。
`NativeSessionProcessor` が戻った後、設定された `releaseResources` closure でモデル解放を行います。一時停止 metadata は既存経路で保存し、既に公開した結果は保持します。
healthy になると、held 要求を FIFO 順でキュー先頭へ戻します。確定処理は同じ generation の durable segmentation / ASR 状態から再開し、成功済み ASR 行を再実行しません。明示 pause / cancellation 中は再開しません。`monitorFailed` は healthy と見なさず、温度状態も作りません。
Mac の [`AppState`](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift) は `resourceMonitor: nil` を明示します。Windows Engine の [`EngineProcess`](../app/MacAmbientJev/Sources/MacAmbientJevEngine/EngineProcess.swift) は [`WindowsInferenceResourceMonitor`](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/WindowsInferenceResourceMonitor.swift) を生成し、[`EngineApplication`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineApplication.swift) が live と確定処理の coordinator に渡し、`releaseResources` から gateway の `releaseIdleResources()` を呼びます。Windows Engine は実行中の確定処理が境界で一時停止するまで、表示に「（実行中の処理の終了待ち）」を付けます。NDJSON に専用の command や field はなく、状態は既存の `processing_status_text` だけで示します。[SessionProcessingCoordinator](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingCoordinator.swift)、[SessionProcessingQueue](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingQueue.swift)、[monitoring protocol](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/InferenceResourceMonitoring.swift) を参照してください。
`PauseCheck` と pause outcome は `InferenceHoldReason` を運び、`NativeSessionProcessor.Status.paused(reason)` の表示文は `reason.finalizationExplanation` から得ます。thermal の Mac 表示文は `UserFacingStatus.finalizationPausedForHeat.text` のままで、status string の後処理書換えはしません。

## 復旧と明示的な再処理

イベントログの最新 `pipeline.started` が generation と必須 run selection を決めます。decision selection は初期 pair に始まり、最新の durable `pipeline.decisions.replaced` で更新します。`processing_metadata.json` は generation ID と status のみを記録し、run / row selection には使いません。

| 保存状態 | 復旧 action |
| --- | --- |
| generation status が `running` / `paused` | `finalize`。同じ generation の未完了段階を続ける |
| generation がなく、保存音声あり | `finalize`。新 generation を作成 |
| status が `failed`、または未解決 ASR failure | 起動時に自動復旧しない |
| `complete`、replacement decision run が selection event 前に durable | `recoverDecisionRun`。起動時に判定だけを回復 |
| `complete`、選択済み run に pending decision target | `retryContentPriority`。自動復旧せず、利用者の再試行待ち |
| その他 | 復旧対象なし |

録音・読み込みの確定処理では、sealed frame count が保存音声と完全一致することを要求します。未完了 segmentation は sample 0 から再生し、生成した全 segment prefix を durable な `segment.created` と照合して不足分だけ追記します。完了済み segmentation は呼び出しません。ASR は成功済み `asr.completed` を維持し、未成功区間だけを再開します。最初の ASR failure は attempt を止め、保存済み部分行を残します。

`recoverDecisionRun` と `retryContentPriority` は decision のみを扱い、VAD / ASR を再実行しません。起動時は `finalize` と `recoverDecisionRun` を queue に入れます。`retryContentPriority` は設定の「保留中の判定を再試行」だけが実行します。判定の再試行は既存イベントを変更せず新 run の events を追記し、`pipeline.decisions.replaced` が durable になった後だけ選択を切り替えます。replacement event 前に残った run の部分結果は表示しません。

読めないセッションは理由付きで報告します。events と `processing_metadata.json` は `schema_version: 4` だけを受け付け、version の欠落・未対応は明示的な再処理でも拒否します。自動復旧は読めない metadata を上書きしません。利用者の明示的な再処理は未対応 version 以外の破損した処理 metadata を置き換え、先に空の新 `pipeline.started` generation を durable に選択してから推論します。旧 generation の行・ログ payload を display 側へ復元しません。派生結果が破損でも保存音声が使えれば再処理できますが、原音声や録音 timeline の破損は解消しません。

復旧 scanner は非表示・manifest 欠損を含む root 直下の全ディレクトリを調べ、保存フォルダー名と manifest を検証します。同じ完全 UUID が複数フォルダーにある場合は全て復旧失敗として報告し、自動処理へ投入しません。`running` / `paused` は `finalize` として同 generation から再開します。sealed source の segmentation / ASR が検証済みで `complete` でも録音 PCM や一時ファイルが残る場合は transcript 推論と別に `compactRecording` / `removeTransients` maintenance を返します。ライブ中・未完了音声の compaction はありません。起動時は maintenance を先に実行し、その session の maintenance が成功するまで inference recovery から除外します。maintenance の実エラーは `SessionMaintenanceIssue.failed`、shutdown cancellation で未完了の現在 item と残りの item は `interruptedByShutdown` として UUID と理由を記録し、成功済み item は結果に含めません。中断理由は終了処理による中断と次回起動時の再実行を明示し、disk error として扱いません。maintenance 成功後にのみ inference recovery へ進みます。詳細は [保存形式](storage.md) を参照してください。

### CLI の復旧インターフェース

実行 target は `MacAmbientJevProcessRecording` です。セッション UUID を SESSION_ID、セッション保存ルートを SESSIONS_ROOT、セッション内部とは異なる出力先を SEGMENTS_OUTPUT に設定して使います。

```bash
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --inspect-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT"

swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --resume-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT" "$SEGMENTS_OUTPUT"
```

`--inspect-session` は読み取り専用で、JSON に `action`（`finalize`、`recoverDecisionRun`、`retryContentPriority`、`none`、`unrecoverable`）と `maintenance`（`compactRecording`、`removeTransients`、`null`）を出します。音声欠損は `unrecoverable`、その他の読取不整合はエラーになります。`--resume-session` は先に保存整理（`maintenance`）を実行し、もう一度調べた結果の `action` に従います。`finalize`（録音・読み込み）は再開します。CLI の `ContentPriorityAccess.disabled` は Core ML tagger による判定を無効にし、必須のローカル2段階だけを実行するため、`recoverDecisionRun` と `retryContentPriority` は判定せず公開済みの結果を書き出します。通常処理・再開とも `--low-heat` で ASR 区間の間に 2 秒の待機を入れられます。

ID は manifest の完全 UUID から実フォルダー URL に解決します。不在・複数一致・フォルダー名の不整合はエラーで、`none` は存在する正常セッションの action がない場合に限ります。resume は実行時に実フォルダーを解決して出力先を検査し、symlink と大文字小文字の違いを考慮してセッション内部への出力を production engine の処理前に拒否します。

## ASR 区間

利用可能な speech range を、最初の range の開始から追加 range の終了までの外側 span が30秒以内なら一 segment にまとめます。Mac の確定処理では一 segment は Haas の一回の呼び出しと transcript row 一つに対応します。ASR loader は speech range の音声だけを連結し、range 間の gap 音声は読みません。行の開始・終了時刻は segment の最初の range の開始・最後の range の終了です。

画面と `transcript.txt` は同じ表示本文を使い、表示本文がある行を「[mm:ss] 本文」の一行ずつで書き出します。本文内改行は空白にし、フィラー・相槌除去と保存済み LOW 発話文の除去を反映します。ASR の原文と CLI JSON の `text` は表示用の除去で変更しません。

## ASR の成功・空本文・失敗

`asr.completed` は `outcome: recognized` または `empty` を持ちます。空白・改行・句読点（Unicode の句読点文字）だけなら `empty` です。空本文区間もイベントには残りますが、画面、`transcript.txt`、`segments.json` の公開ビューには出しません。特定の失敗定型文との文字列一致では除外しません。

`asr.failed` は `engine_unavailable`、`audio_unreadable`、`transcription_failed` の kind と原因メッセージを持ちます。モデル準備、音声読取、認識、イベント保存の失敗は確定 run の公開失敗につながります。ASR 区間ごとのタイムアウトを独立した失敗 kind として保存する仕組みはありません。

## 実装の根拠

- [確定パイプラインと FinalTranscriptVADSegmenter](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift)、[確定 VAD adapter](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidFinalTranscriptVADSegmenter.swift)、[共通 VAD engine](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADSegmentationEngine.swift)、[共通入口・公開・保持](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)、[ASR の一時停止・失敗・計測](../app/MacAmbientJev/Sources/MacAmbientJevCore/PipelineCoordinator.swift)、[区間組み立て](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift)、[FluidAudio 0.15.8 のストリーミング VAD](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/VAD/VadManager+Streaming.swift)
- [処理 metadata](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)、[復旧判定](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecoveryScanner.swift)、[音声 maintenance とキャンセル時の partial 保護](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/RecordingAudioCompactor.swift)、[maintenance の失敗・未完了 item と inference 除外](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingCoordinator.swift)、[finalization の pause・公開・cleanup](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)、[CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)。関連テスト: [型付きキャンセルと compaction 復旧](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/FinalTranscriptPipelineTests.swift)、[detached compactor へのキャンセル転送と音声正本の保護](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingAudioTests.swift)、[maintenance の中断・未処理 item](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingAudioCompactorTests.swift)、[pause 中 cleanup 失敗](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/SessionStorageFinalizationTests.swift)、[起動時 maintenance 失敗の報告と recovery 除外](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LaunchMaintenanceStatusTests.swift)
- [判定 run の provenance・境界／優先度処理・batch](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionEnrichmentCoordinator.swift)、[provider factory とモデル cache](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionProviderFactory.swift)、[Core ML tagger](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)
- [読み込み音声のタイムライン準備](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)
- [表示 projection](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[画面の表示](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift)、[テキスト書き出し](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/TranscriptTextRenderer.swift)、[構造化 ASR 結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
