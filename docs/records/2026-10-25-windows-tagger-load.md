# Windows ClauseTagger・ファイル書込み計測記録（2026-10-25）

この記録は完了した Windows VM / Mac の計測・検証結果と、確認済みの Foundation ファイル書込み経路をまとめる。観測結果は製品受入を意味しない。

## 環境と測定範囲

Mac は arm64 macOS、Apple Swift 6.4（swiftlang-6.4.0.34.1、clang-2100.3.34.1）、空き容量約17 GiB。Windows 11 ARM64 VM は Swift 6.2（swift-6.2-RELEASE）、assertions 有効、`aarch64-unknown-windows-msvc`、4 CPUs、ONNX Runtime 1.31.0。測定前の C: 空き容量は4,403,572,736 bytes。D: は書込み不可の UDF optical media で writable temp ではない。hosted x64 / D: temp の再実行、hosted runtime stack・handle capture、製品 engine 全体の起動時間測定はない。

ClauseTagger model は146,889,562 bytes、SHA-256 `1131898abd272f8bfb6e30828384e875971486cf9ba4f42f464f40b2f1119782`。

## SHA-256 と tagger 初期化

現行 `CSHA256` target は全 configuration・platform で `cSettings: [.unsafeFlags(["-O2"])]` を使う。Swift 側は1 MiB streaming、C 側は連続 block の batched compression。C header と Swift API は `block_count > 0` および non-null block bytes を要求する。448-bit NIST vector の digest `248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1` は Data と chunked file の両方でテストされ、Mac の SHA tests 7件は pass。

| 計測 | 完了済み観測値 |
| --- | --- |
| 以前の debug C `-O0` update hash wall interval（read を除く） | 3.7821706 / 4.2194269 / 3.7041245 s |
| 以前の debug C `-O0` read | 0.430613 / 0.1612265 / 0.1728092 s |
| 以前の debug C `-O0` end-to-end file hash | 4.2284666 / 4.3829624 / 3.8789342 s |
| 以前の actor init | 5.867–6.387 s |
| 現行 `-O2`、`FileSHA256.hexDigest(file)` wall time（read 込み） | 1.169 / 0.939 / 0.949 s |
| 現行 `-O2`、fresh `ONNXClauseTagger` init、`intraOpThreads=4` | 3.006 / 2.390 / 2.530 s |

現行3 trial は同一 model で、別々の時計による非計装の計測。以前の update hash wall interval（read を除く）3.70–4.22 s と現行の read 込み時間は同一 timer scope ではない。比較可能な end-to-end 値では以前3.879–4.383 s、現行0.939–1.169 s。1件の一時 serialized timing test は11.045 sで pass し、計測 source は削除済み。

以前の instrumented debug baseline は9 tests、suite envelope 180.232 s。C kernel 後は同じ3回の load を含む suite が17.930 s。factory reuse 後の filtered run は25 tests / 3 suites、12.499 s（tagger suite 12.497 s）。これらは debug suite 計測であり、厳密な A/B microbenchmark ではない。

過去の standalone optimized hash probe では Swift `-O` が read/hash/total 0.7628062/0.8661351/1.6430774 s、Swift `-O` + C `-O2` が0.4733789/0.8255641/1.3137653 s。hash の差は有意な改善を示さず、read 差も交絡する。過去の graph diagnostic（threads=4、inter-op=1、arena off）は `all` 0.678629167 / 0.499808667 s、`disabled` 0.493157250 / 0.471541125 s。`CreateSession` は deserialization / prepacking を含み、純粋な transformer CPU 時間ではない。ORT C API で graph phase ごとの時間を分離しておらず、profiler による transformer timing もない。通常の測定は ORT default `all`、CPU、optimized cache なし。Silero は arena on、Qwen3ASR・Community1・ClauseTagger は off。release app startup や full engine の before/after は測定していない。

## Windows Foundation atomic write の共有ハンドル再現

Swift 6.2 Foundation Windows の `Data.write` atomic path は [`_wsopen_s(..., _SH_DENYNO, ...)`](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift#L43-L46) で一時 file を開き、[flags](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift#L170-L176) は `_O_BINARY|_O_CREAT|_O_EXCL|_O_RDWR`（`_O_NOINHERIT` なし）。Foundation `Process` は通常の [`STARTUPINFOW`](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.2-RELEASE/Sources/Foundation/Process.swift#L511-L513) と [`CreateProcessW(..., inheritHandles: true, ...)`](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.2-RELEASE/Sources/Foundation/Process.swift#L667-L675) を使い、handle allowlist / `STARTUPINFOEX` は使わない。一方、直接 `Data.write` の [`CreateFileW`](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift#L565-L574) は security attributes が NULL で handle を継承させない。atomic path は親が fd を close して `-1` にした後に [`MoveFileExW`](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift#L389-L399) を呼ぶが、子へ継承された一時 file handle は親の close 後も残り得る。その handle が rename/delete を妨げて Win32 error 32 となる経路であり、fixture reader の遅い close ではない。元の `NSCocoaErrorDomain` 513 / underlying `Win32Error(code:32)` はこの再現と一致する。この経路への production retry / fallback はない。

`missing.f32le` fixture の書込みは capture 開始前に完了する。ただし、同一 test process 内で並列実行される他の tests が `Process` を spawn し、atomic write の一時 handle を継承し得る。以下は `/private/tmp/winvm-p4.lock` 下で、一時 standalone Swift executable によって完了した再現。unique C temp root、同一 `payload.bin` への8 MiB preallocated payload の writer Thread（200 writes、2 ms 間隔）と、`Foundation Process` の child（100回、各 child は handle 4–16384 を4刻みで走査し、inherit flag / final path を調べて200 ms sleep）を並行させた。sleep は probe の scheduling であり製品 retry ではない。

| 条件 | 成功 | error 32 | 経過時間 |
| --- | ---: | ---: | ---: |
| atomic write のみ | 200 | 0 | 4.565 s |
| atomic write と child spawn | 190 | 10 | 31.257 s |
| direct write と child spawn | 200 | 0 | 31.444 s |

child は実在する `.dat.nosync...` temp path を10件出力し、write error は完全な NSError 513 / underlying `FoundationEssentials.Win32Error(code:32)`。child はこれらの path を自ら開いていない。direct-write 条件の出力には一致する継承 file handle がなかった。thread と child の join 後に temp roots を削除した。この結果は相関だけでなく、実際に継承された該当 handle を確認したもの。

## Windows test fixture 書込み監査

次の6 fixture writes は Windows で実行され、non-atomic write を使う。いずれも書込み完了後に reader が検査し、atomic publication 契約はない。

- `app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/WindowsCaptureTestSource.swift:323` — Data float bytes
- `app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionFileProcessingServiceTests.swift:196` — Data input
- `app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ASRSessionEvaluationTests.swift:12` — String reference
- `app/MacAmbientJev/Tests/MacAmbientJevCoreTests/PortablePathTests.swift:69` — String absolute reference
- `app/MacAmbientJev/Tests/MacAmbientJevCoreTests/EventLogTranscriptReaderTests.swift:457` — String completed tamper
- `app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/FinalTranscriptPipelineTests.swift:1188` — String completed fake-ASR corruption

実際の atomic publication tests は変更なし。`WindowsSessionBoundaryTests.swift:70–85` の `windowsAtomicWriteReplacesFileHeldOpenWithShareDelete` と `FLACTimelineReaderTests.swift:725–740` の `flacTimelineKeepsOpenReaderPinnedAcrossRenameAndPathReplacement` は Windows native `SessionFileAccess.writeAtomically` を呼び、Foundation atomic path ではない。他の既存 `SessionFileAccess.writeAtomically` test calls も維持されている。

Foundation atomic write を使う残りの tests は Mac 限定：RuntimeTests の `StorageDiskUsageHarness.swift:216`、`DiarizationFrontendParityTests.swift:679`、`DiarizationParityFixtureTests.swift:87,119,214`、`Community1ONNXStageFixtureTests.swift:217`；AppleSupportTests の `ClauseTaggerParityFixtureSupport.swift:108,109,1258`。共有 `MacAmbientJevVADFixtures/VADParityFixture.swift:98` writer は `RuntimeTests/VADParityFixtureTests.swift:43–46` の唯一の呼出しで、`MAC_AMBIENT_JEV_WRITE_VAD_PARITY` が有効な場合に限られ、Windows tests からは呼ばれない。

## Production write-path 監査

production write path の変更はない。Windows から到達可能な5件の `Foundation.atomic` disk writes は次のとおり。Foundation 6.2 Windows では同一 process が書込み中に child を spawn する場合、一時 handle の継承リスクがある。test process が並列実行中に実際の production export path を通る可能性があり、fixture cleanup は production path の修正にはならない。

- `MacAmbientJevPipeline/SessionFileProcessingService.swift:522` — transcript JSON export（Windows engine から到達）
- `MacAmbientJevTranscribeFile/TranscribeFileCommand.swift:238–239` — primary output、artifact（portable CLI）
- `MacAmbientJevEvaluateASR/main.swift:60` — report（portable CLI）
- `MacAmbientJevEvaluateDiarization/main.swift:69` — report（portable CLI）

Windows engine / portable production targets の Swift・C・C++・header を調査し、child を起動する `Process()` / `CreateProcess` / `ShellExecute` / `posix_spawn` / `popen` / `system` 呼出しは見つからなかった。`GetCurrentProcess` と `AudioHardwareCreateProcessTap` は child creation ではない。test launch sites の例（網羅的ではない）は `WindowsTokenizerMemoryTests.swift:13`、`WindowsSessionBoundaryTests.swift:9,90`、`EngineProcessTests.swift:19`。optional flac CLI interop tests など他の test process 起動もある。handle 継承は process-local で、UI / 親 process が engine 起動後に engine 内で開かれた handle を継承することはない。通常の現行 engine code がこの child-spawn race を発生させるとは確認されていない。一方、Foundation atomic が外部 opener や全 dependency に対して一般に安全だという意味ではない。

Windows の他の file writes も監査した。`DiarizationMeasurement.swift:201,203` は `.withoutOverwriting` の一時 file を直接書いて `moveItem` し、direct `Data` path は non-inheritable。native `SessionFileAccessWindows.writeAtomically`（197–215）および openHandle streams（SessionWriter / events、DurableAudioWriter chunks / checkpoints、SessionBootstrapper manifest、ProcessingMetadata、SessionAudioStorage、EngineSettingsStore、SessionExporter、import / copy、RecordingFLAC、ProcessingTimelineAudioExporter、ApplicationRootLock）は、`CWindowsSession.c:56–58` または `77–91` の `securityAttributes=NULL` / `OBJ_CASE_INSENSITIVE` のみの NtCreateFile attributes から handle を得て、`SHARE_DELETE` を有効にする。追加の inheritable regular-file writer は確認されていない。standard streams / diagnostic pipes は transport で atomic file publication ではない。CMiniaudio は `MA_NO_ENCODING`、read-only borrowed-fd decoder で別 writer ではない。Mac-only `MacAmbientJevCaptureSystemAudio/main.swift:183` の Foundation atomic ready file はこの監査の Windows 到達範囲外。

## 完了した検証

- Mac final build は2.66 sで pass。最終の combined filtered command は25 tests：Pipeline 15件（service 14、corruption 1）と Core 10件（SHA 7、reference 2、tamper 1）、全件 pass。個別の SHA 7 / service 14 / reference 2 / tamper 2 checks も pass。ONNX target は Mac で除外され、Mac ONNX 実行とは扱わない。
- 最終 Windows uninstrumented full run：`winvm test .` はこの round の最初の full attempt で rc=0。1,491 tests / 104 suites pass、console elapsed 220.530 s、ABI single-segment whole-invocation 220.531 s、変更なしの540 s budget pass。`/private/tmp/winvm-p4.lock` は `until mkdir /private/tmp/winvm-p4.lock 2>/dev/null; do sleep 30; done` で取得し、全 repro・timing・final full run の間保持した。削除前に resolved absolute lock path を検証し、lock release は rc=0。Windows build は2.47 s、`MacAmbientJevEngine` product build は2.39 s。injected C safety、checker / fetcher selftests はすべて pass。engine acceptance driver は50 tests / 2.592 s、FLAC validator は8 tests / 0.204 sで pass、deterministic acceptance は `passed`。full-run event envelope は ONNXClauseTaggerTests 182.436 s、factory 0.006 s、`knownMissingExtentAndTrustedRestartPersistDurableGaps` 179.767 s（pass）、NIST vector 152.521 s、FileSHA256Suite 163.311 s。これらの event envelope は並列 scheduling / queue wait を含み、standalone の初期化時間や hash 時間ではない。独立計測した hash と init の startup evidence は上表の0.939–1.169 s と2.390–3.006 s。`flacCLIinterop` の2 tests は `flac` が PATH にないため skip。gated real Qwen3 / Community1 / FullModel tests は未実行で、ungated real ClauseTagger test は pass。
- `python3 scripts/check_test_time_limits.py`、`python3 -B scripts/check_portable_core.py`、`python3 scripts/check_doc_references.py`、`git diff --check` は pass。`Package.resolved` は不変で `git hash-object` は `30e6fc8b3a9db20fed36606ce72a89727f2e5e2a`。test budget 変更なし、audio hardware 未使用。timing / repro temporary sources は削除済み。

## 参照

- Swift Foundation 6.2 `Data` write/atomic implementation: [`Data+Writing.swift:43–46`](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift#L43-L46) (`_SH_DENYNO`)、[`:170–176`](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift#L170-L176) (temp flags)、[`:389–399`](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift#L389-L399) (close / `MoveFileExW`)、[`:565–574`](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift#L565-L574) (direct write)。
- Swift Foundation 6.2 `Process`: [`Process.swift:511–513`](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.2-RELEASE/Sources/Foundation/Process.swift#L511-L513)、[`:667–675`](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.2-RELEASE/Sources/Foundation/Process.swift#L667-L675)。
- Microsoft: [`_sopen_s`, `_wsopen_s`](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/sopen-s-wsopen-s?view=msvc-170)、[`CreateProcessW`](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw)、[`CreateFileW`](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)、[`OBJECT_ATTRIBUTES`](https://learn.microsoft.com/en-us/windows/win32/api/ntdef/ns-ntdef-_object_attributes)。
- [Swift 6.2 release](https://www.swift.org/blog/swift-6.2-released/)、[SwiftPM `CSetting.unsafeFlags`](https://developer.apple.com/documentation/packagedescription/csetting/unsafeflags(_:_:))、[NIST test data](https://www.nist.gov/itl/ai/ai-standards-and-guidelines-group/nsrl-test-data)。
- [ONNX Runtime graph optimizations](https://onnxruntime.ai/docs/performance/model-optimizations/graph-optimizations.html) / [release v1.31.0](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)。
