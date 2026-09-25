# V1 完了検証の実装設計

この文書は [`V1 完了検証の実行計画`](../plans/2026-09-24-v1-completion.md) を実装する担当者向けの設計である。既存の振る舞いと新たに実装する契約を区別する。実音声は Git 管理外の `test-data/recordings/local/` に置く。マイクは使わず、Jev への実通信はアプリの設定画面でキーが入力された後だけ行う。ユーザーの指定により注釈付き golden corpus と誤除外精度の評価は今回行わない。

## 先に確かめる事実と未決定事項

- 対象の保存済みセッションは `31AC3491-986E-4F0A-8697-E9181B0910D4`。`events.jsonl` では `seg_000382` の範囲が `[190344768, 191016768)`、`seg_000383` が `[191016768, 191016960)`、`seg_000384` が `[191098176, 191770176)` フレームである。48 kHz なら382は14秒、383は4ミリ秒。`SegmentationAssembler.splitIfNeeded` は14秒で区間を確定した後、同じ発話の開始位置をその終端に進める。383は382を14秒で分割した直後の端数と整合する。ログには VAD の終了イベントそのものはないため、`speechEnded` と入力終端の `finish` のどちらで確定したかまでは断定しない。VAD が独立した4ミリ秒の発話を検出した、と説明しない。
- 現行の `SegmentationAssembler.speechEnded` は20ミリ秒未満の端数を新たな区間として出さない。保存済みの383は変更前に作られたイベントなので残る。`NativeQwen3ASREngine.transcribe` はこれを空文字で完了させ、MLX に渡さない。この完了は「4ミリ秒の発話を書き起こした」という意味ではない。端数を別の発話として認識させるために Whisper を追加しない。原音声と382のイベントは維持し、復旧前後で383の範囲、文字列、重複イベントの有無を検証する。
- `SessionRecoveryScanner.pendingSessions()` はイベントログ末尾の不完全行を切り詰める可能性がある。対象セッションの解析前に複製とハッシュを取る。セッション一覧を走査する前に、アプリの自動復旧を含む別の書き手が動いていないことを確認する。

## 1. CLI の二つの入力経路

対象ファイルは `app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift`。現状の引数は `[--keep-session] [--low-heat] <audio-file> [segments.json]`。`--keep-session` がなければ終了時にセッションを削除する。復旧は既存のセッションを対象にする別経路を加える。

```text
MacAmbientJevProcessRecording [--keep-session] [--low-heat] <audio-file> [segments.json]
MacAmbientJevProcessRecording --resume-session <UUID> --sessions-root <path> [--low-heat] <segments.json>
MacAmbientJevProcessRecording --inspect-session <UUID> --sessions-root <path>
```

計測する場合は import または resume に `--run-id <id> --metrics-output <path> --thermal-output <path> --memory-output <path>` を全て追加する。

`--inspect-session` は後述の復旧計画と件数を JSON で標準出力へ書き、セッションを変更しない。現状の `pendingSessions()` は全セッションを走査し、不完全なイベントログ末尾を修復する。CLI 用には指定 ID のディレクトリだけを開く `inspect(sessionID:)` を追加し、末尾の不完全行をメモリ上で除いた解析結果を返す。inspect の前後で対象の `events.jsonl` と metadata のハッシュが一致することを確認する。resume もこの対象限定の解析結果を使い、`pendingSessions()` を呼ばない。resume で末尾修復が必要なら、対象セッションを複製してから、対象の `events.jsonl` だけを明示的に修復する。他のセッションは読み書きしない。`--resume-session` はセッションを保持する。`--resume-session` と音声ファイル入力、`--inspect-session` と音声ファイル入力を同時に指定したら使用方法エラーにする。通常入力と同じ場所に勝手に manifest を生成しない。出力ファイルと元のセッションを削除しない。

引数の解釈は CLI 境界の `enum RecordingInput { case importFile(URL, URL, Bool, ASRPacingMode); case inspectSession(UUID, URL); case resumeSession(UUID, URL, URL, ASRPacingMode) }` で一度だけ行う。inspect と resume は `--sessions-root` を必須とし、セッション ID は UUID として parse して指定 root の直下に組み立てる。任意のセッションディレクトリパスは受け付けない。指定 root を scanner と processor の両方へ渡し、実データを複製した root とアプリの通常 root を取り違えない。`session.json` の ID と指定 ID が一致し、`sourceKind == .importedFile`、processing checkpoint が存在することを確認する。CLI からライブ録音の復旧を始めない。

`--resume-session` は対象 ID の解析結果から `RecoverableSession` を組み立て、`source == .processingTimeline` に限って `action` を実行する。`resumeASR`、`selectCompletedASR`、`runDiarization` はそれぞれ既存の `NativeSessionProcessor` メソッドを呼ぶ。`reprocess` は今回のコマンドでは拒否し、全量再処理を暗黙に開始しない。`retryContentPriority` は Jev の承認条件と実行環境が別なので拒否する。対象に未完了 action がないときは同じ対象限定の解析結果と `processing_metadata.json` を使い、すでに scope まで完了していれば成功済み出力を生成し、それ以外は理由付きで失敗する。再実行で ASR を重複させない。

出力の `[MaterializedTranscriptSegment]` は `ProcessingMetadataStore.load()?.activeRuns` と `EventLogTranscriptReader.events(lines:activeRuns:)` を使用して作り直す。復旧直後に採った `onUpdate` の配列は最終段階の反映を保証しないため、最終 `activeRuns.scope` と処理状態を確認してから `segments.json` を atomic write する。新規 import 経路もこの書き出し規則に合わせる。途中失敗では最後の正常な active run を保持し、成功ファイルを上書きしない。極短端数を除外する規則は後述の通り materialization と export の両方に適用する。

変更箇所は CLI の引数解釈と実行、`NativeSessionProcessor.resumePendingASRSession` の `pacingMode: ASRPacingMode` 引数、復旧側の `PipelineCoordinator(..., pacingMode: pacingMode)`、`tools/process-recording.swift` のフラグ転送と使用方法。後段の成功判定を曖昧な status 文字列から推測せず、CLI 向け processor メソッドは最終 `disposition`、`sessionID`、この起動で得た `ASRBatchMetrics?`、失敗理由を含む結果を返す。アプリ側は `.normal` を明示して呼ぶ。計測実行用に `--run-id <id> --metrics-output <path> --thermal-output <path> --memory-output <path>` を CLI に追加し、4引数は全て指定するか全て省略する。指定されたときは成功・失敗・一時停止のいずれでも run ID と結果を `engine-metrics.json` へ atomic write する。測定スクリプトは4引数を必ず渡し、メトリクスファイルが欠けるか解読できなければ計測 run を失敗として記録する。

検証は fake ASR fixture で4つの経路を分ける。pending のみを一回ずつ投入し、既存の `asr.completed` の ID 集合に新規完了が混入しないこと、完了済み ASR の後段だけを実行すること、失敗後も active run を保持すること、2回目の resume が二重処理しないことをイベントログと `segments.json` で確認する。`--resume-session` が音声ファイルを指定された場合には起動前に失敗する CLI テストも加える。

## 2. 14秒分割後の端数処理

`SegmentationAssembler` は `splitIfNeeded(atFrame:)` で14秒の上限に達すると、その位置を次の開始 frame にする。直後の `speechEnded(atFrame:)` がこの開始位置から20ミリ秒未満なら新規区間を出さない。修正済みの `SegmentationTests.swift` には、元の382と383と同じ frame 範囲を使って14秒区間だけが作られるテストがある。

復旧時の383は既存の `asr.pending` のままなので、モデル入力境界で空文字の `asr.completed` を一件書いて処理済みにする。382は再投入せず、383を理由に382の本文や区間 ID を書き換えない。元のイベントを削除せず、原音声も保持する。現行の `TranscriptMaterializer` は空文字の `asr.completed` も区間として出すため、同じ segmentation run の `segment.created` から計算した長さが20ミリ秒未満かつ ASR 本文が空の区間は materialization で除外する。空文字だけ、または短時間だけを理由に他の区間を除外しない。ライブ表示と `segments.json` の両方にこの規則を適用する。

テストは3箇所で行う。`SegmentationTests.swift` は14秒区間と4ミリ秒端数を入力し、端数の `SegmentReference` が作られないことを確認する。`ASRIntegrationTests.swift` と実セッション復旧は、保存済みの端数が MLX を呼ばずに完了し、完了済み382の ASR イベントが増えず、pending が残らないことを確認する。`MaterializerTests.swift` と復旧後の実 `segments.json` では、383のイベントが保存されても383が独立した出力区間にならず、本文のある短い区間は保持されることを確認する。この結果から音声全体の書き起こし精度までは推定しない。

## 3. 実行計測のデータ形

`PipelineCoordinator` に `ASRBatchMetrics` を作り、`PipelineBatchResult` に含める。値は `modelLoadSeconds`、`asrCallSeconds`、`processedAudioSeconds`、`pacingWaitSeconds`、`pacingWaitCount`、`initialPendingCount`、`maximumPendingCount`、`oldestPendingAgeSeconds`。`ContinuousClock` で `prepare()`、`transcribe()`、`sleep` を挟んで別々に計測する。`asrCallSeconds` には loader と VAD、待機、モデル準備を入れない。`processedAudioSeconds` は実際に ASR へ渡した frame 数と sample rate から計算し、`asr_rtf = asrCallSeconds / processedAudioSeconds` とする。処理全体の所要時間を `wall_seconds` として別に残す。ASR バッチ外のモデル読み込み時間も `modelLoadSeconds` に分ける。

`asr.pending` の `event_seq` と `created_at` から最古 pending の発生時刻を決める。対象セッションの実ログには `created_at` がある。完了済み ID を除いた集合について区間境界ごとに最大待機時間を計算する。既存の imported-file バッチで pending を一括保存した結果を「ライブ入力の滞留時間」と呼ばない。`initialPendingCount` は復旧前 pending の数、新規 batch の queue depth は保存後の未完了数とする。途中失敗した区間は成功済みとは数えない。

CLI はプロセス内の `ProcessInfo.processInfo.thermalState` を5秒間隔で読み、`--thermal-output` で指定された `thermal.jsonl` に `{timestamp, state}` を書く。最初と最後の状態も記録する。熱状態が `critical` に達したら新しい ASR 区間を始めず、`processing.run.completed` を成功として書かないで一時停止する契約を加える。具体的には `PipelineCoordinator` の区間境界で注入した停止判定を読み、`PipelineBatchResult` の `disposition` を `completed`, `failed`, `paused` で返す。`NativeSessionProcessor` は `paused` では `selectSuccessfulRuns` と後段を実行しない。pending はイベントログに残す。現状の `failedCount == 0` だけによる成功判定をそのまま使わない。外部からの `SIGSTOP` は使わない。

実測できる総メモリは `/usr/bin/time -l` の最大 RSS と peak memory footprint、プロセス内で採る footprint の時系列を区別する。CLI は最初、最後、実行中5秒ごとに自身の `phys_footprint` を記録し、`--memory-output` で指定された `memory.jsonl` の各行に run ID、UTC 時刻、処理段階、footprint bytes を書く。計測失敗は `null` と理由を記録する。別プロセスの thermal サンプルやメモリを対象プロセスの値として書かない。温度の絶対値は thermal state から推定しない。ASR 以外の diarization 完了時刻、scene 変更件数はログとイベントから導出する。メモリ増加はモデル読み込み後の ASR 段階の時系列で判定し、開始・終了値だけで推測しない。

CLI の最終 status と ASR 計測はセッションの transcript event に混ぜず、`--metrics-output` が指定する `engine-metrics.json` に出す。外側の `scripts/measure_v1_run.sh` は一度ビルドしたバイナリを実行し、このファイルと `/usr/bin/time -l` の結果を検証して `run.json` に統合する。スクリプトは exit code、録音の尺、`git rev-parse HEAD`、`git diff` の SHA-256、入力とイベントログのハッシュ、開始・終了の UTC 時刻、出力パス、ビルド構成を run ID ごとに記録する。JSON の `asr_rtf`, `oldest_pending_age_ms`, `peak_memory_mb` は計測不能なら `null` と `unavailable_reason` にする。再開 run の ASR 時間と RTF はその起動で実行した区間だけを対象とし、過去の未計測分を含む録音全体の RTF として報告しない。`--low-heat` は待機を ASR 完了イベントの保存後に置き、最終区間の後は待機しない。

`run.json` の値には単位を含むキーを使う。想定形は `{"run_id":"...","corpus_id":"...","session_id":"...","input_sha256":"...","exit_code":0,"status":"complete","metric_scope":"this_invocation","wall_seconds":0.0,"asr_call_seconds":0.0,"processed_audio_seconds":0.0,"pacing_wait_seconds":0.0,"asr_rtf":null,"maximum_pending_count":0,"oldest_pending_age_ms":null,"peak_memory_mb":null,"memory_growth_mb":null,"unavailable_reason":{}}`。数値の `0.0` は形を示す例で、実測値ではない。中断なら `status` は `paused` とし、成功時と同じ `exit_code:0` にしない。`thermal.jsonl` と `memory.jsonl` の各行は同じ run ID と時刻を持つ。

長時間メモリ判定は M4 16 GB 実機の run ごとに行う。モデル読み込み終了後の ASR 段階で最初と最後の重ならない各5分間の `phys_footprint` 中央値を比較し、増加が512 MiB以下、かつ `/usr/bin/time -l` の peak memory footprint が12 GiB以下なら VERIFIED とする。5秒周期の有効サンプルが各窓で48件未満、両窓が重なる、段階が判別できない、または途中失敗した run は INCONCLUSIVE とし、開始・終了値だけで合格にしない。閾値超過は失敗として実測値を残す。

テストでは fake clock と sleep を注入する。2区間の fake ASR のそれぞれの計測時間、完了イベントより後の1回だけの待機、待機を含まない RTF、critical で pending が残ること、復旧時も同じ pacing が適用されることを確認する。計測用4引数の一部だけを指定した場合は起動前に失敗させる。CLI の成功・失敗・一時停止で `engine-metrics.json` が生成され、スクリプトが欠落ファイルを失敗として扱うことも確認する。長時間の実モデル入力では計測行とイベントログの完成数、および5秒周期のメモリ記録を突き合わせる。

## 4. 試験データと順序

1. 事前確認。残容量、熱状態、保存済みセッションの複製先容量、競合するアプリやモデル処理を調べる。事前の実行ログ、作業ツリー差分のハッシュ、依存解決ファイルを run ID に固定する。`--inspect-session` の修正経路を整えるまで元セッションを scanner に渡さない。
2. 短時間試験。`_smoke/audio.wav` を通常と `--low-heat` で別セッションに処理する。本文、処理された区間数、経過時間、ASR 時間、待機時間、熱状態を比較する。文字起こしが異なる場合は差分を残し、自動合格にしない。
3. 討論抜粋。15〜33分のファイルを `--keep-session --low-heat` で処理する。`segments.json`、active run、scene event、thermal.jsonl を保持する。失敗時には保存済みセッションの action を点検する。
4. 保存済み復旧。コピーの `events.jsonl`、checkpoint、metadata のハッシュを保存する。復旧プランの pending と completed の ID 集合を保存し、交差が空であることを確認する。382の14秒分割と383の端数を確認してコピー上で先に復旧する。コピーと本体を同時に実行しない。本体で検証する場合も開始前に再度バックアップを取る。
5. 残りの約84分。短時間、抜粋、コピー復旧の各ゲートに通った後で1本だけ処理する。終了後に `run.json`、イベント、`segments.json` を突き合わせる。critical による一時停止は失敗や成功として丸めない。熱が落ち着いた後に保存済みセッションから再開する。

実行例は以下の形にする。`measure_v1_run.sh` は未実装であり、`--id`, `--audio`, `--output` をこの設計に従って追加する。録音ごとにコマンドを一回実行し、前の run が終了してから次を始める。

```bash
swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevProcessRecording
bash scripts/measure_v1_run.sh --id 20251017_security_discussion_15to33 --audio test-data/recordings/local/20251017_security_discussion_15to33/audio.mp3 --output test-data/recordings/local/20251017_security_discussion_15to33/segments.json --low-heat --keep-session
bash scripts/measure_v1_run.sh --id 20260119_080630 --audio test-data/recordings/local/20260119_080630/audio.mp3 --output test-data/recordings/local/20260119_080630/segments.json --low-heat --keep-session
```

復旧時は `--audio` の代わりに `--resume-session 31AC3491-986E-4F0A-8697-E9181B0910D4 --sessions-root <複製セッションの親ディレクトリ>` を使う。script は `swift build --package-path app/MacAmbientJev -c release --show-bin-path` で実体を見つける。実行中に `swift run` を呼ばず、別の Swift ビルドも行わない。終了コードと `segments.json` の有無を確認した後に次へ進む。

run ID は `<recording-id>-<UTC timestamp>` とする。各 run の `engine-metrics.json`、`thermal.jsonl`、`memory.jsonl`、`run.json` と成功した `segments.json` のコピーは `test-data/recordings/local/<recording-id>/<run-id>/` に置く。`--output` のファイルも保存するが、比較と判定には run ID に結び付いたコピーを使う。既存セッションのコピーも同じ Git 管理外の領域に置き、コピーの manifest ID と格納ディレクトリ ID の整合を維持する。`--sessions-root` から指定 root を scanner と processor に注入する。既存の app sessions root にコピーを戻して自動復旧と競合させない。

## 5. 結果の判定

討論抜粋と長時間録音は、処理完了、復旧、処理時間、メモリ、熱状態の確認に使う。注釈の作成、`GoldenCorpusEvaluator` の変更、用語保持率、誤低優先度、誤背景の合否判定は今回行わない。既存の `manifest.json` と `docs/evaluation.md` は残すが、これらの指標を合格として報告しない。`docs/v1-acceptance-results-2026-09-23.md` には、元の設計の評価項目を今回省いたことと、そのために判定できない範囲を記す。

## 6. 実装を進める順序と終了条件

| 単位 | 実装ファイル | 先に証明すること |
| --- | --- | --- |
| A. CLI 引数と read-only inspect | `MacAmbientJevProcessRecording/main.swift`, `SessionRecoveryScanner.swift` | inspect と resume は指定 ID 以外を読まない。inspect で元のイベントログが不変。 |
| B. 復旧入口と出力 | `NativeSessionProcessor.swift`, `PipelineCoordinator.swift`, `Materialization.swift`, CLI | pending だけを実行し、最後の active run を材料に最終結果を export。383を出力区間にせず、再実行で ASR 重複なし。 |
| C. 計測と中断 | `PipelineCoordinator.swift`, CLI, `scripts/measure_v1_run.sh` | ASR と待機の時間を分離し、メトリクスを CLI からスクリプトへ渡す。5秒ごとにメモリを記録。critical の区間境界で停止して pending を保持。 |
| D. 実データ | Git 管理外の各 run、`docs/v1-acceptance-results-2026-09-23.md` | 各段階のゲートと理由を記録。注釈付き評価、マイク実機、キー未設定の Jev は NOT VERIFIED。 |

各単位で対象の Swift テスト、必要な CLI 実行、`git diff --check` を通してから次へ進む。`RUN_MODEL_TESTS=1` の全検証はコード変更がそろった後に一回実行する。処理中は別のビルドやモデル処理を起動しない。長時間 run の証拠を `test-data/recordings/local/_v1-run/decisions.tsv` から参照できるようにする。
