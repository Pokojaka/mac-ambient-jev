# Clean Transcription Core — Design Spec

Date: 2026-09-22
Repository: `Pokojaka/mac-ambient-jev`
Status: Approved conversational design, awaiting written-spec review

## 1. Purpose

Build a macOS transcription core that turns live microphone audio or imported recordings into structured, lossless, AI-consumable transcripts.

The v1 product is not a lecture-note generator and not yet a daily-life voice assistant. Its job is to create a reliable intermediate representation that later agents can use for lecture notes, explanations, Q&A, daily conversational context, or other downstream tasks.

Humans may read the live transcript during a lecture to recover a recently missed statement. After the session, the transcript is primarily machine-facing intermediate data rather than the final human-facing artifact.

## 2. Success criteria

v1 succeeds when it can:

1. Record a 60–90 minute session without losing the original audio.
2. Import an existing lecture recording and run it through the same processing pipeline as live audio.
3. Segment speech with VAD and transcribe each completed utterance locally with Qwen3-ASR 1.7B on Apple Silicon.
4. Show each ASR result promptly in a live transcript without waiting for Jev or a general-purpose LLM.
5. Preserve all ASR results while assigning two independent metadata axes:
   - content priority: `PRIMARY` / `LOW_PRIORITY`;
   - acoustic scope: `NEAR` / `BACKGROUND` / `UNKNOWN`.
6. Use Jev conservatively to demote only clearly low-information speech.
7. Infer `LECTURE` vs `DISCUSSION` with a stable state machine rather than per-utterance guesses.
8. During discussion, separate likely near-group speech from likely background speech and perform anonymous session-local diarization where possible.
9. Continue recording if ASR, Jev, diarization, or scene analysis fails.
10. Preserve enough metadata to re-run later processing without re-recording.
11. Support automated, AI-based quality evaluation without requiring a human-labeled transcript corpus.

## 3. Non-goals for v1

v1 does not implement:

- lecture-note generation;
- summarization, explanations, quizzes, or course-material synthesis;
- general LLM processing in the live path;
- wake-word-free AI response behavior;
- VOICEVOX or other speech output;
- long-term speaker identity;
- permanent `SELF` identity;
- long-term memory;
- cloud sync;
- manual transcript correction as a primary workflow;
- in-lecture playback of captured audio;
- a full waveform editor;
- semantic importance ranking of lecture content.

The original audio remains available as source data, but v1 does not expose “click transcript line to replay audio” during a lecture.

## 4. Upstream strategy

Use `pasrom/meeting-transcriber` as the implementation baseline where practical instead of rebuilding macOS audio infrastructure from scratch.

Prefer reusing its existing concepts and components for:

- macOS microphone capture;
- microphone permissions and device selection;
- session start/stop;
- background processing;
- audio streaming/queue infrastructure;
- FluidAudio / VAD integration;
- diarization and speaker embedding infrastructure;
- SwiftUI application shell;
- tests and app plumbing.

Do not aggressively delete upstream features. Features not required by this project should normally be hidden, disabled, or bypassed so future upstream synchronization remains possible.

The new project-specific core is centered on:

- utterance collection from VAD;
- Qwen3-ASR 1.7B local worker integration;
- structured transcript storage;
- Jev priority classification;
- scene state inference;
- near/background classification during discussions;
- live transcript UI;
- imported-audio processing.

## 5. Top-level architecture

```text
                  AudioSource
                      |
          +-----------+-----------+
          |                       |
 LiveMicrophoneSource       FileAudioSource
          |                       |
          +-----------+-----------+
                      |
                Audio Capture
                      |
          +-----------+-----------+
          |                       |
     source audio               VAD
                                  |
                         UtteranceCollector
                                  |
                           AudioSegmentQueue
                                  |
                         Qwen3-ASR 1.7B
                                  |
                         TranscriptSegment
                                  |
                 +----------------+----------------+
                 |                |                |
           Scene Analyzer   Acoustic Scope     Jev Cleaner
                 |                |                |
                 +----------------+----------------+
                                  |
                           Transcript Store
                                  |
               content_priority + acoustic_scope
                                  |
                           downstream agents
```

The recording path is independent from the enrichment path. Slow or failed downstream processing must not interrupt audio capture.

## 6. Audio sources

### 6.1 Live microphone

The user explicitly starts and stops a session.

On start:

1. create a session;
2. begin continuous source-audio persistence;
3. stream audio to VAD;
4. enqueue completed utterances for ASR.

Always prioritize source-audio persistence over downstream work.

### 6.2 Imported recording

The user can choose an existing audio file, especially previously recorded lecture audio.

Imported recordings create a normal session with `source.type = imported_file`.

The imported path feeds the same VAD → ASR → scene → Jev → store pipeline as live capture. It must not have a separate transcription implementation.

Initial supported formats should use the reliable formats already handled by the chosen macOS audio stack; target common formats such as M4A, WAV, MP3, and AAC where the underlying framework supports them.

The original imported file must not be modified. By default, create a session-owned immutable copy under the session audio directory so later processing does not depend on the external file remaining at its original path.

## 7. VAD and utterance segmentation

VAD is responsible only for identifying safe acoustic utterance boundaries.

It must not decide whether speech is meaningful.

Behavior:

- begin buffering when speech starts;
- tolerate short internal pauses;
- end the utterance after configurable sustained silence;
- include short pre-roll and post-roll to avoid clipping phoneme boundaries;
- never discard a segment solely because it is short;
- if an utterance becomes too long, prefer the most suitable recent pause near the limit, otherwise force a hard split;
- represent overlap explicitly when detected rather than inventing a single-speaker assignment.

Configuration is internal and tunable. Parameters include:

- speech start threshold;
- speech end threshold;
- minimum end-silence duration;
- pre-roll;
- post-roll;
- hard maximum utterance duration.

Exact timing values are calibration parameters, not product invariants.

The source audio is canonical. VAD segmentation is reproducible derived data and can be regenerated from stored audio.

## 8. ASR architecture

### 8.1 Default engine

Default v1 engine: Qwen3-ASR 1.7B via MLX on Apple Silicon.

The engine should fit behind the transcription abstraction already used by the upstream application where practical.

### 8.2 Worker model

Run ASR as one long-lived local worker rather than loading the model per utterance.

```text
Swift app
   |
   | JSONL request/response
   v
Python ASR worker
   |
   v
Qwen3-ASR 1.7B / MLX
```

The model loads once and remains resident.

v1 uses one worker and one ordered ASR queue. Multiple ASR workers are out of scope unless measurements later prove one worker cannot keep up.

### 8.3 Live behavior

This is not token-streaming ASR.

The sequence is:

1. VAD detects utterance end.
2. The utterance is sent to the ASR worker.
3. The completed transcript is returned.
4. The transcript appears immediately in the live UI.
5. Scene, speaker, acoustic-scope, and Jev metadata are attached asynchronously.

No general LLM sits between ASR and live display.

### 8.4 Worker protocol

Use simple local process IPC, preferably newline-delimited JSON over stdin/stdout for v1.

A request identifies:

- request ID;
- segment ID;
- audio source reference;
- start/end range or materialized utterance file.

A response returns:

- request ID;
- segment ID;
- transcript text;
- language if available;
- status/error information.

Do not embed large PCM buffers as base64 JSON.

The implementation plan must choose between safe range-reading from the active source file and materializing a temporary utterance audio file based on the actual upstream recording APIs.

### 8.5 Failure states

Per-segment ASR states include at least:

- `PENDING`;
- `OK`;
- `EMPTY`;
- `FAILED`;
- `TIMEOUT`;
- `WORKER_UNAVAILABLE`.

If the worker crashes:

- recording continues;
- VAD continues;
- segments remain queued/persisted;
- the app restarts the worker;
- the model reloads;
- pending segments resume.

## 9. Transcript data model

### 9.1 Canonical store

Use one canonical append-safe transcript representation rather than duplicating records into several independently authoritative files.

Primary file:

`transcript.jsonl`

Each record represents one segment and includes, as available:

```json
{
  "id": "seg_000042",
  "session_id": "session_20260922_01",
  "start_ms": 199100,
  "end_ms": 201970,
  "text": "あれ、画面出ないな。ちょっと待ってください",
  "asr": {
    "engine": "qwen3-asr",
    "model": "1.7b",
    "status": "ok"
  },
  "scene": {
    "state": "lecture",
    "confidence": 0.91
  },
  "speaker": {
    "id": "speaker_2",
    "confidence": 0.81
  },
  "scope": {
    "class": "near",
    "confidence": 0.76
  },
  "content_priority": "low_priority",
  "jev": {
    "schema_version": "v1",
    "scores": {}
  }
}
```

Not every enrichment field is required before a transcript segment becomes visible or persistent.

### 9.2 Content priority and acoustic scope

Do not use destructive `DROPPED` semantics, and do not conflate semantic priority with acoustic relevance.

Content priority is one axis:

- `PRIMARY`: normal downstream context;
- `LOW_PRIORITY`: obvious filler, hesitation-only speech, operational friction, or similarly low-information speech; normally excluded from first-pass downstream context but still queryable.

Acoustic scope is a separate axis:

- `NEAR`: likely part of the nearby relevant conversation;
- `BACKGROUND`: likely outside the relevant discussion group;
- `UNKNOWN`: insufficient evidence.

In `LECTURE`, distance alone must never cause lecturer speech to become `BACKGROUND`.

Uncertain semantic content defaults to `PRIMARY`. Uncertain discussion scope defaults to `NEAR`/retained behavior rather than exclusion.

A default downstream view first excludes records whose scope is confidently `BACKGROUND`, then prefers `PRIMARY` over `LOW_PRIORITY`. Both axes remain queryable.

### 9.3 Append-safe revisions

`transcript.jsonl` is an append-safe event log, not an in-place mutable JSON array.

The first record for a segment contains its stable identity, timing, ASR text, and any metadata already available. Later asynchronous enrichment or retroactive scene relabeling is written as an additional update event referencing the same `segment_id`.

Consumers materialize the latest state by applying updates in file order. This preserves crash safety while allowing scene, speaker, scope, and Jev metadata to arrive or change after the transcript text has already been shown.

### 9.4 Derived views

Optional derived files may be generated for convenience, for example:

- `views/primary.jsonl`;
- `views/low_priority.jsonl`;
- `views/background.jsonl`.

The background view is derived from acoustic scope; primary/low-priority views are derived from content priority.

They are never canonical.

## 10. Jev Cleaner

Jev is a conservative low-information classifier, not a summarizer or importance model.

### 10.1 Responsibility

It may help identify:

- standalone fillers;
- content-free acknowledgements;
- equipment/interface fumbling;
- waiting-time remarks;
- incidental operational friction;
- clearly irrelevant muttering.

It must not attempt to identify “important lecture content,” summarize, rewrite, correct terminology, or extract exam material.

### 10.2 Local exact filler fast path

A tiny, conservative local rule may mark exact standalone fillers such as clearly content-free hesitation tokens without calling Jev.

The rule is exact/narrow. It must not grow into an NLP subsystem.

A mixed utterance such as “えー、RSAでは公開鍵を使います” remains `PRIMARY`.

### 10.3 Jev questions

Use a small typed schema with narrow independent scores, conceptually:

- `meaningful_information`;
- `filler_only`;
- `incidental_noise`.

The application policy, not Jev itself, maps scores to `PRIMARY` or `LOW_PRIORITY`.

The policy is deliberately conservative:

- only very high-confidence low-information cases become `LOW_PRIORITY`;
- ambiguity remains `PRIMARY`.

Exact thresholds are calibration settings derived from recorded-session evaluation.

### 10.4 Context policy

Cleaner input is normally the current utterance only.

Do not send the whole lecture or broad context just to become more aggressive about demotion.

If an utterance is ambiguous in isolation, leave it `PRIMARY`.

### 10.5 Caching

Cache Jev results using a fingerprint containing at least:

- normalized text;
- Jev question/schema version;
- model/version identifier when available.

Repeated identical classification inputs reuse stored results.

### 10.6 Failure

If Jev is unavailable or times out, retain the utterance as `PRIMARY`/unclassified-equivalent for normal use. Jev failure must never hide content or block ASR/capture.

## 11. Scene Analyzer

Scene state is session-local:

- `LECTURE`;
- `DISCUSSION`;
- `UNKNOWN`.

It is not predicted independently for each utterance. Use a hysteretic state machine with candidate states:

```text
LECTURE
   |
   v
DISCUSSION_CANDIDATE
   | confirmed
   v
DISCUSSION
   |
   v
LECTURE_CANDIDATE
   | confirmed
   v
LECTURE
```

Candidate states prevent transient questions, brief side conversations, or one long student turn from causing rapid mode oscillation.

### 11.1 Rolling acoustic window

Maintain a rolling acoustic observation window, initially around tens of seconds and tunable from recorded data.

Features may include:

- estimated active speaker count;
- turn count/rate;
- overlap ratio;
- near-speech ratio;
- dominant-speaker ratio;
- voiced duration.

Recompute periodically.

### 11.2 Semantic transition detector

Use a separate narrow semantic classifier for scene transition cues.

Examples of start cues:

- “では隣の人と話し合ってください”
- “5分間グループで考えてください”
- “3人組を作ってください”

Examples of end cues:

- “はい、そこまでです”
- “グループワークは終了です”
- “それでは解説します”
- “では前に戻ってください”

This detector is separate from `JevCleaner` even if both use Jev as a backend.

Its typed output is conceptually:

- `discussion_start` probability;
- `discussion_end` probability;
- `none` probability.

It may use the current utterance, previous utterance, and current scene only. It must not require the full transcript.

### 11.3 LECTURE → DISCUSSION

Strong path:

1. a semantic start cue appears;
2. state becomes `DISCUSSION_CANDIDATE`;
3. within a confirmation interval, near multi-speaker activity or turn-taking actually rises;
4. state becomes `DISCUSSION`.

If conversation does not actually begin, return to `LECTURE`.

Weak path:

Sustained acoustic evidence alone may move `LECTURE` to `DISCUSSION_CANDIDATE`, then to `DISCUSSION` only after continued confirmation.

A brief student/teacher exchange must not trigger discussion mode.

### 11.4 DISCUSSION → LECTURE

This transition is stricter than the start transition.

Strong path:

1. a semantic end cue appears;
2. state becomes `LECTURE_CANDIDATE`;
3. observe the following interval;
4. confirm that near multi-speaker activity/turn-taking falls and one speaker becomes dominant;
5. transition to `LECTURE`.

If group conversation continues, revert to `DISCUSSION`.

Acoustic-only transition is allowed only with strong sustained evidence. A single group member talking for a long time is insufficient by itself.

### 11.5 Transition timestamp

Detection may happen after the real transition.

When a candidate is confirmed, retroactively assign the best-supported transition time within the recent observation window rather than using the confirmation time.

Recent segments must therefore support scene relabeling through append-only segment update events rather than destructive rewriting.

### 11.6 UNKNOWN behavior

At startup or when evidence is insufficient, state may be `UNKNOWN`.

Once in a stable state, ambiguity alone does not force `UNKNOWN`; maintain the current state until there is sufficient evidence for transition.

## 12. Discussion acoustic scope and diarization

Distance/scope filtering is active only in `DISCUSSION`.

Never classify distant speech as background simply because it is distant while in `LECTURE`, because the lecturer may be physically far from the Mac.

During discussion:

1. estimate whether speech is likely `NEAR`, `BACKGROUND`, or `UNKNOWN`;
2. apply diarization primarily to likely relevant near speech;
3. assign anonymous session-local speaker labels such as `SPEAKER_1`, `SPEAKER_2`;
4. use `mixed`/unknown representations rather than false precision when overlap cannot be resolved.

`NEAR` means “likely relevant to the Mac's nearby discussion group,” not a guaranteed social-group identity.

Conservative rule: if uncertain between near and background, prefer near/primary retention.

Long-term speaker identity and speaker naming are out of scope.

## 13. Live transcript UI

During an active live session, the transcript is a primary UI because the user may need to recover a recently missed statement.

### 13.1 Critical latency rule

Display the transcript as soon as local ASR completes.

Do not wait for:

- Jev;
- scene analysis;
- diarization;
- a general LLM;
- downstream note generation.

Later metadata updates may change styling asynchronously.

### 13.2 Display behavior

- `PRIMARY`: normal display.
- `LOW_PRIORITY`: reduced visual emphasis after classification completes.
- scope `BACKGROUND`: hidden by default during discussion, with optional diagnostics access. Lecture mode does not background-filter distant lecturer speech.
- unclassified/pending metadata: display normally.

When the user scrolls upward to inspect previous statements, automatic “follow latest” scrolling must pause. Provide a clear action to return to the newest utterance.

Show timestamps and anonymous speaker IDs if available.

No audio replay control is required in v1. The user is expected to consult the live text, not play recorded audio during class.

## 14. Session lifecycle and storage

A session directory conceptually contains:

```text
sessions/
└── <session-id>/
    ├── session.json
    ├── processing_metadata.json
    ├── audio/
    │   └── source.<ext>
    ├── transcript.jsonl
    ├── views/
    │   ├── primary.jsonl
    │   ├── low_priority.jsonl
    │   └── background.jsonl
    └── logs/
        └── processing.log
```

Persist progressively throughout the session, not only at stop time.

A segment lifecycle may include:

- `CAPTURED`;
- `ASR_PENDING`;
- `ASR_DONE`;
- enrichment/classification pending;
- complete.

Stopping a session stops new capture but allows queued work to drain.

If work remains because a dependency is unavailable, the session records a completed-with-pending-work state and can resume later.

## 15. Crash recovery and idempotency

The application must survive partial processing.

On restart:

1. detect unfinished sessions;
2. inspect persisted segment states;
3. restart necessary local workers;
4. resume only incomplete work.

Use stable `session_id + segment_id` identity to avoid duplicate transcript rows.

Classification caches and processing versions make enrichment re-runnable without repeating unrelated stages.

## 16. Processing versions and reprocessing

Store processing metadata such as:

- VAD configuration/version;
- ASR engine/model/version;
- scene analyzer version;
- Jev schema/model version;
- policy version.

Reprocessing should reuse earlier stages when possible.

Examples:

- priority-threshold change → reuse stored Jev scores;
- scene algorithm change → reuse audio/ASR;
- Jev schema change → reuse ASR;
- ASR model change → reuse source audio/VAD segments where compatible.

A sophisticated multi-run comparison UI is not required in v1, but the data model must not prevent later comparison.

## 17. Error handling priorities

Priority order:

1. preserve source audio;
2. preserve segment boundaries or enough data to regenerate them;
3. preserve ASR text;
4. add scene/speaker/scope metadata;
5. add Jev priority metadata.

Failure of step N must not erase or block already viable work at steps 1..N-1.

Monitor disk space because storage exhaustion is one of the few downstream failures that can directly threaten source capture.

## 18. Evaluation strategy

The main consumer after a session is an AI agent, not a person reading the raw transcript.

Therefore v1 evaluation focuses on information usability rather than human transcript polish.

### 18.1 Automated evaluation harness

Keep evaluation separate from production processing.

Conceptually:

```text
recorded session
      |
      v
Clean Transcription Core
      |
      +-------------------+
      |                   |
   PRIMARY          full structured data
      |                   |
      +--------+----------+
               |
          AI evaluator
               |
     information-retention report
```

An evaluation LLM may:

1. derive factual questions/tasks from the fuller session data;
2. answer them using the normal default context (non-background `PRIMARY`);
3. compare against answers available when `LOW_PRIORITY` and `BACKGROUND` data are also available;
4. identify cases where content-priority assignment, scene classification, scope classification, or VAD likely caused information loss.

This comparison alone cannot independently measure ASR transcription errors because both views may share the same ASR text. For ASR evaluation, the harness may run selected source-audio segments through an independent reference path using a different ASR or audio-capable evaluator, then compare semantic recovery and important technical terms. This reference path is evaluation-only and is not part of live processing.

No human-labeled full transcript dataset is required for v1.

### 18.2 Human review

Human review is not a required production or evaluation stage for v1.

The system should expose enough diagnostics to investigate failures when desired, but quality evaluation is designed to run automatically.

### 18.3 Core automated metrics

Track at least:

- downstream information-retention delta between primary-only and fuller context;
- number/rate of likely false `LOW_PRIORITY` assignments identified by the evaluator;
- discussion transition timing and stability;
- number of scene oscillations;
- near-group retention relative to background filtering;
- disagreement with the independent ASR evaluation path on selected segments;
- ASR failures/timeouts;
- ASR real-time factor;
- queue depth and oldest pending age;
- memory usage and long-session stability.

Exact target thresholds should be calibrated using the user's real recorded lecture data rather than invented in advance.

## 19. Performance model

The architecture assumes local ASR can process completed utterances at or faster than sustained real-time input on the target Mac.

Measure:

- real-time factor;
- average and maximum ASR processing time;
- maximum queue depth;
- oldest pending segment age;
- memory use;
- long-session thermal/stability behavior.

If one Qwen3-ASR 1.7B worker cannot keep up on the actual M4 16GB machine, only then evaluate fallbacks such as a smaller model or other scheduling changes. Do not pre-build multiple ASR paths into v1.

## 20. Privacy boundary

Raw audio remains local.

Qwen3-ASR runs locally.

External services such as Jev receive text only, not raw audio.

Future downstream cloud LLM use is outside this core's live path and will be designed separately.

## 21. Extension points

The core intentionally exposes structured session data so later phases can add:

- lecture-note and explanation agents;
- quiz/flashcard generation;
- retrieval over historical sessions;
- daily-life conversational agents;
- speaker verification for `SELF`;
- wake-word-free response decisions;
- VOICEVOX or other TTS;
- richer downstream use of `LOW_PRIORITY` and `BACKGROUND`.

These later capabilities must consume the structured transcript rather than requiring a rewrite of capture, VAD, ASR, or storage.

## 22. Design principles

1. **Audio is canonical.**
2. **No destructive transcript filtering.**
3. **When uncertain, retain information.**
4. **Live transcript latency depends on local ASR, not an LLM.**
5. **Scene, speaker, scope, and Jev are enrichments, not capture prerequisites.**
6. **One pipeline handles live and imported audio.**
7. **Use existing upstream macOS/audio infrastructure where it saves work.**
8. **Optimize the transcript for downstream AI utility, not post-class human reading.**
9. **YAGNI: downstream notes and daily-agent behavior are separate later phases.**
