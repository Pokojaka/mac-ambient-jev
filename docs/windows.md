# Windows の共通コア

macOS app は Swift 6.4（[Swift 6.4 release](https://www.swift.org/blog/swift-6.4-released/)）、Windows / Linux の共通 portable targets は Swift 6.2（[Swift 6.2 release](https://www.swift.org/blog/swift-6.2-released/)）です。Windows では Swift 6.2 で共通 Core / Pipeline / EngineProtocol / EngineHost、WindowsSupport、ONNX、PortableRuntime、Windows engine process、評価 CLI 3 本、full-session file CLI `MacAmbientJevProcessRecording`、file transcription CLI `MacAmbientJevTranscribeFile`、および Core / Pipeline / EngineProtocol / EngineHost / WindowsSupport / ONNX / PortableRuntime / Engine / ProcessRecording / TranscribeFile の各 test target を build / test できます（[Swift 6.2 release](https://www.swift.org/blog/swift-6.2-released/)）。Linux でも共通 Core / Pipeline、CMiniaudio、ONNX、PortableRuntime、同じ評価 CLI 3 本と2つの file CLI を build します。共通 Core の [`RecordingFLAC`](../app/MacAmbientJev/Sources/MacAmbientJevCore/RecordingFLAC.swift) と [`FLACTimelineReader`](../app/MacAmbientJev/Sources/MacAmbientJevCore/FLACTimelineReader.swift) は、録音用の正規 `recording.flac`（16 kHz mono 16-bit）の streaming encoder / reader API と CRC / MD5 検証を提供し、Windows でも利用できます。共通の [`MacAmbientJevPipeline`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline) と [`MacAmbientJevPipelineTests`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests) は Windows / Linux の build / test 対象です。`MacAmbientJevProcessRecording` は音声ファイルを session に import して full-session finalization / recovery を実行します。`MacAmbientJevTranscribeFile` は PortableRuntime の [`PortableAudioFileImporter`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableAudioFileImporter.swift) と ONNX Qwen3-ASR engine / Silero final-transcript VAD segmenter を使う別の評価 CLI で、WindowsSupport の WAV / FLAC / MP3 / M4A / AAC streaming decoder と SRC に委譲します。Windows の engine process `MacAmbientJevEngine.exe` は WASAPI の microphone / system-audio capture を持ち、GUI とインストーラーはありません。macOS の app は Apple Silicon と macOS 15 以降で動作します。

## MacAmbientJevEngineProtocol NDJSON v1

この節は portable `MacAmbientJevEngineProtocol` ライブラリの現行 wire 仕様です。Windows 専用の `MacAmbientJevEngine.exe` はこの protocol を使い、NDJSON transport・WASAPI capture・PortableRuntime inference を composition します（実行時の規則は[エンジンの composition](#エンジンの-composition起動時復旧と実行ファイル)を参照）。型と厳密 codec は Foundation の Codable / [Foundation JSONEncoder](https://developer.apple.com/documentation/foundation/jsonencoder) / [JSONDecoder](https://developer.apple.com/documentation/foundation/jsondecoder) / [KeyedDecodingContainer](https://developer.apple.com/documentation/swift/keyeddecodingcontainer) を使います（[Swift 6.4 release](https://www.swift.org/blog/swift-6.4-released/)、[Swift 6.2 release](https://www.swift.org/blog/swift-6.2-released/)）。行 framing は [NDJSON 1.0](https://raw.githubusercontent.com/ndjson/ndjson-spec/master/README.md) に従います。engine と client は strict NDJSON v1 の同じ schema と enum 集合を同時に出荷します。

実装: [`EngineProtocolVersion.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EngineProtocolVersion.swift)、[`EngineWireSupport.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EngineWireSupport.swift)、[`EngineCommands.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EngineCommands.swift)、[`EngineEventPayloads.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EngineEventPayloads.swift)、[`EngineEvents.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EngineEvents.swift)、[`EngineDiagnostics.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EngineDiagnostics.swift)、[`EngineModelInspection.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EngineModelInspection.swift)、[`EngineCodec.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EngineCodec.swift)、[`EnginePresentationState.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EnginePresentationState.swift)、[`EngineApplication+Presentation.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineApplication+Presentation.swift)。対応 tests: [`EngineProtocolVersionTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolVersionTests.swift)、[`EngineProtocolLexicalTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolLexicalTests.swift)、[`EngineProtocolCommandTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolCommandTests.swift)、[`EngineProtocolEventPayloadTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolEventPayloadTests.swift)、[`EngineProtocolEventTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolEventTests.swift)、[`EngineProtocolCodecTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolCodecTests.swift)、[`EngineProtocolCorpusTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolCorpusTests.swift)、[`EngineProtocolCorpusCoverageTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolCorpusCoverageTests.swift)、[`EngineProtocolDiagnosticsTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolDiagnosticsTests.swift)、[`EngineProtocolModelInspectionTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolModelInspectionTests.swift)、[`EngineProtocolDocumentationTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolDocumentationTests.swift)。

### Envelope、ID、line framing

Request object は正確に `{version, request_id, command, payload}`、output object は正確に `{version, sequence, request_id, event, payload}` です。wire は binary UTF-8 bytes で、BOM は使いません。全 key は snake_case、`version` は JSON integer の literal `1`。request `payload` と output `payload` は常に object です。required key の欠落、null/wrong type、unknown key/value、camelCase alias は、ネストした object を含め拒否します。nullable field も key 自体は必須で、値がないときは明示的な JSON `null` を使います。

`request_id` と `sequence` は JSON number でなく、正の canonical decimal UInt64 string (`1`...`18446744073709551615`) です。先頭ゼロ、符号、空白、範囲外値は不可です。接続の最初の request は `hello` / ID `1` の組だけを受け入れ、その後の ID は厳密増加し、間の欠番は許容します。output sequence も `1` から厳密増加し、欠番は許容します。revision は同じ正の canonical decimal UInt64 string domain です。これらの envelope/ID schema と、admission order helper (`EngineRequestOrder` / `EngineSequenceOrder`) は分離されています。

`session_id`、`folder_id`、`row_id` は空でない不透明文字列です。UUID 形式を要求せず、読み取れない folder に架空の session ID を割り当てません。device endpoint ID も不透明な空でない文字列です。cursor は構文を解釈しない不透明文字列で、初回は `null`、返されたページ cursor は空でない文字列です。`transcript.read` の初回 revision は `null` にします。cursor の有効性は対応する保持 snapshot 内だけで判定します。

`EngineCodec.decodeRequest(_:)` / `decodeOutput(_:)` は LF/CRLF delimiter を含まない1 record の UTF-8 bytes を受け取ります。`EngineLineFramer` が fragmented/coalesced input を分割し delimiter を除去します。LF と CRLF を受け入れ、blank line、bare CR、BOM、invalid UTF-8、partial final line を拒否します。EOF 時は buffer が空なら正常、途中の record があれば error です。framer はいずれかの framing/validation failure で terminal に閉じ、以後の append/finish は拒否します。codec の encoder は compact JSON、stable sorted keys、unescaped slash を出力し、record ごとに LF を1つ付けます。

lexical validation は root object、JSON grammar、有限数値、重複 object key（escape 展開後も含む）、nesting depth を typed decode より先に検査します。typed decode はすべての object level の unknown fields と enum values を拒否します。

| 定数 | 制約 |
| --- | --- |
| `max_line_bytes = 1048576` | CRLF delimiter を除く record は最大 1 MiB。complete envelope/page も同じ record 上限内。 |
| `transcript.row_details` envelope sizing | completed envelope 全体を canonical JSON UTF-8 bytes で実測し、`max_line_bytes` 内に収める。LF は含めない。最大 sequence / request ID と 36-byte cursor 2個を含む空 page の固定 overhead、および各 span の cached byte 数と comma を使う。 |
| `max_depth = 32` | root object を depth 1 とする object/array nesting 上限。 |
| transcript page / tail rows-array budget = 700000 bytes | `transcript.read` page と `transcript.watch` tail の rows 配列に使える予算。row ごとの canonical JSON UTF-8 byte 数と配列 comma を実際に数え、文字数や推定値は使わない。session list と `transcript.row_details` の speakers 配列には適用しない。 |
| `max_row_bytes = 262144` | 個々の compact encoded row の上限。key と JSON escaping を含み、LF は含めない。1行でも超える row は `row_too_large` error。 |
| session list count | request `limit` は 1...100。 |
| transcript page count | `transcript.read` の request `limit` は 1...200。`transcript.read` / `transcript.watch` の rows は最大 200（`transcript.watch` に request limit はない）。`transcript.row_details` の request `limit` は 1...200、`EngineTranscriptRowDetailsPage.speakers` は最大 200。 |
| row changes | `rows.count + removed_row_ids.count <= 200`。 |
| state queue | `EngineState.queue` は最大 16 operation。 |

host が request admission を最大 16 件に制限する場合、それは host contract であり、個別 envelope を検証する codec の機能ではありません。codec は上記の型・record・row 制約を検証します。

### Commands と completed result

`payload` key は各行に示すものだけで、すべて必須です。`EngineResult` は `completed` の `{command, result}` object で、result は対応する型または `{}` です。

| Command | 必須 payload | completed result / 意味 |
| --- | --- | --- |
| `hello` | `EngineEmptyPayload` `{}` | `EngineReadyPayload`。capabilities と現在の revisioned state。最初の request のみ。 |
| `state.get` | `EngineEmptyPayload` `{}` | `EngineState`。現在の revisioned state。 |
| `diagnostics.get` | `EngineEmptyPayload` `{}` | `EngineDiagnosticsResult`。process lifetime の decision usage diagnostics。 |
| `devices.list` | `EngineDevicesListPayload` `{source: EngineSource}` | `EngineDevicesResult`。source ごとの endpoint と明示された default selection。 |
| `recording.start` | `EngineRecordingStartPayload` `{source: EngineSource, device: EngineDevice}` | `EngineSessionPayload`。開始が成功してから session ID を返す。 |
| `recording.stop` | `EngineSessionPayload` `{session_id: String}` | `EngineSessionPayload`。durable stop と finalization queue への追加後に完了し、transcript finalization は待たない。 |
| `session.import` | `EngineImportPayload` `{input_path: String}` | `EngineSessionPayload`。source を retained import として保存し finalization queue に追加後に完了し、final transcript は待たない。 |
| `session.inspect` | `EngineSessionInspectPayload` `{folder_id: String}` | `EngineSessionSummary`。folder ID で現在の catalog を厳密検索し、unreadable folder も返す。 |
| `session.reprocess` | `EngineSessionPayload` `{session_id: String}` | `EngineSessionPayload`。要求した reprocess work が終端状態になってから完了。 |
| `session.retry_decisions` | `EngineSessionPayload` `{session_id: String}` | `EngineSessionPayload`。要求した decisions retry が終端状態になってから完了。 |
| `session.list` | `EngineSessionListPayload` `{cursor: String|null, limit: Int}` | `EngineSessionListResult`。unreadable folder も stable `folder_id` と error 付きで含む。 |
| `transcript.read` | `EngineTranscriptReadPayload` `{session_id: String, revision: EngineID|null, cursor: String|null, limit: Int}` | `EngineTranscriptPage`。engine が投影済みの revisioned page。stale revision/cursor は error。 |
| `transcript.row_details` | `EngineTranscriptRowDetailsPayload` `{session_id: String, revision: EngineID, row_id: String, cursor: String|null, limit: Int}` | `EngineTranscriptRowDetailsPage`。read/watch で取得した必須 revision の、単一 row の節状態と話者区間をページングして返す。 |
| `transcript.watch` | `EngineSessionPayload` `{session_id: String}` | `EngineTranscriptPage`。single selected session の bounded tail snapshot を返し、以降は revisioned `rows` event を送る。 |
| `session.export` | `EngineExportPayload` `{session_id: String, destination_path: String}` | `EngineExportResult`。明示 destination へ `transcript.txt` と audio（recording は `audio.flac`、import は retained original）を含む bundle を publication した後に完了。 |
| `settings.get` | `EngineEmptyPayload` `{}` | `EngineSettingsResult`。settings と revision。未設定時は `settings_required` / validation error。 |
| `settings.replace` | `EngineSettingsReplacePayload` `{expected_revision: EngineID|null, settings: EngineSettings}` | `EngineSettingsResult`。10 field 全体の strict replacement。`expected_revision: null` は first setup のみ。busy 中に recording/model/state と競合する replacement は host が `busy` error で拒否する。 |
| `models.prepare` | `EngineEmptyPayload` `{}` | `{}`。installed model profile の検証・load と progress。download はしない。 |
| `models.inspect` | `EngineEmptyPayload` `{}` | `EngineModelsInspection`。installed clause tagger の read-only inspection。 |
| `shutdown` | `EngineEmptyPayload` `{}` | `{}`。host が capture を安全に停止し resource を release した後に terminal completion して終了する。 |

### Nested model の exact schema

次表の object は列挙した key のみを持ちます。略記 `T?` は必須 key の値が `T` または明示的 `null` であることを示します。array の要素も記載した型どおりです。

| Swift 型 | exact fields と検証 |
| --- | --- |
| `EngineRequest` | `{version: Int (=1), request_id: EngineID, command: EngineCommandName, payload: command に対応する payload union}`。 |
| `EngineOutput` | `{version: Int (=1), sequence: EngineID, request_id: EngineID|null, event: EngineEventName, payload: event に対応する payload union}`。 |
| `EngineCommand` | `command` ごとに対応する payload 型を選ぶ union。正確な key/value は上表の command 行。 |
| `EngineEvent` | `event` ごとに対応する payload 型を選ぶ union。正確な payload 型は下の Events 表。 |
| `EngineEmptyPayload` | `{}` のみ。 |
| `EngineDevicesListPayload` | `source: EngineSource`。 |
| `EngineRecordingStartPayload` | `source: EngineSource`, `device: EngineDevice`。 |
| `EngineImportPayload` | `input_path: String`。空不可。 |
| `EngineSessionInspectPayload` | `folder_id: String`。folder ID は空不可。 |
| `EngineSessionListPayload` | `cursor: String|null`, `limit: Int` (1...100)。 |
| `EngineTranscriptReadPayload` | `session_id: String`, `revision: EngineID|null`, `cursor: String|null`, `limit: Int` (1...200)。session ID は空不可。 |
| `EngineTranscriptRowDetailsPayload` | `session_id: String`, `revision: EngineID` (必須・非 null), `row_id: String`, `cursor: String|null`, `limit: Int` (1...200)。session ID / row ID と non-null cursor は空不可。全 key 必須。 |
| `EngineTranscriptRowDetailsPage` | `session_id: String`, `revision: EngineID`, `row_id: String`, `clause_state: EngineClauseState` (非 null), `clause_state_text: String`, `speakers: [EngineTranscriptSpeakerSpan]` (最大200), `next_cursor: String|null`, `previous_cursor: String|null`。session ID / row ID / clause state text と non-null cursors は空不可。全 key 必須。 |
| `EngineTranscriptSpeakerSpan` | `speaker_id: String`, `display_label: String`, `start_ms: Int64`, `end_ms: Int64`。両 string は空不可。時刻は session audio の 0 起点 millisecond timeline 上で nonnegative、`end_ms >= start_ms`。 |
| `EngineExportPayload` | `session_id: String`, `destination_path: String`。両方空不可。 |
| `EngineSettingsReplacePayload` | `expected_revision: EngineID|null`, `settings: EngineSettings`。 |
| `EngineDevice` | `{kind: "default"}` または `{kind: "id", id: String}`。後者の id は空不可。 |
| `EngineSettings` | `schema_version: Int` (=1), `source: EngineSource`, `device: EngineDevice`, `asr_size: EngineASRSize`, `execution_provider: EngineExecutionProvider`, `threads: Int` (1...4), `low_heat: Bool`, `decisions_enabled: Bool`, `automatic_export: Bool`, `export_destination_path: String?` (null または空でない)。全10 key 必須。 |
| `EngineCapabilities` | `sources: [EngineSource]`, `asr_sizes: [EngineASRSize]`, `execution_providers: [EngineExecutionProvider]`, `maximum_threads: Int` (1...4), `automatic_input_volume: EngineUnavailableCapability`, `thermal_monitoring: EngineUnavailableCapability`。3 arrays は空でなく各 raw value unique。 |
| `EngineRecordingState` | `session_id: String`, `source: EngineSource`, `device: EngineDevice`, `phase: EngineRecordingPhase`。session ID は空不可。`waiting_for_device` は同じ録音 session の capture 再接続待ちであり、`screen` は `live` のまま。 |
| `EngineQueuedOperation` | `session_id: String`, `stage: EngineStage`。session ID は空不可。 |
| `EngineState` | `revision: EngineID`, `screen: EngineScreen`, `setup: EngineSetupStatus`, `recovery: EngineRecoveryStatus`, `recording: EngineRecordingState|null`, `queue: [EngineQueuedOperation]` (最大16), `failures: [EngineFailure]`, `presentation: EnginePresentationState` (必須・非 null)。 |
| `EnginePresentationState` | `recording_status_text: String`, `recording_tone: EngineRecordingTone`, `preparation_phase: EnginePreparationPhase`, `preparation_status_text: String|null`, `recovery_status_text: String|null`, `processing_status_text: String|null`, `live_failure_notices: [String]`, `silence_warning_active: Bool`, `silence_warning_text: String|null`, `audio_gap_count: UInt64` is a JSON integer **number** in `0...18446744073709551615` (not an ID string), `audio_gap_text: String|null`, `processing_indicator: EngineProcessingIndicator`。全 key 必須で、`recording_tone` と `preparation_phase` は非 null。nullable の5 key も必須で、値なしは明示的 `null`。必須 text と非 null nullable text、および `live_failure_notices` の各要素は空不可。`preparation_status_text` は `preparation_phase` が `idle` / `ready` なら必ず null、`preparing` / `failed` なら空でない非 null text。各 key の型を厳密に検証する。`silence_warning_active` は `silence_warning_text != null` と同値。`audio_gap_text` が非 null なら空不可かつ `audio_gap_count > 0`。 |
| `EngineReadyPayload` | `capabilities: EngineCapabilities`, `state: EngineState`。 |
| `EngineDeviceInfo` | `id: String`, `name: String`, `is_default: Bool`。id/name は空不可。 |
| `EngineDevicesResult` | `source: EngineSource`, `devices: [EngineDeviceInfo]`, `default_device_id: String|null`。device ID は一意。default device は最大1つで、nullable ID は `is_default: true` の唯一の endpoint と一致する（ID null の場合は default flag もない）。 |
| `EngineSettingsResult` | `revision: EngineID`, `settings: EngineSettings`。 |
| `EngineSessionSummary` | `folder_id: String`, `session_id: String|null`, `status: EngineSessionStatus`, `error: EngineFailure|null`, `display_name: String`, `status_text: String`, `folder_path: String`, `export_path: String|null`, `can_reprocess: Bool`, `can_retry_decisions: Bool`, `can_export: Bool`, `metadata: EngineSessionMetadata`。folder ID は一意・空不可。display name / status text / folder path と non-null export path は空不可。`unreadable` は `session_id` nullable で、catalog に既知の ID があれば保持し、存在しない場合だけ null とする（架空 ID は作らない）。unreadable summary では `error` は必須で、host が返す `error.session_id` は summary の `session_id` と一致する（codec はこの対応関係を追加検証しない）。`export_path` は null、action flags は false、metadata は unreadable。それ以外は session ID 必須かつ readable metadata。readable summary の `error` は通常 null だが、cached export failure（`session.export` の `failExport` を含む）がある場合はその failure を保持する。 |
| `EngineSessionSource` | `{kind: "microphone"}` / `{kind: "system_audio"}` / `{kind: "imported", original_filename: String}`。imported filename は空不可。各 variant は示した key のみ。 |
| `EngineSessionAudio` | `{kind: "available"}` / `{kind: "missing"}` / `{kind: "unreadable", reason: String}`。reason は空不可。各 variant は示した key のみ。 |
| `EngineSessionMetadata` | `{kind: "unreadable", reason: String}` または `{kind: "readable", created_at: finite Double, source: EngineSessionSource, audio: EngineSessionAudio, has_transcript: Bool}`。reason は空不可。`created_at` は Unix epoch seconds の有限数値で、負値も許す。各 variant は示した key のみ。unreadable metadata は timestamp / source / audio / transcript / ID を含まない。 |
| `EngineSessionListResult` | `sessions: [EngineSessionSummary]` (最大100、folder ID unique), `next_cursor: String|null`, `previous_cursor: String|null`。 |
| `EngineTranscriptPage` | `session_id: String`, `revision: EngineID`, `rows: [EngineTranscriptRow]` (最大200、row ID unique), `next_cursor: String|null`, `previous_cursor: String|null`。watch result は両 cursor null。 |
| `EngineTranscriptRow` | `row_id: String`, `start_ms: Int64`, `end_ms: Int64`, `text: String`, `headings: [EngineSpeakerLabel]`, `clause_state: EngineClauseState|null`。row ID は空不可。時刻は wall-clock でなく session audio の 0 起点 millisecond timeline、双方 nonnegative、`end_ms >= start_ms`。text は空白だけでない。 |
| `EngineRowsPayload` | `session_id: String`, `revision: EngineID`, `kind: EngineRowsKind`, `rows: [EngineTranscriptRow]`, `removed_row_ids: [String]`, `next_cursor: String|null`。upsert/removed ID は各々と相互で一意、removed ID は空不可、両配列合計最大200。`snapshot` は removed rows なし、`changes` と `reload_required` の cursor は null、`reload_required` は rows と removed IDs が空。 |
| `EngineProgressPayload` | `stage: EngineStage`, `completed_units: UInt64`, `total_units: UInt64|null`, `session_id: String|null`。units は JSON integer **number** で ID string ではない。total がある場合 completed は total 以下。 |
| `EngineErrorDetail` | `domain: String`, `code: String`, `message: String`, `path: String|null`, `device_id: String|null`。domain/code/message は空不可。nullable path/device ID は null または空でない。 |
| `EngineFailure` | `code: EngineErrorCode`, `message: String`, `stage: EngineStage`, `request_id: EngineID|null`, `session_id: String|null`, `severity: EngineSeverity`, `recovery_action: EngineRecoveryAction`, `details: [EngineErrorDetail]`, `cleanup_errors: [EngineErrorDetail]`。message は空でない Japanese user-facing text。`details` と `cleanup_errors` は raw native domain/code/message/path/device ID を保持する。 |
| `EngineDecisionRequestUsage` | `{send_count: Int, input_tokens: Int, success_count: Int, failure_count: Int}`。各値は JSON integer `0...9223372036854775807`。`success_count + failure_count` は overflow-safe に計算し `send_count` 以下。 |
| `EngineDecisionUsageSnapshot` | `{send_count: Int, input_tokens: Int, success_count: Int, failure_count: Int, pending_boundary_segment_count: Int, pending_priority_clause_count: Int, boundary_requests: EngineDecisionRequestUsage, priority_requests: EngineDecisionRequestUsage}`。全 Int は JSON integer `0...9223372036854775807`、pending も非負。4 totals (`send_count`, `input_tokens`, `success_count`, `failure_count`) は同名の boundary / priority count の overflow-safe な正確な和。両 breakdown にも `success_count + failure_count <= send_count` を overflow-safe に適用。 |
| `EngineDecisionUsage` | `{kind: "available", snapshot: EngineDecisionUsageSnapshot}` または `{kind: "unavailable", error: EngineFailure}`。各 variant に記した key のみ必須で、反対 arm の key は値が `null` でも拒否。 |
| `EngineDiagnosticsScope` | JSON string `"engine_process"` のみ。 |
| `EngineDiagnosticsResult` | `{scope: EngineDiagnosticsScope, decision_usage: EngineDecisionUsage, automatic_input_volume: EngineUnavailableCapability, thermal_monitoring: EngineUnavailableCapability}`。両 capability は `none`。 |
| `EngineClauseTaggerIdentity` | `{backend: String, model_id: String, revision: String, tokenizer_sha256: String}`。backend / model_id は non-whitespace 文字を含み、revision / tokenizer_sha256 は lowercase ASCII 64桁 hex。 |
| `EngineClauseTaggerInspection` | `{kind: "validated", identity: EngineClauseTaggerIdentity}` または `{kind: "invalid", error: EngineFailure}`。各 variant に記した key のみ必須で、反対 arm の key は値が `null` でも拒否。 |
| `EngineModelsInspection` | `{clause_tagger: EngineClauseTaggerInspection}`。 |
| `EngineExportResult` | `session_id: String`, `destination_path: String`; 両方空不可。 |
| `EngineAcceptedPayload` | `command: EngineCommandName`。 |
| `EngineResult` | `{command: EngineCommandName, result: <対応 command の型>}`。各 command の result 型は上表の Commands 欄、model prepare/shutdown は空 object。 |
| `EngineSessionPayload` | `{session_id: String}`。空不可。request と session 操作の結果で共有。 |

settings `threads` の wire 検査は明示範囲 `1...4` です。host は machine ごとの上限を検査する際 `logicalCPUCount` を注入して `threads <= min(4, logicalCPUCount)` を検証します。decode は CPU 数を読み取ったり推定したりしません。`execution_provider` は `cpu` のみで、CPU-only の選択可能な `asr_size` は `0.6b` と `1.7b` です。`low_heat` は pacing を選ぶ必須 boolean、`decisions_enabled` と `automatic_export` も必須 boolean です。`automatic_export: true` でも `export_destination_path: null` は visibly unconfigured で、Desktop を含む保存先を推測しません。

Stable raw values:

- `EngineSource`: `microphone`, `system_audio`; `EngineASRSize`: `0.6b`, `1.7b`; `EngineExecutionProvider`: `cpu`; `EngineUnavailableCapability`: `none`.
- `EngineDiagnosticsScope`: `engine_process`; `EngineDecisionUsage.kind`: `available`, `unavailable`; `EngineClauseTaggerInspection.kind`: `validated`, `invalid`.
- `EngineDevice.kind`: `default`, `id`; `EngineSessionSource.kind`: `microphone`, `system_audio`, `imported`; `EngineSessionAudio.kind`: `available`, `missing`, `unreadable`; `EngineSessionMetadata.kind`: `unreadable`, `readable`.
- `EngineCommandName` (enum order): `hello`, `state.get`, `diagnostics.get`, `devices.list`, `recording.start`, `recording.stop`, `session.import`, `session.inspect`, `session.reprocess`, `session.retry_decisions`, `session.list`, `transcript.read`, `transcript.row_details`, `transcript.watch`, `session.export`, `settings.get`, `settings.replace`, `models.prepare`, `models.inspect`, `shutdown`.
- `EngineEventName`: `ready`, `state`, `accepted`, `completed`, `progress`, `rows`, `error`.
- `EngineScreen`: `idle`, `live`, `finalizing`, `finalized`; `EngineSetupStatus`: `settings_required`, `models_required`, `ready`; `EngineRecoveryStatus`: `pending`, `running`, `completed`, `failed`; `EngineRecordingPhase`: `starting`, `recording`, `waiting_for_device`, `stopping`; `EngineRecordingTone`: `neutral`, `recording`, `warning`, `error`; `EnginePreparationPhase`: `idle`, `preparing`, `ready`, `failed`; `EngineSessionStatus`: `unreadable`, `recording`, `queued`, `processing`, `finalized`, `failed`.
- `EngineSpeakerLabel`: `Speaker 1`, `Speaker 2`, `Speaker 3`, `Speaker 4`, `Speaker 5`, `Speaker 6`, `Speaker 7`, `OTHER`, `UNKNOWN`. These are materialized headings; the client does not infer speakers.
- `EngineClauseState`: `awaiting_next_segment`, `boundary_pending`, `priority_pending`, `classified`; transcript rows use nullable `clause_state` for unavailable state, whereas `EngineTranscriptRowDetailsPage.clause_state` is required and non-null.
- `EngineRowsKind`: `snapshot`, `changes`, `reload_required`.
- `EngineStage`: `startup`, `settings`, `devices`, `capture`, `import`, `recovery`, `maintenance`, `validating_models`, `loading_models`, `vad`, `diarization`, `asr`, `decisions`, `finalization`, `export`, `shutdown`, `protocol`.
  `startup` は codec enum の値です。Windows host の `EngineController.run` は `ready` 初期化失敗時に `startupFailed` で終了し、wire `error` を送らないため、`stage: startup` の corpus record は contract-only です。
- `EngineErrorCode`: `invalid_request`, `unsupported_version`, `invalid_request_id`, `hello_required`, `busy`, `settings_required`, `invalid_settings`, `stale_revision`, `invalid_cursor`, `session_not_found`, `row_not_found`, `device_not_found`, `device_failure`, `device_lost`, `capture_failure`, `disk_space`, `power_failure`, `filesystem`, `model_missing`, `model_corrupt`, `model_failure`, `processing_failure`, `export_failure`, `row_too_large`, `cancelled`, `internal_error`.
  `device_not_found` と `power_failure` は現在の Windows host producer がありません。corpus の両 record は codec contract の例であり、host が wire emission することを示しません。
- `EngineSeverity`: `warning`, `error`, `fatal`.
- `EngineProcessingIndicator`: `idle`, `running`, `backlogged`, `complete`, `partial_failure`.
- `EngineRecoveryAction`: `none`, `replace_settings`, `prepare_models`, `retry`, `reprocess`, `retry_decisions`, `select_device`, `free_disk_space`, `inspect_session`, `restart`.
  `session.retry_decisions` は [`NativeSessionProcessor.retryContentPrioritySession`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift) が typed `SessionProcessingResult` を返します。対象なし、無効な decision engine、factory 初期化失敗、boundary / priority 推論失敗はいずれも `.failed` となり、日本語の利用者向け prefix `発話文の判定を再試行できませんでした: ` に元の `localizedDescription` を付加します（raw error は英語の場合もあります）。[`SessionProcessingCoordinator`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingCoordinator.swift) と [`EngineProcessorGateway`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineProcessorGateway.swift) はこの結果を保持して伝播します。推論失敗時は failed-run cleanup の直前に cancellation を一度確認し、durable outcome 前かつ cleanup 開始前に取り消されていた場合だけ paused / held として `code: cancelled`、`severity: warning`、`message: 処理は中断されました。次回の起動時に再開できます` を返します。この場合は background `processing_failure` event、`state.failures` entry、failed run end を作りません。failed-run cleanup 開始後は coordinator / writer が cancellation を再確認せず、retry が開始した各 run の `processing.run.completed` (`succeeded: false`) をすべて保存しようとします。durable な failed completion は late cancellation や shutdown に優先して `.failed` となり、held / cancelled にはなりません。実 I/O による completion write failure も `.failed` で、message に元の推論 error と保存 error の両方を含めますが、耐久化できたとはみなしません。未完了 run は起動時 recovery 対象です。retry の `.failed` outcome は host で `request_id: null` の background `error` event を一件、`state.failures` に failure entry を一件だけ作り、両者は実際の同一 `message` と `code: processing_failure`、`severity: error`、`stage: decisions`、`recovery_action: retry_decisions`、`session_id` を持ちます（failure entry の `request_id` は `null`）。要求に相関する終端 `error` も同じ failure を実際の request ID で返します。成功 retry は decision snapshot の metadata publication 後に `.completed` となり、後からの cancellation、未準備 settings / models、shutdown でも held / cancelled に戻さず自動 rerun しません。`succeeded: true` の run end だけで metadata publication がない場合は durable success ではなく、起動時 recovery が適用されます。成功 retry も自動 export はしません。[`SessionFileProcessingService`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionFileProcessingService.swift) は失敗結果を保持して export を行いません。

### Engine-owned presentation semantics

`EngineState.presentation` は engine が組み立てる必須の表示状態です。client は受信した text をそのまま表示し、shell や UI 側で payload から文字列を再構成しません。

- 録音 text は lifecycle に従い、`待機中` → `録音を開始しています` → source に応じた `マイクを録音中` / `システム音声を録音中` → `録音を保存しています` となります。保存成功は `録音を保存しました（MM:SS[・発話 N区間]）` または `録音を保存しました（H:MM:SS[・発話 N区間]）`（発話数が0なら suffix なし）、録音開始の取消は `録音の開始を中止しました` です。`recording_tone` は開始・停止/保存・import の通常状態を `neutral`、capture 中を `recording`、保存済み録音の system-audio release failure / overflow / VAD failure を `warning`、録音開始・capture・import の失敗を `error` とします。overflow は `録音は保存しましたが、一部の音声が欠落した可能性があります。`、system-audio release failure は `録音は保存しましたが、<release>`、VAD failure は `録音を保存しました。発話検出を後で再実行します: <reason>` です。import は `音声ファイルを読み込んでいます`、成功時 `「<filename>」を読み込みました`、失敗時 `音声ファイルを読み込めませんでした: <reason>` です。capture failure / cleanup の text は engine が設定します。デバイス復帰待ちでは `recording_status_text: 録音デバイスの復帰を待っています`、`phase: waiting_for_device`、`recording_tone: warning` とし、同じ session のまま `screen: live` を保ちます。待機中は silence warning を解除・抑止し、復帰後は新しい silence interval から監視を再開します。音声欠落数は待機中も表示します。
- `preparation_phase` が準備状態を表し、`idle` / `ready` では `preparation_status_text: null`、`preparing` / `failed` では空でない text を送ります。text は `preparing` / `failed` の場合にだけ存在します。Mac status bar は preparing spinner または failed warning のみを表示し、idle / ready は status-bar text を表示しません。Windows は `models.prepare` で installed assets を検証し、検証中は `音声認識モデルを準備しています`、loading 中は `音声認識モデルを読み込み中（N%）`（整数 percent）を表示します。validation / loading progress は completed units を `floor(completed / total × 100)` に正規化し、`total_units: 100` で直列に送ります。各 phase 内で high-water を保持して percent を戻さず、loading 開始後に届いた validation progress は無視します。100% loading progress は完了を意味せず、準備処理が戻り inference を install した後だけ phase を `ready` にします。idle model release は phase を `idle`、text を `null` にします。`models.prepare` 実行中は idle release を開始せず、準備 presentation も reset しません。すでに scheduled な idle release task も実行時にこの不変条件を再確認します。
- recovery text は maintenance 中 `保存済み録音の音声を整理しています（N件）`、復旧中 `未完了の文字起こしを復旧しています（N件）` です。scan failure は `復旧できないセッションがN件あります。詳細は「保存済み録音」で確認できます`、maintenance failure は `保存済み録音の音声を整理できなかったセッションがN件あります: <details>`、shutdown interruption は `終了処理のため保存済み録音の音声整理が中断されたセッションがN件あります。次回起動時に再実行します: <details>` です。scan 全体の失敗は `未完了セッションを復旧できませんでした: <reason>` です。該当する表示がないときは `recovery_status_text: null`、復旧完了時は進行中の復旧 text を null にします。
- processing text は共有 status と queue lifecycle をそのまま使います: `音声ファイルを読み込んでいます`、`音声ファイルを処理用タイムラインへ変換しています`、`発話区間を検出しています`、`音声認識モデルを準備しています`、`音声認識モデルを読み込んでいます`、`文字起こし処理が遅れています`、`話者分離を準備しています`、`話者を分離しています`、`発話文の境界と優先度を判定しています`、`発話文の判定を保留しました`、`文字起こし処理が待機中です`、`次の文字起こし処理を開始します`。Windows の held task は `処理は中断されました。次回の起動時に再開できます` を表示し、`processing_indicator: idle` で spinner を止めます。録音中の VAD 表示は `録音中に発話を検出しています（N区間）` です。
- 無音警告は共有 `CaptureHealthMonitor` / `CaptureHealth.isSilent` が `silentSinceMillis` から30秒以上を判定し、`silentSinceMillis == 0` または録音終了で解除します。表示は microphone で `マイク入力が30秒以上無音です。ミュート設定を確認してください`、system audio で `システム音声が30秒以上無音です` です。これは `presentation` 専用で、failure history や `error` event には追加しません。音声欠落数は既存 monitor の `onDropouts` と `captureStopped` から受け取り、録音中かつ count > 0 の場合だけ `音声の欠落: N 回` を表示します。停止後は text を null にし、count は次の録音開始まで保持します。`waiting_for_device` 中は無音警告を常に解除し、復帰後は新しい monitor 開始時刻から silence interval を数え直します。欠落数は待機中も `audio_gap_count` / `audio_gap_text` に表示します。通常の packet-first 再接続では最後の captured end から最初の復帰 packet の mapped frame までを1つの `missingCallback` として記録します。loopback の idle-health buffer evidence が成立した場合は、待機中の単一 `missingCallback` を prepared reopen / settled boundary で閉じ、health silence 後の最初の実 packet は残る既知の idle 区間（250 ms delivery grace を含む）だけを有効な silence として補い、二つ目の gap は作りません。いずれの再接続経路でも `audio_gap_count` は1回だけ増えます。新規の idle start は gap 数0です。timeout 時は missing tail を deadline までで閉じます。保存上の zero placeholder は欠落区間の表現であり、capture した音声ではありません。
- `live_failure_notices` は同一 text を重複させず最新16件に制限し、通常の status 更新や finalization 後も保持します。次の録音開始時に消去します。live の `partial_failure` は indicator と transcript に反映し、通常の `processing_status_text` を保持します。failure notice がこの status text を置き換えることはありません。
- `processing_indicator` は Mac と同じ状態・icon 対応です: `idle` = `circle`、`running` = `waveform`、`backlogged` = `clock`、`complete` = `checkmark.circle`、`partial_failure` = `exclamationmark.triangle`（SF Symbols）。Windows は常に `WindowsNoThermalMonitoring` を使い、`isCritical == false`、live ASR decision は `.processNow`、thermal monitoring は `none` です。shutdown / fatal failure では processing task を cancel します。typed processor activity は exhaustive に変換し、thermal-only activity が Windows に届けば precondition failure とする programming error です（silently filter しません）。recovery の `.retryEmpty` / `.retryFailed` event も Windows では programming error とし、受信時に fail fast します。Mac 固有の thermal-pause status は Windows presentation に出しません。

実装: [`EnginePresentationState.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EnginePresentationState.swift)、[`EngineApplication+Presentation.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineApplication+Presentation.swift)。tests: [`EngineProtocolPresentationTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolPresentationTests.swift)、[`EngineApplicationPresentationTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationPresentationTests.swift)、[`EngineApplicationPresentationLifecycleTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationPresentationLifecycleTests.swift)。

### diagnostics と installed model inspection

`diagnostics.get` は1つの process-lifetime `DecisionUsageCounter` の snapshot を返します。counter は [`PortableEngineInference.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngine/PortableEngineInference.swift) が保持し、すべての [`PortableSessionEngineBundle`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableSessionEngineBundle.swift) に明示的に渡されます。usage は NDJSON command 数ではなく、Mac の共有 `DecisionCoordinator` boundary で集計され、model preparation や settings replacement をまたいで保持され、これらを理由に reset されません。成功した request の token 数だけが実際の model read を反映し、failed / cancelled request の token 数は 0 です。in-flight または cancelled attempt は success / failure のどちらにも未計上の場合があります。pending counts はこの process が観測・公開・消去した共有 durable pending target を表し、disk 全体の pending 数ではありません。

usage の collection または mapping に失敗した場合も `diagnostics.get` は completed result を返しますが、`decision_usage` は `unavailable` となり、error は `code: internal_error`, `stage: decisions`, `request_id: null`, `session_id: null`, `severity: error`, `recovery_action: retry` の Japanese `EngineFailure` で native details を保持します。zero snapshot に置き換えてはいけません。

`models.inspect` は settings / `models.prepare` より前から利用でき、`decisions_enabled` に依存しません。Portable inference harness でも、inspection に使う clause tagger directory は decision selection と独立です。公開 service [`PortableClauseTaggerInspection`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableClauseTaggerInspection.swift) は信頼済みの同梱 manifest と installed model の通常ファイル型・byte 数・streaming SHA-256 を `BlockingIOExecutor` 上で検証し、manifest 由来の identity を返します。ONNX environment / session を作らず、tokenizer の parse や ONNX tensor metadata の検証もしません。実際の ONNX loading は `models.prepare` が行います。

同じ retained service への同時 request は in-flight validation だけを共有します。validation が成功または失敗した時点で共有状態を消し、後続 request は再検証します。結果の cache はありません。inspection は inference、usage accounting、state mutation、download を行いません。model directory / member の欠落は `model_missing`、manifest・file type・size・hash の不正は `model_corrupt` となり、`models.prepare` と同じ validator と error mapping を使います。未知の non-cancellation adapter error は `model_failure` です。通常の invalid result は `stage: validating_models`, `request_id: null`, `session_id: null`, `severity: error`, `recovery_action: prepare_models` の `EngineFailure` として nested になり、model detail は `domain: models`, `code: clause_tagger`, `path: null`, `device_id: null` です。詳細な path と検査内容は Japanese message に保持します。

CancellationError は `invalid` に変換しません。相関した terminal `event: error` は `code: cancelled`, `stage: validating_models`, `message: モデルの確認が中止されました`, `recovery_action: none`, `session_id: null`, `severity: error`, 空の `details` / `cleanup_errors` を持ち、request ID を保持します。中断できない共有 hash validation 中に caller が cancel した場合、その waiter は validation flight の終了後に cancel し、他 caller の検証は cancel しません。関連 tests: [`PortableClauseTaggerInspectionTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/PortableClauseTaggerInspectionTests.swift)、[`PortableEngineInferenceTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineTests/PortableEngineInferenceTests.swift)、[`EngineApplicationInspectionCancellationTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationInspectionCancellationTests.swift)。Mac の diagnostics / model-check reference が公開する identity は tagger の model ID / revision のみです。VAD / ASR / diarizer identity list は作らず、settings の選択済み ASR size も検証済み installed identity ではありません。

[`EngineApplicationDiagnosticsTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationDiagnosticsTests.swift) は7件の host accounting tests を含み、[`EngineProtocolDiagnosticsTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolDiagnosticsTests.swift) と [`EngineProtocolModelInspectionTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolModelInspectionTests.swift) は不一致 totals、overflow-safe な合計、in-flight request、hash と identity name の検証、invalid inspection 内の `EngineFailure` 検証を確認します。unknown / missing / null / wrong-type fields は corpus mutation test が全 object で確認します。

### Session catalog、enriched summary、paging

`session.list` の `cursor: null` は limit にかかわらず catalog を読み直し、各 folder を `EngineSessionSummary` へ完全に enrich した immutable snapshot と新しい page navigation を確立または置換します。初回 page はどの有効な limit でも始められ、同じ limit であっても以前の前後 cursor は失効します。続きの page はその snapshot の値を返し、catalog の更新は保持済み page に反映しません。`session.inspect` は現在の catalog を folder ID で厳密検索し、読み取り可能な session だけでなく unreadable folder も同じ mapper で返します。folder ID が現在の catalog にない場合は `session_not_found` です。inspect は list snapshot を変更しません。export destination probe が失敗しても list / inspect は失敗で中断せず、catalog の各 session summary を返し、該当 session の export failure を cache します。inspect の completed envelope も、最大 sequence / request ID を含めて 1 MiB 以下であることを検査します。summary 1件だけで上限を超える場合も切り詰めず `filesystem` error を返します。

list の `limit` は 1...100 です。各 page は `sessions` 最大100件かつ completed event の compact canonical JSON envelope 全体が 1 MiB 以下です。retained snapshot ごとに各 summary を canonical encode するのは1回だけで、その UTF-8 byte 数を cache します。page サイズは選択された summary の cached byte 数の合計、summary 間の comma byte 数、および `sessions:[]`・最大 sequence / request ID・各36-byte cursor 2個を含む固定 envelope byte 数で計算します。LF はこの1 MiB record 上限に含めません。session 配列には transcript rows の 700000-byte budget を適用しません。1件の summary さえこの envelope に収まらない場合は切り詰めず `filesystem` error です。cursor は engine が生成する opaque UUID token で、その構文は解釈せず、保持中の該当 snapshot の page navigation に結び付けます。`cursor: null` の初回 page は有効な任意の limit で開始し、その limit で navigation を開始して前後の旧 cursor を失効させます。同じ limit でも reset します。非 null の continuation cursor だけが開始時の navigation limit と一致しなければならず、未知・別 snapshot の continuation cursor または limit mismatch は `invalid_cursor` です。したがって limit mismatch による `invalid_cursor` は continuation に限られ、`cursor: null` の開始時に以前の limit と異なる値を使っても拒否しません。`previous_cursor` と `next_cursor` は実際に返した page 境界を指し、byte limit で短くなった page の境界も反映します。最初の page の `previous_cursor` と最後の page の `next_cursor` は null です。

`display_name` は readable session では abbreviated date / short time を明示的な `ja_JP` locale と TimeZone.current で表示し、unreadable session では固定文字列 `日時を読み取れません` を返します。`metadata.created_at` は表示用文字列でなく有限の Unix epoch seconds number です。`status_text` は audio 状態を先に評価し、missing は `保存済み音声がありません`、unreadable は `音声を読めません: <reason>`。available audio では processing status に応じて `未処理`、`処理中`、`文字起こしあり` / `処理完了`、`文字起こしあり・判定を再試行`、`処理は中断されました。次回の起動時に再開できます`（paused / held session）、`再処理が必要: <reason>`（reason が null なら `処理に失敗しました`）、または `文字起こしデータが破損しています（音声から再処理できます）` を返します。held session の `status_text` は `processing_status_text` と同じ `処理は中断されました。次回の起動時に再開できます` です。Windows は熱による pause を行わず、Mac 固有の thermal-pause status を session summary に出しません（`thermal_monitoring: none`）。unreadable metadata は `読み込みエラー: <reason>` を表示します。

`can_reprocess` と `can_retry_decisions` は、settings と prepared models があり、recording / import が idle、shutdown / model preparation / storage maintenance がなく、processing capacity が残り、session 自身が busy でない場合に限ります。reprocess は audio source も必要です。retry decisions はさらに usable audio（`metadata.audio.kind == available`）、`metadata.has_transcript`、`decisions_enabled` と `classificationPending` 分類を必要とします。実際の recovery path が音声を必要とするため、host は音声と transcript の有無も検査します。`can_export` は確定 transcript と usable audio があり、session が corrupted / queued / exporting / shutdown 中でない場合に true です。`processingQueue.sessionIDs` に含まれる全 session では `can_reprocess`、`can_retry_decisions`、`can_export` は false です。queue membership 自体が busy として扱われます。storage maintenance は recorded PCM の export だけを block します。explicit `session.export.destination_path` を指定するため export destination の設定有無は `can_export` の条件ではありません。`export_path` は tracked completed export または configured destination にある検証済み complete bundle の path だけを返し、それ以外は null です。`export_path: null` だけでは cached export failure がないとは限りません。readable summary に cached export failure（export probe failure や `session.export` の `failExport` を含む）がある場合、`error` は `EngineFailure` で、その field は `code: export_failure`、`stage: export`、cache と同一の `message`、`request_id: null`、summary と一致する `session_id`、`severity: error`、`recovery_action: retry` です。probe failure の message prefix は `書き出し先を確認できません: …` です。失敗は該当 summary の error に明示され、list / inspect はその failure を理由に他 session の列挙を中止しません。

成功した `settings.replace` で `export_destination_path` が変わると、failed / exported probe cache を reset し、後続の現在 catalog に対する `session.list` / `session.inspect` で新しい destination を再 probe します。設定 replacement が失敗した場合または destination が変わらない場合は reset しません。すでに保持している immutable list snapshot は変更せず、新しい `cursor: null` list が新しい catalog view を確立します。

### Events、correlation、revision

全 event は共通 output envelope を使い、payload は下表の正確な型です。`ready` の top-level `request_id` は null、`accepted` / `completed` は非 null。`error` の envelope `request_id` と `EngineFailure.request_id` は同値です。`state`、`progress`、`rows` は相関 ID を null または該当 request ID にできます。

| event | payload | 意味 |
| --- | --- | --- |
| `ready` | `EngineReadyPayload` | capabilities と初期 state。unsolicited。 |
| `state` | `EngineState` | revisioned current state。 |
| `accepted` | `EngineAcceptedPayload` | request の command を確認。 |
| `completed` | `EngineResult` | command に対応する typed terminal result。 |
| `progress` | `EngineProgressPayload` | stage progress。`completed_units` は UInt64 JSON number、`total_units` は必須 nullable UInt64 JSON number。 |
| `rows` | `EngineRowsPayload` | 選択 session の revisioned projected row snapshot/changes/reload marker。 |
| `error` | `EngineFailure` | stable code、Japanese message、stage、severity/recovery action、native details と cleanup errors。 |

valid admitted request ごとに `accepted` 1つ、その後 terminal `completed` または `error` 1つを返すことは **host contract** です。`EngineCodec` は個々の envelope/schema/correlation を検査するだけで、process-wide event lifecycle を保証しません。background processing failure は unsolicited `error` / state として報告し、既に完了した stop/import command の結果を遡って変更しません。

Rows snapshot にはその revision の row set を、`changes` には distinct row upsert と removals を載せます。`transcript.read` は cursor の位置から最大200 rows、`transcript.watch` は最大200 rowsの最新 tail を返し、`transcript.read` page と `transcript.watch` tail の rows 配列は実際の canonical JSON row bytes と comma を数えて700000 bytesの budget内に収めます。個々のrowが262144 bytesを超える場合は `row_too_large` error です。`changes` が200件またはこの byte budgetを超える場合、および出力待ち行列で change stream が coalesce / 失効する場合は `reload_required` にし、row data は持たせず client に再読込させます。`EngineRowsPayload` には `previous_cursor` はなく、watch の completed page は `next_cursor` / `previous_cursor` をともに null とし、history cursor を作りません。

`transcript.read` の `revision: null, cursor: null` は最新 snapshot を開始し、要求された有効な limit で immutable read snapshot と page navigation を開始または置き換えます。revision が前と同じ場合も前後両方向の全 cursor を失効させます。保持済みの valid revision を指定して `cursor: null` を送る場合は、同じ immutable snapshot 内容を保持したまま navigation を新しく開始し、要求された有効な limit で page 1 を返します。以前の cursor は同じ limit の場合も失効します。snapshot は engine 全体で1つだけ保持され、watch projection / read cache から独立します。同じ session または別 session の新しい snapshot で前の snapshot と全 cursor token が失効します。page navigation の limit は開始時に決まり、非 null continuation cursor は同じ revision と limit とともに使います。limit mismatch による `invalid_cursor` はこの非 null continuation cursor に限ります。`cursor: null` の開始時は既存 navigation limit と異なる有効な limit を指定しても拒否しません。`revision: null` と非 null cursor の組は `invalid_cursor` です。未知・cross-snapshot continuation cursor も `invalid_cursor` です。cursor は実際の page 境界を記録し、rows byte budget で page が短くなった場合も次 / 前 page はその境界に接続します。最初の page の `previous_cursor` と最後の page の `next_cursor` は null です。live transcript の追記・変更・削除では immutable read snapshot を変えません。保持 snapshot がない場合でも指定 revision が現在の最新 revision と一致すれば、その revision で `cursor: null` を指定して snapshot を確立できます。保持 snapshot と現在 revision のいずれにも一致しない revision は `stale_revision` です。final transcript publication は内容が同じ場合も新しい revision を発行し、対象 session の read snapshot と前後両方向の cursor を失効させ、watch 側には `reload_required` を送ります。watch の revision は、投影済み rows または row-bearing details projection が変わった場合に限り変わり、上流 update ごとには変わりません。

#### `transcript.row_details`

この NDJSON v1 command 名に alias や version negotiation はありません。payload は `EngineTranscriptRowDetailsPayload` の `{session_id: String, revision: EngineID, row_id: String, cursor: String|null, limit: Int}` で、初回 details page を含むすべての呼び出しで `revision` は必須・非 null です。呼び出し側は `transcript.read` または `transcript.watch` で得た revision を送ります。result は `EngineTranscriptRowDetailsPage` の `{session_id, revision, row_id, clause_state, clause_state_text, speakers, next_cursor, previous_cursor}` のみで、row text や全行一覧は返しません。`clause_state` は非 null の `EngineClauseState`、`clause_state_text` は空でない文字列で、portable Core の単一実装 `TranscriptClauseState.rowDetailsDescription` が生成し、Mac popover と engine が共用します: `awaiting_next_segment` = `発話文: 続き待ち`、`boundary_pending` = `発話文: 境界判定を保留中`、`priority_pending` = `発話文: 優先度判定を待っています`、`classified` = `発話文: 判定済み`。両 cursor key は必須で、値は空でない文字列または明示的 `null` です。request の `limit` は protocol boundary で 1...200 の範囲を一度だけ厳密に検証し、snapshot paging はその値を clamp せず使います。

`EngineTranscriptSpeakerSpan` は `{speaker_id: String, display_label: String, start_ms: Int64, end_ms: Int64}` です。両 string は空でなく、時刻は session audio の 0 起点 millisecond timeline 上で非負、`end_ms >= start_ms`。`display_label` は enum でなく一般の String で、host は Mac popover と同じ意味を保つ materialized な明示 `displayLabel` を使い、値がない場合は raw `speaker_id` をそのまま表示 label にします。話者区間配列は最大200件で、materialized 順序、重複 ID、重なりをそのまま保ちます。confidence は含めず、区間の clipping・merging・deduplication はしません。

engine-wide に保持する詳細 snapshot は独立した単一 row の immutable snapshot です。session の存在確認を revision 照合より先に行い、row details 自身の保持 snapshot、完全一致する session/revision の retained `transcript.read` snapshot、同じ session/revision の現在の watch cache、同じ session/revision の現在の read cache の順に解決します。いずれの保持 source も session/revision に一致しなければ直ちに stage `finalization`、recovery `retry` の `stale_revision`（`文字起こしの revision が古くなっています。最初から読み直してください`）です。この拒否では `SavedTranscriptLoader` によるディスク上の transcript 読み込み、revision 発行、watch/read cache の置換、navigation の変更を行いません。revision の照合後に row が投影済み rows に見つからなければ stable code `row_not_found`（stage `finalization`、recovery `inspect_session`、message `指定された文字起こし行が見つかりません`）です。revision、row の順に検査してから cursor を検証します。続きの cursor は同一 row/session/revision/navigation に結び付き、limit も navigation の limit と一致しなければ `invalid_cursor` です。

row-bearing details projection は clause state と materialized 順序の表示対象 spans の各 `id`、`start`、`end`、rendered display label で定義し、label は materialized `displayLabel` があればその値、なければ raw speaker id とします。projected rows が変わらず row-bearing details projection のみが変わった live update も revision を進め、watch に rows を含まない `reload_required` を送ります。confidence、`clauseSlices`、`textProjection`、`source.asrEventSeq` の変化、および empty/whitespace な rowless segment の変化は、projected rows と row-bearing details projection が同一である限り revision を進めず rows event を送りません。rowless span が見出しに影響して projected rows を変える場合があるため、rowless segment の変更を一律に無視する意味ではありません。`cursor: null` は有効な limit なら毎回 page navigation を新しく開始し、同じ limit の場合も過去の全 cursor token を失効させます。cursor は client が解釈しない UUID token で、実際に返した page 境界を保持します。speaker byte limit で短くなった page もその実境界に続き、`previous_cursor` は実際の前 page をたどります。別 row の詳細要求が成功すると engine-wide の保持 details snapshot を置換します。live update と `transcript.read` snapshot の置換は保持済み details を変更しません。対象 session の final transcript publication は一致する details snapshot を常に無効化します。details の取得は read cursor/navigation や watch の選択 session を変更しません。

completed envelope 全体は実際の canonical JSON UTF-8 bytes で `max_line_bytes = 1048576` 以下に制限し、LF は数えません。host は各 span の canonical encoded byte 数を cache し、span 間 comma と、最大 sequence / request ID および 36-byte UUID cursor 2個を含む空 envelope の固定 overhead を足して page を計算します。transcript rows の 700000-byte array budget と `max_row_bytes` は speaker spans には適用しません。単一 span または固定 metadata が envelope に収まらない場合は切り詰めず、stage `finalization`、stable code `row_too_large`、message `文字起こし行の詳細が大きすぎて返せません`、recovery `inspect_session` で失敗します。

実装: [`EngineTranscriptRowDetails.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol/EngineTranscriptRowDetails.swift)、[`EngineTranscriptRowDetailsSnapshot.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineTranscriptRowDetailsSnapshot.swift)、[`EngineApplication+Transcript.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineApplication+Transcript.swift)。tests: [`EngineApplicationRowDetailsTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationRowDetailsTests.swift)、[`EngineProtocolRowDetailsTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolRowDetailsTests.swift)。

incremental projection cache は materialized segment のうち変化したものだけを投影・diff し、run 全体の speaker mapping は保持します。row-bearing details comparison は rows が変わった場合は省略し、rows が同一の場合に lazy scan と materialized 順序での visible span field comparison を行います。comparison は details payload の構築や JSON encoding、span ごとの projection array を作らず、上流 segment 数を n、visible span 数を s として O(n+s)、visible row membership set は row 数 r に対して O(r) です。ただし現在の上流 API は毎回 snapshot 全体を渡すため、既存の更新入力走査は O(n) で、cache array も全体を組み立てます。bounded-memory または O(1) 更新の保証ではありません。

`EngineCodec.trustedRequestID(in:)` は entire record の lexical validation 後に限り canonical `request_id` を取り出します。全 record が lexical-valid で ID も canonical の場合だけ error correlation に利用し、それ以外の error ID は null です。invalid request は side effect を起こしません。最初の unsupported version は error を出して process を終了する扱いが host の責務です。EOF disconnect 時の durable recording stop も host responsibility で、protocol codec が実行する処理ではありません。

### 独立 wire example corpus

[`wire-v1.ndjson`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/Fixtures/wire-v1.ndjson) の102 record は独立例 corpus です。1つの process timeline ではなく、request ID / sequence / session lifecycle は例ごとに独立しており相互に整合する必要はありません。`device_not_found`、`power_failure`、`stage: startup` の failure record は codec contract の例で、Windows host の wire emission ではありません。corpus test が全行を strict decode して encoder bytes と照合し、documentation test は本書の corpus が fixture と byte 一致することを確認します。corpus の録音中 session summary は durable checkpoint に PCM chunk が commit 済みの例であり、`audio.available` と status `未処理` は capture activity だけでなく復旧した durable checkpoint に基づきます。日付付きの host-shaped folder example は Asia/Tokyo を前提とします。host の `session_id` は lowercase UUID ですが、codec は任意の空でない文字列を受け入れます。host が生成する cursor は opaque UUID token です。`model_failure` の `C:/Models/silero_vad.onnx` は明示的に設定された Silero model path の例で、括弧内の ONNX initialization reason は illustrative raw reason です。

[`EngineProtocolCorpusCoverageTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/EngineProtocolCorpusCoverageTests.swift) の coverage gate は corpus から required token registry を作りません。required token set は `coverageRepresentativeValues()` が返す代表 Swift 値を traversal-only encoder で再帰的に encode して導出し、`CodingKeys` の全 key、CaseIterable な wire enum の全値（Optional / Array / `EngineNullable` の wrapped type を含む）、`EngineNullable` field の null / non-null の両 arm、全 command の request と completed result、全 event を required にします。observed token set は corpus record を typed decode した `EngineRequest` / `EngineOutput` の値だけを同じ traversal に通して集めます。required と observed は双方向に比較され、完全一致を要求します。field coverage は envelope context の組合せごとでなく宣言元 Swift type ごとです。corpus record 自体は corpus test が strict decode と canonical byte roundtrip を検証し、全 object の unknown / missing / null / wrong-type mutation を拒否することも確認します。102 record は recording の starting / stopping と、recording とは独立した whole-scan recovery failure の lifecycle snapshot、session の recording / queued / processing、producer-shaped error outcomes、paging / settings の nullable 例、default のない device list、vad / diarization の progress を含みます。

```ndjson engine-protocol-v1
{"command":"hello","payload":{},"request_id":"1","version":1}
{"command":"state.get","payload":{},"request_id":"2","version":1}
{"command":"devices.list","payload":{"source":"microphone"},"request_id":"3","version":1}
{"command":"recording.start","payload":{"device":{"id":"wasapi-loopback-42","kind":"id"},"source":"system_audio"},"request_id":"4","version":1}
{"command":"recording.start","payload":{"device":{"kind":"default"},"source":"microphone"},"request_id":"5","version":1}
{"command":"recording.stop","payload":{"session_id":"session-live"},"request_id":"6","version":1}
{"command":"session.import","payload":{"input_path":"D:/Recordings/meeting.wav"},"request_id":"7","version":1}
{"command":"session.reprocess","payload":{"session_id":"session-finalized-2025-03-08T10-22-31Z"},"request_id":"8","version":1}
{"command":"session.retry_decisions","payload":{"session_id":"session-finalized-2025-03-08T10-22-31Z"},"request_id":"9","version":1}
{"command":"session.list","payload":{"cursor":null,"limit":20},"request_id":"10","version":1}
{"command":"transcript.read","payload":{"cursor":"rows-cursor-1","limit":75,"revision":"184","session_id":"session-finalized-2025-03-08T10-22-31Z"},"request_id":"11","version":1}
{"command":"transcript.watch","payload":{"session_id":"session-live"},"request_id":"12","version":1}
{"command":"session.export","payload":{"destination_path":"D:/Published/meeting-bundle","session_id":"session-finalized-2025-03-08T10-22-31Z"},"request_id":"13","version":1}
{"command":"settings.get","payload":{},"request_id":"14","version":1}
{"command":"settings.replace","payload":{"expected_revision":null,"settings":{"asr_size":"0.6b","automatic_export":true,"decisions_enabled":true,"device":{"kind":"default"},"execution_provider":"cpu","export_destination_path":null,"low_heat":true,"schema_version":1,"source":"microphone","threads":3}},"request_id":"15","version":1}
{"command":"models.prepare","payload":{},"request_id":"16","version":1}
{"command":"session.import","payload":{"input_path":"D:/Recordings/second-meeting.wav"},"request_id":"17","version":1}
{"command":"shutdown","payload":{},"request_id":"18446744073709551615","version":1}
{"event":"ready","payload":{"capabilities":{"asr_sizes":["0.6b","1.7b"],"automatic_input_volume":"none","execution_providers":["cpu"],"maximum_threads":4,"sources":["microphone","system_audio"],"thermal_monitoring":"none"},"state":{"failures":[],"presentation":{"audio_gap_count":0,"audio_gap_text":null,"live_failure_notices":[],"preparation_phase":"idle","preparation_status_text":null,"processing_indicator":"idle","processing_status_text":null,"recording_status_text":"待機中","recording_tone":"neutral","recovery_status_text":null,"silence_warning_active":false,"silence_warning_text":null},"queue":[],"recording":null,"recovery":"pending","revision":"1","screen":"idle","setup":"settings_required"}},"request_id":null,"sequence":"1","version":1}
{"event":"state","payload":{"failures":[{"cleanup_errors":[{"code":"ERROR_INVALID_HANDLE","device_id":null,"domain":"Win32","message":"録音ハンドルの解放にも失敗しました","path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-live"}],"code":"device_failure","details":[{"code":"AUDCLNT_E_DEVICE_INVALIDATED","device_id":"wasapi-mic-17","domain":"WASAPI","message":"録音デバイスが切断されました","path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-live/audio.wav"}],"message":"録音デバイスが利用できず、クリーンアップにも失敗しました","recovery_action":"select_device","request_id":"4","session_id":"session-live","severity":"error","stage":"capture"}],"presentation":{"audio_gap_count":2,"audio_gap_text":"音声の欠落: 2 回","live_failure_notices":[],"preparation_phase":"ready","preparation_status_text":null,"processing_indicator":"backlogged","processing_status_text":"文字起こし処理が待機中です","recording_status_text":"システム音声を録音中","recording_tone":"recording","recovery_status_text":"未完了の文字起こしを復旧しています（2件）","silence_warning_active":true,"silence_warning_text":"システム音声が30秒以上無音です"},"queue":[{"session_id":"session-queued-2","stage":"asr"},{"session_id":"session-queued-3","stage":"decisions"}],"recording":{"device":{"id":"wasapi-loopback-42","kind":"id"},"phase":"recording","session_id":"session-live","source":"system_audio"},"recovery":"running","revision":"42","screen":"live","setup":"ready"},"request_id":null,"sequence":"2","version":1}
{"event":"accepted","payload":{"command":"session.import"},"request_id":"7","sequence":"3","version":1}
{"event":"progress","payload":{"completed_units":1,"session_id":null,"stage":"import","total_units":4},"request_id":"7","sequence":"4","version":1}
{"event":"progress","payload":{"completed_units":2,"session_id":"session-imported-second","stage":"import","total_units":null},"request_id":"17","sequence":"5","version":1}
{"event":"error","payload":{"cleanup_errors":[{"code":"E_TEMP_CLEANUP","device_id":null,"domain":"filesystem","message":"一時ファイルの削除に失敗しました","path":"C:/Users/Aki/AppData/Local/Temp/import-stage"}],"code":"filesystem","details":[{"code":"ERROR_ACCESS_DENIED","device_id":null,"domain":"Win32","message":"アクセスが拒否されました","path":"D:/Recordings/meeting.wav"}],"message":"インポート元を読み取れませんでした","recovery_action":"retry","request_id":"7","session_id":null,"severity":"error","stage":"import"},"request_id":"7","sequence":"6","version":1}
{"event":"completed","payload":{"command":"hello","result":{"capabilities":{"asr_sizes":["0.6b","1.7b"],"automatic_input_volume":"none","execution_providers":["cpu"],"maximum_threads":4,"sources":["microphone","system_audio"],"thermal_monitoring":"none"},"state":{"failures":[],"presentation":{"audio_gap_count":0,"audio_gap_text":null,"live_failure_notices":[],"preparation_phase":"idle","preparation_status_text":null,"processing_indicator":"idle","processing_status_text":null,"recording_status_text":"待機中","recording_tone":"neutral","recovery_status_text":null,"silence_warning_active":false,"silence_warning_text":null},"queue":[],"recording":null,"recovery":"pending","revision":"1","screen":"idle","setup":"settings_required"}}},"request_id":"1","sequence":"7","version":1}
{"event":"completed","payload":{"command":"state.get","result":{"failures":[{"cleanup_errors":[{"code":"ERROR_INVALID_HANDLE","device_id":null,"domain":"Win32","message":"録音ハンドルの解放にも失敗しました","path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-live"}],"code":"device_failure","details":[{"code":"AUDCLNT_E_DEVICE_INVALIDATED","device_id":"wasapi-mic-17","domain":"WASAPI","message":"録音デバイスが切断されました","path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-live/audio.wav"}],"message":"録音デバイスが利用できず、クリーンアップにも失敗しました","recovery_action":"select_device","request_id":"4","session_id":"session-live","severity":"error","stage":"capture"}],"presentation":{"audio_gap_count":2,"audio_gap_text":"音声の欠落: 2 回","live_failure_notices":["録音は継続しています。ライブ文字起こしを停止しました: 推論に失敗しました"],"preparation_phase":"ready","preparation_status_text":null,"processing_indicator":"partial_failure","processing_status_text":"録音中の発話を文字起こししています","recording_status_text":"マイクを録音中","recording_tone":"recording","recovery_status_text":"未完了の文字起こしを復旧しています（2件）","silence_warning_active":true,"silence_warning_text":"マイク入力が30秒以上無音です。ミュート設定を確認してください"},"queue":[{"session_id":"session-queued-2","stage":"asr"},{"session_id":"session-queued-3","stage":"decisions"}],"recording":{"device":{"id":"wasapi-mic-17","kind":"id"},"phase":"recording","session_id":"session-live","source":"microphone"},"recovery":"running","revision":"42","screen":"live","setup":"ready"}},"request_id":"2","sequence":"8","version":1}
{"event":"completed","payload":{"command":"devices.list","result":{"default_device_id":"wasapi-loopback-42","devices":[{"id":"wasapi-loopback-42","is_default":true,"name":"Speakers (High Definition Audio)"},{"id":"wasapi-loopback-73","is_default":false,"name":"USB Audio Output"}],"source":"system_audio"}},"request_id":"3","sequence":"9","version":1}
{"event":"completed","payload":{"command":"recording.start","result":{"session_id":"session-live"}},"request_id":"4","sequence":"10","version":1}
{"event":"completed","payload":{"command":"recording.start","result":{"session_id":"session-microphone"}},"request_id":"5","sequence":"11","version":1}
{"event":"completed","payload":{"command":"recording.stop","result":{"session_id":"session-live"}},"request_id":"6","sequence":"12","version":1}
{"event":"completed","payload":{"command":"session.import","result":{"session_id":"session-imported-second"}},"request_id":"17","sequence":"13","version":1}
{"event":"completed","payload":{"command":"session.reprocess","result":{"session_id":"session-finalized-2025-03-08T10-22-31Z"}},"request_id":"8","sequence":"14","version":1}
{"event":"completed","payload":{"command":"session.retry_decisions","result":{"session_id":"session-finalized-2025-03-08T10-22-31Z"}},"request_id":"9","sequence":"15","version":1}
{"event":"completed","payload":{"command":"session.list","result":{"next_cursor":"folder-page-cursor-2","previous_cursor":null,"sessions":[{"can_export":false,"can_reprocess":false,"can_retry_decisions":false,"display_name":"日時を読み取れません","error":{"cleanup_errors":[],"code":"filesystem","details":[{"code":"fileReadCorruptFile","device_id":null,"domain":"Foundation.FileManager","message":"メタデータの形式が正しくありません","path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/stable-folder-id-corrupt-metadata-17/session.json"}],"message":"セッション情報を読み取れません","recovery_action":"inspect_session","request_id":null,"session_id":null,"severity":"warning","stage":"recovery"},"export_path":null,"folder_id":"stable-folder-id-corrupt-metadata-17","folder_path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/stable-folder-id-corrupt-metadata-17","metadata":{"kind":"unreadable","reason":"セッション情報を読み取れません"},"session_id":null,"status":"unreadable","status_text":"読み込みエラー: セッション情報を読み取れません"},{"can_export":true,"can_reprocess":true,"can_retry_decisions":false,"display_name":"2025年3月8日 19:22","error":null,"export_path":null,"folder_id":"session-folder-2025-03-08-live","folder_path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-folder-2025-03-08-live","metadata":{"audio":{"kind":"available"},"created_at":1741429351,"has_transcript":true,"kind":"readable","source":{"kind":"microphone"}},"session_id":"session-finalized-2025-03-08T10-22-31Z","status":"finalized","status_text":"文字起こしあり"},{"can_export":false,"can_reprocess":false,"can_retry_decisions":false,"display_name":"2025年3月10日 17:00","error":null,"export_path":null,"folder_id":"session-folder-system-audio-missing-2025-03-10T08-00-00Z","folder_path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-folder-system-audio-missing-2025-03-10T08-00-00Z","metadata":{"audio":{"kind":"missing"},"created_at":1741593600,"has_transcript":false,"kind":"readable","source":{"kind":"system_audio"}},"session_id":"session-system-audio-missing-2025-03-10T08-00-00Z","status":"failed","status_text":"保存済み音声がありません"},{"can_export":false,"can_reprocess":false,"can_retry_decisions":false,"display_name":"2025年3月11日 9:30","error":null,"export_path":null,"folder_id":"session-folder-imported-audio-unreadable-2025-03-11T00-30-00Z","folder_path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-folder-imported-audio-unreadable-2025-03-11T00-30-00Z","metadata":{"audio":{"kind":"unreadable","reason":"音声ファイルを読めません"},"created_at":1741653000,"has_transcript":false,"kind":"readable","source":{"kind":"imported","original_filename":"meeting.wav"}},"session_id":"session-imported-audio-unreadable-2025-03-11T00-30-00Z","status":"failed","status_text":"音声を読めません: 音声ファイルを読めません"},{"can_export":true,"can_reprocess":true,"can_retry_decisions":false,"display_name":"2025年3月8日 19:22","error":{"cleanup_errors":[],"code":"export_failure","details":[],"message":"書き出し先を確認できません: アクセスが拒否されました","recovery_action":"retry","request_id":null,"session_id":"session-export-probe-failed","severity":"error","stage":"export"},"export_path":null,"folder_id":"session-folder-export-probe-failed","folder_path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-folder-export-probe-failed","metadata":{"audio":{"kind":"available"},"created_at":1741429351,"has_transcript":true,"kind":"readable","source":{"kind":"microphone"}},"session_id":"session-export-probe-failed","status":"finalized","status_text":"文字起こしあり"}]}},"request_id":"10","sequence":"16","version":1}
{"event":"completed","payload":{"command":"transcript.read","result":{"next_cursor":"rows-cursor-after-2","previous_cursor":"rows-cursor-before-2","revision":"184","rows":[{"clause_state":null,"end_ms":900,"headings":["Speaker 1"],"row_id":"row-1","start_ms":0,"text":"おはよう、世界😀\n次の行です"},{"clause_state":"awaiting_next_segment","end_ms":2150,"headings":["Speaker 2"],"row_id":"row-2","start_ms":1250,"text":"日本語の発話 2 😀"}],"session_id":"session-finalized-2025-03-08T10-22-31Z"}},"request_id":"11","sequence":"17","version":1}
{"event":"completed","payload":{"command":"transcript.watch","result":{"next_cursor":null,"previous_cursor":null,"revision":"185","rows":[{"clause_state":"boundary_pending","end_ms":3400,"headings":["Speaker 3"],"row_id":"row-3","start_ms":2500,"text":"日本語の発話 3 😀"},{"clause_state":"priority_pending","end_ms":4650,"headings":["Speaker 4"],"row_id":"row-4","start_ms":3750,"text":"日本語の発話 4 😀"}],"session_id":"session-live"}},"request_id":"12","sequence":"18","version":1}
{"event":"completed","payload":{"command":"session.export","result":{"destination_path":"D:/Published/meeting-bundle","session_id":"session-finalized-2025-03-08T10-22-31Z"}},"request_id":"13","sequence":"19","version":1}
{"event":"completed","payload":{"command":"settings.get","result":{"revision":"8","settings":{"asr_size":"0.6b","automatic_export":true,"decisions_enabled":true,"device":{"kind":"default"},"execution_provider":"cpu","export_destination_path":"D:/Ambient Exports","low_heat":true,"schema_version":1,"source":"microphone","threads":3}}},"request_id":"14","sequence":"20","version":1}
{"event":"completed","payload":{"command":"settings.replace","result":{"revision":"9","settings":{"asr_size":"0.6b","automatic_export":true,"decisions_enabled":true,"device":{"kind":"default"},"execution_provider":"cpu","export_destination_path":"D:/Ambient Exports","low_heat":true,"schema_version":1,"source":"microphone","threads":3}}},"request_id":"15","sequence":"21","version":1}
{"event":"completed","payload":{"command":"models.prepare","result":{}},"request_id":"16","sequence":"22","version":1}
{"event":"completed","payload":{"command":"shutdown","result":{}},"request_id":"18446744073709551615","sequence":"23","version":1}
{"event":"rows","payload":{"kind":"snapshot","next_cursor":"live-rows-page-2","removed_row_ids":[],"revision":"186","rows":[{"clause_state":null,"end_ms":900,"headings":["Speaker 1"],"row_id":"row-1","start_ms":0,"text":"おはよう、世界😀\n次の行です"},{"clause_state":"awaiting_next_segment","end_ms":2150,"headings":["Speaker 2"],"row_id":"row-2","start_ms":1250,"text":"日本語の発話 2 😀"},{"clause_state":"boundary_pending","end_ms":3400,"headings":["Speaker 3"],"row_id":"row-3","start_ms":2500,"text":"日本語の発話 3 😀"},{"clause_state":"priority_pending","end_ms":4650,"headings":["Speaker 4"],"row_id":"row-4","start_ms":3750,"text":"日本語の発話 4 😀"},{"clause_state":"classified","end_ms":5900,"headings":["Speaker 5"],"row_id":"row-5","start_ms":5000,"text":"日本語の発話 5 😀"},{"clause_state":"classified","end_ms":7150,"headings":["Speaker 6"],"row_id":"row-6","start_ms":6250,"text":"日本語の発話 6 😀"},{"clause_state":"awaiting_next_segment","end_ms":8400,"headings":["Speaker 7"],"row_id":"row-7","start_ms":7500,"text":"日本語の発話 7 😀"},{"clause_state":"boundary_pending","end_ms":9650,"headings":["OTHER"],"row_id":"row-8","start_ms":8750,"text":"日本語の発話 8 😀"},{"clause_state":"priority_pending","end_ms":10900,"headings":["UNKNOWN"],"row_id":"row-9","start_ms":10000,"text":"日本語の発話 9 😀"}],"session_id":"session-live"},"request_id":null,"sequence":"24","version":1}
{"event":"rows","payload":{"kind":"changes","next_cursor":null,"removed_row_ids":["row-stale-4"],"revision":"187","rows":[{"clause_state":"classified","end_ms":12150,"headings":["Speaker 3"],"row_id":"row-10","start_ms":11250,"text":"変更された発話 😺"}],"session_id":"session-live"},"request_id":null,"sequence":"25","version":1}
{"event":"rows","payload":{"kind":"reload_required","next_cursor":null,"removed_row_ids":[],"revision":"188","rows":[],"session_id":"session-live"},"request_id":null,"sequence":"26","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"processing_failure","details":[{"code":"MODEL_EXECUTION_FAILED","device_id":null,"domain":"PortableRuntime","message":"推論処理を完了できませんでした","path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/models/asr/model.onnx"}],"message":"バックグラウンド処理に失敗しました。セッションを確認してください","recovery_action":"reprocess","request_id":null,"session_id":"session-background-8","severity":"warning","stage":"asr"},"request_id":null,"sequence":"27","version":1}
{"event":"error","payload":{"cleanup_errors":[{"code":"ERROR_INVALID_HANDLE","device_id":null,"domain":"Win32","message":"録音ハンドルの解放にも失敗しました","path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-live"}],"code":"device_failure","details":[{"code":"AUDCLNT_E_DEVICE_INVALIDATED","device_id":"wasapi-mic-17","domain":"WASAPI","message":"録音デバイスが切断されました","path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-live/audio.wav"}],"message":"録音デバイスが利用できず、クリーンアップにも失敗しました","recovery_action":"select_device","request_id":"4","session_id":"session-live","severity":"error","stage":"capture"},"request_id":"4","sequence":"28","version":1}
{"command":"session.inspect","payload":{"folder_id":"stable-folder-id-corrupt-metadata-17"},"request_id":"18","version":1}
{"event":"completed","payload":{"command":"session.inspect","result":{"can_export":false,"can_reprocess":false,"can_retry_decisions":false,"display_name":"日時を読み取れません","error":{"cleanup_errors":[],"code":"filesystem","details":[{"code":"fileReadCorruptFile","device_id":null,"domain":"Foundation.FileManager","message":"メタデータの形式が正しくありません","path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/stable-folder-id-corrupt-metadata-17/session.json"}],"message":"セッション情報を読み取れません","recovery_action":"inspect_session","request_id":null,"session_id":"session-known-unreadable-17","severity":"warning","stage":"recovery"},"export_path":null,"folder_id":"stable-folder-id-corrupt-metadata-17","folder_path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/stable-folder-id-corrupt-metadata-17","metadata":{"kind":"unreadable","reason":"セッション情報を読み取れません"},"session_id":"session-known-unreadable-17","status":"unreadable","status_text":"読み込みエラー: セッション情報を読み取れません"}},"request_id":"18","sequence":"29","version":1}
{"event":"completed","payload":{"command":"session.inspect","result":{"can_export":true,"can_reprocess":true,"can_retry_decisions":false,"display_name":"2025年3月11日 9:30","error":null,"export_path":"D:/Published/session-folder-imported","folder_id":"session-folder-imported-audio-unreadable-2025-03-11T00-30-00Z","folder_path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-folder-imported-audio-unreadable-2025-03-11T00-30-00Z","metadata":{"audio":{"kind":"available"},"created_at":1741653000,"has_transcript":true,"kind":"readable","source":{"kind":"imported","original_filename":"meeting.wav"}},"session_id":"session-imported-audio-unreadable-2025-03-11T00-30-00Z","status":"finalized","status_text":"文字起こしあり"}},"request_id":"19","sequence":"30","version":1}
{"command":"diagnostics.get","payload":{},"request_id":"19","version":1}
{"command":"models.inspect","payload":{},"request_id":"20","version":1}
{"event":"completed","payload":{"command":"diagnostics.get","result":{"automatic_input_volume":"none","decision_usage":{"kind":"available","snapshot":{"boundary_requests":{"failure_count":1,"input_tokens":11,"send_count":2,"success_count":1},"failure_count":2,"input_tokens":28,"pending_boundary_segment_count":2,"pending_priority_clause_count":3,"priority_requests":{"failure_count":1,"input_tokens":17,"send_count":2,"success_count":1},"send_count":4,"success_count":2}},"scope":"engine_process","thermal_monitoring":"none"}},"request_id":"19","sequence":"35","version":1}
{"event":"completed","payload":{"command":"diagnostics.get","result":{"automatic_input_volume":"none","decision_usage":{"error":{"cleanup_errors":[],"code":"internal_error","details":[{"code":"DECISION_BACKEND_UNAVAILABLE","device_id":null,"domain":"native","message":"ネイティブ判断バックエンドに接続できません","path":null}],"message":"判断情報を収集できませんでした","recovery_action":"retry","request_id":null,"session_id":null,"severity":"error","stage":"decisions"},"kind":"unavailable"},"scope":"engine_process","thermal_monitoring":"none"}},"request_id":"19","sequence":"36","version":1}
{"event":"completed","payload":{"command":"models.inspect","result":{"clause_tagger":{"identity":{"backend":"onnx-clause-tagger","model_id":"Pokojaka/modernbert-ja-30m-utterance-tagger","revision":"90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9","tokenizer_sha256":"0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062"},"kind":"validated"}}},"request_id":"20","sequence":"37","version":1}
{"event":"completed","payload":{"command":"models.inspect","result":{"clause_tagger":{"error":{"cleanup_errors":[],"code":"model_corrupt","details":[{"code":"clause_tagger","device_id":null,"domain":"models","message":"モデル(clause_tagger)が不正です: C:/Users/Aki/AppData/Local/mac-ambient-jev/models/clause-tagger/5c0213592cf8d59fc0b665183ab7536ddde05d1f/clause-tagger-onnx/ClauseTagger.onnx (サイズが一致しません (期待: 146889562, 実際: 1))。次の手順で配置し直してください: python3 scripts/fetch_clause_tagger.py --format onnx を実行し、出力されたディレクトリの内容を C:/Users/Aki/AppData/Local/mac-ambient-jev/models/clause-tagger/5c0213592cf8d59fc0b665183ab7536ddde05d1f/clause-tagger-onnx に置く","path":null}],"message":"モデル(clause_tagger)が不正です: C:/Users/Aki/AppData/Local/mac-ambient-jev/models/clause-tagger/5c0213592cf8d59fc0b665183ab7536ddde05d1f/clause-tagger-onnx/ClauseTagger.onnx (サイズが一致しません (期待: 146889562, 実際: 1))。次の手順で配置し直してください: python3 scripts/fetch_clause_tagger.py --format onnx を実行し、出力されたディレクトリの内容を C:/Users/Aki/AppData/Local/mac-ambient-jev/models/clause-tagger/5c0213592cf8d59fc0b665183ab7536ddde05d1f/clause-tagger-onnx に置く","recovery_action":"prepare_models","request_id":null,"session_id":null,"severity":"error","stage":"validating_models"},"kind":"invalid"}}},"request_id":"20","sequence":"38","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"cancelled","details":[],"message":"モデルの確認が中止されました","recovery_action":"none","request_id":"20","session_id":null,"severity":"error","stage":"validating_models"},"request_id":"20","sequence":"39","version":1}
{"command":"transcript.row_details","payload":{"cursor":null,"limit":2,"revision":"201","row_id":"row-detail-201","session_id":"session-detail-a"},"request_id":"101","version":1}
{"command":"transcript.row_details","payload":{"cursor":"11111111-1111-4111-8111-111111111111","limit":2,"revision":"202","row_id":"row-detail-202","session_id":"session-detail-b"},"request_id":"102","version":1}
{"event":"completed","payload":{"command":"transcript.row_details","result":{"clause_state":"awaiting_next_segment","clause_state_text":"発話文: 続き待ち","next_cursor":"11111111-1111-4111-8111-111111111111","previous_cursor":null,"revision":"201","row_id":"row-detail-201","session_id":"session-detail-a","speakers":[{"display_label":"Speaker 1","end_ms":850,"speaker_id":"speaker-internal-101","start_ms":0},{"display_label":"Speaker 1","end_ms":1500,"speaker_id":"speaker-internal-101","start_ms":700}]}},"request_id":"101","sequence":"101","version":1}
{"event":"completed","payload":{"command":"transcript.row_details","result":{"clause_state":"boundary_pending","clause_state_text":"発話文: 境界判定を保留中","next_cursor":"22222222-2222-4222-8222-222222222222","previous_cursor":"33333333-3333-4333-8333-333333333333","revision":"202","row_id":"row-detail-202","session_id":"session-detail-b","speakers":[{"display_label":"Speaker 2","end_ms":1200,"speaker_id":"speaker-internal-202","start_ms":400},{"display_label":"Speaker 3","end_ms":2100,"speaker_id":"speaker-internal-203","start_ms":1100}]}},"request_id":"102","sequence":"102","version":1}
{"event":"completed","payload":{"command":"transcript.row_details","result":{"clause_state":"priority_pending","clause_state_text":"発話文: 優先度判定を待っています","next_cursor":"44444444-4444-4444-8444-444444444444","previous_cursor":"55555555-5555-4555-8555-555555555555","revision":"203","row_id":"row-detail-203","session_id":"session-detail-c","speakers":[{"display_label":"Speaker 4","end_ms":3000,"speaker_id":"speaker-internal-204","start_ms":2000},{"display_label":"Speaker 5","end_ms":4150,"speaker_id":"speaker-internal-205","start_ms":3100},{"display_label":"Speaker 6","end_ms":5200,"speaker_id":"speaker-internal-206","start_ms":4200}]}},"request_id":"103","sequence":"103","version":1}
{"event":"completed","payload":{"command":"transcript.row_details","result":{"clause_state":"classified","clause_state_text":"発話文: 判定済み","next_cursor":null,"previous_cursor":"66666666-6666-4666-8666-666666666666","revision":"204","row_id":"row-detail-204","session_id":"session-detail-d","speakers":[{"display_label":"Speaker 7","end_ms":6200,"speaker_id":"speaker-internal-207","start_ms":5100},{"display_label":"OTHER","end_ms":7000,"speaker_id":"speaker-internal-other","start_ms":6300},{"display_label":"UNKNOWN","end_ms":7900,"speaker_id":"speaker-internal-unknown","start_ms":7100},{"display_label":"speaker-raw-208","end_ms":8500,"speaker_id":"speaker-raw-208","start_ms":8000}]}},"request_id":"104","sequence":"104","version":1}
{"event":"completed","payload":{"command":"transcript.row_details","result":{"clause_state":"classified","clause_state_text":"発話文: 判定済み","next_cursor":null,"previous_cursor":null,"revision":"205","row_id":"row-detail-205","session_id":"session-detail-empty","speakers":[]}},"request_id":"105","sequence":"105","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"row_not_found","details":[],"message":"指定された文字起こし行が見つかりません","recovery_action":"inspect_session","request_id":"108","session_id":"session-detail-missing","severity":"error","stage":"finalization"},"request_id":"108","sequence":"106","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"stale_revision","details":[],"message":"文字起こしの revision が古くなっています。最初から読み直してください","recovery_action":"retry","request_id":"109","session_id":"session-detail-stale","severity":"error","stage":"finalization"},"request_id":"109","sequence":"107","version":1}
{"event":"completed","payload":{"command":"state.get","result":{"failures":[],"presentation":{"audio_gap_count":2,"audio_gap_text":null,"live_failure_notices":[],"preparation_phase":"ready","preparation_status_text":null,"processing_indicator":"running","processing_status_text":"発話区間を検出しています","recording_status_text":"録音を保存しました（00:30・発話 2区間）","recording_tone":"neutral","recovery_status_text":null,"silence_warning_active":false,"silence_warning_text":null},"queue":[{"session_id":"session-finalizing-43","stage":"finalization"}],"recording":null,"recovery":"completed","revision":"43","screen":"finalizing","setup":"ready"}},"request_id":"201","sequence":"201","version":1}
{"event":"completed","payload":{"command":"state.get","result":{"failures":[],"presentation":{"audio_gap_count":2,"audio_gap_text":null,"live_failure_notices":[],"preparation_phase":"ready","preparation_status_text":null,"processing_indicator":"complete","processing_status_text":"文字起こしと話者分離が完了しました（4区間）","recording_status_text":"録音を保存しました（00:30・発話 2区間）","recording_tone":"neutral","recovery_status_text":null,"silence_warning_active":false,"silence_warning_text":null},"queue":[],"recording":null,"recovery":"completed","revision":"44","screen":"finalized","setup":"ready"}},"request_id":"202","sequence":"202","version":1}
{"event":"completed","payload":{"command":"state.get","result":{"failures":[],"presentation":{"audio_gap_count":0,"audio_gap_text":null,"live_failure_notices":[],"preparation_phase":"preparing","preparation_status_text":"音声認識モデルを読み込み中（80%）","processing_indicator":"idle","processing_status_text":null,"recording_status_text":"待機中","recording_tone":"neutral","recovery_status_text":null,"silence_warning_active":false,"silence_warning_text":null},"queue":[],"recording":null,"recovery":"pending","revision":"45","screen":"idle","setup":"models_required"}},"request_id":"203","sequence":"203","version":1}
{"event":"completed","payload":{"command":"state.get","result":{"failures":[],"presentation":{"audio_gap_count":0,"audio_gap_text":null,"live_failure_notices":[],"preparation_phase":"failed","preparation_status_text":"準備できませんでした: 認識モデルを検証できません","processing_indicator":"idle","processing_status_text":null,"recording_status_text":"待機中","recording_tone":"error","recovery_status_text":null,"silence_warning_active":false,"silence_warning_text":null},"queue":[],"recording":null,"recovery":"pending","revision":"46","screen":"idle","setup":"models_required"}},"request_id":"204","sequence":"204","version":1}
{"event":"completed","payload":{"command":"state.get","result":{"failures":[],"presentation":{"audio_gap_count":2,"audio_gap_text":null,"live_failure_notices":[],"preparation_phase":"idle","preparation_status_text":null,"processing_indicator":"idle","processing_status_text":"処理は中断されました。次回の起動時に再開できます","recording_status_text":"録音は保存しましたが、一部の音声が欠落した可能性があります。","recording_tone":"warning","recovery_status_text":null,"silence_warning_active":false,"silence_warning_text":null},"queue":[{"session_id":"session-held-46","stage":"finalization"}],"recording":null,"recovery":"completed","revision":"47","screen":"finalizing","setup":"ready"}},"request_id":"205","sequence":"205","version":1}
{"event":"state","payload":{"failures":[],"presentation":{"audio_gap_count":1,"audio_gap_text":"音声の欠落: 1 回","live_failure_notices":[],"preparation_phase":"ready","preparation_status_text":null,"processing_indicator":"idle","processing_status_text":null,"recording_status_text":"録音デバイスの復帰を待っています","recording_tone":"warning","recovery_status_text":null,"silence_warning_active":false,"silence_warning_text":null},"queue":[],"recording":{"device":{"id":"wasapi-mic-reconnect","kind":"id"},"phase":"waiting_for_device","session_id":"session-reconnect","source":"microphone"},"recovery":"completed","revision":"115","screen":"live","setup":"ready"},"request_id":null,"sequence":"115","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"device_lost","details":[{"code":"reopen","device_id":null,"domain":"capture","message":"Native operation mja_capture_open failed with code -401","path":null}],"message":"録音デバイスが30秒以内に復帰しなかったため録音を停止しました。録音は保存されています","recovery_action":"select_device","request_id":null,"session_id":"session-reconnect","severity":"warning","stage":"capture"},"request_id":null,"sequence":"116","version":1}
{"command":"session.list","payload":{"cursor":"11111111-1111-4111-8111-111111111302","limit":20},"request_id":"301","version":1}
{"command":"transcript.read","payload":{"cursor":null,"limit":75,"revision":null,"session_id":"00000001-0000-4000-8000-000000000001"},"request_id":"302","version":1}
{"command":"settings.replace","payload":{"expected_revision":"9","settings":{"asr_size":"1.7b","automatic_export":true,"decisions_enabled":true,"device":{"id":"wasapi-loopback-42","kind":"id"},"execution_provider":"cpu","export_destination_path":"D:/Ambient Exports","low_heat":true,"schema_version":1,"source":"system_audio","threads":3}},"request_id":"303","version":1}
{"event":"completed","payload":{"command":"devices.list","result":{"default_device_id":null,"devices":[],"source":"microphone"}},"request_id":"400","sequence":"300","version":1}
{"event":"completed","payload":{"command":"session.list","result":{"next_cursor":null,"previous_cursor":"11111111-1111-4111-8111-111111111301","sessions":[{"can_export":false,"can_reprocess":false,"can_retry_decisions":false,"display_name":"2025年3月8日 19:22","error":null,"export_path":null,"folder_id":"2025-03-08_19-22-31_録音_00000002","folder_path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/2025-03-08_19-22-31_録音_00000002","metadata":{"audio":{"kind":"available"},"created_at":1741429351,"has_transcript":false,"kind":"readable","source":{"kind":"microphone"}},"session_id":"00000002-0000-4000-8000-000000000002","status":"recording","status_text":"未処理"},{"can_export":false,"can_reprocess":false,"can_retry_decisions":false,"display_name":"2025年3月8日 19:22","error":null,"export_path":null,"folder_id":"2025-03-08_19-22-31_meeting_00000003","folder_path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/2025-03-08_19-22-31_meeting_00000003","metadata":{"audio":{"kind":"available"},"created_at":1741429351,"has_transcript":false,"kind":"readable","source":{"kind":"imported","original_filename":"meeting.wav"}},"session_id":"00000003-0000-4000-8000-000000000003","status":"queued","status_text":"未処理"},{"can_export":false,"can_reprocess":false,"can_retry_decisions":false,"display_name":"2025年3月8日 19:22","error":null,"export_path":null,"folder_id":"2025-03-08_19-22-31_録音_00000004","folder_path":"C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/2025-03-08_19-22-31_録音_00000004","metadata":{"audio":{"kind":"available"},"created_at":1741429351,"has_transcript":false,"kind":"readable","source":{"kind":"system_audio"}},"session_id":"00000004-0000-4000-8000-000000000004","status":"processing","status_text":"処理中"}]}},"request_id":"401","sequence":"301","version":1}
{"event":"completed","payload":{"command":"state.get","result":{"failures":[],"presentation":{"audio_gap_count":0,"audio_gap_text":null,"live_failure_notices":[],"preparation_phase":"ready","preparation_status_text":null,"processing_indicator":"idle","processing_status_text":null,"recording_status_text":"録音を開始しています","recording_tone":"neutral","recovery_status_text":null,"silence_warning_active":false,"silence_warning_text":null},"queue":[],"recording":{"device":{"kind":"default"},"phase":"starting","session_id":"00000005-0000-4000-8000-000000000005","source":"microphone"},"recovery":"completed","revision":"300","screen":"live","setup":"ready"}},"request_id":"402","sequence":"302","version":1}
{"event":"completed","payload":{"command":"state.get","result":{"failures":[],"presentation":{"audio_gap_count":0,"audio_gap_text":null,"live_failure_notices":[],"preparation_phase":"ready","preparation_status_text":null,"processing_indicator":"idle","processing_status_text":null,"recording_status_text":"録音を保存しています","recording_tone":"neutral","recovery_status_text":null,"silence_warning_active":false,"silence_warning_text":null},"queue":[],"recording":{"device":{"kind":"default"},"phase":"stopping","session_id":"00000006-0000-4000-8000-000000000006","source":"microphone"},"recovery":"completed","revision":"301","screen":"finalizing","setup":"ready"}},"request_id":"403","sequence":"303","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"invalid_request","details":[],"message":"hello は最初のリクエストでのみ送れます","recovery_action":"none","request_id":"410","session_id":null,"severity":"error","stage":"protocol"},"request_id":"410","sequence":"310","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"unsupported_version","details":[{"code":"unsupported_version","device_id":null,"domain":"engine","message":"unsupportedVersion(2)","path":null}],"message":"サポートされていない version です。version 1 のみ対応しています","recovery_action":"restart","request_id":"411","session_id":null,"severity":"fatal","stage":"protocol"},"request_id":"411","sequence":"311","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"invalid_request_id","details":[],"message":"request_id は直前の値より大きい必要があります","recovery_action":"none","request_id":"412","session_id":null,"severity":"error","stage":"protocol"},"request_id":"412","sequence":"312","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"hello_required","details":[],"message":"最初のリクエストは hello である必要があります","recovery_action":"none","request_id":"413","session_id":null,"severity":"error","stage":"protocol"},"request_id":"413","sequence":"313","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"busy","details":[],"message":"録音または取り込みを実行中です","recovery_action":"retry","request_id":"414","session_id":null,"severity":"error","stage":"capture"},"request_id":"414","sequence":"314","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"settings_required","details":[],"message":"設定が必要です。設定ファイルがありません: C:/Users/Aki/AppData/Local/mac-ambient-jev/settings.json","recovery_action":"replace_settings","request_id":"415","session_id":null,"severity":"error","stage":"settings"},"request_id":"415","sequence":"315","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"invalid_settings","details":[],"message":"設定が不正です: invalidJSON(\"threads exceed logical CPU limit\")","recovery_action":"replace_settings","request_id":"416","session_id":null,"severity":"error","stage":"settings"},"request_id":"416","sequence":"316","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"invalid_cursor","details":[],"message":"cursor には revision が必要です","recovery_action":"none","request_id":"417","session_id":"00000001-0000-4000-8000-000000000001","severity":"error","stage":"finalization"},"request_id":"417","sequence":"317","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"session_not_found","details":[],"message":"保存済み録音が見つからないか、読み取れません","recovery_action":"inspect_session","request_id":"418","session_id":"00000001-0000-4000-8000-000000000001","severity":"error","stage":"recovery"},"request_id":"418","sequence":"318","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"device_not_found","details":[],"message":"指定された録音デバイスが見つかりません","recovery_action":"select_device","request_id":"419","session_id":null,"severity":"error","stage":"devices"},"request_id":"419","sequence":"319","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"capture_failure","details":[],"message":"録音を保存できませんでした","recovery_action":"reprocess","request_id":"420","session_id":"00000007-0000-4000-8000-000000000007","severity":"error","stage":"capture"},"request_id":"420","sequence":"320","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"disk_space","details":[{"code":"AudioCaptureEngineError","device_id":null,"domain":"swift","message":"90分の録音に必要な空き容量がありません（必要: 601 MB）","path":null}],"message":"90分の録音に必要な空き容量がありません（必要: 601 MB）","recovery_action":"free_disk_space","request_id":"421","session_id":"00000007-0000-4000-8000-000000000007","severity":"error","stage":"capture"},"request_id":"421","sequence":"321","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"power_failure","details":[],"message":"終了処理中に電源状態を確認できませんでした","recovery_action":"restart","request_id":"422","session_id":null,"severity":"fatal","stage":"shutdown"},"request_id":"422","sequence":"322","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"model_missing","details":[],"message":"モデルが準備されていません。models.prepare を実行してください","recovery_action":"prepare_models","request_id":"423","session_id":null,"severity":"error","stage":"capture"},"request_id":"423","sequence":"323","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"model_failure","details":[{"code":"vad","device_id":null,"domain":"models","message":"モデル(vad)を読み込めません: C:/Models/silero_vad.onnx (ONNX Runtime の初期化に失敗しました)","path":null}],"message":"モデル(vad)を読み込めません: C:/Models/silero_vad.onnx (ONNX Runtime の初期化に失敗しました)","recovery_action":"prepare_models","request_id":"424","session_id":null,"severity":"error","stage":"loading_models"},"request_id":"424","sequence":"324","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"row_too_large","details":[],"message":"文字起こし行の詳細が大きすぎて返せません","recovery_action":"inspect_session","request_id":"425","session_id":"00000001-0000-4000-8000-000000000001","severity":"error","stage":"finalization"},"request_id":"425","sequence":"325","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"processing_failure","details":[],"message":"発話文の判定を再試行できませんでした: テスト判定エンジンに失敗しました","recovery_action":"retry_decisions","request_id":"426","session_id":"00000008-0000-4000-8000-000000000008","severity":"error","stage":"decisions"},"request_id":"426","sequence":"326","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"capture_failure","details":[],"message":"録音の保存に失敗しました","recovery_action":"reprocess","request_id":null,"session_id":"00000009-0000-4000-8000-000000000009","severity":"fatal","stage":"capture"},"request_id":null,"sequence":"330","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"filesystem","details":[],"message":"保存済み録音の音声を整理できませんでした: 音声ファイルを読み取れません","recovery_action":"inspect_session","request_id":null,"session_id":"0000000a-0000-4000-8000-00000000000a","severity":"error","stage":"maintenance"},"request_id":null,"sequence":"331","version":1}
{"event":"progress","payload":{"completed_units":0,"session_id":"00000004-0000-4000-8000-000000000004","stage":"vad","total_units":null},"request_id":null,"sequence":"332","version":1}
{"event":"progress","payload":{"completed_units":0,"session_id":"00000004-0000-4000-8000-000000000004","stage":"diarization","total_units":null},"request_id":null,"sequence":"333","version":1}
{"event":"error","payload":{"cleanup_errors":[],"code":"internal_error","details":[],"message":"起動時の初期化に失敗しました","recovery_action":"restart","request_id":null,"session_id":null,"severity":"fatal","stage":"startup"},"request_id":null,"sequence":"334","version":1}
{"event":"completed","payload":{"command":"state.get","result":{"failures":[{"cleanup_errors":[],"code":"filesystem","details":[],"message":"未完了セッションを復旧できませんでした: セッション一覧を読み取れません","recovery_action":"restart","request_id":null,"session_id":null,"severity":"error","stage":"recovery"}],"presentation":{"audio_gap_count":0,"audio_gap_text":null,"live_failure_notices":[],"preparation_phase":"ready","preparation_status_text":null,"processing_indicator":"partial_failure","processing_status_text":null,"recording_status_text":"待機中","recording_tone":"neutral","recovery_status_text":"未完了セッションを復旧できませんでした: セッション一覧を読み取れません","silence_warning_active":false,"silence_warning_text":null},"queue":[],"recording":null,"recovery":"failed","revision":"302","screen":"idle","setup":"ready"}},"request_id":"404","sequence":"335","version":1}
```

## ONNX Runtime

Windows / Linux の ONNX 実行には Microsoft ONNX Runtime の固定版 1.31.0 を使います（[公式 v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)、[C API](https://onnxruntime.ai/docs/get-started/with-c.html)、[OrtApi](https://onnxruntime.ai/docs/api/c/struct_ort_api.html)）。[`CONNXRuntime`](../app/MacAmbientJev/Sources/CONNXRuntime/module.modulemap) は取得した ONNX Runtime C header を読み込む `systemLibrary` module です。[`MacAmbientJevONNX`](../app/MacAmbientJev/Sources/MacAmbientJevONNX/ONNXSession.swift) はこの C module だけに直接依存し、[`MacAmbientJevONNXTests`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/ONNXSessionTests.swift) は Windows / Linux のみで定義します。macOS は ONNX target を定義せず、ONNX Runtime SDK を取得しません。

公開 API は `ONNXEnvironment(loggingID:)`、`ONNXSession(environment:modelURL:intraOpThreads:cpuMemoryArenaEnabled:)`、`ONNXTensor`、`ONNXTensorElementType`、`ONNXTensorMetadata`、`ONNXValue`、`ONNXRuntimeError` です。すべての引数が必須です。`cpuMemoryArenaEnabled` は session ごとの CPU memory arena を選ぶ必須値で、`true` では EnableCpuMemArena、`false` では DisableCpuMemArena を CreateSession より前に呼びます（[ONNX Runtime 1.31.0 OrtApi](https://onnxruntime.ai/docs/api/c/struct_ort_api.html)）。native 呼び出しの失敗は検査し、日本語の `ONNXRuntimeError` にします。この設定は session の並列度を指定する `intraOpThreads` と、別設定の memory pattern optimization（EnableMemPattern / DisableMemPattern）とは独立です。default 値も process-wide な runtime override もありません。`ONNXSession.inputMetadata()` / `outputMetadata()` は graph の順序で name・element type・shape を返し、動的次元は `-1` です。metadata と実行値で扱う要素型は float32 / int64 に限られ、非 tensor または未対応型は `ONNXRuntimeError` になります。raw `ONNXSession` の呼び出し側が `ONNXEnvironment` を生成・保持して session 間で共有します。ORT environment は process-wide に共有でき、wrapper は global singleton を提供しません。ONNX Qwen3-ASR engine は独自の environment を生成し、3 session に共有します。`ONNXEnvironment` は環境作成前に読み込まれた ONNX Runtime の版が固定 1.31.0 と一致することを確認し、一致しない場合は実際の版を含む日本語エラーを返して環境を作成しません（異なるシステム DLL は使用できません）。`ONNXEnvironment` は OrtEnv を所有して解放します。ORT は OrtEnv を複数 thread から共有できるとしており、wrapper は作成後に変更しないため `@unchecked Sendable` で、固定版は `ONNXEnvironment.runtimeVersion` として公開します。`ONNXSession` は environment を強参照で保持し、自身の native session だけを所有・解放します。モデル URL は明示し、モデルや SDK の path を環境変数・config から読み取る override はありません。`intraOpThreads` は各 session で選ぶ正の Int32 表現可能な Int で、全 session 共通の値ではありません。inter-op thread 数は 1 固定です。PortableRuntime の Silero VAD、Qwen3-ASR、Community-1、clause tagger の全 model session は CPU provider を ONNX Runtime の暗黙の default として使います。graph optimization level は明示設定せず、ONNX Runtime の default `ORT_ENABLE_ALL` を使います（[graph optimizations](https://onnxruntime.ai/docs/performance/model-optimizations/graph-optimizations.html)）。optimized model の disk cache は設定・利用しません。`ONNXTensor` は `.float32(shape:values:)` と `.int64(shape:values:)` のみを持ち、値はそれぞれ `[Float]` と `[Int64]` です。shape `[]` は値1個の scalar、0 extent を含む shape は値0個です。負の次元、要素数の不一致、要素数または byte 数の overflow は `ONNXValue` の作成時に検証します。`run(inputs:outputNames:)` は名前付き複数入力を受け取り、指定した順序の出力テンソルを返します（入力は `ONNXValue` へコピーして `runValues` に渡し、出力は `tensor()` でコピーして返す薄い層です）。出力で読み取れる要素型は float32 と int64 だけで、ほかの型は `ONNXRuntimeError` になります。空または NUL を含む入出力名、重複する入力名、空の出力一覧も拒否します。`ONNXValue` は float32 / int64 の ORT 値（OrtValue）を所有する不透明なハンドルで、deinit で解放します。`ONNXValue(environment:tensor:)` が `ONNXTensor` から作る（コピー1回）ほか、`runValues(inputs:outputNames:)` が名前付き `ONNXValue` を受け取って出力を `ONNXValue` で返します。`runValues` は入出力のテンソルデータを Swift 側へコピーしないため、ある step の出力（例: Qwen3-ASR decoder の `present_keys` / `present_values`）を次の step の入力（`past_keys` / `past_values`）へそのまま渡せ、数百 MB の KV cache が Swift 配列を往復しません。`shape` は作成時に取得済みの値を返す安価なアクセサです。`tensor()` は全体を `ONNXTensor` にコピーし、`float32LastRow()` は形状 `[1, S, V]`（`S >= 1`）の float32 テンソルの最終行だけを `[Float]`（長さ `V`）にコピーします（`[1, S, 151936]` の logits 全体をコピーしないため）。`ONNXValue` は float32 と int64 のテンソルだけを表し、出力がほかの型の場合は `runValues` が `ONNXRuntimeError` を返します。`float32LastRow()` は float32 以外または形状が `[1, S, V]`（`S >= 1`）でない値を `ONNXRuntimeError` で拒否します。別の `ONNXEnvironment` で作った値を session に渡すことも拒否します。`ONNXValue` は作成後に変更せず ORT は入力値を読み取るだけなので thread 間で受け渡せますが、1つの値を同時に複数の session run で使いません。入出力名と ORT status のエラーは `run` と同じ `ONNXRuntimeError` です。ファイル URL の native filesystem representation を使い、Windows では native UTF-8 path を UTF-16 に変換して ORT に渡します（`URL.path` は使いません）。CPU provider のみを使い telemetry を無効にし、fallback はありません。ORT status は日本語の処理状況と ORT のメッセージを含む `ONNXRuntimeError` として返します。

ONNX のテストは [`affine.onnx`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/affine.onnx) を用いて、名前付き型付きテンソル推論、`ONNXValue` 作成時の検証、environment / session の寿命とエラー処理、日本語・絵文字を含むパスを確認します（[テスト](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/ONNXSessionTests.swift)）。[`cache.onnx`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/cache.onnx)（`past` に `step` を第2軸で連結した `present` と、int64 の `count` に 1 を足した `count_out`）は、出力 `ONNXValue` を次の run の入力へ渡す連鎖、最終行の読み出し、名前と形状の誤りのエラーを確認します（[テスト](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/ONNXValueTests.swift)）。両 fixture は [`generate_onnx_fixture.py`](../scripts/generate_onnx_fixture.py) が決定的に生成します。

[`fetch_onnxruntime.py`](../scripts/fetch_onnxruntime.py) は Python 3.12 以上の標準ライブラリのみを使い、Python 3.12 未満は明示的なエラーで拒否します。Windows x64 / arm64 と Linux x64 / aarch64 の asset を単一の公式 v1.31.0 release から `.build/onnxruntime/1.31.0/` に取得し、それ以外の OS / architecture は明示エラーです。自動 retry はありません。既存の展開先は内容を検証して抽出せず再利用し、header の更新時刻を保持します。展開先が無効なら、削除が必要な directory の path を示して失敗します。新しい展開先を作る場合は、アーカイブの SHA-256 を抽出・公開前に照合します。有効な展開先を再利用するときはアーカイブをハッシュしません。展開先がない場合は、スクリプトが作成した残存 `.extract-*` directory と download 一時ファイルを削除してから、一時 staging に展開します。tar の `data` filter を使い、ZIP の絶対 / drive path を拒否します（[Python `tarfile`](https://docs.python.org/3.12/library/tarfile.html)、[`zipfile`](https://docs.python.org/3.12/library/zipfile.html)）。期待する root が staging 内に1つだけあることと、header・platform library・`LICENSE`・ThirdPartyNotices.txt を検証し、未作成の展開先へ `os.replace` で公開します（[`os.replace`](https://docs.python.org/3.12/library/os.html#os.replace)）。

| archive | SHA-256 |
| --- | --- |
| `onnxruntime-win-x64-1.31.0.zip` | `3958d8a44984160692c1b4ffd0de3cb48f8c39f9d34bb31e433db06e30b82195` |
| `onnxruntime-win-arm64-1.31.0.zip` | `ef6206fa8d6975878d93a97035d280240ce5764c126a7430e5427e18923316d5` |
| `onnxruntime-linux-x64-1.31.0.tgz` | `cc5c72baf5ae5c8238a6841f0897227be2d02826b9cf98eaf02fdefaeeb03a57` |
| `onnxruntime-linux-aarch64-1.31.0.tgz` | `c5b8b3cca31f3d643a3b313b8f42e2d0f16a4fcefd02cda343d97bd5306afaab` |

SwiftPM は取得 SDK の header / library へ固定したリポジトリ内パスで接続します。Windows は import library の絶対パス、Linux は versioned `.so` の絶対パスと取得済み library directory の絶対 rpath を使い、pkg-config や system library search は使いません。SDK 不足時は fetch command 付きの manifest error で停止します。SwiftPM は Linux / Windows で ONNX Runtime SDK を `binaryTarget` として扱えず、`systemLibrary` target に binary を同梱できないため、fetch した local SDK を使います。`systemLibrary` に `cSettings` がないため、共通の `-Xcc -I` include 設定を `MacAmbientJevONNX` と `MacAmbientJevONNXTests` の target-local `swiftSettings` に個別適用します（[SwiftPM PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)）。fetcher の asset/version/platform 対応と manifest の compile-time version/platform 対応は、manifest で Python を実行せずに link / path を決定・検証するため双方に必要です。version literal は各 source に1つずつ置き、path / version は shim、PowerShell runner、workflow に重複させません。local SDK と linker `unsafeFlags` に依存するため、これは外部配布用 Swift package ではなくリポジトリ内の開発 build です。

Headless Pipeline consumer と P4 engine の run loop は DispatchQueue.main と MainActor executor の処理を継続して drain する必要があります。Pipeline の processing / live transcription coordinators は `@MainActor` で動作し、[`MicInputVolumeController`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/MicInputVolumeController.swift) も DispatchQueue.main.asyncAfter で timeout を進めます。どちらかを drain しないと coordinator の処理や timer callback が進みません。状態型と coordinator の責務は [architecture.md](architecture.md) を参照してください。

## Silero VAD フレーム推論

`MacAmbientJevONNX` の `SileroVAD` は、Silero VAD の単一16 kHz mono frame から speech probability を返す stateful API です。公開 API は `SileroVAD(environment:modelURL:intraOpThreads:)`、`SileroVAD.frameSamples`、`speechProbability(frame:)`、`snapshot()`、`restore(_:)`、`reset()` で、初期化引数はすべて必須です。内部の ONNX session は `cpuMemoryArenaEnabled: true` を明示します。`snapshot()` は recurrent state と context の値を保存し、`restore(_:)` はそれを戻します。数 frame を進めた後に失敗した処理を取り消すために使います。`frameSamples` は512です。モデル URL を明示し、実行時に環境変数から推論モデルを探しません。`MacAmbientJevONNX` は Foundation と `CONNXRuntime` のみに依存し、プロセス共有の `ONNXEnvironment` は呼び出し側が作成・共有します。インスタンスは状態を持ち、Swift concurrency 上は non-sendable であるため、呼び出し側が呼び出しを直列化します。

固定 ONNX model は upstream v6.2.3 release の commit `5cd7945676eb32225748052e2e6a0580e4686a08` にある [src/silero_vad/data/silero_vad_16k_op15.onnx](https://raw.githubusercontent.com/snakers4/silero-vad/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/data/silero_vad_16k_op15.onnx) です。この opset 15 export は v6.2.1 の Silero VAD model weights を使います。取得した実ファイルの SHA-256 は `7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49` です。upstream の [model.py](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/model.py) は opset 15 用にこのファイルを選びます。この API は16 kHz のみを受け取ります。固定 revision の [LICENSE](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/LICENSE) は MIT License、Copyright (c) 2020-present Silero Team です（[v6.2.3 release](https://github.com/snakers4/silero-vad/releases/tag/v6.2.3)）。

ONNX 推論では `input[1, 576]`、`state[2, 1, 128]`、`sr[] = 16000` を渡し、出力 `output[1, 1]` と `stateN[2, 1, 128]` を検証します。1 frame は `SileroVAD.frameSamples` の512 sample（16 kHz で32 ms）です。新しい frame に64 sample context を連結し、初期 context と recurrent state `[2, 1, 128]` はゼロです。推論に成功した場合に限り `stateN` と新しい frame の末尾64 sample を次 frame 用に保持します。`reset()` は session を保持したまま state と context をともにゼロに戻します。state の初期化・reset は固定 revision の上流 [`reset_states` (L103–107)](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/utils_vad.py#L103-L107)、frame 推論は [`__call__` (L109–144)](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/utils_vad.py#L109-L144) の実装を mirror します。単体 API は frame の padding、chunking、sample-rate conversion を行いません。512 sample 以外または有限でない入力は明示的なエラーとなります。確率出力は float32 `[1, 1]`、有限値かつ `[0, 1]` 内であることを検証し、state 出力は float32 `[2, 1, 128]` で有限であることを検証します（state の値域は制約しません）。検証に成功する前に状態を更新しません。

Mac は FluidAudio 0.15.8 の Core ML artifact `silero-vad-unified-256ms-v6.2.1` を使います（[FluidAudio VAD docs](https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.8/Documentation/VAD/GettingStarted.md)、[release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.8)、[artifact metadata](https://huggingface.co/FluidInference/silero-vad-coreml/commit/b419383c55c110e2c9271fa6ee0ea83d03c70d96)、[model README](https://huggingface.co/FluidInference/silero-vad-coreml/raw/main/README.md)）。segmentation layer は16 kHz の連続 recurrent state で連続する512-sample frameを8個処理し、各 frame probability を noisy-OR `1 − Π(1 − p_i)` で集約した256 msごとの確率に threshold 0.50 を適用します。最後の部分 chunk は最後の sample の反復で埋めます。ONNX の `SileroVAD` は同じ v6.2.1 weights を使う opset 15 export から frame probability を返します。ONNX 側は PortableRuntime の `SileroChunkScorer` が同じ8 frame/noisy-OR/部分 chunk の最後の sample 反復で256 msごとの確率を作り、threshold 0.50 は Pipeline の区間検出が適用します。この集約は `SileroVAD` 単体 API の処理ではありません（[Silero VAD の区間検出](#silero-vad-の区間検出)）。

[`fetch_silero_vad.py`](../scripts/fetch_silero_vad.py) は Python 3.12 以上の標準ライブラリのみを使う引数なし fetcher です（[Python 3.12 release](https://docs.python.org/3.12/whatsnew/3.12.html)）。固定 raw GitHub URL だけから取得し、retry や代替 URL は使わず、ダウンロード後と既存ファイルの再利用時に SHA-256 を検証します。不一致は再ダウンロードせずエラーにします。symlink、リポジトリ外 path、通常ファイルでない cache entry を拒否し、一時ファイルを検証してから `os.replace` で公開します。成功時の stdout は検証済み絶対 path 1行のみで、保存先は `.build/silero-vad/5cd7945676eb32225748052e2e6a0580e4686a08/silero_vad_16k_op15.onnx` です。両 fetcher は [`pinned_download.py`](../scripts/pinned_download.py) を共有し、repository directory の検証と hash 検証付き atomic file download を行います。download staging は Python 3.12 の [`tempfile.mkstemp`](https://docs.python.org/3.12/library/tempfile.html#tempfile.mkstemp) を使います。ONNX Runtime の archive extraction は fetcher 固有です。

モデル path の環境変数 `MAC_AMBIENT_JEV_SILERO_MODEL` は ONNX と PortableRuntime の test harness 専用です。未設定・空・欠損の場合は fetch command を示すエラーになり、test は skip しません。`MacAmbientJevONNXTests` は連続無音 frame の確率が0.1未満、有声 RMS 0.01 以上の frame の70%以上で確率が0.5以上となること、reset 後の bitwise 再現性と speech 後に reset した無音の一致、recurrent state / context の frame 間引継ぎを検証します。不正 frame と非有限値は状態を変えません。固定 revision の上流参照確率も許容差 `1e-4` で照合します。Linux で手動設定する場合は repository root で次を実行します。Bash は fetch 結果を先に変数へ代入してから `export` し、失敗 status を保持します（[Bash simple command expansion](https://www.gnu.org/software/bash/manual/html_node/Simple-Command-Expansion.html)）。

```bash
set -e
model="$(python3 scripts/fetch_silero_vad.py)"
export MAC_AMBIENT_JEV_SILERO_MODEL="$model"
python3 -B scripts/test_fetch_silero_vad.py
python3 -B scripts/test_fetch_community1_diarization.py
python3 -B scripts/test_pinned_download.py
python3 -B scripts/test_generate_silero_reference.py
```

同梱の [`silero_speech.wav`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/silero_speech.wav) は mono PCM16・16 kHz で、SHA-256 は `c807432e609c0357593243253e089ae5710755ac6bd2ac30d74420fef09d9731` です。元の英文は “Hello, this is a speech recording for voice activity detection.” です。[`generate_silero_speech_fixture.py`](../scripts/generate_silero_speech_fixture.py) は Ubuntu 24.04 を含む `swift:6.2-noble` image の espeak-ng と espeak-ng-data `1.51+dfsg-12build1` で en-us、speed 150、pitch 50、amplitude 100 を指定して生成します。生成した22,050 Hz 音声を整数有理数 linear interpolation（ties-to-even）で16 kHz に変換し、512 sample 境界までゼロ padding します。この変換は fixture 専用で、アプリの SRC ではありません。再生成コマンドは次のとおりです。

```bash
docker run --rm -v "$PWD:/repo" -w /repo swift:6.2-noble bash -lc 'apt-get update && apt-get install -y python3 espeak-ng=1.51+dfsg-12build1 espeak-ng-data=1.51+dfsg-12build1 && python3 scripts/generate_silero_speech_fixture.py'
```

fixture は eSpeak NG（GPL-3.0-or-later）の出力で、eSpeak NG は生成にのみ使用して同梱せず、元の英文・音声は CC0-1.0 です（[COPYING](https://raw.githubusercontent.com/espeak-ng/espeak-ng/1.51/COPYING)、[guide](https://github.com/espeak-ng/espeak-ng/blob/1.51/docs/guide.md)）。

[`silero_reference.json`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/silero_reference.json) は固定 revision の上流 [utils_vad.py](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/utils_vad.py#L103-L144) にある OnnxWrapper が生成した参照値を保存します。reference generator は上流 script の SHA-256 `15d0f6b3ef9590e22ca2f146e1436f6901da356cb552d3183df4100862b333cb` を照合し、PCM16 を `32768` で正規化します。有声 frame の確率0.5以上の割合が0.70未満、または無音 frame の確率が0.1以上なら、reference JSON を書き込む前に失敗します。再生成には `uv` と次の固定依存を使います。

```bash
uv run --with onnxruntime==1.31.0 --with numpy==2.5.4 --with torch==2.14.1 --with packaging==26.3 python scripts/generate_silero_reference.py --model "$(python3 scripts/fetch_silero_vad.py)"
```

参照 frame index は `0, 1, 2, 4, 8, 16, 32, 48, 64, 80, 100, 120, 140` です。Swift test は同梱 JSON を使うため、実行時に Python は必要ありません。

## Silero VAD の区間検出

Linux / Windows の確定処理 VAD とライブ VAD は、Mac と同じ区間規則を Silero VAD の確率に適用します。規則は Mac と共有する部分を Pipeline、ONNX Runtime を使う部分を PortableRuntime に置きます。

| 型 | target | 役割 |
| --- | --- | --- |
| `VADSegmentationParameters` | Pipeline | 区間規則の定数。chunk 4,096 sample（256 ms）、開始閾値 0.50、pre-roll 0.10 秒、最大区間 14.0 秒、無音 0.75 秒、分割探索 2.0 秒、エネルギー frame 0.02 秒、独立区間の最短 0.5 秒。Mac の `FluidVADSegmentationEngine` も同じ値を使う |
| `VADSegmentationState` | Pipeline | VAD event から [`SegmentationAssembler`](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift) で区間を作る。pre-roll、14 秒到達時の最も静かな 20 ms frame での分割、独立区間の最短長を扱う。Mac と共有する |
| `VADStreamingStateMachine` | Pipeline | chunk ごとの確率から発話の開始・終了 event を作る |
| `VADChunkScoring` | Pipeline | 部分 chunk の最後の sample 反復による padding と、8 frame の noisy-OR |
| `VADProbabilitySegmenter` | Pipeline | `VADStreamingStateMachine` と `VADSegmentationState` を連結し、chunk の確率から区間を作る。ONNX Runtime を使わずにテストできる |
| `SileroChunkScorer` | PortableRuntime | 4,096 sample を8個の512-sample frame として1つの `SileroVAD` に順に通し、`VADChunkScoring` で256 msの確率にする。recurrent state は chunk をまたいで続く |
| `SileroVADSegmentationEngine` | PortableRuntime | `VADChunkSegmenting` の実装。`SileroChunkScorer` と `VADProbabilitySegmenter` を持つ |
| `SileroFinalTranscriptVADSegmenter` | PortableRuntime | `FinalTranscriptVADSegmenter` の実装。`environment`、`modelURL`、`intraOpThreads` はすべて必須 |
| `SileroLiveVADSessionFactory` | PortableRuntime | `LiveVADSession` を作る。引数は Mac の `MacLiveVADSessionFactory` に `environment`、`modelURL`、`intraOpThreads` を加えたもの |

PortableRuntime は Linux / Windows の推論 engine と portable audio importer の置き場で、Core、Pipeline、MacAmbientJevONNX、MacAmbientJevDiarization に依存します。platform 固有の import 依存は Linux では CMiniaudio、Windows では MacAmbientJevWindowsSupport です（[`Package.swift`](../app/MacAmbientJev/Package.swift)）。`MacAmbientJevTranscribeFile` は Core、Pipeline、PortableRuntime、ONNX に依存し、decoder target には直接依存しません。MacAmbientJevONNX は Foundation と `CONNXRuntime` だけに依存する汎用層のままにし、Core の型に依存する engine を分けています。`scripts/check_portable_core.py` は PortableRuntime の import も検査します。

発話の開始・終了判定は FluidAudio 0.15.8 の [`streamingStateMachine`](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/VAD/VadManager+Streaming.swift)（Apache-2.0）から、アプリが使う経路だけを移植した `VADStreamingStateMachine` です。出典は [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md#fluidaudio) に記載しています。Mac の `FluidVADSegmentationEngine` は FluidAudio の streaming API をそのまま使います。

- 確率が0.50以上なら無音の計測を解除します。未開始なら、その chunk の先頭 sample を開始位置にして発話を開始します。
- 発話中に確率が終了閾値 0.35（開始閾値 0.50 から FluidAudio の offset 0.15 を引いた値）を下回ると、その chunk の末尾から無音を数え始めます。0.35 以上 0.50 未満の確率は無音の開始も解除も行いません。
- 無音が0.75秒（12,000 sample）以上続くと発話を終了します。終了位置は、無音を数え始めた位置から現在の chunk の長さを引いた sample です。
- speech padding は0です。pre-roll は区間組み立てが加えます。
- 処理済み sample 数には部分 chunk の実際の長さを足します。padding した sample は数えません。

chunk の途中で ORT がエラーを返した場合、`SileroChunkScorer` は `SileroVAD.snapshot()` で state を戻してから error を投げます。同じ chunk を再度渡しても、結果は失敗がなかった場合と一致します。

確定処理の来歴は `engine = onnxruntime-silero-vad`、`model = silero_vad_16k_op15.onnx`、`version = silero-vad@<commit>+onnxruntime@1.31.0` です。configuration の値は [storage.md](storage.md#run-の来歴) にあります。固定 model の commit と SHA-256 は `SileroVADModel` に置き、`test_fetch_silero_vad.py` が `fetch_silero_vad.py` の値との一致を検査します。`SileroVADModel.validate` の SHA-256 は Core の `FileSHA256`（streaming）で計算します。

### Mac との一致

Mac の FluidAudio（Core ML、`silero-vad-unified-256ms-v6.2.1`）と Silero の ONNX は同じ v6.2.1 weights ですが、Core ML は mixed float16 で動作し、recurrent state を frame ごとに float16 へ丸めます。ONNX は float32 です。256 msごとの確率は同じ値になりません。parity fixture では次の3点を検査します。

1. 区間の開始・終了 frame が完全に一致します（許容差 0 frame）。
2. すべての chunk で、ONNX と Core ML の確率が開始閾値 0.50 と終了閾値 0.35 のそれぞれに対して同じ側にあります。
3. chunk ごとの確率差は 0.25 以下です。

[`vad_parity.json`](../app/MacAmbientJev/Tests/MacAmbientJevVADFixtures/vad_parity.json) は Mac の FluidAudio が2つの入力に対して出した256 msごとの確率と区間です。入力は `silero_speech.wav`（4.5秒）から作ります。`speech_clip` はその音声そのもので、部分 chunk で終わります。`pauses_and_long_utterance` は0.75秒未満・以上の無音、約19秒続く発話（14秒の分割を起こす）、音声の途中で終わる部分 chunk を含む約43秒です。入力の組み立ては [VADParityFixture.swift](../app/MacAmbientJev/Tests/MacAmbientJevVADFixtures/VADParityFixture.swift) にあり、追加の音声ファイルはありません。

測定値は次のとおりです。`speech_clip` は18 chunk、最大差 0.0373（最後の部分 chunk）、平均差 0.0021 です。`pauses_and_long_utterance` は168 chunk、最大差 0.2015（chunk 20、発話終了の直後で ONNX 0.665、Core ML 0.867）、平均差 0.0130 です。どちらも全 chunk が両閾値に対して同じ側にあり、区間の開始・終了 frame は完全に一致します。ONNX が閾値に最も近い chunk は chunk 122（ONNX 0.505、Core ML 0.621）で、余裕は 0.005 です。確率差は最大 0.2 あるため、確率が閾値付近にある chunk を含む録音では、Mac と Linux / Windows で区間が異なることがあります。区間の完全一致は fixture の2入力で確認した結果で、任意の録音に対する保証ではありません。

fixture は Mac で次のコマンドにより生成します。

```bash
MAC_AMBIENT_JEV_WRITE_VAD_PARITY=1 swift test --package-path app/MacAmbientJev --filter VADParityFixtureTests/writeParityFixture
```

Mac の [VADParityFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/VADParityFixtureTests.swift) は、実行ごとに FluidAudio の出力が保存済み fixture と一致すること（確率差 0.05 以下、区間は完全一致）と、fixture の FluidAudio の確率を `VADProbabilitySegmenter` に通すと fixture の区間と完全に一致すること（移植した状態機械と FluidAudio の状態機械の一致）を検査します。Linux / Windows の [SileroVADParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/SileroVADParityTests.swift) は、同じ入力を Silero engine に通して上の3点を検査します。[SileroVADEngineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/SileroVADEngineTests.swift) は、ライブ VAD が durable chunk に分けた音声から同じ区間を作ること、provenance、失敗した chunk の再試行を検査します。ORT を使わない状態機械と区間組み立ては [VADStreamingTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/VADStreamingTests.swift) と [VADSegmentationStateTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/VADSegmentationStateTests.swift) が検査します。

## セッション全体のファイル処理 CLI

`MacAmbientJevProcessRecording` は Linux / Windows 共通の portable CLI です。音声ファイルを session に import し、共通の [`SessionFileProcessingService`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionFileProcessingService.swift) と [`FinalTranscriptPipeline`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift) で VAD segmentation、話者分離、ASR を含む full-session finalization を行います。session inspection と、中断した finalization / decisions の resume も利用できます。`MacAmbientJevTranscribeFile` は別の評価用 file-processing path です。

```text
MacAmbientJevProcessRecording --sessions-root ROOT [--keep-session] [--low-heat] [--with-decisions] --threads N AUDIO [OUTPUT]
MacAmbientJevProcessRecording --inspect-session UUID --sessions-root ROOT
MacAmbientJevProcessRecording --resume-session UUID --sessions-root ROOT [--low-heat] [--with-decisions] --threads N OUTPUT
```

`--sessions-root` は必須です。symlink ではなく、application support / cache の保護領域と重ならない安全な保存先を明示してください。import では必要に応じて session root を作成します。Portable の import / resume は `--threads N` が必須で、`N` は `1...min(4, 論理 CPU 数)` の整数です。ASR・diarizer・decisions 用 tagger の ONNX session は `N`、VAD は常に1 thread で動作します。model 不要の `--inspect-session` は `--threads` を受け付けず、macOS の CLI では `--threads` 自体を指定できません。Portable の resume は export-only の場合も `--threads` が必要です。

Import の `AUDIO` に続く `OUTPUT` は省略でき、省略時は音声ファイルの親 directory に `segments.json` を作成します。import 時は stdout に `session_id: UUID` を出力します。`--keep-session` を指定しない import session は成功時・失敗時とも処理後に削除されます。失敗した session を調査または再開するために残す場合は、import に `--keep-session` を指定してください。`--inspect-session` と `--resume-session` の UUID にはこの `session_id` を使います。session root 直下の manifest を検索し、該当 manifest の `session_id` で folder を特定します。`--resume-session` は必須の `OUTPUT` へ export し、その path は symlink 解決後も対象 session folder の外でなければなりません。

`--inspect-session` は recovery action と storage maintenance の状態だけを返し、`--low-heat`、`--with-decisions`、`--threads`、`--keep-session`、measurement options や位置引数は指定できません。JSON の object は `{ "session_id": "...", "action": "...", "maintenance": null }` の3 key のみで、maintenance がない場合は `null` です。`--run-id`、`--metrics-output`、`--thermal-output`、`--memory-output` は Mac 専用の measurement options で、Linux / Windows はこれらを filesystem/session side effect より前に拒否します。

`--low-heat` は Portable では ASR の認識済み segment 間に約2秒の pacing wait を入れるだけです。Linux / Windows では thermal monitoring、thermal start gate、thermal state による pause は行いません。

Decisions は既定で無効です。`--with-decisions` のとき、認識テキストがある export は clause-boundary と content-priority の両 run が公開済みで、pending decision target がない場合に限り成功します。decision request が失敗した場合は session 内の公開済み local transcript は保持されますが、成功 export は作らず CLI は非0で終了します。その失敗 session が必要なら import に `--keep-session` を指定してください。認識テキストがない場合は空の `[]` を正常に export し、decision run は不要です。完了済み decisions の session を `--with-decisions` 付きで resume する場合は、既存と同じ recognized segment 配列を export し、model resources を作らず inference event も追加しません。decisions だけを retry する resume は retry API を使い、ASR / diarizer inference を実行しませんが、portable の基本 engine bundle は構築します。

成功時の import / resume output は、Linux / Windows 共通の pretty-printed・sorted JSON schema による `MaterializedTranscriptSegment` 配列です。これは `MacAmbientJevTranscribeFile` の primary JSON や CER artifact の envelope ではありません。recognized segment の `text`（ASR text）、`display_text`、`source`、`speakers`、clause 情報（`clause_state`、`clause_slices`）を保持します。

### Portable inference environment

`PortableProcessingConfiguration.resolve` は import と inference が必要な resume のときだけ portable model environment を読みます。inspect と export-only resume は model environment を読みません。decision-only retry は ASR / diarizer inference を行わない場合も、base engine bundle を作るため次の基本 model 設定を必要とします。

| 環境変数 | 必要な値 |
| --- | --- |
| `MAC_AMBIENT_JEV_SILERO_MODEL` | 絶対 path の既存 Silero ONNX model file |
| `QWEN3_ASR_ONNX_MODEL_DIRECTORY` | 絶対 path の既存 Qwen3-ASR ONNX model directory |
| `QWEN3_ASR_ONNX_MODEL_SIZE` | `0.6b` または `1.7b` のいずれか（大文字・空白なし） |
| `MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY` | 絶対 path の既存 Community-1 ONNX model directory |
| `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` | `--with-decisions` の場合のみ必要な、絶対 path の既存 clause-tagger model directory |

値に default はありません。model path を指定する CLI option、暗黙 download、path / model の fallback もありません。欠落・不正な設定は import session の bootstrap または resume の storage maintenance より前に失敗します。configuration の path/type 検査は model integrity 全体の preflight ではありません。Silero の pin 検証は engine bundle 構築時に行い、各 ONNX engine の model file / graph の検証・load は engine の prepare/load 時に行います。全 model の hash を session mutation 前に一括検証する契約ではありません。asset の取得方法は [Silero VAD](#silero-vad-フレーム推論)、[Qwen3-ASR](#qwen3-asr-onnx-モデルの取得)、[Community-1](#community-1-話者分離モデルの取得)、[clause tagger](#発話文タガー-onnx-モデルの取得) の既存手順を参照してください。CLI はそれらを自動実行しません。

Windows import は [音声 import API](#音声-import-api) と同じ decoder を使い、WAV / FLAC / MP3 は miniaudio、AAC / M4A は Windows Media Foundation で decode し、canonical 16 kHz mono へ SRC します。Linux import は CMiniaudio の WAV / FLAC / MP3 のみで、入力は既に 16 kHz mono である必要があります。`--threads` や model environment は下記の `MacAmbientJevTranscribeFile` の設定とは別です。

Windows での実行例です。次は release CLI の build / 実行例で、ONNX Runtime DLL の配置は [ビルドと検証](#ビルドと検証) の手順に従ってください。model assets は自動取得されません。path と `N` は実在する環境に合わせて明示し、取得方法は上記の既存手順を参照してください。

```powershell
$ErrorActionPreference = 'Stop'
$env:MAC_AMBIENT_JEV_SILERO_MODEL = 'D:\Models\silero_vad_16k_op15.onnx'
$env:QWEN3_ASR_ONNX_MODEL_DIRECTORY = 'D:\Models\qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4'
$env:QWEN3_ASR_ONNX_MODEL_SIZE = '0.6b'
$env:MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY = 'D:\Models\community1'
$env:MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY = 'D:\Models\clause-tagger'
swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevProcessRecording
if ($LASTEXITCODE -ne 0) { throw 'ProcessRecording build failed' }
$binDir = (swift build --package-path app/MacAmbientJev -c release --show-bin-path).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve release binary path' }
& (Join-Path $binDir 'MacAmbientJevProcessRecording.exe') `
  --sessions-root 'D:\AmbientSessions' `
  --keep-session --with-decisions --threads 1 `
  'D:\Audio\interview.m4a' `
  'D:\Transcripts\interview-segments.json'
if ($LASTEXITCODE -ne 0) { throw 'Full-session processing failed' }
```

実装と関連 test は [`ProcessRecordingArguments.swift`](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/ProcessRecordingArguments.swift)、[`main.swift`](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)、[`ProcessRecordingArgumentsTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ProcessRecordingArgumentsTests.swift)、[`ProcessRecordingSafetyTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ProcessRecordingSafetyTests.swift)、[`SessionFileProcessingServiceTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionFileProcessingServiceTests.swift)、[`FinalTranscriptPipelineTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/FinalTranscriptPipelineTests.swift)、[`PortableProcessingConfiguration.swift`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableProcessingConfiguration.swift)、[`PortableProcessingConfigurationTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/PortableProcessingConfigurationTests.swift) を参照してください。

## ファイル文字起こし CLI

`MacAmbientJevTranscribeFile` は Linux / Windows で音声ファイルを VAD 区間ごとに文字起こしし、区間と評価 artifact を出力する計測用 portable CLI です。参照文や評価規則は受け取らず、CER は `MacAmbientJevEvaluateASR` で別途計算します。実行 helper は [`FileTranscriptionPipeline`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FileTranscriptionPipeline.swift) で、`SileroFinalTranscriptVADSegmenter`、`PipelineCoordinator`、`ASRAudioLoader` を組み合わせます。この helper は mandatory diarization を含む full-session `FinalTranscriptPipeline` ではありません。話者分離・speaker-turn による区間分割、話者 tagger、thermal / pacing flag はありません。Windows の full-session file-import path は前節の `MacAmbientJevProcessRecording` です。Windows の engine は live capture をサポートしますが、GUI はありません。

確定処理の区間規則は [Silero VAD の区間検出](#silero-vad-の区間検出) と同じで、chunk 4,096 sample / 256 ms、開始閾値 0.50・終了閾値 0.35、pre-roll 0.10 秒、最大区間 14.0 秒、無音 0.75 秒、分割探索 2.0 秒、energy frame 0.02 秒、独立区間の最短 0.5 秒です。

```text
MacAmbientJevTranscribeFile <audio-file> --silero-model <path> --asr-model-directory <dir> --asr-model-size <0.6b|1.7b> --threads <n> --output <file.json> --artifact-output <artifact.json>
```

`--help` だけで終了コード 0 になります。音声 path は必須の先頭位置引数で、残りの6 option はすべて一度ずつ必須です。option/value の組は並べ替えできます。

| option | 内容 |
| --- | --- |
| `--silero-model <path>` | Silero VAD ONNX model file |
| `--asr-model-directory <dir>` | 取得済み Qwen3-ASR ONNX model directory |
| `--asr-model-size <0.6b\|1.7b>` | model size |
| `--threads <n>` | 正の Int32 範囲内の値。ASR / VAD の全 ONNX session で intra-op thread 数として使う |
| `--output <file.json>` | 区間別の primary JSON |
| `--artifact-output <artifact.json>` | `MacAmbientJevEvaluateASR` 用の評価 artifact v2 |

認識言語は `ja` 固定で、detected-language field は出力しません。6 個の option に default や環境変数 override はありません。不明、重複、欠落 option、余分な引数、不正値は非 0 で拒否します。入力音声・Silero model・ASR model directory は readable な既存 file / directory、出力先の親 directory は既存 directory でなければなりません。`--output` と `--artifact-output` は既存 path を指定すると、処理開始前に非 0 で拒否されます。入力、primary 出力、artifact 出力は path 標準化と symlink 解決後に互いに異なる必要があります。

音声 import と VAD の前に、CLI は Silero model の pinned SHA-256 を検証し、選択した ASR model manifest が列挙する6ファイルの存在・通常ファイル型・readability・正確な byte 数を確認します。この preflight は VAD 区間が空の場合も実行しますが、ASR model ファイルの SHA-256 は検証しません。preflight は測定時間に含まれません。invalid input / 処理失敗時に出力 JSON は作りません。import した original、processing timeline、event files は一時 scratch directory に書いて処理後に削除し、永続 session は作成しません。処理と scratch 削除の両方が失敗した場合は両方の error を報告し、削除だけが失敗した場合も filesystem error として返します（[`TranscribeFileCommand`](../app/MacAmbientJev/Sources/MacAmbientJevTranscribeFile/TranscribeFileCommand.swift)）。各 JSON file は個別に atomic write しますが、2 file の pair は transactional ではありません。

`MacAmbientJevTranscribeFile` の import は PortableRuntime の [`PortableAudioFileImporter.open(inputURL:sessionURL:)`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableAudioFileImporter.swift) が入口です（source の一度だけのコピーと builder / processing directory の構成は[音声 import API](#音声-import-api)）。Windows は WindowsSupport の streaming WAV / FLAC / MP3 / M4A / AAC decoder と canonical 16 kHz mono SRC に委譲し、AAC encoder priming を保持します。Linux の CMiniaudio 0.11.23 は WAV / FLAC / MP3 のみを読み、入力が既に16 kHz mono であることを要求します。Linux では sample-rate conversion / channel mixing をせず、unsupported format・noncanonical input・decoder error は明示エラーとして返し、別 decoder へ fallback しません。Linux で必要なら利用者が ffmpeg で事前に mono PCM16 / 16 kHz WAV に変換します（CLI の fallback ではありません）。

primary JSON の exact top-level keys は `schema_version: 1`、`asr`、`vad`、`segments`、`runtime` です。`asr` / `vad` は各々 `engine`、`model`、`version`、`configuration` の provenance を持ちます。`segments` は `start_ms`、`end_ms`、`text` の配列で、canonical frame の境界を整数 millisecond に ties-to-even で丸めます。`runtime` は `audio_seconds`、`model_load_seconds`、`inference_seconds`、`rtf` です。VAD 区間が空でも成功し、segment は空、評価 artifact の hypothesis も空文字となり、ASR load / inference は行いません。評価 artifact の hypothesis は VAD 区間の認識 text を順に改行文字 `\n` で結合します。これは Mac の `ASRSessionEvaluator` と同じ規則です。artifact の一つの segment は全音声を包む CER 用 envelope であり、primary の区間境界だけが実際の segmentation 時刻です。

`asr.configuration` と artifact の `engine.inference_config` にある `intra_op_threads`、`inter_op_threads`、`cpu_memory_arena` は ASR の3 ONNX session で実際に使う設定（CLI の `--threads` 値、`1`、`false`）を表します。`inference_config` のこれらの値は ASR session のみを指します。Silero session は `--threads` の値を intra-op に使い、CPU memory arena を有効にします。`model_load_seconds` は `PipelineCoordinator` が計測する `ASR.prepare()` のみ、`inference_seconds` は `segmentationSeconds + asrWallSeconds - model_load_seconds` です。後者は lazy VAD model load / inference と event persistence を含み、audio import、モデル identity preflight、ONNX environment の生成、model unload / scratch cleanup、JSON 出力を含みません。`rtf = inference_seconds / audio_seconds` です。負値または非有限の計測値・算出指標はエラーになり、0 へ clamp しません。artifact schema、ONNX の engine / configuration values、runtime の詳細は [Linux 音声評価](linux.md#ファイル文字起こし-cli) に記載しています。

Qwen3-ASR ONNX の品質判定（Linux は CER を実測、Windows は Linux との token parity から導出）は [2026-10-20 の記録](records/qwen3-asr-onnx-cer-2026-10-20.md) にあります。

### Windows release build と実行

Python 3.12 以上、Swift 6.2 と対応する Visual Studio C++ Build Tools / Windows SDK が必要です。Silero model fetch は `python scripts/fetch_silero_vad.py` を使います。ASR model は既存の [Qwen3-ASR ONNX model fetcher](#qwen3-asr-onnx-モデルの取得) で事前取得してください。ONNX Runtime SDK と `onnxruntime.dll` は [ビルドと検証](#ビルドと検証) の既存の取得・DLL 配置手順を使います。以下の path は置換例で、既定値ではありません。`D:\Transcripts` と各 input / model file directory は事前に作成してください。

```powershell
$ErrorActionPreference = 'Stop'
$runtimeRoot = python scripts/fetch_onnxruntime.py
if ($LASTEXITCODE -ne 0) { throw 'ONNX Runtime fetch failed' }
$sileroModelPathLines = @(python scripts/fetch_silero_vad.py)
if ($LASTEXITCODE -ne 0) { throw 'Silero VAD fetch failed' }
if ($sileroModelPathLines.Count -ne 1) { throw 'Silero VAD fetch must return exactly one output line' }
$sileroModel = [string]$sileroModelPathLines[0]
swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevTranscribeFile
if ($LASTEXITCODE -ne 0) { throw 'Release CLI build failed' }
$binDir = (swift build --package-path app/MacAmbientJev -c release --show-bin-path).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve release binary path' }
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'lib/onnxruntime.dll') `
  -Destination (Join-Path $binDir 'onnxruntime.dll') -Force
& (Join-Path $binDir 'MacAmbientJevTranscribeFile.exe') `
  'D:\Audio\interview.m4a' `
  --silero-model $sileroModel `
  --asr-model-directory 'D:\Models\qwen3-asr-onnx\qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd' `
  --asr-model-size 1.7b `
  --threads 2 `
  --output 'D:\Transcripts\interview-segments.json' `
  --artifact-output 'D:\Transcripts\interview-artifact.json'
if ($LASTEXITCODE -ne 0) { throw 'File transcription failed' }
```

### Windows の実モデル CLI integration test

[`test_transcribe_file_cli_model.py`](../tools/linux-audio/tests/test_transcribe_file_cli_model.py) は release CLI と evaluator を build し、長い fixture の primary JSON、評価 artifact、CER を検証します。実行には Python 3.12 と `uv` が必要です。下記は repository root から実行し、先に上記 release build 手順と同じく `onnxruntime.dll` を release binary directory に配置してください。model directory の path は実際の既存 directory に置き換えます。

```powershell
$ErrorActionPreference = 'Stop'
$env:RUN_MODEL_TESTS = '1'
$env:QWEN3_ASR_ONNX_MODEL_DIRECTORY = 'D:\Models\qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4'
$env:QWEN3_ASR_ONNX_MODEL_SIZE = '0.6b'
$sileroModelPathLines = @(python scripts/fetch_silero_vad.py)
if ($LASTEXITCODE -ne 0) { throw 'Silero VAD fetch failed' }
if ($sileroModelPathLines.Count -ne 1) { throw 'Silero VAD fetch must return exactly one output line' }
$env:MAC_AMBIENT_JEV_SILERO_MODEL = [string]$sileroModelPathLines[0]
Push-Location tools/linux-audio
try {
  uv run --python 3.12 --with pytest python -m pytest -q tests/test_transcribe_file_cli_model.py
  if ($LASTEXITCODE -ne 0) { throw 'Model CLI integration test failed' }
} finally {
  Pop-Location
}
```

## 熱状態

Pipeline の [`ThermalMonitoring`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/ThermalMonitoring.swift) contract は `isCritical`（確定処理の pause / resume 判定）と `liveASRDecision`（live ASR の policy）です。Windows の `WindowsNoThermalMonitoring` は thermal state を読み取らず、`isCritical == false` と `.processNow` を返します。Windows では熱状態を測定・推定せず、nominal state を設定することもありません。Windows では熱状態によるライブ ASR 待機・確定処理一時停止を行いません（[製品ルールの熱状態](decisions.md#熱状態)）。

Mac の [`MacThermalMonitor`](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/MacThermalMonitor.swift) は `ProcessInfo.thermalState` を使う具体実装です。Mac の nonoptional `state` / `pressure` と live/finalization の policy 境界は [architecture.md](architecture.md#portable-core-の境界) を参照してください。Mac app とファイル処理・システム音声・遅延計測 CLI が同じ監視元を使います。

## 音声 import API

公開 import entry point は PortableRuntime の [`PortableAudioFileImporter.open(inputURL:sessionURL:)`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableAudioFileImporter.swift) です。Core の [`AudioImporter`](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioImporter.swift) が source を一度だけ `sessionURL/audio/original.*` にコピーし、[`PortableImportedAudioTimelineBuilder`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableImportedAudioTimelineBuilder.swift) が保存済み original を再コピーせず、Core の [`SessionLayout.processingDirectory`](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionLayout.swift)（audio directory 内の processing subdirectory）へ timeline を構築します。両 platform で Core の [`ImportedAudioTimelineBuilding`](../app/MacAmbientJev/Sources/MacAmbientJevCore/ImportedAudioTimelineBuilding.swift) contract を使い、builder の読み込み buffer は最大 8,192 frame、processing timeline は5秒単位の durable chunk に保存します。

Windows では [`PortableImportedAudioTimelineBuilder`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableImportedAudioTimelineBuilder.swift) が既存 WindowsSupport の [`AudioFileTimelineBuilder`](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/AudioFileTimelineBuilder.swift) に decode / SRC を委譲します。`.wav` / `.flac` / `.mp3` は miniaudio 0.11.23、`.m4a` / `.aac` は Windows Media Foundation AAC Source Reader で decode します。miniaudio の参照版は [0.11.23 release](https://github.com/mackron/miniaudio/releases/tag/0.11.23) です。拡張子の大文字・小文字は区別しません。未対応の拡張子、拡張子なし、対応拡張子でも decode できないファイルは、日本語の明示的なエラーで拒否し、別 decoder へ fallback しません。native read / seek error は EOF として扱わず、エラーとして伝播します。

入力は `SessionFileAccess.openHandle` で開いた session-pinned file handle です。miniaudio はこの handle の descriptor を読み、Media Foundation は同じ handle を複製して read-only IStream / byte stream を作り、MFCreateSourceReaderFromByteStream に渡します。Media Foundation が元ファイルの URL / pathname を再度開く経路はありません。詳細は Microsoft の [Source Reader によるメディアデータ処理](https://learn.microsoft.com/en-us/windows/win32/medfound/processing-media-data-with-the-source-reader) と [MFCreateSourceReaderFromByteStream](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-mfcreatesourcereaderfrombytestream) を参照してください。

各 chunk の全 channel を算術平均して mono にし、Core の `CanonicalAudioConverting` API を実装する Windows resampler へ渡します。16 kHz 以外では miniaudio 0.11.23 の公開 `ma_linear_resampler` API と order 8 Butterworth 低域フィルター（linear LPF8）を使います。公開 `ma_linear_resampler_config.lpfNyquistFactor` を `0.95` に設定し、カットオフを `min(sourceRate, 16000) / 2 × 0.95` とします。48 kHz から 16 kHz への downsampling cutoff は 7,600 Hz です。C wrapper は実際の 4 個の biquad section の Q 値（0.50979557910415918、0.60134488693504529、0.89997622313641557、2.5629154477415055）から DC group delay を計算し、最も近い整数の output frame 数へ丸めて返します。Swift 側はその frame 数を先頭出力から補償します。EOS では filter state をゼロ入力で進め、filter tail を音声時間に加えず、`CanonicalAudio.boundary(sourceFrames, sampleRate: sourceRate)` が定める（`round(sourceFrames * 16000 / sourceRate)`）半開区間の frame 数に切り詰めます。source rate は正の整数 UInt32 のみ受け付け、16 kHz は変換なしで通します。

Media Foundation AAC Source Reader は decode した native frames を canonical timeline に含め、AAC encoder priming / padding を除去しません。また、Media Foundation は AAC encoder priming を示す marker を付けません。Apple が encode した M4A は一般に 48 kHz で 2,112 frames（約 44 ms）の priming を含みます。Windows import ではこの priming を保持するため、Mac import より duration が長くなり、信号・イベント時刻も priming 分だけ後ろになります。Windows は累積 source extent を丸めた frame 境界まで出力します。一方、AVAudioConverter は EOS まで drain して正確な変換長の floor または ceil にあたる出力を保持します。同じ decoded source extent を SRC した場合、終端 frame 数は boundary rounding により Apple と Windows で最大 1 frame 異なることがあります。これは AAC priming の保持による差とは別です。sample 値も platform 間で bit-identical ではありません。

[`ImportedAudioTimelineWriter`](../app/MacAmbientJev/Sources/MacAmbientJevCore/ImportedAudioTimelineWriter.swift) は Core の共通 API で、mono canonical PCM を5秒単位の durable storage chunk と checkpoint に書き込みます。WindowsSupport の builder がこれを使い、timeline metadata は builder の呼び出し側が公開します。Pipeline の [`SessionProcessingAudio`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingAudio.swift) は共通 builder の注入を必須とし、recording reader を [`SessionAudioReaders`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionAudioReaders.swift)、recording compaction を [`RecordingAudioCompactor`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/RecordingAudioCompactor.swift) に委譲します。import timeline を作る場合は built `ProcessingTimelineReader` を検証して `.importedOriginal(reader.info)` を保存し、CAF export は Core の [`ProcessingTimelineAudioExporter`](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingTimelineAudioExporter.swift) が担います。これは session processing の責務で、`MacAmbientJevTranscribeFile` は一時 scratch directory を使う standalone file-processing CLI です。Windows の engine は WASAPI live capture をサポートしますが、GUI はありません。WASAPI backend は capture path 向けに CMiniaudio にコンパイルされます。

### WindowsSupport テスト

`MacAmbientJevWindowsSupportTests` はテスト中に生成する WAV と同梱の FLAC / MP3 / M4A / AAC fixture により、デコード、import copy の保持、timeline frame boundary、再構築時の partition invariant、symlink を含む session 境界、未対応拡張子・破損ファイルに対する日本語エラーを検証します。モデル不要の [`PortableAudioImportTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/PortableAudioImportTests.swift) は stored-original builder の no-copy 動作を検査し、Linux 条件付きで非 canonical 入力と非対応形式の拒否も検査します。

RIFF / RIFX WAV では、miniaudio 0.11.23 の `dr_wav` が宣言 data size を clamp する前に、セッションに固定された file handle 上で data chunk の payload 先頭位置 + 宣言 data size をファイルの物理サイズと照合します（[miniaudio 0.11.23 source](https://raw.githubusercontent.com/mackron/miniaudio/0.11.23/miniaudio.h)）。RIFF / RIFX container の宣言 extent はこの判定に使いません。data size が `0xFFFFFFFF` の WAV は物理サイズとの照合対象から除外し、streaming WAV を受け入れます。data payload 全体が物理サイズ内にあれば、後続 LIST chunk の実体が宣言より短い場合、RIFF outer size が物理サイズと 8 bytes 異なる場合、最後の data pad byte が欠けている場合も音声を受け入れます。回帰テストは streaming、短い trailing LIST、8 bytes 大きい outer size の各 WAV で import 成功を確認します。

RF64 WAV / FLAC では、デコード位置が宣言 frame 数に達する前に miniaudio が終端を返した場合、基礎ファイルの位置が物理終端にあるときに限り `AudioImportError.unexpectedEOF` とし、物理終端より前なら `MA_INVALID_DATA` によるデコード失敗とします。発生した read error は decoder の再 read でも保持されます。回帰テストでは、途中の FLAC subframe header の破損を物理 EOF より前のデコード失敗として確認します。CRC だけが壊れた FLAC では decoder が frame を skip して物理 EOF まで進むことがあり、CRC error 全般を個別のデコード失敗として検出するわけではありません。`AudioImportError.unexpectedEOF` の日本語メッセージは `音声ファイルが宣言されたフレーム数より前に終了しました。` です。

FLAC STREAMINFO の総サンプル数が 0 の場合、timeline model が宣言済み長さを必要とするため、デコーダー作成時に `AudioImportError.missingTotalSampleCount` を返します。日本語メッセージは `FLAC の総サンプル数が記録されていません。` です。借用した CRT descriptor を write-only descriptor に置き換えて `MA_IO_ERROR` を誘発するテストでは、native I/O エラーが clean EOF として扱われず、終端エラーとして保持されることも確認します。

fixture は [generate_windows_audio_fixtures.py](../scripts/generate_windows_audio_fixtures.py) が [FFmpeg 8.0](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.0/Changelog) で生成します。resampler の仕様と miniaudio 0.11.23 の出典は [CMiniaudio README](../app/MacAmbientJev/Sources/CMiniaudio/README.md)、[miniaudio 0.11.23 release](https://github.com/mackron/miniaudio/releases/tag/0.11.23)、[0.11.23 changes](https://raw.githubusercontent.com/mackron/miniaudio/0.11.23/CHANGES.md) を参照してください。Media Foundation の byte-stream API は [WinSDK 26100: MFCreateSourceReaderFromByteStream](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-mfcreatesourcereaderfrombytestream) を参照してください。

Resampler の連続 SRC テストは 8 / 16 / 22.05 / 44.1 / 48 / 96 kHz を使い、WAV と SRC の interior sine error を 0.025 未満、whole-buffer と異なる read partition 間の差を 1e-6 未満で検査します。別の regression test は、48 kHz の同振幅 1 kHz / 11 kHz tone を 16 kHz へ downsample し、11 kHz tone の rejection が 30 dB 以上であることを確認します。

FLAC / MP3 fixture は 48 kHz stereo、375 Hz の音声です。M4A / AAC の marker fixture は 48 kHz stereo で、silence、700 Hz から 3,700 Hz への chirp、silence、375 Hz sine の順に信号を配置します。M4A / AAC は Media Foundation の AAC priming を trim せず、marker の onset と canonical timeline 上の位置を確認します。marker は `abs(sample) > 0.05` で検出します。FLAC / MP3 の compressed interior sine error と M4A / AAC の sine error は 0.06 未満です。

FLAC 形式の仕様は [RFC 9639 (December 2024)](https://www.rfc-editor.org/rfc/rfc9639.html) を参照してください。

## Qwen3-ASR の prompt と token decoder

Linux / Windows の ONNX ASR engine は、PortableRuntime の [Qwen3ASR](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Qwen3ASR) ディレクトリにある prompt 生成と token id から text への復元を使います。どちらも ONNX Runtime を呼ばない純粋な Swift で、モデルの入出力は別の層が扱います。

`Qwen3ASRPrompt(audioTokenCount:)` は、encoder の出力 token 数 N（1以上）から decoder に渡す `input_ids`（Int64）を作ります。N が0以下なら `Qwen3ASRError.invalidAudioTokenCount` で失敗します。言語は日本語に固定し、引数にしません。prompt tail は Mac の speech-swift と同じ `language ja`（IDs `[11528, 11937]`）であり、[公式 qwen-asr 実装](https://raw.githubusercontent.com/QwenLM/Qwen3-ASR/main/qwen_asr/inference/qwen3_asr.py) の `_build_text_prompt` は完全な言語名 `language Japanese` を prefill します。

```text
[151644, 8948, 198, 151645, 198, 151644, 872, 198, 151669]
+ [151676] * N
+ [151670, 151645, 198, 151644, 77091, 198, 11528, 11937, 151704]
```

先頭の9個が `<|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>`、末尾が `<|audio_end|><|im_end|>\n<|im_start|>assistant\nlanguage ja<asr_text>` です。decoder graph の `audio_offset` は `Qwen3ASRPrompt.audioOffset`（9、最初の `<|audio_pad|>` の位置）です。

`Qwen3ASRTokenDecoder` は Hugging Face 形式の tokenizer.json から、復元に必要な `model.vocab` と `added_tokens`（`id`、`content`、`special`）だけを読みます。vocab の各 token は文字ごとに GPT-2 の ByteLevel の byte-unicode 表で byte に戻し、id ごとの byte 列にします。`special` の added token は text を出さず、それ以外の added token（`<think>`、`<asr_text>` など）は `content` をそのまま UTF-8 として使います。復元した byte 列全体は厳密に UTF-8 として解釈し、不正な列（1文字が複数 token に分かれた途中で終わる場合を含む）はエラーです。次の場合は明確なエラーで失敗します。

- ファイルがない、または JSON として不正
- `model.type` が BPE でない、または `decoder.type` が ByteLevel でない
- vocab に ByteLevel の文字集合にない文字がある
- id が vocab と added token の間、または added token 同士で重複する
- 復元時の id が tokenizer にない

`transcript(generatedIDs:endedAtTokenCap:)` は生成 id から認識結果の text を作ります。id が151704（`<asr_text>`）を含む場合は、最後の出現より後ろだけを使います。マーカーは `<asr_text>` が special ではなく text として復元されてしまうため、復元後の text ではなく id で探します。停止 token（151645 `<|im_end|>`、151643 `<|endoftext|>`）を除いて復元し、前後の空白と改行を削ります。マーカーがなければ全体を復元します。Mac の Qwen3ASR モデル（speech-swift）はマーカーを復元後の text から探して最初の出現より後ろを取り、前後の空白（改行は除く）を削ります。Linux / Windows は最後の出現より後ろを取り、改行も削る点と、未知の id を黙って飛ばさず失敗させる点で異なります。

[`fetch_qwen3_asr_tokenizer.py`](../scripts/fetch_qwen3_asr_tokenizer.py) は `fetch_silero_vad.py` と同じ仕様の引数なし fetcher で、[`pinned_download.py`](../scripts/pinned_download.py) を使います。取得元は [andrewleech/qwen3-asr-1.7b-onnx](https://huggingface.co/andrewleech/qwen3-asr-1.7b-onnx) の commit `df916193ac67e59347769891a21e10d81d12acdd` の tokenizer.json（11,429,377 byte、SHA-256 `bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92`）で、保存先は `.build/qwen3-asr-tokenizer/<commit>/` 配下、成功時の stdout は検証済み絶対 path 1行のみです。自己 test は `test_fetch_qwen3_asr_tokenizer.py` です。

tokenizer の path は test 専用の環境変数 `MAC_AMBIENT_JEV_QWEN3_TOKENIZER` で渡します。未設定・空・欠損の場合は fetch command を示すエラーになり、test は skip しません。`verify_portable.sh`、`test-windows.ps1`、`portable-core.yml` の Linux job が fetch して設定します。

[`qwen3_tokenizer_golden.json`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_tokenizer_golden.json) は実際の tokenizer.json を Python の `tokenizers` 0.23.3（`skip_special_tokens=True`）で復元した期待値です。日本語、ASCII 混在、句読点、改行、絵文字、1文字が複数 token に分かれる場合、special / 非 special の added token、transcript の規則を含みます。再生成は次のとおりで、同じ入力から同じ JSON を出力します。

```bash
uv run --python 3.12 --with tokenizers==0.23.3 python scripts/generate_qwen3_tokenizer_fixture.py --tokenizer "$(python3 scripts/fetch_qwen3_asr_tokenizer.py)"
```

Swift の test は [Qwen3ASRPromptTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRPromptTests.swift) と [Qwen3ASRTokenDecoderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRTokenDecoderTests.swift) にあり、上の fixture との照合と、合成した小さな tokenizer による各エラーの検査を行います。

### Qwen3-ASR ONNX モデルの取得

[`fetch_qwen3_asr_model.py`](../scripts/fetch_qwen3_asr_model.py) は Python 3.12 以上の標準ライブラリだけで動きます。CLI はサイズと保存先の両方を必須とし、サイズは `0.6b` または `1.7b` だけです。既定のサイズ・保存先はありません。

```text
python3 scripts/fetch_qwen3_asr_model.py <size> <destination>
```

`destination` は絶対パスで指定する、事前に存在するディレクトリです。相対パス、未作成のパス、ディレクトリでないパスは拒否されます。保存先の基底ディレクトリ（destination）は呼び出し側が事前に作成してください。fetcher は基底ディレクトリを作らず、モデルを `<destination>/qwen3-asr-<size>-int4-<commit>/` に取得します。作成するモデル保存先はこの子 directory のみです。以下は使用例であり、既定値ではありません。

```bash
# /absolute/path/to/models は事前に作成しておく
python3 scripts/fetch_qwen3_asr_model.py 0.6b /absolute/path/to/models
```

```powershell
# D:\Models\qwen3-asr-onnx は事前に作成しておく
python scripts/fetch_qwen3_asr_model.py 1.7b D:\Models\qwen3-asr-onnx
```

取得元は Apache-2.0 の Hugging Face repository を commit 固定で使います: [andrewleech/qwen3-asr-0.6b-onnx (`4fc24a1402e74db89c4d2ef256875e71680128c4`)](https://huggingface.co/andrewleech/qwen3-asr-0.6b-onnx/tree/4fc24a1402e74db89c4d2ef256875e71680128c4) と [andrewleech/qwen3-asr-1.7b-onnx (`df916193ac67e59347769891a21e10d81d12acdd`)](https://huggingface.co/andrewleech/qwen3-asr-1.7b-onnx/tree/df916193ac67e59347769891a21e10d81d12acdd)。取得 URL はこれらの固定 commit を直接指定し、[Hub REST API](https://huggingface.co/docs/hub/api) を使った最新版の解決、retry、代替 URL / filename への fallback は行いません。両 repository には `encoder.onnx` と、サイズ・SHA-256 が同じ `encoder.int4.onnx` の両方がありますが、fetcher は `encoder.onnx` を取得し、別名を試しません。

モデル directory には次の6ファイルを取得します: `encoder.onnx`、`decoder_init.int4.onnx`、`decoder_step.int4.onnx`、`decoder_weights.int4.data`、`embed_tokens.bin`、tokenizer.json。decoder の ONNX proto が参照する external-data の場所は厳密に `decoder_weights.int4.data` です。このファイルは同じ directory にこの名前で置く必要があります。[`pinned_download.py`](../scripts/pinned_download.py) が新規・既存ファイルの SHA-256 を検証し、fetcher はさらに各ファイルの正確な byte 数を検証します。不一致は再ダウンロードせず失敗します。 全6ファイルが存在し、サイズと SHA-256 がすべて一致する場合は、再実行してもネットワークから取得せず同じモデル directory を返します。

モデル重みの保存先は `.build` cache ではなく、指定した外部 directory です。外部の永続保存先は worktree 間で共有できます。既存の [`fetch_qwen3_asr_tokenizer.py`](../scripts/fetch_qwen3_asr_tokenizer.py) は tokenizer のみを `.build/qwen3-asr-tokenizer/<commit>/` に保存します。

成功時の stdout は取得したモデル directory の絶対パス1行だけです。終了コードは成功が `0`、引数・サイズ・保存先の不正が `2`、Python version、取得、integrity、OS の失敗が `1` です。[`test_fetch_qwen3_asr_model.py`](../scripts/test_fetch_qwen3_asr_model.py) はネットワーク上のモデル重みに依存しない offline self-test で、[`verify_portable.sh`](../scripts/verify_portable.sh) と [`test-windows.ps1`](../scripts/test-windows.ps1) から実行されます。両 runner は [`test_generate_qwen3_asr_token_reference.py`](../scripts/test_generate_qwen3_asr_token_reference.py) の依存 package・model weights 不要な Python self-test も実行します。full model weights は自動取得せず、full model inference は既定では実行しません。

### Qwen3-ASR の embedding と greedy 生成

PortableRuntime の純粋 Swift embedding・生成・text helper は、重みなしの unit test が可能で、下記 ONNX Qwen3-ASR engine からも使われます。`Qwen3ASREmbeddingTable(contentsOf:vocabSize:hiddenSize:)` は `embed_tokens.bin` を FP16 little-endian、row-major として読み、語彙数 `151936` と hidden size を呼び出し側が指定します。ファイルサイズが `vocabSize * hiddenSize * 2` と完全一致することと token ID の範囲を検証し、immutable な `Foundation.Data` を `.alwaysMapped` で memory map し、[`row(_ id: Int64) throws -> [Float]`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Qwen3ASR/Qwen3ASREmbeddingTable.swift) で選択した行だけを Float32 に変換します。ファイル全体を Swift 配列へコピーしません（[Foundation 6.2 の Data 読み込み実装](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BReading.swift)）。

`Qwen3ASRDecoderModel` は associated type Cache と `prefill(promptIDs:audioOffset:)` / `step(tokenID:position:cache:)` を定義します。prefill は位置 `0..<S` を使う契約で、最初の step は `S`、以降は1ずつ増加します。不透明な cache は Swift 配列へ変換せず各 step に渡します。汎用の `Qwen3ASRGreedyDecoder(model:)` の `generate(promptIDs:audioOffset:maxNewTokens:noRepeatNgramSize:)` は生成 ID、終了理由 `.stopToken(id)` / `.tokenCap`、`endedAtTokenCap` を返します。全引数を明示し、token cap は正数、no-repeat n-gram は `nil` または `3` のみです。停止 ID `151645` / `151643` は結果に含め、その後の step は行いません。同点では小さい ID を選び、空または NaN を含む logits はエラーです。3-gram 抑制は prompt ではなく生成済み ID だけを対象にし、抑制対象 ID が logits の範囲外なら明確なエラーにして黙って除外しません。

`transcript(generatedIDs:endedAtTokenCap:)` は marker・stop token 除外・trim 規則を適用し、`endedAtTokenCap == true` の場合に限って、有効な不完全 trailing UTF-8 byte を取り除いてから厳密に decode します。それ以外の不正 UTF-8 はエラーです。`endedAtTokenCap == false` の場合と `decode(_:)` は常に厳密です。Mac は切れた byte を U+FFFD に置換しますが、PortableRuntime は cap 到達時に限り不完全末尾を除きます。[embedding tests](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASREmbeddingTableTests.swift) は合成 FP16、[greedy tests](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRGreedyDecoderTests.swift) は scripted logits を使い、モデル重みは不要です。[token decoder tests](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRTokenDecoderTests.swift) も参照してください。

## Qwen3-ASR ONNX engine と実モデル test

### ONNX Qwen3-ASR engine

[`ONNXQwen3ASREngine`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/ONNXQwen3ASREngine.swift) は PortableRuntime の公開 `ASREngine` actor です。公開 initializer は `init(modelDirectory:size:intraOpThreads:)` で、モデル directory、size、各 ONNX session の intra-op thread 数をすべて明示します（default 引数はありません）。公開 `Qwen3ASRModelSize.small` の raw value は `0.6b`、hidden size は1024、`.large` の raw value は `1.7b`、hidden size は2048です。

[`qwen3_asr_models.json`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/qwen3_asr_models.json) は Swift engine と [`fetch_qwen3_asr_model.py`](../scripts/fetch_qwen3_asr_model.py) が共有する唯一のモデル情報源です。2サイズそれぞれの Hugging Face repository、pinned commit、hidden size、6ファイル名・正確な byte 数・SHA-256 を定義し、各ファイルには `encoder`、`decoder_init`、`decoder_step`、`decoder_weights`、`embed_tokens`、`tokenizer` のいずれかを必須かつ一意な `role` として割り当てます。Swift engine と fetcher は配列順ではなく `role` でファイルを参照します。`role` の欠落、重複、未対応値、必須 role の不在は不正です。同梱 manifest の不正は Swift engine が package 設定の欠陥として `fatalError` にし、fetcher はネットワーク取得前に ValueError で失敗します。fetcher は同じ resource を読んで取得・hash 検証に使います。`prepare()` は外部 model directory と6つすべての通常ファイルについて readable であることと manifest の正確な byte 数を検証しますが、起動時に SHA-256 は計算しません。モデルファイルや directory の不備は `prepare()` が throw します。

`prepare()` は engine 所有の `ONNXEnvironment`、encoder / decoder_init / decoder_step の3 session、memory-mapped embedding table、tokenizer を用意します。環境は3 session で共有され、3 session はそれぞれ `cpuMemoryArenaEnabled: false` を明示します。raw `ONNXSession` を直接使う呼び出し側のように environment を渡す API ではありません。各 graph は session 作成後、次の session を作る前に、入力・出力の数と名前、float32 / int64 型、shape metadata を検証します。静的次元は完全一致し、動的次元は `-1` として扱います。dynamic batch 軸だけは metadata が `-1` または1であることを許容します。実行時の encoder `audio_features` は `[1, N, H]`、`N > 0`、`H` が選択モデルの hidden size（1024 / 2048）と一致することも検証します。

推論ごとの mel 特徴量は encoder へ渡し、`audio_features` は `ONNXValue` のまま `decoder_init` に渡すため Swift 配列への出力コピーはありません。decoder の KV cache (`present_keys` / `present_values`) も ONNX Runtime 所有の `ONNXValue` として次の step の `past_keys` / `past_values` に渡し、Swift 経由で複製しません。logits は最後の sequence row だけを Swift 配列へ読み出します。各 step で置き換えられた cache は不要になり次第解放され、run の `ONNXValue` は各 transcription 内だけで使われます。sessions、embedding、tokenizer は準備後に共有されますが、音声特徴量や cache は run 間で共有されません。

Actor は同時の `prepare()` 呼び出しで1つの準備 task を共有します。準備失敗は `.failed` 状態となり、後の `prepare()` で再試行できます。`unload()` は進行中 load の generation を取り消し、モデル資産を外して load task の終了を待ちます。並行する unload も同じ準備 task の終了を待ち、unload 中に呼んだ `prepare()` は cancellation error になります。

`transcribe(_:)` はまず16 kHz以外の sample rate を拒否し、次に prepared 状態を確認し、その後に最小音声長を判定します。最小長は `ASRAudioInput.minimumDurationSeconds` の0.02秒（16 kHzで320 samples）で、これ未満の入力は推論せず空 text と `detectedLanguage == nil` を返します。認識言語は日本語固定で、戻り値の `detectedLanguage` は常に `nil` です。生成は最大448 token、停止 token ID `151645` / `151643` で終了し、音声が厳密に15秒を超える場合だけ生成済み token に対する3-gram抑制を有効にします。

provenance は `engine = onnxruntime-qwen3-asr`、`model = <repository>@<commit>`、`version = onnxruntime-1.31.0` です。configuration は次の値です。

| key | value |
| --- | --- |
| `language` | `ja` |
| `minimum_input_seconds` | `0.02` |
| `quantization` | `int4` |
| `mel_variant` | `whisper-slaney-128-nfft400-hop160-reflect-global-log10` |
| `max_new_tokens` | `448` |
| `no_repeat_ngram` | `3 when input_seconds > 15; disabled otherwise` |

### 実モデルを使う opt-in test

[`ONNXQwen3ASRModelTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXQwen3ASRModelTests.swift) の実モデル推論は、`RUN_MODEL_TESTS` が文字列としてちょうど `1` の場合だけ有効です。それ以外の値や未設定では無効です。有効時は `QWEN3_ASR_ONNX_MODEL_DIRECTORY` と `QWEN3_ASR_ONNX_MODEL_SIZE` の両方が必須で、前者は絶対 path の既存 readable directory、後者は厳密に `0.6b` または `1.7b` でなければなりません。有効時に設定が欠落・不正なら skip せず test failure になります。[`Qwen3ASRModelTestConfigurationTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRModelTestConfigurationTests.swift) はこの設定検証を確認します。以下のように各サイズで別々に実行します（release build は `-c release` を追加）。

```bash
export RUN_MODEL_TESTS=1
export QWEN3_ASR_ONNX_MODEL_DIRECTORY="/absolute/path/to/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4"
export QWEN3_ASR_ONNX_MODEL_SIZE=0.6b
swift test --package-path app/MacAmbientJev --filter ONNXQwen3ASRModelTests

export QWEN3_ASR_ONNX_MODEL_DIRECTORY="/absolute/path/to/models/qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd"
export QWEN3_ASR_ONNX_MODEL_SIZE=1.7b
swift test --package-path app/MacAmbientJev --filter ONNXQwen3ASRModelTests
```

```powershell
$env:RUN_MODEL_TESTS = '1'
$env:QWEN3_ASR_ONNX_MODEL_DIRECTORY = 'D:\Models\qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4'
$env:QWEN3_ASR_ONNX_MODEL_SIZE = '0.6b'
swift test --package-path app/MacAmbientJev --filter ONNXQwen3ASRModelTests

$env:QWEN3_ASR_ONNX_MODEL_DIRECTORY = 'D:\Models\qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd'
$env:QWEN3_ASR_ONNX_MODEL_SIZE = '1.7b'
swift test --package-path app/MacAmbientJev --filter ONNXQwen3ASRModelTests
```

Linux Docker では model directory を read-only で mount できます。次の例は小サイズの固定 commit directory を mount し、container 内で ONNX Runtime SDK を取得して test を実行します。大サイズでは model path と size をそれぞれ `qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd` と `1.7b` に置き換えます。

```bash
docker run --rm \
  -v "$PWD:/repo" \
  -v "$PWD/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:ro" \
  -w /repo swift:6.2-noble bash -lc '
    apt-get update -qq &&
    apt-get install -y -qq python3 curl >/dev/null &&
    python3 scripts/fetch_onnxruntime.py &&
    RUN_MODEL_TESTS=1 \
    QWEN3_ASR_ONNX_MODEL_DIRECTORY=/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4 \
    QWEN3_ASR_ONNX_MODEL_SIZE=0.6b \
    swift test --package-path app/MacAmbientJev --filter ONNXQwen3ASRModelTests
  '
```

### 日本語音声 fixture

実モデル test は [`qwen3_asr_voicevox_short.wav`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox_short.wav) と [`qwen3_asr_voicevox_long.wav`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox_long.wav) を使います。両方とも mono PCM16、16 kHz WAV です。参照文は合成時に渡したコーパス文そのもので、短い音声は `general-001`、長い音声は `long-001`、`statistics-001`、`question-001` をこの順に連結しています。

| fixture | 参照文 | 長さ | samples | bytes | SHA-256 |
| --- | --- | ---: | ---: | ---: | --- |
| short | 今日は音声認識の動作を確認します。 | 3.3066875 秒 | 52,907 | 105,858 | `2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9` |
| long | 通信相手を認証したあと、セッション鍵を共有し、その鍵を使って以降の通信内容を暗号化する流れを考えます。今日の講義ではベイズ推定について説明します。この場合、公開鍵はどこで配布されるのでしょうか。 | 18.464 秒 | 295,424 | 590,892 | `d50f7f2a1fe9665279689e53297772aeb52c43d9068c82ab21b21fa62cac78b2` |

音声は VOICEVOX ENGINE の固定 image voicevox/voicevox_engine@sha256:52bfd61345fe6896a3d0014e0efd1931f6d2f91f501f3c27181e7bce05b47d68（CPU linux/arm64）で生成します。engine `/version` は 0.25.2（[0.25.2 release](https://github.com/VOICEVOX/voicevox_engine/releases/tag/0.25.2)、[README](https://raw.githubusercontent.com/VOICEVOX/voicevox_engine/0.25.2/README.md)）、speaker library version は 0.16.0、speaker UUID は `388f246b-8c41-4ac1-8e2d-5d79f3ff56d9`、話者・style は ずんだもん／ノーマル（style ID `3`）です。クレジットは `VOICEVOX:ずんだもん` です。生成器は engine version、speaker/style と `/audio_query` の値を検証し、不一致なら fallback せず失敗します。query は speed 1、pitch 0、intonation 1、volume 1、pre/post phoneme length 0.1、24 kHz、stereo false です。生成された 24 kHz mono PCM16 を整数演算の線形変換で16 kHzへ変換します。出力 frame 数は ceil、端点は clamp、丸めは ties-to-even で、padding はしません。同じ設定で2回生成した WAV は bit-identical です。

[`qwen3_asr_voicevox.LICENSE.txt`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox.LICENSE.txt) はこの2つの音声に適用される利用条件と生成元を記録します。[VOICEVOX 利用規約](https://voicevox.hiroshiba.jp/term/)、[東北ずん子・ずんだもんプロジェクト音源利用規約](https://zunko.jp/con_ongen_kiyaku.html) および [VOICEVOX 音声モデル・音声ライブラリ利用規約](https://raw.githubusercontent.com/VOICEVOX/voicevox_vvm/main/TERMS.txt) に従い、クレジットを表示した商用・非商用利用が認められる音声を、中立的な test fixture として規約上の制限を保って配布しています。この音声はリポジトリの software license や CC0 で再許諾されるものではありません。再配布時は WAV とともにこの注意書きと規約へのリンクを保持し、`VOICEVOX:ずんだもん` のクレジットと適用条件を受領者にも伝えてください。VOICEVOX software、音声 library、model、画像は同梱・再配布しません。

再生成には Python 3.12 以上、`curl`、Docker が必要です。repository root で固定 image を起動し、最大120回・2秒間隔で `/version` の readiness を確認してから [`generate_qwen3_asr_fixtures.py`](../scripts/generate_qwen3_asr_fixtures.py) を実行します。終了時は trap で固定 container 名を削除します。

```bash
set -eu
docker run -d --platform linux/arm64 \
  -p 127.0.0.1:50021:50021 \
  --name qwen3-fixture-voicevox \
  voicevox/voicevox_engine@sha256:52bfd61345fe6896a3d0014e0efd1931f6d2f91f501f3c27181e7bce05b47d68
trap 'docker rm -f qwen3-fixture-voicevox >/dev/null 2>&1 || true' EXIT
ready=0
for attempt in {1..120}; do
  if curl --fail --silent http://127.0.0.1:50021/version >/dev/null; then
    ready=1
    break
  fi
  if [ "$attempt" -lt 120 ]; then sleep 2; fi
done
test "$ready" -eq 1
python3 -B scripts/generate_qwen3_asr_fixtures.py --base-url http://127.0.0.1:50021
```

生成器はコーパス ID の不足・重複、engine / style の不一致、query の値の不一致、入力 WAV の形式・長さを検証してから両方の出力を公開します。生成器の offline self-test は [`test_generate_qwen3_asr_fixtures.py`](../scripts/test_generate_qwen3_asr_fixtures.py) で実行します。

```bash
python3 -B scripts/test_generate_qwen3_asr_fixtures.py
```

### 実モデル test の音声照合

opt-in test は合成時と同一の各参照文に対して short / long を別々に照合し、CER 計算前には空白と句読点だけを除去します。受け入れ上限は short `<= 0.05`、long `<= 0.15` です。両 fixture で非空の日本語 text、`detectedLanguage == nil`、WAV の正確な sample 数、および2回の認識 text の一致も検証します。long は15秒を超えるため、runtime の no-repeat 3-gram 経路を通ります。空入力と319-sample入力についても、空 text と `detectedLanguage == nil` を確認します。first / repeat RTF は `prepare()` 後の `transcribe()` だけを計測して出力し、準備時間を含めませんが、RTF の test threshold はありません。既存の first / repeat baseline measurements は[測定記録](records/qwen3-asr-token-memory-2026-10-20.md)にあります。

### 独立 token reference と完全一致 test

[`generate_qwen3_asr_token_reference.py`](../scripts/generate_qwen3_asr_token_reference.py) は、実モデルの生成 token ID と復元 text の独立した参照 fixture を作ります。同梱の [`qwen3_asr_token_reference.json`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_token_reference.json) は0.6b model commit `4fc24a1402e74db89c4d2ef256875e71680128c4` と `ja` で生成した固定 parity fixture です。生成器は `--model-size` に `0.6b` または `1.7b`、`--language-tag` に `ja` または `"Japanese"` を受け取ります。prompt は tokenizer の special token を `token_to_id` で引き、`system`、`user`、`assistant`、改行、`language <tag>` を `add_special_tokens=False` で encode して組み立て、tag ごとの literal ID（`ja` は `[11528, 11937]`、`"Japanese"` は `[11528, 10769]`）と照合します。不一致なら推論前に失敗します。`ja` の prompt は製品の `Qwen3ASRPrompt` と一致し、`"Japanese"` では language token だけが変わります。出力 metadata は model の hidden size（0.6b は1024、1.7b は2048）と `reference.language_tag` を記録します。同梱 fixture にはこの2つの field はありません。

生成器の `--model-directory`、`--output` に加えて `--model-size`、`--audio-manifest`、`--language-tag` はすべて必須です。`--audio-manifest` は絶対 JSON path で、root object の key は厳密に `{schema_version, clips}`、`schema_version` は1です。各 `clips` entry の key も厳密に `{id, file, sample_count, sha256}` です。`id` は重複のない空でない文字列、`file` は manifest と同じ directory に置く symlink でない通常 WAV file の basename（traversal 不可）、`sample_count` は正の整数、`sha256` は小文字16進64文字でなければなりません。各 WAV は mono PCM16・16 kHz で、hash と sample count を検証します。

同梱の short / long WAV を再生成入力に使う場合、Docker 外の `/absolute/path/to/short-long-inputs` に2つの WAV をコピーし、次の manifest を manifest.json として置きます。

```json
{
  "schema_version": 1,
  "clips": [
    {
      "id": "short",
      "file": "qwen3_asr_voicevox_short.wav",
      "sample_count": 52907,
      "sha256": "2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9"
    },
    {
      "id": "long",
      "file": "qwen3_asr_voicevox_long.wav",
      "sample_count": 295424,
      "sha256": "d50f7f2a1fe9665279689e53297772aeb52c43d9068c82ab21b21fa62cac78b2"
    }
  ]
}
```

fixture には model の6ファイルそれぞれの実 byte 数と SHA-256、commit、短・長 WAV の SHA-256、Python と全 installed distribution の version、参照実行の設定を記録します。同梱 fixture の reference metadata は `platform=Linux`、`architecture=aarch64`、`intra_op_threads=2`、`inter_op_threads=1` を示します。この platform / architecture は同梱 fixture の参照実行環境を表し、生成器の全出力に共通する値ではありません。各 clip には `prompt_ids`、`audio_token_count`、`no_repeat_ngram_size`、`ended_at_token_cap`、生成 ID と text が含まれます。生成器は Python 3.12、NumPy 2.2.6、Transformers 4.57.1、tokenizers 0.22.2、ONNX Runtime 1.31.0 を要求します。NumPy と Transformers は log-mel golden と同じ版です。必須 package version、選択 model size に対応する model metadata と6ファイルの byte 数・SHA-256、WAV manifest の形式・sample 数・SHA-256 が合わない場合は、推論や出力 JSON の書き込み前に失敗します。

参照の mel は Transformers の公式 Whisper NumPy 経路 `_np_extract_fbank_features`（`feature_size=128`、16 kHz、`n_fft=400`、`hop_length=160`、`dither=0`）を使い、WAV 全体をそのまま渡します。30秒への padding / truncation はしません。ONNX Runtime の encoder / decoder session は CPUExecutionProvider のみ、intra-op 2、inter-op 1、CPU memory arena 有効で動作します。`audio_offset` は常に9です。prompt は選択した language tag に従い、`ja` だけが製品 prompt literal `language ja` と一致します。`"Japanese"` にすると language token だけが変わります（上記 [prompt と token decoder](#qwen3-asr-の-prompt-と-token-decoder)）。FP16 little-endian の embedding row を選択して Float32 に変換し、greedy 同点は最小 token ID を選びます。stop token `151645` / `151643` は生成 ID 配列に含めてその位置で停止し、最大生成数は448です。15秒を超える音声だけ生成済み ID に対する no-repeat 3-gram を使います。text は tokenizers の decode で special token を除いて復元します。

`exactTokenParity` は固定 fixture の各 clip について、`Qwen3ASRPrompt(audioTokenCount:)` と `prompt_ids`、`audio_token_count`、`no_repeat_ngram_size`、`ended_at_token_cap` を照合し、実モデル実行では生成 ID と text も完全一致で検証します。prompt と decoding の診断は区別され、fixture と実行環境それぞれの platform / architecture / intra-op thread 数をログに出力します（Swift parity は intra-op 2 / inter-op 1）。独立した [metadata test](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXQwen3ASRModelTests.swift) は model なしで fixture の prompt と metadata を検証します。parity は固定 fixture と実際に実行した platform に限り、任意の platform への保証でも mel / logits の bit identity でもありません。この固定 fixture で token ID と text の完全一致を確認した platform は Linux aarch64（Swift 6.2.4 release）と Windows ARM64（Swift 6.2.0 debug）です。両者とも ONNX Runtime 1.31.0、intra-op 2 / inter-op 1 での結果であり、任意の platform への保証ではありません（[Linux parity 記録](records/qwen3-asr-token-memory-2026-10-20.md#parity)、[Windows ARM64 記録](records/qwen3-asr-token-memory-2026-10-20.md#windows-arm64-vm2026-10-20)）。

[ONNXQwen3ASRModelTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXQwen3ASRModelTests.swift) の `exactTokenParity` test は `RUN_MODEL_TESTS` が文字列として `1` で、既存の必須 `QWEN3_ASR_ONNX_MODEL_DIRECTORY` / `QWEN3_ASR_ONNX_MODEL_SIZE` 設定が有効な場合に実行します。reference は0.6bだけなので、size が明示的に `1.7b` の場合は skip します。その他の欠落・不正な model 設定は skip や別 model への fallback ではなく test failure です。test は `@testable` の内部 `transcribeWithTokens` 結果から、同じ推論 run の `generatedIDs` と `text` を取得し、生成 ID の配列全体を許容差なしで比較します。この内部結果はその推論 run の比較にのみ使い、後続の推論 run へ保持しません。不一致時は最初の差の0-based index、expected / actual ID と配列長を出力して失敗します。public API の追加や token の永続保存はありません。

Python 3.12 の virtual environment をコンテナ内の `/tmp` に作り、4 package を固定して fixture を再生成します。model directory は例のとおり読み取り専用 mount とし、出力は worktree 内の指定 fixture だけです。仮想環境はコンテナが削除されるまで残ります。

```bash
docker run --rm \
  -v "$PWD:/src" \
  -v "/absolute/path/to/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:ro" \
  -v "/absolute/path/to/short-long-inputs:/inputs:ro" -w /src swift:6.2-noble bash -lc '
    apt-get update -qq &&
    apt-get install -y -qq python3-venv >/dev/null &&
    export TMPDIR=/tmp &&
    TOKEN_TMP="$(mktemp -d "${TMPDIR:?}/qwen3-token.XXXXXX")" &&
    python3 -m venv "${TOKEN_TMP:?}/venv" &&
    "${TOKEN_TMP:?}/venv/bin/python" -m pip install \
      numpy==2.2.6 transformers==4.57.1 tokenizers==0.22.2 onnxruntime==1.31.0 &&
    "${TOKEN_TMP:?}/venv/bin/python" scripts/generate_qwen3_asr_token_reference.py \
      --model-directory /models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4 \
      --model-size 0.6b \
      --audio-manifest /inputs/manifest.json \
      --language-tag ja \
      --output /src/app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_token_reference.json
  '
```

参照元は [Transformers v4.57.1 Whisper feature extractor](https://raw.githubusercontent.com/huggingface/transformers/v4.57.1/src/transformers/models/whisper/feature_extraction_whisper.py)、[ONNX Runtime v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)、[ONNX Runtime Python API](https://onnxruntime.ai/docs/api/python/api_summary.html)、[tokenizers 0.22.2 API](https://huggingface.co/docs/tokenizers/v0.22.2/api/tokenizer) と [release](https://github.com/huggingface/tokenizers/releases/tag/v0.22.2) です。

### 複数回推論の RSS benchmark

[ONNXQwen3ASRModelTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXQwen3ASRModelTests.swift) の `memoryOverManyCalls` test は `QWEN3_ASR_MEMORY_BENCHMARK=1` と `RUN_MODEL_TESTS=1` の両方でのみ有効です。既存の `QWEN3_ASR_ONNX_MODEL_DIRECTORY` と `QWEN3_ASR_ONNX_MODEL_SIZE` も必須で、欠落・不正なら test は失敗します。engine を一度だけ prepare し、長い WAV に対して public `transcribe` を50回実行します。各結果は蓄積せず、text が毎回一定かを検査します。RSS は `after_prepare`、`after_call_1`、`after_call_10`、`after_call_25`、`after_call_50`、`after_unload` で出力します。

Linux は [`/proc/self/status`](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html) の VmRSS kB 値を1024倍して byte 数にします。Windows は current process に対する WinSDK K32GetProcessMemoryInfo の `PROCESS_MEMORY_COUNTERS.WorkingSetSize` を byte 数として読みます（[Microsoft API reference](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo)）。値が欠落・不正、または Windows API 呼び出しに失敗した場合は例外にします。各呼び出しの RTF と50回合計の RTF を表示します。合計時間は prepare と unload を含まず、RTF の test threshold はありません。

製品では Qwen3-ASR の encoder / decoder_init / decoder_step の3 session は `cpuMemoryArenaEnabled: false`、Silero は `true` を固定使用し、runtime selector はありません。Qwen の選択理由は arena disabled で warm RSS が低かった測定結果です（[2026-10-20 JST の記録](records/qwen3-asr-token-memory-2026-10-20.md)）。一般の `ONNXSession` は呼び出し側が必須の bool を指定し、default はありません。

Windows では既存の model directory / size 環境変数を設定した状態で、release 用 ONNX Runtime DLL を配置してから実行します。以下は repository root から実行します。

```powershell
$ErrorActionPreference = 'Stop'
$env:RUN_MODEL_TESTS = '1'
$env:QWEN3_ASR_MEMORY_BENCHMARK = '1'
$runtimeRoot = python scripts/fetch_onnxruntime.py
if ($LASTEXITCODE -ne 0) { throw 'ONNX Runtime fetch failed' }
swift build --package-path app/MacAmbientJev -c release
if ($LASTEXITCODE -ne 0) { throw 'Release build failed' }
$releaseBin = swift build --package-path app/MacAmbientJev -c release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve release binary path' }
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'lib/onnxruntime.dll') `
  -Destination (Join-Path $releaseBin 'onnxruntime.dll') -Force
swift test --package-path app/MacAmbientJev -c release --filter ONNXQwen3ASRModelTests/memoryOverManyCalls
if ($LASTEXITCODE -ne 0) { throw 'RSS benchmark failed' }
```

Linux Docker では model directory を読み取り専用で mount します。`/absolute/path/to/models` は手元で用意した絶対 path の例であり、既定 path ではありません。

```bash
docker run --rm \
  -v "$PWD:/repo" \
  -v "/absolute/path/to/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:ro" \
  -w /repo swift:6.2-noble bash -lc '
    apt-get update -qq &&
    apt-get install -y -qq python3 curl >/dev/null &&
    python3 scripts/fetch_onnxruntime.py &&
    RUN_MODEL_TESTS=1 \
    QWEN3_ASR_MEMORY_BENCHMARK=1 \
    QWEN3_ASR_ONNX_MODEL_DIRECTORY=/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4 \
    QWEN3_ASR_ONNX_MODEL_SIZE=0.6b \
    swift test --package-path app/MacAmbientJev -c release \
      --filter ONNXQwen3ASRModelTests/memoryOverManyCalls
  '
```

## Qwen3-ASR の log-mel 前処理

PortableRuntime の [`Qwen3ASRMelFrontend`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Qwen3ASR/Qwen3ASRMelFrontend.swift) は、ONNX Runtime を使わず Qwen3-ASR encoder 用 log-mel 特徴量を計算します。公開 API は `Qwen3ASRMelFrontend.init()` と `compute(samples: [Float]) throws -> Qwen3ASRMelSpectrogram` です。入力は呼び出し側が用意する16 kHz mono 音声で、この API は resampling しません。結果の `values: [Float]` は row-major の 128×T、`frameCount: Int` は T で、encoder 入力は `[1, 128, T]` です。

入力は非空・有限で、reflect padding のため最低201 sample 必要です。`T = floor(N / 160)` が120,000を超える場合は、出力確保や入力走査より前に拒否します。エラーは `Qwen3ASRMelError.emptyInput`、`inputTooShort(sampleCount:)`、`nonFiniteSample(index:)`、`tooManyFrames(Int)` で、代替処理はしません。

400 sample の periodic Hann window、hop 160、中央に左右200 sample の reflect padding を使い、保持する T frame だけを計算します。各 frame は400点の非正規化 DFT から201個の power bin を作ります。Slaney scale、128 mel、0–8,000 Hz、HTK なし、area normalization の mel filter を適用します。filter は Swift で動的に計算し、大きな固定 table は持ちません。FFT は25個の長さ16の radix-2 FFT と25項の合成で構成し、twiddle と疎な filter を cache します。ONNX Runtime、Accelerate、外部 FFT library は使わず、中間計算は Double として、大きな有限 Float 入力でも power が overflow しないようにします。各 mel 値を `log10(max(mel, 1e-10))` に変換し、保持 frame 内の最大値を M として `max(x, M - 8)` に clamp した後に `(x + 4) / 4` で正規化します。出力から除外する frame は計算せず、最大値と clamp にも含めません。

[`Qwen3ASRMelFrontendTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRMelFrontendTests.swift) は、[`qwen3_mel_golden.json`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_mel_golden.json) に対する golden 一致、入力検証、境界、正規化を検査します。6入力は、1秒の440/1,000 Hz sine mix（16,000 sample、100 frame）、180–6,200 Hz chirp（3,791、23）、0.3秒 envelope sine（4,800、30）、最後の sample（index 479）に peak を置く `last_frame_peak`（480、3）、最小 reflect 入力（201、1）、および index 558 だけに peak を置く `dropped_only_peak`（559、3）です。480-sample peak は保持 frame の window にも入るため dropped-only ではありません。559 sample では保持 window の末尾が source index 519 なので、index 558 の peak は除外 frame のみに入り、同じ長さの無音と出力が完全一致することも検査します。golden の入力は Float32 little-endian Base64、出力は row-major 全値を丸めずに JSON に保存し、Swift 照合許容差は `2e-7` です。

golden は Transformers 4.57.1 の WhisperFeatureExtractor(feature_size=128, sampling_rate=16000, hop_length=160, n_fft=400, dither=0) を使い、`_np_extract_fbank_features(audio[None, :], device='cpu')[0]` を明示的に呼び出して生成します。各入力をそのまま渡すため30秒への padding / truncation はせず、Torch 実装を自動選択しません。librosa の float64 Slaney mel filter（fmax 8,000 Hz）は公式 filter と丸め誤差の範囲で一致します。NumPy DFT の実装差を別途見る openai-whisper chirp cross-check の許容差は `5e-5` で、Swift golden の `2e-7` とは別の照合です。生成元は [Transformers Whisper feature extractor v4.57.1](https://github.com/huggingface/transformers/blob/v4.57.1/src/transformers/models/whisper/feature_extraction_whisper.py) と [openai-whisper audio.py v20250625](https://github.com/openai/whisper/blob/v20250625/whisper/audio.py) です。生成環境は Python 3.12.14、NumPy 2.2.6、librosa 0.11.0、Transformers 4.57.1、torch 2.8.0、openai-whisper 20250625 で、全47 distribution の version は fixture metadata に provenance として記録します（Swift test は version を検査しません）。librosa の変更履歴と Transformers release は [librosa 0.11.0 changelog](https://librosa.org/doc/0.11.0/changelog.html) と [Transformers v4.57.1 release](https://github.com/huggingface/transformers/releases/tag/v4.57.1) を参照してください。

fixture の再生成は、macOS arm64 で記録された生成環境の依存集合を fixture metadata から pin して実行します。host によって installed distribution metadata が変わる場合があります。Python 仮想環境と uv cache は `${TMPDIR}` 内に作り、削除しません（worktree 内には作成しません）。[`generate_qwen3_mel_fixture.py`](../scripts/generate_qwen3_mel_fixture.py) は引数なしで実行します。

```bash
set -eu
MEL_TMP="$(mktemp -d "${TMPDIR:?}/qwen3-mel.XXXXXX")"
export UV_CACHE_DIR="${MEL_TMP:?}/uv-cache"
uv venv --python 3.12.14 "${MEL_TMP:?}/venv"
python3 - "${MEL_TMP:?}/requirements.txt" <<'PY'
import json,sys
from pathlib import Path
fixture=json.loads(Path('app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_mel_golden.json').read_text())
versions=fixture['metadata']['versions']['distributions']
Path(sys.argv[1]).write_text(''.join(f'{name}=={version}\n' for name,version in sorted(versions.items())))
PY
uv pip install --python "${MEL_TMP:?}/venv/bin/python" -r "${MEL_TMP:?}/requirements.txt"
"${MEL_TMP:?}/venv/bin/python" scripts/generate_qwen3_mel_fixture.py
```

Performance test は30秒（480,000 sample）の入力を同期実行し、初回と3回の warm 実行を計測します。`QWEN3_MEL_BENCHMARK=1` を設定した場合だけ実行し、既定では skip します。release build の opt-in command は次のとおりです。

```bash
QWEN3_MEL_BENCHMARK=1 swift test --package-path app/MacAmbientJev -c release --filter Qwen3ASRMelFrontendPerformanceTests --no-parallel
```

Release / Debug の実測値、fixture 誤差、Linux test 結果は[2026-10-19 の計測記録](records/qwen3-mel-2026-10-19.md)を参照してください。

## Community-1 話者分離モデルの取得

話者分離の固定 model は4ファイルで、取得元・revision・byte 数・SHA-256 は1つの manifest [`community1_diarization_models.json`](../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Resources/community1_diarization_models.json) だけが持ちます。この JSON は `MacAmbientJevDiarization` target の resource として全 OS で同梱され、Swift の `Community1Manifest` と Python の fetcher が同じファイルを読みます。ファイル名・revision・hash を Swift や script の定数に複製しません。

| role | repository（固定 revision） | ファイル | byte 数 | SHA-256 |
| --- | --- | --- | ---: | --- |
| segmentation | [avencera/speakrs-models](https://huggingface.co/avencera/speakrs-models/tree/67f963b6a1d94fcd4678948237b3cc8bd69bf1d8)（`67f963b6a1d94fcd4678948237b3cc8bd69bf1d8`） | `segmentation-3.0.onnx` | 5,916,308 | `038b971741ed623af9773ecafdefa4b7bc523520099c2a68f8568b24189e8ad9` |
| embedding | 同上 | `wespeaker-multimask-tail.onnx` | 26,777,461 | `3695eeb26e875c606d5b5d82314f08dbcbb685d691837c035d7ea690863c64ea` |
| plda | [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/df2625ac79a7ac6b65ad868fee6d80f320da4232)（`df2625ac79a7ac6b65ad868fee6d80f320da4232`） | `plda-parameters.json` | 89,416 | `38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f` |
| xvector | 同上 | `xvector-transform.json` | 177,499 | `f7cd5cc16e63e2d89db052a23018ecfc47a311998ed1e9e39838fbac65048688` |

manifest はさらに、PLDA の128個の座標符号 `coordinateSigns`（各 -1 または 1）を持ちます。固有ベクトルの符号は数学的に一意でないため、移植した固有値分解が逆符号の rho を返しても有効な解になります。そこで Mac の Core ML graph（PldaRho.mlmodelc）の射影行から導いた符号（各行で絶対値が最大の座標の符号、同率は最小 index）を manifest に固定し、`Community1PLDA` が行ごとに適用します。符号はこの manifest だけが持ち、`plda-rho.json` fixture は持ちません。Mac の PLDA oracle（`RUN_MODEL_TESTS=1`）は Core ML graph から導いた符号が manifest と一致することを検査し、portable の PLDA test は manifest の符号を読みます。符号を変えるときは oracle で再導出した値で manifest を更新します。

[`fetch_community1_diarization.py`](../scripts/fetch_community1_diarization.py) は Python 3.12 以上の標準ライブラリのみを使う引数なし fetcher で、`fetch_silero_vad.py` と同じ [`pinned_download.py`](../scripts/pinned_download.py) を使います。各ファイルは `https://huggingface.co/<repository>/resolve/<revision>/<ファイル名>` の固定 URL だけから取得し、retry や代替 URL は使いません。保存先は `.build/community1-diarization/<2つの revision の先頭12文字をソース名順に連結>/`（現在は `df2625ac79a7-67f963b6a1d9`）で、4ファイルをこの1 directory に置きます。ダウンロード後と既存ファイルの再利用時に SHA-256 を検証し、さらに正確な byte 数を検証します。不一致は再ダウンロードせずエラーにします。4ファイルがすべて有効なら再実行してもネットワークを使わず、更新時刻を変えずに同じ directory を返します。ダウンロードは一時ファイルに書いて検証してから `os.replace` で公開するため、中断しても最終名のファイルは作られず、次の実行は最初から取得し直します。強制終了で残った `.<ファイル名>.*.download` は次の実行が無視します（自動削除はしません）。成功時の stdout は検証済み directory の絶対 path 1行だけです。空白や非 ASCII を含むリポジトリ path も扱います。

```bash
MODELS="$(python3 scripts/fetch_community1_diarization.py)"
```

```powershell
$community1Lines = @(python scripts/fetch_community1_diarization.py)
if ($LASTEXITCODE -ne 0) { throw 'Community-1 diarization fetch failed' }
if ($community1Lines.Count -ne 1) { throw 'Community-1 diarization fetch must return exactly one output line' }
$models = [string]$community1Lines[0]
```

Swift 側は `Community1Assets(modelDirectory:)`（同梱 manifest を使う公開 init。内部の `init(modelDirectory:manifest:)` は test が manifest を差し替えるために使う）が caller の渡した directory で4ファイルの通常ファイル型・byte 数・SHA-256 を順に検証し、2つの JSON から `Community1PLDA` を manifest の符号付きで作ります。欠落・サイズ違い・hash 違い・通常ファイルでないものは、ファイル名と fetch command を含む明確なエラーで失敗し、修復や代替 path はありません。directory 内の無関係な追加ファイルは検査しません。検証とロードは暗黙に download しません。SHA-256 は Core の [`FileSHA256`](../app/MacAmbientJev/Sources/MacAmbientJevCore/FileSHA256.swift) が計算します。Foundation の FileHandle で1 MiB bounded chunk を読み、Swift が chunk 間の部分 block buffering、padding、digest の hex formatting を行います。各 chunk 内の連続する完全な64-byte block 群は1回の batch call で [`CSHA256.c`](../app/MacAmbientJev/Sources/CSHA256/CSHA256.c) に渡し、FIPS 180-4 SHA-256 compression（sections 4.1.2、4.2.2、6.2.2；[NIST FIPS 180-4](https://csrc.nist.gov/pubs/fips/180-4/upd1/final)）を実行します。処理は macOS・Linux・Windows に共通です。Silero VAD、Community-1、PortableRuntime の clause-tagger assets と `PortableAssetVerifier` は同じ実装を使います。各 caller の hash / size validation は全て実行し、validation skip、hash cache、fallback はありません。

自己 test は次のとおりです。

```bash
python3 -B scripts/test_fetch_community1_diarization.py
```

test は4ファイルの pin、既存の破損ファイルの拒否、中断したダウンロードからの復旧、再実行での再利用、空白・非 ASCII を含む path、script が Swift と同じ manifest ファイルを読む（複製がない）ことを検査します。ネットワークには接続せず、取得元は mock した小さな fixture です。attribution と license は [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md#community-1-話者分離モデル) にあります。

### 話者分離の計測 CLI

`MacAmbientJevDiarizeFile` は Linux / Windows で canonical CAF を `ONNXCommunity1DiarizationEngine` により話者分離し、run JSON を出力します。Windows のピークメモリは process memory counters のピーク working set です。Mac の oracle との比較手順は [testing.md](testing.md#話者分離-der-の計測) にあります。モデル directory には [Community-1 話者分離モデルの取得](#community-1-話者分離モデルの取得) の出力を渡します。

```powershell
swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevDiarizeFile
$binDir = (swift build --package-path app/MacAmbientJev -c release --show-bin-path)
& (Join-Path $binDir 'MacAmbientJevDiarizeFile.exe') --audio $caf --model-directory $models --threads 2 --output $run
```

### ONNX 話者分離 engine のモデルテスト

`ONNXCommunity1DiarizationEngine` と `Community1ONNXInference` の model テストは、fetcher が出力した directory を `MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY` に、`RUN_MODEL_TESTS` を `1` にして実行します。この環境変数に既定値はなく、未設定・空・相対 path・存在しない directory のときは skip せず失敗します。

```powershell
$env:RUN_MODEL_TESTS = '1'
$env:MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY = $models
swift test --package-path app/MacAmbientJev --jobs 4 --filter Community1ONNX
```

`--filter ONNXCommunity1DiarizationEngine` は model を使わない lifecycle の単体テストで、環境変数なしで実行できます。内容は [testing.md](testing.md#onnx-話者分離の-stage-テスト) を参照してください。

## 発話文タガー ONNX モデルの取得

ポータブル ONNX 発話文タガーは Hugging Face の [Pokojaka/modernbert-ja-30m-utterance-tagger](https://huggingface.co/Pokojaka/modernbert-ja-30m-utterance-tagger/tree/5c0213592cf8d59fc0b665183ab7536ddde05d1f) の commit `5c0213592cf8d59fc0b665183ab7536ddde05d1f` から取得します。model ID は Pokojaka/modernbert-ja-30m-utterance-tagger、model revision は `90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9` です。source commit と model revision は別の識別子で、後者は変更ありません。Swift と fetcher が共有する唯一の pin 情報源は [`clause_tagger_model.json`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/clause_tagger_model.json) です。この manifest が source repository・commit、model identity・tokenizer contract、ONNX の入出力 contract、および Core ML / ONNX 両形式の各ファイルについて remote path・local name・byte count・SHA-256 を記録します。各ファイルの取得 URL は `https://huggingface.co/Pokojaka/modernbert-ja-30m-utterance-tagger/resolve/<commit>/<path>` です。

tokenizer contract は SHA-256 `0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062`、`encodingRevision=1`、`unitPolicy=btsj-utterance-sentence`、`trainingStatus=trained` です。ONNX は opset 18、sequence length `2...192`、入力 `input_ids` int64 `[1,seq]`、出力 `boundary_probs` float32 `[1,seq,2]`、`span_probs` float32 `[1,seq,4]`、`priority_probs` float32 `[1,2]` の契約です。

| remote path | local name | byteCount | SHA-256 |
| --- | --- | ---: | --- |
| onnx/ClauseTagger.onnx | ClauseTagger.onnx | 146,889,562 | `1131898abd272f8bfb6e30828384e875971486cf9ba4f42f464f40b2f1119782` |
| onnx/tokenizer.json | tokenizer.json | 6,724,873 | `0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062` |
| onnx/export.json | export.json | 253,707 | `c62d12cba67447ba64c45d9e5471c65f69f0efebe9c2901852ec3ce8587c3a4a` |
| onnx/LICENSE.txt | LICENSE.txt | 1,292 | `2e97bfc46df586a08bb5942dc2af608d1aced6023735f65797d0ced0ba7fd77a` |
| LICENSE.md | LICENSE.md | 2,185 | `08b0eeee7efa0c43bcdefa95e64f0cf0e8f869eed4d01f3c5bcc2d99f112fb77` |

LICENSE.txt は base model の MIT license、LICENSE.md は名大会話コーパスで学習したモデルの CC BY-NC-ND 4.0 license です。アプリのコードは MIT license であり、モデルの license とは別です。license を含む pinned files は [Hugging Face repository](https://huggingface.co/Pokojaka/modernbert-ja-30m-utterance-tagger/tree/5c0213592cf8d59fc0b665183ab7536ddde05d1f) にあります。

[`fetch_clause_tagger.py`](../scripts/fetch_clause_tagger.py) は Python 3.12 以上の標準ライブラリと [`pinned_download.py`](../scripts/pinned_download.py) を使います。ONNX 形式の各実行で、manifest に固定された Hugging Face URL から5ファイルを取得し、byte count と SHA-256 を検証します。認証 token、retry、fallback は使いません。保存先は `.build/clause-tagger-onnx/5c0213592cf8d59fc0b665183ab7536ddde05d1f/clause-tagger-onnx` です。各ファイルを保存先の sibling `.fetch-*` staging directory に取得し、5つの通常ファイルだけからなる正確な tree と pin を検証してから `os.replace` で原子的に公開します。既存 cache は network access なしで全ファイルと tree を再検証し、有効ならそのまま返します。不正な cache は error となり、修復・上書き・再取得はしません。捕捉した失敗時は fetcher 自身の staging directory だけを削除し、他の staging directory は削除しません。成功時の stdout は検証済み directory の絶対 path 1行だけです。

```bash
CLAUSE_TAGGER="$(python3 scripts/fetch_clause_tagger.py --format onnx)"
```

```powershell
$clauseTaggerLines = @(python scripts/fetch_clause_tagger.py --format onnx)
if ($LASTEXITCODE -ne 0) { throw 'Clause tagger fetch failed: python scripts/fetch_clause_tagger.py --format onnx' }
if ($clauseTaggerLines.Count -ne 1) { throw 'Clause tagger fetch must return exactly one output line' }
$clauseTagger = [string]$clauseTaggerLines[0]
```

`--format coreml` は `.build/clause-tagger/5c0213592cf8d59fc0b665183ab7536ddde05d1f/clause-tagger` に Core ML 形式を取得します。Mac の [`build_app.sh`](../scripts/build_app.sh) はこの形式を取得し、アプリ bundle に同梱します。

Swift 側の PortableRuntime `ClauseTaggerAssets(modelDirectory:)` は、caller が指定した絶対 path の既存 directory で5ファイルすべて（LICENSE.md を含む）の通常ファイル型・byte count・SHA-256 を、他の処理より先に検証します。欠落・サイズ違い・hash 違い・通常ファイルでないものは、ファイル名、期待値と実際の値、`python3 scripts/fetch_clause_tagger.py --format onnx` を含む error で失敗し、修復や代替 path はありません。成功すると ONNX model URL、tokenizer URL、manifest 由来の `ClauseTaggerModelIdentity`（model ID、model revision、tokenizer SHA-256）を公開します。実モデルを使う test は `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` で明示された directory を使います。runtime の環境変数による path 注入に変更はなく、既定値はありません。未設定・相対 path・存在しない directory は skip せず失敗します。

自己 test は次のとおりです。

```bash
python3 -B scripts/test_fetch_clause_tagger.py
```

fetcher の test は単一 manifest、両形式の pin と URL、不正な manifest、完全な tree の公開、有効な既存 cache の再利用（network access なし）、破損・不足・余分・symlink の既存 cache の拒否、取得・hash・byte count 不一致時の retry なしと staging cleanup を検査します。test は network に接続せず、小さな合成データを使います。Swift の [ClauseTaggerAssetsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ClauseTaggerAssetsTests.swift) は PortableRuntime の test target（Linux / Windows）で、manifest の pin と、小さな stand-in の一時 directory による欠落・サイズ違い・hash 違い・directory・相対 path の拒否を、実モデルなしで検査します。

## ビルドと検証

Linux / Windows では Core のみの作業を含むすべての `swift build` の前に、リポジトリルートで ONNX Runtime fetch が必要です（Linux: `python3 scripts/fetch_onnxruntime.py`、Windows: `python scripts/fetch_onnxruntime.py`）。Python 3.12 以上を使います。Silero model fetch は build には不要で、`swift test` に必要です。テスト前に `fetch_silero_vad.py` の出力を `MAC_AMBIENT_JEV_SILERO_MODEL` に、`fetch_qwen3_asr_tokenizer.py` の出力を `MAC_AMBIENT_JEV_QWEN3_TOKENIZER` に、`fetch_clause_tagger.py --format onnx` の出力（検証済み directory）を `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` に設定します。

Swift 6.2 の Windows toolchain、対応する Visual Studio の C++ Build Tools と Windows SDK、Python 3.12 以上を用意し、リポジトリルートから実行します。全 check、ONNX Runtime SDK 取得、全適用 target の build、DLL 配置、全 test を行うコマンドは次のとおりです。

```powershell
./scripts/test-windows.ps1
```

各段階の失敗で非 0 終了します。runner は ONNX Runtime SDK / Silero model / Qwen3-ASR tokenizer / clause tagger fetch の stdout を UTF-8 として受け取り、終了コードと単一行出力を確認します。ONNX Runtime root は絶対 path の既存 directory として検証します。Silero path は fetcher が絶対 path と通常 file を検証し、runner は再検証しません。Silero path を test 専用 `MAC_AMBIENT_JEV_SILERO_MODEL` に、clause tagger の directory を test 必須の `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` に設定し、ONNX Runtime SDK root の lib/onnxruntime.dll を Swift の実行 bin directory へコピーします。Silero fetcher、Qwen3-ASR tokenizer fetcher、pinned download helper、Silero reference generator、Qwen3-ASR token reference generator の各 self-test も実行します。token reference generator の self-test は依存 package や model weights を必要としません。Qwen3-ASR tokenizer の path は test 専用 `MAC_AMBIENT_JEV_QWEN3_TOKENIZER` に設定します。full model weights は自動取得せず、full model inference は既定では実行しません。手動で同じ build / test を行う場合は、次のように取得し、build 後に Swift の実行 bin directory へ DLL を配置してから `swift test` を実行します。

```powershell
$env:PYTHONIOENCODING = 'utf-8'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$runtimeRoot = python scripts/fetch_onnxruntime.py
if ($LASTEXITCODE -ne 0) { throw 'ONNX Runtime fetch failed' }
python -B scripts/check_portable_core.py
python scripts/check_doc_references.py
python -B scripts/test_fetch_onnxruntime.py
$sileroModelPathLines = @(python scripts/fetch_silero_vad.py)
if ($LASTEXITCODE -ne 0) { throw 'Silero VAD fetch failed' }
if ($sileroModelPathLines.Count -ne 1) { throw 'Silero VAD fetch must return exactly one output line' }
$env:MAC_AMBIENT_JEV_SILERO_MODEL = [string]$sileroModelPathLines[0]
$qwen3TokenizerPathLines = @(python scripts/fetch_qwen3_asr_tokenizer.py)
if ($LASTEXITCODE -ne 0) { throw 'Qwen3-ASR tokenizer fetch failed' }
if ($qwen3TokenizerPathLines.Count -ne 1) { throw 'Qwen3-ASR tokenizer fetch must return exactly one output line' }
$env:MAC_AMBIENT_JEV_QWEN3_TOKENIZER = [string]$qwen3TokenizerPathLines[0]
$clauseTaggerPathLines = @(python scripts/fetch_clause_tagger.py --format onnx)
if ($LASTEXITCODE -ne 0) { throw 'Clause tagger fetch failed' }
if ($clauseTaggerPathLines.Count -ne 1) { throw 'Clause tagger fetch must return exactly one output line' }
$env:MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY = [string]$clauseTaggerPathLines[0]
python -B scripts/test_fetch_silero_vad.py
if ($LASTEXITCODE -ne 0) { throw 'Silero VAD fetcher self-test failed' }
python -B scripts/test_fetch_community1_diarization.py
if ($LASTEXITCODE -ne 0) { throw 'Community-1 diarization fetcher self-test failed' }
python -B scripts/test_fetch_clause_tagger.py
if ($LASTEXITCODE -ne 0) { throw 'Clause tagger fetcher self-test failed' }
python -B scripts/test_fetch_qwen3_asr_tokenizer.py
if ($LASTEXITCODE -ne 0) { throw 'Qwen3-ASR tokenizer fetcher self-test failed' }
python -B scripts/test_pinned_download.py
if ($LASTEXITCODE -ne 0) { throw 'Pinned download helper self-test failed' }
python -B scripts/test_generate_silero_reference.py
if ($LASTEXITCODE -ne 0) { throw 'Silero reference generator self-test failed' }
python -B scripts/test_generate_qwen3_asr_token_reference.py
if ($LASTEXITCODE -ne 0) { throw 'Qwen3-ASR token reference generator self-test failed' }
swift build --package-path app/MacAmbientJev
$binDir = (swift build --show-bin-path --package-path app/MacAmbientJev).Trim()
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'lib/onnxruntime.dll') -Destination (Join-Path $binDir 'onnxruntime.dll') -Force
swift test --package-path app/MacAmbientJev
```

`swift test` は DLL を Swift の実行 bin directory に置いた後に実行します。

ARM64 の Windows 11 では、管理者の PowerShell で [setup-winvm.ps1](../scripts/setup-winvm.ps1) を 1 回実行すると、
Visual Studio 2022 Build Tools（MSVC と Windows SDK 26100）、Swift 6.2、Python 3.12 を入れ、
symlink の作成に必要な開発者モードを有効にします。実行後はサインインし直してから検証します。

Core の FLAC テストは codec の round-trip と破損データの拒否を検証します。参照用 `flac` CLI との比較は `PATH` から実行ファイルを解決できる場合だけ実行し、見つからない場合は Swift Testing の `enabled` trait で無効になります。`flac` はテスト専用で、実行時依存ではありません。詳細は [RecordingFLACEncoderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/RecordingFLACEncoderTests.swift) と [FLACTimelineReaderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACTimelineReaderTests.swift) を参照してください。

Windows の `swift build` は Core、Pipeline、CWindowsSession、CMiniaudio、CWindowsAudio、WindowsSupport、`CONNXRuntime`、MacAmbientJevONNX、PortableRuntime と既存評価 CLI 3 本、file transcription CLI 1 本を build します。`swift test` は Core、Pipeline、WindowsSupport、ONNX、PortableRuntime、TranscribeFile の各 test target を filter 指定なしで実行します。WindowsSupport の音声 fixture と ONNX fixture（Silero speech / reference fixture を含む）も各 test target に含まれます。これは [`test-windows.ps1`](../scripts/test-windows.ps1) と [portable CI](../.github/workflows/portable-core.yml) の実行内容です。ONNX Runtime の Windows DLL はテスト実行 bin directory に配置し、Silero model を test 用に取得します。macOS 専用 framework や Mac 用モデルは取得しません。
評価 CLI の参照文・artifact の形式と file CLI の evaluation artifact / model test は [linux.md](linux.md) を参照してください。
参照文のファイル指定は相対パスと Windows の絶対パスを扱います。

[portable-core.yml](../.github/workflows/portable-core.yml) は、共通 Core / Pipeline、Windows 音声関連ソースとテスト、ONNX source / tests / fixture、file transcription CLI の source / tests、fixture 生成スクリプト、Silero fetch / fixture script の変更を含む main への push とレビュー可能な pull request で、Linux と Windows の build/test を実行します。
Linux は CMiniaudio、Core、Pipeline、`CONNXRuntime`、MacAmbientJevONNX、PortableRuntime と既存評価 CLI 3 本、file transcription CLI 1 本を build し、Core、Pipeline、ONNX、PortableRuntime、TranscribeFile の tests を実行します。workflow は ONNX Runtime SDK、Silero model、Qwen3-ASR tokenizer をそれぞれ fetch し、検証した path を `MAC_AMBIENT_JEV_SILERO_MODEL` と `MAC_AMBIENT_JEV_QWEN3_TOKENIZER` として `GITHUB_ENV` に書き込みます。ONNX Runtime / Silero / Qwen3-ASR tokenizer fetcher、pinned download helper、Silero reference generator の各 self-test、`check_portable_core.py`、`test_compare_diarization_runs.py`、`test_prepare_canonical_caf.py`、`check_doc_references.py` は check step で実行し、`swift build` と `swift test` はそれぞれ別 step で実行します。Linux workflow は `verify_portable.sh` を実行しません。ローカルの [verify_portable.sh](../scripts/verify_portable.sh) は別の実行手順で、ONNX Runtime SDK、Silero model、Qwen3-ASR tokenizer を fetch し、path を環境変数に設定したうえで Silero fetcher、Qwen3-ASR tokenizer fetcher、pinned download helper、Silero と Qwen3-ASR token reference generator の依存 package・model weights 不要な self-test、portable checker、SwiftPM manifest check、build、test を実行します。full model inference は既定では実行しません。
Windows は Core、Pipeline、CWindowsSession、CMiniaudio、CWindowsAudio、WindowsSupport、`CONNXRuntime`、MacAmbientJevONNX、PortableRuntime と既存評価 CLI 3 本、file transcription CLI 1 本を build し、Core、Pipeline、WindowsSupport、ONNX、PortableRuntime、TranscribeFile の tests を実行します。Windows CI は [test-windows.ps1](../scripts/test-windows.ps1) が ONNX Runtime SDK、Silero model、Qwen3-ASR tokenizer の fetch、各 check、ONNX Runtime / Silero / Qwen3-ASR tokenizer fetcher、pinned download helper、Silero reference generator と Qwen3-ASR token reference generator、diarization run 比較、canonical CAF 変換の各 self-test、Package の全適用 target の `swift build`、DLL 配置、全適用 test target の `swift test` を行います。
Draft PR では portable と macOS の CI を起動せず、作業中の Linux 検証はローカルにまとめます。
手動実行は Windows のみが既定で、run_linux を有効にすると Linux も実行します。
同じブランチ・PR の古い実行は自動で取り消します。Windows のテストには symlink の作成権限が必要です。
macOS の app bundle と録音・GUI の検証は [ci.yml](../.github/workflows/ci.yml) と Mac で行います。

## 保存先と境界

既定の保存先は SHGetKnownFolderPath で取得する LocalAppData 配下です。
取得に失敗した場合はエラーにし、環境変数や macOS のパスで補いません。
セッションは LocalAppData/mac-ambient-jev/sessions、モデルは同じアプリ root の models、
キャッシュは LocalAppData/Caches/mac-ambient-jev に置きます。
LocalAppData はシステムの既知フォルダーであり、これらは生成される保存先です。

SessionFileAccess は Windows 専用の CWindowsSession を使います。
明示された root を CreateFileW の FILE_FLAG_OPEN_REPARSE_POINT 付きで開き、
子要素は固定した親 handle を基点に NtCreateFile で開きます。
reparse point（symlink、junction を含む）、通常ファイルでない末尾、境界外パスは拒否します。
親が途中で改名されても、検査後に絶対パスから開き直すことはありません。

一時ファイルは同じ親 handle 配下に排他的に作り、FlushFileBuffers 後、
NtSetInformationFile の FileRenameInformationEx（FILE_RENAME_POSIX_SEMANTICS と
FILE_RENAME_REPLACE_IF_EXISTS）で開いた一時ファイル自身を原子的に公開します。
エディタやバックアップソフトなど別のプロセスが公開先を FILE_SHARE_DELETE 付きで開いていても置換できます。
FILE_SHARE_DELETE なしで開かれている場合や、POSIX semantics の改名に対応しないファイルシステムでは
エラーを返し、非 POSIX の改名へ切り替えません。
公開先も固定したディレクトリ handle で指定し、公開後にディレクトリを同期します。
MoveFileExW のパスを再解決する方式は使いません。同期・原子置換をファイルシステムが拒否した場合は
エラーを返し、通常のコピーや未同期の保存へ切り替えません。
ファイルとディレクトリの同期には書き込み権限が必要です。
読み取り・列挙・サイズ取得・ログの durable read はディレクトリの書き込み権限を要求しません。
root の Win32 パスは明示的な長いパス形式で開き、MAX_PATH を超える保存先も同じ境界検査を使います。
CWindowsSession が開く handle は継承不可です（CreateFileW に SECURITY_ATTRIBUTES を渡さず、NtCreateFile に OBJ_INHERIT を付けません）。
子プロセスが一時ファイルの handle を持ち続けて公開の改名を妨げることはありません。

Windows で実行するテストは、fixture の書き込みに Foundation の `Data.write(to:options: .atomic)` を使いません。
Swift 6.2 の Foundation は `.atomic` の一時ファイルを MSVC 170 UCRT の継承可能な CRT handle（[`_wsopen_s`](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/sopen-wsopen?view=msvc-170)、`FILE_SHARE_DELETE` なし）で開き、閉じた直後に MoveFileExW で改名します（[Data+Writing.swift](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift)）。
同じテストプロセスで `Process.run()` が並行すると、CreateProcessW の `bInheritHandles` が TRUE のため子プロセスがその handle を継承し（[Process.swift](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.2-RELEASE/Sources/Foundation/Process.swift)）、改名が ERROR_SHARING_VIOLATION（32）になり、NSCocoaErrorDomain Code=513 で失敗します。
`.atomic` を付けない `Data.write(to:)` は継承不可の CreateFileW handle を使うため、この競合は起きません。

イベントログの追記と durable read は LockFileEx で全範囲を排他ロックし、
handle を閉じるまで保持します。復旧の途中で破損した末尾を読むことを防ぎ、
複数 writer が同じイベント番号を発行しません。

セッション名と PCM chunk 名には Windows と POSIX に共通の名前規則を適用します。
詳細は [storage.md](storage.md) を参照してください。

PCM chunk 一覧は大文字に変換した名前でも一意である必要があります。
大小文字を区別しないファイルシステムで同じ音声を二重に数える索引を拒否します。

## エンジン設定とアプリケーション root lock

`MacAmbientJevEngineHost` の `EngineSettingsStore` は、アプリ root（`AppPaths.root`）直下の settings.json を読み書きします。パスは `AppPaths` だけから決め、環境変数や追加のパス計算を使いません。
ファイルは `{"revision":"<EngineID>","settings":{…}}` の 1 object で、プロトコルの `EngineSettingsResult`（`settings` は `EngineSettings`）をそのまま使い、別のスキーマはありません。`schema_version` は 1 だけを受け付け、未知のフィールド、重複キー、欠落フィールド、型違いは読み込み時に拒否します。`threads` は `1...min(4, logicalCPUCount)` で、`logicalCPUCount` は呼び出し側が明示的に渡します。
`load()` は次の結果になります。

| ファイルの状態 | 結果 |
|---|---|
| なし | `EngineSettingsError.required`（`settings_required`、復旧は `replace_settings`）。何も作りません |
| 読めて有効 | revision 付きの設定 |
| 不正（JSON、スキーマ、threads の上限超過） | `EngineSettingsError.corrupt`（`invalid_settings`）。既定値、移行、部分的な読み込みはありません |
| symlink、通常ファイルでない、I/O エラー | `EngineSettingsError.filesystem` |

`replace(expectedRevision:settings:)` は設定を検証し、現在の revision が `expectedRevision` と一致するときだけ revision を 1 進めて保存します。ファイルがないときの `expectedRevision` は `nil` だけです。不一致は `staleRevision` で、書き込みません。不正なファイルは `expectedRevision == nil` の全体置換だけが修復し、revision は 1 から始まります。保存は `SessionFileAccess.writeAtomically`（固定した親 handle、同期後の原子的な公開、ディレクトリ同期）です。`load` と `replace` の直列化は engine controller が行います。

`ApplicationRootLock.acquire(paths:)` はアプリ root を作成し、`engine.lock` を開いて排他 lock を取ります。2 つ目の engine は `alreadyRunning` で失敗します。lock は開いたファイルに属し、プロセスが終了すると OS が解放します。macOS / Linux は flock（LOCK_EX と LOCK_NB）、Windows は [LockFileEx](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex)（LOCKFILE_EXCLUSIVE_LOCK と LOCKFILE_FAIL_IMMEDIATELY）で、ERROR_LOCK_VIOLATION が `alreadyRunning` になります。Windows の lock tests は同一プロセス内の 2 つ目の lock と、別プロセスの 2 つ目の engine を対象にします。

## インストール済みモデルの検証と読み込み

`models.prepare` は `PortableModelPreparationService.prepare(configuration:onProgress:)` で実装します。ダウンロード、代替モデル、モデルや decisions の自動無効化はありません。
モデルはアプリ root の models 配下に次の配置で置きます。名前は同梱の pin とマニフェストから `PortableInstalledModelLayout` が作ります。

| モデル | 配置 |
|---|---|
| Silero VAD | `silero/<commit>/silero_vad_16k_op15.onnx` |
| Qwen3-ASR | `qwen3-asr-<0.6b\|1.7b>-int4-<commit>/`（`fetch_qwen3_asr_model.py <size> <models root>` が作るディレクトリ） |
| Community-1 | `community1/<同梱マニフェスト bytes の SHA-256>/` |
| 発話文タガー | clause-tagger/5c0213592cf8d59fc0b665183ab7536ddde05d1f/clause-tagger-onnx/（`models.prepare` は decisions 有効時のみ検証・load。`models.inspect` は decisions 設定にかかわらず常に検証） |

`PortableProcessingConfiguration.installed(layout:qwen3Size:threads:logicalCPUCount:withDecisions:)` は設定から型付きの configuration を作ります。threads の検証は `resolve` と同じ関数を使い、パスの存在は確認しません。

`prepare` は全モデルを検証してから、全モデルを読み込みます。VAD、ASR、diarization、（decisions 有効時）タガーの順です。検証は存在、通常ファイル、サイズ、streaming SHA-256 を見ます（Silero はサイズの pin がなく SHA-256 のみ）。読み込みは Silero の ONNX session、`ONNXQwen3ASREngine.prepare()`、`ONNXCommunity1DiarizationEngine.prepare()`、`ONNXClauseTagger` の生成で、認識や decisions のリクエストは作りません。読み込んだモデルは次のモデルの前に解放するため、`prepare` は後続の処理が使う engine を温めず、読み込めることの確認だけを行います。
進捗は `PortableModelPreparationProgress`（`stage` は `validating` / `loading`、`model`、`completed`、`total`）です。各モデルの開始時に `completed` = 完了済みの数で通知し、各 stage の最後に `model == nil`、`completed == total` を通知します。単位はモデル数で、1 ファイル内の byte 進捗はありません。
失敗は `PortableModelPreparationError` です。`missing` と `invalid` は期待するパスと配置手順（fetch コマンド）を含み、`loadFailed` はモデルとパスを含みます。ホストは `missing` を `model_missing`、`invalid` を `model_corrupt`、`loadFailed` を `model_failure` に対応させ、復旧は `prepare_models` です。

## エンジンの NDJSON transport とコマンド dispatcher

`MacAmbientJevEngineHost` は、プロトコル（`MacAmbientJevEngineProtocol`）の codec の上に、stdin/stdout の有界 transport と main actor の dispatcher を実装します。どちらも Foundation とプロトコル module だけに依存し、macOS と Linux で build と test が通ります。実装は [`EngineTransport.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineTransport.swift)、[`EngineTransportOutput.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineTransportOutput.swift)、[`EngineTransportIO.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineTransportIO.swift)、[`EngineTransportLimits.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineTransportLimits.swift)、[`EngineController.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineController.swift)、[`EngineHandlers.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineHandlers.swift) です。テストは [`EngineTransportInputTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineTransportInputTests.swift)、[`EngineTransportOutputTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineTransportOutputTests.swift)、[`EngineTransportPipeTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineTransportPipeTests.swift)、[`EngineControllerTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineControllerTests.swift)、[`EngineSettingsStoreHandlerTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineSettingsStoreHandlerTests.swift) です。プロセスを起動せず、スクリプト化した source / sink と実際の POSIX pipe で検証します（POSIX pipe のテストは Windows では build せず、Windows の pipe は `MacAmbientJevEngineTests` が検証します）。

### 入力 lane

`EngineTransport` は専用 thread で `EngineByteSource` から生の bytes を読み、`EngineLineFramer` に渡します。テキスト変換や code page は使いません。`FileHandleByteSource` は OS の read を 1 回ずつ呼び（POSIX は `read`、Windows は ReadFile。pipe の終端 `ERROR_BROKEN_PIPE` は EOF）、record の一部が届いた時点で返します。Windows の executable は ReadFile の取り消しに対応した `WindowsPipeByteSource` を使います（下記）。
chunk は LF ごとに framer へ渡すため、不正な行の前に完成した record は失われず、先に `line` として届きます。framer が失敗した時点で入力 lane は止まります。
controller に渡したが `lineHandled()` が呼ばれていない行は最大 32 件で、超えると入力 lane が読み取りを止め、pipe の backpressure になります。

`EngineTransport.events` は次の event を 1 つの consumer に渡します。

| event | 意味 |
|---|---|
| `line` | delimiter を除いた、字句検査済みの 1 record |
| `endOfInput` | record の境界での EOF |
| `protocolViolation` | framing / 字句違反。最後の行が LF で終わらない EOF は `partialFinalLine` |
| `readFailed` | 入力の read エラー |
| `writeFailed` | 出力 writer の失敗（下記） |

### 出力 writer

stdout へ書くのは専用の writer thread 1 つだけです。record を 1 件ずつ、部分書き込みを繰り返して LF まで書きます。診断は stderr にだけ出し、stdout には NDJSON の record 以外を一切書きません。`sequence` は enqueue 時に 1 から連番で付けます。encode に失敗した record は番号を消費しません。

出力待ち行列は最大 128 record / 8 MiB（`EngineTransportLimits.production`）です。そのうち 32 record / 2 MiB は `accepted`、`completed`、`error`、`ready` のために空けておき、置き換え可能な event は残りだけを使います。

| event | 扱い |
|---|---|
| `ready`、`accepted`、`completed`、`error` | 結合も破棄もしません。待ち行列が満杯なら送信側が writer の空きを待ちます |
| `state` | 待ち行列に 1 件だけ残し、新しいものが古いものを置き換えます |
| `progress` | session とステージごとに置き換えます。枠が足りないときは最も古い `progress` を捨てます |
| `rows` | 枠が足りないとき、その session の待ち行列上の `rows` を 1 件の `reload_required`（最新の revision）にまとめます。完全な変更列を装いません |

置き換え可能な event の枠に収まらず、結合できる古い event もないときは `replaceableOverflow` を呼び出し元に返します（黙って捨てません）。

出力が失敗すると、writer は最初の失敗だけを記録し、ブロック中の write を cancel し、sink を閉じ、`writeFailed` を通知します。失敗は次の 3 種類です。

| 失敗 | 条件 |
|---|---|
| `deadlineExceeded` | 書き込み中に 1 byte も進まない状態が 5 秒続いた（部分書き込みが進めば deadline は延びる） |
| `brokenPipe` | 読み手が閉じた |
| `failed` | その他の write エラー |

ブロック中の write を止める OS 固有の処理は `EngineByteSink` が持ちます。`cancelBlockedWrite()` は別 thread から呼ばれ、実行中の `write` を `cancelled` で戻らせます。移植可能な既定の `PosixByteSink` は、`poll` を短い間隔で繰り返し、`PIPE_BUF` 以下ずつ書くことで、満杯の pipe を flag で止められるようにします（fd の状態 flag は変えず、SIGPIPE は process 全体で無視して `brokenPipe` にします）。Windows の executable は WriteFile と [CancelSynchronousIo](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelsynchronousio) を使う sink を渡します。

### dispatcher

`EngineController`（`@MainActor`）が `run()` で transport を開始し、`ready` を送ってから `events` を処理します。

- 最初の request は `hello` で `request_id` は `1` です。以後は厳密に増加します（`EngineRequestOrder`）。違反は `hello_required` / `invalid_request_id` / `invalid_request`（2 回目の `hello`）の `error` 1 件で拒否します。このとき `accepted` は送らず、副作用もありません。順序を満たした request の id は、あとで `busy` になっても high-water mark に含まれます。
- request を解釈できない場合（未知の command、未知の field など）は、字句検査に通る行から信頼できる `request_id` を取り出せるときだけそれを付け、`invalid_request` の `error` を返して接続を続けます。framing / 字句違反（重複 key、不正 JSON など）と `unsupported_version` は `error`（`fatal`）を送ったあと、接続を終了します。
- 受理した request は同時に最大 16 件です。`recording.stop` と `shutdown` 用に 2 件を予約し、それ以外の command は 14 件までで、超えると `busy` の `error` 1 件で拒否します（`EngineAdmissionLimits.production`）。
- 受理すると `accepted` を送り、handler を main actor 上の task で実行し、`completed` か `error` のどちらか 1 件だけを送ります。handler が投げた `EngineCommandError` はそのまま、Swift の取り消しエラーは `cancelled`、それ以外は `internal_error`（元のエラーを detail に保持）です。`shutdown` は dispatcher が直接処理します。
- handler は `EngineStateHandling`、`EngineRecordingHandling`、`EngineSessionHandling`、`EngineTranscriptHandling`、`EngineSettingsHandling`、`EngineModelsHandling`、`EngineShutdownHandling` の protocol で注入します。実際の実装は Windows の composition 層が組み立てます。`EngineSettingsStoreHandler` は `settings.get` / `settings.replace` を `EngineSettingsStore` につなぐ実装で、実行中の作業と衝突する置換は呼び出し側が渡す条件で `busy` として拒否します。
- handler は `EngineRequestContext` の `EngineEventEmitter` で、request に紐づく `progress` や、request を持たない `state` / `rows` / background の `error` を送ります。

### 終了

`run()` は終了理由 `EngineExit` を返し、`processExitCode` が process の終了コードです。

| 理由 | `shutdown` handler の reason | コード |
|---|---|---|
| `shutdown` request の完了 | `requested` | 0 |
| EOF（record の境界） | `inputClosed` | 0 |
| framing / プロトコル違反、最後の行が LF で終わらない EOF | `protocolError` | 3 |
| 入力の read エラー | `inputFailed` | 4 |
| 出力の失敗（deadline、broken pipe） | `outputFailed` | 5 |
| `shutdown` handler の失敗 | なし | 6 |
| successful device reconnect timeout（durable stop と finalization enqueue 後、engine は command を継続） | EngineExit なし | process は終了しない（7 ではない） |
| fatal capture / writer failure（durable stop 後） | `captureFailed` | 7 |
| `ready` の準備に失敗 | なし | 2 |

終了時は `shutdown` handler を 1 回呼び、capture の durable な停止と推論の安全な取り消しを任せます。`ready` の準備に失敗した場合も `EngineProcess` が safe shutdown を先に実行します。その後、終端を受け取っていない受理済み request には `cancelled` の `error` を送ります。出力が失敗した場合は何も書かず、`shutdown` handler の実行後すぐ終了します。それ以外は待ち行列を書き切ってから transport を閉じます。startup maintenance は shutdown pause で cancel され、process は startup task の完了を待って root lock を保持します。
`device_lost` の30秒 reconnect timeout は成功した自動停止として扱い、durable stop と通常の finalization enqueue の後に warning `error` event を unsolicited で送り、engine は引き続き command を処理します。これは `captureFailed` / exit code 7 ではありません。writer failure とその他の fatal capture failure は fatal capture failure 経路で扱い、durable stop を待ち、録音を次回起動の pending recovery に残し、auto finalization を続けず、出力可能なら unsolicited fatal error を送って exit code 7 で終了します。
EOF は client が消えたときの安全な切断として扱い、終了コードは通常 0 です（shutdown handler の失敗は exit code 6）。dispatcher は shutdown handler の完了を待ち、native inference を強制 preempt しません。shutdown handler 完了後、終端結果をまだ持たない他の受理済み request は `cancelled` として終了します。


## エンジンの composition、起動時復旧と実行ファイル

### composition

`EngineApplication`（`MacAmbientJevEngineHost`）が `EngineController` の handler 全部を実装します。1 つの `@MainActor` 型が録音 lifecycle、処理 queue と claim、設定、選択中 transcript、request の完了待ちを持ち、Mac の `AppState` と同じ共有部品を使います。録音開始は `RecordingStartCoordinator`、停止は `LiveTranscriptionCoordinator.finishRecording`、確定・再処理・判定の再試行は `SessionProcessingCoordinator`、取り込みは `RetainedSessionImporter`、書き出しは `SessionExporter`、transcript の行は Mac の画面と `transcript.txt` が共有する `LiveTranscriptProjection` です。

capture と推論は注入します。`EngineCaptureProviding`（Windows は `WindowsEngineCapture`、`WindowsCaptureSource` と WASAPI、`WindowsCaptureDiskSpaceProvider`、`WindowsRecordingPowerProvider` を使う）と `EngineInferenceProviding`（Windows は `PortableEngineInference`、`PortableModelPreparationService` と `PortableSessionEngineBundle` を使う）です。テストは fake を注入します。processing と live の coordinator は `EngineProcessorGateway` 経由で現在の `NativeSessionProcessor` に委譲するため、設定のモデル profile が変わると processor だけを作り直せます。processor がないとき（モデル未準備）は処理が `models.prepare` を促すエラーで失敗し、代替では動きません。

### Windows WASAPI capture と device reconnect

[`WindowsWASAPICaptureFactory`](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/WindowsWASAPICaptureFactory.swift) と [`WindowsCaptureSource`](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/WindowsCaptureSource.swift) は vendored miniaudio 0.11.23 を使います。microphone と loopback の両方で `performanceProfile = ma_performance_profile_conservative`、`periodSizeInMilliseconds = 100`、`periodSizeInFrames = 0`、`periods = 3`、`wasapi.usage = ma_wasapi_usage_pro_audio`、`noAutoStreamRouting = true` を要求し、MMCSS task profile に `Pro Audio` を指定します（[miniaudio 0.11.23 header](https://raw.githubusercontent.com/mackron/miniaudio/0.11.23/miniaudio.h)、[changes](https://raw.githubusercontent.com/mackron/miniaudio/0.11.23/CHANGES.md)）。period 値は backend への要求 / hint であり、実際の period / frame 数は異なる場合があります。特定の hardware period が保証されるとは主張しません。

入力 ring は512 source-frame fragment 単位で、requested period hint を使った slot capacity は `ceil(ceil(rate × 0.1) / 512) × 3 × ceil(10 / (0.1 × 3))`（`rate` は source frames/second）です。これにより既存の10秒以上の buffered audio capacity を保ちます。

Pure reconnect policy は Pipeline の [`CaptureDeviceReconnect`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/CaptureDeviceReconnect.swift)、Windows glue は WindowsSupport の `WindowsCaptureSource` が担い、sleep-inclusive QPC clock と device factory を注入します。状態は `capturing` → `waiting`（初回 loss から不変の30秒 deadline）→ `capturing` または `stopping` / `device_lost` です。normal resume は `waiting_for_device` から同じ session の `recording` へ直接戻り、timeout は `waiting_for_device` から `stopping` へ直接進むため、timeout 中に一瞬 `recording` にはなりません。再度 loss が起きたり endpoint が unavailable の retry 中でも deadline は reset しません。microphone の default 選択は開始時に解決した endpoint ID に pin し、explicit microphone と explicit loopback は同じ ID だけを再 open します。default loopback だけは新 default output を追います。

30秒 reconnect deadline は既存の注入可能な `qpc100ns`（QueryPerformanceCounter）で測り、health monitor の uptime とは独立させます。Microsoft の [high-resolution timestamp guidance § Resolution, precision, accuracy, and stability](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps#resolution-precision-accuracy-and-stability) は、QPC について “QueryPerformanceCounter reads the performance counter and returns the total number of ticks that have occurred since the Windows operating system was started, including the time when the machine was in a sleep state such as standby, hibernate, or connected standby.” と明記しています。したがって QPC elapsed time は sleep / hibernate / connected standby 中も含み、sleep 中に pause するとは扱いません。対照的に [QueryInterruptTime](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-queryinterrupttime) は Windows 10 以降で利用できる100-ns単位の biased interrupt time、[Interrupt Time](https://learn.microsoft.com/en-us/windows/win32/sysinfo/interrupt-time) の biased 値も sleep 時間を含みます。[QueryUnbiasedInterruptTime](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-queryunbiasedinterrupttime) は sleep 時間を除外します。期限は `min(observedLossQPC + 30 seconds, lastCapturedEndQPC + 30 seconds)` で、loss 観測が sleep 後に遅れても長時間の placeholder を許しません。期限を過ぎた最初の control tick は device を enumerate / reopen せず `deviceLost` 停止へ進み、sleep の長さに応じて数時間の gap を作ることはありません。ただし期限前に有効な first-buffer evidence をすでに受信していれば、control tick が遅れてもその証拠を保持して復帰を完了できます。期限後の first packet は破棄し、open 前・start 前・start 後にも期限を再確認します。reconnect gap は30秒を超えません。

native device loss だけが `waiting_for_device` の固定30秒待機を開始します。再 open ごとに新しい segment / converter を作り、device の sample rate / channel 数が変わっても同じ writer と recording session に接続します。`waiting_for_device` 中は native operational open / start error（vendored miniaudio 0.11.23 の `MA_NO_DEVICE`、`MA_UNAVAILABLE`、`MA_FAILED_TO_OPEN_BACKEND_DEVICE = -401` を含む）、factory enumeration error、endpoint-list validation error、および各候補の first buffer 前の worker stall / active-output stall / suspended / native failure を候補失敗として fence し、同じ初回 deadline まで0.25秒間隔で再試行します。native operational error は実際の operation 名 `mja_capture_open` / `mja_capture_start` と code を伴い、再試行するかは Swift の `waiting_for_device` state が決めます。各候補の3秒 first-buffer deadline は有効な first-buffer evidence でのみ満たされ、healthy heartbeat だけでは延長も満了回避もできません。破棄する再試行候補の packet / error は writer に書かず、gap も作りません。この待機中だけの retry は初回 start と通常の `recording` の error 判定を変えず、それらの native failure は fatal のままです。factory enumeration / endpoint-list validation error も `waiting_for_device` の再 open 時だけ retry 対象となり、それ以外の configuration validation failure は fatal です。invalid packet、timestamp validation failure、cleanup error、writer error も fatal です。有効な first-buffer evidence を期限内に受信した後で native `start` が throw した場合も fatal です。その候補で buffer された gap と PCM は terminal cleanup より前に writer へ書き込み、waiting gap は閉じたものとして扱います。cleanup はその timeline を保ち、古い waiting tail の gap を追加しません。native failure diagnostic には実際の operation 名と code を含めます。WASAPI packet-read extension は raw invalidated HRESULT を保持します（[WindowsCapture.inc](../app/MacAmbientJev/Sources/CMiniaudio/WindowsCapture.inc)、[WindowsCaptureIngress.swift](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/WindowsCaptureIngress.swift)）。stopped / rerouted / interruption notification は HRESULT を伴わない synthetic interruption のため、それだけでは device loss と判定しません（[Microsoft: Recovering from an invalid device error](https://learn.microsoft.com/en-us/windows/win32/coreaudio/recovering-from-an-invalid-device-error)）。native callback 内では device の stop / initialization を行いません。

再 open した loopback candidate は reconnect 用に ingress を準備し、実 packet または有効な idle-health buffer evidence が得られるまで writer へ何も書きません。idle candidate は復帰待ち中の古い区間を無音として取り込みません。有効な idle-health evidence が prepared reopen / settled boundary で成立したら、待機中の単一 `missingCallback` をその境界で閉じ、health silence 後の最初の実 packet は境界から残る既知の idle 区間（250 ms delivery grace を含む）だけを有効な silence として補います。二つ目の gap は作りません。待機が3秒以上でも、欠落として残るのはその境界までの未確認区間だけです。新規の idle start は gap 数0です。250 ms delivery grace、通常の0.5秒 fill cap、3秒の active-output / stall safety は維持します。最初の有効 buffer 前に active output から idle へ移り packet がない場合、その区間は信頼できる idle fill が成立するまで単一の missing interval に留め、隣接する `invalidBuffer` gap を作ったり precondition failure を起こしたりしません。device 復帰待ち以外の通常の idle loopback policy は変わりません。

再接続成功時は eager gap を reopen 時に作りません。通常の packet-first 再接続では最後に captured した end frame から最初に復帰した packet の mapped PTS frame までを1つの `missingCallback` gap として記録し、区間は native open / start latency も含みます。loopback で idle-health evidence が成立した場合は同じ単一 gap を prepared reopen / settled boundary で閉じ、その後の最初の実 packet は残る既知の idle 区間（250 ms delivery grace を含む）だけを有効な silence として補い、二つ目の gap を作りません。新規の idle start は gap 数0です。どちらの再接続経路も `audio_gap_count` は1回だけ増えます。破棄した候補は audio / gap のいずれも書きません。timeout では missing tail を deadline までで閉じ、zero placeholder が保存表現にあっても captured audio ではありません。通常の idle loopback の扱いは復帰待ち以外で変わりません。再接続期限切れは durable stop と通常の finalization enqueue が成功した後にだけ、request を持たない unsolicited `event: error` として報告します。failure は `code: device_lost`、`stage: capture`、`request_id: null`、対象の `session_id`、`severity: warning`、`recovery_action: select_device`、message `録音デバイスが30秒以内に復帰しなかったため録音を停止しました。録音は保存されています` です。`cleanup_errors` は常に空です。最後の reopen diagnostic（factory enumeration / endpoint-list validation error、または native operation 名と code を含む error）が nil なら `details` は空、1回以上あれば最後の diagnostic だけを `domain: capture`、`code: reopen`、`message: <last reopen diagnostic>`、`path: null`、`device_id: null` の単一 `EngineErrorDetail` として返します。同じ failure は既存の bounded state-failure retention に従い保持し、finalization 成功後に消去します（永久保持しません）。この成功した timeout では engine は command を処理し続け、exit code 7 では終了しません。

関連 tests: [`CaptureDeviceReconnectTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/CaptureDeviceReconnectTests.swift)、[`WindowsCaptureConfigurationTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/WindowsCaptureConfigurationTests.swift)、[`WindowsCaptureReconnectTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/WindowsCaptureReconnectTests.swift)、[`EngineApplicationDeviceReconnectTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationDeviceReconnectTests.swift)。

実機で確認する項目（自動テストでは検証しない）:

- [ ] USB microphone を抜き、30秒以内に再接続
- [ ] USB microphone を抜き、30秒を超えて再接続
- [ ] HDMI / DisplayPort loopback 中の GPU driver update
- [ ] loopback 録音中の default output switch
- [ ] USB microphone を再接続した直後の一時的な native reopen error が、30秒以内の復帰まで0.25秒間隔で再試行される
- [ ] GPU driver update 中の一時的な loopback reopen error が、30秒 deadline まで再試行される
- [ ] reconnect 待機中に system sleep し、復帰後の最初の期限超過 tick で再 enumerate / reopen せず `device_lost` になる
- [ ] loopback の再接続待機が3秒を超えて idle のまま復帰し、idle-health boundary までの無音を capture せず、以後の既知 idle silence を補って単一の `missingCallback` gap として保存する
- [ ] GPU idle からの復帰後に loopback playback を再開し、gap が正確に1件となる
- [ ] 新規の idle loopback capture 開始後に playback を始め、gap が0件となる

主な規則です。

- `setup` は、設定がなければ `settings_required`、設定があり `models.prepare` が成功していなければ `models_required`、両方あれば `ready` です。`recording.start` は `ready` でなければ `settings_required` / `model_missing`（復旧は `prepare_models`）で拒否します。キューに入った処理は `ready` になるまで開始しません（`pausesProcessing`）。
- `models.prepare` 実行中は排他的な準備状態です。`settings.replace`、`recording.start` と user processing（`session.import` / `session.reprocess` / `session.retry_decisions`）を `busy` で拒否します。`shutdown` が始まると準備を cancel し、完了した準備結果も inference / processor として late install しません。
- Windows の user processing queue は最大16件で、`current` と `pending` を数えます。熱状態による pause は行いません。モデル未準備で準備処理も実行中でないときは、`session.import` は retained original を保存して queue が空くまでの上限内で enqueue でき、モデルが `ready` になるまで待機します。上限を超える新規 user processing は `busy` です。この queue 上限は controller の最大16 concurrent requests とは別の制限です。
- `recording.start` は、録音中（`waiting_for_device` を含む）・取り込み中、起動時の整理中、確定処理が走っているか待っているときは `busy` です。`recording.stop` は復帰待ち中も通常どおり capture の durable な停止と確定処理の enqueue が済んだ時点で完了し、transcript の確定は待ちません。自動 reconnect timeout は `recording.stop` request の失敗ではなく、durable stop と通常 finalization enqueue の成功後に request ID null の unsolicited `device_lost` / `warning` error を別に送ります。writer failure / その他の fatal capture failure は durable stop して保存済み音声を pending recovery に残し、auto finalization を続けず、unsolicited `capture_failure` / `fatal` error を送り process exit code 7 で終了します。次回起動の recovery がこの session を queue に入れ直します。
- `session.reprocess` と `session.retry_decisions` は settings と準備済みモデルを要求し、モデル未準備なら queue に入れず直ちに `model_missing` / `prepare_models`、`models.prepare` 実行中なら `busy` で失敗します。受け付けた処理は終端結果になってから応答します。decision retry の durable failure は `processing_failure` error として `state.failures` に一件記録し、failed run end を作ります。cancellation が durable outcome 前かつ failed-run cleanup 開始前に観測された場合だけ `cancelled` warning（`処理は中断されました。次回の起動時に再開できます`）で held となり、`state.failures` entry や failed run end は作りません。cleanup 開始後は遅れて届いた cancellation で失敗を held / cancelled に変えず、write failure は二つの error を含む failure として未完了 run を起動時 recovery に残します。decision snapshot の metadata publication 後は `.completed` を保ち、後続の cancellation / shutdown で held にしたり自動 rerun したりしません。`succeeded: true` end だけで metadata が未公開の場合は起動時 recovery 対象です（詳細は上記）。モデル未準備でも準備中でなければ、`session.import` は retained original を保持して finalization queue に enqueue した時点で完了し、モデル準備後まで待機します。
- `session.export` は `transcript.txt` と音声（録音は `audio.flac`、取り込みは original）を destination の下に session フォルダー名で公開し、公開した bundle フォルダーの path を `destination_path` で返します。Import / export の mutation は detached file copy、cleanup、bookkeeping を含む全体を EngineApplication core が所有し、caller の cancel 後も登録済み mutation として完了まで追跡します。shutdown は新しい mutation を拒否し、登録済みの mutation が完了するまで待ってから root lock を解放します。既に開始した copy / export は完了まで実行します。自動書き出しは設定の `automatic_export` と `export_destination_path` を使い、有効で destination が null のときは何もせず書き出し先未設定の `error` を報告します。pause 後に新たな retry や自動書き出しは開始しません。
- `settings.replace` は、モデル profile（`asr_size`、`execution_provider`、`threads`、`decisions_enabled`）が変わる置換を作業中は `busy` で拒否します。profile が変わった置換は準備済み状態を破棄し `models_required` に戻します。`low_heat` は確定処理の pacing に反映します。
- `transcript.watch` は選択中の 1 session を切り替え、末尾最大 200 行を返します。以後はその session の行変更を `rows` event（`changes`、一度に 200 件を超える変更は `reload_required`）で送り、live update で watch revision を進めます。live update ごとに、matching watch / read cache の projection 結果と encoding 結果を行単位で集約し、失敗 marker を row ID、失敗した段階の入力（projection では source segment、encoding では projected row / removal）、failure の組として追跡します。話者 context が不確かなため projection を skip した行など、段階の成功を確認できない marker は保持します。marker は失敗した段階で修復が検証された場合、行の削除・rowless が検証された場合、または final publication を読み込んだ場合にだけ消去します。記録済みの組と同じ失敗は報告せず、新しい組だけを報告するため、同じ失敗が続く update や無関係な行の変更では再報告せず、失敗行の入力または failure が変われば再報告します。failure tracking は source 順の最大16件（`state.failures` の上限）で、それを超えた行は先行する枠が空くまで報告しません。失敗した update は projection の dirty retry state を保持しますが、incremental projection の commit、公開 rows、および revision は更新しません。update で対象になった全行の projection と encoding が検証された場合だけ cache / revision に反映されます。この source-side 抑止で wire schema は変わりません。`transcript.read` は `revision: null` で read snapshot を開始または置き換え、後続 page は同じ revision / cursor を使います。live edit / removal / append ではこの snapshot を変えません。snapshot がない場合も指定 revision が現在の最新 revision と一致すれば snapshot を確立でき、保持 snapshot と最新 revision のいずれにも一致しない revision は `stale_revision`、cursor が一致しない場合は `invalid_cursor` です。final publication は対象 session の read snapshot を無効化します（詳細は `Events、correlation、revision` 節）。
- state の `failures` は直近16件を保持する履歴であり、failure の重複排除 domain ではありません。同一 failure の coalescing は未送信 pending / in-flight error の間だけで、既に delivery 済みの failure と同一の発生も再送します（例: 同一の録音 warning の再発）。app の未送信 error event は最大16件を保留し、超過時は transport admission 前の最古 pending error を置き換え、bounded `EngineLog` marker を出します。最新の failure は `state.failures` に残ります。error sender は1つで、最大1件だけを in-flight にします。transport に admission 済みの reliable `error` と terminal reply は置き換えません。unsolicited `state` / `error` / `rows` は `completed(hello)` が transport に正常に enqueue されるまで gate し、その後 current state を発行します。shutdown で gate を閉じた後は再開せず、in-flight error sender の完了を待ってから `completed(shutdown)` を送り、遅れて background event を出しません。したがって終了処理による maintenance 中断 warning が gate 閉鎖後に必ず送信されるわけではありません。
- `shutdown`（EOF などの切断も同じ）は最初に shutting-down state を設定し、`processingCoordinator.requestPause()` を呼んで processing drain（decision retry を含む）を cancel し、startup maintenance task を cancel します。開始中の録音を取り消し、録音中なら durable に停止します。停止済み session と fatal capture session では残った live ASR backlog を drain せず、active / retired live worker を cancel して完了を待ちます。durable 音声は次回 recovery 用に残ります。既に実行中の native inference call は強制 preempt せず、その call が戻る必要があります。decision retry に限り、shutdown cancellation が durable outcome 前かつ failed-run cleanup 開始前に届けば held / paused になりますが、cleanup 開始後は全 failed completion の保存を試み、durable failure を held / cancelled に置き換えません。decision snapshot の metadata publication 後は retry を `.completed` として保ち、後続 shutdown で再実行しません。`succeeded: true` end のみで metadata が未公開なら次回起動時 recovery の対象です。finalization では、ローカル run 公開前に finalization が中断された場合は `paused` metadata の保存を試みます。保存に成功すれば `paused` を永続化し、次回起動の scanner が `.finalize` として再 enqueue します。保存に失敗した場合は元の中断理由と保存エラーを含む明示的な処理エラー結果を返し、`failFinalization` は呼ばず、既存の `running` / `paused` metadata を保ちます。次回 scanner は残った状態から `.finalize` として再 enqueue します。したがって `paused` が durable なのは metadata 保存に成功した場合に限られます。ローカル run 公開後は finalization attempt の `complete` を保ち、録音 compaction が未完了なら次回起動の storage maintenance で再開し、ASR を再実行しません。実行中 finalization が安全に pause するまで最大30秒待ち、間に合わなければ `shutdown` は失敗して exit code 6 になります。shutdown は登録済み import / export mutation も完了まで待ちます。

録音 compaction は pause signal と interrupt callback で取り消します。通常の `closeStorage` から起動する detached compaction は cancellation handler で親 task の shutdown cancellation を detached task に転送し、startup storage maintenance も shutdown cancellation を compactor / encoder まで伝えます。録音用 FLAC encoder は最大4096 sample frames の block で符号化し、validation は各 FLAC frame を decode・検査します。これは他の FLAC reader が block size を4096 sample frames に固定する保証ではありません。encode / validation 中は cancellation を確認するため、detached encode が uninterruptible になることはありません。cancel は filesystem failure として報告せず、残る PCM と partial FLAC は次回起動の recovery / compaction が回復可能な状態として扱います。process はこれらの処理完了を待ってから root lock を解放します。

共通 Core の [`BlockingIOExecutor.swift`](../app/MacAmbientJev/Sources/MacAmbientJevCore/BlockingIOExecutor.swift) が公開する `BlockingIOExecutor.shared` は Swift の TaskExecutor で、enqueue された各 job を専用の Foundation Thread で実行します。単一の serial global bottleneck は作りません。Swift 6.2 の [Executor.swift](https://raw.githubusercontent.com/swiftlang/swift/swift-6.2-RELEASE/stdlib/public/Concurrency/Executor.swift) は task executor preference と default actor の実行場所を説明します。[SE-0417](https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0417-task-executor-preference.md) が示す unstructured Task.detached の非継承は Swift 6.0 でも当てはまります。ここで述べる配置は各 helper が明示する範囲です。Engine の retained `session.import` / `session.export`、Pipeline の [`SessionProcessingAudio`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingAudio.swift) の同期 `compactRecording`、PortableRuntime の [`PortableModelPreparationService`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableModelPreparationService.swift) による同期 asset hash 検証と Silero / clause tagger 構築は、必要な同期 blocking closure に `BlockingIOExecutor.shared` を明示します。PortableRuntime の既定 [`ONNXQwen3ASREngine`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/ONNXQwen3ASREngine.swift) loader は同期 `Qwen3ASRONNXModel` constructor を Task.detached(executorPreference: BlockingIOExecutor.shared) で実行して結果を待ちます。注入された async loader はそのまま呼びます。既定 [`ONNXCommunity1DiarizationEngine`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/ONNXCommunity1DiarizationEngine.swift) loader は、actor-isolated な `prepareSynchronously()` の同期 body を `withTaskExecutorPreference(BlockingIOExecutor.shared)` 内で実行し、pinned asset hash の検証、ONNX environment / sessions の作成、actor が所有する non-Sendable kernel の構築を行います。`diarize` と `unload` は actor entry 後に suspension point がないため、この kernel の利用と解放は直列です。Community loader を async body 全体で包むことや、preference が任意の task へ推移的に継承されることは意味しません。専用 thread に載せるのは同期 blocking work だけです。`task.value` の読み取り・待機は async wait であり、timeout の延長や retry で blocking I/O を補うものではありません。

### 起動時復旧

`EngineApplication.start()` は、`hello` より前に storage maintenance を始めます。maintenance の間は録音・取り込み・再処理を `busy` で拒否します。続いて `SessionProcessingCoordinator.recoverPendingSessions`（共有の `SessionRecoveryScanner` と `SessionRecoveryPlan`）が、強制終了で残った session（録音中だった session、確定処理の途中だった session）の storage maintenance と確定処理を行います。maintenance result は session ID ごとの map で、完了した候補は含まず、実エラーになった候補と shutdown interruption された現在・残りの未実行候補には未完了 item を含めます。map にある候補は maintenance 済みとして扱わず、確定処理にも enqueue しません。issue を engine failure として報告する場合、`SessionMaintenanceIssue.failed` は `filesystem` / `error` / `inspect_session`、`interruptedByShutdown` は `cancelled` / `warning` / `restart` とし、stage はどちらも `maintenance` です。中断 message は shutdown による interruption と次回起動時の再実行を示し、disk error ではありません。両方とも実際に maintenance が成功するまで recovery から除外します。成功した候補の後で `SessionRecoveryPlan` による復旧を enqueue します。結果は state の `recovery`（`running` → `completed`、scan 全体の失敗は `failed`、モデル未準備で待機中は `pending`）と failures に出ます。壊れた folder は個別の `error`（`recovery` / `maintenance`、復旧は `inspect_session`）で、他の session の復旧は続きます。設定やモデルがないと enqueue された復旧は待機し、`models.prepare` の成功後に実行します。一覧と読み取りは復旧中も使えます。shutdown pause は startup maintenance / recovery task を cancel し、その task の完了を待ちます。`ready` の準備失敗時も `EngineProcess` は safe shutdown を先に呼び、startup task の完了後に終了します。startup task や登録済み mutation が終わるまで root lock は保持され、shutdown の最終化と診断出力の後に解放されます。lock 解放後は直ちに終了 code を返します。

### 実行ファイル

`MacAmbientJevEngine.exe`（Windows のみ）は `[--local-app-data <絶対パス>]` だけを受け付けます。省略すると `AppPaths.systemDefault`（SHGetKnownFolderPath の LocalAppData）を使い、指定すると LocalAppData の代わりにそのフォルダーを使います（`<フォルダー>/mac-ambient-jev` が application root）。テストと配置先の変更用で、環境変数や既定値への fallback はありません。

[`EngineProcess.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngine/EngineProcess.swift) の `EngineProcess.run()` は path 解決より先に [`EngineLog`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineTransportIO.swift) を初期化し、通常の application log 用に継承された client stderr の複製を含む bounded diagnostic writer を用意します。起動順は、path 解決、`engine.lock`（LockFileEx）の取得、`WindowsPipeByteSink.claimStandardOutput()` による NDJSON stdout の確保、native stdout capture pipe への redirect、transport と `EngineApplication` の構築、起動時復旧の開始、`EngineController.run()` です。`EngineProcess.withLockedRoot` は lock 取得後の operation error を捕捉して `reportFailure` で stderr へ同期出力し、出力完了後に非 0 code を返します。その後、defer が best-effort の `EngineLog` close を行い root lock を解放します。`run()` の外側の catch は argument / path 解決 / lock 取得など lock 保持前の startup error を `reportFailure` で stderr へ同期出力してから exit code 2 を返します。ready の準備に失敗した場合は safe shutdown を呼んで startup task 完了を待ってから終了します。別 engine が lock を保持している場合は stdout に書かず、理由を同期的に client stderr へ出して exit code 2 で終了します。引数の誤りも exit code 2 です。

stdout は NDJSON record だけです。`WindowsPipeByteSink.claimStandardOutput()` は client の stdout handle を複製して transport 専用に確保します。その後 [`WindowsDiagnosticCapture`](../app/MacAmbientJev/Sources/MacAmbientJevEngine/WindowsDiagnosticCapture.swift) は native stdout だけを private anonymous pipe に redirect し、CRT の fd 1 は [`_dup2`](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/dup-dup2?view=msvc-170)、Win32 の `STD_OUTPUT_HANDLE` は Windows 2000 以降の [SetStdHandle](https://learn.microsoft.com/en-us/windows/console/setstdhandle) でその pipe に接続します。fd 2 と `STD_ERROR_HANDLE` は一切 redirect しません。raw native stderr と Swift runtime の fatal / precondition / crash output は client の実 stderr に届き、client が stderr を drain しなければ uncontrolled runtime write が block することがあります。stderr redirect や native stderr の nonblocking 保証はありません。通常 / application の Swift logs は `EngineLog` が初期化時に複製した client stderr へ bounded `EngineDiagnosticWriter` 経由で送ります。terminal process failure は [`EngineProcess.reportFailure`](../app/MacAmbientJev/Sources/MacAmbientJevEngine/EngineProcess.swift) が `FileHandle.standardError.write(contentsOf:)` で UTF-8 message と LF を同期的に直接書き、非 0 return と（root lock を保持中なら）その release より前に診断を完了します。Swift 6.2 の corelibs Foundation [FileHandle.swift](https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/swift-6.2-RELEASE/Sources/Foundation/FileHandle.swift) の Windows write path は [Win32 WriteFile](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-writefile) を使い、これは Windows XP 以降の API です。client は stderr を drain する必要があり、pipe が満杯なら同期 terminal write は block し得ます。write error は抑制・fallback せず直ちに `fatalError` になります。stdout capture または transport stdout の setup が失敗した場合も、redirect なしで続行する fallback はありません。

通常 / application logs 用の `EngineLog` は [`EngineDiagnosticWriter`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineDiagnosticWriter.swift) の bounded queue を使います。queued record 128 件・queued bytes 262144 bytes・1 record あたり 16384 bytes（末尾 LF を含む）が上限で、これとは別に最大 1 bounded record が writer で in-flight です。超過・oversized record は切り詰めず record 全体を drop し、record 数と LF を含む byte 数を数えます。stderr が再び書き込み可能になったら、drop 数を ASCII の `engine diagnostics overflow: dropped_records=N dropped_bytes=N\n` marker で報告してから残った record を出力します。各 log 呼び出しは bounded queue に追加するだけで、log ごとの async task を作りません。blocked sink に対する [`EngineDiagnosticWriterTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineDiagnosticWriterTests.swift) は producer が止まらないことを検査します。専用 stderr writer は1本です。Windows の [`EngineStandardErrorSink`](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineStandardErrorSink.swift) は継承 stderr の duplicate handle に WriteFile し、満杯の pipe での書き込みは CancelSynchronousIo で取り消せます。close は最大0.25秒 queue を drain し、その後も書き込みが止まっていれば cancel します。この best-effort queue と close の上限は通常 / application logs に適用され、terminal process failure の同期 stderr reporting には適用されません。

native stdout capture は [CreatePipe function](https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createpipe) に 65536-byte の pipe buffer size を要求しますが、これは OS への hint であり、実際の buffer capacity は保証されません。専用 drain thread は最大4096-byteの arbitrary byte chunk を `EngineLog` queue に渡し、protocol record / NDJSON line として扱いません。native stdout capture flood test は capture drain を、blocked sink の [`EngineDiagnosticWriterTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineDiagnosticWriterTests.swift) は通常 / application Swift log producer の bounded な書き込みを検査します。raw native stderr はこの pipe / logger を通らず client stderr に直接書かれ、client が drain しない場合に block し得ます。

- 出力: `WindowsPipeByteSink` は WriteFile を 4096 byte 以下ずつ呼びます（pipe への blocking write は全 byte が渡るまで戻らないため、進捗を deadline で観測できる粒度にする）。`cancelBlockedWrite()` は writer thread に [CancelSynchronousIo](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelsynchronousio) を、書き込みが戻るまで繰り返して送ります。`ERROR_BROKEN_PIPE` / `ERROR_NO_DATA` は `brokenPipe` です。
- 入力: `WindowsPipeByteSource` は ReadFile を呼び、`close()` で読み取り中の thread に CancelSynchronousIo を送ります。client が接続したまま `shutdown` を送ると、入力 thread は ReadFile で待っています。handle を CloseHandle で閉じようとすると戻らず process が終了しないため、取り消してから閉じずに process 終了に任せます。
- 終了 code は `EngineExit.processExitCode` です（0: `shutdown` 要求または EOF、2: 起動失敗、3: protocol 違反、4: 入力エラー、5: 出力失敗、6: shutdown の失敗、7: fatal capture failure）。fatal な transport / capture failure では capture を durable に停止してから非 0 で終了します。

テスト: [`EngineApplicationTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationTests.swift)（全 OS。fake capture の録音→停止→確定→書き出し、強制終了後の起動時復旧、モデル未準備での復旧待機、shutdown 中の finalization 中断と新しい `EngineApplication` / processor instance による次回起動時の再確定、settings の busy 拒否、fatal capture failure 後の durable stop / pending recovery / exit 7）、[`EngineApplicationConcurrencyTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationConcurrencyTests.swift)（startup cancel と root lock の保持、停止済み録音および recording phase が idle になった fatal capture session の live ASR backlog teardown、共有 mutation registry への登録・cancel / throw 後の cleanup と shutdown 待機）、[`EngineApplicationFailureDeliveryTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationFailureDeliveryTests.swift)（pending / in-flight failure の coalescing、delivery 済みの同一 failure の再送〔同一の録音 warning の再発を含む〕、bounded pending delivery、hello 完了後の state 公開、shutdown 中の in-flight error 完了と late event 抑止）、[`EngineApplicationTranscriptTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationTranscriptTests.swift)（oversized watched row の source-side row ID / row content revision dedupe、無関係な更新での再報告抑止、row 内容変更後の再報告、修復後の marker 解除）、[`EngineDiagnosticWriterTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineDiagnosticWriterTests.swift)（bounded queue、producer を止めない blocked sink、overflow marker、oversized record の drop、bounded close）、[`WindowsDiagnosticCaptureTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineTests/WindowsDiagnosticCaptureTests.swift)（Windows。client stderr が止まった状態での native stdout capture flood、stderr handle を変更しないこと、fatal / precondition output が original stderr に届くこと、stdout pollution capture と capture cancellation）、[`WindowsPipeByteSinkTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineTests/WindowsPipeByteSinkTests.swift)（満杯の pipe の取り消し、broken pipe、全 byte の順序、遅い reader、deadline）、[`EngineProcessTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineTests/EngineProcessTests.swift)（build 済み exe を子プロセスで起動し、stdout が NDJSON だけであること、`shutdown` と EOF の終了 code、protocol 違反、二重起動 lock failure）。process test は子が親の継承可能な handle を引き継ぐため直列に実行します。

共通 Pipeline の [`LiveASRSessionTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveASRSessionTests.swift) と [`LiveTranscriptionCoordinatorTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveTranscriptionCoordinatorTests.swift) は、live segment registration、registration 中の停止・取消、共有 queue / processor の race を検査します。[`FinalTranscriptPipelineTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/FinalTranscriptPipelineTests.swift) は公開前の cancellation が `paused` として保存され scanner が次回 finalize すること、公開済み run は `complete` を保ち compaction の再開に ASR を使わないことを検査します。[`SessionProcessingCoordinatorTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingCoordinatorTests.swift) は retry の terminal outcome が遅い cancellation / pause より優先し、retry success で自動 export しないことを検査します。[`PriorityBatchPersistenceTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/PriorityBatchPersistenceTests.swift) は failed-run cleanup 中の cancellation でも開始済み run の failed completion をすべて保存することを検査し、[`EngineApplicationDecisionRetryFailureTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationDecisionRetryFailureTests.swift) は host の typed failure、相関終端 error、単一の background / state failure、遅い cancellation と failed-completion I/O failure 後の起動時 recovery を検査します。[`SessionProcessingAudioTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingAudioTests.swift) と [`RecordingAudioCompactorTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingAudioCompactorTests.swift) は detached compaction への cancellation forwarding と startup maintenance の中断・未実行候補の明示的な map item、および未完了候補を recovery queue に enqueue しないことを検査します。

fake canonical capture は既に canonical な sample を identity converter で送り、実際の `TimestampedMonoSink` → `AudioBlockRing` → `AudioCaptureDrain` → `DurableAudioWriter` と Core の recording FLAC encoder / reader を通して durable frames と FLAC MD5 を検査します。この fake converter は identity なので、Windows platform SRC を検証するものではありません（SRC は WindowsSupport の別 test target が担当します）。

Engine transport の blocking input / stdout write と watchdog wait、および scripted blocking source / sink は専用 thread で動きます。[`EngineTransportOutputTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineTransportOutputTests.swift) の coalescing / backpressure cases は writer を開始する前に queue を埋めてから `start()` するため、write deadline はテストの進み具合を測りません。producer task は test-owned の TransportTestExecutor（serial DispatchQueue backed TaskExecutor）で動き、default pool の進行に依存しません。[`EngineDiagnosticWriterTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineDiagnosticWriterTests.swift) の `close`、[`WindowsPipeByteSinkTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineTests/WindowsPipeByteSinkTests.swift) の sink cancel / close、[`EngineApplicationConcurrencyTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationConcurrencyTests.swift) の FLAC cancellation / retry は Task.detached(executorPreference:) で、[`FLACTimelineReaderTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACTimelineReaderTests.swift) と [`RecordingFLACEncoderTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/RecordingFLACEncoderTests.swift) の FLAC subprocess tests、[`WindowsSessionBoundaryTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/WindowsSessionBoundaryTests.swift) の Windows subprocess 部分、[`WindowsTokenizerMemoryTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/WindowsTokenizerMemoryTests.swift) の memory test、[`WindowsCaptureEnvironmentTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/WindowsCaptureEnvironmentTests.swift) の publisher-join test は await を含まない `withTaskExecutorPreference` で、同期 blocking 呼び出しだけを `BlockingIOExecutor.shared` に載せます。POSIX pipe の [`EngineTransportPipeTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineTransportPipeTests.swift) と [`ONNXCommunity1DiarizationEngineTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXCommunity1DiarizationEngineTests.swift) は executor を指定しません。Pipeline の semaphore helper も Dispatch global pool ではなく、専用 Foundation Thread と checked continuation を使います。deadline を試さない transport cases と slow-reader cases は5秒の deadline を保ち、deadline 専用 cases だけ短い test deadline を指定します。

## 偽キャプチャ engine テストハーネス

[MacAmbientJevEngineHarness](../app/MacAmbientJev/Tests/MacAmbientJevEngineHarness/HarnessMain.swift) は [Package.swift](../app/MacAmbientJev/Package.swift) が提供する独立 test executable product で、app/MacAmbientJev の Tests/MacAmbientJevEngineHarness にあります。本番用 fake flag は追加せず、本番 `MacAmbientJevEngine.exe` は Windows 専用のままです。CLI の6引数 `--root`、`--fixture`、`--sample-rate`、`--channels`、`--inference`、`--threads` はすべて必須です。root は絶対 path の既存 directory、fixture は絶対 path の既存 file、sample rate は `16000|44100|48000`、channels は `1..8`、inference は `deterministic|portable`、threads は `1...min(4, logicalCPUCount)` です。`portable` は Linux / Windows のみで利用でき、PortableRuntime を build しない macOS では明示的な起動エラーになります。harness での fake capture・推論選択は test-only であり、本番 executable に flag や hardware 利用を加えません。

この受け入れ harness は stdin / stdout に test-only の [`HarnessPipeIO.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHarness/HarnessPipeIO.swift) を使い、実際の `EngineTransport` / `EngineController` / `EngineApplication` を通します。一方、出荷する [`WindowsPipeIO.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngine/WindowsPipeIO.swift) と [`EngineProcess.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngine/EngineProcess.swift) の `EngineProcess.run()` にある標準ハンドルの設定・redirect や本番起動時の組み立ては、deterministic / full-model のどちらの acceptance でも対象外です。この対象外範囲は、acceptance をどの OS で実行しても Windows VM を含めて変わりません。本番 executable を別途 build しても、acceptance がこの起動 wiring を検証したことにはなりません。

[FileCaptureProvider](../app/MacAmbientJev/Tests/MacAmbientJevEngineE2ESupport/FileCapture.swift) は header なし raw interleaved little-endian Float32 fixture を最大512 source framesずつ読みます。16 kHz / 44.1 kHz / 48 kHz と1〜8 channelを受け付け、実際の `TimestampedMonoSink` → `AudioBlockRing` → `AudioCaptureDrain`（連続 SRC）→ `DurableAudioWriter` を通します。macOS は MacAmbientJevAppleSupport、Windows は MacAmbientJevWindowsSupport の `CanonicalAudioResampler` を使います。Linux は16 kHz canonical identity のみを受け付け、非 canonical rate は拒否し、SRC や別経路への fallback はありません。有限 fixture 全体を `recording.start` 中に送り、最終 packet の直前に実 writer の checkpoint を永続化します。process は fixture を全部受け取った後も recording 状態を保ち、最終 packet の tail は `recording.stop` まで checkpoint に含めません。

Deterministic acceptance は実際の [EngineApplication](../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/EngineApplication.swift) と [NativeSessionProcessor](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift) で recovery・compaction・catalog・export を行い、[DeterministicInferenceProvider](../app/MacAmbientJev/Tests/MacAmbientJevEngineE2ESupport/DeterministicInference.swift) が VAD / ASR / diarization を決定的に置き換えます。強制終了 scenario は `0 < committedFrames < fullFixtureFrames` の実 checkpoint を確認し、次 process の実 recovery 後に retained / exported FLAC の両方が検証済み checkpoint PCM prefix と完全一致し、未 checkpoint tail を補わないことを検査します。これは hardware capture や実モデル推論の精度の証拠ではありません。

### full-model portable inference acceptance

`engine_acceptance.py full-model` は Linux / Windows の test-only harness で実 PortableRuntime inference と decisions を実行し、同じ音声を使う ProcessRecording CLI baseline と host 出力を比較します。macOS では PortableRuntime が build されないため、この mode は明示的なエラーで終了します。必須 CLI 引数は `--executable PATH`、`--process-recording PATH`、`--fixture PATH`、`--threads N` です。thread 数に既定値はなく、Linux / Windows runners は `2` を渡します。Linux の no-build invocation は次のとおりです。

<pre><code>python3 -B scripts/engine_acceptance.py full-model &#45;&#45;executable /absolute/path/to/MacAmbientJevEngineHarness &#45;&#45;process-recording /absolute/path/to/MacAmbientJevProcessRecording &#45;&#45;fixture app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox_long.wav &#45;&#45;threads 2</code></pre>

fixture は上記 `日本語音声 fixture` の `long` row（18.464 秒）を使います。既存の [`process_recording_acceptance.py`](../tools/linux-audio/process_recording_acceptance.py) helper が使う reference SHA-256 と sample count はこの row から読み、full-model driver はその pin に対する非圧縮 PCM16 / 16 kHz mono WAV を再検証します。PCM16 値は `/32768` で Float32 に変換し、同じ PCM16 source WAV も保持して baseline と比較します。Linux は16 kHz mono identity のみです。Windows は加えて各 sample を3回繰り返し、両 channel に出力する48 kHz stereo WAV / Float32 fixture を生成します。この入力は engine host の Windows `CanonicalAudioResampler` に渡り、実 SRC を通ります。fixture の3倍反復は入力生成だけの規則で、推論 fallback はありません。

Portable harness は既存の ProcessRecording acceptance helper と同じ5つの必須 model 環境変数 `MAC_AMBIENT_JEV_SILERO_MODEL`、`QWEN3_ASR_ONNX_MODEL_DIRECTORY`、`QWEN3_ASR_ONNX_MODEL_SIZE`、`MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY`、`MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` を使います。欠落・空値・不正 path / size は失敗し、別モデルへ切り替えません。engine settings の ASR size と threads は環境設定 / `--threads` に一致し、`decisions_enabled` は true でなければなりません。host は `execution_provider=cpu`、`low_heat=false`、`automatic_export=false`（destination は null）を設定し、`models.prepare` は実際の pinned model files を検証して load します。

各 host scenario は fake file capture から start、stop、実 finalization を行います。retained FLAC と2回の export FLAC は全 frame decode、CRC-8 / CRC-16、STREAMINFO PCM MD5、frame/sample count を検証し、retained と各 export の PCM / FLAC bytes、反復した export bundle の bytes が一致することを確認します。16 kHz mono scenario の canonical PCM は元 source WAV の全 sample と完全一致します。別の ProcessRecording baseline は同じ source WAV に `--keep-session --with-decisions --threads N` を指定して処理します（runner は N=2 を渡し、baseline には low-heat 設定を付けません）。Windows の full-model driver は、Python / harness が所有する filesystem checks では path の extended Windows spelling を維持し、ProcessRecording CLI には既存の `SessionsRootPolicy` に渡す path として通常の絶対 DOS / UNC spelling を明示します（retry / fallback は行わず、policy も弱めません）。

host shutdown 後、ProcessRecording CLI の read-only `--resume-session` mode は既に公開済み event を読み取り JSON を materialize します。resume の前後で `events.jsonl` と `processing_metadata.json` の bytes が変わらないことを確認します。baseline と host の JSON は semantic leaf ごとに型・key・配列順も含めて厳密比較します。比較対象には segment ID、source segment ID、開始・終了時刻、raw `text` と `display_text`、speakers / confidence、clause state、clause slice の ranges / priorities / retry state を含みます。canonicalize する lineage は `source.segmentation_run_id`、`source.asr_run_id`、`source.asr_event_seq`、`clause_slices[].reference.boundary_run_id`、`clause_slices[].reference.clause_id` の5 path だけで、clause ID 間の alias equality は保ちます。text normalization、数値 epsilon、その他の field 除外はありません。別々の inference run ID は異なるため JSON 全体の byte equality とはせず、この5 lineage path 以外の意味内容が完全一致することを検査します。不一致では segment / field / text mismatch 数と最初の field path を出し、scenario ごとに segment・比較 field・text・FLAC frame/sample/MD5 の値も表示します。`transcript.read` は baseline の display projection と一致し、exported `transcript.txt` は `transcript.read` rows の整形結果と bytes 単位で一致します。

これらは test-only file capture による EngineHost / PortableRuntime の acceptance で、microphone / system-audio hardware、WASAPI 実機、出荷 executable の pipe wiring、manual 操作や long-duration operation を検証しません。数値 suite や acceptance の実行結果から、この文書に測定値や品質保証を追加するものではありません。

Deterministic acceptance の検証用 fixture は反復しない、frame ごとに厳密単調増加する ramp で、各 channel に異なる offset を与えます。channel を mono にした source signal は `(-16000 + frame * 16000 / rate) / 32768` です。16 kHz identity では canonical PCM の全 sample（両端を含む）と、強制終了前に commit 済みの各 chunk を global sample index `i` に対する `i - 16000` と完全一致させます。44.1 kHz / 48 kHz SRC は連続 ramp を出力時刻で独立に評価し、canonical sample index `i` の期待値 `i - 16000` との interior 差を絶対値 8 LSB 以下とします。SRC では先頭・末尾各256 sample だけを filter の開始・EOS 過渡として除外し、identity 検査からは除外しません。ramp の曲率は0で unity-DC filter はその傾きを保ち、遅延補償と量子化を考慮した8 LSB の上限は十分に保守的です。512 source-frame のずれは約171 LSB（48 kHz）/ 186 LSB（44.1 kHz）で8 LSBを大きく上回るため、chunk の並べ替え・重複や、入力を無視する定数出力 converter を検出します。driver の self-tests は channel ramp、identity の両端、endpoint の破損、8 LSB を許容し9 LSB を拒否する境界、定数出力の拒否、512-frame chunk の並べ替え・重複の検査を含みます。

Swift 6.2 の build と、build 済み executable path を必須入力する no-build acceptance は次のとおりです（[Swift 6.2 release](https://www.swift.org/blog/swift-6.2-released/)）。Windows の `scripts/test-windows.ps1` は package build 後、`swift build --show-bin-path` で解決した `$binDir\MacAmbientJevEngineHarness.exe` を driver に渡します。acceptance command は既存 executable を使い、build は行わず、deterministic acceptance を実行します。

```bash
swift build --package-path app/MacAmbientJev --product MacAmbientJevEngineHarness
```

<pre><code>python3 -B scripts/engine_acceptance.py deterministic &#45;&#45;executable /absolute/path/to/MacAmbientJevEngineHarness</code></pre>

<pre><code>python -B scripts/engine_acceptance.py deterministic &#45;&#45;executable "C:\absolute\path\to\MacAmbientJevEngineHarness.exe"</code></pre>

[engine_acceptance.py](../scripts/engine_acceptance.py) は child を binary stdin/stdout/stderr pipes で起動し、stdout を strict NDJSON として検査しながら stdout/stderr を drain し、I/O と scenario の deadline を適用します（[Python 3.12 `subprocess`](https://docs.python.org/3.12/library/subprocess.html)）。native profile 専用の [engine_acceptance_flac.py](../scripts/engine_acceptance_flac.py) は全 frame を decode し、constant / verbatim / fixed-predictor 4-bit Rice subframe、CRC-8 / CRC-16、STREAMINFO PCM MD5、正確な frame/sample count と canonical PCM を検証します。これは限定した `RecordingFLAC` profile validator であり、一般 FLAC decoder の実装を主張しません（[RFC 9639, December 2024](https://www.rfc-editor.org/rfc/rfc9639.html)）。driver と validator の self-test は `python3 -B scripts/test_engine_acceptance.py` と `python3 -B scripts/test_engine_acceptance_flac.py` です。

Windows driver の long-path scenario は260文字超の root path を作り、Unicode / space を含む path、child directory の reparse-point export rejection、再 export の byte 不変性も扱います。driver は Python が所有する一時 path に `\\?\C:\...` または `\\?\UNC\server\share\...` の extended absolute spelling を明示して使うため、260文字超 scenario は system registry の設定や default fallback に依存しません（[Microsoft: Maximum Path Length Limitation](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)、updated 2024-07-16）。選択した root path の symlink 解決は許容し、reparse-point rejection の検査境界は export root 内の child です。SRC・multichannel/timestamp/restart・overflow・idle loopback・stall・disk error/low space・power error・healthy writer prefix は既存の [CanonicalAudioResamplerTests](../app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/CanonicalAudioResamplerTests.swift)、[WindowsCaptureIngressTests](../app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/WindowsCaptureIngressTests.swift)、[WindowsNativeCapturePacketTests](../app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/WindowsNativeCapturePacketTests.swift)、[WindowsCaptureSourceTests](../app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/WindowsCaptureSourceTests.swift)、[WindowsCaptureSafetyTests](../app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/WindowsCaptureSafetyTests.swift) が扱うため、ここでは重複させません。

[EngineP4FloodEvidenceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineP4FloodEvidenceTests.swift) の4 tests は production limits で `P4_BOUND` counters を出し、stdout queue 128 records + 1 in-flight、8 MiB queued-byte cap、stdin 1 MiB line cap、admission 16 slots（2 reserved、14 ordinary）を検査します。これは4時間/RSS gate、paging、resource preflight の証拠ではなく、既存 live/history の unbounded measurement は対象外です。
