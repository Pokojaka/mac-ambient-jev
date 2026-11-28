# ライブ文字起こし

録音中のライブ表示は、最新の durable `pipeline.started` generation が選択する区間・ASR 成功行を保存直後に表示します。停止・確定処理は同じ generation を sealed source まで完了します。録音保存、発話検出（VAD）、音声認識（ASR）は別々に進み、ASR が遅れても録音保存を止めません。ASR 結果は保存直後に、フィラー・相槌や LOW を除かず、RAW ASR とイベントを変更せずに表示用の数字表記変換だけを適用して表示し、区間ごとの境界 assessment が保存された後にだけ、その assessment の F・B除去範囲を表示から除きます。同梱の Core ML 発話文モデルが BTSJ 発話文単位の境界・継続・F・B除去範囲・優先度を任意に判定します。保存 key や内部名の `clause` / `節` はこの発話文単位を識別し、別の節分割器はありません。[停止と確定処理](final.md)

## VAD と ASR の区切り

- 保存済みの処理タイムラインだけを VAD に渡します。まだディスクに確定していない音声は対象にしません。
- 録音中の durable chunk（必須処理完了後、sealed source を検証してから FLAC 化・削除する PCM）は 0.5 秒、アプリの checkpoint 確認間隔は 250 ms です。ライブ中・未完了 generation の compaction はありません。保存済みの 16 kHz mono float32 を直接 FluidAudio のストリーミング VAD に渡します。VAD と ASR は入力形式を検証し、処理段階の SRC・downmix は行いません。
- 発話開始は VAD 確率 0.50 以上、発話終了は 0.35 未満（FluidAudio streaming VAD は開始閾値から 0.15 引く）です。発話開始前に 0.10 秒の pre-roll を含め、無音終了は 0.75 秒です。確定処理も同じ設定で区間を作り、Linux / Windows は同じ値を Silero VAD の確率に適用します（[Windows の VAD](windows.md#silero-vad-の区間検出)）。
- `SpeechRangeAssembler` は 0.10 秒の VAD pre-roll を含む speech range を作り、独立 speech range が 0.5 秒未満なら破棄します。これは最終 ASR segment の長さ判定ではありません。VAD が利用できない録音ではライブ ASR を実行しません。
- speech range が 14 秒に達すると、`[rangeStart+12s,rangeStart+14s)` の範囲で、絶対 sample 0 に揃えた 320 sample（20 ms）frame の RMS が最小の位置で分割します。
  分割位置は frame の midpoint とし、同値なら最も早い frame を選びます。14 秒到達時点で対象範囲の音声は処理済みなので先読みしません。
  RMS の rolling history は直近 3 秒（150 frame）だけ保持し、必要な範囲が履歴にない場合は error にします。分割後の continuation は speech range として保持し、独立 range の最小長判定では破棄しません。
- ライブと確定処理は同じ `VADSegmentationState` の chunking を使います。利用可能な連続 speech ranges は、先頭 range の開始から追加対象 range の終了まで（間の gap を含めて）30秒以内なら一 segment にまとめます。1 segment は ASR 一回・transcript row 一つで、ASR は speech range 部分だけを連結し gap の音声は含めません。
- 追加した range の終了が segment 先頭 range の開始から30秒を超えると、追加前の segment を閉じて新しい segment を開きます。release 後に報告された range は次の segment に入ります。音声末尾では `finish` が開いた segment を閉じます。
- 4096 sample chunk ごとの `settledFrame` heuristic は、`settledFrame` の値が先頭 range 開始 + 30秒以上になった時点で開いた segment を release します。0.75秒の無音終了と2 chunk 分の余裕、および静かな分割位置を見込む実用上の判定であり、遅れて届く発話終了時刻を保証しません。
- 長い連続発話では、最初の speech frame から segment release まで約31〜32秒を見込みますが、普遍的な保証ではありません。表示には ASR・checkpoint overhead が加わります。短い発話も蓄積または無音終了による release まで待つことがあり、残りは停止時に flush します。
- 0.5 秒未満で独立した speech range は ASR に送りません。Haas-ja-v1.0 は連結後の ASR 入力が 20 ms 未満なら推論せず空本文を返します。この 20 ms 条件は各 speech range ではなく、結合した ASR 入力に対するものです。

ファイル replay は capture device を開かず、ファイルまたは指定した device 相当形式を原速で ingress に投入します。replay input と保存形式は別で、durable timeline とイベント frame 座標は常に 16 kHz mono です。詳細は[原速 replay のライブ遅延計測](testing.md#原速-replay-のライブ遅延計測)を参照してください。
- 検出した区間は ASR の待ち行列に入れる前に `segment.created` として保存します。ライブ経路は `asr.pending` を書きません。このイベントは確定処理の ASR 待ち状態に使います。
- 区間の音声読取・認識・pacing・計測・結果保存は確定処理・ファイル評価と同じ [`PipelineCoordinator.execute`](../app/MacAmbientJev/Sources/MacAmbientJevCore/PipelineCoordinator.swift) を使い、保存後の callback で行と件数を更新します。ライブは通常 pacing を指定し、モデル準備は共有 `execute` に集約し、成功する session では一度だけ行います。pending age の起点は保存した `segment.created` の時刻です。各バッチは段階を終了せず、`LiveASRSession.finish` が ASR run の完了を保存します。
- 未認識区間の新規登録・同じ ID の再登録は認識済み行を変えず、ライブセッション内の行配列を返し、登録 progress 取得は履歴全体の sort・materialization・ID 集合差の生成を行いません。`LiveASRSession.open` は durable events から指定した segmentation / ASR runs を復元し、`segment.created` の全 `speechRanges` と登録時刻、成功した空結果を含む `asr.completed`、既存の `processing.run.started` を保持します。成功結果の重複は consistency error です。
- `process(reader:)` は任意の `TimelineAudioReading` を受け取り、durable events から pending set を再導出して、未成功区間を古い順に処理します。pending count は登録 ID 数から成功 `asr.completed` ID 数を引いた値で、failure も pending に含みます。成功済み区間・登録・run-start を重複保存せず、ASR event の durable write 後に行・status・件数を更新します。保存失敗は元の error を throw します。recognized / empty / failed / pending status は独立した判定 queue に渡り、pending と failure を後続 ASR 成功として扱いません。最初の `asr.failed` はその attempt を停止し、先行成功行を保持して後続を処理しません。未解決 ASR failure は起動時に自動復旧せず、明示 CLI `--resume-session` は同 generation で不足区間だけを再開できます。利用者の再処理は空の新 generation から始めます。成功した空結果は区切りです。空白・改行・句読点だけの ASR 原文は空の結果です。
- [`VADSession`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/VADSession.swift) の saved-reader API は固定4096 sample chunk を保持し、partial chunk は EOF の一度だけ flush します。4096 frame 境界に揃う実消費 progress（無音を含む）は、今回の全 segment を `segment.created` として保存後だけ記録し、正確な EOF frame 数の seal、tail 保存、完了の順です（[保存形式](storage.md#eventsjsonl)）。
- `VADSession` saved-reader API は未完了 run を sample 0 から replay し、全 ordinal の ID / speech ranges が一致する prefix だけを受け入れ、不一致を error にします。完了済み run は保存済み segments を使い、processor factory / VAD を呼びません（[recovery と保存形式](storage.md#eventsjsonl)）。production の live VAD は `LiveVADSession` で、停止時に `LiveASRSession` が `segmentation.input.sealed`（EOF flush の前、正確な最終 frame 数）と、tail 区間を登録した後の `segmentation.completed` を保存します（`segment.created` を保存するのは `LiveASRSession` だけです。ASR 失敗・登録失敗があれば completed を書かず、stop が未完了 segmentation として開き直します）。stop/finalize は同じ generation に対する `StoredSegmentation.finish` を使います。後者は segmentation が未完了の場合だけ sealed source を sample 0 から再生成・prefix 照合し、完了済みなら保存済み segments を使います。`LiveASRSession.open` / `drain` は stop/finalize と明示 CLI resume で同じ ASR run の durable 成功行を復元し、不足区間だけを処理します。
- アプリのライブ ASR 待ち行列はバッチごとの `SegmentReference` だけを保持します。`AudioCheckpoint` はセッションごとに最新の保存済み checkpoint を 1 件だけ保持し、各バッチの認識時に使います。保存範囲は単調に伸びるため、最新 checkpoint は待機中の全区間を含みます。バッチとして渡した区間の終端が渡した checkpoint の確定範囲を超える場合は、区間を登録する前に `LiveASRSessionError.segmentBeyondCheckpoint` で失敗します。checkpoint の外に残るのは、別に登録済みの区間だけです。checkpoint の chunk 一覧・フレーム数・gap 一覧をバッチごとに保持せず、区間参照はメモリ内に残します。冷却後も登録順で処理し、停止後のライブ処理終了・取消時にキューと checkpoint を解放します。

`LiveTranscriptionState.enqueue` の前提条件は、区間が空でなく、失敗が記録されていないことです。VAD が空の終端区間を返す場合、coordinator は enqueue 前に空を除外します。`await registerLiveSegments` の待機中に ASR 認識失敗が記録されることがあり、登録完了後に coordinator は失敗状態を再確認し、失敗済みならキューへ追加しません。認識失敗が記録されると、既存の待機バッチも破棄します。一方、区間登録の永続化失敗は失敗を記録しても既存の未処理キューを空にせず保持します。未処理キューが残る間はアイドル時のモデル解放条件を満たさず、確定処理または取消時の後始末までモデルは解放されません。

Mac の ASR は日本語専用 Haas-ja-v1.0 を ONNX Runtime の CPU で実行し、演算スレッド数は固定 4 です。実エンジン名は `onnxruntime-haas-tdt`、モデル ID は [Sanami/haas-ja-onnx/int8dyn](https://huggingface.co/Sanami/haas-ja-onnx/tree/354baedfd9612b00e74cc1ae87dff7f2c558db6f/int8dyn) です。このモデルへの Mac の呼び出しに言語引数はありません。[Haas ASR manifest](../app/MacAmbientJev/Sources/MacAmbientJevHaasASR/Resources/haas_asr_model.json) は commit `354baedfd9612b00e74cc1ae87dff7f2c558db6f` の7ファイルを固定し、model store が全ファイルの byte 数と SHA-256 を検証したディレクトリから読み込みます。

### モデルが揃うまで

モデルが app に同梱されていなくても、録音は始められて保存されます。ライブ文字起こしは、2つのモデル（ASR、VAD）の取得・照合・読み込みが終わった状態（ready）でだけ動きます。

- 取得中・未取得・取得に失敗した間はライブ ASR を実行せず、表示は「モデルの取得後に文字起こしします」（失敗したときは理由）です。モデルが揃う前の音声も保存され、停止後の finalization は既存 generation を続けるか、generation がなければ新規開始し、未完了 segmentation / 未成功 ASR を処理します。保存済み成功 ASR 行は再認識しません。
- 照合と読み込みの間（毎回の起動後は ASR の SHA-256 照合に数秒かかります）だけは、読み込み中の既存バッチを保持します。ready になれば処理し、失敗に終わればその attempt を停止します。未処理区間の durable 登録は残り、ASR failure が発生した generation は起動時に自動再試行せず、明示 CLI resume または利用者の新 generation 再処理を待ちます。
- 録音を始めた時点で VAD のモデルが取得済みでなければ、その録音は全長にわたってライブ VAD なしで進みます（録音は継続）。録音中に VAD を始めません。停止後は `finalize`（`.reject`）がモデルの取得を待ちます。録音の停止は常にこの `finalize` を一件 enqueue します。live VAD が完了し live worker が残っていればそれを drain し、なければ event log から開き直して drain します。
- 録音の開始時にモデルの取得を始めます。取得は録音の開始・停止をまたいで続き、録音を止めても止まりません。`asr.completed` の engine/model は実際に認識したエンジンの来歴から取得します。

## 画面の状態と操作

ヘッダーには残りの区間を処理中にだけ「残りを処理中」を表示します。ライブや最終結果を示すマーカーはありません。

画面と `transcript.txt` は同じ表示用 projection を使い、表示本文が空白・改行だけでない認識済み発話をすべて含めます。認識不能と、空白・改行・句読点だけの ASR 原文は `asr.completed` の `outcome: empty` で表し、「聞き取れませんでした」などの文字列に一致しただけでは除外しません。

表示本文は、ASR 原文に区間ごとの保存済み assessment の `filler_ranges` を適用してフィラー・相槌を除去し、その後、優先度が保存済みの LOW 発話文 slice を別に除いた本文です。保存フィールド `filler_ranges` は `{start,end}` object の配列で、フィラー（F）と相槌（B）を表示本文から除く raw UTF-16 範囲を表します。各 token の `span_probs` は `O=0, F=1, D=2, B=3` の argmax で label を決め、同点なら添字の小さい label を選びます。token span が重なる scalar は後の token の label で上書きし、どの token span にも含まれない scalar は O とします。原文の各 Character は構成するすべての scalar が F または B（F/B 混在も可）のときだけ除去し、ひとつでも O または D の scalar があれば Character 全体を残します。隣接して除去される Character は raw UTF-16 範囲にまとめます。F・B除去範囲の直後に連続して接する句読点だけを併せて除き、空白は変更・正規化しません。[TranscriptTextProjection](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptTextProjection.swift) は保存済み範囲を投影するだけで、materialization は辞書やモデルを使いません。assessment が未保存・保留・失敗の区間は、RAW ASR 原文の F・B・LOW を除かず、表示用の数字表記変換だけを適用します。assessment が保存されれば発話文の続き待ちや優先度待ちでもその区間のフィラー・相槌除去は反映されます。優先度未判定・保留・再試行待ちの slice は除きません。PRIMARY と LOW の発話文が混在する行は LOW slice 以外を表示し、本文が空または空白・改行だけになった行（フィラー・相槌だけの行、全発話文が LOW の行）は表示しません。ASR イベントの原文は変更せず、画面、選択コピー、読み上げ、アクセシビリティと `transcript.txt` は共通の表示本文を使います。UI は投影済み本文を描画するだけで独自判定はしません。行の状態は次のとおりです。

| 状態 | 表示 |
| --- | --- |
| 発話文の続き待ち | 保存済み assessment の F・B除去範囲を適用した本文を表示し、保存済み LOW slice も除く。行の下に「発話文の続き待ち」と表示。次区間の境界判定まで発話文を閉じない |
| 境界判定を保留中 | assessment が未保存の範囲は、RAW ASR 原文に表示用の数字表記変換だけを適用した本文を表示し、分割しない。別区間に保存済み assessment があれば、その F・B除去範囲を適用 |
| 優先度判定を待っています | 保存済み assessment の F・B除去範囲と保存済み LOW slice を適用。未判定・再試行待ち slice は本文を表示 |
| 判定済み | 保存済み assessment の F・B除去範囲と保存済み LOW slice を適用した本文を表示 |

状態は時刻ボタンの popover にも表示します。

行は本文だけのテキストで、開閉の矢印を持ちません。行頭の時刻を押すと、発話文の判定状態だけを popover で確認できます。popover は時刻ボタンの右側を指定して開き、ウィンドウ左端の外へ出る配置を避けます。LazyVStack の行間は 4pt です。

## 録音中の発話文判定

ASR 原文を保存した直後は、RAW ASR とイベントを変更せず、フィラー・相槌や LOW を除かない本文に表示用の数字表記変換だけを適用して表示し、まだ境界 assessment が保存されていない区間ではフィラー・相槌除去を行いません。境界 assessment の保存後にその区間の F・B除去範囲に含まれるテキストが表示から除かれ、発話文が続き待ち、優先度未判定・保留・再試行待ちでもフィラー・相槌除去は反映されます。境界 assessment が未保存・保留・失敗なら F・B除去はせず、RAW ASR 原文に表示用の数字表記変換だけを適用します。LOW 発話文 slice は優先度保存後に別に消えます。ASR イベントの原文は変わりません。判定結果を待って行や後続行を隠すことはありません。判定キューは時間順の保存済み ASR 区間を処理し、判定の待機・失敗は録音、ASR の登録・認識・表示へ伝播しません。録音・VAD・ASR の drain は判定と独立しています。

境界判定単位は BTSJ 発話文です。候補となる句読点・閾値に従ってモデルが境界と次区間への継続を判定し、コードが発話文を組み立てます。保存名 `clause` / `節` はこの発話文を識別するだけで、別の節分割処理はありません。通常は次区間の ASR が durable に保存されてから境界判定し、継続入力にはその先頭 60 Character だけを使います。成功した空結果は現在のテキスト列だけを区切り、それ以前の未解決本文は保留のまま残します。入力全体の EOF は、segmentation 完了後に caller が明示する `finishInput` で通知します。segmentation 完了は caller の責任で API は検証せず、全 segment の ASR 成功結果が durable でなければ `finishInput` は拒否されます。本文のある終端区間も、候補がなくても F・B除去範囲を得るため source-only 境界推論を実行して assessment を保存します。終端を理由に request や推論を省略しません。区間をまたぐ発話文は後続区間の判定まで閉じません。

一つの論理境界 request は、候補と原文対応 token を網羅する複数の source-only window、および次区間があれば継続入力を含みます。候補境界と F・B除去範囲の推論、継続推論は別入力でも一 request で、F・B除去範囲は source-only window の出力だけから得ます。本文のある終端区間は候補がなくても F・B除去範囲用の source-only window を推論し、request と assessment を保存します。長い原文は連続 piece を切らず複数 window に分けます。一 piece が上限を超える場合や必要な窓を作れない場合は境界 request 全体を失敗として保留し、確率を作って補いません。request の入力 token 数は全 window と継続入力の実数を合計します。次区間が保存された後に、閉じた非空の発話文を最大 40 件ずつ優先度 batch へ渡します。未閉鎖の末尾は対象外です。優先度は最大 40 件を一 batch とし、内部では sequence ごとに直列推論しますが一 request と数え、入力 token は全 sequence の実数の合計を記録します。判定に時間の上限はなく、行表示も判定を待ちません。境界・発話文・優先度は保存された後だけ表示へ反映します。

ライブ materialization は区間・ASR 原文・表示行・閉じた発話文を source/reference 索引に保持します。ASR 完了では新しい行だけを作り、保存済み判定イベントでは影響する source の行だけを更新します。全イベントを再 replay しません。開いた末尾は区間ごとの immutable link で保持し、継続ごとに過去の末尾をコピーしません。長い区間横断発話文の閉鎖・優先度更新では、その発話文に含まれる全区間を更新します。長さによる打ち切りはありません。

source の同一性、境界候補、次区間の原文 head、時間順、組み立て結果との一致、発話文と優先度の重複は batch 公開前に検証します。不正 batch は組み立て cursor と索引を戻し、行とイベント列のいずれも一部だけ公開しません。snapshot の配列は Swift の copy-on-write を使い、保存時の全履歴 materialization と同じ表示行・発話文範囲・優先度になります。原文・イベント・行・発話文の索引は保存履歴に比例して増えます。増分処理は無関係な履歴の再解析と一時作業領域を抑えますが、総メモリには一定上限を設けません。

判定キューは batch ごとに provider factory から coordinator を取得します。Core ML tagger のロード結果（成功・失敗とも）は factory 内で cache され、アプリを再起動するまで再ロードしません。同時に要求されたロードは一つにまとまります。

モデルの初期化失敗、符号化失敗、または判定結果の検証失敗なら、該当境界／優先度を保留して本文を表示したままにします。境界保留では分割せず、継続を no と偽装しません。優先度だけが保留の発話文も本文を表示します。ライブの後続待ちは、登録済みでも成功結果がない区間（`asr.failed` を含む）を待ち続け、EOF にもしません。成功した空 ASR 区間は現在のテキスト列だけを区切り、それ以前の保留を解決せず、次の列と切り離します。

`LiveContentPrioritySession.open` は録音中と通常 stop/finalization で、同じ選択済み decision run ID 群を開きます。durable な boundary / assignment を再要求せず、cursor・successor wait・open clause parts を復元します。既存 event 間で中断していれば不足する derived closure と未割当の非空 clause だけを続けます。ASR が完了した stop/finalization は `finishInput` を通知して同 worker を drain し、確定専用の新しい batch pass を作りません。

判定 `processing.run.started` の provenance は run 開始時に実際にロードした tagger の engine/model/revision を記録します。本文のある各区間には、終端で候補がない場合も F・B除去範囲を得る実際の境界 request があり、終端を理由に判定呼出しや provenance を省略しません。`unavailable` はモデルの初期化失敗など、tagger を取得していない場合に限ります。成功した各判定呼出しの request record は request ID と入力 token 数を持ち、モデルは run の provenance が示します。モデル確認は live 判定 request ではありません。

通常の録音停止では VAD polling の停止要求が次の polling を防ぎ、進行中の poll は完了まで待ちます。sleep 中なら polling sleep だけをキャンセルし、durable な `segment.created` 登録は完了させて同じ ASR drain に渡します。final VAD enqueue も同じ segmentation generation / ASR drain に加わり、poll と final の両区間を処理します。finalization は正確な committed frame count を sealed input boundary として記録し、未完了 segmentation を再生する場合は sample 0 から再生成した prefix を保存済み区間と比較します。ASR は同じ run の成功行を保持し、未成功区間だけを認識します。失敗は隠さず、その attempt を止めます。ASR completion 後は同じ初期 decision pair の worker を開き、durable boundary / priority events を復元して `finishInput` と drain を行います。後続の判定結果もこの worker が同じ選択 run のイベントとして保存します。

ASR drain は判定に関係なく動作します。CLI の `ContentPriorityAccess.disabled` は境界・F・B除去範囲・優先度の判定を行わず、assessment と `filler_ranges` を作らないため、表示本文は RAW ASR 原文に表示用の数字表記変換だけを適用し、ASR とイベントは変更しません。ライブ判定と確定判定は共通の confidence ≥ 0.90 の優先度表示規則を使います。

新しい行への自動追従は利用者のスクロール操作で解除します。アプリ自身のスクロールアニメーションでは解除しません。「最新へ戻る」を押すと追従を再開し、その場で末尾へ移動します。

## 発熱時の動作

以下は macOS の録音中の動作です。Windows では熱監視を行わず、熱状態によるライブ ASR の待機・停止はありません（[Windows の熱状態](windows.md#熱状態)）。

| 熱状態 | ライブ ASR |
| --- | --- |
| nominal / fair | 待機を入れず処理 |
| serious | 各区間の推論の直前に 750 ms 待機し、判定し直す |
| critical、または未知の熱状態 | 新しいバッチの認識を一時停止 |

`critical` または状態不明では「発熱のためライブ表示を一時停止中」と表示します。録音保存、VAD、durable な区間登録は継続し、滞留時間が長くても認識を強行しません。熱状態を 1 秒ごとに確認し、認識を再開できる状態になったらキューの最古のバッチから処理します。バッチの途中で `critical` になった場合も、次の区間の音声を読む前の区間境界で（待機なしに）止まり、冷却後にそのバッチの checkpoint が覆う残りの区間から続けます。冷却中に登録された後続の区間は、それぞれのバッチで処理します。`serious` まで冷えた場合は区間ごとに 750 ms 待機します。冷却待ちの間、停止後の確定処理はこの live worker を待たずに `thermal` 保留となり、worker を残します。進行中の同期推論を途中で中断する仕組みではありません。

このライブ熱判定は録音停止の前後で同じです。停止は入力を封印するだけで、`critical` の待機を飛ばさず、新しい generation も run ID も作りません。停止後の残存ライブキューも `critical` の間は認識せず、冷却後に最古の区間から同じ generation の続きを処理します。続く確定処理も同じ判定（`serious` は 750 ms 待機、`critical` または状態不明は一時停止）に従います。一時停止中は同 generation の durable rows を保持し、冷却後は未完了 segmentation / 未成功 ASR だけを再開します。CLI は明示的な再開操作を必要とします。[確定処理](final.md#発熱による一時停止と再開)

## リソース保護によるライブ認識の停止

`LiveTranscriptionCoordinator` は初期化時に `resourceMonitor` を optional に受け取る portable seam です。`nil` は monitor 未設定であり、`.healthy` を観測した意味ではありません。Mac の [`AppState`](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift) は明示的に `resourceMonitor: nil` を渡します。Windows Engine は [`WindowsInferenceResourceMonitor`](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/WindowsInferenceResourceMonitor.swift) を注入します（[Windows の推論リソース監視](windows.md#windows-の推論リソース監視)）。
resource 状態の変化を観測したとき、VAD 開始時、VAD が checkpoint を処理する直前、ASR batch を dequeue する直前に gate を確認します。`healthy`・`pressure`・`monitorFailed` を受け、pressure / monitorFailed はこの録音のライブ認識停止を failure としてラッチします（「メモリ不足のためライブ認識を停止しました。録音は継続しています」「リソース監視に失敗したためライブ認識を停止しました。録音は継続しています」）。
VAD の新規処理と ASR の新規登録・認識を止め、破棄するのは未処理のライブ待ち行列だけです。進行中の native call は完了することがあり、capture・audio drain・durable writer は継続し、保存済み events と audio は保持します。
同じ録音中に healthy へ戻ってもライブ認識を再開しません。failure は cleanup までその録音にラッチされます。停止時は放棄した live drain を省き、保存済み generation の finalization へ進みます。その処理も monitor 設定時は resource gate の対象で、再開時は segmentation 未完了なら sealed source から prefix 照合し、ASR の成功済み行を保持して不足区間だけを処理します。
熱制御の backlog 保持と冷却後の再開は別動作で、変更ありません。詳細は [monitoring protocol](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/InferenceResourceMonitoring.swift) と [ライブ coordinator](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveTranscriptionCoordinator.swift) を参照してください。

## ライブ処理の失敗

VAD の失敗時は「録音は継続しています。発話検出を停止しました: …」と表示し、マイクの発話音量監視も利用不能にします。ASR の開始失敗、区間登録失敗、認識結果や失敗イベントの保存失敗は、それぞれ理由を表示します。ライブ ASR が継続できなくても録音保存は継続し、停止後は同じ generation の finalization が保存済み segmentation / ASR を検証して不足分を処理します。録音保存自体が失敗した場合は[キャプチャの保存障害](capture.md#保存障害と健全範囲の確定処理)の扱いになります。

登録・ASR 完了・ASR 失敗の件数と status は、それぞれのイベントが durable になってから更新します。イベント保存失敗は元の error を throw し、その event の行・件数・status を公開しません。
model prepare・音声読取・文字起こしの最初の失敗は `asr.failed` 診断を保存してその attempt を止めます。それ以前の成功は保持し、後続区間は処理しません。未解決 failure がある generation は起動時に自動復旧せず、明示 CLI resume だけが同じ generation で未成功区間を再試行します。利用者の再処理は新 generation を空から開始します。未処理区間や failure があればライブ run の終了結果は成功になりません。終了は進行中の保存・推論を待ち、終了結果を保存した後は同じ completion を返します。

モデルの初期化失敗・判定失敗は録音保存やライブ ASR を停止せず、その対象を保留して通常表示を保ちます。モデルの欠損・未学習・metadata/tokenizer 不正では「発話文の判定を保留しました。判定エンジンを初期化できませんでした: <実際の理由>」と表示し、保存済み ASR 原文は通常表示のまま録音を続けます。ライブ判定のイベント保存・materialization 公開に失敗した場合は保留への置換をせず、理由をエラー表示してその判定キューを停止します。録音と ASR は継続します。

初期化・符号化エラー等の判定保留は明確な理由を表示します。判定失敗の区分と再試行の保存規則は [発話文判定](decision-engine.md) を参照してください。

## ライブ遅延の計測範囲

`scripts/measure_live_latency.sh` は既存音声を原速で durable timeline へ供給し、ライブ VAD と ASR の更新を計測します。マイク録音や GUI の起動は行いません。取得済みの Haas ASR と FluidVAD のモデルが必要です。

入力音声と明示 root の絶対パスを設定して実行する。`--match-default-input` は検証時に指定しない。

```bash
bash scripts/measure_live_latency.sh --sessions-root "$SESSIONS_ROOT" "$AUDIO_FILE"
```

指標は「segment 内の最後の speech range 終了時刻 → 最初の非空の表示データ更新」です。14 秒分割位置や最初の単語を起点にしません。マイク機器の入力遅延、SwiftUI の描画完了時間は測りません。また、この CLI はアプリの熱制御付きライブキューとは異なり、VAD から ASR を直接呼びます。

音声は遅延計測と同じ時計の起点からの絶対予定で投入し、処理時間を後続の塊へ累積させません。出力 JSON は `measurement_scope`、`replay_max_feed_lag_seconds`（append 完了時刻と投入済み音声秒数の差の最大値）、`segment_count`、`updated_count`、`missing_count`、`missing_segment_ids`、個別の遅延、P50、P95、最大値を含みます。遅延の分布は非空更新を得た区間だけから計算し、更新のない区間は missing として別に報告します。更新数がゼロなら分位値は null です。この指標を「発話開始から 1〜3 秒で表示する」保証として扱いません。

## 実装の根拠

- [区間組み立て](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift)、[VAD 設定](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/VADSegmentation.swift)、[Mac の VAD engine](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADSegmentationEngine.swift)、[durable timeline の VAD 読取](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/VADTimelineProcessor.swift)、[FluidAudio 0.15.8 のストリーミング VAD](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/VAD/VadManager+Streaming.swift)
- [録音・確認周期](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveTranscriptionCadence.swift)、[ライブ ASR セッションと durable `segment.created` 登録](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveASRSession.swift)、[HaasASREngine](../app/MacAmbientJev/Sources/MacAmbientJevHaasASR/HaasASREngine.swift)、[Haas ASR manifest](../app/MacAmbientJev/Sources/MacAmbientJevHaasASR/Resources/haas_asr_model.json)
- [ライブ ASR の所有・VAD polling 停止・thermal polling](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveTranscriptionCoordinator.swift)、[FIFO 待ち行列の状態](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveTranscriptionState.swift)、[アプリ側の UI 効果のみ](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+LiveTranscription.swift)、[熱監視と Windows の監視なし方針](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/ThermalMonitoring.swift)（Mac は [MacThermalMonitor](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/MacThermalMonitor.swift)、[Windows の熱状態](windows.md#熱状態)）、[ライブ熱状態ポリシー](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveASRThermalPolicy.swift)、[ライブ判定キュー](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveContentPrioritySession.swift)、[停止と確定への引き継ぎ](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)。関連テスト: [停止中の poll registration 完了と poll/final 両 segment の drain](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveTranscriptionCoordinatorTests.swift)、[durable append 後の registration 完了](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveASRSessionTests.swift)
- [表示 materialization](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[保存済み F・B除去範囲から表示本文への projection](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptTextProjection.swift)、[token span から raw UTF-16 F・B除去範囲への projection](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerSpanProjection.swift)、[Core ML 境界・継続・優先度判定](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)、[画面の表示](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift)、[ASR の構造化結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
- [遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)、[実行スクリプト](../scripts/measure_live_latency.sh)
