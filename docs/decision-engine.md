# 発話文の境界・優先度判定

境界判定と優先度判定の単位は、両エンジンとも BTSJ 発話文（以下「発話文」）です。保存形式・コード上の `clause` / `節` はこの発話文単位を識別し、別の節分割器を意味しません。判定エンジンは Jev（API）またはローカル Core ML モデルを選択できます。製品の初期値は明示的に Jev（API）です。エンジン固有の仕様を区別し、この文書では共通の発話文仕様と Jev provider の API・保存・再試行、およびローカル provider の仕様を記載します。外部 Jev API を使うのは発話文の境界・優先度判定だけです。録音、VAD、ASR、話者分離、フィラー除去はローカルで動作します。確定処理のローカル必須段階は segmentation・diarization・ASR の3段階で、判定段階は任意です。選択したエンジンの停止・初期化・判定失敗時に別 provider へ切り替えず、判定結果を保留します。

## 処理の流れ

1. コードが ASR 原文の `、。？！?!` の直後（原文末尾を除く）を UTF-16 offset で候補として列挙します。候補 offset は句読点の後ろで、句読点そのものの位置や原文末尾ではありません。原文末尾に連続する `、。？！?!` の内部には候補を置きません（「本当？！」は候補なし）。
2. 選択した境界判定エンジンが、各候補位置で話された文が BTSJ 発話文として終わるか、また区間末尾と次区間の先頭が同じ発話文かを判定します。節が完結していても「けど」「が」「し」などの接続で内容が続く場合や、倒置・後置・付け足しが続く場合は同じ発話文です。フィラーや言い直し・修復があることだけでは発話文境界にしません。文末の「けど」「が」「し」も語尾だけでは決めず、話された文全体が実際に終わる場合に限り発話文の終わりとします。継続判定では、述語が完結していても次区間に倒置・後置・付け足しとして発話文に付く内容が続けば同じ発話文としてつなぎ、次が独立した発話文なら継続とはしません。
3. コードが採用境界（確率 `> 0.5`）と継続（確率 `> 0.5`）から発話文を組み立てます。発話文は複数の ASR 区間にまたがることができ、各区間の原文範囲（parts）で表します。
4. 既存のフィラー検出で原文から削除範囲を求め、発話文に属する残りの本文を空白を挿入せずに連結します。
5. 選択したエンジンが、閉じた発話文のフィラー除去後本文を PRIMARY / LOW_PRIORITY に分類します。

形態素解析、辞書、規則による別分割・判定は行いません。候補にない位置では切れず、句点があっても判定エンジンが no なら切れません。この精度の限界を別方式で補いません。

## ローカル Core ML provider

「設定」→「発話文の判定」の Picker は `Jev（API）`（raw value `jev`）と `ローカルモデル`（`local-coreml`）を選びます。保存 key は `decision.engine`、使用停止 key は `decision.isPaused` です。初回起動は両 key が存在しない状態で、アプリが明示的な初期化手順で `decision.engine=jev` と `decision.isPaused=true` を書き込みます。利用者が再開するまで外部 API には何も送りません。片方だけが存在する場合、および以降に値の欠損・型・値が不正な場合は、すべて設定エラーとして扱い、初期値の補完やリセットをしません。Picker は録音中、処理中、接続／モデル確認中、再試行中は変更できません。選択したローカル provider は Keychain を読まず、HTTP/Jev 呼出しも行わず、失敗時に Jev へ切り替わりません。

ローカルモデルは手動で配置したファイルだけを読みます。保存場所は `paths.modelsRoot` の `clause-tagger` 子ディレクトリで、sandbox container 内では `~/Library/Containers/app.mac-ambient-jev/Data/Library/Application Support/mac-ambient-jev/models/clause-tagger/` です。直下に ClauseTagger.mlpackage と tokenizer.json が必要です。自動ダウンロード、設定可能な別パス、パス上書きはありません。モデル ID sbintuitions/modernbert-ja-30m-multitagger は外部モデル識別子であり、ローカルのファイルパスではありません。

モデルをロードすると macOS 15 で Core ML に compile し、compute units は CPU only、tensor dtype は float32 です。入力 `input_ids` は int32、形状 `[1,L]`（`2...192`）です。モデル出力は `boundary_probs` `[1,L,2]`、`span_probs` `[1,L,3]`、`priority_probs` `[1,2]` の float32 に厳密に一致しなければなりません。span 出力は形状・値を検証しますが判定には使いません。

`.mlpackage` の creator-defined metadata は次の6 key を全て必要とし、値・型を検証します。`model_id` は sbintuitions/modernbert-ja-30m-multitagger、`model_revision` は sorted state-key bytes と tensor bytes から計算した SHA-256 hash の64桁小文字 hex、`training_status` は `trained`、`tokenizer_sha256` は tokenizer.json の生 bytes の SHA-256、`unit_policy` は `btsj-utterance-sentence`、`encoding_revision` は `1` です。`training_status` が `trained` 以外の package はアプリ判定に使用できません。metadata 欠損・不正、tokenizer hash 不一致、型・shape・語彙検証失敗は初期化エラーとなります。境界・優先度の表示は通常の保留状態のままとし、架空確率を記録せず、別 provider へフォールバックしません。ロードの結果（成功も失敗も）は provider factory が選択 engine ごとに cache し、選択が変わるかアプリを再起動するまで再 compile しません。失敗は同じエラーを返し続けます。compile で作る一時 `.mlmodelc` ディレクトリはロード直後に削除します。差し替えたモデルを使うにはアプリ再起動が必要です。

### ローカル符号化と推論

共通の UTF-16 候補 offset を句読点直後として使います。Unicode scalar を正規化せず保持し、原文から末尾連続の `、。？！?!` だけを取り除きます。空白は trim しません。符号化時は各 `、。？！?!` を中立記号 `、` として扱います。句読点間を piecewise Unigram lattice で tokenize し、句読点は語彙 ID `275` を強制します。special-token 追加を tokenizer に任せず、先頭に `[CLS]` ID `6`、末尾に `[SEP]` ID `4` を付けます。入力は `[CLS]` + 内容 token（最大190）+ `[SEP]` で最大192 token です。優先度用の符号化は内容 token が190を超えると先頭190 token で切り、その後ろに `[SEP]` を付けます。これは訓練時の符号化（Python `enc` が192 token に切る）と同じ規則で、切った後ろの内容は判定に使いません。

Tokenizer 実装は swift-transformers Tokenizers `1.3.4` の Unigram を直接使い、tokenizer 宣言どおり Metaspace の `prepend_scheme=never`・`split=false` と UTF-8 byte fallback を wrapper 側で実装します。tokenizer.json はモデル metadata の SHA-256 と一致した時だけ読み、一度だけ typed vocabulary（byte を保つ）として解析します。ファイル内容はこの hash で固定されるため、構造の再検証はしません。byte fallback で表現できない入力はエラーにし、別 tokenizer や方式を試しません。

境界候補用入力は対象区間だけ、継続用入力は対象区間の末尾句読点を除いた原文 + 強制 comma + 次区間先頭を連結し、連結後の末尾 `、。？！?!` も除いてから、別々に符号化します。継続確率は連結入力の junction token における `1 - boundary_probs[junction][1]` です。候補判定と継続判定を同じ入力に混ぜません。内容が190 token を超える入力は、「、」などで区切られた連続 piece を単位にした窓（各190 token 以下）に分けて判定します。piece は途中で切りません。各候補は、その token の左右の文脈の短い方が最大になる窓で判定し、同じ窓の候補は一回の推論にまとめます。継続判定は junction とその直前の piece、次区間先頭の token を同じ窓に含め、左右文脈の短い方が最大の窓を使います。一つの piece が190 token を超える、または junction と次区間先頭を含む窓を作れない場合は encoding error として当該リクエスト全体を保留します。確率の捏造はしません。

優先度判定は一つの batch で最大40発話文をそれぞれ sequence として推論します。優先度入力は発話文全体を一つの入力にするため窓分割せず、内容が190 token を超える場合は先頭190 token に切り詰めます（エラーにしません）。空白・改行だけの対象は推論せず batch 全体を `invalidTargets` で拒否します（Jev の空対象拒否と同じです）。句読点だけの対象（例「？」）は `[CLS]` `[SEP]` の2 token に符号化され、他の対象と同じくモデルが判定します。`priority_probs[0][0]` は PRIMARY、`priority_probs[0][1]` は LOW_PRIORITY の確率です。`span_probs` は検証だけに使い、選択しません。PRIMARY と LOW_PRIORITY の確率が同率なら PRIMARY を選択し、confidence は `2 * max(probabilities) - 1` です。LOW_PRIORITY を表示へ反映する閾値は他 provider と同じ `0.90` のままです。

「モデルを確認」は provider factory が cache した同じ tagger の model ID と revision を表示するだけで（別に compile しません）、classifier request、利用回数、token を発生させません。検証失敗は通常の初期化失敗／保留です。ロード結果は成功も失敗も、エンジン選択を変えるかアプリを再起動するまで cache されます。失敗後に model package を直しても、選択変更か再起動まで再ロードしません。同時に要求されたロードは一つにまとまり、compile と load は設定の変更を待たせません。

## Jev に送る内容

アプリは選択中の engine を使います。Jev 選択時だけ Keychain の API key を読み、Jev provider を用意します。処理 CLI、システム音声キャプチャ CLI、ライブ遅延計測 CLI の `ContentPriorityAccess.disabled` は両 engine の境界・優先度判定を無効にします。これらの CLI は HTTP を送らず Core ML tagger もロードせず、segmentation・diarization・ASR の必須3段階は通常どおり実行します。判定 run は任意です。

API は https://api.typesafe.ai/v1/systemone へ Bearer 認証で POST し、モデル指定は jev-latest、リクエストのタイムアウトは 15 秒です。この URL は外部 API の endpoint であり、リポジトリ内のパスではありません。音声、話者 embedding、話者情報、セッション ID、区間 ID は送りません。

### 境界判定（Noul）

一区間につき一回だけ送信します。state は次の二つだけです。

- `text`: 対象区間の **ASR 原文**（フィラーを含む）に候補印を挿入したもの。印の挿入位置はコードが列挙した候補の UTF-16 offset だけを使い、原文の文字列を保ち、原文末尾の句読点には印を置きません。印には原文に存在しないマーカーフレームを使い、保存する範囲や本文には混ぜません。
- `next_text`: 次区間の原文の先頭 60 Character 以内。次区間があるときだけ置きます。

全候補の質問 `b0001` 等と継続質問 `continuation` を同じリクエストに入れ、一区間を候補用と継続用の二送信に分けません。候補がなくても次区間があれば継続質問だけを送ります。前区間、次区間の全文は送りません。

次区間は、後続区間の ASR が保存されてから決まります。

| 後続区間 | 扱い |
| --- | --- |
| 非空の ASR 結果 | `next_text` に先頭 60 Character を置く |
| 空の ASR 結果 | テキスト列の終端。`next_text` と継続質問を省く |
| ASR 失敗（ASR gap） | 送信せず境界判定を保留（`asr_gap`）。gap をまたいで本文を推測しない |
| なし（録音停止・最後の区間） | テキスト列の終端 |

ASR gap の後に空の ASR 結果が保存された場合も、そこでテキスト列を区切ります。gap より前の未解決本文は保留のまま残し、空結果の後の本文は独立した列として判定します。空結果の後に別の ASR gap があれば、その直後の本文の先頭は再び未解決です。ライブ、確定・再試行、保存済みイベントの再読込で同じ規則を使います。

選択した coordinator が利用可能な場合に限り、終端の区間に候補も後続もなければ provider 判定呼出しをせず単一区間の `terminal_without_questions` を記録します。モデルのロード・初期化の可用性確認は必要で、利用不可・初期化失敗・停止中は通常どおり保留し、架空の境界結果を作りません。判定呼出しがないので `request` は `null` で利用計数なし。

### 優先度判定（Choice）

閉じた節のうち、フィラー除去後の本文が空白・改行だけでない節だけを送ります。state は `{"u0001": "節本文", ...}` で、質問 `p0001` 等は対応する `u` key を直接指定します。他の key の本文は判定対象外と指示し、文脈や原文を添えません。一送信は最大 40 節で、原文順に並べます。ライブでは一つの境界応答で新しく閉じた節をまとめ、確定と再試行では全境界の後に、最大40節ずつ直列に送ります。40 節が貯まるまで待つことも、batch を一節ずつの送信へ分解することもしません（対象が一節なら一節の batch です）。境界と優先度を一つの送信にまとめることはしません。

ライブ・確定・再試行は [ClausePriorityBatches.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClausePriorityBatches.swift) の同じ直列 batch 処理を使います。ライブは送信する batch ごとに現在の設定から分類器を取得し、設定停止・キー未設定・初期化失敗の batch は未送信の保留にします。その保留だけで後続 batch の取得を止めません。送信を停止する失敗後は、同じ実行の後続の境界・優先度判定でも分類器取得・HTTP 送信を行わず、未送信の節を最大 40 節ずつ `request: null` の保留イベントとして保存します。失敗した batch も部分成功にせず全対象を保留にします。取り消しは保留を作らず、遅れて戻った応答を保存・表示しません。引き継ぎは Choice batch の対象外です。

### Jev API 応答の検証

全 requested answer key、質問と一致する type、Choice の二択・両選択肢の probabilities・confidence、非空 model、usage object を検証します。確率と confidence は有限の 0..1、token は未報告なら nil、報告された値は非負整数です。不足・余分な回答、型不一致、不正値はリクエスト全体を拒否し、部分結果や架空の確率を記録しません。HTTP の並列化、自動再送、同文の cache、失敗した batch の一節ずつの再送はしません。

Choice は両確率の和が 1 に近いこと（絶対誤差 ≤ 0.01）、選択した option が最大確率であること（同率最大はどちらも可）、confidence が二択の式 `2 * max(probabilities) - 1` と整合すること（絶対誤差 ≤ 0.015）も検証します。比較には浮動小数点演算の端数用に `1e-12` を加え、値を正規化・補正しません。Noul は単一の確率なので和・Choice confidence の検査はなく、有限の閉区間 0..1 を厳密に検証します。矛盾した応答は既存の `invalidResponse` 経路で送信を停止し、全対象を保留します。

この応答検証は [API reference](https://docs.typesafe.ai/api.md)、[Confidence](https://docs.typesafe.ai/confidence.md)、[Choice examples](https://docs.typesafe.ai/primitives/choice.md) の仕様例を基にした provider 側の受入規則です。API は丸め桁数や許容誤差を保証していません。

## 優先度の採用と表示

| 選択 provider の判定 | 発話文の表示用優先度 |
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

401 / 403 の状態表示は「Jev の API キーの修正が必要です。発話文の判定を保留しました」、その他の保留は「発話文の判定を後で再試行します」です。分類器の生成や Keychain の読取が例外で失敗した場合は、その理由を添えて「発話文の判定を後で再試行します。判定エンジンを初期化できませんでした: …」と表示し、録音とライブ ASR は継続します。

初期化失敗の理由は、後続区間の ASR が保存されて境界・優先度の保留状態が更新されても表示に残します。一般的な再試行メッセージだけで上書きしません。保留イベントにも理由を保存し、実際に送信しなかった処理を外部リクエストとして計数しません。

確定結果の保留は `processing_metadata.json` の `pending_clause_boundary_segments`（境界判定が未成立の区間）と `pending_content_priority_clauses`（優先度が未成立の発話文）に保存します。設定の「保留中の判定を再試行」で、現在選択中の provider により再実行できます。対象・公開済み run・引き継ぎ元を事前に検証し、不整合は明示エラーにします。

- **優先度だけの再試行**: 公開済みの境界判定 run をそのまま使い、指定した発話文だけを最大40件の batch で選択 provider に判定させます。新しい優先度 run で、その他の発話文の判定を元 run・イベント・参照付きで引き継ぎます。指定しなかった保留は保留のまま引き継ぎます。
- **境界を含む再試行**: 新しい境界判定 run を作り、公開済みの成功判定を元 run・イベント参照付きで引き継ぎ、保留区間だけを選択 provider で再判定します。全区間から発話文を組み直し、除去後本文が UTF-8 byte 列で完全一致する発話文の優先度を元参照の検証付きで引き継ぎ、新しく閉じた発話文と指定した保留だけを優先度判定します。ASR と音声は再実行しません。
- ASR gap で必要な次区間の原文がない保留は、同じ ASR では回復できません。送信前に「次の区間に音声認識結果がないため、境界を再判定できません。録音を再処理してください」とエラーにします。

新しい境界・優先度 run と保留一覧は一回の metadata 書き込みで公開します。未公開の再試行 run の結果は使わず、公開済みの snapshot から再構築します。判定 run の `processing.run.started` は開始時に選択した coordinator の来歴を記録し、質問0の終端や優先度の carry-over だけで provider 呼出しがない場合も、利用可能ならその identity を記録します。`request: null` は呼出しなしの場合に加え、失敗した呼出しのイベントにも使われるため、それだけで呼出しの有無は判断できません。

## ライブから確定への再利用

確定処理の開始時点でイベントログを読み、その時点で保存済みのライブ優先度 run の classified 判定だけを固定します。その後にライブの判定キューを取り消します。固定より後に保存された応答や未保存の応答は使いません。未完了のライブ run でも保存済みの判定は使えます。

確定の発話文本文（フィラー除去後の連結本文）がライブの発話文本文と **UTF-8 byte 列で完全一致**する場合だけ、再判定せず優先度を引き継ぎます。trim、空白・句読点・Unicode の正規化、類似一致はしません。フィラーの位置だけが違って除去後本文が同じなら引き継ぎます。同じ本文の判定が複数あればイベント順で最新の classified を使い、後の保留はそれを無効にしません。発話文の parts と ID は確定 ASR と確定の境界判定のもので、ライブの境界判定は確定区間へ移しません。境界判定が成立しなかった確定区間にライブ結果を持ち込みません。

## API キー・確認・利用状況

Jev 選択時の API key は「設定」→「発話文の判定」で保存・削除し、macOS Keychain に置きます。設定やセッション JSON、イベントログには保存しません。キーの有無を調べるだけでは Keychain の許可を求めず、キー本体を読むのは Jev 接続確認と Jev 判定のときだけです。ローカルモデル選択時は Keychain を読みません。Keychain の許可はアプリの署名に結び付くため、app bundle は固定の自己署名証明書で署名します（[README](../README.md) の「ビルドと起動」）。判定を一時停止しても録音や必須のローカル認識は停止しません。

「Jev 接続を確認」は固定の一対象 Choice で「これは接続確認のためのテスト文です。」だけを送り、応答またはエラーを表示します。保存済み key がない、Jev が停止中、確認実行中なら開始しません。接続確認は判定利用状況に数えません。エラーには API key、対象 key、送信本文、応答本文を含めません。「モデルを確認」はローカル package の compile・検証だけで、classifier request や利用状況を発生させません。

「診断」には「発話文判定の利用状況（判定リクエスト単位）」を表示します。

- 合計: リクエスト回数、入力 token 数（Jev の応答報告分 + ローカルモデルが実際に入力した token 数）、成功件数、token 数不明の件数、失敗件数
- 境界判定・優先度判定それぞれのリクエスト回数と入力 token 数
- 境界判定の保留区間数と優先度判定の保留発話文数

リクエスト回数は `DecisionProvider` の各判定呼出しを1回として数え、候補数、推論数、対象発話文数では数えません。ローカル境界 provider は候補と継続の両方を推論しても1 request で、入力 token は両 sequence の実数を合計します。ローカル優先度 provider は最大40 sequence を処理して1 request とし、sequence ごとの実入力 token を合計します。ローカル判定は HTTP を使いません。Jev input token は API の報告値、ローカルは実際に入力した token 数です。Jev が token 数を報告しない成功は「token 数不明」に数え、既知の0として補いません。接続確認、モデル確認、carry-over、質問0の terminal、provider 呼出し前に保留された処理は判定 request 回数に含めません。取り消し済み provider 呼出しは request 回数だけ残ります。

保留件数はセッションと対象（区間または発話文）の組で重複なく管理し、request 計数とは独立です。公開 snapshot が解決した保留、または置き換えた run の保留を除き、累計 request と token は保持します。provider の初期化に失敗し request 呼出しがなかった場合は計数しません。metadata から利用状況を合成しません。

## 実装の根拠

- [Jev request・応答・エラー](../app/MacAmbientJev/Sources/MacAmbientJevCore/JevClient.swift)、[共有型・Noul閾値・batch上限](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTypes.swift)、[優先度閾値・バッチ停止](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionCoordinator.swift)、[保存 payload](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseRecords.swift)、[節の組み立て](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseBoundaryAssembly.swift)、[確定・再試行の snapshot](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionEnrichmentCoordinator.swift)、[ライブの判定キュー](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveContentPrioritySession.swift)、[保存結果の検証と再利用](../app/MacAmbientJev/Sources/MacAmbientJevCore/EventLogTranscriptReader.swift)
- [アプリ／CLI のアクセス境界と保存済みキー](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[アプリの構成](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift)、[処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)、[システム音声 CLI](../app/MacAmbientJev/Sources/MacAmbientJevCaptureSystemAudio/main.swift)、[遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)
- [設定と接続確認](../app/MacAmbientJev/Sources/MacAmbientJev/SettingsView.swift)、[Keychain](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/KeychainStore.swift)、[利用計数](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionUsageCounter.swift)、[診断表示](../app/MacAmbientJev/Sources/MacAmbientJev/DiagnosticsView.swift)
- [画面と書き出しの行集合・節 slice](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)
- [候補・ローカル入力符号化](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerEncoding.swift)、[Tokenizer 検証と Unigram wrapper](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerTokenizer.swift)、[Core ML model validation](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerModel.swift)、[local provider](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)
- [Engine preference](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/DecisionEnginePreference.swift)、[provider factory/cache](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/SelectedDecisionProviderFactory.swift)、[settings](../app/MacAmbientJev/Sources/MacAmbientJev/SettingsView.swift)、[AppPaths](../app/MacAmbientJev/Sources/MacAmbientJevCore/AppPaths.swift)
