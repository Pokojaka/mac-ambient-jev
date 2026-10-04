# 確定処理・復旧・再処理

録音停止後、ライブ処理が継続できなかった録音、音声ファイルの読み込み、保存済みセッションの再処理、クラッシュ復旧、CLI の再開は、共通の確定パイプラインを使います。ライブ文字起こしは暫定結果であり、確定本文や区間の入力にはしません。Jev の優先度だけは、確定本文と一致する保存済みライブ判定を再利用できます。

## 共通パイプライン

```text
保存音声の処理タイムライン
  → VAD
  → 録音全体のオフライン話者分離
  → VAD 区間の話者 turn 分割
  → 区間ごとの Qwen3-ASR
  → 音響による場面判定
  → 近接度に基づく音響範囲判定
  → ローカル必須段階の結果を一括公開
  → アプリで利用可能なら Jev の優先度分類
```

録音は保存済みタイムラインを使います。読み込み音声はアプリ内に保存した original を使う入口から処理タイムラインを準備するため、外部の読み込み元ファイルが残っている必要はありません。

読み込み音声の確定処理は、毎回既存の処理タイムラインを削除し、保存済み original からゼロから作り直してから始まります。

エンジン入力は **16,000 Hz・mono・float32 PCM** だけを受け付けます。VAD は保存済み floats を直接読み、ASR loader は区間の canonical samples を変更せず Qwen に 16000 を渡します。20 ms 未満の ASR 入力を推論しない規則は変わりません。source frame は original や device ではなく保存タイムラインの座標です。

話者分離は既存の canonical CAF と FluidAudio の OfflineDiarizerConfig.segmentation.sampleRate を検証し、`OfflineDiarizerManager.process(audioSource:audioLoadingSeconds:progressCallback:)` を呼びます。`CanonicalCAFAudioSource` が lock 付きの bounded random read を行い、SRC や別の whole-audio raw PCM temporary file は作りません。発話のある確定処理の CAF 自体は derived 内に保存します。

VAD、ASR、話者分離、場面、音響範囲には新しい run ID を付け、各段階の `processing.run.started` に、その実行の engine、model、version、configuration を保存します。以前の run の来歴を新しい実行へ引き継ぎません。

検証済み VAD 結果が 0 区間なら、話者分離用の音声を書き出さず、話者分離と ASR のモデル準備・推論、場面・音響範囲の判定、Jev 分類を実行しません。5 段階すべてに provenance を持つ開始と `succeeded: true`、`completed_count: 0`、`failed_count: 0` の完了を保存し、同じ公開前検証を通して空の確定文字起こしを `complete` として公開します。これは処理対象がないことの完了であり、推論した話者 span や場面を作りません。ASR 計測値はすべて 0、終端表示は「発話区間は検出されませんでした」です。保存音声は変更しません。

VAD の失敗・不正な区間、発話がある場合の話者分離・ASR の失敗を空の成功結果へ変換しません。これらは `failed` として以前の公開結果を保持します。空の成功結果は自動復旧の対象ではなく、明示的な再処理では新しい 5 段階の run で同じ空の結果を公開します。

録音停止時にライブ Jev の進行中 task と待ち行列を取り消します。確定処理はその終了を待たず、処理開始時点でイベントログに保存されている同じセッションのライブ classified 判定だけを読みます。前後の空白・改行を trim した本文が確定本文と完全一致した発話は、Jev へ再送せず優先度を引き継ぎます。新しい確定 content priority run の carried_over に元 run・segmentation run・segment ID を保存します。本文が変わった発話、保留中のライブ発話は確定本文を分類し、確定本文をライブ本文で置き換えません。ライブ判定の読取失敗は明示して意味分類を保留し、成功したローカル結果の公開を取り消しません。[Jev](jev.md)

## 全段階の一括公開

開始時に `processing_metadata.json` の finalization attempt を `running` にし、公開済みの `active_runs` は保持します。途中で得た話者 span、本文、場面、音響範囲を、それぞれ独立に画面の現在値へ切り替えることはしません。

ローカル必須段階がすべて成功し、保存イベントの run 開始・成功完了、区間 ID・範囲・件数の整合性を確認した後、`active_runs` の組と finalization の `complete` を同じ atomic write で保存します。その組から生成した確定表示を一括で渡します。[Jev](jev.md) は任意の後段です。未設定、停止中、通信失敗でも、成功したローカル結果の公開を取り消しません。

| 結果 | 永続状態と表示 |
| --- | --- |
| 成功 | `complete` と新しい全 run を公開 |
| 発熱による中断 | `paused`。公開済み run を保持 |
| 処理失敗・公開失敗 | `failed` と理由。公開済み run を保持 |

失敗・一時停止では、以前の正常な確定結果があればその表示を保持します。初回録音で確定結果がなければ、終了処理が得たライブ暫定結果を保持します。保持できる結果がなければ文字は表示しません。以前の結果自体が読めない場合は、その読取失敗も明示します。失敗状態の保存まで失敗した場合も元の原因と併記します。

途中失敗・一時停止でも、ASR 段階で得た計測値を処理結果に残します。ASR 開始前の失敗では ASR 計測値はありません。

## 発熱による一時停止と再開

アプリは critical の間、確定処理の開始をキューに保留します。実行中は各 ASR 区間の処理前に critical を確認し、中断した attempt を `paused` として保存します。「発熱のため確定処理を一時停止中」と表示し、`failed` にはしません。

熱状態が critical を下回ると、アプリは保留した要求をキューの先頭に戻して自動再開します。利用者が文字起こし処理を一時停止している場合は再開しません。再開は未完了の ASR 区間だけを続けるのではなく、新しい attempt と run で確定処理全体を実行します。進行中のモデル推論を途中で強制中断するものでも、VAD・話者分離・場面・音響範囲の各処理に区間ごとの熱中断を設けるものでもありません。

`MacAmbientJevProcessRecording` の file import、`--inspect-session`、`--resume-session` の全てで `--sessions-root DIRECTORY` は必須です。CLI は保存場所を暗黙に選ばず、root を検証してからセッション検索・作成・モデル処理を始めます。

CLI は開始時の熱状態が nominal / fair 以外なら開始を拒否します。処理中の critical では `paused` を保存して非 0 終了します。冷却後、`--resume-session` で再開できます。CLI のプロセスが冷却を待って自動再開するわけではありません。

## 復旧と明示的な再処理

復旧判定は保存音声と処理 metadata を基準にします。

| 保存状態 | 復旧 action |
| --- | --- |
| finalization が `running` / `paused` | `finalize` |
| finalization 未作成、公開済み run なし、保存音声あり | `finalize` |
| finalization が `failed` | 自動復旧しない。利用者の再処理待ち |
| `complete`、公開済み run と Jev 保留 ID あり | `retryContentPriority` |
| その他 | 復旧対象なし |

停止前にクラッシュした録音は durable checkpoint の保存範囲を使います。録音・読み込みのどちらも、復旧時の確定処理は VAD から音響範囲まで全量を新しい run で実行します。復旧は保存された `asr.pending` の区間に限定しません。

Jev の保留再試行は別の action で、ローカル必須段階をやり直しません。公開済みより新しい未公開の優先度 run がログに残る場合は、その部分結果を採用せず、公開済み segmentation の全区間を分類対象にします。

読めないセッションは理由付きで報告します。自動復旧は読めない `processing_metadata.json` を上書きしません。アプリの保存済み一覧で利用者が明示的に「再処理」を選ぶ場合だけ、読めない処理 metadata を置き換えられます。派生結果が「破損」でも保存音声が利用可能なら再処理できます。原音声や録音タイムラインまで壊れている場合、metadata を置き換えても音声の問題は解消しません。

復旧 scanner は非表示・manifest 欠損を含む root 直下の全ディレクトリを調べ、保存フォルダー名と manifest を検証します。同じ完全 UUID が複数フォルダーにある場合は全て復旧失敗として報告し、自動処理へ投入しません。詳細は [保存形式](storage.md) を参照してください。

### CLI の復旧インターフェース

実行 target は `MacAmbientJevProcessRecording` です。セッション UUID を SESSION_ID、セッション保存ルートを SESSIONS_ROOT、セッション内部とは異なる出力先を SEGMENTS_OUTPUT に設定して使います。

```bash
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --inspect-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT"

swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --resume-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT" "$SEGMENTS_OUTPUT"
```

`--inspect-session` の JSON action は `finalize`、`retryContentPriority`、`none`、`unrecoverable` です。音声欠損は `unrecoverable`、その他の読取不整合はエラーになります。`--resume-session` は録音・読み込みの `finalize` に対応しますが、CLI は Jev を無効にするため `retryContentPriority` を再開しません。通常処理・再開とも `--low-heat` で ASR 区間の間に 2 秒の待機を入れられます。

ID は manifest の完全 UUID から実フォルダー URL に解決します。不在・複数一致・フォルダー名の不整合はエラーで、`none` は存在する正常セッションの action がない場合に限ります。resume は実行時に実フォルダーを解決して出力先を検査し、symlink と大文字小文字の違いを考慮してセッション内部への出力を production engine の処理前に拒否します。

## 話者 turn の境界

VAD 区間を話者 turn と同一視しません。一つの VAD 区間内で、直前・直後の話者集合がそれぞれ一人で、異なる話者である場合に分割候補を作ります。

- 両側の連続した単独話者の根拠を各 0.3 秒以上要求します。
- 話者 span が接していれば接点、間に空白があれば空白の中点で分割します。中点で二つの子区間へ配分するので、空白部分の音声サンプルは捨てません。独立した UNKNOWN gap 行は作りません。
- 切断で生じる子区間も各 0.3 秒以上必要です。短い揺れや重なり・入れ子で境界が曖昧な場合は切らず、元の詳細 span を保持します。
- 子区間は元 VAD 区間を欠落・重複なく覆います。VAD の 14 秒分割後の短い continuation はそのまま保持し、短いからという理由で隣の別話者へ混ぜません。
- 負の開始位置、逆転・ゼロ長、音声全体の範囲外の話者 span は明示エラーです。範囲内へ黙って切り詰めません。

重なり発話を話者分離したことは、混合音声から各人の声を分離したことを意味しません。本文を文字数比で二人へ配分する処理もありません。

## 話者ラベルと見出し

話者ラベルは確定 run の raw 話者 ID を最初の開始フレーム順に並べ、同時刻なら raw ID の辞書順で決めます。最初の 7 人を `Speaker 1`〜`Speaker 7`、8 人目以降を `OTHER` とします。`OTHER` は一人の人物を意味しません。番号は同一確定 run 内で固定し、再処理では振り直せます。

話者分離前のライブには見出しを出しません。話者分離後の行の見出しは次の **80% ルール**を使います。

1. 行と重なる話者 span の時間を話者 ID ごとに足します。
2. 全話者の重なり時間の合計を分母にし、一人が 80% 以上ならその人だけを見出しにします。分母は行全体の長さではありません。同時発話の時間は各話者の分として数えます。
3. 80% 未満なら、該当するラベルを登場順に「Speaker 1 / Speaker 2」のように併記します。同じ表示ラベルは重複させません。
4. 重なる有効な span がなければ `UNKNOWN` です。

画面では同じラベル集合が連続する行の見出しを繰り返しません。`transcript.txt` は画面と同じ行集合・話者ラベルを使い、各発話を「[mm:ss] Speaker 1 / Speaker 2: 本文」の一行で書き出します。本文内改行は空白にし、低優先度の原文も印なしで含めます。空本文、討論場面で音響範囲がすべて背景の行は含めません。話者分離前の暫定本文はこの形式では書き出せません。

## ASR の成功・空本文・失敗

`asr.completed` は `outcome: recognized` または `empty` を持ちます。空白・改行だけなら `empty` です。空本文区間もイベントには残りますが、画面、`transcript.txt`、`segments.json` の公開ビューには出しません。特定の失敗定型文との文字列一致では除外しません。

`asr.failed` は `engine_unavailable`、`audio_unreadable`、`transcription_failed` の kind と原因メッセージを持ちます。モデル準備、音声読取、認識、イベント保存の失敗は確定 run の公開失敗につながります。ASR 区間ごとのタイムアウトを独立した失敗 kind として保存する仕組みはありません。

## 実装の根拠

- [確定パイプライン](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[共通入口・公開・保持](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[ASR の一時停止・失敗・計測](../app/MacAmbientJev/Sources/MacAmbientJevCore/PipelineCoordinator.swift)
- [処理 metadata](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)、[復旧判定](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecoveryScanner.swift)、[アプリの処理キュー](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+Processing.swift)、[CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)
- [読み込み音声のタイムライン準備](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[話者 turn 分割](../app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerTurnSegmenter.swift)、[話者ラベル](../app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerDisplayMapper.swift)
- [表示 projection](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[画面の見出し](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift)、[テキスト書き出し](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/SessionExport.swift)、[構造化 ASR 結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
