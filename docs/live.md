# ライブ文字起こし

録音中の文字起こしは暫定表示です。録音保存、発話検出（VAD）、音声認識（ASR）は別々に進み、ASR が遅れても録音保存を止めません。停止後は、保存音声全体を[確定処理](final.md)して表示を置き換えます。

## VAD と ASR の区切り

- 保存済みの処理タイムラインだけを VAD に渡します。まだディスクに確定していない音声は対象にしません。
- 録音の durable chunk は 0.5 秒、アプリの checkpoint 確認間隔は 250 ms です。VAD 用の音声は 16 kHz に変換し、FluidAudio のストリーミング VAD に渡します。
- 発話開始の前に 0.10 秒の pre-roll を含めます。無音による区間終了の設定は 0.75 秒、最大区間長は 14 秒です。
- ASR に送るのは、VAD が閉じた区間、または 14 秒に達して分割した区間です。長い連続発話では最初の区間が閉じるまで初表示が遅れます。14 秒は表示遅延の上限ではなく、音声区間の最大長です。
- 最初の発話区間の最小長は 20 ms です。14 秒分割後の端数は continuation として保持し、この最小長では捨てません。たとえば 14 秒 + 4 ms の発話範囲は、14 秒と 4 ms の二つの区間になります。ただし Qwen3-ASR の入力が 20 ms 未満なら推論せず空本文を返すため、端数区間が残ることと文字が表示されることは別です。
- 検出した区間は ASR の待ち行列に入れる前に `segment.created` として保存します。ライブ経路は `asr.pending` を書きません。このイベントは確定処理の ASR 待ち状態に使います。

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

[Jev の優先度分類](jev.md)で低優先度になった行は「低優先度の発話」として折り畳み、展開すると原文と詳細を読めます。低優先度は削除ではありません。本文中の局所フィラーは淡い文字色で表示しますが、文字列を改変せず、行全体の低優先度分類とも区別します。

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

## ライブ遅延の計測範囲

`scripts/measure_live_latency.sh` は既存音声を原速で durable timeline へ供給し、ライブ VAD と ASR の更新を計測します。マイク録音や GUI の起動は行いません。Qwen3-ASR と VAD のキャッシュ済みモデルが必要です。

入力音声の絶対パスをシェル変数 AUDIO_FILE に設定して実行します。

```bash
bash scripts/measure_live_latency.sh "$AUDIO_FILE"
```

指標は「VAD 区間の終了フレームの時刻 → 最初の非空の表示データ更新」です。14 秒分割区間では分割位置が起点です。発話開始からの時間、マイク機器の入力遅延、SwiftUI の描画完了時間は測りません。また、この CLI はアプリの熱制御付きライブキューとは異なり、VAD から ASR を直接呼びます。

出力 JSON は `measurement_scope`、`segment_count`、`updated_count`、`missing_count`、`missing_segment_ids`、個別の遅延、P50、P95、最大値を含みます。遅延の分布は非空更新を得た区間だけから計算し、更新のない区間は missing として別に報告します。更新数がゼロなら分位値は null です。この指標を「発話開始から 1〜3 秒で表示する」保証として扱いません。

## 実装の根拠

- [区間組み立て](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift)、[VAD 設定](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADSegmentationEngine.swift)、[durable timeline の VAD 読取](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADTimelineProcessor.swift)
- [録音・確認周期](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveTranscriptionCadence.swift)、[ライブ ASR](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveASRSession.swift)、[Qwen3-ASR](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeQwen3ASREngine.swift)、[モデル ID](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASR.swift)
- [ライブキューと熱制御](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+LiveTranscription.swift)、[熱状態ポリシー](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveASRThermalPolicy.swift)
- [表示規則](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[文字起こし画面](../app/MacAmbientJev/Sources/MacAmbientJev/LiveTranscriptView.swift)、[局所フィラー](../app/MacAmbientJev/Sources/MacAmbientJevCore/FillerTextSpanDetector.swift)、[ASR の構造化結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
- [遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)、[実行スクリプト](../scripts/measure_live_latency.sh)
