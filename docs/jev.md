# Jev・場面・音響範囲

Jev の外部 API を使うのは、録音中と確定後の発話本文の**優先度分類**だけです。録音、VAD、ASR、話者分離、場面判定、近接度・音響範囲判定はローカルで動作します。Jev を利用できなくても録音とローカルの確定結果の公開を継続できます。

## Jev に送る内容

アプリは `ContentPriorityAccess.jev` を使い、設定と Keychain の API キーに応じて分類器を用意します。処理 CLI、システム音声キャプチャ CLI、ライブ遅延計測 CLI は `ContentPriorityAccess.disabled` で、Jev へ送信しません。

分類対象は、録音中のライブ ASR が保存した非空本文と、公開した確定結果の非空本文です。ライブ表示は、判定が届くまでその行（と時間順で後続の行）を表示せず、保存された判定とともに表示します。Jev 無効・失敗・保留・停止の行は即時に通常行として表示します。音声そのもの、話者 embedding、講義全文、前後の発話、場面や近接度の情報を添えて送りません。背景判定による画面非表示とは別の対象判定なので、非空本文であれば画面から除外する背景発話も分類対象になります。

API は https://api.typesafe.ai/v1/systemone へ Bearer 認証で POST し、モデル指定は jev-latest、リクエストのタイムアウトは 15 秒です。この URL は外部 API の endpoint であり、リポジトリ内のパスではありません。送信本文を state、質問を content_priority として送り、PRIMARY / LOW_PRIORITY の二択を求めます。応答の model と入力 token 数は判定ごとに保存します。

## 優先度の採用と原文保持

| Jev の判定 | 表示用の優先度 |
| --- | --- |
| LOW_PRIORITY、confidence ≥ 0.90 | `lowPriority` |
| LOW_PRIORITY、confidence < 0.90 | `primary` |
| PRIMARY | `primary` |
| 未分類・通信失敗 | `primary` として表示し、必要な分類を保留 |

0.90 以上の LOW_PRIORITY は、内容や特定のフィラー語との一致にかかわらず、すべて低優先度として採用します。画面は行を「低優先度の発話」に折り畳み、展開すると原文を読めます。優先度分類は本文の削除・改変ではなく、`transcript.txt` にも低優先度の原文を通常行として含めます。

本文中の局所フィラーを淡い色にするローカル表示は、Jev による行全体の優先度分類とは独立しています。局所フィラーを含むことだけで行全体を折り畳みません。

## 通信失敗と再試行

| 失敗 | バッチの扱い |
| --- | --- |
| HTTP 401 / 403 | バッチを停止。残りを送信せず保留し、API キーの修正を求める |
| HTTP 429 / 5xx、通信エラー、有効な応答を decode できない | バッチを停止。残りを送信せず再試行待ち |
| その他の失敗 | その区間を保留し、後続区間の分類を続ける |

バッチ停止後の区間は送信失敗として再送を繰り返すのではなく、未送信のまま保留します。保留中は primary 表示です。401 / 403 の状態表示は次の文言です。

> Jev の API キーの修正が必要です。意味分類を保留しました

その他の保留は「意味分類を後で再試行します」です。HTTP 応答に判定キーがない、選択肢が未対応などのエラーは区間単位の保留に該当します。保存エラーは通信エラーとは別に扱い、再試行状態を保存できない場合もその理由を表示します。

ライブ分類では、分類器の生成や Keychain の API キー読取が例外で失敗すると、送信前の初期化失敗として「意味分類を後で再試行します。意味分類器を初期化できませんでした: …」に例外の理由を添えて表示します。これは HTTP 401 / 403 の認証拒否や通信失敗によるバッチ停止とは異なり、その行を未分類の通常行として表示し、次の行で分類器の生成を再度試みます。録音保存とライブ ASR は停止しません。

確定結果の保留区間 ID は `processing_metadata.json` に保存します。設定の「保留中の分類を再試行」で再実行でき、Jev が有効な状態で API キーを保存すると再試行を開始します。再試行 run は対象区間だけを送信し、それ以外の区間には公開済みの優先度と元 run・segmentation run・segment ID を引き継いだことを記録します。引き継ぐ以前の判定が見つからない場合は明示エラーにします。

`content_priority.assigned` は表示用 priority と、今回の判定、再試行待ち、元判定からの引き継ぎのいずれかを保持します。ライブ分類は独立した content priority run の `processing.run.started` に `configuration.mode: live` を記録し、判定を保存してから暫定表示へ反映します。この run は確定結果の `active_runs` には選択しません。停止時の取り消しで run が未完了でも、保存済みの classified 判定は再利用できます。

確定処理は全音声を新しい区間と本文で再認識します。その開始時点で同じセッションの保存済みライブ classified 判定を読み、前後の空白・改行だけを trim した本文が確定本文と完全一致する場合は送信せず優先度を引き継ぎます。元 run・segmentation run・segment ID を carried_over に記録し、本文自体は確定 ASR のものを使います。同一本文の判定が複数ある場合はイベント順で最新の classified 判定を使います。本文内の空白、句読点、表記は正規化しません。未分類・保留・停止後の未保存応答は再利用せず、変更された本文を Jev へ送ります。確定 run を選択してから表示を更新し、保留対象は確定区間 ID で再試行します。Jev が現在利用不能でも保存済みの一致判定は引き継ぎ、残りは保留します。

## API キーと利用状況

「設定」→「Jev」で API キーを保存・削除します。キーは macOS Keychain に保存し、設定やセッション JSON、イベントログには保存しません。設定画面を開いたときは、キーの有無を属性だけで確かめるため、キーチェーンの許可は求めません。キー本体を読むのは接続確認と分類のときだけです。Keychain の許可はアプリの署名に結び付くため、app bundle は固定の自己署名証明書で署名します（[README](../README.md) の「ビルドと起動」）。Jev の使用切り替えは優先度分類へのアクセスを止めるもので、録音やローカル認識を停止しません。

「Jev 接続を確認」は「これは接続確認のためのテスト文です。」だけを送り、応答またはエラーを表示します。保存済みキーがない、Jev が停止中、確認実行中なら開始しません。接続確認はセッション分類の usage counter を通りません。

「診断」の Jev 利用状況には次を表示します。

- 送信回数
- 入力 token 数（Jev の報告分）
- 成功件数
- token 数不明の件数
- 失敗件数
- 再試行待ち件数

token 数がない成功応答を 0 token の既知成功としては扱いません。成功件数と「token 数不明の件数」に数え、報告された入力 token 数だけを合計します。再試行待ちは session ID と segment ID の組で重複なく数え、成功で除きます。送信・成功・失敗の回数と token 合計は実行中の usage counter の値で、保留 ID を保存する metadata とは別です。未送信の保留区間は送信回数や失敗件数を増やしません。

## 場面判定は音響のみ

場面は講義、討論、それぞれへの候補、未判定を表します。確定処理の開始時点は**講義**で、冒頭に手がかりのない区間も講義扱いです。Jev の本文意味や近接度は場面判定の入力ではありません。

話者 span から、20 秒の観測窓を 1 秒ずつ進めて次の特徴を求めます。音声が 20 秒より短い場合はその範囲を一つの窓として観測します。

- 活動話者数
- 話者交替率（毎秒の交替数）
- 発声時間内の重なり率
- 最も長く話す話者の占有率
- 観測窓内の発声時間率

状態遷移の実際の根拠は、活動話者数、話者交替率、最多話者の占有率です。

| 遷移先の根拠 | 条件 | 連続観測 |
| --- | --- | --- |
| 討論 | 3 話者以上、交替率 ≥ 0.25、最多話者の占有率 ≤ 0.65 | 8 回で討論候補、12 回で討論 |
| 講義 | 2 話者以下、交替率 ≤ 0.15、最多話者の占有率 ≥ 0.75 | 10 回で講義候補、15 回で講義 |

根拠が途切れると、候補の蓄積を取り消して直前の確定状態へ戻します。単独の短い発話だけで討論へ切り替えません。転換イベントの時刻は状態が変わった観測窓の終了フレームです。発話の場面は、その発話開始時刻以前の最新転換から決めます。同時刻の転換はイベント記録順で決めます。

## 近接度と音響範囲（scope）

近接度は音響範囲判定だけに使います。話者ごとに音声レベルとスペクトルの鋭さの**固定 profile**を作り、セッション内の中央値との差から相対的な近傍・遠方の根拠を得ます。話者が移動するたびに profile を更新する追跡ではなく、物理距離をメートルで推定するものでもありません。

一話者あたり最大 8 個のサンプルを使い、各サンプルは最大 2 秒、候補に必要な長さは 0.35 秒です。安定した profile が 3 話者分未満なら距離判定を未判定にします。対象範囲に活動話者が複数いる、または話者の根拠がない場合も未判定です。音声の根拠が足りないことと読取失敗は区別し、音声読取失敗は scope 段階の失敗として確定 run の公開を止めます。

scope は `near`、`background`、`unknown` の時間 span として保存します。

- 近傍の根拠は、音量・スペクトルから得た confidence の平均が 0.6 以上なら near、それ未満なら unknown です。
- 遠方の根拠から background にするのは、**討論が確定している場面だけ**です。音量とスペクトルの両方の根拠があり、confidence の平均が 0.75 以上必要です。
- 講義や候補状態では、遠いことだけで background にしません。unknown として保持します。
- 発話内で場面が変わる場合は scope の span を転換位置でも分け、その時点の場面を使います。

画面と `transcript.txt` が除外するのは、発話の場面が討論で、scope span が存在し、そのすべてが background の行だけです。一部に near / unknown を含む発話、scope のない発話は丸ごと背景として捨てません。背景として表示しない発話もイベントログと認識本文を保持します。

## 実装の根拠

- [Jev request・応答・エラー](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevClient.swift)、[優先度閾値・バッチ停止](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevDecision.swift)、[判定イベントと再試行 run](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevEnrichmentCoordinator.swift)
- [アプリ／CLI のアクセス境界と保存済みキー](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[アプリの構成](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift)、[処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)、[システム音声 CLI](../app/MacAmbientJev/Sources/MacAmbientJevCaptureSystemAudio/main.swift)、[遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)
- [設定と接続確認](../app/MacAmbientJev/Sources/MacAmbientJev/SettingsView.swift)、[Keychain](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/KeychainStore.swift)、[利用計数](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevUsageCounter.swift)、[診断表示](../app/MacAmbientJev/Sources/MacAmbientJev/DiagnosticsView.swift)
- [場面の観測と記録時刻](../app/MacAmbientJev/Sources/MacAmbientJevCore/SceneCoordinator.swift)、[場面特徴と状態機械](../app/MacAmbientJev/Sources/MacAmbientJevCore/SceneInference.swift)、[確定処理の場面設定](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)
- [近接度 profile](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/TimelineProximityEvidenceProvider.swift)、[scope の閾値](../app/MacAmbientJev/Sources/MacAmbientJevCore/ScopeInference.swift)、[場面と scope の結合](../app/MacAmbientJev/Sources/MacAmbientJevCore/ScopeCoordinator.swift)、[画面と書き出しの行集合](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)
