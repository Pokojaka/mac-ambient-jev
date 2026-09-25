# 低遅延文字起こしと話者ターン確定処理の設計

## 目的と確定した要件

- 録音中は Qwen3-ASR を使い、モデル準備済みの環境で発話開始から最初の文字表示まで 1〜3 秒を目標にする。
- 録音中の話者分離は行わない。録音中の文字は「暫定」として更新できる。
- 録音停止後は保存した原音声の時間軸に対して先に offline diarization を行い、話者ターンで ASR 入力を分割してから Qwen3-ASR で確定する。確定結果が暫定結果を置き換える。
- 異なる話者の連続発言を単一話者の一行として扱わない。
- 個別表示は発話時間の長い 4 話者まで。5 人目以降は「その他」。話者が推定できない区間は「話者不明」。超過した人の音声や文字を捨てない。
- 新規録音と読み込み音声の両方を対象にする。保存済みセッションはユーザーが選んだときだけ同じ確定処理で再処理する。
- 検証のために新規録音やユーザーによる動画再生を求めない。既存の保存音声を使う。

## 現行コードで確認した原因

`AppState` は 1 秒ごとに durable checkpoint を読み、`LiveVADSession` の `emittedSegments` だけを ASR キューに入れる。`SegmentationAssembler` が発話を確定する条件は無音または 14 秒の最大長である。このため長い連続発話は最初の表示まで長く待つ。`LiveTranscriptView` は `row.speakers.first` の ID しか表示せず、複数話者の span を持つ既存行でも先頭話者に見える。現行の確定経路は VAD → ASR → diarization であり、ASR 入力に複数話者を含む。

会話の話者交替には約 0.2 秒前後の短い間隔が多い。これは話者判定に使える固定しきい値ではない。現行 VAD の `minSilenceSeconds = 0.75` では短い交替が一つの VAD 区間に入るので、**VAD 区間を話者ターンと見なさない**。0.75 秒を 0.2 秒へ機械的に変更せず、offline diarization の独立した話者境界で分割する。参照: [Stivers et al., PNAS 2009](https://pmc.ncbi.nlm.nih.gov/articles/PMC2705608/)、[Levinson and Torreira, Frontiers in Psychology 2015](https://pmc.ncbi.nlm.nih.gov/articles/PMC4464110/)。

## 処理フロー

```text
マイク入力 → durable audio chunks ─┬→ VAD の開いた発話範囲 → 最新 snapshot の Qwen → 暫定 UI
                                  └→ 録音停止 → offline diarization → VAD と話者境界の交差
                                                               → 区間ごとの Qwen → scene/scope
                                                               → activeRuns を一括公開 → 確定 UI

読み込み音声 → processing timeline → VAD → offline diarization → 以下同じ
保存済みセッション → 「再処理」 → 保存音声 → VAD → offline diarization → 以下同じ
```

### 1. ライブ暫定文字

1. `SegmentationAssembler` は確定済み segment に加えて、現在開いている発話の `startFrame` を読み出せるようにする。`FluidVADSegmentationEngine`、`FluidVADTimelineProcessor`、`LiveVADSession` は `OpenSpeechRange(startFrame, endFrame)` を伝える。`endFrame` はその時点の **durable** checkpoint 以下に限る。
2. VAD が発話開始を通知し、少なくとも 0.8 秒の確定済み音声がある時点で最初の snapshot を依頼する。同じ発話では直近の依頼から 2.0 秒以上経過した場合に更新する。1 発話につき実行中は最大 1 件、待機中は最新 snapshot 1 件に上書きし、古い snapshot の待ち行列を作らない。
3. `LivePartialASRSession` は `ASRAudioLoader` で `startFrame..<endFrame` を読む。Qwen 呼び出しは既存の `ASREngine` actor に一本化する。録音開始時のモデル準備を継続し、準備完了前は「モデル準備中」を表示する。
4. 暫定結果は `{sessionID, utteranceID, snapshotEndFrame, text}` を `LiveTranscriptViewModel` のメモリに保持し、同じ `utteranceID` の行を上書きする。`utteranceID` は VAD の発話開始時に決まる安定 ID。暫定文字と snapshot は `events.jsonl` に書かない。
5. 確定済みライブ VAD segment が届いたら、その発話に対応する暫定行を消し、既存の `LiveASRSession` が保存した完了 segment を暫定表示する。停止後の offline 結果が完成した時点で、ライブ側の全行を新しい active run の行で一括置換する。
6. 録音停止・セッション切替時は世代番号を進める。遅れて帰った Qwen 結果は `{sessionID, generation, utteranceID}` が一致しなければ表示しない。モデル呼び出しは途中中断できると仮定しない。

目標値は推論時間を含む実測で判定する。1 秒 chunk と 1 秒 polling のため、入力確定を待つ時間が遅延の下限になる。既存の発話入り音声を原速で durable timeline に順次供給する replay harness を用い、ライブ VAD・snapshot ASR・UI 更新の経路を検証する。これで測れるのは durable timeline 以降の遅延であり、マイク機器からの入力遅延は含まない。P95 が 3 秒を超える場合は測定を出し、poll 周期・chunk 長・snapshot 間隔を計測に基づき調整する。モデルの無断変更はしない。

### 2. 話者ターン分割

`SpeakerTurnSegmenter.split(vadSegments: [SegmentReference], speakerSpans: [SpeakerSpan], segmentationRunID: String, totalFrames: Int64) throws -> [SpeakerTurn]` を Core に追加する。`SpeakerTurn` は `segment: SegmentReference` と `speakerIDs: [String]` を持つ。入力はフレームで扱い、`[startFrame, endFrame)` の半開区間で統一する。

1. VAD 区間は `0 <= start < end <= totalFrames`、入力 VAD run ID の一致、segment ID の重複なしを検証し、違反ならエラーとする。speaker span は `start < end` を検証し、`0..<totalFrames` にクリップする。クリップ後に空になる span は無視する。
2. 各 VAD 区間の開始・終了、および内部にある speaker span の開始・終了を境界として昇順に並べる。隣り合う境界の間に活動する話者 ID の集合を計算する。
3. 同一話者集合の隣接小区間を結合する。異なる話者集合をまたいで結合しない。話者集合が空なら `話者不明` 相当の空集合のターンとして保持する。重なり発話は複数 ID の集合として保持し、一人へ決め打ちしない。
4. 元の VAD 区間のフレーム範囲は分割後ターンの和集合と一致させる。VAD 区間間の無音は対象にしない。各ターンに新しい run ID と時系列連番の `segmentID` を付ける。元のライブ run と ID を再利用しない。
5. 各ターンを Qwen に個別入力する。短いターンも黙って落とさない。ASR が空文字なら空文字の `asr.completed` を保持し、Materializer はその行を残し、UI で「聞き取れませんでした」と表示する。ASR 呼び出し自体が失敗したら確定 run を公開せず、失敗した区間数と理由を状態に示す。短区間を隣の別話者へ混ぜて補う処理は行わない。

重なり発話の単一マイク音声には二人分の声が物理的に混在するため、diarization だけでは声源分離はできない。この場合は複数話者として明示し、各人の発言を正確に分けられたとは表示しない。

### 3. 話者表示の上限

`SpeakerDisplayMapper` は raw `SpeakerSpan` を話者 ID ごとに集計する。各 ID の重複 span は union して発話フレーム数を一度だけ数える。降順の発話時間、同点なら最初の開始フレーム、なお同点なら raw ID の辞書順で順位を決める。上位 4 ID に `話者1`〜`話者4` を割り当て、残りを `その他` とする。raw ID がないターンは `話者不明`。重なりターンにはラベルを複数表示する。表示順位の変更は確定処理全体が終わったときだけ反映する。`speaker.span` イベントには raw ID を保持し、ラベルは表示 projection で計算する。

### 4. 確定処理と公開の原子性

`NativeSessionProcessor` に `processFinalTranscript(sessionID:checkpoint:source:onStatus:onUpdate:)` を設け、録音停止・読み込み・手動再処理の共通入口にする。`source` は保存済み processing timeline または import 済み原音声から構築した timeline とし、UI のファイル URL を再読みに行かない。

1. 開始時に `FinalizationAttempt {attemptID, state: running}` を `processing_metadata.json` に記録する。旧 `activeRuns` は変えない。既存メタデータにはこの optional フィールドがないため、読み込み時は `nil` として扱う。これはユーザー指定の旧録音再処理に必要な読み込み互換である。
2. 既存の VAD run を使える停止後の録音でも、確定処理は新しい VAD run を作り直す。これによりライブ失敗や max 14 秒で分割された区間から独立した同一処理を、録音・読み込み・再処理へ適用できる。
3. 原音声を CAF に export → offline diarization → `speaker.span` と diarization 成功イベントを記録 → `SpeakerTurnSegmenter` → 新しい `segment.created` と `asr.pending` → Qwen → ASR 成功イベントを記録 → scene → scope。Jev は任意の後段で、失敗時もローカルの確定結果を公開できる。
4. mandatory なローカル段階がすべて成功したら、一つの `ActiveRuns(segmentation, asr, diarization, scene, scope, contentPriority?)` を `ProcessingMetadataStore.save` の atomic write で公開し、`FinalizationAttempt.state = complete` と同時に保存する。途中で各 stage の select helper を呼ばない。
5. 途中失敗は `FinalizationAttempt.state = failed` と理由を保存し、旧 `activeRuns` を維持する。初回録音で旧 run がなければ保存済みライブ ASR run を暫定成果として選択してよいが、scope/diarization 付きの確定結果としては表示しない。表示とステータスに失敗を示す。
6. `SessionRecoveryScanner` は `running` の attempt を見たとき、保存音声から新しい attempt を再処理キューへ入れる。`failed` は自動無限再試行せず、UI から手動再処理可能にする。旧セッションの従来 recovery action は `finalization` フィールドがない場合だけ従来どおり扱う。

`ActiveRuns` の ID と run 成功イベントの整合性を公開直前に検証する。公開後に UI materialize した結果を一括送信する。Jev の後からの成功は contentPriority run だけを独立して更新する。

### 5. 保存済みセッションの再処理 UI

メイン画面に「保存済み録音」を追加する。`sessionsRoot` の各 `session.json` を読み、日時・長さ・処理状態を一覧表示する。行を選ぶと、現在 active な文字起こしを表示する。各行の「再処理」はその session ID の保存音声を `PendingProcessing.finalize` に入れる。録音中はボタンを無効にする。同一 session に同時再処理を重複投入しない。音声が欠損している場合は行に理由を表示し、処理を開始しない。読み込みファイルはアプリ内にコピー済みの original から timeline を再構築する。

### 6. 計測と受け入れ条件

- ライブ: `speechStart`, `checkpointCommitted`, `snapshotRequested`, `asrStarted`, `asrReturned`, `viewModelUpdated` の monotonic timestamp を同じ utterance ID で記録する。既存の `test-data/recordings/local/_smoke/audio.wav` と発話入り会話音声を原速で replay し、モデル準備済みの実機で durable timeline 上の発話開始から表示データ更新までの P95 が 3.0 秒以下か測る。中央値・最大値・件数も併記し、失敗・空文字も分母に含める。これはマイク入力と画面描画を含む測定値とは称さない。
- オフライン: 2 人が VAD の一発話区間内で交替する音声で、別々の確定行と話者ラベルになる。重なり区間は複数ラベル、話者推定なしは `話者不明`、5 人目は `その他` と表示され、いずれも音声フレームが欠けない。
- 話者交替の評価音声は無音長 0、0.1、0.2、0.5 秒と同時発話を含める。各条件で diarization が返した raw span の境界誤差と、最終行の話者取り違えを別々に計測する。境界誤差の合否値は評価音声の人手境界と実機結果を見て決め、0.2 秒の無音を検出条件とはしない。
- 再処理: 保存済みの録音を選んで実行し、成功時に全 run が一括切替、失敗時に旧表示を保持する。再起動後に同じ結果を materialize できる。
- Jev: 架空の日本語文で `PRIMARY` / `LOW_PRIORITY` と場面開始・終了・なしを fake transport で検証し、確定した話者ターンのテキストだけが分類へ渡ること、応答が content priority run に保存・再表示されること、失敗時は通常表示と再試行待ちになることを確認する。実 API 通信は保存済み API キーが利用できる場合に限り短い架空文で確認し、未設定なら「実通信未検証」と報告する。
- アプリで Jev 分類イベントの保存が完了した後、処理状態と表示文言を必ず完了へ更新する。分類がスキップされた場合も完了文言へ進め、失敗した場合は再試行待ちまたは失敗理由を表示する。「分類中」を終了後に残さない。
- フィラーと本文が同じ ASR 区間にある場合、区間全体を通常表示に戻すだけで終えない。確定文字列内の明らかな単独フィラー（例: `えー、今日は…` の `えー、`）を文字範囲として検出し、その範囲だけ低優先度の見た目にする。本文は通常表示し、正本文字列は削除・改変しない。Jev の区間全体の優先度判定と、局所フィラー範囲の表示判定を別の結果として扱う。
- 局所フィラーの試験では `えー、今日は公開鍵暗号を説明します。` の `えー、` だけを低優先度にし、フィラーだけの区間、フィラーなし、語の内部に似た文字列がある場合、句読点を挟む複数フィラーを確認する。
- 回帰: `swift test` の Core/Runtime、アプリ build、既存の発話入り保存音声によるモデル試験。durable timeline への書き込み失敗・Qwen 失敗・diarization 失敗・途中終了は fake と replay で確認する。無音音声は「文字が出ない」条件だけに用い、速度や話者分離の判定には使わない。新規録音の手動試験は含めない。

## 実装対象の境界

- Core: `Segmentation.swift` または新規 `SpeakerTurnSegmenter.swift`、`SpeakerDisplayMapper.swift`、`ProcessingMetadata.swift`、`Materialization.swift`、`SessionRecoveryScanner.swift`。
- Runtime: `FluidVADSegmentationEngine.swift`、`FluidVADTimelineProcessor.swift`、`LiveVADSession.swift`、新規 `LivePartialASRSession.swift`、`NativeSessionProcessor.swift`。
- App: `AppState.swift`、`LiveTranscriptViewModel.swift`、`LiveTranscriptView.swift`、`MacAmbientJevApp.swift`、新規保存済み録音一覧 view。
- テスト: Core と Runtime の対応テスト、既存音声の原速 replay。マイクから表示までの遅延は今回の検証対象外として明記する。
