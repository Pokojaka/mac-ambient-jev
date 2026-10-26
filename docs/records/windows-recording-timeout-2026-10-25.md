# Windows の録音公開テストにおける timeout 計測（2026-10-25）

## 目的と結論

CI で `recordingListPublishesAudioAfterTheFirstDurableChunk` が60秒の `timeLimit` に達した後も、test body の処理時間では説明できない長い経過時間を示した。Swift Testing の並列実行下での scheduler contention が短い hang guard を超過させる現象を、Windows ARM64 VM で修正前に再現した。これは await の wall-clock 経過が処理時間そのものを示さない証拠であり、writer の分単位 tick を待った結果ではない。

修正は5つの test source に限り、短い test-level limits を取り除くか suite の10分 hang guard に戻すもの。assertion と cleanup は維持する。production code は変更していない。録音公開の製品動作が変わったという主張ではない。

## CI と toolchain

- CI job の実ログ: [GitHub Actions run 40181979404 / job 121134749285](https://github.com/Pokojaka/mac-ambient-jev/actions/runs/40181979404/job/121134749285)。実環境は **Windows Server 2022 / `windows-2022` / image `20261022.344.1` / x64**。`windows-latest` ではない。
- この job は全 **1,720 tests / 132 suites** を実行し、全体 **661.317秒**、issue 1件。対象 test は60秒 timeout を報告し、**338.616秒**で失敗した。
- 別途の再現 VM は **Windows 11 ARM64 VM**、Swift **6.2 (`swift-6.2-RELEASE`)**、Testing **6.2 (`3fdabe5392108d8`)**。
- macOS 側での計測環境は Swift **6.4 (`swiftlang-6.4.0.34.1`)**、Testing **2084**。
- ARM64 VM では再現したが、同じ制御負荷を使った x64 VM の再実行はしていない。CI の x64 ログと ARM64 の再現結果を同一環境の測定として扱わない。

## 失敗時の await trace

対象 test は [`EngineApplicationSessionPresentationTests.swift`](../../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationSessionPresentationTests.swift) の `recordingListPublishesAudioAfterTheFirstDurableChunk`。処理順は次のとおり。

1. `prepared`
2. `recording.start` (`start`)
3. `capture.committedCheckpoint()` (`initialCheckpoint`)
4. `listedSession` (`initialList`)
5. `capture.appendSpeech(seconds: 0.25)` (`append .25`)
6. `capture.committedCheckpoint()` (`partialCheckpoint`)
7. `listedSession` (`partialList`)
8. `capture.appendSpeech(seconds: 0.75)` (`append .75`)
9. `capture.committedCheckpoint()` (`committedCheckpoint`)
10. `listedSession` (`committedList`)
11. `recording.stop` (`stop`)
12. `listedSession` (`afterStopList`)
13. `harness.shutdown()` (`shutdown`)

修正前の target ではキャンセルは3回目の `listedSession`（`committedList`）完了前に起きた。失敗後の cleanup は `recording.stop` **1.7628769秒**、直接の `capture.stop` **0.7491184秒**、`shutdown` **0.1945095秒**だった。

## test が待っているもの

`FakeCaptureSession.appendSpeech` は512-frame packet を投入して queue を同期的に drain する。`committedCheckpoint` も現在 queue を drain した後、writer の snapshot を即時取得する。partial chunk の flush や将来の書込み待ちはしない。test は0.25秒分だけでは `committedFrames == 0` かつ session list に音声が未公開であること、さらに0.75秒を加えて0.5秒の durable chunk 境界を越えると committed frame と公開済み音声があることを検証する。ここに wall-clock sleep / polling wait はない。

`listedSession` は `ApplicationHarness.call` を通る。terminal reply は transport thread と MainActor handler を経て `ChangeSignal` で通知され、generation を使って通知の取りこぼしを防ぐ。stop は ring と drain を finish し、VAD sleep / final queue の task を cancel・join する。shutdown は terminal reply 後に controller を終了し、task join を含む。shutdown 中の10ms pause / 最大20秒 poll は測定値を支配していない。これらの await の経過時間には並列 task による MainActor / cooperative scheduling の遅延が累積し得る。

## 修正前の測定

Temporary instrumented target で各 await の前後に `ContinuousClock` mark を置いた。計測コードはすべて除去し、次の値は修正前の Windows ARM64 VM での測定である。値は秒。

| await | Windows isolated | 2 CPU + 2 busy workers | 全 test instrumented run | 強い再現: 1 CPU + 4 busy workers |
| --- | ---: | ---: | ---: | ---: |
| `prepared` | 0.0308906 | 10.9369144 | 14.6184282 | 28.5161382 |
| `start` | 0.0357143 | 2.3931244 | 3.0901179 | 5.387498 |
| `initialCheckpoint` | 0.0000274 | 0.40341 | 0.1849433 | 1.629383 |
| `initialList` | 0.0197742 | 1.2973874 | 0.6755002 | 5.0918937 |
| `append .25` | 0.002606 | 5.3817221 | 1.7169447 | 8.3007469 |
| `partialCheckpoint` | 0.0000218 | 0.3414274 | 0.1441357 | 0.467202 |
| `partialList` | 0.0136461 | 1.3925154 | 1.1303863 | 2.2069747 |
| `append .75` | 0.0117909 | 7.044354 | 4.9984526 | 17.6321719 |
| `committedCheckpoint` | 0.0000261 | 0.0161891 | 0.1004862 | 0.8201659 |
| `committedList` | 0.0161013 | 0.8696534 | 0.5527155 | 完了前に timeout cancellation |
| `stop` | 0.0251229 | 1.9311361 | 1.2414077 | cleanup: 1.7628769 |
| `afterStopList` | 0.0198504 | 0.9818315 | 0.5886944 | — |
| `shutdown` | 0.0518992 | 1.4940631 | 0.8830469 | cleanup: 0.1945095 |

- isolated target は **0.232秒**。filtered test を30回すべて通し、最大観測値は **0.537秒**。同時実行した EngineHost 198 tests は **61.731秒**、target は **19.964秒**。
- 2 CPU affinity mask `3` と2つの busy PowerShell worker では EngineHost 198 tests が **103.949秒**、target が **34.791秒**。表の await 合計は isolated baseline と比べて大きく伸びる一方、全体は60秒未満だった。
- `winvm test .` の全 test instrumented run は exit code 0、**1,720 tests / 132 suites、214.095秒**、target **116.670秒**。測定した body 内の経過は約 **29.926秒**、残る約 **86.744秒**は instrumented body 外。差分を特定の framework / entry / scheduling 区間に帰属させる測定ではない。
- 強い再現では、既に compile 済みの baseline を `--skip-build` で実行し、1 CPU affinity mask `1` と4つの busy PowerShell worker を使用。EngineHost 198 tests / 30 suites は **253.434秒**、2 issues、exit code 1。対象は60秒 timeout を報告し **75.139秒**で失敗。別の lifecycle test `interruptedRecordingWaitsForModelsThenCompletesThroughStartupRecovery` は120秒 timeout を報告し **124.566秒**で失敗した。
- 強い再現の `committedList` は完了せず、timeout cancellation が先行した。表の後半 cleanup 値も含め、同期処理の CPU work がその長さだったという意味ではない。複数 await の scheduler delay が累積した結果である。

同じ suite には await を持たない同期 test の大きな経過時間もあった: `processorPresentationTextPreservesDynamicMessages` **154.635秒**、`forwardsIngressDropoutsWhileCaptureIsActive` **307.554秒**、`progress` **314.304秒**、`interruptedRecording` **389.697秒**、`paused` **390.058秒**。同期 test でも同様の遅延があるため、await / writer tick の仕事量と wall-clock 経過を同一視できない。

## 強い再現の実行方法

共有 VM lock を保持し、既存 baseline を再 build せず、現在の PowerShell invocation が起動した worker だけを `finally` で停止する。cleanup が失敗すれば非ゼロで表面化する。再現実行同士を並列にせず、この invocation が終了して lock が解放されるまで待つ。

```bash
( lock=/private/tmp/winvm-p4.lock; until mkdir "$lock" 2>/dev/null; do sleep 30; done; trap 'rmdir "$lock"' EXIT; winvm run . -- '$ErrorActionPreference="Stop"; $busy=@(); try { [Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity=[IntPtr]1; for($i=0;$i -lt 4;$i++){ $busy += Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -Command `"while (1) { }`"" -PassThru }; $ErrorActionPreference="Continue"; swift test --skip-build --package-path app/MacAmbientJev --filter EngineHost; $rc=$LASTEXITCODE } finally { foreach($p in $busy){ if(-not $p.HasExited){ Stop-Process -InputObject $p -Force -ErrorAction Stop; $p.WaitForExit() } } }; exit $rc'; rc=$?; exit "$rc" )
```

別の process をまとめて停止する処理ではない。実験の before-fix await 値は一時 instrumentation を使った別 run の結果であり、この再現 command 自体が instrumentation を追加するものではない。

## 変更の根拠と適用範囲

Swift Testing の Swift 6.2 実装では継承された `timeLimit` の最短値が適用され、suite trait は test に適用される ([pinned `TimeLimitTrait.swift`](https://raw.githubusercontent.com/swiftlang/swift-testing/swift-6.2-RELEASE/Sources/Testing/Traits/TimeLimitTrait.swift))。標準では test が同一 process 内の parallel task groups で実行される ([pinned Parallelization documentation](https://raw.githubusercontent.com/swiftlang/swift-testing/swift-6.2-RELEASE/Sources/Testing/Testing.docc/Parallelization.md)、[Swift Testing 6.2 release](https://github.com/swiftlang/swift-testing/releases/tag/swift-6.2))。このため、短い per-test limit を suite の10分 hang guard より優先するのは、負荷時の scheduling 遅延を誤って test deadline とみなす。

変更対象の test source は5ファイルのみ。対象 test は10分 suite guard を継承し、WindowsEngineCapture suite は10分を維持して短い個別 limit を除去し、progress / paused / lifecycle の suite limits は2分から10分へ戻す。assertions と cleanup は維持する。既存の待機は signal / terminal reply / cancellation-aware lifecycle を使っており、production wait や製品挙動を変える修正ではない。

## 限界

- 強い再現と await の細分化は Windows 11 ARM64 VM の値。CI の Windows Server 2022 x64 では同じ CPU affinity / busy-worker 制御の再実行をしていない。
- Instrumented run は各 await に境界を置いたが、body 外の差分を正確な実行区間へ割り当てていない。よって約86.744秒の所在を断定しない。
- 同期 fake packet drain / committed snapshot は capture hardware、WASAPI、実音声や実時間録音の性能測定ではない。
- ここで示す timeout はテストの hang guard と scheduler contention の診断であり、製品の録音時間・性能・公開契約を測定するものではない。
