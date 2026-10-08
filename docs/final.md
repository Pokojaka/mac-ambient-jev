# 確定処理・復旧・再処理

録音停止後、ライブ処理が継続できなかった録音、音声ファイルの読み込み、保存済みセッションの再処理、クラッシュ復旧、CLI の再開は、共通の確定パイプラインを使います。ライブ文字起こしは暫定結果であり、確定本文や区間、節の境界の入力にはしません。Jev の優先度だけは、確定の節本文と完全一致する保存済みライブ判定を再利用できます。

## 共通パイプライン

```text
保存音声の処理タイムライン
  → VAD
  → 録音全体のオフライン話者分離
  → VAD 区間の話者 turn 分割
  → 区間ごとの Qwen3-ASR
  → 音響による場面判定
  → 近接度に基づく音響範囲判定
  → ローカル必須段階の結果と全区間の境界保留を一括公開
  → アプリで利用可能なら Jev の境界判定（一区間一送信）
  → 節の組み立て
  → Jev の優先度判定（閉じた節を 40 節ずつ）
  → 境界判定 run・優先度 run・両保留を一括公開
```

音声は `storage.json` を確定処理の開始時に読んで決めます。`recordingPCM` は processing ディレクトリの PCM、`recordingFLAC` は `recording.flac` を全復号して検証した読み取り元として使います。FLAC 状態の録音では PCM が残っていても読みません。保存済みの音声がなければ「保存済みの音声がありません」で開始に失敗します。読み込み音声はアプリ内に保存した original から処理タイムラインを作るため、外部の読み込み元ファイルが残っている必要はありません。

読み込み音声の確定処理は、毎回既存の処理タイムラインを削除し、保存済み original からゼロから作り直してから始まります。作り直した処理タイムラインの長さと欠落記録は `storage.json` に保存し、確定処理の終了時に処理タイムラインを削除します。

エンジン入力は **16,000 Hz・mono・float32 PCM** だけを受け付けます。VAD は保存済み floats を直接読み、ASR loader は区間の canonical samples を変更せず Qwen に 16000 を渡します。20 ms 未満の ASR 入力を推論しない規則は変わりません。source frame は original や device ではなく保存タイムラインの座標です。

話者分離は既存の canonical CAF と FluidAudio の OfflineDiarizerConfig.segmentation.sampleRate を検証し、`OfflineDiarizerManager.process(audioSource:audioLoadingSeconds:progressCallback:)` を呼びます。`CanonicalCAFAudioSource` が lock 付きの bounded random read を行い、SRC や別の whole-audio raw PCM temporary file は作りません。FluidAudio が末尾で要求する固定長のモデル window には、CAF に存在する sample だけをコピーし、呼び出し元が 0 初期化した残りを変更しません。保存タイムラインの長さ・音声・区間座標には padding を加えず、実ファイルの予期しない EOF・不正 sample はエラーです。発話のある確定処理の CAF 自体は derived 内に保存します。

FluidAudio の話者時刻はゼロ padding を含むモデル window の grid 上の値です。`FluidOfflineDiarizationEngine` は CAF の実 sample 数を使い、`SpeakerSpanMapper` が canonical frame に変換した時点で、実音声内に開始し、最終 window の padding 内で終了する span の終端だけを EOF に合わせます。window 開始位置は `0, samplesPerStep, ... < sampleCount` なので、最終開始位置は `floor((sampleCount - 1) / samplesPerStep) * samplesPerStep`、許容 padding は `max(0, samplesPerWindow - (sampleCount - 最終開始位置))` です。EOF ちょうどで開始する span、padding を超える終端、負の開始位置、逆転・ゼロ長は明示エラーにします。音声自体の長さは変えず、保存イベントには実音声内の span だけを渡します。他の話者分離 engine や下流の確定処理で範囲外 span を切り詰めません。

VAD、ASR、話者分離、場面、音響範囲には新しい run ID を付け、各段階の `processing.run.started` に、その実行の engine、model、version、configuration を保存します。以前の run の来歴を新しい実行へ引き継ぎません。

検証済み VAD 結果が 0 区間なら、話者分離用の音声を書き出さず、話者分離と ASR のモデル準備・推論、場面・音響範囲の判定、Jev の判定を実行しません。保留も空です。5 段階すべてに provenance を持つ開始と `succeeded: true`、`completed_count: 0`、`failed_count: 0` の完了を保存し、同じ公開前検証を通して空の確定文字起こしを `complete` として公開します。これは処理対象がないことの完了であり、推論した話者 span や場面を作りません。ASR 計測値はすべて 0、終端表示は「発話区間は検出されませんでした」です。保存音声は変更しません。

VAD の失敗・不正な区間、発話がある場合の話者分離・ASR の失敗を空の成功結果へ変換しません。これらは `failed` として以前の公開結果を保持します。空の成功結果は自動復旧の対象ではなく、明示的な再処理では新しい 5 段階の run で同じ空の結果を公開します。

録音停止では、ライブ ASR の残りを処理した後にライブ Jev キューへテキスト列の終端を伝えます。確定処理は開始時にイベントログを読んで保存済みのライブ classified 判定を固定し、その後でライブ Jev キューを取り消します。キューの通信完了は待たず、固定より後に保存された応答も使いません。確定の境界判定は全ての確定区間について一区間一送信で行い（最後の区間は次区間なし）、ライブの境界判定は確定区間へ移しません。組み立てた確定の節のうち、フィラー除去後の連結本文がライブの節本文と UTF-8 byte 列で完全一致する節は Jev へ再送せず優先度を引き継ぎ、元の優先度 run・イベント・節参照を保存します。残りの節を原文順に 40 節ずつ分類し、応答全体を検証してから batch ごとに一イベントで保存します。境界判定が成立しなかった確定区間にはライブの節を持ち込みません。ライブ判定の読取失敗や保存破損は明確なエラーとして表示し、空の再利用で全量を再分類しません。その場合も成功したローカル結果の公開は取り消しません。[Jev](jev.md)

## ローカル公開と任意の Jev 公開

開始時に `processing_metadata.json` の finalization attempt を `running` にし、公開済みの `active_runs` は保持します。途中で得た話者 span、本文、場面、音響範囲を、それぞれ独立に画面の現在値へ切り替えることはしません。

ローカル必須段階がすべて成功し、保存イベントの run 開始・成功完了、区間 ID・範囲・件数の整合性を確認した後、`active_runs` の組、finalization の `complete`、全ての非空区間の境界保留を同じ atomic write で保存します。その組から生成した確定表示（分割なしの通常行）を一括で渡します。[Jev](jev.md) は任意の後段です。Jev が使える場合は境界判定 run と優先度 run を実行し、両 run の pointer と両保留を一回の atomic write で公開してから表示を更新します。この保存に失敗した場合は未公開の結果を表示せず、直前に公開したローカル結果を保持して保存エラーを表示します。未設定、停止中、通信失敗でも、成功したローカル結果の公開を取り消しません。CLI は Jev を使わず、全区間を境界保留としたローカル結果を公開します。

Jev の未設定・停止・通信失敗は通常の保留として扱います。一方、保存済み判定の破損・再利用参照の不整合・イベント保存失敗・metadata の公開失敗は保留へ変換せず、処理結果を失敗として報告します。ローカル5段階が既に公開されていれば、その表示と境界保留を保持し、処理結果の失敗を成功完了で上書きしません。

| 結果 | 永続状態と表示 |
| --- | --- |
| 成功 | `complete` と新しい全 run を公開 |
| 発熱による中断 | `paused`。公開済み run を保持 |
| ローカル処理失敗・ローカル公開失敗 | `failed` と理由。公開済み run を保持 |
| ローカル公開後の Jev 整合性・保存・公開失敗 | 処理結果は失敗。公開済みローカル run・表示・保留 metadata は保持 |

失敗・一時停止では、以前の正常な確定結果があればその表示を保持します。初回録音で確定結果がなければ、終了処理が得たライブ暫定結果を保持します。保持できる結果がなければ文字は表示しません。以前の結果自体が読めない場合は、その読取失敗も明示します。失敗状態の保存まで失敗した場合も元の原因と併記します。

セッション情報を読めない開始失敗を除く全ての結果で、確定処理は終了時に一度だけ一時音声（話者分離入力の CAF、import の処理タイムライン、FLAC の partial）を削除します。成功した録音（文字起こし無しの完了を含む）は続けて `recording.flac` へ変換し、PCM を削除します。FLAC の録音の再処理は再符号化しません。変換・削除の失敗は成功でも結果を失敗とし、公開済みの文字起こしの保持を明示します。一時停止の削除失敗は一時停止のまま、削除エラーを状態文で報告します。詳細は [保存形式](storage.md) を参照してください。

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
| `complete`、公開済み run と Jev の保留（境界判定の区間または優先度の節）あり | `retryContentPriority` |
| その他 | 復旧対象なし |

停止前にクラッシュした録音は durable checkpoint の保存範囲を使います。録音・読み込みのどちらも、復旧時の確定処理は VAD から音響範囲まで全量を新しい run で実行します。復旧は保存された `asr.pending` の区間に限定しません。

Jev の保留再試行は別の action で、ローカル必須段階をやり直しません。保留一覧をイベントログで検証し、公開済みの snapshot から新しい run を作ります。公開済みより新しい未公開の Jev run がログに残っていても、その部分結果は採用しません。ライブの未完了 run は確定の再試行対象と見なしません。

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

`--inspect-session` は読み取り専用で、JSON に `action`（`finalize`、`retryContentPriority`、`none`、`unrecoverable`）と `maintenance`（`compactRecording`、`removeTransients`、`null`）を出します。音声欠損は `unrecoverable`、その他の読取不整合はエラーになります。`--resume-session` は先に保存整理（`maintenance`）を実行し、もう一度調べた結果の `action` に従います。`finalize`（録音・読み込み）は再開し、`retryContentPriority` は CLI が Jev を無効にするため Jev を再試行せず、公開済みの結果をそのまま書き出します。通常処理・再開とも `--low-heat` で ASR 区間の間に 2 秒の待機を入れられます。

ID は manifest の完全 UUID から実フォルダー URL に解決します。不在・複数一致・フォルダー名の不整合はエラーで、`none` は存在する正常セッションの action がない場合に限ります。resume は実行時に実フォルダーを解決して出力先を検査し、symlink と大文字小文字の違いを考慮してセッション内部への出力を production engine の処理前に拒否します。

## 話者 turn の境界

VAD 区間を話者 turn と同一視しません。一つの VAD 区間内で、直前・直後の話者集合がそれぞれ一人で、異なる話者である場合に分割候補を作ります。

- 両側の連続した単独話者の根拠を各 0.3 秒以上要求します。
- 話者 span が接していれば接点、間に空白があれば空白の中点で分割します。中点で二つの子区間へ配分するので、空白部分の音声サンプルは捨てません。独立した UNKNOWN gap 行は作りません。
- 切断で生じる子区間も各 0.3 秒以上必要です。短い揺れや重なり・入れ子で境界が曖昧な場合は切らず、元の詳細 span を保持します。
- 子区間は元 VAD 区間を欠落・重複なく覆います。VAD の 14 秒分割後の短い continuation はそのまま保持し、短いからという理由で隣の別話者へ混ぜません。
- 負の開始位置、逆転・ゼロ長、音声全体の範囲外の話者 span は明示エラーです。FluidAudio adapter が上記の最終 window padding を処理した後も、確定パイプラインは音声範囲を厳密に検証し、範囲内へ黙って切り詰めません。

重なり発話を話者分離したことは、混合音声から各人の声を分離したことを意味しません。本文を文字数比で二人へ配分する処理もありません。

## 話者ラベルと見出し

話者ラベルは確定 run の raw 話者 ID を最初の開始フレーム順に並べ、同時刻なら raw ID の辞書順で決めます。最初の 7 人を `Speaker 1`〜`Speaker 7`、8 人目以降を `OTHER` とします。`OTHER` は一人の人物を意味しません。番号は同一確定 run 内で固定し、再処理では振り直せます。

話者分離前のライブには見出しを出しません。話者分離後の行の見出しは次の **80% ルール**を使います。

1. 行と重なる話者 span の時間を話者 ID ごとに足します。
2. 全話者の重なり時間の合計を分母にし、一人が 80% 以上ならその人だけを見出しにします。分母は行全体の長さではありません。同時発話の時間は各話者の分として数えます。
3. 80% 未満なら、該当するラベルを登場順に「Speaker 1 / Speaker 2」のように併記します。同じ表示ラベルは重複させません。
4. 重なる有効な span がなければ `UNKNOWN` です。

画面では同じラベル集合が連続する行の見出しを繰り返しません。`transcript.txt` は画面と同じ行集合・話者ラベルを使い、各発話を「[mm:ss] Speaker 1 / Speaker 2: 本文」の一行で書き出します。本文内改行は空白にし、フィラー除去済み本文と低優先度本文を印なしで含めます。フィラー除去後の空本文、討論場面で音響範囲がすべて背景の行は含めません。ASR の原文と CLI の JSON は表示用のフィラー除去で変更しません。話者分離前の暫定本文はこの形式では書き出せません。

## ASR の成功・空本文・失敗

`asr.completed` は `outcome: recognized` または `empty` を持ちます。空白・改行だけなら `empty` です。空本文区間もイベントには残りますが、画面、`transcript.txt`、`segments.json` の公開ビューには出しません。特定の失敗定型文との文字列一致では除外しません。

`asr.failed` は `engine_unavailable`、`audio_unreadable`、`transcription_failed` の kind と原因メッセージを持ちます。モデル準備、音声読取、認識、イベント保存の失敗は確定 run の公開失敗につながります。ASR 区間ごとのタイムアウトを独立した失敗 kind として保存する仕組みはありません。

## 実装の根拠

- [確定パイプライン](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[共通入口・公開・保持](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[ASR の一時停止・失敗・計測](../app/MacAmbientJev/Sources/MacAmbientJevCore/PipelineCoordinator.swift)
- [処理 metadata](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)、[復旧判定](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecoveryScanner.swift)、[アプリの処理キュー](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+Processing.swift)、[CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)
- [読み込み音声のタイムライン準備](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[話者 turn 分割](../app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerTurnSegmenter.swift)、[話者ラベル](../app/MacAmbientJev/Sources/MacAmbientJevCore/SpeakerDisplayMapper.swift)
- [表示 projection](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[画面の見出し](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift)、[テキスト書き出し](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/SessionExport.swift)、[構造化 ASR 結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
