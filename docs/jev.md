# Jev の節境界・優先度判定

Jev の外部 API を使うのは、発話本文の**節の境界判定**と**節の優先度判定**だけです。録音、VAD、ASR、話者分離、フィラー除去はローカルで動作します。確定処理のローカル必須段階は segmentation・diarization・ASR の3段階です。Jev を利用できなくても録音、ライブ ASR、ローカルの確定結果の公開を継続します。

## 処理の流れ

1. コードが ASR 原文の `、。？！?!` の直後（原文末尾を除く）を候補として列挙します。
2. Jev Noul が、各候補の直前で**文または独立した節が終わるか**（文末、または「けど」「が」「し」などで前の節が完結するか）と、区間末尾が次区間の先頭へ続くかを判定します。継続の判定には区間間の無音秒数を添え、次区間が「ですね」「ますので」のような語尾・助動詞・接続助詞から始まる場合は無音の長さにかかわらず継続とするよう指示します。主語・目的語・修飾・テ接続・条件・理由・引用の途中では切りません。
3. コードが採用境界（確率 `> 0.5`）と継続（確率 `> 0.5`）から節を組み立てます。節は複数の ASR 区間にまたがることができ、各区間の原文範囲（parts）で表します。
4. 既存のフィラー検出で原文から削除範囲を求め、節に属する残りの本文を空白を挿入せずに連結します。
5. Jev Choice が、閉じた節の除去後本文を PRIMARY / LOW_PRIORITY に分類します。

形態素解析、規則エンジン、辞書など別方式の分割器は使いません。候補にない位置では切れず、句点があっても Jev が no なら切れません。この精度の限界を別方式で補いません。

## Jev に送る内容

アプリは `ContentPriorityAccess.jev` を使い、設定と Keychain の API キーに応じて分類器を用意します。処理 CLI、システム音声キャプチャ CLI、ライブ遅延計測 CLI は `ContentPriorityAccess.disabled` で、Jev へ送信しません。

API は https://api.typesafe.ai/v1/systemone へ Bearer 認証で POST し、モデル指定は jev-latest、リクエストのタイムアウトは 15 秒です。この URL は外部 API の endpoint であり、リポジトリ内のパスではありません。音声、話者 embedding、話者情報、セッション ID、区間 ID は送りません。

### 境界判定（Noul）

一区間につき一回だけ送信します。state は次の三つです。

- `text`: 対象区間の **ASR 原文**（フィラーを含む）に候補印を挿入したもの。印の挿入位置はコードが列挙した候補の UTF-16 offset だけを使い、原文の文字列を保ち、原文末尾の句読点には印を置きません。印には原文に存在しないマーカーフレームを使い、保存する範囲や本文には混ぜません。
- `next_text`: 次区間の原文の先頭 60 Character 以内。次区間があるときだけ置きます。
- `silence_before_next`: 次区間があるときだけ置きます。現区間の終了から次区間の開始までの無音秒数を小数1桁（例: `0.0 秒`）で示し、区間が重なる場合は `0.0 秒` です。`0.0 秒` は区間の長さ上限で機械的に区切られたことを意味すると継続質問に説明します。

全候補の質問 `b0001` 等と継続質問 `continuation` を同じリクエストに入れ、一区間を候補用と継続用の二送信に分けません。候補がなくても次区間があれば継続質問だけを送ります。前区間、次区間の全文は送りません。

次区間は、後続区間の ASR が保存されてから決まります。

| 後続区間 | 扱い |
| --- | --- |
| 非空の ASR 結果 | `next_text` に先頭 60 Character を置き、`silence_before_next` に現区間終了から次区間開始までの無音秒数を小数1桁で置く（重なりは `0.0 秒`） |
| 空の ASR 結果 | テキスト列の終端。`next_text`、`silence_before_next` と継続質問を省く |
| ASR 失敗（ASR gap） | 送信せず境界判定を保留（`asr_gap`）。gap をまたいで本文を推測しない |
| なし（録音停止・最後の区間） | テキスト列の終端。次区間がないため `silence_before_next` を省く |

ASR gap の後に空の ASR 結果が保存された場合も、そこでテキスト列を区切ります。gap より前の未解決本文は保留のまま残し、空結果の後の本文は独立した列として判定します。空結果の後に別の ASR gap があれば、その直後の本文の先頭は再び未解決です。ライブ、確定・再試行、保存済みイベントの再読込で同じ規則を使います。

終端の区間に候補もなければ質問が0なので送信しません。Jev が利用可能な場合に限り、その区間を一つの範囲とする結果（`terminal_without_questions`）を記録します。Jev 不可のときはこの規則で節を作りません。

### 優先度判定（Choice）

閉じた節のうち、フィラー除去後の本文が空白・改行だけでない節だけを送ります。state は `{"u0001": "節本文", ...}` で、質問 `p0001` 等は対応する `u` key を直接指定します。他の key の本文は判定対象外と指示し、文脈や原文を添えません。一送信は最大 40 節で、原文順に並べます。ライブでは一つの境界応答で新しく閉じた節をまとめ、確定と再試行では全境界の後に、最大40節ずつ直列に送ります。40 節が貯まるまで待つことも、batch を一節ずつの送信へ分解することもしません（対象が一節なら一節の batch です）。境界と優先度を一つの送信にまとめることはしません。

ライブ・確定・再試行は [ClausePriorityBatches.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClausePriorityBatches.swift) の同じ直列 batch 処理を使います。ライブは送信する batch ごとに現在の設定から分類器を取得し、設定停止・キー未設定・初期化失敗の batch は未送信の保留にします。その保留だけで後続 batch の取得を止めません。送信を停止する失敗後は、同じ実行の後続の境界・優先度判定でも分類器取得・HTTP 送信を行わず、未送信の節を最大 40 節ずつ `request: null` の保留イベントとして保存します。失敗した batch も部分成功にせず全対象を保留にします。取り消しは保留を作らず、遅れて戻った応答を保存・表示しません。引き継ぎは Choice batch の対象外です。

### 応答の検証

全 requested answer key、質問と一致する type、Choice の二択・両選択肢の probabilities・confidence、非空 model、usage object を検証します。確率と confidence は有限の 0..1、token は未報告なら nil、報告された値は非負整数です。不足・余分な回答、型不一致、不正値はリクエスト全体を拒否し、部分結果や架空の確率を記録しません。HTTP の並列化、自動再送、同文の cache、失敗した batch の一節ずつの再送はしません。

Choice は両確率の和が 1 に近いこと（絶対誤差 ≤ 0.01）、選択した option が最大確率であること（同率最大はどちらも可）、confidence が二択の式 `2 * max(probabilities) - 1` と整合すること（絶対誤差 ≤ 0.015）も検証します。比較には浮動小数点演算の端数用に `1e-12` を加え、値を正規化・補正しません。Noul は単一の確率なので和・Choice confidence の検査はなく、有限の閉区間 0..1 を厳密に検証します。矛盾した応答は既存の `invalidResponse` 経路で送信を停止し、全対象を保留します。

根拠は [API reference](https://docs.typesafe.ai/api.md) の「和が1」「最高確率の option」と [Confidence](https://docs.typesafe.ai/confidence.md) の Choice 式です。API は丸め桁数や許容誤差を保証していません。[Choice の文書例](https://docs.typesafe.ai/primitives/choice.md) は二桁の確率・confidence を示すため、各値の丸め幅 0.005 から、二択の和に 0.01、confidence に `2 * 0.005 + 0.005 = 0.015` のローカル許容幅を使います。[記録済み実API観測](records/2026-10-09-clause-acceptance.md) は Noul 0.15〜0.78、Choice confidence 0.94／0.96／1.00 を報告していますが、Choice の全確率や元応答の桁数は残していません。したがって、この幅を実応答の最大誤差やAPIの保証値とは主張しません。

## 優先度の採用と表示

| Jev の判定 | 節の表示用優先度 |
| --- | --- |
| LOW_PRIORITY、confidence ≥ 0.90 | `lowPriority` |
| LOW_PRIORITY、confidence < 0.90 | `primary`（実際の判定は記録する） |
| PRIMARY | `primary` |
| 未分類・保留 | 通常表示 |

表示方針は [TranscriptPriorityPresentationPolicy](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptPriorityPresentation.swift) の一箇所です。行内の節 slice ごとに LOW の節を淡色にし、PRIMARY と LOW の混在はそのまま表示します。行を畳むのは、行の可視本文を覆う全ての非空の節が保存済み LOW で、境界の未解決部分も保留もない行だけです。続き待ち・境界保留・優先度保留の部分がある行は通常表示で、畳みません。区間をまたぐ節は、所属する全ての行の slice に同じ判定を適用します。話者の違いで節の結合を拒否しません。

画面、コピー、accessibility、`transcript.txt` はフィラー除去後の本文を使い、空白・改行だけでない全ての認識済み本文を表示・書き出しします。LOW の本文も残します。ASR イベントの原文は変更しません。

## 保留と再試行

| 失敗 | 扱い |
| --- | --- |
| HTTP 401 / 403 | 送信を停止。残りを送信せず保留し、API キーの修正を求める |
| HTTP 429 / 5xx、通信エラー、有効な応答を decode できない | 送信を停止。残りを送信せず保留 |
| その他の失敗（回答不足、未対応の選択肢など） | そのリクエストの全対象を保留し、次のリクエストを続ける |

境界判定が保留の区間は分割せず、フィラー除去後の行本文を未分類の通常行として表示します。その区間へ続く未解決の節に属する行、ASR gap や保留の直後の区間の先頭も、閉じた節として扱いません。すでに独立して閉じた節の保存結果は保持します。優先度判定だけが保留の節は通常表示で、全 LOW として扱いません。境界の保留を「継続しない」と偽装しません。

401 / 403 の状態表示は「Jev の API キーの修正が必要です。意味分類を保留しました」、その他の保留は「意味分類を後で再試行します」です。分類器の生成や Keychain の読取が例外で失敗した場合は、その理由を添えて「意味分類を後で再試行します。意味分類器を初期化できませんでした: …」と表示し、録音とライブ ASR は継続します。

初期化失敗の理由は、後続区間の ASR が保存されて境界・優先度の保留状態が更新されても表示に残します。一般的な再試行メッセージだけで上書きしません。保留イベントにも理由を保存し、実際に送信しなかった処理を外部リクエストとして計数しません。

確定結果の保留は `processing_metadata.json` の `pending_clause_boundary_segments`（境界判定が未成立の区間）と `pending_content_priority_clauses`（優先度が未成立の節）に保存します。設定の「保留中の判定を再試行」で再実行でき、Jev が有効な状態で API キーを保存したときも再試行を開始します。送信前に全対象を検証し、公開済みの保留でない対象、別 run の対象、引き継ぎ元の欠落は明示エラーにします。

- **優先度だけの再試行**: 公開済みの境界判定 run をそのまま使い、指定した節だけを 40 節ずつ送ります。新しい優先度 run で、その他の全ての節の判定を元 run・イベント・節参照付きで引き継ぎます。指定しなかった保留は保留のまま引き継ぎます。
- **境界を含む再試行**: 新しい境界判定 run を作り、公開済みの成功判定を元 run・イベント参照付きで引き継ぎ、保留の区間だけ Noul を送ります。全区間から節を組み直し、除去後本文が UTF-8 byte 列で完全一致する変わらない節の優先度を元参照の検証付きで引き継ぎ、新しく閉じた節と指定した保留だけを Choice に送ります。ASR と音声は再実行しません。
- ASR gap で必要な次区間の原文がない保留は、同じ ASR では回復できません。送信前に「次の区間に音声認識結果がないため、境界を再判定できません。録音を再処理してください」とエラーにします。

新しい境界・優先度 run と保留一覧は一回の metadata 書き込みで公開します。未公開の再試行 run の結果は使わず、公開済みの snapshot から再構築します。

## ライブから確定への再利用

確定処理の開始時点でイベントログを読み、その時点で保存済みのライブ優先度 run の classified 判定だけを固定します。その後にライブの Jev キューを取り消します。固定より後に保存された応答や未保存の応答は使いません。未完了のライブ run でも保存済みの判定は使えます。

確定の節本文（フィラー除去後の連結本文）がライブの節本文と **UTF-8 byte 列で完全一致**する場合だけ、送信せず優先度を引き継ぎます。trim、空白・句読点・Unicode の正規化、類似一致はしません。フィラーの位置だけが違って除去後本文が同じなら引き継ぎます。同じ本文の判定が複数あればイベント順で最新の classified を使い、後の保留はそれを無効にしません。節の parts と ID は確定 ASR と確定の境界判定のもので、ライブの境界判定は確定区間へ移しません。境界判定が成立しなかった確定区間に、ライブの節を持ち込みません。境界判定の後に Jev が使えなくなった場合も、一致する節は引き継ぎます。

## API キーと利用状況

「設定」→「Jev」で API キーを保存・削除します。キーは macOS Keychain に保存し、設定やセッション JSON、イベントログには保存しません。設定画面を開いたときは、キーの有無を属性だけで確かめるため、キーチェーンの許可は求めません。キー本体を読むのは接続確認と判定のときだけです。Keychain の許可はアプリの署名に結び付くため、app bundle は固定の自己署名証明書で署名します（[README](../README.md) の「ビルドと起動」）。Jev の使用切り替えは境界判定と優先度判定へのアクセスを止めるもので、録音やローカル認識を停止しません。

「Jev 接続を確認」は、一対象の Choice で「これは接続確認のためのテスト文です。」だけを送り、応答またはエラーを表示します。保存済みキーがない、Jev が停止中、確認実行中なら開始しません。接続確認は利用状況に数えません。エラーには API キー、対象 key、送信本文、応答本文を含めません。

「診断」の Jev 利用状況は、実際の HTTP リクエスト単位で次を表示します。

- 合計: 送信回数、入力 token 数（Jev の報告分）、成功件数、token 数不明の件数、失敗件数
- 境界判定リクエストと優先度判定リクエストのそれぞれの内訳
- 境界判定の保留区間数と優先度判定の保留節数

候補数や節数を送信回数にせず、一送信の token を節ごとに重複して加算しません。入力 token 未報告の成功は「token 数不明の件数」に数え、0 token の既知成功にしません。接続確認、ライブ判定の再利用、質問0の終端、未送信の保留は送信回数を増やさず、未送信の保留は失敗にも数えません。通信成功後の保存失敗は通信の失敗に数えません。取り消されたリクエストは送信回数だけを残します。

保留件数はセッションと対象（区間または節）の組で重複なく管理し、request の計数とは独立です。公開した snapshot が解決した保留、または置き換えた run（ライブから確定、区間から節、古い境界判定 run から新しい run）の保留を明示的に除き、累計の request と token は保持します。Jev の分類器を作れない場合でも共有の計数器を更新します。metadata から利用状況を合成しません。

## 実装の根拠

- [Jev request・応答・エラー](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevClient.swift)、[共有型・Noul閾値・batch上限](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTypes.swift)、[優先度閾値・バッチ停止](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevDecision.swift)、[保存 payload](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseRecords.swift)、[節の組み立て](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseBoundaryAssembly.swift)、[確定・再試行の snapshot](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevEnrichmentCoordinator.swift)、[ライブの判定キュー](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveContentPrioritySession.swift)、[保存結果の検証と再利用](../app/MacAmbientJev/Sources/MacAmbientJevCore/EventLogTranscriptReader.swift)
- [アプリ／CLI のアクセス境界と保存済みキー](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[アプリの構成](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift)、[処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)、[システム音声 CLI](../app/MacAmbientJev/Sources/MacAmbientJevCaptureSystemAudio/main.swift)、[遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)
- [設定と接続確認](../app/MacAmbientJev/Sources/MacAmbientJev/SettingsView.swift)、[Keychain](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/KeychainStore.swift)、[利用計数](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevUsageCounter.swift)、[診断表示](../app/MacAmbientJev/Sources/MacAmbientJev/DiagnosticsView.swift)
- [画面と書き出しの行集合・節 slice](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)
