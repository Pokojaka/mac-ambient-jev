# Low Latency Transcription and Speaker Turns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 録音中に Qwen3-ASR の暫定文字を 1〜3 秒目標で表示し、停止後に話者境界で分割した確定文字へ置換する。

**Architecture:** 音声保存と VAD は現行の durable timeline を維持する。開いた VAD 区間を bounded snapshot として Qwen に渡し、録音停止後は別 run で VAD → offline diarization → speaker turns → ASR → scene/scope を実行する。完了した run 群だけを一度に active にする。

**Tech Stack:** Swift 6, macOS 15, SwiftUI, FluidAudio 0.15.8, Qwen3ASR speech-swift pinned revision, XCTest/Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-24-low-latency-transcription-speaker-turns.md`

## Global Constraints

- Qwen3-ASR を継続し、Whisper や別の ASR backend は追加しない。
- 録音中の diarization は実行しない。暫定文字は正本イベントへ書かない。
- 話者個別表示は 4 人、超過者は「その他」、推定不能は「話者不明」。文字と音声を捨てない。
- 既存セッションは明示的に選んだ場合のみ再処理する。
- 新規録音とユーザーの動画再生をテスト手順に含めない。速度・話者評価は既存の発話入り保存音声を使い、無音素材を性能測定に使わない。
- 作業ツリーには先行する未コミット変更がある。対象外ファイルを戻さず、実装タスク同士で同じファイルを同時編集しない。

## Review Focus

1. VAD の一つの区間に S1→S2→S1 があり、交替間隔が 0.2 秒以下でも話者ごとの区間が分かれるか。話者 span 間に空白があれば話者不明区間として残し、元の VAD 範囲を欠けなく覆うか。Task 1 と Task 7 でテストする。
2. 同時発話と diarization の空白で、先頭話者への誤帰属や無音扱いによる削除が起きないか。Task 1、Task 4 でテストする。
3. 推論中に停止・別セッション開始したとき、古い暫定結果が新画面へ戻らないか。Task 3 でテストする。
4. 確定処理が ASR/diarization の途中で失敗したとき、旧 active run が混成状態にならないか。Task 4、Task 5 でテストする。
5. 既存の読み込み音声を手動再処理するとき、外部元ファイルが消えていても保存済み original を使えるか。Task 6 でテストする。

---

### Task 1: Speaker Turn Segmenter

**Files:** Create `app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerTurnSegmenter.swift`; create `app/MacAmbientJev/Tests/MacAmbientJevCoreTests/SpeakerTurnSegmenterTests.swift`.

**Interfaces:** Consume `[SegmentReference]`, `[SpeakerSpan]`, `totalFrames`. Produce `SpeakerTurn(segment: SegmentReference, speakerIDs: [String])` and `SpeakerTurnSegmenter.split(vadSegments:speakerSpans:segmentationRunID:totalFrames:) throws -> [SpeakerTurn]`.

- [ ] **Step 1: Write failing tests.** Use 16 kHz frame intervals: VAD `[0, 48_000)`, S1 `[0, 16_000)`, S2 `[16_000, 32_000)`, S1 `[32_000, 48_000)`; assert returned ranges and IDs exactly. Add tests for `[S1,S2]` overlap, uncovered interval `[]`, adjacent same speaker coalescing, zero/negative/out-of-checkpoint input, sorted unique segment IDs, and union of frames equal to VAD frames.

```swift
let turns = try SpeakerTurnSegmenter().split(
    vadSegments: [SegmentReference(segmentationRunID: "vad", segmentID: "v1", startFrame: 0, endFrame: 48_000)],
    speakerSpans: [
        SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: nil),
        SpeakerSpan(speakerID: "S2", startFrame: 16_000, endFrame: 32_000, confidence: nil),
        SpeakerSpan(speakerID: "S1", startFrame: 32_000, endFrame: 48_000, confidence: nil)
    ], segmentationRunID: "final", totalFrames: 48_000
)
#expect(turns.map(\.speakerIDs) == [["S1"], ["S2"], ["S1"]])
```

- [ ] **Step 2: Run** `cd app/MacAmbientJev && swift test --filter SpeakerTurnSegmenterTests`; confirm missing type failure.
- [ ] **Step 3: Implement** half-open boundary sweep. Validate `totalFrames >= 0`, VAD `0 <= start < end <= totalFrames`, speaker `start < end`; clip speaker spans to checkpoint. Sort unique boundaries, compute active IDs for each adjacent range, coalesce equal consecutive sets within each VAD segment only. Generate `seg_000001` style IDs in time order and reject duplicate input VAD IDs.
- [ ] **Step 4: Run** focused tests and inspect changed-file diff.

### Task 2: Speaker Ranking and Display Projection

**Files:** Create `app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerDisplayMapper.swift`; modify `app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift`; modify `app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift`; create corresponding Core tests.

**Interfaces:** `SpeakerDisplayMapper.makeLabels(spans: [SpeakerSpan], limit: Int = 4) -> [String: String]`; `SpeakerDisplayMapper.label(for rawID: String?, labels: [String:String]) -> String`. Raw event IDs stay unchanged. `LiveTranscriptRow` receives display labels separately from raw `speakers`.

- [ ] **Step 1: Write failing tests** for five IDs with unequal durations, tied duration and first start, duplicate overlapping spans for one ID, unknown span, and a materialized row carrying two simultaneous IDs.

```swift
let labels = SpeakerDisplayMapper.makeLabels(spans: spans)
#expect(labels["S5"] == "その他")
#expect(SpeakerDisplayMapper.label(for: nil, labels: labels) == "話者不明")
```

- [ ] **Step 2: Run** `swift test --filter SpeakerDisplayMapperTests`; confirm failure.
- [ ] **Step 3: Implement** union duration per raw ID, deterministic ranking, and projection labels. Derive labels once from all speaker spans of the active diarization run; never rank independently per row. Replace `row.speakers.first?.id` with all unique mapped labels joined by `・`. A row with no span shows `話者不明` only in a final transcript; live rows have no speaker label and show `暫定`.
- [ ] **Step 4: Run** focused tests and app build.

### Task 3: Open VAD Range and Bounded Live Partial ASR

**Files:** Modify `Segmentation.swift`, `FluidVADSegmentationEngine.swift`, `FluidVADTimelineProcessor.swift`, `LiveVADSession.swift`, `AppState.swift`, `LiveTranscriptViewModel.swift`; create `app/MacAmbientJev/Sources/MacAmbientJevRuntime/LivePartialASRSession.swift`; add Core and Runtime tests.

**Interfaces:** `OpenSpeechRange(utteranceID: String, startFrame: Int64, endFrame: Int64)` in Core; `LiveVADProgress.openSpeech: OpenSpeechRange?`; `LivePartialASRSession.offer(range:checkpoint:) async -> LivePartialResult?` with `LivePartialResult(sessionID, utteranceID, snapshotEndFrame, text)`. `finish()` invalidates pending output.

- [ ] **Step 1: Write failing tests** for no range before speech start, durable end-frame bound, first snapshot at >=0.8 s, refresh at >=2.0 s, one running + latest waiting, older completion ignored, and stale generation after stop ignored.

```swift
let first = await partial.offer(range: OpenSpeechRange(utteranceID: "u1", startFrame: 0, endFrame: 12_800), checkpoint: checkpoint)
#expect(first != nil)
let tooSoon = await partial.offer(range: OpenSpeechRange(utteranceID: "u1", startFrame: 0, endFrame: 20_000), checkpoint: checkpoint)
#expect(tooSoon == nil)
```

- [ ] **Step 2: Run** `swift test --filter LivePartialASRSessionTests`; confirm failure.
- [ ] **Step 3: Implement** assembler's read-only active start, propagate through VAD actors, and bounded snapshot scheduler. Make only `ASRAudioLoader` read durable frames. Store partial text only in the view model. Add `generation` checks on every UI callback. Cancel partial scheduling on stop; a Qwen call already in progress may return but may not mutate UI. Keep final `LiveASRSession` event path separate.
- [ ] **Step 4: Run** focused Runtime tests, Core tests, app build.

### Task 4: Unified Offline Finalization

**Files:** Modify `NativeSessionProcessor.swift`; add `FinalTranscriptPipeline.swift` under Runtime if the processor would otherwise grow further; modify `Materialization.swift` for empty/failed short turns; add `FinalTranscriptPipelineTests.swift` under Runtime.

**Interfaces:** `processFinalTranscript(sessionID: UUID, checkpoint: AudioCheckpoint, onStatus: StatusHandler?, onUpdate: UpdateHandler?) async -> SessionProcessingResult`. Consume Task 1 turns. Produce staged `ActiveRuns` plus final materialized segments. Keep optional Jev outside mandatory commit.

- [ ] **Step 1: Write failing integration tests** with fake diarizer and fake ASR. Inject `any DiarizationEngine` into `NativeSessionProcessor` rather than fixing it to `FluidOfflineDiarizationEngine`. Assert the call order `VAD, diarization, turn segmentation, ASR`, S1→S2 yields two Qwen inputs, mixed overlap has both IDs, empty short turn remains visible as「聞き取れませんでした」, and diarization/ASR failure leaves prior active IDs untouched.

```swift
#expect(fakeCalls == ["vad", "diarize", "asr:S1", "asr:S2"])
#expect(try store.load()?.activeRuns == oldActiveRuns)
```

- [ ] **Step 2: Run** `swift test --filter FinalTranscriptPipelineTests`; confirm failure.
- [ ] **Step 3: Implement** fresh VAD run; export full timeline and run `DiarizationCoordinator`; split VAD intervals; run `PipelineCoordinator` on turn segments; run scene and scope on resulting events. Record successful stage completion; publish one `ActiveRuns` only after all mandatory stages succeed. Remove intermediate `selectSuccessfulRuns` / `selectDiarizationRun` calls from this path. On import and live stop, route to this same method; keep live ASR result as interim display while finalization runs. Return explicit partial failure on failure.
- [ ] **Step 4: Run** pipeline tests, full Core/Runtime tests, app build.

### Task 5: Finalization State and Crash Recovery

**Files:** Modify `ProcessingMetadata.swift`, `SessionRecoveryScanner.swift`, `NativeSessionProcessor.swift`; add Core recovery tests.

**Interfaces:** Add optional `FinalizationAttempt(attemptID: String, state: State, failureReason: String?)` to metadata. Add `RecoverableProcessingAction.finalize` for a `running` attempt. Existing JSON without this key decodes as `nil`.

- [ ] **Step 1: Write failing tests** for old metadata decoding, active runs unchanged while running/failed, one atomic switch on complete, scanner action for interrupted `running`, no auto action for `failed`, and no duplicate active result after restart.

```swift
let old = try JSONDecoder().decode(ProcessingMetadata.self, from: oldJSON)
#expect(old.finalizationAttempt == nil)
```

- [ ] **Step 2: Run** `swift test --filter FinalizationRecoveryTests`; confirm failure.
- [ ] **Step 3: Implement** metadata lifecycle and scanner branch before legacy ASR-plan logic. A crash during `running` schedules new full finalization from saved audio. A caught failure writes `failed`, keeps previous active IDs, and waits for manual retry. Validate stage completion events before the atomic `ProcessingMetadataStore.save` call.
- [ ] **Step 4: Run** Core recovery tests and Runtime finalization tests.

### Task 6: Saved Session List and Explicit Reprocessing

**Files:** Modify `AppState.swift`, `MacAmbientJevApp.swift`; create `SavedSessionsView.swift`; add testable Core `SavedSessionCatalog.swift` and Core tests.

**Interfaces:** `SavedSessionCatalog.list(sessionsRoot:) throws -> [SavedSessionSummary]`, `AppState.reprocess(sessionID:) async`; summary includes session ID, createdAt, source kind, audio availability, active transcript status. `PendingProcessing.finalize` accepts saved session ID and saved source.

- [ ] **Step 1: Write failing tests** for sorting, corrupt one-session metadata reported as an error for that row, missing audio disables reprocess, imported original retained under session directory, and no duplicate queue entry for one session.

```swift
let summaries = try SavedSessionCatalog().list(sessionsRoot: fixtures)
#expect(summaries.map(\.sessionID) == expectedNewestFirst)
#expect(summaries.last?.canReprocess == false)
```

- [ ] **Step 2: Run** `swift test --filter SavedSessionCatalogTests`; confirm failure.
- [ ] **Step 3: Implement** toolbar entry, list/detail UI, selection loading via current active events, and per-row `再処理`. Validate audio availability before queueing; use imported original inside the session or durable processing checkpoint. Disable duplicate same-session work while queued/running and while recording.
- [ ] **Step 4: Run** catalog tests and app build。既存の保存済みセッションを選び、表示・再処理・失敗時の旧表示維持を UI で確認する。新規録音は行わない。

### Task 7: Jev Classification Verification

**Files:** Modify `app/MacAmbientJev/Tests/MacAmbientJevCoreTests/JevDecisionTests.swift` and `JevEnrichmentCoordinatorTests.swift`; modify `NativeSessionProcessor.swift` only if the new finalization path omits Jev; update `docs/v1-acceptance.md`.

**Interfaces:** Feed synthetic Japanese text from finalized `MaterializedTranscriptSegment` to `JevEnrichmentCoordinator`, then inspect `content_priority.assigned` events and the selected active run. Use an injected `JevHTTPTransport` in tests; never place a real key in test code or logs.

- [ ] **Step 1: Write failing tests** for `PRIMARY` on a lecture sentence, conservative `LOW_PRIORITY` on an isolated filler, `discussion_start` / `discussion_end` / `none` response parsing, and HTTP failure resulting in primary display with retry pending. Verify the finalization path passes final turn text, not stale live provisional text. Collect finalization status callbacks and assert the last message is completion/failure, never 「分類中」; the same assertion applies when Jev is skipped.

```swift
let result = await coordinator.classify(text: "えー")
#expect(result.visiblePriority == .lowPriority)
#expect(result.needsRetry == false)
```

- [ ] **Step 2: Run** `swift test --filter JevDecisionTests` and `swift test --filter JevEnrichmentCoordinatorTests`; confirm any new expectation fails before implementation. Existing passing tests can be reused instead of duplicating them.
- [ ] **Step 3: Implement** the terminal status update in `NativeSessionProcessor` for live finalization success, Jev skipped, no speech, and failure. Keep Jev optional after the atomic local run publication, and do not send audio or provisional text. Record existing classification test evidence instead of duplicating passing tests.
- [ ] **Step 4: Run** focused tests. If a saved Jev API key is available, use the existing Settings connection check with one short synthetic sentence and record status only; otherwise record real API communication as unverified. Do not require user video playback or new recording.

### Task 8: Mixed Filler and Content Rendering

**Files:** Create `app/MacAmbientJev/Sources/MacAmbientJevCore/FillerTextSpanDetector.swift` and Core tests; modify `Materialization.swift` projection and `LiveTranscriptView.swift` after Task 2 no longer owns those files. Add projection tests.

**Interfaces:** `FillerTextSpanDetector.fragments(in text: String) -> [TranscriptTextFragment]`; each fragment carries the exact original substring and `isFiller` flag. `LiveTranscriptRow` carries fragments, and `LiveTranscriptView` applies secondary text style only to filler fragments. Concatenating fragments must recover the exact original `text`.

- [ ] **Step 1: Write failing tests** for `えー、今日は公開鍵暗号を説明します。` yielding a filler fragment `えー、` and normal remainder; `今日は、えー、RSAです。` yielding one internal filler; filler-only, no filler, punctuation variants, and similar characters inside a meaningful word. Assert concatenation equals original text in every case.

```swift
let fragments = FillerTextSpanDetector().fragments(in: "えー、今日は公開鍵暗号を説明します。")
#expect(fragments.filter(\.isFiller).map(\.text) == ["えー、"])
#expect(fragments.map(\.text).joined() == "えー、今日は公開鍵暗号を説明します。")
```

- [ ] **Step 2: Run** `swift test --filter FillerTextSpanDetectorTests`; confirm failure.
- [ ] **Step 3: Implement** deterministic phrase-boundary matching for the existing fixed filler vocabulary. Keep the full raw text and event payload unchanged. Build styled fragments in the display projection for both provisional and final rows; never demote a meaningful sentence merely because it contains a filler. Keep whole-segment Jev priority as a separate signal.
- [ ] **Step 4: Run** focused tests and app build. Inspect one saved mixed-content line if available; do not create a new recording.

### Task 9: Measurements and Acceptance

**Files:** Create `app/MacAmbientJev/Sources/MacAmbientJevCore/LiveLatencyTrace.swift`; modify live scheduler and app render callback; create a focused recorded-audio replay harness and measurement script; update `docs/v1-acceptance.md`.

**Interfaces:** One `utteranceID` links `speechStart`, `checkpointCommitted`, `snapshotRequested`, `asrStarted`, `asrReturned`, `viewModelUpdated` monotonic timestamps. Export count, median, P95, maximum, empty/failure count.

- [ ] **Step 1: Write failing calculation tests** for unsorted samples, a failed first snapshot, and percentile boundary. For five delays `[1,2,3,4,5]` seconds, assert chosen nearest-rank P95 is 5 seconds and failure is counted in total attempts.
- [ ] **Step 2: Run** `swift test --filter LiveLatencyTraceTests`; confirm failure.
- [ ] **Step 3: Implement** trace collection without blocking audio persistence and a replay harness that reads an existing audio file, feeds durable chunks at original speed, and drives the same `LiveVADSession` and partial ASR path without opening a microphone. Document this procedure. Do not mark the 3-second target passed from unit tests; report actual replay P50/P95/count and label it as latency from durable timeline to view-model update, excluding microphone input and screen drawing.
- [ ] **Step 4: Run** `scripts/verify_v1.sh`、既存の `test-data/recordings/local/_smoke/audio.wav` と発話入り会話音声によるモデル・原速 replay 試験、および保存済みセッションの再処理・再起動確認。無音音声は速度判定に使わない。2 話者の音声では短い交替と同時発話を確認し、raw diarization の境界誤差と分割処理の正しさを別々に記録する。5 話者の上限は合成 span の単体試験でも確認する。新規録音は行わない。

## Subagent execution order

User requested Luna for implementation. Use a fresh `gpt-6-luna` implementer for each task and a separate review gate. Tasks 1 and 3 can run concurrently because they own different files; Task 2 starts after Task 1 interface is reviewed; Task 4 starts after Tasks 1–3; Task 5 follows Task 4; Task 6 follows Tasks 4–5; Task 7 follows Task 4 and can run beside Task 6 when it does not edit `NativeSessionProcessor.swift`; Task 8 follows Task 2; Task 9 follows all functionality. Avoid parallel edits of `AppState.swift`, `Materialization.swift`, and `NativeSessionProcessor.swift`.

## Self-review checklist

- The spec's live, finalization, speaker mapping, saved-session, recovery, and measurement requirements each map to a task.
- All required types are introduced before dependent tasks. Tests cover the five Review Focus inputs.
- No migration or fallback path is added beyond decoding old metadata and opening saved audio, which the user explicitly requested.
