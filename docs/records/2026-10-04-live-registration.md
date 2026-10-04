# 2026-10-04 — Pending-only live registration

## Scope and method

B1 uses a `LiveASRSession`-local materialized-row array and pending progress derived from registered/finished ID counts. New pending references and duplicate registration do not materialize recognized rows or allocate a set difference. ASR completion and content-priority application, including active-run changes, refresh rows. Public API shapes, durable-before-visible ordering, offline materialization, Jev held-row behavior, and AppState queue ownership are unchanged.

Baseline evidence is preserved in [the reproduction record](2026-10-04-bug-hunt.md), from reproduction commit `e328886`. No baseline rerun was used. The unchanged measurement function was run in the same default Swift debug configuration:

```bash
swift test --package-path app/MacAmbientJev --filter bugHuntMeasureLiveRegistrationCost
```

Five-second event cadence; 120, 720, and 2880 pending IDs; setup excluded; seven samples of 100 duplicate registrations per size. Values are median microseconds per call, not inference or recognized-row projection latency.

| Equivalent history | Pending count | Before median (µs) | After median (µs) |
| --- | ---: | ---: | ---: |
| 10 minutes | 120 | 110.97875 | 0.93959 |
| 1 hour | 720 | 629.62458 | 1.03292 |
| 4 hours | 2880 | 2542.80125 | 0.98541 |

The 4-hour median is below 50 µs and is 1.04877× the 10-minute median, below 3×. The measured 4-hour reduction is approximately 2580×. Both criteria passed on the first isolated run; no timer-noise repeat was required. No permanent timing assertion was added. Whole-transcript recognized-update optimization and live queue retention are outside this measurement and this fix.

## Sequential verification

All commands ran from the worktree root, with one heavy command at a time:

```bash
swift test --package-path app/MacAmbientJev --filter 'liveASR|liveRows|liveAuthorization|stoppingRecordingCancels'
swift test --package-path app/MacAmbientJev --filter bugHuntMeasureLiveRegistrationCost
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev
python3 scripts/check_doc_references.py
```

- Targeted run passed: 15 Runtime tests (including parameterized registration/completion append faults and Jev gating) and 3 Core thermal-policy tests.
- Swift build and the full Swift suite passed. None of the named Swift reproduction failures remained in this checkout. Real-model ASR smoke was skipped; no real models, capture, GUI launch, or permission prompts were used.
- The full suite's concurrently scheduled test functions also emitted medians 1.3925 / 1.135 / 0.95916 µs at 120 / 720 / 2880 pending IDs. These are not substituted for the isolated acceptance measurement.
- Existing build warnings included the MLX bundle mutated-node warning; the first targeted build also reported unrelated diarization isolation and transcript-view test actor-isolation warnings.
- Documentation reference check passed.

A throwaway standalone Swift executable compiled the changed `LiveASRSession.swift` against the built Core library, not the test runner:

```bash
swiftc -parse-as-library -I app/MacAmbientJev/.build/out/Products/Debug -L app/MacAmbientJev/.build/out/Products/Debug -lMacAmbientJevCore app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveASRSession.swift /tmp/luna-live-registration-smoke.swift -o /tmp/luna-live-registration-smoke
/tmp/luna-live-registration-smoke
```

The synthetic executable observed an actual writer error with `events.jsonl` replaced by a directory, proved snapshot/counters unchanged after the failed failure append, restored the log, persisted an ASR failure, and finished idempotently with counts completed=1 / failed=1 / pending=0. It also exercised duplicate/new pending registration after recognized text, immutable prior rows, ASR completion, priority application and active-run replacement. The durable event order was exactly `segment.created`, `asr.completed`, `segment.created`, `asr.failed`, `processing.run.completed`. Its source, executable, audio, and event-log fixtures were removed after verification.

Core and Python source/tests were not changed; portable-Core and Python tests were not rerun for this piece. No Python repro status is inferred from the Swift results.
