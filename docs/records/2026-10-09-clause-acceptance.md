# 2026-10-09 — 節契約のconsumer受入と実Jevテキスト観測

## 実行範囲

開始HEADは `2151b0a`。マイク録音、システム音声録音、音声再生、システム音量・出力装置の変更は行わない。実保存consumerの注入応答、実モデルの既存ファイルCLI、実ネットワークのJevテキスト入力を区別する。利用者報告の13行／14送信／33,187 token／3.3秒は再測定しない。

## 注入consumerと実ファイル

一時Runtime harnessの実行:

```bash
JEV_CLAUSE_CONSUMER_SMOKE=1 swift test --package-path app/MacAmbientJev --filter temporaryClauseConsumerDiskSmoke
```

実際の起動はCore回帰・実API probe・Native takeoverのfilterと合わせた一回。consumer testは0.638秒で成功した。`NativeSessionProcessor`、`SessionWriter`、metadata、reader/materializer、`SavedSessionCatalog`、`SessionExporter`の実装と隔離した保存ファイルを使い、ASR/VAD/話者分離/Jevを注入した。実capture・音声認識精度・API精度の証拠ではない。

- raw `えー、週末の設計を確認します。そうですね。` はイベントに残り、表示は `週末の設計を確認します。そうですね。`。PRIMARYとLOWのfragmentを区別し、実txtはLOWも保持して共通rendererと一致。
- `そうですね。なるほど。` は全LOWとして行を畳む。
- priorityの注入401/429は2節とも通常色・保留。1節だけのretryはboundary pointerを維持し、priority pointerを置換、非対象pendingを維持。ASRは1回のまま。
- boundaryの注入429は無分割・通常行。boundary retryは新しいboundary/priorityと保留解消をatomicに公開。応答前にmetadataと表示を読み直すと直前の公開snapshotのまま。
- liveの2区間 `えー、週末の設計を` / `確認します。` をfinalの1区間 `週末の設計を確認します。` に変更。除去後本文が完全一致し、保存済みpriorityをcarry、Choiceはliveの1回だけ。
- `events.jsonl` appendと `processing_metadata.json` 公開を別々に実ファイルで失敗させた。処理はfailed、ローカルのdurable本文を保持。optionalのpointer/sliceは不採用、通常表示を維持。

永久テストは再利用除外後40/41節、回答の後半だけが不正なbatch、全no／無句読点／連続句読点と終端、trim／句読点のbyte差、未公開retryの回答不採用、LOW＋待機、takeover時の保存済みLOWと通信中の通常本文を補強した。新しい固定sleepによるnegative assertionは残さない。一時harnessは検証後に削除する。

## 実モデルのファイルCLI

既存のローカル20秒WAV（16 kHz mono）を再生せず、隔離rootに処理した。

```bash
app/MacAmbientJev/.build/out/Products/Debug/MacAmbientJevProcessRecording \
  --sessions-root /private/tmp/mac-ambient-jev-task4-n6h_9u5i/sessions \
  --keep-session --low-heat "$EXISTING_SMOKE_WAV" \
  /private/tmp/mac-ambient-jev-task4-n6h_9u5i/segments.json
```

正常終了、3区間。schema2のみ、公開active runはsegmentation/diarization/ASR/scene/scopeの5段、境界保留3、priority保留0。Jevのassessment・closed clause・priority assignment・request記録はいずれも0。JSONのraw textとsourceのrun/segment/event_seqを実ASRイベントへ照合し、全行 `boundary_pending`・空sliceを確認した。raw/displayに差のある行は0だったため、この実ASR結果をフィラー除去の証拠にはしない。

同じ隔離sessionのinspectは `retryContentPriority`、maintenanceはnull。resumeはJevを実行せず公開済みJSONを書き出し、初回JSONと一致した。eventsのSHA-256とmetadataは不変。個人本文は記録しない。モデルは既存cacheを使用した。CLIは21.71秒で完了したが、これは起動・モデル準備・ファイル処理込みで、節API性能ではない。

## 実Jev API

一時Core probeが実 `JevClient`、`URLSessionJevHTTPTransport`、`DecisionCoordinator`、候補列挙、assembly、フィラーprojectorと優先度採用policyを使用した。キーは指定serviceを `security find-generic-password -s app.mac-ambient-jev.jev -w` でメモリへ読み、キー・Authorizationを出力／ファイル保存しない。音声・source IDは送信しない。応答の品質をtestの固定正解にしない。

### 継続の観測

新規入力 `これはコピーと。` → `いうか、原本を複製する操作です。`。返却modelは `jev-1.13.0`。

| 対象 | raw UTF-16候補 | 確率 | HTTP時間 | reported input token |
| --- | --- | ---: | ---: | ---: |
| 第一区間（末尾句点は候補なし）→次区間 | continuation | 0.70 | 564.542 ms | 481 |
| 第二区間、`いうか、` の直後 | b0001、offset 4 | 0.15 | 171.860 ms | 553 |

第一区間では閉節0、次区間の終端で跨ぎ節1を得た。閾値は厳密な `> 0.5` のまま。この2区間を含む最初の3シナリオは境界4 HTTP＋priority3 HTTP、reported input token合計4,700、HTTP時間合計1,668.712 ms、実API probeのtestは成功した。長いstdoutの取得で後半の詳細が切れたため、それ以外の個別確率やChoice confidenceはこの観測から主張しない。

### 複数句点と弱境界の追加観測

取得可能な短い集計と測定JSONを残す別の新規入力を使用した。同じ入力のモデル精度再確認や上記試作の再測定ではない。modelは全応答 `jev-1.13.0`。

| raw入力 | candidate | offset UTF-16 | 確率 | 採用 |
| --- | --- | ---: | ---: | --- |
| `えー、資料を配ります。図を示します。質問を受けます。` | b0001（フィラー後） | 3 | 0.40 | no |
| 同上 | b0002（第一句点後） | 11 | 0.78 | yes |
| 同上 | b0003（第二句点後） | 18 | 0.78 | yes |
| `準備ができたので、手順を確認して、実験を始めます。` | b0001 | 9 | 0.23 | no |
| 同上 | b0002 | 17 | 0.35 | no |

末尾句点はいずれも候補にしない。複数句点例は3節となり、Choice本文は `資料を配ります。` / `図を示します。` / `質問を受けます。`。いずれもPRIMARY、confidenceは順に0.96／0.94／1.00。弱境界例は1節、本文は無挿入連結のまま、PRIMARY/confidence 0.96。LOWの実API品質はこの入力では検証していない。

| HTTP | purpose | reported input token | HTTP時間 |
| --- | --- | ---: | ---: |
| 複数句点の境界 | boundary | 1,104 | 248.167 ms |
| 3節batch | priority | 806 | 268.226 ms |
| 弱境界 | boundary | 832 | 235.728 ms |
| 1節batch | priority | 458 | 179.130 ms |

追加観測は境界2＋priority2の4 HTTP、3,200 reported input token、HTTP時間合計931.252 ms。token未報告成功0。2回のprobe全体では11 HTTP（境界6＋priority5）、reported input token 7,900、HTTP時間合計2,599.964 ms。これは利用量の報告値で、請求金額の証明ではない。

HTTP応答後に除去後本文と可視priorityの配列を導出するconsumer処理は追加観測で0.028625 ms／0.012209 ms。durable保存・実GUI描画は含まない。全テキストを事前に用意したため、実next区間到着待ち・ASR待ち・画面反映時間は未計測。実live/final経路のreuseはこのAPI probeでは実行していない（上の注入consumerでのみ確認）。

今回の入力で期待した接続・句点分割・弱境界非採用を観測しただけで、別入力の精度保証、CSJ全認定一致、14秒超のライブ遅延上限ではない。候補以外の位置では切れず、モデルがnoなら句点でも切れない。句点の規則分割、特別な接合、閾値変更、再送で帳尻を合わせない。

## 完成状態の検証とGUIの限界

一時Core API probe・Runtime consumer harness・隔離CLI sessionとJSON・API測定JSONを除去した後、repo rootで次の一連のコマンドはすべて成功した。

```bash
python3 -B scripts/check_portable_core.py
python3 scripts/check_doc_references.py
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev
bash scripts/verify_v1.sh
```

`verify_v1.sh` のCLI検査は不正入力12種とnamed session／contained resume拒否を通過し、release bundleの作成・署名・MLX shader・entitlement確認を終えて `V1 verification passed`。sandbox回避オプションは使用しない。既存のMLX mutated-node、未使用checkpoint、話者分離managerのisolation警告は出たが、build/test失敗はない。Linux評価本体は変更せず、Linuxモデル品質の根拠にはしない。

READMEの手順で生成されたbundleを `open .build/MacAmbientJev.app` で起動した。起動前の同bundleプロセスはなく、起動後の実行pathはこのworktreeのbundle、System Eventsの `visible` はtrueだった。これはプロセス／ウィンドウ公開の観測であり、実画面の描画・操作成功を意味しない。

AccessibilityのUI操作許可とscreen-observationの事前確認は両方false。許可を要求したり設定を変更したりせず、設定のJev有効化・キー読取・録音元／出力先操作、実画面のLOW折畳み・展開、選択copy/paste、VoiceOver、時刻popover・話者見出し、保存済み録音の再選択とGUI exportは未観察。授業中のため、実captureと権限、14秒超の発話とnext待ち、録音停止→ASR drain→final表示、実live/finalのreuse、実障害時の録音継続、設定retryトリガー／診断操作も未確認。注入smoke・API probe・buildをこれらの代替合格とはしない。
