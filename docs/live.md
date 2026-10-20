# ライブ文字起こし

録音中の文字起こしは暫定表示です。録音保存、発話検出（VAD）、音声認識（ASR）は別々に進み、ASR が遅れても録音保存を止めません。ASR 結果は保存直後に RAW 原文として表示し、区間ごとの境界 assessment が保存された後にだけ、その assessment の F・B除去範囲を表示から除きます。同梱の Core ML 発話文モデルが BTSJ 発話文単位の境界・継続・F・B除去範囲・優先度を任意に判定します。保存 key や内部名の `clause` / `節` はこの発話文単位を識別し、別の節分割器はありません。停止後は、保存音声全体を[確定処理](final.md)して表示を置き換えます。

## VAD と ASR の区切り

- 保存済みの処理タイムラインだけを VAD に渡します。まだディスクに確定していない音声は対象にしません。
- 録音中の durable chunk（確定処理の後に FLAC へ変換して削除する PCM）は 0.5 秒、アプリの checkpoint 確認間隔は 250 ms です。保存済みの 16 kHz mono float32 を直接 FluidAudio のストリーミング VAD に渡します。VAD と ASR は入力形式を検証し、処理段階の SRC・downmix は行いません。
- 発話開始は VAD 確率 0.50 以上、発話終了は 0.35 未満で判定します（FluidAudio の streaming VAD は開始閾値から 0.15 引いた値を終了閾値に使います）。BGM の重なる発話を落とさないための値です。発話開始の前に 0.10 秒の pre-roll を含めます。無音による区間終了の設定は 0.75 秒です。確定処理も同じ設定で区間を作ります。
- 最大区間長は 14 秒です。区間が 14 秒に達すると、区間開始から 12〜14 秒の範囲で RMS が最も小さい 20 ms frame（絶対 sample 0 に揃えた 320 sample）の中点で分割します。同じ値なら早い frame を選びます。語の途中で切って境界で語が重複するのを減らすためで、14 秒に達した時点でこの範囲の音声は処理済みなので先読みはしません。分割用のエネルギー履歴は直近 3 秒分（150 frame）だけを保持し、必要な範囲が履歴にない場合はプログラムの誤りとして停止します。
- ASR に送るのは、VAD が閉じた区間、または分割した区間です。長い連続発話では最初の区間が閉じるまで初表示が遅れます。14 秒は表示遅延の上限ではなく、音声区間の最大長です。
- 発話開始から始まる独立区間は、pre-roll を含めて 0.5 秒未満なら ASR に送りません。無音や雑音の短い断片から ASR が「はい。」などを生成するのを防ぐためで、0.5 秒未満の本物の相づちも送られません。分割後の端数は continuation として保持し、この最小長では捨てません。ただし Qwen3-ASR の入力が 20 ms 未満なら推論せず空本文を返すため、端数区間が残ることと文字が表示されることは別です。

ファイル replay は capture device を開かず、ファイルまたは指定した device 相当形式を原速で ingress に投入します。replay input と保存形式は別で、durable timeline とイベント frame 座標は常に 16 kHz mono です。詳細は[原速 replay のライブ遅延計測](testing.md#原速-replay-のライブ遅延計測)を参照してください。
- 検出した区間は ASR の待ち行列に入れる前に `segment.created` として保存します。ライブ経路は `asr.pending` を書きません。このイベントは確定処理の ASR 待ち状態に使います。
- 未認識区間の新規登録・同じ ID の再登録は認識済み行を変えず、ライブセッション内の行配列を返します。登録の progress 取得は履歴全体の sort・materialization・ID 集合差の生成を行いません。待ち件数は保存済み登録 ID 数と保存済み ASR 完了・失敗 ID 数から求めます。行の更新は ASR 完了・失敗の保存後と、保存済みの発話文イベント（境界判定・発話文・優先度）の適用時に行います。ライブセッションは保存した区間の順序と ASR の結果（認識済み・空・失敗・未処理）を独立した判定キューへ渡し、空の区間や失敗した区間も次区間の判定に使えるようにします。空白・改行・句読点だけの ASR 原文は空の結果です。
- アプリのライブ ASR 待ち行列はバッチごとの `SegmentReference` だけを保持します。`AudioCheckpoint` はセッションごとに最新の保存済み checkpoint を 1 件だけ保持し、各バッチの認識時に使います。保存範囲は単調に伸びるため、最新 checkpoint は待機中の全区間を含みます。checkpoint の chunk 一覧・フレーム数・gap 一覧をバッチごとに保持せず、区間参照はメモリ内に残します。冷却後も登録順で処理し、停止後のライブ処理終了・取消時にキューと checkpoint を解放します。

`LiveTranscriptionState.enqueue` の前提条件は、区間が空でなく、失敗が記録されていないことです。VAD が空の終端区間を返す場合、coordinator は enqueue 前に空を除外します。`await registerLiveSegments` の待機中に ASR 認識失敗が記録されることがあり、登録完了後に coordinator は失敗状態を再確認し、失敗済みならキューへ追加しません。認識失敗が記録されると、既存の待機バッチも破棄します。一方、区間登録の永続化失敗は失敗を記録しても既存の未処理キューを空にせず保持します。未処理キューが残る間はアイドル時のモデル解放条件を満たさず、確定処理または取消時の後始末までモデルは解放されません。

ASR は Qwen3-ASR をローカルで実行し、言語指定は日本語（ja）です。実エンジン名は qwen3-asr-swift、モデル ID は aufklarer/Qwen3-ASR-1.7B-MLX-8bit です。この ID はモデル配布元の識別子であり、リポジトリ内のパスではありません。`asr.completed` の engine/model は実際に認識したエンジンの来歴から取得します。

録音中は話者分離を行わず、話者見出しを付けません。停止後の話者境界はライブ本文から確定するのではなく、発話区間検出・話者分離・音声認識の3段階からなる共通の確定処理で計算します。

## 画面の状態と操作

ヘッダーに画面全体の状態を表示します。行ごとのライブ／確定マークはありません。

| 表示 | 意味 |
| --- | --- |
| ライブ（暫定） | 録音中の結果、または確定できなかった際に保持する暫定結果 |
| 確定処理中 | 保存音声の確定処理を実行中 |
| 確定済み | 公開済みの確定結果 |

画面と `transcript.txt` は同じ表示用 projection を使い、表示本文が空白・改行だけでない認識済み発話をすべて含めます。認識不能と、空白・改行・句読点だけの ASR 原文は `asr.completed` の `outcome: empty` で表し、「聞き取れませんでした」などの文字列に一致しただけでは除外しません。

表示本文は、ASR 原文に区間ごとの保存済み assessment の `filler_ranges` を適用してフィラー・相槌を除去し、その後、優先度が保存済みの LOW 発話文 slice を別に除いた本文です。保存フィールド `filler_ranges` は `{start,end}` object の配列で、フィラー（F）と相槌（B）を表示本文から除く raw UTF-16 範囲を表します。各 token の `span_probs` は `O=0, F=1, D=2, B=3` の argmax で label を決め、同点なら添字の小さい label を選びます。token span が重なる scalar は後の token の label で上書きし、どの token span にも含まれない scalar は O とします。原文の各 Character は構成するすべての scalar が F または B（F/B 混在も可）のときだけ除去し、ひとつでも O または D の scalar があれば Character 全体を残します。隣接して除去される Character は raw UTF-16 範囲にまとめます。F・B除去範囲の直後に連続して接する句読点だけを併せて除き、空白は変更・正規化しません。[TranscriptTextProjection](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptTextProjection.swift) は保存済み範囲を投影するだけで、materialization は辞書やモデルを使いません。assessment が未保存・保留・失敗の区間は RAW 原文のままです。assessment が保存されれば発話文の続き待ちや優先度待ちでもその区間のフィラー・相槌除去は反映されます。優先度未判定・保留・再試行待ちの slice は除きません。PRIMARY と LOW の発話文が混在する行は LOW slice 以外を表示し、本文が空または空白・改行だけになった行（フィラー・相槌だけの行、全発話文が LOW の行）は表示しません。ASR イベントの原文は変更せず、画面、選択コピー、読み上げ、アクセシビリティと `transcript.txt` は共通の表示本文を使います。UI は投影済み本文を描画するだけで独自判定はしません。行の状態は次のとおりです。

| 状態 | 表示 |
| --- | --- |
| 発話文の続き待ち | 保存済み assessment の F・B除去範囲を適用した本文を表示し、保存済み LOW slice も除く。行の下に「発話文の続き待ち」と表示。次区間の境界判定まで発話文を閉じない |
| 境界判定を保留中 | assessment が未保存の範囲は RAW 原文を表示し、分割しない。別区間に保存済み assessment があれば、その F・B除去範囲を適用 |
| 優先度判定を待っています | 保存済み assessment の F・B除去範囲と保存済み LOW slice を適用。未判定・再試行待ち slice は本文を表示 |
| 判定済み | 保存済み assessment の F・B除去範囲と保存済み LOW slice を適用した本文を表示 |

状態は時刻ボタンの popover にも表示します。

行は本文だけのテキストで、開閉の矢印を持ちません。行頭の時刻を押すと、節の判定状態と話者区間を popover で確認できます。popover は時刻ボタンの右側を指定して開き、ウィンドウ左端の外へ出る配置を避けます。同じ話者の連続行は 4pt、話者見出しで始まる行は 12pt の上余白で区切ります。

## 録音中の発話文判定

ASR 原文を保存した直後は RAW 本文を表示し、まだ境界 assessment が保存されていない区間ではフィラー・相槌除去を行いません。境界 assessment の保存後にその区間の F・B除去範囲に含まれるテキストが表示から除かれ、発話文が続き待ち、優先度未判定・保留・再試行待ちでもフィラー・相槌除去は反映されます。境界 assessment が未保存・保留・失敗なら原文のままです。LOW 発話文 slice は優先度保存後に別に消えます。ASR イベントの原文は変わりません。判定結果を待って行や後続行を隠すことはありません。判定キューは時間順の保存済み ASR 区間を処理し、判定の待機・失敗は録音、ASR の登録・認識・表示へ伝播しません。録音・VAD・ASR の drain は判定と独立しています。

境界判定単位は BTSJ 発話文です。候補となる句読点・閾値に従ってモデルが境界と次区間への継続を判定し、コードが発話文を組み立てます。保存名 `clause` / `節` はこの発話文を識別するだけで、別の節分割処理はありません。通常は次区間の ASR が保存されてから境界判定し、継続入力にはその先頭 60 Character だけを使います。テキスト列の終端では次区間なしで扱いますが、本文のある終端区間も、候補がなくても F・B除去範囲を得るため source-only 境界推論を実行して assessment を保存します。終端を理由に request や推論を省略しません。区間をまたぐ発話文は後続区間の判定まで閉じません。

一つの論理境界 request は、候補と原文対応 token を網羅する複数の source-only window、および次区間があれば継続入力を含みます。候補境界と F・B除去範囲の推論、継続推論は別入力でも一 request で、F・B除去範囲は source-only window の出力だけから得ます。本文のある終端区間は候補がなくても F・B除去範囲用の source-only window を推論し、request と assessment を保存します。長い原文は連続 piece を切らず複数 window に分けます。一 piece が上限を超える場合や必要な窓を作れない場合は境界 request 全体を失敗として保留し、確率を作って補いません。request の入力 token 数は全 window と継続入力の実数を合計します。次区間が保存された後に、閉じた非空の発話文を最大 40 件ずつ優先度 batch へ渡します。未閉鎖の末尾は対象外です。優先度は最大 40 件を一 batch とし、内部では sequence ごとに直列推論しますが一 request と数え、入力 token は全 sequence の実数の合計を記録します。判定に時間の上限はなく、行表示も判定を待ちません。境界・発話文・優先度は保存された後だけ表示へ反映します。

ライブ materialization は区間・ASR 原文・表示行・閉じた発話文を source/reference 索引に保持します。ASR 完了では新しい行だけを作り、保存済み判定イベントでは影響する source の行だけを更新します。全イベントを再 replay しません。開いた末尾は区間ごとの immutable link で保持し、継続ごとに過去の末尾をコピーしません。長い区間横断発話文の閉鎖・優先度更新では、その発話文に含まれる全区間を更新します。長さによる打ち切りはありません。

source の同一性、境界候補、次区間の原文 head、時間順、組み立て結果との一致、発話文と優先度の重複は batch 公開前に検証します。不正 batch は組み立て cursor と索引を戻し、行とイベント列のいずれも一部だけ公開しません。snapshot の配列は Swift の copy-on-write を使い、保存時の全履歴 materialization と同じ表示行・発話文範囲・優先度になります。原文・イベント・行・発話文の索引は保存履歴に比例して増えます。増分処理は無関係な履歴の再解析と一時作業領域を抑えますが、総メモリには一定上限を設けません。

判定キューは batch ごとに provider factory から coordinator を取得します。Core ML tagger のロード結果（成功・失敗とも）は factory 内で cache され、アプリを再起動するまで再ロードしません。同時に要求されたロードは一つにまとまります。

モデルの初期化失敗、符号化失敗、または判定結果の検証失敗なら、該当境界／優先度を保留して本文を表示したままにします。境界保留では分割せず、継続を no と偽装しません。優先度だけが保留の発話文も本文を表示します。ASR gap は本文をまたいで推測せず、前の境界を `asr_gap` で保留します。空の成功 ASR 区間はテキスト列を終端し、その前の保留を成功に変えず次の列と切り離します。録音先頭が ASR gap の場合も後続の先頭を独立発話文とは推測しません。

判定 `processing.run.started` の provenance は run 開始時に実際にロードした tagger の engine/model/revision を記録します。本文のある各区間には、終端で候補がない場合も F・B除去範囲を得る実際の境界 request があり、終端を理由に判定呼出しや provenance を省略しません。`unavailable` はモデルの初期化失敗や ASR gap 等で tagger を取得していない場合に限ります。成功した各判定呼出しの request record は request ID と入力 token 数を持ち、モデルは run の provenance が示します。モデル確認は live 判定 request ではありません。

録音停止時は、ライブ ASR の残りを処理してテキスト列の終端を伝え、境界待ちを解放します。確定処理はイベント append と同じファイル lock で、その時点までに保存済みのライブ classified 結果だけを固定してからキューを取り消します。推論の完了は待ちません。取り消し後に遅れて返った結果は保存も表示もせず、固定より後に保存された結果も確定処理の再利用には使いません。確定と再試行の比較は各 run 自身の保存済み F・B除去範囲を原文へ適用し、発話文 parts を区間順に区切りなしで連結した UTF-8 byte 列が完全一致する場合だけ優先度を carry-over します。trim・空白・句読点・Unicode 正規化はしません。[確定時の再利用](final.md)

ASR drain は判定に関係なく動作します。CLI の `ContentPriorityAccess.disabled` は境界・F・B除去範囲・優先度の判定を行わず、assessment と `filler_ranges` を作らないため、表示本文は RAW 原文のままです。ライブ判定と確定判定は共通の confidence ≥ 0.90 の優先度表示規則を使います。

新しい行への自動追従は利用者のスクロール操作で解除します。アプリ自身のスクロールアニメーションでは解除しません。「最新へ戻る」を押すと追従を再開し、その場で末尾へ移動します。

## 発熱時の動作

以下は macOS の録音中の動作です。Windows では熱監視を行わず、熱状態によるライブ ASR の待機・停止はありません（[Windows の熱状態](windows.md#熱状態)）。

| 熱状態 | ライブ ASR |
| --- | --- |
| nominal / fair | 待機を入れず処理 |
| serious | 次の待機バッチを取り出す前に 750 ms 待機 |
| critical、または未知の熱状態 | 新しいバッチの認識を一時停止 |

`critical` または状態不明では「発熱のためライブ表示を一時停止中」と表示します。録音保存、VAD、durable な区間登録は継続し、滞留時間が長くても認識を強行しません。熱状態を 1 秒ごとに確認し、認識を再開できる状態になったらキューの最古のバッチから処理します。`serious` まで冷えた場合は 750 ms 待機します。進行中の同期推論を途中で中断する仕組みではありません。

このライブ熱判定は録音中に適用します。録音停止後の残存ライブキューはこの判定では待たずに処理します。続く確定処理は実際の `critical` の間だけ一時停止し、状態不明では一時停止しません。一時停止中は公開済み結果を保持し、冷却後は新しい run で全量を再実行します。CLI は明示的な再開操作を必要とします。[確定処理](final.md#発熱による一時停止と再開)

## ライブ処理の失敗

VAD の失敗時は「録音は継続しています。発話検出を停止しました: …」と表示し、マイクの発話音量監視も利用不能にします。ASR の開始失敗、区間登録失敗、認識結果や失敗イベントの保存失敗は、それぞれ理由を表示します。ライブ ASR が継続できなくても録音保存は継続し、停止後に保存音声を確定処理します。録音保存自体が失敗した場合は[キャプチャの保存障害](capture.md#保存障害と健全範囲の確定処理)の扱いになります。

登録・ASR 完了・ASR 失敗の件数は、それぞれのイベントの保存が成功してから進めます。保存失敗はエラーとして返し、そのイベントの行・件数を公開しません。未処理区間が残る場合や保存済み ASR 失敗がある場合、ライブ run の終了結果は成功になりません。終了は進行中の保存・推論を待ち、終了結果を保存した後は同じ completion を返します。

モデルの初期化失敗・判定失敗は録音保存やライブ ASR を停止せず、その対象を保留して通常表示を保ちます。モデルの欠損・未学習・metadata/tokenizer 不正では「発話文の判定を保留しました。判定エンジンを初期化できませんでした: <実際の理由>」と表示し、保存済み ASR 原文は通常表示のまま録音を続けます。ライブ判定のイベント保存・materialization 公開に失敗した場合は保留への置換をせず、理由をエラー表示してその判定キューを停止します。録音と ASR は継続します。

初期化・符号化エラー等の判定保留は明確な理由を表示します。判定失敗の区分と再試行の保存規則は [発話文判定](decision-engine.md) を参照してください。

## ライブ遅延の計測範囲

`scripts/measure_live_latency.sh` は既存音声を原速で durable timeline へ供給し、ライブ VAD と ASR の更新を計測します。マイク録音や GUI の起動は行いません。Qwen3-ASR と VAD のキャッシュ済みモデルが必要です。

入力音声と明示 root の絶対パスを設定して実行する。`--match-default-input` は検証時に指定しない。

```bash
bash scripts/measure_live_latency.sh --sessions-root "$SESSIONS_ROOT" "$AUDIO_FILE"
```

指標は「VAD 区間の終了フレームの時刻 → 最初の非空の表示データ更新」です。14 秒分割区間では分割位置が起点です。発話開始からの時間、マイク機器の入力遅延、SwiftUI の描画完了時間は測りません。また、この CLI はアプリの熱制御付きライブキューとは異なり、VAD から ASR を直接呼びます。

音声は遅延計測と同じ時計の起点からの絶対予定で投入し、処理時間を後続の塊へ累積させません。出力 JSON は `measurement_scope`、`replay_max_feed_lag_seconds`（append 完了時刻と投入済み音声秒数の差の最大値）、`segment_count`、`updated_count`、`missing_count`、`missing_segment_ids`、個別の遅延、P50、P95、最大値を含みます。遅延の分布は非空更新を得た区間だけから計算し、更新のない区間は missing として別に報告します。更新数がゼロなら分位値は null です。この指標を「発話開始から 1〜3 秒で表示する」保証として扱いません。

## 実装の根拠

- [区間組み立て](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift)、[VAD 設定](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADSegmentationEngine.swift)、[durable timeline の VAD 読取](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/VADTimelineProcessor.swift)、[FluidAudio 0.15.8 のストリーミング VAD](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/VAD/VadManager+Streaming.swift)
- [録音・確認周期](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveTranscriptionCadence.swift)、[ライブ ASR セッション](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveASRSession.swift)、[Qwen3-ASR](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeQwen3ASREngine.swift)、[モデル ID](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASR.swift)
- [ライブ ASR の所有と熱状態ポーリング](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveTranscriptionCoordinator.swift)、[FIFO 待ち行列の状態](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveTranscriptionState.swift)、[アプリ側の UI 効果のみ](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+LiveTranscription.swift)、[熱監視と Windows の監視なし方針](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/ThermalMonitoring.swift)（Mac は [MacThermalMonitor](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/MacThermalMonitor.swift)、[Windows の熱状態](windows.md#熱状態)）、[ライブ熱状態ポリシー](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveASRThermalPolicy.swift)、[ライブ判定キュー](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveContentPrioritySession.swift)、[provider factory](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/DecisionProviderFactory.swift)、[停止と確定への引き継ぎ](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)
- [表示 materialization](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[保存済み F・B除去範囲から表示本文への projection](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptTextProjection.swift)、[token span から raw UTF-16 F・B除去範囲への projection](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerSpanProjection.swift)、[Core ML 境界・継続・優先度判定](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)、[文字起こし画面](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift)、[ASR の構造化結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
- [遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)、[実行スクリプト](../scripts/measure_live_latency.sh)
