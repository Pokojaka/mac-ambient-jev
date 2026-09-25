# Linux Audio Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Process Issues #1–#6 by separating a Linux-testable portable core, adding common ASR/diarization evaluators, Linux Qwen/Nemotron runners, reproducible corpora, and a local regression suite without changing the macOS app's production inference path.

**Architecture:** Keep macOS SwiftUI/AVFoundation/MLX/FluidAudio code in Apple/runtime targets. Share only portable Swift schemas/evaluators. Linux model runners communicate through versioned JSON artifacts and remain optional dependencies.

**Tech Stack:** Swift 6 / Swift Testing, Python 3.11+, pytest, Qwen3-ASR, PyTorch/CUDA, NVIDIA NeMo Nemotron 3 Diarization, VOICEVOX Docker, ffmpeg.

**Spec:** `docs/superpowers/specs/2026-09-26-linux-audio-validation-design.md`

## Global Constraints

- macOS `.app` remains the production application.
- Nemotron / CUDA / NeMo / Python must not become Mac app runtime dependencies.
- Portable Core must not import AVFoundation or Security.
- Speaker identity is `Speaker 1...7 + OTHER + UNKNOWN`.
- Speaker 1...7 are assigned in first-arrival order and remain stable.
- The Nemotron eighth stream is not equivalent to OTHER.
- ASR and diarization runners exchange versioned JSON artifacts rather than FFI or a resident service.
- Audio/corpus payloads are cached locally and are not committed by default.
- GitHub Actions are not required.
- Missing optional model dependencies are SKIPPED_MISSING_DEPENDENCY, never PASS.

## Review Focus

- Linux build must not silently pull macOS-only targets or Apple frameworks.
- Empty reference text must not produce NaN/Infinity CER.
- Artifact schema errors or hash mismatches must fail closed rather than generate success reports.
- The eighth and later true speakers must not be silently counted as tracked Speaker 1...7 in collapsed evaluation.
- UNKNOWN must stay distinct from OTHER when evidence is insufficient.

---

### Task 1: Issue #1 — Portable Core boundary

**Files:**
- Modify: `app/MacAmbientJev/Package.swift`
- Move: `app/MacAmbientJev/Sources/MacAmbientJevCore/KeychainStore.swift` -> `app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/KeychainStore.swift`
- Move: `app/MacAmbientJev/Sources/MacAmbientJevCore/AudioFileTimelineBuilder.swift` -> `app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift`
- Move: `app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingTimelineAudioExporter.swift` -> `app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ProcessingTimelineAudioExporter.swift`
- Modify dependent Mac targets to import `MacAmbientJevAppleSupport`
- Move Apple-only tests from CoreTests into `MacAmbientJevAppleSupportTests`
- Create: `scripts/verify_portable.sh`

**Interfaces:**
- Produces: `MacAmbientJevCore` with no Apple-framework imports.
- Produces: `MacAmbientJevAppleSupport` depending on Core.

- [ ] Write a static portability test that fails if Core imports `AVFoundation` or `Security`.
- [ ] Run it and observe failure on current branch.
- [ ] Split package targets and move Apple-specific files/tests.
- [ ] Update Mac runtime/app imports and dependencies.
- [ ] Run portability test; expect PASS.
- [ ] Run Linux Core tests where dependencies permit.
- [ ] Commit with `refactor: separate portable core from Apple support`.

### Task 2: Issue #2 — Japanese ASR evaluation

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJevCore/JapaneseTextNormalizer.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJevCore/CharacterErrorRate.swift`
- Create: `app/MacAmbientJev/Sources/MacAmbientJevCore/ASREvaluation.swift`
- Modify: `app/MacAmbientJev/Sources/MacAmbientJevCore/GoldenCorpusEvaluation.swift`
- Create tests under `MacAmbientJevCoreTests`
- Modify evaluation CLI as needed.

**Interfaces:**
- Produces: `JapaneseTextNormalizer.normalizeForCER(_:)`
- Produces: `CharacterErrorRate.evaluate(reference:hypothesis:)`
- Produces report fields raw/normalized CER plus edit counts.

- [ ] Write failing tests for NFKC, whitespace/punctuation handling, substitutions/deletions/insertions, empty strings and Japanese text.
- [ ] Implement normalizer and Levenshtein edit accounting.
- [ ] Extend Golden Corpus schema compatibly with optional reference text/path.
- [ ] Add JSON report encoding tests.
- [ ] Run Core evaluation tests; expect PASS.
- [ ] Commit with `feat: add portable Japanese ASR evaluation`.

### Task 3: Issue #3 — Linux Qwen3-ASR runner

**Files:**
- Create: `tools/linux-audio/common/artifact.py`
- Create: `tools/linux-audio/asr/pyproject.toml`
- Create: `tools/linux-audio/asr/qwen3_asr.py`
- Create: `tools/linux-audio/tests/test_asr_artifact.py`

**Interfaces:**
- Consumes: audio path.
- Produces: schema-versioned ASR artifact with model revision/backend, segments, audio_seconds, inference_seconds, rtf.

- [ ] Write failing tests for artifact validation and CLI argument failure.
- [ ] Implement dependency-light artifact/CLI layer.
- [ ] Lazy-import qwen-asr/torch so unit tests run without model dependencies.
- [ ] Ensure inference failure writes no success artifact.
- [ ] Run pytest.
- [ ] Commit with `feat: add Linux Qwen3-ASR runner`.

### Task 4: Issue #4 — Reproducible corpora

**Files:**
- Create corpus manifests under `tools/corpora/`
- Create: `tools/linux-audio/common/corpus.py`
- Create: `tools/linux-audio/common/voicevox.py`
- Create tests under `tools/linux-audio/tests/`

**Interfaces:**
- Produces cached corpus fixtures with source/hash/license/reference metadata.
- Produces deterministic VOICEVOX timelines and reference files.

- [ ] Write failing manifest/hash/cache tests.
- [ ] Implement local cache + SHA-256 verification.
- [ ] Add VOICEVOX / Nemo fixed scripts and deterministic fixture metadata.
- [ ] Add LibriVox/青空文庫, CSJ public sample, and news sample manifests without committing audio payloads.
- [ ] Treat inaccessible/hash-mismatched sources as explicit failure.
- [ ] Run pytest.
- [ ] Commit with `feat: add reproducible Japanese audio corpora`.

### Task 5: Issue #5 — Nemotron 3 and 7+OTHER

**Files:**
- Create: `app/MacAmbientJev/Sources/MacAmbientJevCore/DiarizationEvaluation.swift`
- Create corresponding Swift tests.
- Create: `tools/linux-audio/diarization/pyproject.toml`
- Create: `tools/linux-audio/diarization/nemotron3.py`
- Create: `tools/linux-audio/diarization/speaker_overflow.py`
- Create Python tests.

**Interfaces:**
- Produces common speaker identity: tracked 1...7, other, unknown.
- Produces standard and collapsed diarization metrics.
- Produces Linux Nemotron speaker-span artifact.

- [ ] Write failing tests for tracked IDs 1...7 and rejection of 8+ tracked IDs.
- [ ] Write failing 10-speaker collapse tests: 1...7 tracked, 8...10 OTHER.
- [ ] Write failing tests for UNKNOWN and leakage metrics.
- [ ] Implement portable speaker schema/evaluator.
- [ ] Implement overflow resolver using injected embeddings/similarity so logic is model-testable without NeMo.
- [ ] Add lazy-loaded Nemotron adapter with offline and streaming profile configuration.
- [ ] Run Swift/Python tests.
- [ ] Commit with `feat: add Nemotron diarization evaluation and 7+OTHER policy`.

### Task 6: Issue #6 — Local regression suite

**Files:**
- Create: `scripts/verify_linux_audio.sh`
- Create: `tools/linux-audio/run_suite.py`
- Create: `baselines/.gitkeep` and baseline schema/documentation
- Modify docs/README with local commands.

**Interfaces:**
- Consumes outputs from Tasks 1–5.
- Produces PASS / FAIL / SKIPPED_MISSING_DEPENDENCY summary and backend-specific baseline JSON.

- [ ] Write failing orchestration tests for PASS/FAIL/SKIPPED status aggregation.
- [ ] Implement `--smoke` and `--full`.
- [ ] Ensure full suite does not convert SKIP to PASS.
- [ ] Record model/corpus/evaluator/backend/device metadata in baselines.
- [ ] Run dependency-light smoke suite locally.
- [ ] Commit with `feat: add local Linux audio regression suite`.

## Final Verification

- Run portable verification on Linux.
- Run all dependency-light Python tests.
- Type-check/syntax-check shell and Python entrypoints.
- Verify Core contains no Apple framework imports.
- Verify Mac-only dependencies remain outside Linux runner manifests.
- Review branch diff against Issues #1–#6 and the design spec.
