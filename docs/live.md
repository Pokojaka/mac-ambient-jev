# ライブ文字起こし

録音中の文字起こしは暫定表示です。録音保存、発話検出（VAD）、音声認識（ASR）は別々に進み、ASR が遅れても録音保存を止めません。ASR 結果は保存直後に通常の本文として表示し、その後に選択中の判定エンジン（Jev API またはローカル Core ML）が BTSJ 発話文単位の境界・優先度を任意に判定します。保存 key や内部名の `clause` / `節` はこの発話文単位を識別し、別の節分割器はありません。停止後は、保存音声全体を[確定処理](final.md)して表示を置き換えます。

## VAD と ASR の区切り

- 保存済みの処理タイムラインだけを VAD に渡します。まだディスクに確定していない音声は対象にしません。
- 録音中の durable chunk（確定処理の後に FLAC へ変換して削除する PCM）は 0.5 秒、アプリの checkpoint 確認間隔は 250 ms です。保存済みの 16 kHz mono float32 を直接 FluidAudio のストリーミング VAD に渡します。VAD と ASR は入力形式を検証し、処理段階の SRC・downmix は行いません。
- 発話開始の前に 0.10 秒の pre-roll を含めます。無音による区間終了の設定は 0.75 秒、最大区間長は 14 秒です。
- ASR に送るのは、VAD が閉じた区間、または 14 秒に達して分割した区間です。長い連続発話では最初の区間が閉じるまで初表示が遅れます。14 秒は表示遅延の上限ではなく、音声区間の最大長です。
- 最初の発話区間の最小長は 20 ms です。14 秒分割後の端数は continuation として保持し、この最小長では捨てません。たとえば 14 秒 + 4 ms の発話範囲は、14 秒と 4 ms の二つの区間になります。ただし Qwen3-ASR の入力が 20 ms 未満なら推論せず空本文を返すため、端数区間が残ることと文字が表示されることは別です。

ファイル replay は capture device を開かず、ファイルまたは指定した device 相当形式を原速で ingress に投入します。replay input と保存形式は別で、durable timeline とイベント frame 座標は常に 16 kHz mono です。詳細は[原速 replay のライブ遅延計測](testing.md#原速-replay-のライブ遅延計測)を参照してください。
- 検出した区間は ASR の待ち行列に入れる前に `segment.created` として保存します。ライブ経路は `asr.pending` を書きません。このイベントは確定処理の ASR 待ち状態に使います。
- 未認識区間の新規登録・同じ ID の再登録は認識済み行を変えず、ライブセッション内の行配列を返します。登録の progress 取得は履歴全体の sort・materialization・ID 集合差の生成を行いません。待ち件数は保存済み登録 ID 数と保存済み ASR 完了・失敗 ID 数から求めます。行の更新は ASR 完了・失敗の保存後と、保存済みの選択 provider による発話文イベント（境界判定・発話文・優先度）の適用時に行います。ライブセッションは保存した区間の順序と ASR の結果（認識済み・空・失敗・未処理）を独立した判定キューへ渡し、空の区間や失敗した区間も次区間の判定に使えるようにします。
- アプリのライブ ASR 待ち行列はバッチごとの `SegmentReference` だけを保持します。`AudioCheckpoint` はセッションごとに最新の保存済み checkpoint を 1 件だけ保持し、各バッチの認識時に使います。保存範囲は単調に伸びるため、最新 checkpoint は待機中の全区間を含みます。checkpoint の chunk 一覧・フレーム数・gap 一覧をバッチごとに保持せず、区間参照はメモリ内に残します。冷却後も登録順で処理し、停止後のライブ処理終了・取消時にキューと checkpoint を解放します。

ASR は Qwen3-ASR をローカルで実行し、言語指定は日本語（ja）です。実エンジン名は qwen3-asr-swift、モデル ID は aufklarer/Qwen3-ASR-1.7B-MLX-8bit です。この ID はモデル配布元の識別子であり、リポジトリ内のパスではありません。`asr.completed` の engine/model は実際に認識したエンジンの来歴から取得します。

録音中は話者分離を行わず、話者見出しを付けません。停止後の話者境界はライブ本文から確定するのではなく、発話区間検出・話者分離・音声認識の3段階からなる共通の確定処理で計算します。

## 画面の状態と操作

ヘッダーに画面全体の状態を表示します。行ごとのライブ／確定マークはありません。

| 表示 | 意味 |
| --- | --- |
| ライブ（暫定） | 録音中の結果、または確定できなかった際に保持する暫定結果 |
| 確定処理中 | 保存音声の確定処理を実行中 |
| 確定済み | 公開済みの確定結果 |

画面と `transcript.txt` は同じ表示用 projection を使い、フィラー除去後の本文が空白・改行だけでない認識済み発話をすべて含めます。認識不能は `asr.completed` の `outcome: empty` で表し、「聞き取れませんでした」などの文字列に一致しただけでは除外しません。

選択 provider が LOW_PRIORITY と判定した発話文は淡色で表示します。行を折り畳むのは、行の可視本文を覆う全ての節が保存済み LOW で、続き待ち・境界保留・優先度保留がない行だけです。PRIMARY と LOW の節が混在する行はそのまま両方を表示します。フィラー除去後に本文が空または空白・改行だけになった行は表示しません。ASR の原文は保存したまま、画面、選択コピー、読み上げ、アクセシビリティと `transcript.txt` は共通のフィラー除去済み本文を使います。除去範囲と原文の UTF-16 座標への写像は共通 projection で作り、行本文と表示 fragment の両方へ適用します。淡色表示と行の折り畳みは [TranscriptPriorityPresentationPolicy](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptPriorityPresentation.swift) 一箇所で決め、UI はその結果を描画するだけで独自判定はしません。行の状態は次のとおりです。

| 状態 | 表示 |
| --- | --- |
| 発話文の続き待ち | 待機部分は通常色、保存済み LOW 発話文は淡色。行の下に「発話文の続き待ち」と表示。次区間の境界判定まで発話文を閉じない |
| 境界判定を保留中 | 分割せず通常色 |
| 優先度判定を待っています | 閉じた発話文の境界は反映済み。未判定・再試行待ちの発話文だけ通常色にし、同じ行の保存済み LOW 発話文は淡色を保つ |
| 判定済み | 発話文ごとに通常色または淡色 |

状態は時刻ボタンの popover にも表示します。

通常の行は本文だけのテキストで、開閉の矢印を持ちません。行頭の時刻を押すと、節の判定状態と話者区間を popover で確認できます（低優先度の行も同じ）。popover は時刻ボタンの右側を指定して開き、ウィンドウ左端の外へ出る配置を避けます。同じ話者の連続行は 4pt、話者見出しで始まる行は 12pt の上余白で区切ります。

## 録音中の発話文判定

ASR 結果を保存した直後に本文を通常色で表示します。選択 provider の結果を待って行や後続行を隠すことはありません。判定キューは時間順の保存済み ASR 区間を処理し、provider の待機・失敗は録音、ASR の登録・認識・表示へ伝播しません。録音・VAD・ASR の drain は選択 provider と独立しています。

境界判定単位は両 provider とも BTSJ 発話文です。候補となる句読点・共通閾値に従って、選択 provider が候補境界と次区間への継続を判定し、コードが発話文を組み立てます。保存名 `clause` / `節` はこの発話文を識別するだけで、節を別途分割する処理はありません。次区間の ASR が保存されるまで境界判定を進めず、次区間先頭 60 Character だけを継続判定に使います。そのため発話文の確定は遅れることがあり、区間をまたぐ発話文は後続区間の判定まで閉じません。区間終端が明らかな場合は次区間なしで扱います。

ローカル Core ML provider は候補境界用と継続用を別々に符号化・推論します。長い入力は連続 piece 単位の窓に分けて判定し、一つの piece が上限を超える場合や junction を含む窓を作れない場合は境界要求全体を失敗として保留します。外部通信へ切り替えたり確率を作ったりしません。Jev provider に限り、候補と継続を Noul の一つの API request にまとめます。次区間が保存された後に、閉じた非空の発話文を最大 40 件ずつ選択 provider の優先度 batch へ渡します。未閉鎖の末尾は対象外です。Jev の優先度は Choice です。ローカル優先度も最大 40 件の provider 呼出しを一 batch とし、内部では sequence ごとに直列推論しますが一 request と数え、入力 token は全 sequence の実数の合計を記録します。Jev の HTTP timeout は 15 秒ですが、これは行表示・判定完了の上限ではありません。境界・発話文・優先度は保存された後だけ表示へ反映します。

ライブ materialization は区間・ASR 原文・表示行・閉じた発話文を source/reference 索引に保持します。ASR 完了では新しい行だけを作り、保存済み判定イベントでは影響する source の行だけを更新します。全イベントを再 replay しません。開いた末尾は区間ごとの immutable link で保持し、継続ごとに過去の末尾をコピーしません。長い区間横断発話文の閉鎖・優先度更新では、その発話文に含まれる全区間を更新します。長さによる打ち切りはありません。

source の同一性、境界候補、次区間の原文 head、時間順、組み立て結果との一致、発話文と優先度の重複は batch 公開前に検証します。不正 batch は組み立て cursor と索引を戻し、行とイベント列のいずれも一部だけ公開しません。snapshot の配列は Swift の copy-on-write を使い、保存時の全履歴 materialization と同じ表示行・発話文範囲・優先度になります。原文・イベント・行・発話文の索引は保存履歴に比例して増えます。増分処理は無関係な履歴の再解析と一時作業領域を抑えますが、総メモリには一定上限を設けません。

選択 engine は「設定」→「発話文の判定」で選びます。Picker は録音中・処理中・接続確認／モデル確認中・再試行中は変更できません。共通の一時停止 `decision.isPaused` はどちらの provider も停止します。factory は各 request のたびに現在の選択と停止設定を厳密に読み直し、選択 provider だけを作ります。Core ML tagger のロード結果（成功・失敗とも）は factory 内で cache され、エンジン選択を変えるかアプリを再起動するまで再ロードしません。モデルの差し替えと失敗したロードのやり直しは、選択変更か再起動で反映されます。同時に要求されたロードは一つにまとまり、エンジン選択の変更はロードを待ちません。ローカル provider は API key を必要とせず、Keychain と HTTP を使いません。

選択 provider が未設定・停止・初期化失敗、ローカル符号化失敗、または応答検証失敗なら、該当境界／優先度を保留して表示を通常状態に保ち、別 provider へフォールバックしません。境界保留では分割せず、継続を no と偽装しません。優先度だけが保留の発話文も通常色です。ASR gap は本文をまたいで推測せず、前の境界を `asr_gap` で保留します。空の成功 ASR 区間はテキスト列を終端し、その前の保留を成功に変えず次の列と切り離します。録音先頭が ASR gap の場合も後続の先頭を独立発話文とは推測しません。

Jev 固有の輸送・状態: Jev は境界に Noul、優先度に Choice を使い、HTTP timeout は 15 秒です。401 / 403 は Jev API key の修正が必要な専用状態・表示にし、Jev の後続送信を停止します。429 / 5xx、通信・応答失敗も Jev の後続送信を停止して保留します。Keychain 読取エラーは Jev 選択時だけ起こり得る Jev 固有の初期化失敗です。これらの Jev 固有 status や Keychain 条件をローカル provider の仕様とはしません。

判定 `processing.run.started` の provenance は run 開始時に実際に選択・初期化された coordinator の engine/model/revision を記録します。終端区間に候補がなく質問が0で provider request がない場合も coordinator を利用できていれば選択 provider の provenance です。`unavailable` は coordinator が未設定・停止・初期化失敗、ASR gap 等で provider が初期化されていない場合に限ります。成功した各 provider 呼出しについては request record の実 provider/model/revision を正とします。Jev API の接続確認・モデル確認は live 判定 request ではありません。

録音停止時は、ライブ ASR の残りを処理してテキスト列の終端を伝え、境界待ちを解放します。確定処理はイベント append と同じファイル lock で、その時点までに保存済みのライブ classified 結果だけを固定してからキューを取り消します。通信またはローカル推論の完了は待ちません。取り消し後に遅れて返った応答は保存も表示もせず、固定より後に保存された結果も確定処理の再利用には使いません。確定時は本文が UTF-8 bytes で完全一致する保存済み判定だけを優先度 carry-over します。[確定時の再利用](final.md)

ASR drain は選択 provider に関係なく動作し、CLI の `ContentPriorityAccess.disabled` は Jev request と Core ML tagger の両方を無効化します。ライブ判定と確定判定は共通の confidence ≥ 0.90 の優先度表示規則を使います。

新しい行への自動追従は利用者のスクロール操作で解除します。アプリ自身のスクロールアニメーションでは解除しません。「最新へ戻る」を押すと追従を再開し、その場で末尾へ移動します。

## 発熱時の動作

| 熱状態 | ライブ ASR |
| --- | --- |
| nominal / fair | 待機を入れず処理 |
| serious | 次の待機バッチを取り出す前に 750 ms 待機 |
| critical、または未知の熱状態 | 新しいバッチの認識を一時停止 |

critical では「発熱のためライブ表示を一時停止中」と表示します。録音保存、VAD、区間登録、キューへの追加は継続します。滞留時間が長くても認識を強行しません。1 秒ごとに熱状態を確認し、critical を下回るとキューの最古のバッチから再開します。serious まで冷えた場合は 750 ms の待機を入れます。進行中の同期推論を途中で中断する仕組みではありません。

このライブ熱判定は録音中に適用します。録音停止後の残存ライブキューはこの判定では待たずに処理し、続く確定処理には独立した critical 時の一時停止があります。確定処理は保存範囲全体を認識するので、ライブ表示が停止していた時間も対象になります。

## ライブ処理の失敗

VAD の失敗時は「録音は継続しています。発話検出を停止しました: …」と表示し、マイクの発話音量監視も利用不能にします。ASR の開始失敗、区間登録失敗、認識結果や失敗イベントの保存失敗は、それぞれ理由を表示します。ライブ ASR が継続できなくても録音保存は継続し、停止後に保存音声を確定処理します。録音保存自体が失敗した場合は[キャプチャの保存障害](capture.md#保存障害と健全範囲の確定処理)の扱いになります。

登録・ASR 完了・ASR 失敗の件数は、それぞれのイベントの保存が成功してから進めます。保存失敗はエラーとして返し、そのイベントの行・件数を公開しません。未処理区間が残る場合や保存済み ASR 失敗がある場合、ライブ run の終了結果は成功になりません。終了は進行中の保存・推論を待ち、終了結果を保存した後は同じ completion を返します。

選択 provider の未設定・停止・初期化失敗・判定失敗は録音保存やライブ ASR を停止せず、その対象を保留して通常表示を保ちます。ローカルモデルの欠損・未学習・metadata/tokenizer 不正では「発話文の判定を後で再試行します。判定エンジンを初期化できませんでした: <実際の理由>」と表示し、保存済み ASR 原文は通常表示のまま録音を続けます。ローカル符号化・応答検証に失敗しても Jev へ fallback しません。ライブ判定のイベント保存・materialization 公開に失敗した場合は保留への置換や別 provider への fallback をせず、理由をエラー表示してその判定キューを停止します。録音と ASR は継続します。

Jev 固有の状態: 401 / 403 は Jev API key の修正が必要な専用表示を出して Jev の後続送信を止めます。429 / 5xx、通信・応答失敗も Jev の後続送信を止めて保留します。Keychain 読取例外は Jev 選択時だけの初期化失敗です。Jev transport と応答失敗の区分、および再試行の保存規則は [発話文判定](decision-engine.md) を参照してください。

選択 provider の factory は次の要求で現在の設定を読み直します。停止・初期化・ローカル符号化エラー等の判定保留は明確な理由を表示し、別 provider へ切り替えません。

## ライブ遅延の計測範囲

`scripts/measure_live_latency.sh` は既存音声を原速で durable timeline へ供給し、ライブ VAD と ASR の更新を計測します。マイク録音や GUI の起動は行いません。Qwen3-ASR と VAD のキャッシュ済みモデルが必要です。

入力音声と明示 root の絶対パスを設定して実行する。`--match-default-input` は検証時に指定しない。

```bash
bash scripts/measure_live_latency.sh --sessions-root "$SESSIONS_ROOT" "$AUDIO_FILE"
```

指標は「VAD 区間の終了フレームの時刻 → 最初の非空の表示データ更新」です。14 秒分割区間では分割位置が起点です。発話開始からの時間、マイク機器の入力遅延、SwiftUI の描画完了時間は測りません。また、この CLI はアプリの熱制御付きライブキューとは異なり、VAD から ASR を直接呼びます。

出力 JSON は `measurement_scope`、`segment_count`、`updated_count`、`missing_count`、`missing_segment_ids`、個別の遅延、P50、P95、最大値を含みます。遅延の分布は非空更新を得た区間だけから計算し、更新のない区間は missing として別に報告します。更新数がゼロなら分位値は null です。この指標を「発話開始から 1〜3 秒で表示する」保証として扱いません。

## 実装の根拠

- [区間組み立て](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift)、[VAD 設定](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADSegmentationEngine.swift)、[durable timeline の VAD 読取](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADTimelineProcessor.swift)
- [録音・確認周期](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveTranscriptionCadence.swift)、[ライブ ASR](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveASRSession.swift)、[Qwen3-ASR](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeQwen3ASREngine.swift)、[モデル ID](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASR.swift)
- [ライブキューと熱制御](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+LiveTranscription.swift)、[熱状態ポリシー](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveASRThermalPolicy.swift)、[選択 provider のライブ判定キュー](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveContentPrioritySession.swift)、[provider factory](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/SelectedDecisionProviderFactory.swift)、[停止と確定への引き継ぎ](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)
- [表示規則](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[文字起こし画面](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift)、[局所フィラー](../app/MacAmbientJev/Sources/MacAmbientJevCore/FillerTextSpanDetector.swift)、[ASR の構造化結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
- [遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)、[実行スクリプト](../scripts/measure_live_latency.sh)
