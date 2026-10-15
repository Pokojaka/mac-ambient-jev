# 発話文の境界・優先度判定

境界判定と優先度判定の単位は BTSJ 発話文（以下「発話文」）です。保存形式・コード上の `clause` / `節` はこの発話文単位を識別し、別の節分割器を意味しません。境界、継続、フィラー範囲、優先度は app bundle に同梱したローカル Core ML モデル（clause tagger）だけが判定し、ネットワークを使いません。録音、VAD、ASR、話者分離、フィラー除去、発話文判定はすべてこの Mac 上で動作します。確定処理のローカル必須段階は segmentation・diarization・ASR の3段階で、判定段階は任意です。モデルの初期化や判定が失敗した場合は判定結果を保留し、別の方式で補いません。

## 処理の流れ

1. コードが ASR 原文の `、。？！?!` の直後（原文末尾を除く）を UTF-16 offset で候補として列挙します。候補 offset は句読点の後ろで、句読点そのものの位置や原文末尾ではありません。原文末尾に連続する `、。？！?!` の内部には候補を置きません（「本当？！」は候補なし）。
2. モデルが各候補位置の発話文境界、区間末尾と次区間先頭の継続、および対象区間のトークンごとの O / F / D を同じ境界要求で判定します。F だけをフィラーとして除き、D は除きません。節が完結していても「けど」「が」「し」などの接続で内容が続く場合や、倒置・後置・付け足しが続く場合は同じ発話文です。フィラーや言い直し・修復があることだけでは発話文境界にしません。
3. コードが採用境界（確率 `> 0.5`）と継続（確率 `> 0.5`）から発話文を組み立てます。発話文は複数の ASR 区間にまたがることができ、各区間の原文範囲（parts）で表します。
4. 成功した境界判定の F 範囲を assessment イベントへ保存した後、その範囲から発話文ごとのフィラー除去後本文を空白を挿入せずに連結します。materialization は保存済み範囲を適用するだけで、モデルを読み込み・実行しません。
5. モデルが、閉じた発話文のフィラー除去後本文を PRIMARY / LOW_PRIORITY に分類します。

形態素解析、辞書、規則による別分割・判定は行いません。候補にない位置では切れず、句点があってもモデルが境界と判定しなければ切れません。この精度の限界を別方式で補いません。

## 判定の入力

本文を持つ各 ASR 区間について、候補の有無や終端かどうかにかかわらず境界判定を一回呼び出します。入力は対象区間の **ASR 原文**（フィラーを含む）と、次区間があればその原文の先頭 60 Character 以内です。全候補の判定・F 範囲の推定と継続判定を同じ呼出しで行い、候補用と継続用の二呼出しに分けません。候補がなくても次区間があれば継続を判定し、終端で候補がない場合も F 範囲を得るため境界 request を実行します。前区間、次区間の全文は入力しません。成功した境界判定は、候補が空でも `request` を持つ assessment になります。

次区間は、後続区間の ASR が保存されてから決まります。ASR 原文が空白・改行・句読点（Unicode の句読点文字）だけの区間は空の ASR 結果として扱い、本文を持つ区間とはしません。

| 後続区間 | 扱い |
| --- | --- |
| 本文のある ASR 結果 | 先頭 60 Character を次区間として入力する |
| 空の ASR 結果（空白・句読点だけを含む） | テキスト列の終端。次区間と継続判定を省く |
| ASR 失敗（ASR gap） | 判定せず境界判定を保留（`asr_gap`）。gap をまたいで本文を推測しない |
| なし（録音停止・最後の区間） | テキスト列の終端 |

ASR gap の後に空の ASR 結果が保存された場合も、そこでテキスト列を区切ります。gap より前の未解決本文は保留のまま残し、空結果の後の本文は独立した列として判定します。空結果の後に別の ASR gap があれば、その直後の本文の先頭は再び未解決です。ライブ、確定・再試行、保存済みイベントの再読込で同じ規則を使います。

区間の境界判定に失敗した場合は `clause_boundaries.pending` を記録し、フィラー範囲を推測しません。

優先度判定は、閉じた発話文のうちフィラー除去後の本文が空白・改行だけでない発話文だけを対象にします。各対象は request 内の key `u0001` 等で識別し、一呼出しは最大 40 発話文で原文順に並べます。ライブでは一つの境界結果で新しく閉じた発話文をまとめ、確定と再試行では全境界の後に、最大40発話文ずつ直列に判定します。40 発話文が貯まるまで待つことも、batch を一発話文ずつに分解することもしません（対象が一発話文なら一発話文の batch です）。境界と優先度を一つの呼出しにまとめることはしません。

ライブ・確定・再試行は [ClausePriorityBatches.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClausePriorityBatches.swift) の同じ直列 batch 処理を使います。ライブは判定する batch ごとに provider factory から coordinator を取得し、モデルの初期化に失敗した batch は未判定の保留にします。判定呼出しが失敗した batch は部分成功にせず全対象を `request: null` の保留にし、後続の境界・優先度判定は通常どおり続けます。取り消しは保留を作らず、遅れて戻った結果を保存・表示しません。引き継ぎは優先度 batch の対象外です。

処理 CLI、システム音声キャプチャ CLI、ライブ遅延計測 CLI は `ContentPriorityAccess.disabled` で境界・優先度判定を無効にします。これらの CLI は Core ML tagger をロードせず、assessment と F 範囲を作らず、ASR 原文をそのまま表示します。segmentation・diarization・ASR の必須3段階は通常どおり実行します。

## モデルの同梱と更新

モデルは ClauseTagger.mlpackage と tokenizer.json の組で、容量が GitHub のファイル上限を超えるため、このリポジトリ（Pokojaka/mac-ambient-jev）の GitHub release asset に置きます。[build_app.sh](../scripts/build_app.sh) は release tag、asset 名、asset の SHA-256 を定数として固定しています。

- archive は最上位に `clause-tagger` ディレクトリを一つだけ持ち、その直下に ClauseTagger.mlpackage と tokenizer.json を置きます。
- ビルドはリポジトリの .build/clause-tagger に archive を保存し、ない場合だけ GitHub CLI で固定 tag の asset を取得します。`gh` がない場合や取得に失敗した場合はエラーで止まります。
- 取得した asset は .build/clause-tagger 内の一時ディレクトリで SHA-256 を検証してから保存先へ rename します。中断や不一致の取得は保存先に残りません。
- ビルドのたびに保存済み archive の SHA-256 を検証し、不一致ならエラーで止まります。検証していない archive は使いません。
- 新しい一時ディレクトリに展開し、`clause-tagger` ディレクトリを app bundle の Contents/Resources に入れてから署名します。

アプリは app bundle の Resources 直下の `clause-tagger` ディレクトリだけを読みます（`LocalClauseTagger.bundledModelDirectory()`）。モデルのダウンロード、別の保存先、パスの設定はありません。bundle にモデルがない場合は初期化エラーです。テストは `LocalClauseTagger(modelDirectory:)` に自分のディレクトリを渡します。

モデルを更新する手順:

1. 新しいモデルを書き出し、`clause-tagger` ディレクトリに ClauseTagger.mlpackage と tokenizer.json を置いて tar.gz にまとめる。asset 名と tag は model revision の先頭8桁を使う（例: tag `clause-tagger-54443a6a`）。
2. その tag で GitHub release を作り、archive を asset として登録する。
3. build_app.sh の tag、asset 名、SHA-256（`shasum -a 256` の値）の3定数を書き換える。
4. 実モデル parity テストの fixture を新しいモデルで作り直す（[検証と計測](testing.md)）。

## モデルの検証と推論

モデルをロードすると macOS 15 で Core ML に compile し、compute units は CPU only、tensor dtype は float32 です。入力 `input_ids` は int32、形状 `[1,L]`（`2...192`）です。モデル出力は `boundary_probs` `[1,L,2]`、`span_probs` `[1,L,3]`、`priority_probs` `[1,2]` の float32 に厳密に一致しなければなりません。`span_probs` は値と形状を検証し、境界要求の F 範囲投影に使います。

`.mlpackage` の creator-defined metadata は次の6 key を全て必要とし、値・型を検証します。`model_id` は sbintuitions/modernbert-ja-30m-multitagger、`model_revision` は sorted state-key bytes と tensor bytes から計算した SHA-256 hash の64桁小文字 hex、`training_status` は `trained`、`tokenizer_sha256` は tokenizer.json の生 bytes の SHA-256、`unit_policy` は `btsj-utterance-sentence`、`encoding_revision` は `1` です。モデル ID は外部モデル識別子であり、ローカルのファイルパスではありません。`training_status` が `trained` 以外の package は判定に使用できません。metadata 欠損・不正、tokenizer hash 不一致、型・shape・語彙検証失敗は初期化エラーとなり、境界・優先度の表示は通常の保留状態のままとし、架空確率を記録しません。

ロードの結果（成功も失敗も）は [DecisionProviderFactory](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/DecisionProviderFactory.swift) がアプリの実行中 cache し、再 compile しません。失敗は同じエラーを返し続け、アプリを再起動するまで再ロードしません。同時に要求されたロードは一つにまとまります。compile で作る一時 `.mlmodelc` ディレクトリはロード直後に削除します。

### 符号化と推論

候補 offset は ASR 原文の句読点直後の UTF-16 offset です。Unicode scalar を正規化せず保持し、原文から末尾連続の `、。？！?!` だけを符号化対象から取り除きます。空白は trim しません。符号化時は各 `、。？！?!` を中立記号 `、` として扱い、句読点間を piecewise Unigram lattice で tokenize し、句読点は語彙 ID `275` を強制します。special-token 追加を tokenizer に任せず、先頭に `[CLS]` ID `6`、末尾に `[SEP]` ID `4` を付けます。入力は `[CLS]` + 内容 token（最大190）+ `[SEP]` で最大192 token です。優先度用の符号化は内容 token が190を超えると先頭190 token で切り、その後ろに `[SEP]` を付けます。切った後ろの内容は判定に使いません。

Tokenizer は swift-transformers Tokenizers `1.3.4` の Unigram を使い、Metaspace の `prepend_scheme=never`・`split=false` と UTF-8 byte fallback を wrapper で実装します。tokenizer.json はモデル metadata の SHA-256 と一致した時だけ読み、一度だけ typed vocabulary として解析します。ASCII space は tokenize の間だけ Metaspace の U+2581 に置換します。原文対応の source token range と span 投影 index は source-only の `boundaryInputs` でのみ生成し、優先度入力の符号化と継続用入力では生成しません。連続する OOV Unicode scalar は一つの unknown run として扱い、run 内の各 UTF-8 byte fallback token は個々の scalar ではなく run 全体を覆う同じ raw UTF-16 範囲を持ちます。既知 scalar または added token が現れると run はそこで分かれます（例: `😀😀` が連続した OOV run なら、8 byte token はすべて `[0,4)`）。tokenize の再構成が Metaspace 変換後の piece bytes と一致しない入力、byte fallback で表現できない入力はエラーにし、別 tokenizer や方式を試しません。

境界入力の長さが190 token 以下なら対象区間全体を一つの窓にします。それを超える場合は句読点で分かれた連続 piece を途中で切らず、各190 token 以下の窓にします。各候補と原文対応を持つ全 source token は、それぞれ左右の文脈の短い方が最大になる窓を選び、同率なら開始位置が最も早い窓を使います。選ばれた窓の和集合を推論し、候補の境界判定と全 source token の F 範囲推定を網羅します。source token は一つの窓だけを F 投影に使います。候補がない窓も source token の F 推定に使います。

継続用入力は対象区間の末尾句読点を除いた原文 + 強制 comma + 次区間先頭を連結し、連結後の末尾 `、。？！?!` も除いた別入力です。継続確率は junction token における `1 - boundary_probs[junction][1]` です。junction と次区間先頭の少なくとも一つの token を含む窓のうち、junction の左右の文脈の短い方が最大の窓を使います。この継続用窓を F 範囲推定には使いません。special token に原文範囲はなく、継続用入力の junction token と次区間 token にも原文範囲はありません。符号化対象から外れる終端句読点もモデル上は O です。一つの piece が190 token を超える、または必要な継続窓を作れない場合は encoding error として当該 request 全体を保留します。

### F 範囲の投影

各投影対象 token の `span_probs` は O=0、F=1、D=2 の argmax でラベル化し、同率では先にあるラベルを選びます。token 範囲が重なる場合は後の token のラベルが scalar ごとに先のラベルを上書きし、どの token 範囲にも覆われない scalar は O とします。Swift Character は構成する全 scalar の最終ラベルが F の場合だけ F とし、一つでも O または D があれば Character 全体を保持します。隣接する F Character は、Character 全体を含む UTF-16 範囲にまとめます。たとえば `ｶﾞ` や `👍🏻` の構成 scalar にラベルの混在があれば、Character の一部だけを削除せず全体を残します。削除するのは F だけで、O / D は保持します。投影の対象は source-only 境界窓で一度だけ選ばれた原文対応 token です。特殊 token と継続用入力の junction・次区間 token は原文範囲や span 投影 index を持たず、投影しません。token label・token probability・投影済み本文は保存しません。

assessment の検証と text projector が受け付ける F 範囲は正の長さを持ち、原文順にソートされ、重ならず隣接もしない必要があり、両端は Swift Character の境界でなければなりません。不正な caller 入力はエラーとし、範囲の正規化・coalesce・補正はしません。F 範囲は raw ASR text 上で適用します。各範囲の直後に続く句読点を削除範囲へ拡張しますが、開き括弧などの開き句読点と引用符は拡張対象外です。拡張後の削除範囲が重なるか接する場合は統合するため、受理時には分かれていた入力 F 範囲が一つの削除範囲にまとまることがあります。これは拡張後の削除範囲の統合であり、入力範囲の正規化ではありません。空白は trim、挿入、正規化せずそのまま保持します。符号化から除かれた終端句読点はモデル上 O ですが、直前の F 範囲に接する句読点はこの拡張規則で除去されます。

優先度判定は一つの batch で最大40発話文をそれぞれ sequence として推論します。優先度入力は発話文全体を一つの入力にするため窓分割せず、内容が190 token を超える場合は先頭190 token に切り詰めます（エラーにしません）。空白・改行だけの対象は推論せず batch 全体を `invalidTargets` で拒否します。句読点だけの対象（例「？」）は `[CLS]` `[SEP]` の2 token に符号化され、他の対象と同じくモデルが判定します。`priority_probs[0][0]` は PRIMARY、`priority_probs[0][1]` は LOW_PRIORITY の確率です。PRIMARY と LOW_PRIORITY の確率が同率なら PRIMARY を選択し、confidence は `2 * max(probabilities) - 1` です。

### 判定結果の検証

tagger は Core ML の出力ごとに、各確率が有限の閉区間 0..1 にあり、softmax の和が 1 から `1e-5` 以内であることを検証し、外れた出力は推論エラーにします。coordinator は全対象への回答があり余分な回答がないことを検証します。優先度判定の結果は、両確率が有限の 0..1 で和が 1 から `1e-5` 以内、選択した優先度が最大確率（同率最大はどちらも可）、confidence が `2 * max(probabilities) - 1` と完全に一致する場合だけ作れます。保存済みイベントの読取も同じ検証を通し、値を正規化・補正しません。検証に失敗したリクエストは全体を拒否し、部分結果や架空の確率を記録しません。並列化、自動再試行、同文の cache、失敗した batch の一発話文ずつの再判定はしません。

## 優先度の採用と表示

| モデルの判定 | 発話文の表示用優先度 |
| --- | --- |
| LOW_PRIORITY、confidence ≥ 0.90 | `lowPriority` |
| LOW_PRIORITY、confidence < 0.90 | `primary`（実際の判定は記録する） |
| PRIMARY | `primary` |
| 未分類・保留 | 本文を表示 |

表示方針は [MaterializedTranscriptSegment](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift) の `displayText` 一箇所です。保存済み assessment の F 範囲で原文からフィラーを除き、その後、行内の発話文 slice ごとに `lowPriority` が保存され再試行待ちでない本文をさらに除きます。PRIMARY と LOW の混在行は PRIMARY の本文だけを表示し、表示本文が空白・改行だけになった行は表示しません。続き待ち・境界判定保留・優先度保留の部分は、保存された F 範囲がある部分を除いて本文を残します。区間をまたぐ発話文は、所属する全ての行の slice に同じ判定を適用します。話者の違いで発話文の結合を拒否しません。

画面、コピー、accessibility、`transcript.txt` と CLI の `display_text` は同じ表示本文を使います。ASR イベントの原文は変更しません。

## 保留と再試行

| 失敗 | 扱い |
| --- | --- |
| 判定呼出しの失敗（符号化エラー、Core ML の推論エラー・不正な出力、回答の不足・余分、優先度の確率・confidence の不正） | そのリクエストの全対象を保留し（`request_failed`）、次のリクエストを続ける |
| モデルの初期化失敗 | 判定せず保留（`initialization_failed`） |

境界判定の assessment が保存されていない区間は分割せず、ASR 原文を未分類の通常行として表示します。判定前・保留・失敗・判定無効 CLI では F 範囲を適用しません。その区間へ続く未解決の発話文に属する行、ASR gap や保留の直後の区間の先頭も、閉じた発話文として扱いません。すでに独立して閉じた発話文の保存結果は保持します。優先度判定だけが保留の発話文は通常表示で、全 LOW として扱いません。境界の保留を「継続しない」と偽装しません。

保留の状態表示は「発話文の判定を保留しました」です。モデルの初期化が失敗した場合は、その理由を添えて「発話文の判定を保留しました。判定エンジンを初期化できませんでした: …」と表示し、録音とライブ ASR は継続します。初期化失敗の理由は、後続区間の ASR が保存されて境界・優先度の保留状態が更新されても表示に残します。理由のない保留メッセージだけで上書きしません。保留イベントにも理由を保存し、実際に呼び出さなかった処理を判定リクエストとして計数しません。

確定結果の保留は `processing_metadata.json` の `pending_clause_boundary_segments`（境界判定が未成立の区間）と `pending_content_priority_clauses`（優先度が未成立の発話文）に保存します。判定は同じ入力に同じ結果を返すため、起動時の復旧は保留を再試行しません。保留を再判定するのは利用者が設定の「保留中の判定を再試行」を押したときだけです。対象・公開済み run・引き継ぎ元を事前に検証し、不整合は明示エラーにします。

- **優先度だけの再試行**: 公開済みの境界判定 run をそのまま使い、指定した発話文だけを最大40件の batch で判定します。新しい優先度 run で、その他の発話文の判定を元 run・イベント・参照付きで引き継ぎます。指定しなかった保留は保留のまま引き継ぎます。
- **境界を含む再試行**: 新しい境界判定 run を作り、公開済みの成功判定を元 run・イベント参照付きで引き継ぎ、保留区間だけを再判定します。全区間から発話文を組み直し、新 run の assessment と公開済み run それぞれの保存 F 範囲で各本文を投影してから、UTF-8 byte 列が完全一致する発話文の優先度を元参照の検証付きで引き継ぎます。parts の同一性は本文一致の代用にせず、各 run の投影後本文だけを照合します。新しく閉じた発話文と指定した保留だけを優先度判定します。ASR と音声は再実行しません。
- ASR gap で必要な次区間の原文がない保留は、同じ ASR では回復できません。判定前に「次の区間に音声認識結果がないため、境界を再判定できません。録音を再処理してください」とエラーにします。

新しい境界・優先度 run と保留一覧は一回の metadata 書き込みで公開します。未公開の確定・再試行 run の結果は使わず、公開済みの snapshot から再構築します。公開前に中断した判定 run がログに残るセッションは、起動時の復旧が公開済みの保留を対象に判定 run をやり直して公開します。判定 run の `processing.run.started` は開始時に読み込んだモデルの来歴を記録します。優先度の carry-over のように判定呼出しがない run も、開始時の model identity を記録します。境界 assessment は `source_decision.kind` が `assessed` の場合に成功した判定呼出しの request を必ず持ち、`carried_over` の場合は呼出しを行わず request を持ちません。`request: null` は境界 assessment の `carried_over` と、判定呼出し失敗の優先度イベントや呼出し前保留などに現れます。

## ライブから確定への再利用

確定処理の開始時点でイベントログを読み、その時点で保存済みのライブ優先度 run の classified 判定だけを固定します。その後にライブの判定キューを取り消します。固定より後に保存された結果や未保存の結果は使いません。未完了のライブ run でも保存済みの判定は使えます。再利用するのは、開始 provenance の `model_revision` が確定処理で判定に使う tagger と同じライブ run だけです。revision が違うライブ run の判定は引き継がず、確定処理で判定し直します。

確定 run とライブ run それぞれの保存 F 範囲から作った発話文本文が **UTF-8 byte 列で完全一致**する場合だけ、再判定せず優先度を引き継ぎます。各 run 自身の境界 assessment を使って投影し、parts の同一性を本文一致の代用にしません。trim、空白・句読点・Unicode の正規化、類似一致はしません。F 範囲の位置だけが違って投影本文が同じなら引き継ぎます。同じ本文の判定が複数あればイベント順で最新の classified を使い、後の保留はそれを無効にしません。発話文の parts と ID は確定 ASR と確定の境界判定のもので、ライブの境界判定は確定区間へ移しません。境界判定が成立しなかった確定区間にライブ結果を持ち込みません。

## 設定と利用状況

「設定」→「発話文の判定」には、判定がこの Mac 上で行われることの説明、「モデルを確認」「保留中の判定を再試行」があります。どちらも録音中、処理中、モデル確認中、再試行中は押せません。「モデルを確認」は provider factory が cache した同じ tagger の model ID と revision を表示するだけで（別に compile しません）、判定リクエスト、利用回数、token を発生させません。検証失敗は通常の初期化失敗として表示します。

「診断」には「発話文判定の利用状況（判定リクエスト単位）」を表示します。

- 合計: リクエスト回数、入力 token 数、成功件数、失敗件数
- 境界判定・優先度判定それぞれのリクエスト回数、入力 token 数、成功件数、失敗件数
- 境界判定の保留区間数と優先度判定の保留発話文数

リクエスト回数は `DecisionProvider` の各判定呼出しを1回として数え、候補数、推論数、対象発話文数では数えません。境界判定は候補と継続の両方を推論しても1 request で、候補のない終端区間も F 範囲推定のため1 request です。入力 token は境界内の全 sequence の実数を合計します。優先度判定は最大40 sequence を処理して1 request とし、sequence ごとの実入力 token を合計します。入力 token 数は成功した判定の合計です。モデル確認、carry-over、判定呼出し前に保留された処理は request 回数に含めません。取り消し済みの判定呼出しは request 回数だけ残ります。

保留件数はセッションと対象（区間または発話文）の組で重複なく管理し、request 計数とは独立です。公開 snapshot が解決した保留、または置き換えた run の保留を除き、累計 request と token は保持します。モデルの初期化に失敗し判定呼出しがなかった場合は計数しません。metadata から利用状況を合成しません。

## 実装の根拠

- [共有型・境界閾値・batch 上限](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTypes.swift)、[回答の検証・優先度閾値](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionCoordinator.swift)、[保存 payload](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseRecords.swift)、[発話文の組み立て](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseBoundaryAssembly.swift)、[確定・再試行の snapshot と来歴](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionEnrichmentCoordinator.swift)、[ライブの判定キュー](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveContentPrioritySession.swift)、[保存結果の検証と再利用](../app/MacAmbientJev/Sources/MacAmbientJevCore/EventLogTranscriptReader.swift)、[空の ASR 結果](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)
- [アプリ／CLI の判定アクセス](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[アプリの構成](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift)、[処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)、[システム音声 CLI](../app/MacAmbientJev/Sources/MacAmbientJevCaptureSystemAudio/main.swift)、[遅延計測 CLI](../app/MacAmbientJev/Sources/MacAmbientJevMeasureLiveLatency/main.swift)
- [設定](../app/MacAmbientJev/Sources/MacAmbientJev/SettingsView.swift)、[利用計数](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionUsageCounter.swift)、[診断表示](../app/MacAmbientJev/Sources/MacAmbientJev/DiagnosticsView.swift)
- [画面と書き出しの行集合・発話文 slice](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)
- [候補・入力符号化](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerEncoding.swift)、[Tokenizer 検証と Unigram wrapper](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerTokenizer.swift)、[Core ML model validation](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerModel.swift)、[tagger と同梱モデルの場所](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)、[provider factory/cache](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/DecisionProviderFactory.swift)、[モデルの取得と同梱](../scripts/build_app.sh)
