# ライブ文字起こし

録音中の文字起こしは暫定表示です。録音保存、発話検出（VAD）、音声認識（ASR）は別々に進み、ASR が遅れても録音保存を止めません。停止後は、保存音声全体を[確定処理](final.md)して表示を置き換えます。

## VAD と ASR の区切り

- 保存済みの処理タイムラインだけを VAD に渡します。まだディスクに確定していない音声は対象にしません。
- 録音中の durable chunk（確定処理の後に FLAC へ変換して削除する PCM）は 0.5 秒、アプリの checkpoint 確認間隔は 250 ms です。保存済みの 16 kHz mono float32 を直接 FluidAudio のストリーミング VAD に渡します。VAD と ASR は入力形式を検証し、処理段階の SRC・downmix は行いません。
- 発話開始の前に 0.10 秒の pre-roll を含めます。無音による区間終了の設定は 0.75 秒、最大区間長は 14 秒です。
- ASR に送るのは、VAD が閉じた区間、または 14 秒に達して分割した区間です。長い連続発話では最初の区間が閉じるまで初表示が遅れます。14 秒は表示遅延の上限ではなく、音声区間の最大長です。
- 最初の発話区間の最小長は 20 ms です。14 秒分割後の端数は continuation として保持し、この最小長では捨てません。たとえば 14 秒 + 4 ms の発話範囲は、14 秒と 4 ms の二つの区間になります。ただし Qwen3-ASR の入力が 20 ms 未満なら推論せず空本文を返すため、端数区間が残ることと文字が表示されることは別です。

ファイル replay は capture device を開かず、ファイルまたは指定した device 相当形式を原速で ingress に投入します。replay input と保存形式は別で、durable timeline とイベント frame 座標は常に 16 kHz mono です。詳細は[原速 replay のライブ遅延計測](testing.md#原速-replay-のライブ遅延計測)を参照してください。
- 検出した区間は ASR の待ち行列に入れる前に `segment.created` として保存します。ライブ経路は `asr.pending` を書きません。このイベントは確定処理の ASR 待ち状態に使います。
- 未認識区間の新規登録・同じ ID の再登録は認識済み行を変えず、ライブセッション内の行配列を返します。登録の progress 取得は履歴全体の sort・materialization・ID 集合差の生成を行いません。待ち件数は保存済み登録 ID 数と保存済み ASR 完了・失敗 ID 数から求めます。行の更新は ASR 完了・失敗の保存後と、保存済みの Jev 節イベント（境界判定・節・優先度）の適用時に行います。ライブセッションは保存した区間の順序と ASR の結果（認識済み・空・失敗・未処理）を Jev キューへ渡し、空の区間や失敗した区間も次区間の判定に使えるようにします。
- アプリのライブ ASR 待ち行列はバッチごとの `SegmentReference` だけを保持します。`AudioCheckpoint` はセッションごとに最新の保存済み checkpoint を 1 件だけ保持し、各バッチの認識時に使います。保存範囲は単調に伸びるため、最新 checkpoint は待機中の全区間を含みます。checkpoint の chunk 一覧・フレーム数・gap 一覧をバッチごとに保持せず、区間参照はメモリ内に残します。冷却後も登録順で処理し、停止後のライブ処理終了・取消時にキューと checkpoint を解放します。

ASR は Qwen3-ASR をローカルで実行し、言語指定は日本語（ja）です。実エンジン名は qwen3-asr-swift、モデル ID は aufklarer/Qwen3-ASR-1.7B-MLX-8bit です。この ID はモデル配布元の識別子であり、リポジトリ内のパスではありません。`asr.completed` の engine/model は実際に認識したエンジンの来歴から取得します。

録音中は話者分離を行わず、話者見出しを付けません。停止後の話者境界や場面・音響範囲はライブ本文から確定するのではなく、共通の確定処理で計算します。

## 画面の状態と操作

ヘッダーに画面全体の状態を表示します。行ごとのライブ／確定マークはありません。

| 表示 | 意味 |
| --- | --- |
| ライブ（暫定） | 録音中の結果、または確定できなかった際に保持する暫定結果 |
| 確定処理中 | 保存音声の確定処理を実行中 |
| 確定済み | 公開済みの確定結果 |

画面と `transcript.txt` は同じ表示用 projection を使います。空白・改行だけの本文と、討論場面で音響範囲がすべて背景の発話を表示しません。認識不能は `asr.completed` の `outcome: empty` で表し、「聞き取れませんでした」などの文字列に一致しただけでは除外しません。

Jev が LOW と判定した節は淡色で表示します。行を折り畳むのは、行の可視本文を覆う全ての節が保存済み LOW で、続き待ち・境界保留・優先度保留がない行だけです。PRIMARY と LOW の節が混在する行はそのまま両方を表示します。フィラー除去後に本文が空または空白・改行だけになった行は表示しません。ASR の原文は保存したまま、画面、選択コピー、読み上げ、アクセシビリティと `transcript.txt` は共通のフィラー除去済み本文を使います。除去範囲と原文の UTF-16 座標への写像は共通 projection で作り、行本文と表示 fragment の両方へ適用します。淡色表示と行の折り畳みは [TranscriptPriorityPresentationPolicy](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptPriorityPresentation.swift) 一箇所で決め、UI はその結果を描画するだけで独自判定はしません。行の状態は次のとおりです。

| 状態 | 表示 |
| --- | --- |
| 節の続き待ち | 待機部分は通常色、保存済み LOW 節は淡色。行の下に「節の続き待ち」と表示。次区間の境界判定まで節を閉じない |
| 境界判定を保留中 | 分割せず通常色 |
| 優先度判定を待っています | 閉じた節の境界は反映済み。未判定・再試行待ちの節だけ通常色にし、同じ行の保存済み LOW 節は淡色を保つ |
| 判定済み | 節ごとに通常色または淡色 |

状態は時刻ボタンの popover にも表示します。

通常の行は本文だけのテキストで、開閉の矢印を持ちません。行頭の時刻を押すと、場面・音響範囲・話者区間を popover で確認できます（低優先度の行も同じ）。popover は時刻ボタンの右側を指定して開き、ウィンドウ左端の外へ出る配置を避けます。同じ話者の連続行は 4pt、話者見出しで始まる行は 12pt の上余白で区切ります。

## 録音中の Jev 判定

ASR の結果を保存した直後に、行を通常色で表示します。Jev の応答を待って行や後続行を隠すことはしません。その後、時間順を保つ Jev キューへ区間を渡します。キューはネットワークを待っても ASR の登録・認識・表示を止めません。

区間の境界判定は、次区間の ASR が保存されるまで送れません（次区間の先頭 60 Character を継続の判定に使うため）。そのため区間内の節の確定も一区間分遅れます。区間をまたぐ節は、続く区間自身の境界判定まで閉じず、長い節は複数区間を待つことがあります。15 秒の Jev タイムアウトは行の表示遅延の上限ではありません。境界応答を保存すると閉じた節を保存し、表示に反映してから、その応答で新しく閉じた節を 40 節までの batch で Choice に送ります。閉じていない末尾の節は送りません。境界応答・節・優先度は保存した後だけ表示に反映します。

ライブの表示用 materialization は、区間・ASR 原文・表示行・閉じた節を source/reference ごとの索引に保持します。ASR 完了では新しい行だけを作り、Jev の境界・節・優先度 batch では影響する source の行だけを更新します。保存済みの全イベントを結合して再 replay することはありません。開いた末尾は区間ごとの immutable link で保持し、継続のたびに過去の末尾をコピーしません。長い区間横断節の閉鎖や優先度更新では、その節に実際に含まれる全区間を更新します。長さによる打ち切りはありません。

source の同一性、境界候補、次区間の原文 head、時間順、組み立てられる節との一致、節と優先度の重複は batch の公開前に検証します。不正な batch は組み立て cursor と索引を戻し、行とイベント列のいずれも一部だけ公開しません。snapshot の配列は Swift の copy-on-write を使い、読み手が古い snapshot を保持している場合だけ変更時に配列を分離します。保存時の全履歴 materialization と同じ表示行・節範囲・優先度になります。

原文・イベント・行・節の索引は保存する履歴に比例して増えます。増分処理が抑えるのは無関係な履歴の再解析と一時作業領域であり、総メモリの一定上限ではありません。古い snapshot を保持したまま更新する場合、配列の copy-on-write に履歴長に比例するコピーが必要です。

Jev が無効（`ContentPriorityAccess.jev` でない、または設定オフ）の場合、分類器の初期化に失敗した場合、送信を停止した場合は、境界判定を保留として保存し、行は分割しない通常行のままです。継続の判定を no として扱いません。優先度だけが保留になった節も通常色です。保存済みの境界と成功した判定は再試行のために保持します。区間の ASR が失敗した場合は、その区間をまたいで本文を推測せず、前の区間の境界判定を `asr_gap` として保留します。後の区間の先頭は独立した節として扱いません。設定で Jev を停止しても録音は止まらず、録音の停止も Jev の停止とは別の操作です。

空の成功 ASR 区間はテキスト列を終端します。その前に保留があっても成功した節に変えず、保留部分を残したまま次のテキスト列と切り離します。録音先頭が ASR gap の場合も、直後の頭を独立節と推測しません。

録音を停止すると、ライブ ASR の残りを処理した後に Jev キューへテキスト列の終端を伝えます。最後の区間は次区間なしで判定でき、すでに判定済みの末尾の節も閉じられます。続いて確定処理が始まり、イベント append と同じファイルロックで同期済みのライブ判定を固定してから Jev キューを取り消します。固定は短い保存処理の終了だけを待ち、キューの通信完了を待ちません。取消後の応答は新たに保存・表示せず、固定より後に append が完了した結果も表示・再利用には使いません。確定処理は保存済み判定を節本文の byte 完全一致で再利用します。[確定時の再利用](final.md)

アプリの Jev 設定と API キーによるアクセス判定を通った場合だけ送信し、CLI は送信しません。ライブ判定も `ContentPriorityPolicy` の confidence ≥ 0.90 の規則を使う暫定結果です。

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

Jev の失敗は録音保存やライブ ASR を停止しません。401 / 403 はライブの後続送信を止め、「Jev の API キーの修正が必要です。意味分類を保留しました」と表示します。429 / 5xx、通信エラー、無効な応答も後続送信を止め、「意味分類を後で再試行します」と表示します。未判定の行は通常色のまま保持します。Jev の判定を保存できない場合はその録音のライブ判定を止め、理由を表示します。詳細な失敗区分と確定結果の保留再試行は [Jev](jev.md) を参照してください。

分類器の生成や Keychain の API キー読取が例外で失敗した場合は、HTTP 応答による失敗とは別に、「意味分類を後で再試行します。意味分類器を初期化できませんでした: …」として例外の理由を表示します。その区間の境界判定を保留にして通常行として表示し、録音保存とライブ ASR は継続します。分類器の生成は次の区間でも再度試みます。

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
- [ライブキューと熱制御](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+LiveTranscription.swift)、[熱状態ポリシー](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveASRThermalPolicy.swift)、[ライブの Jev キュー](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveContentPrioritySession.swift)、[停止と確定への引き継ぎ](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)
- [表示規則](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[文字起こし画面](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift)、[局所フィラー](../app/MacAmbientJev/Sources/MacAmbientJevCore/FillerTextSpanDetector.swift)、[ASR の構造化結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
- [遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)、[実行スクリプト](../scripts/measure_live_latency.sh)
