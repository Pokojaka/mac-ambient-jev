# Clean Transcription Core V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS 上で原音声を安全に保存し、VAD、Qwen3-ASR、ダイアライゼーション、場面判定、Jev による意味分類を通して、日本語のライブ文字起こしと再処理可能なセッションデータを生成する V1 を実装する。

**Architecture:** 原音声を最上位の保存対象とし、正規化済み処理タイムライン上の frame index をすべてのローカル処理の共通座標にする。
派生結果は追記専用の `events.jsonl` に保存し、active run の選択と Materializer によって UI と外部利用向けの現在状態を構成する。
Jev だけを外部 API として使い、録音、VAD、ASR、ダイアライゼーション、場面判定、近接度判定、再処理はローカルで完結させる。

**Tech Stack:** Swift 6、Swift Package Manager、SwiftUI、AVFoundation、MLX Swift、Qwen3-ASR 1.7B、FluidAudio、Foundation、URLSession、Security.framework、XCTest。

**Spec:** `docs/superpowers/specs/2026-09-22-clean-transcription-core-design.md`

## Global Constraints

- 原音声を最上位の保存対象とする。
- V1 の ASR は Qwen3-ASR 1.7B を Swift と MLX Swift でローカル実行する。
- Python worker、埋め込み Python、ASR server は作らない。
- V1 の通常処理で外部 API を使うのは Jev だけとする。
- 汎用 LLM は V1 に組み込まない。
- Jev が停止しても録音、ASR、話者分離、場面判定を継続する。
- ユーザー向けの画面文言、状態表示、エラー表示、設定名は日本語を既定とする。
- `events.jsonl` は追記専用とし、`SessionWriter` だけが書き込む。
- Materializer は `event_seq` と active run を使って現在状態を構成する。
- 不確実な発話、話者、音響範囲は捨てずに保持する。
- forced alignment は V1 の必須機能にしない。
- HTTP 常駐 API と MCP 常駐サーバーは V1 では作らない。

## Implementation Assumptions

- 最低動作環境は macOS 15.0 とする。
  FluidAudio の offline diarization は macOS 14 以降で利用できるが、macOS 14 の Core ML と BNNS 経路には既知の不安定要因があるため、V1 は macOS 15 以降で検証する。
- アプリ構成は `pasrom/meeting-transcriber` の SwiftPM macOS アプリ構造を参考にし、必要な録音、権限、VAD、ダイアライゼーション周辺だけを選択的に移植する。
- FluidAudio は `0.12.4` を exact version で固定する。
- Qwen3-ASR Swift は実装開始時点の HEAD を取得し、40 文字 commit SHA を `Package.swift` の `.revision(...)` で固定する。
  branch `main` を shipping dependency として残さない。
- upstream 由来コードを移植した場合は、元ライセンスと著作権表示を `THIRD-PARTY-NOTICES.md` に残す。

## Review Focus

- 録音中に ASR が数分停止しても、音声保存が継続し、未処理作業だけが backlog になること。
- process kill によって `events.jsonl` の最終行が途中で切れても、それ以前のイベントと原音声を復旧できること。
- Jev が未接続、タイムアウト、認証失敗、クレジット不足でも、発話を暫定 `PRIMARY` として残し、後から再分類できること。
- 一つの VAD 発話区間に複数話者と複数 scope span が含まれても、近傍または不明区間を誤って丸ごと背景除外しないこと。
- 新しい再処理 run が途中で失敗しても active run を切り替えず、直前の正常な文字起こしを保持すること。

---

## File Structure

実装コードは `app/MacAmbientJev/` に置く。

```text
app/MacAmbientJev/
├── Package.swift
├── Package.resolved
├── Entitlements/
│   └── MacAmbientJev.entitlements
├── Sources/MacAmbientJev/
│   ├── App/
│   │   ├── MacAmbientJevApp.swift
│   │   ├── AppState.swift
│   │   └── AppPaths.swift
│   ├── Domain/
│   │   └── TranscriptTypes.swift
│   ├── Audio/
│   │   ├── AudioCaptureEngine.swift
│   │   ├── AudioImporter.swift
│   │   ├── AudioBlockRing.swift
│   │   ├── DiskSpaceMonitor.swift
│   │   ├── DurableAudioWriter.swift
│   │   └── ProcessingTimeline.swift
│   ├── Storage/
│   │   ├── SessionManifest.swift
│   │   ├── ProcessingMetadata.swift
│   │   ├── EventEnvelope.swift
│   │   ├── SessionWriter.swift
│   │   ├── ActiveRuns.swift
│   │   └── SessionRecovery.swift
│   ├── Segmentation/
│   │   ├── SegmentationEngine.swift
│   │   └── SegmentJobQueue.swift
│   ├── ASR/
│   │   ├── ASREngine.swift
│   │   ├── ASRState.swift
│   │   ├── ModelStore.swift
│   │   └── NativeQwen3ASREngine.swift
│   ├── Diarization/
│   │   └── FluidDiarizationEngine.swift
│   ├── Scene/
│   │   ├── SceneState.swift
│   │   ├── AcousticSceneFeatures.swift
│   │   └── SceneStateMachine.swift
│   ├── Scope/
│   │   ├── ProximityEvidence.swift
│   │   └── ScopeClassifier.swift
│   ├── Jev/
│   │   ├── DecisionProvider.swift
│   │   ├── JevClient.swift
│   │   ├── JevDecisionProvider.swift
│   │   ├── JevUsageCounter.swift
│   │   └── KeychainStore.swift
│   ├── Materialization/
│   │   ├── MaterializedTranscriptSegment.swift
│   │   └── TranscriptMaterializer.swift
│   ├── Pipeline/
│   │   ├── PipelineCoordinator.swift
│   │   └── SessionProcessingState.swift
│   └── UI/
│       ├── LiveTranscriptViewModel.swift
│       ├── LiveTranscriptView.swift
│       ├── SettingsView.swift
│       └── DiagnosticsView.swift
└── Tests/MacAmbientJevTests/
    ├── Storage/
    ├── Audio/
    ├── Segmentation/
    ├── ASR/
    ├── Diarization/
    ├── Scene/
    ├── Scope/
    ├── Jev/
    ├── Materialization/
    ├── Pipeline/
    └── Fixtures/
```

`Sources/MacAmbientJev/` 以下は責務単位で分ける。
録音、永続化、ASR、Jev、Materializer を一つの manager に集約しない。

---

### Task 1: SwiftPM macOS アプリ基盤と依存固定

**Files:**
- Create: `app/MacAmbientJev/Package.swift`
- Create: `app/MacAmbientJev/Entitlements/MacAmbientJev.entitlements`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/App/MacAmbientJevApp.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/App/AppState.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/App/AppPaths.swift`
- Create: `app/MacAmbientJev/Tests/MacAmbientJevTests/AppPathsTests.swift`
- Create: `THIRD-PARTY-NOTICES.md`

**Interfaces:**
- Produces: `AppPaths(applicationSupportURL:cacheURL:)`
- Produces: executable target `MacAmbientJev`
- Produces: pinned FluidAudio and Qwen3-ASR package dependencies

- [ ] **Step 1: Qwen3-ASR の exact revision を取得する**

Run:

```bash
cd app/MacAmbientJev
QWEN_REV="$(git ls-remote https://github.com/ivan-digital/qwen3-asr-swift.git HEAD | awk '{print $1}')"
test "${#QWEN_REV}" -eq 40
printf '%s\n' "$QWEN_REV" > /tmp/mac-ambient-jev-qwen-revision
```

Expected: command が exit 0 で終わり、`/tmp/mac-ambient-jev-qwen-revision` に 40 文字 SHA が 1 行保存される。

- [ ] **Step 2: アプリ用 package と最小 target を作る**

次の shell を実行し、取得した SHA を literal revision として `Package.swift` に書き込む。

```bash
cd app/MacAmbientJev
QWEN_REV="$(cat /tmp/mac-ambient-jev-qwen-revision)"
cat > Package.swift <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacAmbientJev",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacAmbientJev", targets: ["MacAmbientJev"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.12.4"
        ),
        .package(
            url: "https://github.com/ivan-digital/qwen3-asr-swift.git",
            revision: "$QWEN_REV"
        )
    ],
    targets: [
        .executableTarget(
            name: "MacAmbientJev",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Qwen3ASR", package: "qwen3-asr-swift")
            ]
        ),
        .testTarget(
            name: "MacAmbientJevTests",
            dependencies: ["MacAmbientJev"]
        )
    ]
)
EOF
grep -F "$QWEN_REV" Package.swift
```

Expected: `Package.swift` に実 SHA が書かれ、`branch: "main"` は存在しない。

- [ ] **Step 3: AppPaths の failing test を書く**

```swift
import XCTest
@testable import MacAmbientJev

final class AppPathsTests: XCTestCase {
    func testSessionDirectoryLivesUnderApplicationSupport() {
        let support = URL(fileURLWithPath: "/tmp/support")
        let cache = URL(fileURLWithPath: "/tmp/cache")
        let paths = AppPaths(applicationSupportURL: support, cacheURL: cache)

        XCTAssertEqual(
            paths.sessionsRoot.path,
            "/tmp/support/mac-ambient-jev/sessions"
        )
        XCTAssertEqual(
            paths.modelsRoot.path,
            "/tmp/support/mac-ambient-jev/models"
        )
    }
}
```

- [ ] **Step 4: test を実行して失敗を確認する**

Run:

```bash
cd app/MacAmbientJev
swift test --filter AppPathsTests
```

Expected: `AppPaths` が未定義で FAIL。

- [ ] **Step 5: AppPaths と最小 SwiftUI app を実装する**

```swift
import Foundation

struct AppPaths: Sendable {
    let applicationSupportURL: URL
    let cacheURL: URL

    var root: URL {
        applicationSupportURL.appending(path: "mac-ambient-jev", directoryHint: .isDirectory)
    }

    var sessionsRoot: URL {
        root.appending(path: "sessions", directoryHint: .isDirectory)
    }

    var modelsRoot: URL {
        root.appending(path: "models", directoryHint: .isDirectory)
    }

    var configRoot: URL {
        root.appending(path: "config", directoryHint: .isDirectory)
    }
}
```

`MacAmbientJevApp.swift` では `WindowGroup` を作り、最初の画面には「録音を開始」と「音声ファイルを読み込む」だけを表示する。

- [ ] **Step 6: entitlements と権限文言を日本語で追加する**

最低限、マイク権限を有効化する。
アプリ内で表示する説明文は「講義や会話を文字起こしするためにマイクを使用します」とする。

- [ ] **Step 7: upstream notice を追加する**

`THIRD-PARTY-NOTICES.md` に `pasrom/meeting-transcriber` を参考実装として明記し、MIT license 由来コードを移植した場合に元ファイルと著作権表示を追跡できる欄を作る。

- [ ] **Step 8: build と test を通す**

Run:

```bash
cd app/MacAmbientJev
swift package resolve
swift build
swift test
```

Expected: すべて exit 0。

- [ ] **Step 9: commit**

```bash
git add app/MacAmbientJev THIRD-PARTY-NOTICES.md
git commit -m "feat: bootstrap macOS transcription app"
```

---

### Task 2: セッション、イベントログ、active run、復旧

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Domain/TranscriptTypes.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Storage/SessionManifest.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Storage/ProcessingMetadata.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Storage/EventEnvelope.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Storage/SessionWriter.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Storage/ActiveRuns.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Storage/SessionRecovery.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/DomainTypesTests.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Storage/EventStoreTests.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Storage/SessionRecoveryTests.swift`

**Interfaces:**
- Produces: shared `ContentPriority`, `SceneState`, `AcousticScope`, `SpeakerSpan`, `ScopeSpan`
- Produces: `SessionManifest`
- Produces: `EventEnvelope<Payload>`
- Produces: actor `SessionWriter.append(_:)`
- Produces: `ActiveRuns.select(stage:runID:)`
- Produces: `SessionRecovery.recover(sessionURL:)`

- [ ] **Step 1: 共有 domain 型の failing test を書く**

```swift
func testUnknownScopeAndMissingPriorityRemainRepresentable() {
    let scope: AcousticScope = .unknown
    let priority: ContentPriority? = nil

    XCTAssertEqual(scope, .unknown)
    XCTAssertNil(priority)
}
```

`TranscriptTypes.swift` に、後続 Task が共有する型を定義する。

```swift
enum ContentPriority: String, Codable, Sendable {
    case primary
    case lowPriority
}

enum SceneState: String, Codable, Sendable {
    case unknown
    case lecture
    case discussionCandidate
    case discussion
    case lectureCandidate
}

enum AcousticScope: String, Codable, Sendable {
    case near
    case background
    case unknown
}

struct SpeakerSpan: Codable, Sendable, Equatable {
    let speakerID: String
    let startFrame: Int64
    let endFrame: Int64
    let confidence: Double?
}

struct ScopeSpan: Codable, Sendable, Equatable {
    let startFrame: Int64
    let endFrame: Int64
    let scope: AcousticScope
    let confidence: Double
}
```

Run:

```bash
swift test --filter DomainTypesTests
```

Expected: 最初は型未定義で FAIL。
最小実装後は PASS。

- [ ] **Step 2: event ordering の failing test を書く**

```swift
func testSessionWriterAssignsMonotonicEventSequence() async throws {
    let directory = try TemporaryDirectory()
    let writer = try SessionWriter(sessionURL: directory.url)

    let first = try await writer.append(
        EventDraft(eventType: "segment.created", payload: EmptyPayload())
    )
    let second = try await writer.append(
        EventDraft(eventType: "asr.pending", payload: EmptyPayload())
    )

    XCTAssertEqual(first.eventSeq, 1)
    XCTAssertEqual(second.eventSeq, 2)
}
```

- [ ] **Step 3: test を実行して失敗を確認する**

Run:

```bash
swift test --filter EventStoreTests
```

Expected: `SessionWriter` 未定義で FAIL。

- [ ] **Step 4: EventEnvelope と single writer を実装する**

共通 envelope は最低限次を持つ。

```swift
struct EventEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    let eventSeq: UInt64
    let eventID: UUID
    let eventType: String
    let schemaVersion: Int
    let sessionID: UUID
    let processingRunID: String?
    let segmentationRunID: String?
    let segmentID: String?
    let sourceStartFrame: Int64?
    let sourceEndFrame: Int64?
    let createdAt: Date
    let payload: Payload
}
```

`SessionWriter` だけが `events.jsonl` を開き、1 event を 1 JSON 行として append する。

- [ ] **Step 5: 末尾破損復旧の failing test を書く**

```swift
func testRecoveryDropsOnlyIncompleteFinalJSONLine() throws {
    let valid1 = #"{"event_seq":1,"event_type":"segment.created"}"# + "\n"
    let valid2 = #"{"event_seq":2,"event_type":"asr.pending"}"# + "\n"
    let broken = #"{"event_seq":3,"event_type":"asr.com"#

    let recovered = try SessionRecovery.recoverJSONL(
        Data((valid1 + valid2 + broken).utf8)
    )

    XCTAssertEqual(recovered.lines.count, 2)
    XCTAssertEqual(recovered.lastEventSequence, 2)
}
```

- [ ] **Step 6: 復旧処理を実装する**

最終改行より後ろが JSON として decode できない場合だけ、その末尾を破棄する。
途中行の decode 失敗は silent recovery せず、session を `partial_failure` として報告する。

- [ ] **Step 7: active run 切り替えの failing test を書く**

```swift
func testFailedRunCannotReplaceActiveASRRun() throws {
    var runs = ActiveRuns(asr: "asr_run_01")
    runs.markCompleted(stage: .asr, runID: "asr_run_02", succeeded: false)

    XCTAssertThrowsError(
        try runs.select(stage: .asr, runID: "asr_run_02")
    )
    XCTAssertEqual(runs.asr, "asr_run_01")
}
```

- [ ] **Step 8: ActiveRuns を実装する**

stage は次を持つ。

```swift
enum ProcessingStage: String, Codable, Sendable {
    case segmentation
    case asr
    case diarization
    case scene
    case scope
    case contentPriority
}
```

run completion と active selection は別操作にする。
`markCompleted` が成功を記録した run だけを `select(stage:runID:)` で active にできる。

- [ ] **Step 9: Storage tests を通す**

Run:

```bash
swift test --filter Storage
```

Expected: PASS。

- [ ] **Step 10: processing metadata の version test を書く**

```swift
func testProcessingMetadataPersistsReprocessingVersions() throws {
    let metadata = ProcessingMetadata(
        timelineVersion: 1,
        vadVersion: "fluidaudio-vad",
        vadConfigHash: "abc123",
        asrEngine: "qwen3-asr-swift",
        asrModel: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
        asrVersion: "pinned-revision",
        diarizationVersion: "fluidaudio-0.12.4",
        sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1,
        policyVersion: 1,
        materializerSchemaVersion: 1
    )

    let data = try JSONEncoder().encode(metadata)
    let restored = try JSONDecoder().decode(ProcessingMetadata.self, from: data)

    XCTAssertEqual(restored, metadata)
}
```

`processing_metadata.json` は session 作成時に書き、再処理 run ごとの version も event payload に記録する。

- [ ] **Step 11: commit**

```bash
git add app/MacAmbientJev/Sources/MacAmbientJev/Domain app/MacAmbientJev/Sources/MacAmbientJev/Storage app/MacAmbientJev/Tests/MacAmbientJevTests/DomainTypesTests.swift app/MacAmbientJev/Tests/MacAmbientJevTests/Storage
git commit -m "feat: add crash-safe session event store"
```

---

### Task 3: 原音声保存、ファイル import、処理タイムライン

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Audio/AudioCaptureEngine.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Audio/AudioImporter.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Audio/AudioBlockRing.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Audio/DiskSpaceMonitor.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Audio/DurableAudioWriter.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Audio/ProcessingTimeline.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Audio/DurableAudioWriterTests.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Audio/ProcessingTimelineTests.swift`

**Interfaces:**
- Consumes: `AppPaths`, `SessionManifest`
- Produces: `AudioCaptureEngine.start(sessionID:)`
- Produces: `AudioCaptureEngine.stop()`
- Produces: `ProcessingTimeline.readFrames(range:)`
- Produces: `AudioImporter.importFile(_:into:)`

- [ ] **Step 1: durable chunk metadata の failing test を書く**

```swift
func testWriterRecordsCommittedFrameRange() async throws {
    let writer = try DurableAudioWriter(
        directory: TemporaryDirectory().url,
        sampleRate: 48_000,
        channelCount: 1
    )

    try await writer.append(samples: Array(repeating: 0.1, count: 4_800))
    let checkpoint = try await writer.checkpoint()

    XCTAssertEqual(checkpoint.committedFrames, 4_800)
}
```

- [ ] **Step 2: test を実行して失敗を確認する**

Run:

```bash
swift test --filter DurableAudioWriterTests
```

Expected: FAIL。

- [ ] **Step 3: DurableAudioWriter を actor として実装する**

録音 callback から直接ディスク書き込みを await しない。
callback は preallocated bounded SPSC ring buffer の `AudioBlockRing` へ PCM block をコピーし、writer task が順番に 5 秒単位の durable chunk へ書く。
ring が満杯の場合は capture callback を待たせず overflow counter を増やし、UI と診断 log へ即時に異常を出す。
正常時の crash loss window は最後の未確定 chunk だけなので 5 秒以下を受け入れ基準とする。

checkpoint には最低限次を保存する。

```swift
struct AudioCheckpoint: Codable, Sendable {
    let committedFrames: Int64
    let sampleRate: Double
    let channelCount: Int
    let chunkFiles: [String]
}
```

- [ ] **Step 4: disk space monitor の failing test を書く**

```swift
func testDiskSpaceMonitorWarnsBeforeCaptureBecomesUnsafe() throws {
    let monitor = DiskSpaceMonitor(warningThresholdBytes: 2_000_000_000)
    XCTAssertEqual(monitor.level(forAvailableBytes: 1_000_000_000), .critical)
}
```

残容量が warning threshold を下回ったら日本語警告を出し、critical threshold を下回ったら新規録音開始を拒否する。
録音中に critical へ落ちた場合は可能な限り current chunk を確定し、capture failure を記録する。

- [ ] **Step 5: processing timeline の failing test を書く**

```swift
func testTimelineUsesFrameCoordinatesIndependentOfASRResampling() throws {
    let timeline = ProcessingTimeline(
        sampleRate: 48_000,
        channelCount: 1,
        sampleFormat: .float32
    )

    XCTAssertEqual(timeline.milliseconds(forFrame: 48_000), 1_000)
}
```

- [ ] **Step 6: ProcessingTimeline を実装する**

ASR 内部の 16 kHz sample index を public coordinate にしない。
VAD、diarization、scene、scope は `sourceStartFrame` と `sourceEndFrame` でやり取りする。

- [ ] **Step 7: file import test を書く**

fixture WAV を import し、original asset が session directory にコピーされ、元ファイルが変更されていないことを検証する。

```swift
func testImportCopiesOriginalWithoutMutatingSource() async throws {
    let source = try FixtureAudio.makeWAV()
    let before = try Data(contentsOf: source)
    let session = TemporaryDirectory().url

    let result = try await AudioImporter().importFile(source, into: session)

    XCTAssertEqual(try Data(contentsOf: source), before)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.originalURL.path))
}
```

- [ ] **Step 8: microphone capture を upstream の `MicRecorder.swift` を参考に実装する**

移植する場合も、録音 callback の責務を「PCM block を handoff するだけ」に限定する。
meeting detection、system audio tap、LLM protocol generation は持ち込まない。

- [ ] **Step 9: Audio tests を通す**

Run:

```bash
swift test --filter Audio
```

Expected: PASS。

- [ ] **Step 10: commit**

```bash
git add app/MacAmbientJev/Sources/MacAmbientJev/Audio app/MacAmbientJev/Tests/MacAmbientJevTests/Audio
git commit -m "feat: add durable audio and canonical timeline"
```

---

### Task 4: VAD segmentation と bounded segment queue

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Segmentation/SegmentationEngine.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Segmentation/SegmentJobQueue.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Segmentation/SegmentationEngineTests.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Segmentation/SegmentJobQueueTests.swift`

**Interfaces:**
- Consumes: canonical processing timeline frame ranges
- Produces: `SegmentReference`
- Produces: async bounded queue of `SegmentReference`

- [ ] **Step 1: short utterance retention test を書く**

```swift
func testShortSpeechIsNotDiscardedOnlyBecauseItIsShort() async throws {
    let engine = SegmentationEngine(config: .test)
    let events = try await engine.process(
        FixturePCM.speech(durationMilliseconds: 180)
    )

    XCTAssertEqual(events.count, 1)
}
```

- [ ] **Step 2: queue が PCM を所有しない test を書く**

```swift
func testQueueStoresOnlyFrameReferences() async throws {
    let queue = SegmentJobQueue(capacity: 2)
    let ref = SegmentReference(
        segmentationRunID: "seg_run_01",
        segmentID: "seg_01",
        startFrame: 0,
        endFrame: 48_000
    )

    try await queue.enqueue(ref)
    XCTAssertEqual(await queue.count, 1)
}
```

- [ ] **Step 3: FluidAudio VAD を使う adapter を実装する**

upstream の `FluidVAD.swift` を参考にする。

VAD 出力は次に正規化する。

```swift
struct SegmentReference: Codable, Sendable, Equatable {
    let segmentationRunID: String
    let segmentID: String
    let startFrame: Int64
    let endFrame: Int64
}
```

- [ ] **Step 4: pre-roll、silence close、max-duration split の test を追加する**

境界値は test config で固定し、実運用値は設定構造体から注入する。

- [ ] **Step 5: queue capacity 到達時の挙動を実装する**

enqueue が遅延しても録音 callback を止めない。
未処理 segment は event store から再構成できるため、queue の overflow を capture failure にしない。

- [ ] **Step 6: Segmentation tests を通す**

Run:

```bash
swift test --filter Segmentation
```

Expected: PASS。

- [ ] **Step 7: commit**

```bash
git add app/MacAmbientJev/Sources/MacAmbientJev/Segmentation app/MacAmbientJev/Tests/MacAmbientJevTests/Segmentation
git commit -m "feat: add VAD segmentation queue"
```

---

### Task 5: Qwen3-ASR actor とモデル lifecycle

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/ASR/ASREngine.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/ASR/ASRState.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/ASR/ModelStore.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/ASR/NativeQwen3ASREngine.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/ASR/ASREngineTests.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/ASR/ASRIntegrationTests.swift`

**Interfaces:**
- Consumes: `SegmentReference`, `ProcessingTimeline`
- Produces: `ASRResult`
- Produces: `ASREngineState`
- Model ID: `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`

- [ ] **Step 1: protocol と fake engine の failing test を書く**

```swift
protocol ASREngine: Sendable {
    func prepare() async throws
    func transcribe(_ segment: SegmentReference) async throws -> ASRResult
    func unload() async
}

struct ASRResult: Sendable, Equatable {
    let text: String
    let detectedLanguage: String?
}
```

test:

```swift
func testASREngineFailureIsRepresentedInsideASRState() {
    let state = ASREngineState.failed(message: "model unavailable")

    XCTAssertEqual(
        state,
        .failed(message: "model unavailable")
    )
}
```

capture state との障害分離は Task 10 の integration test で固定する。

- [ ] **Step 2: ASR lifecycle state を実装する**

```swift
enum ASREngineState: Sendable, Equatable {
    case stopped
    case loadingModel
    case ready
    case transcribing(segmentID: String)
    case failed(message: String)
}
```

- [ ] **Step 3: managed model store の failing test と実装を書く**

```swift
func testModelStoreNeverUsesSessionDirectoryForDownloads() {
    let paths = AppPaths(
        applicationSupportURL: URL(fileURLWithPath: "/tmp/support"),
        cacheURL: URL(fileURLWithPath: "/tmp/cache")
    )
    let store = ModelStore(paths: paths)

    XCTAssertTrue(store.cacheRoot.path.hasSuffix("/mac-ambient-jev/models"))
    XCTAssertFalse(store.cacheRoot.path.contains("/sessions/"))
}
```

`ModelStore` は `AppPaths.modelsRoot` 以下を Qwen3-ASR の cache root とする。
model load 前に process 内の `QWEN3_CACHE_DIR` をこの directory へ設定し、load 後に model directory が存在することを確認する。
途中 download の一時ファイルを session directory に置かない。

- [ ] **Step 4: NativeQwen3ASREngine を actor として実装する**

```swift
actor NativeQwen3ASREngine: ASREngine {
    private var model: Qwen3ASRModel?

    func prepare() async throws {
        guard model == nil else { return }
        model = try await Qwen3ASRModel.fromPretrained(
            modelId: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        )
    }

    func unload() async {
        model = nil
    }
}
```

`transcribe` は `ProcessingTimeline` から指定 frame range を読み、Qwen3-ASR に渡す。

- [ ] **Step 5: model 未準備中の backlog test を書く**

ASR model が `loadingModel` でも segment reference が保持され、後で処理されることを fake engine で確認する。

- [ ] **Step 6: real model smoke test を opt-in にする**

環境変数 `RUN_MODEL_TESTS=1` のときだけ短い日本語 fixture を実モデルへ渡す。

Run:

```bash
RUN_MODEL_TESTS=1 swift test --filter ASRIntegrationTests
```

Expected: 空文字ではない日本語 transcript を返す。

通常の `swift test` では数 GB の model download を要求しない。

- [ ] **Step 7: model cache と download state を UI へ渡す**

ユーザー表示は次を使う。

```text
音声認識モデルを準備しています
音声認識モデルを読み込んでいます
文字起こし処理が遅れています
```

- [ ] **Step 8: ASR tests を通す**

Run:

```bash
swift test --filter ASR
```

Expected: model opt-in test を除き PASS。

- [ ] **Step 9: commit**

```bash
git add app/MacAmbientJev/Sources/MacAmbientJev/ASR app/MacAmbientJev/Tests/MacAmbientJevTests/ASR
git commit -m "feat: add native Qwen3 ASR engine"
```

---

### Task 6: Materializer と日本語ライブ文字起こし UI

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Materialization/MaterializedTranscriptSegment.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Materialization/TranscriptMaterializer.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/UI/LiveTranscriptViewModel.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/UI/LiveTranscriptView.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Materialization/TranscriptMaterializerTests.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/UI/LiveTranscriptViewModelTests.swift`

**Interfaces:**
- Consumes: Task 2 の shared domain types、ordered events、`ActiveRuns`
- Produces: `[MaterializedTranscriptSegment]`
- Produces: `LiveTranscriptViewModel.rows`

- [ ] **Step 1: active run filtering test を書く**

```swift
func testMaterializerUsesOnlySelectedASRRun() throws {
    let events = FixtureEvents.twoASRRuns(
        oldText: "古い文字列",
        newText: "新しい文字列"
    )
    let runs = ActiveRuns(asr: "asr_run_02")

    let result = try TranscriptMaterializer().materialize(
        events: events,
        activeRuns: runs
    )

    XCTAssertEqual(result.first?.text, "新しい文字列")
}
```

- [ ] **Step 2: scope span と speaker span を失わない test を書く**

```swift
func testMaterializerKeepsMultipleSpeakerAndScopeSpans() throws {
    let segment = try materializeFixture("multi-span")

    XCTAssertEqual(segment.speakers.count, 2)
    XCTAssertEqual(segment.scopeSpans.count, 2)
}
```

- [ ] **Step 3: Materializer を実装する**

```swift
struct MaterializedTranscriptSegment: Identifiable, Sendable {
    let id: String
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let text: String
    let speakers: [SpeakerSpan]
    let scopeSpans: [ScopeSpan]
    let contentPriority: ContentPriority?
}
```

Jev 未判定は `contentPriority == nil` として保持し、UI 側では通常表示する。

- [ ] **Step 4: ASR 完了直後表示の view-model test を書く**

```swift
func testASRCompletedAppearsBeforeEnrichment() async {
    let vm = LiveTranscriptViewModel()
    await vm.apply(FixtureEvents.asrCompleted(text: "公開鍵暗号です"))

    XCTAssertEqual(vm.rows.first?.text, "公開鍵暗号です")
}
```

- [ ] **Step 5: LiveTranscriptView を実装する**

表示規則を次に固定する。

```text
PRIMARY        通常表示
LOW_PRIORITY   薄く表示
BACKGROUND     discussion 中は既定で非表示
Jev 未判定     通常表示
```

ユーザーが上へスクロールしたら自動追従を停止し、「最新へ戻る」を表示する。

- [ ] **Step 6: materialized view の schema stability test を書く**

```swift
func testMaterializedViewEncodesStableAgentFields() throws {
    let segment = FixtureMaterialized.segment()
    let data = try JSONEncoder().encode(segment)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    XCTAssertNotNil(object["segment_id"])
    XCTAssertNotNil(object["text"])
    XCTAssertNotNil(object["scope_spans"])
}
```

V2 の CLI と stdio MCP はこの materialized schema を読む前提なので、field rename は schema version を上げる変更として扱う。

- [ ] **Step 7: UI と Materializer tests を通す**

Run:

```bash
swift test --filter "TranscriptMaterializerTests|LiveTranscriptViewModelTests"
```

Expected: PASS。

- [ ] **Step 8: commit**

```bash
git add app/MacAmbientJev/Sources/MacAmbientJev/Materialization app/MacAmbientJev/Sources/MacAmbientJev/UI app/MacAmbientJev/Tests/MacAmbientJevTests/Materialization app/MacAmbientJev/Tests/MacAmbientJevTests/UI
git commit -m "feat: add live transcript materialization"
```

---

### Task 7: ローカル streaming と offline diarization

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Diarization/FluidDiarizationEngine.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Diarization/FluidDiarizationEngineTests.swift`

**Interfaces:**
- Consumes: canonical processing timeline audio
- Produces: `[SpeakerSpan]`
- Produces: provisional streaming run and final offline run

- [ ] **Step 1: speaker span normalization test を書く**

```swift
func testDiarizationSecondsAreMappedToCanonicalFrames() {
    let mapper = SpeakerSpanMapper(sampleRate: 48_000)
    let span = mapper.map(
        speakerID: "speaker_1",
        startSeconds: 1.25,
        endSeconds: 2.0,
        confidence: 0.8
    )

    XCTAssertEqual(span.startFrame, 60_000)
    XCTAssertEqual(span.endFrame, 96_000)
}
```

- [ ] **Step 2: FluidAudio adapter を実装する**

Task 2 で定義した `SpeakerSpan` をそのまま使い、diarization adapter 内で別の話者型を増やさない。

streaming result は provisional run として保存する。

- [ ] **Step 3: offline run の active 切り替え test を書く**

```swift
func testCompletedOfflineRunCanReplaceStreamingRun() throws {
    var runs = ActiveRuns(diarization: "diar_stream_01")
    runs.markCompleted(
        stage: .diarization,
        runID: "diar_offline_02",
        succeeded: true
    )
    try runs.select(stage: .diarization, runID: "diar_offline_02")

    XCTAssertEqual(runs.diarization, "diar_offline_02")
}
```

- [ ] **Step 4: offline diarization を実装する**

録音停止後に `OfflineDiarizerManager.process(url:)` を使い、disk-backed file processing を優先する。

60〜90 分音声を一括 `[Float]` に展開しない。

- [ ] **Step 5: 単語単位 attribution を作らない**

Materializer は speaker span を時間軸情報として保持する。
ASR text の各単語へ speaker ID を推測で割り当てない。

- [ ] **Step 6: Diarization tests を通す**

Run:

```bash
swift test --filter Diarization
```

Expected: PASS。

- [ ] **Step 7: commit**

```bash
git add app/MacAmbientJev/Sources/MacAmbientJev/Diarization app/MacAmbientJev/Tests/MacAmbientJevTests/Diarization
git commit -m "feat: add local diarization runs"
```

---

### Task 8: 近接度、scope span、ローカル場面状態機械

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Scope/ProximityEvidence.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Scope/ScopeClassifier.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Scene/SceneState.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Scene/AcousticSceneFeatures.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Scene/AcousticSceneFeatureExtractor.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Scene/SceneStateMachine.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Scope/ScopeClassifierTests.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Scene/SceneStateMachineTests.swift`

**Interfaces:**
- Consumes: speaker timeline and local acoustic features
- Produces: `ScopeSpan`
- Produces: `SceneTransition`
- Works without Jev

- [ ] **Step 1: lecture 中に距離だけで background にしない test を書く**

```swift
func testLectureNeverMarksSpeechBackgroundFromDistanceAlone() {
    let classifier = ScopeClassifier()
    let result = classifier.classify(
        evidence: .distant,
        scene: .lecture
    )

    XCTAssertNotEqual(result.scope, .background)
}
```

- [ ] **Step 2: mixed scope segment retention test を書く**

一つの segment に `near` と `background` が混在しても segment 全体を背景扱いしないことを確認する。

- [ ] **Step 3: local-only discussion start test を書く**

```swift
func testAcousticEvidenceCanEnterDiscussionWithoutJev() {
    var machine = SceneStateMachine(config: .test)

    for _ in 0..<6 {
        machine.observe(
            .init(
                activeSpeakerCount: 4,
                turnRate: 0.8,
                overlapRatio: 0.25,
                dominantSpeakerRatio: 0.25,
                voicedDurationRatio: 0.75
            )
        )
    }

    XCTAssertEqual(machine.state, .discussion)
}
```

- [ ] **Step 4: local-only lecture return test を書く**

discussion 中に複数話者活動が下がり、dominant speaker が一定時間戻った場合、Jev cue がなくても `lecture` に戻ることを検証する。

- [ ] **Step 5: SceneStateMachine を実装する**

Task 2 で定義した `SceneState` を使う。
`AcousticSceneFeatureExtractor` は 20 秒 rolling window から active speaker count、turn rate、overlap ratio、dominant speaker ratio、voiced duration ratio を計算する。

初期 production config は次を使い、golden corpus で変更するときは config version を上げる。

```text
discussion candidate:
  activeSpeakerCount >= 3
  turnRate >= 0.25 / sec
  dominantSpeakerRatio <= 0.65
  8 sec 継続

discussion confirm:
  candidate 条件を 12 sec 継続

lecture candidate:
  activeSpeakerCount <= 2
  turnRate <= 0.15 / sec
  dominantSpeakerRatio >= 0.75
  10 sec 継続

lecture confirm:
  candidate 条件を 15 sec 継続
```

start と end で別の hysteresis threshold を持つ。

- [ ] **Step 6: ProximityEvidence と ScopeClassifier を実装する**

V1 では単一の音量閾値だけを最終判定に使わない。
複数特徴を受け取る構造を作り、十分な根拠がなければ `.unknown` を返す。

- [ ] **Step 7: Scene と Scope tests を通す**

Run:

```bash
swift test --filter "Scene|Scope"
```

Expected: PASS。

- [ ] **Step 8: commit**

```bash
git add app/MacAmbientJev/Sources/MacAmbientJev/Scene app/MacAmbientJev/Sources/MacAmbientJev/Scope app/MacAmbientJev/Tests/MacAmbientJevTests/Scene app/MacAmbientJev/Tests/MacAmbientJevTests/Scope
git commit -m "feat: add local scene and scope inference"
```

---

### Task 9: Jev 既定 provider、Keychain、再試行

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Jev/DecisionProvider.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Jev/JevClient.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Jev/JevDecisionProvider.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Jev/JevUsageCounter.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Jev/KeychainStore.swift`
- Modify: `app/MacAmbientJev/Sources/MacAmbientJev/UI/SettingsView.swift`
- Modify: `app/MacAmbientJev/Sources/MacAmbientJev/UI/DiagnosticsView.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Jev/JevDecisionProviderTests.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Jev/KeychainStoreTests.swift`

**Interfaces:**
- Consumes: transcript text and limited scene context
- Produces: `ContentPriorityDecision`
- Produces: `SemanticSceneCue`
- Failure behavior: provisional `PRIMARY` and retryable pending state

- [ ] **Step 1: provider contract の failing test を書く**

```swift
protocol DecisionProvider: Sendable {
    func classifyPriority(
        text: String
    ) async throws -> ContentPriorityDecision

    func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async throws -> SemanticSceneCue
}
```

- [ ] **Step 2: Jev failure fallback test を書く**

```swift
func testJevFailureLeavesSegmentPrimaryAndRetryable() async {
    let provider = FailingDecisionProvider(error: URLError(.notConnectedToInternet))
    let coordinator = JevDecisionCoordinator(provider: provider)

    let result = await coordinator.classify(text: "えー")

    XCTAssertEqual(result.visiblePriority, .primary)
    XCTAssertTrue(result.needsRetry)
}
```

- [ ] **Step 3: JevClient を TypeSafe direct API に対して実装する**

endpoint は `POST https://api.typesafe.ai/v1/systemone` とし、既定 model は `jev-latest` を使う。
header は `Authorization: Bearer <API key>` と `Content-Type: application/json` とする。
response の resolved `model` と `usage.input_tokens` を `content_priority.assigned` または scene cue 用 event の metadata に保存し、cache fingerprint と利用量診断へ使う。

内容優先度は Choice question で `PRIMARY` と `LOW_PRIORITY` の二択にする。
scene cue は Choice question で `discussion_start`、`discussion_end`、`none` の三択にする。

raw audio、speaker embedding、session 全文を送らない。
内容優先度判定では current utterance だけを `state` に入れる。
scene cue 判定では current utterance、直前 3 発話まで、current scene だけを `state` に入れる。

request の形は次に固定する。

```json
{
  "model": "jev-latest",
  "state": {
    "current_text": "では隣の人と話し合ってください",
    "previous_texts": [],
    "current_scene": "lecture"
  },
  "questions": {
    "scene_cue": {
      "type": "choice",
      "instructions": "発話が講義とグループ討論の切り替えを明示しているか判定してください。",
      "criteria": {
        "discussion_start": "討論開始を明示している",
        "discussion_end": "討論終了と講義再開を明示している",
        "none": "どちらでもない"
      }
    }
  }
}
```

- [ ] **Step 4: KeychainStore を実装する**

API key は `UserDefaults`、JSON、log に保存しない。

```swift
protocol SecretStore: Sendable {
    func save(_ value: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}
```

- [ ] **Step 5: mixed-content priority test を書く**

```swift
func testMixedContentCannotBeDemotedByPolicy() {
    let policy = ContentPriorityPolicy()

    let result = policy.apply(
        providerDecision: .lowPriority(confidence: 0.91),
        text: "えー、RSAでは公開鍵を使います"
    )

    XCTAssertEqual(result, .primary)
}
```

policy は Jev score をそのまま UI 判定にせず、保守的な閾値と mixed-content guard を通す。

- [ ] **Step 6: usage counter を実装する**

診断画面で次を表示できるようにする。

```text
Jev 送信回数
推定入力 token 数
成功件数
失敗件数
再試行待ち件数
```

ユーザーが Jev を一時停止できる toggle を Settings に追加する。

- [ ] **Step 7: semantic cue を scene machine へ補助証拠として接続する**

Jev cue だけで即時に final state へ移さない。
candidate state へ進め、ローカル音響確認で確定する。

- [ ] **Step 8: Jev request に音声 path や raw audio が含まれない test を書く**

```swift
func testJevRequestContainsTextContextOnly() throws {
    let body = try JevRequestFactory().priorityRequest(text: "えー")
    let encoded = String(data: try JSONEncoder().encode(body), encoding: .utf8)!

    XCTAssertFalse(encoded.contains("/audio/"))
    XCTAssertFalse(encoded.contains("speaker_embedding"))
    XCTAssertTrue(encoded.contains("えー"))
}
```

- [ ] **Step 9: Jev tests を通す**

Run:

```bash
swift test --filter Jev
```

Expected: PASS。

- [ ] **Step 10: commit**

```bash
git add app/MacAmbientJev/Sources/MacAmbientJev/Jev app/MacAmbientJev/Sources/MacAmbientJev/UI app/MacAmbientJev/Tests/MacAmbientJevTests/Jev
git commit -m "feat: add Jev semantic enrichment"
```

---

### Task 10: PipelineCoordinator、二軸 session state、再開

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Pipeline/SessionProcessingState.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJev/Pipeline/PipelineCoordinator.swift`
- Modify: `app/MacAmbientJev/Sources/MacAmbientJev/App/AppState.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Pipeline/PipelineCoordinatorTests.swift`
- Test: `app/MacAmbientJev/Tests/MacAmbientJevTests/Pipeline/CrashRecoveryIntegrationTests.swift`

**Interfaces:**
- Orchestrates earlier components without owning their internals
- Produces: `captureState` and `processingState`
- Resumes pending tasks from event store and active runs

- [ ] **Step 1: 二軸 state test を書く**

```swift
func testRecordingCanRemainActiveWhileProcessingIsBacklogged() async {
    let state = SessionProcessingState()

    await state.setCapture(.recording)
    await state.setProcessing(.backlogged)

    XCTAssertEqual(await state.captureState, .recording)
    XCTAssertEqual(await state.processingState, .backlogged)
}
```

- [ ] **Step 2: SessionProcessingState を実装する**

```swift
enum CaptureState: Sendable {
    case idle
    case recording
    case stopped
    case failed(String)
}

enum ProcessingState: Sendable {
    case idle
    case running
    case backlogged
    case complete
    case partialFailure(String)
}
```

- [ ] **Step 3: capture が ASR stall に依存しない integration test を書く**

fake ASR を continuation で停止させた状態で、AudioCaptureEngine から durable writer への追加が進むことを検証する。

```swift
func testASRStallDoesNotStopDurableAudioProgress() async throws {
    let harness = try PipelineHarness(asr: SuspendedASREngine())
    try await harness.start()
    try await harness.feedAudio(seconds: 5)

    XCTAssertGreaterThan(
        try await harness.audioCheckpoint().committedFrames,
        0
    )
}
```

- [ ] **Step 4: PipelineCoordinator を実装する**

依存は initializer injection する。

```swift
actor PipelineCoordinator {
    init(
        capture: AudioCaptureEngine,
        writer: SessionWriter,
        segmentation: SegmentationEngine,
        asr: any ASREngine,
        diarization: FluidDiarizationEngine,
        scene: SceneStateMachine,
        decisions: any DecisionProvider,
        materializer: TranscriptMaterializer
    ) { }
}
```

- [ ] **Step 5: stop semantics を実装する**

録音停止時は新規 audio ingestion だけを止める。
ASR、offline diarization、Jev retry は残処理として継続できる。

- [ ] **Step 6: crash recovery integration test を書く**

fixture session に incomplete JSONL tail と pending ASR event を置いて復旧する。

期待値は次のとおり。

```text
原音声は残る
event_seq 1..N は残る
不完全な最後の行だけ落ちる
pending ASR は再投入される
完了済み ASR は重複しない
active run は旧正常 run のまま
```

- [ ] **Step 7: Pipeline tests を通す**

Run:

```bash
swift test --filter Pipeline
```

Expected: PASS。

- [ ] **Step 8: commit**

```bash
git add app/MacAmbientJev/Sources/MacAmbientJev/Pipeline app/MacAmbientJev/Sources/MacAmbientJev/App app/MacAmbientJev/Tests/MacAmbientJevTests/Pipeline
git commit -m "feat: integrate resilient transcription pipeline"
```

---

### Task 11: 評価 harness と回帰 fixture

**Files:**
- Create: `app/MacAmbientJev/Tests/MacAmbientJevTests/Fixtures/README.md`
- Create: `app/MacAmbientJev/Tests/MacAmbientJevTests/Evaluation/GoldenCorpusTests.swift`
- Create: `tools/evaluate-session.swift`
- Create: `docs/evaluation.md`

**Interfaces:**
- Consumes: recorded session directory
- Produces: JSON evaluation report
- Keeps full human transcription optional

- [ ] **Step 1: fixture manifest schema を作る**

```json
{
  "id": "lecture-ja-001",
  "audio": "lecture-ja-001.wav",
  "annotations": {
    "scene_transitions": [
      {"time_ms": 120000, "to": "discussion"}
    ],
    "must_keep_terms": ["RSA", "公開鍵"],
    "must_not_be_low_priority": [42],
    "must_not_be_background": [42]
  }
}
```

著作権上共有できない講義音声は repository に commit せず、local fixture path を設定で参照する。

- [ ] **Step 2: false exclusion test を書く**

```swift
func testGoldenCorpusNeverDropsMustKeepSegment() throws {
    let report = try GoldenCorpusEvaluator.evaluate(fixture: .lectureJA001)

    XCTAssertEqual(report.falseLowPriorityCount, 0)
    XCTAssertEqual(report.falseBackgroundCount, 0)
}
```

- [ ] **Step 3: evaluator を実装する**

最低限次を出力する。

```text
technical_term_retention
false_low_priority_count
false_background_count
scene_transition_error_ms
scene_oscillation_count
asr_rtf
peak_memory_mb
oldest_pending_age_ms
```

- [ ] **Step 4: 15〜30 分の local golden corpus 運用手順を書く**

`docs/evaluation.md` に、個人録音を repository 外に置く方法、annotation file の置き方、実行 command を書く。

- [ ] **Step 5: evaluator test を通す**

Run:

```bash
swift test --filter GoldenCorpusTests
```

Expected: repository 同梱の synthetic fixture では PASS。
実講義 corpus は local opt-in とする。

- [ ] **Step 6: commit**

```bash
git add app/MacAmbientJev/Tests/MacAmbientJevTests/Evaluation app/MacAmbientJev/Tests/MacAmbientJevTests/Fixtures tools/evaluate-session.swift docs/evaluation.md
git commit -m "test: add transcription evaluation harness"
```

---

### Task 12: V1 配布形態、長時間試験、受け入れ試験

**Files:**
- Create: `scripts/build_app.sh`
- Create: `scripts/run_app.sh`
- Create: `scripts/verify_v1.sh`
- Create: `.github/workflows/ci.yml`
- Create: `docs/v1-acceptance.md`
- Modify: `README.md`

**Interfaces:**
- Produces: launchable `MacAmbientJev.app`
- Produces: repeatable CI command
- Produces: V1 acceptance checklist

- [ ] **Step 1: build script を作る**

`build_app.sh` は release binary を SwiftPM で build し、最小の `.app` bundle を生成する。

Run:

```bash
./scripts/build_app.sh
open .build/MacAmbientJev.app
```

Expected: macOS app として起動する。

- [ ] **Step 2: CI を追加する**

CI は model download を必要としない unit tests を実行する。

```yaml
- name: Build
  run: |
    cd app/MacAmbientJev
    swift build

- name: Unit tests
  run: |
    cd app/MacAmbientJev
    swift test
```

- [ ] **Step 3: verify_v1.sh を作る**

最低限、次を順番に実行する。

```bash
cd app/MacAmbientJev
swift package resolve
swift build
swift test
```

Apple Silicon 実機では、環境変数 `RUN_MODEL_TESTS=1` が指定された場合だけ real ASR smoke test も実行する。

- [ ] **Step 4: 60〜90 分 long-session checklist を作る**

`docs/v1-acceptance.md` に次を記録する欄を作る。

```text
録音時間
capture dropout
ASR RTF
peak memory
開始時 memory
終了時 memory
oldest pending age
Jev success/failure count
scene oscillation count
crash recovery loss window
offline diarization completion time
```

- [ ] **Step 5: process kill recovery test を手動受け入れ項目に追加する**

録音中にアプリを強制終了し、再起動後に次を確認する。

```text
過去の原音声が読める
最後の未確定区間以外が残る
events.jsonl が復旧する
完了済み ASR が重複しない
pending ASR が再開する
```

- [ ] **Step 6: offline network test を追加する**

Jev へ接続できない状態で 10 分以上録音し、次を確認する。

```text
録音が継続する
ASR が継続する
scene state machine がローカル音響だけで動く
Jev 未判定発話が通常表示される
Jev 復旧後に再分類できる
```

- [ ] **Step 7: README を日本語 V1 利用方法に更新する**

最低限次を記載する。

```text
必要環境
初回モデル取得
Jev API key の設定
録音開始と停止
ファイル import
データ保存場所
Jev 停止時も録音が継続すること
V1 に汎用 LLM が含まれないこと
```

- [ ] **Step 8: 日本語 UI 文言の regression test を追加する**

状態表示を code 上の一か所へ集約し、少なくとも次を test する。

```swift
func testUserFacingStatusStringsAreJapanese() {
    XCTAssertEqual(UserFacingStatus.loadingASR.text, "音声認識モデルを読み込んでいます")
    XCTAssertEqual(UserFacingStatus.jevDeferred.text, "意味分類を後で再試行します")
}
```

- [ ] **Step 9: 全 verification を実行する**

Run:

```bash
./scripts/verify_v1.sh
```

Expected: unit tests 0 failure、build exit 0。

- [ ] **Step 10: commit**

```bash
git add scripts .github/workflows/ci.yml docs/v1-acceptance.md README.md
git commit -m "chore: add v1 verification and packaging"
```

---

## Final Verification

実装完了後、実装者は次を順番に確認する。

- [ ] `swift build` が成功する。
- [ ] `swift test` が 0 failure で終了する。
- [ ] `RUN_MODEL_TESTS=1 swift test --filter ASRIntegrationTests` が Apple Silicon 実機で成功する。
- [ ] 既存録音を import し、ASR、offline diarization、Materializer まで完了する。
- [ ] ライブ録音中に ASR を意図的に停止させても原音声保存が継続する。
- [ ] Jev を切断しても録音、ASR、scene inference が継続する。
- [ ] process kill 後に session recovery が成功する。
- [ ] failed reprocessing run が active run を切り替えない。
- [ ] discussion 中の mixed scope segment が丸ごと background 除外されない。
- [ ] ユーザー向け UI と error message が日本語で表示される。
- [ ] 60〜90 分の実機試験で memory growth、RTF、queue age を記録する。
