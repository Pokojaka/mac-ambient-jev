# セッション保存形式

保存音声は再処理の基礎であり、文字起こし・話者・場面・音響範囲・優先度は派生結果です。派生結果は追記専用のイベントログに残し、処理 metadata が選ぶ run だけを現在の結果として公開します。処理の流れは [architecture.md](architecture.md) を参照してください。

以下の表は **JSON 上の実際のキーと値**です。イベントと処理 metadata は snake_case のキーを使いますが、checkpoint と音声用 JSONL は camelCase です。String enum の値はキー変換の対象ではなく、`contentPriority`、`lowPriority`、`discussionCandidate` などは camelCase のままです。

## 保存場所とセッションフォルダー

GUI アプリは sandbox 内で動作し、標準のセッション保存先は `~/Library/Containers/app.mac-ambient-jev/Data/Library/Application Support/mac-ambient-jev/sessions` です。全てのセッション CLI は各モードで `--sessions-root DIRECTORY` を必須とし、CLI が既定保存先を選ぶことはありません。非 sandbox の `~/Library/Application Support/mac-ambient-jev/sessions` とその cache、および sandbox 側の app data/cache は CLI の保護対象です。明示 root はこれらの領域と祖先・子孫関係にならず、symlink 経由でも重ならない必要があります。各 Application Support の mac-ambient-jev 以下に sessions と models、各ユーザーの Caches 以下の mac-ambient-jev にキャッシュを置きます。`AppPaths` は sessions の root を上書きできます。App の設定は UserDefaults / AppStorage、Jev API キーは Keychain にあり、セッション JSON のフィールドではありません。

フォルダー名は `YYYY-MM-DD_HH-mm-ss_<stem>_<UUID先頭8桁の小文字hex>` です。作成時に一度取得した日時を、明示した time zone のローカル時刻として Gregorian calendar・`en_US_POSIX` で表します。年は ASCII 4 桁（0001–9999）。アプリと CLI は `.current` を渡します。マイク・システム音声の録音は stem が `録音`、読み込みは元ファイル名の最後の拡張子を除いた stem です。

stem の `/` と `:` は `-`、先頭の `.` は `-` に置換します。固定部分は UTF-8 29 byte、stem は Swift Character の境界で 226 byte 以下に切り詰め、全体を 255 byte 以下にします。合成文字は分割せず、manifest の元ファイル名は正規化・変更しません。NUL、空の stem、最初の Character が上限に入らない名前、形式で表せない日時は明示エラーです。同名の既存フォルダーは上書きしません。名前の辞書順は作成時に記録したローカル時刻順であり、DST や time zone の変更をまたぐ UTC 順ではありません。

セッション identity は `session.json` の **完全な UUID** です。`SessionLayout` は実際の `sessionURL` だけを受け取り、ID から URL を生成しません。`SessionDirectoryLocator` は root 直下の全ディレクトリの manifest を読み、完全な UUID の一致を数えます。0 件は `notFound`、複数件は名前順のフォルダー一覧付き `multipleMatches`、1 件は名前の検証後に URL を返します。無関係な壊れた manifest は identity を提供しません。一致した manifest のフォルダー名が不正なら、その検証エラーを返します。

lookup・一覧・復旧は列挙で得た実フォルダー名を使い、指定された root URL の表記を保ちます。作成時に返した URL と、同じ root から取得した行・lookup の URL は同じ identity として扱えます。

読み取りでは固定 19 byte の日時と最後の `_` に続く小文字 ASCII hex 8 桁を解析し、日時の Gregorian 妥当性、manifest UUID の接頭辞、同じ規則で算出した source stem を検証します。日時の妥当性は読み取り時のローカル time zone に依存しません。フォルダーの日時と `created_at` は比較せず、読み取り時に作成日時や ID から名前・URL を再計算したり、フォルダーを改名したりしません。

一覧と復旧は非表示を含む全直下ディレクトリを対象とし、通常ファイルは対象外です。manifest の欠損・破損、名前の不正、UUID 接頭辞・source stem の不一致はフォルダーごとのエラーとして表示し、健全な他のセッションは処理を続けます。同じ完全 UUID の複数フォルダーは全て読み込みエラー・復旧失敗とし、二重に処理しません。保存済み一覧の行 identity と選択は URL。壊れた manifest に UUID を捏造せず、読み取れた UUID だけを保持します。正常行の再処理・書き出し操作は UUID を使います。

根拠: [SessionFolderName.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionFolderName.swift)、[SessionDirectoryLocator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionDirectoryLocator.swift)、[SavedSessionCatalog.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SavedSessionCatalog.swift)。

セッションの構成は次のとおりです。これは生成されるファイル配置であり、リポジトリ内のファイルではありません。

```text
2023-11-15_07-13-20_録音_0123abcd/
├── session.json
├── events.jsonl
├── processing_metadata.json          処理開始後
└── audio/
    ├── original.<元の拡張子>          import のみ。拡張子なしなら original
    ├── processing/
    │   ├── checkpoint.json
    │   ├── audio-chunks.jsonl
    │   ├── audio-gaps.jsonl
    │   └── chunk-000000.f32le ...     0 始まりの連番
    └── derived/
        └── diarization-input.caf     発話区間のある確定処理の話者分離入力
```

- 録音では処理タイムライン自体が保存音声です。入力の全 channel を平均した mono の 32-bit float PCM を保存します。sample rate は録音開始時の形式です。
- import では元ファイルを無再圧縮コピーした `original` または original に元の拡張子を付けたファイルが保存音声です。audio 直下の該当する通常ファイルは **ちょうど 1 つ**必要です。0 個または複数個ならエラーです。元の外部ファイルを再処理の入力にはしません。
- import の処理タイムラインは派生物で、元ファイルの sample rate と channel 数を保持した interleaved float PCM です。`processImportedSession` は確定処理のたびに処理タイムラインを削除し、保存済み original から作り直します。そのため処理タイムラインが壊れていても、original が無傷なら再処理できます。
- `derived` の CAF は処理用の派生音声です。録音の書き出し音声は 24-bit FLAC、import の書き出し音声は original のコピーであり、内部 PCM chunk と外部書き出しは別物です。

根拠: [AppPaths.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AppPaths.swift)、[SessionLayout.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionLayout.swift)、[AudioImporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioImporter.swift)、[AudioCaptureEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevCapture/AudioCaptureEngine.swift)、[TimestampedMonoSink.swift](../app/MacAmbientJev/Sources/MacAmbientJevCapture/TimestampedMonoSink.swift)、[AudioFileTimelineBuilder.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[SessionExport.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/SessionExport.swift)。

## session.json

`SessionManifest` を atomic write します。全フィールドは次の 5 種です。source は JSON の nested object ではなく、この形に分解されます。

| キー | 型 | 条件・意味 |
| --- | --- | --- |
| `session_id` | UUID 文字列 | 必須。完全なセッション identity。先頭 8 桁を小文字にした値がフォルダー名の末尾と一致する |
| `created_at` | ISO 8601 文字列 | 必須。セッション作成時刻。import では読み込み時刻 |
| `source_kind` | String | 必須。`recording` または `imported` |
| `capture_source` | String | recording で必須。`microphone` または `systemAudio`。import の書き込みでは出力しない |
| `original_filename` | String | imported で必須、空文字は不正。元ファイルの拡張子を含む名前。recording の書き込みでは出力しない |

録音元と元ファイル名は `SessionSource.recording(CaptureSource)` / `.imported(originalFilename:)` で表現します。import を microphone として保存する形式ではありません。manifest に schema version フィールドはありません。

根拠: [SessionManifest.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionManifest.swift)、[SessionBootstrapper.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionBootstrapper.swift)、[SessionRecoveryScanner.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecoveryScanner.swift)。

## events.jsonl

### 共通 envelope

1 行は 1 発話ではなく 1 イベントです。`SessionWriter` が JSON に LF を付けて append し、書き込みごとに synchronize します。actor とファイルの排他ロックを使い、別 writer によるサイズ変更を検出したら末尾を読み直します。

| キー | 型 | 意味 |
| --- | --- | --- |
| `event_seq` | UInt64 | 必須。セッション内のイベント番号。新しい append は最後の番号 + 1、最初は 1 |
| `event_id` | UUID 文字列 | 必須。イベントごとに生成 |
| `event_type` | String | 必須。下記のイベント種別 |
| `schema_version` | Int | 必須。writer が出す値は 1 |
| `session_id` | UUID 文字列 | 必須。所属セッション |
| `processing_run_id` | String | optional。処理段階の run ID |
| `segmentation_run_id` | String | optional。区間が所属する segmentation run ID |
| `segment_id` | String | optional。区間 ID。run 内の区間を識別する |
| `source_start_frame` | Int64 | optional。保存タイムライン上の開始フレーム、または場面転換位置 |
| `source_end_frame` | Int64 | optional。保存タイムライン上の終了フレーム（含まない） |
| `created_at` | ISO 8601 文字列 | 必須。イベント生成時刻。音声時刻ではない |
| `payload` | 種別ごとの JSON | 必須。object のほか、場面では String |

optional の nil は writer の JSON から省略します。音声区間の共通座標は `[source_start_frame, source_end_frame)` です。sample rate は checkpoint を参照します。イベント順序は `created_at` ではなく `event_seq` で扱います。場面を音声時刻へ適用するときは frame 順、同一 frame ならイベント順です。

根拠: [EventEnvelope.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/EventEnvelope.swift)、[SessionWriter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionWriter.swift)、[Materialization.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)。

### イベント種別と payload

表中の run は `processing_run_id`、seg run は `segmentation_run_id`、範囲は envelope の source frame です。

| `event_type` | envelope の付加情報 | `payload` の全フィールド |
| --- | --- | --- |
| `processing.run.started` | run | `stage`: String、`provenance`: 下記の object |
| `processing.run.completed` | run | `stage`: String、`succeeded`: Bool、`completed_count`: Int、`failed_count`: Int |
| `segment.created` | seg run、segment、開始・終了範囲 | 空 object `{}` |
| `asr.pending` | run、seg run、segment、開始・終了範囲 | 空 object `{}`。確定処理でのみ出力する |
| `asr.completed` | run、seg run、segment、開始・終了範囲 | `text`: String、`detected_language`: optional String、`engine`: String、`model`: optional String、`outcome`: `recognized` または `empty` |
| `asr.failed` | run、seg run、segment、開始・終了範囲 | `kind`: 下記の失敗種別、`message`: String |
| `speaker.span` | run、開始・終了範囲 | `speaker_id`: String、`start_frame`: Int64、`end_frame`: Int64、`confidence`: optional Double |
| `scene.changed` | run、開始フレームのみ | **文字列そのもの**。`unknown`、`lecture`、`discussionCandidate`、`discussion`、`lectureCandidate` |
| `scope.span` | run、segment、開始・終了範囲 | `start_frame`: Int64、`end_frame`: Int64、`scope`: `near` / `background` / `unknown`、`confidence`: Double |
| `content_priority.assigned` | run、seg run、segment | `priority`: `primary` / `lowPriority`、`needs_retry`: Bool、`decision`: 下記の object |
| `content_priority.pending_retry` | run、segment | 空 object `{}` |

`stage` の raw value は `segmentation`、`asr`、`diarization`、`scene`、`scope`、`contentPriority` です。metadata のキー `content_priority` と、stage の値 `contentPriority` を混同しないでください。

`asr.completed.outcome` は本文の前後の空白・改行を除いた結果が空なら `empty`、それ以外は `recognized` です。`engine` と `model` は認識した実エンジンの provenance から取ります。本番の engine は `qwen3-asr-swift`、外部モデル ID は aufklarer/Qwen3-ASR-1.7B-MLX-8bit です（リポジトリパスではありません）。認識不能を特定の日本語文面との一致で判定しません。

`asr.failed.kind` は `engine_unavailable`（準備できないエンジン）、`audio_unreadable`（区間音声読取失敗）、`transcription_failed`（認識呼び出し失敗）のいずれかです。TIMEOUT の専用種別はありません。

イベントには空本文を含む全区間が残ります。ライブの `segment.created` / `asr.completed` は暫定結果で、確定処理では新しい segmentation / ASR run を作ります。`speaker.span` の ID はエンジンの raw ID で、表示用の Speaker 番号をイベントへ書き戻しません。

`processing.run.completed` の count は段階ごとの処理対象件数です。segmentation / ASR は区間、diarization / scope は span、scene は初期場面を含む転換、contentPriority は分類対象区間を数えます。優先度 run は保留区間があっても `succeeded: true` を出し、`failed_count` に保留数を保存します。これはローカル確定の失敗を意味しません。

検証済み VAD が 0 区間の確定処理では、segmentation / diarization / ASR / scene / scope の各 run に provenance を持つ開始と、成功・完了 0 件・失敗 0 件の完了を保存します。対象がないため `segment.created`、ASR 区間イベント、`speaker.span`、初期場面を含む `scene.changed`、`scope.span` は作りません。derived 内の話者分離入力 CAF を生成・参照せず、保存音声も変更しません。5 run の保存検証後、空の transcript と `complete` を公開し、`active_runs` はすべて新しい run を選択します。再処理でも新しい run を作り、完了した空結果を未完了扱いで自動復旧しません。

根拠: [ActiveRuns.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ActiveRuns.swift)、[ASREventPayloads.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)、[PipelineCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/PipelineCoordinator.swift)、[TranscriptTypes.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptTypes.swift)、[DiarizationCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DiarizationCoordinator.swift)、[SceneCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SceneCoordinator.swift)、[ScopeCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ScopeCoordinator.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[LiveASRSession.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveASRSession.swift)。

### 優先度判定の来歴

`decision` は種類を表すキーを 1 つ持つ object です。

```json
{"classified":{"confidence":0.95,"model":"jev-latest","input_tokens":12}}
```

```json
{"retry_pending":{}}
```

```json
{"carried_over":{"source_run_id":"priority_live_example","source_segmentation_run_id":"seg_live_example","source_segment_id":"live_000001"}}
```

数値とモデル名は形を示す例です。classified の `confidence` は必須、`model` と `input_tokens` は optional です。`needs_retry` は retry_pending の場合にだけ true で、priority は必ず primary です。carried_over は確定本文と一致したライブ判定の再利用、または再試行で送信しない区間に適用し、引き継ぎ元の run・segmentation run・segment ID をすべて残します。ライブの再利用は前後の空白・改行の trim 後の完全一致に限り、同一本文ではイベント順で最新の classified 判定を使います。Jev の LOW_PRIORITY 応答は confidence が 0.90 以上の場合だけ `lowPriority` として公開します。低 confidence の応答でも classified の来歴自体は保存します。

根拠: [JevEnrichmentCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevEnrichmentCoordinator.swift)、[JevDecision.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevDecision.swift)、[JSON 形状のテスト](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/JevEnrichmentCoordinatorTests.swift)。

### run の来歴

`processing.run.started.payload.provenance` の全フィールドは次のとおりです。

| キー | 型 | 意味 |
| --- | --- | --- |
| `engine` | String | 実装・エンジンの名前 |
| `model` | optional String | モデル ID。モデルを使わない段階では省略 |
| `version` | String | 実装または依存 package の version / revision |
| `configuration` | String → String の object | その run の設定。数値も文字列で保存 |

確定処理は新しい run ごとに各 engine から provenance を取り、開始イベントを保存します。以前の run の version や設定は引き継ぎません。現在の本番構成は次のとおりです。

| 段階 | engine / model / version | configuration |
| --- | --- | --- |
| segmentation | `fluidaudio-silero-vad` / FluidAudio の Repo.vad.rawValue / `FluidAudio@0.15.8` | `pre_roll_seconds` = `0.1`、`max_segment_seconds` = `14.0`、`min_silence_seconds` = `0.75`、`minimum_segment_seconds` = `0.02` |
| asr | `qwen3-asr-swift` / 外部モデル ID: aufklarer/Qwen3-ASR-1.7B-MLX-8bit / `speech-swift@c4c2fabbe825a9290c19e2f45d54ca3eae96b003` | `language` = `ja`、`minimum_input_seconds` = `0.02` |
| diarization | `fluidaudio-offline-diarizer` / FluidAudio の Repo.diarizer.rawValue / `FluidAudio@0.15.8` | `config` = FluidAudio の OfflineDiarizerConfig.default |
| scene | `acoustic-scene-state-machine` / model なし / `1` | `window_seconds` = `20.0`、`hop_seconds` = `1.0`、`discussion_candidate_observations` = `8`、`discussion_confirm_observations` = `12`、`lecture_candidate_observations` = `10`、`lecture_confirm_observations` = `15` |
| scope | `proximity-scope-classifier` / model なし / `1` | `evidence` = `timeline-level-and-spectral` |
| contentPriority | `jev` / run の model なし / `1` | `endpoint` = https://api.typesafe.ai/v1/systemone （外部 API URL）、`minimum_demotion_confidence` = `0.9`。応答モデルは区間の classified に保存 |

Jev provenance は実際に優先度 run を始める場合に保存します。ライブ優先度 run は configuration に `mode: live` を加え、暫定判定を逐次保存します。録音停止で取り消す run は完了イベントなしでも保存済み classified 判定を保持します。ライブ run は metadata の active_runs に選ばず、確定処理は独立した content priority run を完了・選択します。App だけが Jev を許可し、CLI の production processor は無効にしています。ライブ ASR は完了イベントへ engine / model を記録しますが、確定処理と同じ各段階の started provenance をライブ ASR run に出すわけではありません。

根拠: [RunProvenance.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/RunProvenance.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[FluidVADSegmentationEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADSegmentationEngine.swift)、[NativeQwen3ASREngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeQwen3ASREngine.swift)、[FluidOfflineDiarizationEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidOfflineDiarizationEngine.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[SceneInference.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SceneInference.swift)。

## processing_metadata.json

`ProcessingMetadataStore` が snake_case JSON を atomic write します。モデル・version 群はここにはありません。

| キー | 型 | 意味 |
| --- | --- | --- |
| `finalization_attempt` | optional object | 最新の確定処理の状態 |
| `active_runs` | optional object | 一括公開された現在の run 集合 |
| `pending_content_priority_segment_i_ds` | String 配列 | Jev 優先度分類の保留区間 ID。**実キーは末尾が `i_ds`** |

`pendingContentPrioritySegmentIDs` に対する Swift `convertToSnakeCase` の結果が `pending_content_priority_segment_i_ds` です。自然な綴りに直したキーではありません。

finalization_attempt の全フィールド:

| キー | 型 | 意味 |
| --- | --- | --- |
| `attempt_id` | String | 確定処理の試行 ID。Swift の CodingKey は `attemptId` |
| `state` | String | `running` / `paused` / `failed` / `complete` |
| `failure_reason` | optional String | failed の理由。running / paused / complete では省略 |

active_runs の全フィールドは optional String の `segmentation`、`asr`、`diarization`、`scene`、`scope`、`content_priority` です。成功判定用の内部集合は JSON に保存しません。

開始時は旧 active_runs と保留 ID を保持したまま running にします。ローカル全段階が成功したときだけ complete と新しい active_runs を同じ write で保存し、旧保留 ID を空にします。その後の Jev 処理では content_priority run と保留 ID を更新できます。failed / paused は旧公開結果を置き換えません。

復旧対象は running / paused の試行、またはまだ active_runs のない保存音声です。復旧は新しい確定 run の全量実行です。failed を自動で無限再試行しません。complete で Jev 保留 ID がある場合は優先度再試行の対象です。読めない metadata は自動復旧時には理由を報告して保持し、利用者の明示的な再処理だけが置換を許可します。

根拠: [ProcessingMetadata.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)、[ActiveRuns.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ActiveRuns.swift)、[SessionRecoveryScanner.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecoveryScanner.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)。

## checkpoint と PCM タイムライン

### checkpoint.json

`AudioCheckpoint` をキー変換なしで保存します。以下はすべて必須で、空の配列も省略しません。

| キー | 型 | 意味 |
| --- | --- | --- |
| `committedFrames` | Int64 | 完全に公開された音声のフレーム数 |
| `sampleRate` | Double | 正の有限 sample rate、Hz |
| `channelCount` | Int | 正の channel 数。録音は 1、import は元の channel 数 |
| `sampleFormat` | String | `float32LE` |
| `chunkFiles` | String 配列 | タイムライン順の chunk basename。重複・空・`.`・`..`・`/` を含む名前は不正 |
| `chunkFrameCounts` | Int 配列 | chunkFiles と同じ長さ。各値は 1〜Int32.max。合計が committedFrames に一致 |
| `gapEvents` | object 配列 | durable 音声内に含まれる欠落記録 |

gapEvents の object は `startFrame`: Int64（0 以上）、`frameCount`: Int64（正）、`reason`: String です。reason の raw value は `missingCallback`、`overflow`、`invalidBuffer`、`stopTail` です。gap は無音補填した範囲であり、時刻を詰めて削除しません。

### 音声用 JSONL と chunk

- `audio-chunks.jsonl`: 1 行が `{"index":0,"frames":24000}` のような commit object。index は 0 始まりの chunk 番号、frames はそのファイルのフレーム数です。
- `audio-gaps.jsonl`: 1 行が `{"startFrame":0,"frameCount":480,"reason":"missingCallback"}` のような gap object。checkpoint の gapEvents と同じ型で、snake_case ではありません。
- chunk の basename は chunk- に 6 桁の index と .f32le を付けたものです。ヘッダーのない little-endian Float32 を channel-interleaved で保存し、期待バイト数は frames × channelCount × 4 です。
- 録音の通常 chunk 長は 0.5 秒、import は 5 秒です。checkpoint / finish ではメモリ上の端数 chunk も flush するため、すべての chunk が同じ長さとは限りません。

chunk を atomic write して synchronize した後、その index を append / synchronize します。gap は補填無音を chunk に入れる前にログへ同期します。checkpoint は atomic write の snapshot です。メモリ上の未 flush 音声は committedFrames に含めません。

読取時には snapshot、chunk index、連続する公開済み chunk を合わせて最新の checkpoint を復元します。snapshot 更新前にクラッシュしても、末尾に完全な連番 chunk があれば取り込みます。各 chunk のサイズ・channel 幅・記録フレーム数を検証し、不一致・欠損は明示エラーにします。gap は実際の durable 範囲まで切り詰め、音声の公開前に残った gap 全体を有効とはみなしません。音声用 JSONL の commit として採用するのは LF 終端の行です。

`ProcessingTimeline` の型は `version`（1）、`sampleRate`、`channelCount`、`sampleFormat` を持ち、frame からミリ秒への変換を定義します。独立した timeline JSON ファイルを保存する方式ではなく、永続音声の自己記述情報は checkpoint にあります。表示時刻は frame × 1000 / sampleRate の小数部を 0 方向に切り捨てます。ASR / VAD 用の mono 化や resampling をしても、イベントの source frame は保存タイムラインの座標です。

根拠: [DurableAudioWriter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DurableAudioWriter.swift)、[ProcessingTimeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingTimeline.swift)、[ProcessingTimelineReader.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingTimelineReader.swift)、[AudioBlockRing.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioBlockRing.swift)、[LiveTranscriptionCadence.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveTranscriptionCadence.swift)、[ASR.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASR.swift)。

## 読取・復旧と公開ビュー

イベント JSONL では、末尾の LF 未終端かつ不正な JSON 行だけを復旧時に無視・切り詰められます。途中の不正行、LF 終端の不正行は破損として扱います。完全な JSON の最終行に LF がない場合、SessionWriter は LF を足して保持します。イベント番号がある行では正の整数であることを検証します。

保存済みセッション一覧は active ASR run がある場合、イベントログを変更せずに読み込み、JSONL と active transcript event payload を検証します。ログが欠損・不正、または不完全な末尾を含む場合は派生結果を破損として表示し、公開 transcript を持たない扱いにします。active transcript がない未処理セッションではログを要求しません。

`EventLogTranscriptReader` は全行の header を読み、必要な既知イベントの run ID を要求します。非 active run や未知のイベント種別の payload は解釈せず、active run の必要フィールドの欠落・型違いはエラーです。ASR outcome と text の不一致もエラーです。`JevRetryAnalyzer` は全 run の優先度 assigned を読み、保留状態を分析します。

`TranscriptMaterializer` が公開 run の区間・ASR・話者・場面・音響範囲・優先度を適用します。CLI の `segments.json` は配列で、各 object の全キーは次のとおりです。

| キー | 型 |
| --- | --- |
| `segment_id` | String |
| `start_ms`, `end_ms` | Int64 |
| `text` | String |
| `scene` | 上記の SceneState raw value |
| `speakers` | object 配列。各 object は `id`: String、`start_ms` / `end_ms`: Int64、`confidence`: optional Double |
| `scope_spans` | object 配列。各 object は `start_ms` / `end_ms`: Int64、`scope`: AcousticScope raw value、`confidence`: Double |
| `content_priority` | optional String。`primary` / `lowPriority` |

空本文区間は公開 JSON・ライブ表示・テキスト書き出しに出しません。イベントログからは削除しません。`isDiarized` と話者の `displayLabel` は画面用の内部情報で、公開 JSON に出しません。テキスト書き出し `transcript.txt` は画面と同じ発話を選び、討論場面で全 scope が背景の行を除外します。低優先度の発話は通常行として含めます。話者ラベルは 80% 以上を占める 1 人、満たさなければ複数人の併記、分離済みで割当なしなら UNKNOWN です。本文中の改行は空白にして 1 行 1 発話を保ちます。

根拠: [SessionRecovery.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecovery.swift)、[EventLogTranscriptReader.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/EventLogTranscriptReader.swift)、[Materialization.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[SessionExport.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/SessionExport.swift)、[ファイル処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)。
