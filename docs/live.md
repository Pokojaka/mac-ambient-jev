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
- 未認識区間の新規登録・同じ ID の再登録は認識済み行を変えず、ライブセッション内の行配列を返します。登録の progress 取得は履歴全体の sort・materialization・ID 集合差の生成を行いません。待ち件数は保存済み登録 ID 数と保存済み ASR 完了・失敗 ID 数から求めます。行の更新は ASR 完了の保存後と、保存済み Jev 優先度イベントの適用時（active run の変更を含む）に行います。
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

[Jev の優先度分類](jev.md)で低優先度になった行は「低優先度の発話」として 1 行に折り畳み、展開すると原文を読めます。低優先度は削除ではありません。本文中の局所フィラーは淡い文字色で表示しますが、文字列を改変せず、行全体の低優先度分類とも区別します。

通常の行は本文だけのテキストで、開閉の矢印を持ちません。行頭の時刻を押すと、場面・音響範囲・話者区間を popover で確認できます（低優先度の行も同じ）。popover は時刻ボタンの右側を指定して開き、ウィンドウ左端の外へ出る配置を避けます。同じ話者の連続行は 4pt、話者見出しで始まる行は 12pt の上余白で区切ります。

録音中も、非空の ASR 本文が保存された直後に Jev の分類キューへ渡します。**行は Jev の判定が届くまで表示しません。** 判定が届くと、LOW_PRIORITY（confidence ≥ 0.90）の行は最初から「低優先度の発話」に折り畳んだ状態で、それ以外は通常行として現れ、通常行を表示してから折り畳み直すことはありません。待機中の行より後の行は先に表示せず、時間順を保ちます。Jev が無効（`ContentPriorityAccess.jev` でない、または設定オフ）の場合と、その行の分類が失敗・保留・停止した場合は、待たずに通常行として即時に表示します。ライブ判定も `ContentPriorityPolicy` の confidence ≥ 0.90 の規則を使い、暫定結果として扱います。アプリの Jev 設定と API キーによるアクセス判定を通った場合だけ送信し、CLI は送信しません。

Jev キューはライブ ASR の drain と独立しています。未認識の区間は分類対象にならないため、発熱で ASR が停止している間も未認識の本文を送信しません。録音停止時には進行中の Jev task と未送信キューを取り消し、残存ライブ ASR の処理では分類を開始しません。確定処理は Jev の終了を待たず、保存済みの判定だけを本文の一致で再利用します。[確定時の再利用](final.md)

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

Jev の失敗は録音保存やライブ ASR を停止しません。401 / 403 はライブ分類バッチの後続送信を止め、「Jev の API キーの修正が必要です。意味分類を保留しました」と表示します。429 / 5xx、通信エラー、無効な応答も後続送信を止め、「意味分類を後で再試行します」と表示します。未分類行は primary のまま保持します。詳細な失敗区分と確定結果の保留再試行は [Jev](jev.md) を参照してください。

分類器の生成や Keychain の API キー読取が例外で失敗した場合は、HTTP 応答による失敗とは別に、「意味分類を後で再試行します。意味分類器を初期化できませんでした: …」として例外の理由を表示します。その行は分類を送信せず通常行として表示し、録音保存とライブ ASR は継続します。分類器の生成は次の行でも再度試みます。

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
- [ライブキューと熱制御](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+LiveTranscription.swift)、[熱状態ポリシー](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveASRThermalPolicy.swift)
- [表示規則](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[文字起こし画面](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift)、[局所フィラー](../app/MacAmbientJev/Sources/MacAmbientJevCore/FillerTextSpanDetector.swift)、[ASR の構造化結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
- [遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)、[実行スクリプト](../scripts/measure_live_latency.sh)
