# 書き出しと保存済み録音

## 文字起こしの行集合

画面、コピー、アクセシビリティ、`transcript.txt`、キャプチャ CLI の `transcriptText`、CLI `segments.json` の `display_text` は、同じ `MaterializedTranscriptSegment.displayText` を使う。画面と `transcript.txt` は表示本文が空、または空白・改行だけの発話だけを除き、非空白の認識済み発話をすべて含める。

表示本文は保存済みフィラー・相槌範囲と LOW slice の除去後、表示専用で有効な漢数字 run を ASCII 算用数字に保守的に整形する。run の隣接文字に漢字（`々` を含む）、ASCII／全角数字、`.`／`．` があれば変換せず、`run点run` は小数として変換し（`二十八点四` → `28.4`）、`run分のrun` は分数として両方の漢数字を保持する。除去した範囲の両側の漢数字はつなげず、どちらも変換しない。固定語句は全文一致した句中の数字だけを保持し、部分一致では除外しない。ASR 原文・イベント、`textProjection`、raw UTF-16 範囲、モデル入力・発話文判定への入力は変更しない。詳細は[発話文判定](decision-engine.md#優先度の採用と表示)を参照。

フィラー・相槌除去には、active event log の保存済み `clause_boundaries.assessed.filler_ranges` だけを使う。保存フィールド `filler_ranges` は `{start,end}` object の配列で、フィラー（F）と相槌（B）を表示本文から除く raw UTF-16 範囲を表す。範囲は同じ ASR 原文に対する境界判定の source-only window の span head から作る。各 token の `span_probs` は `O=0, F=1, D=2, B=3` の argmax で label を決め、同点なら添字の小さい label を選ぶ。token span が重なる scalar は後の token の label で上書きし、どの token span にも含まれない scalar は O とする。原文の各 Character は構成するすべての scalar が F または B（F/B 混在も可）の場合だけ除去し、ひとつでも O または D の scalar があれば Character 全体を保持する。隣接して除去する Character は raw UTF-16 範囲に結合する。F・B除去範囲の直後に連続して接する句読点だけを併せて除き、空白は変更・正規化しない。対象 source の境界 assessment が未保存、pending、または失敗している場合は、フィラー・相槌除去範囲を適用しない。未判定・保留・失敗の priority slice も除去しないが、表示専用の漢数字から算用数字への整形は適用する。materialization 時にモデル推論は行わない。保存イベントに記録された LOW priority slice は、F・B除去範囲を適用した後に別途表示本文から除く。

「聞き取れませんでした」などの文字列だけで発話を除外しない。認識不能は ASR の構造化状態 `outcome: empty` で扱う。イベントには空本文を含む区間が残る。

`SavedTranscriptLoader` は保存済み active run のイベントと原文から本文・行内 slice を materialize し、保存された境界評価の `filler_ranges`（F・B除去範囲）を使う。別の辞書から範囲を取得したり、読取時に判定を再実行したりしない。読み込み・書き出しは ASR イベントと原文を変更しない。CLI の `segments.json` は原文が非空の行を保持し、`text` は原文、`display_text` は上記と同じ表示本文、`source` は ASR 参照、`clause_state` と `clause_slices` は節の状態と行内範囲を表す。フィラー・相槌除去後に空になる発話・全 LOW の発話（空の `display_text`）も JSON に含むため、画面・txt と JSON の行集合は異なる。跨ぎ節の全文を各行へ複製せず、全 parts はイベントの `clauses.closed` から追跡する。GUI は JSON を書き出さず、`transcript.txt` と音声だけを書き出す。[保存形式](storage.md)を参照。

処理 CLI とキャプチャ CLI は発話区間検出・音声認識・話者分離の3段階すべての公開済み run を必須とし、保存済み metadata の保留一覧とイベント参照を検証してから materialize する。必須 run の欠損、不正なログ・不完全な末尾・保留一覧の不一致は明示エラーで、読取時に発話文判定を再実行しない。キャプチャ CLI の `transcriptText` は `displayText` を行ごとに改行で連結し、原文を trim して代用しない。処理 CLI の `ContentPriorityAccess.disabled` は判定を実行せず、フィラー・相槌や LOW の除去は行わないが、表示専用の漢数字から算用数字への整形は適用する。判定再試行待ちセッションの resume も判定せず、公開済みの原文・表示本文を含む JSON を書き出す。

イベントログと `processing_metadata.json` は `schema_version: 3` を必須とする。欠損・未対応の version は読取エラーとして拒否し、明示的な再処理でも metadata を置換しない。

## transcript.txt

`TranscriptTextRenderer`（Pipeline、Foundation のみ）が開始時刻と話者見出しを付け、UTF-8 で 1 行 1 発話を書き出す。各行末は改行。

```text
[00:07] Speaker 1: 本文
[12:34] Speaker 1 / Speaker 2: 本文
[65:00] UNKNOWN: 本文
```

時刻は開始ミリ秒を秒へ切り捨てた総分数と秒数。1 時間を超えても分数を使う。話者番号は `Speaker 1`〜`Speaker 7`、それ以外は `OTHER`、割り当てがない場合は `UNKNOWN`。

話者と重なる時間の合計に対して 1 人が 80% 以上ならその話者だけを見出しにする。80% 未満なら出現順に ` / ` で併記する。本文内の CRLF、LF、CR、U+2028、U+2029 は空白へ置換する。話者分離前の発話には見出しがなく、テキスト書き出しは「話者分離されていない発話（区間 ID）があるため書き出せません」で失敗する。[確定処理](final.md)を参照。

## 音声とフォルダー名

録音は保存済みの `recording.flac`（16 kHz・mono・16-bit FLAC）を全フレーム復号し、CRC-8・CRC-16 と MD5 を検証してから `audio.flac` に無変換でコピーする。コピー後の FLAC の長さは `committedFrames` と正確に一致する。保存状態が FLAC でない録音は「録音の FLAC 化が終わっていないため書き出せません。確定処理をやり直してください」で失敗し、その場で符号化はしない。起動時の保存整理中（`isMaintainingStorage`）に、まだ `recordingPCM` の録音を書き出そうとした場合は、アプリが書き出しの前に止め、「保存済み録音の音声を整理しています。整理が終わってから書き出してください」と表示する。読み込み音声は保存済み original を再圧縮せず複製し、ファイル名は `audio` と元の拡張子を結合する。音声の選択はセッションの種類で決まり、派生 timeline の有無では切り替えない。書き出しはセッション内の音声を読むだけで、`recording.flac`、original、`storage.json` のいずれも削除・変更しない。保存状態は書き出しの開始時に `storage.json` から決める。

書き出しフォルダー名は保存済みセッションの実フォルダー名をそのまま使う。作成時に固定したタイムゾーンで決めた名前を再計算しないため、現在のタイムゾーンや書き出し時刻で変化しない。

作成時の形式は次のとおり。

```text
YYYY-MM-DD_HH-mm-ss_<stem>_<8 lowercase hex>
```

録音例: `2023-11-14_22-13-20_録音_0123abcd`。読み込み例: `2023-11-14_22-13-20_定例会議_0123abcd`。時刻はセッション作成時に指定したタイムゾーンで一度だけ決まり、読み込みでは読み込み時刻、録音では録音開始時刻を使う。stem の sanitization、切り詰め、検証は[保存形式](storage.md)を参照。

設定の「保存先」で書き出し先を選ぶ。書き出しは Application Support 内のセッションを移動しない。同じセッションの再書き出しは同名のフォルダーを置き換える。書き出しの内容は UTF-8 の `transcript.txt` と、録音なら検証済みで無変換の `audio.flac`、読み込み音声なら元の拡張子・バイト列のままの `audio.<拡張子>` で、macOS と Windows で同じ。`SessionExporter`（Pipeline）は書き出し先を実体に解決した上で、すべてのファイル操作を `SessionFileAccess` 経由で書き出し先に固定して行う。

公開の手順は次のとおり。まず非表示の作業用フォルダー `.export-<セッション ID>.partial` にテキストと音声を揃える。同名の書き出しが既にあれば `.export-<セッション ID>.previous` へ移し、作業用フォルダーを同名へ移して公開し、成功したら置き換え前のフォルダーを削除する。ディレクトリの移動は `SessionFileAccess.renameDirectory` が行い、移動先が既に存在すれば失敗する（Windows でも POSIX 意味論の rename を使う）。公開に失敗したら置き換え前のフォルダーを元の名前へ戻し、戻せなければそのパスを示したエラーで失敗する。置き換え前のフォルダーを削除する手段がなく置き換えを実現できない場合も、既存の書き出しを削除したり、その場へコピーしたりせず失敗する。

失敗時は作業用フォルダーを削除し、削除にも失敗した場合は元の書き出しエラーと削除エラーを併記する。公開後に置き換え前のフォルダーを削除できなかった場合は、書き出し済みであることと残ったパスを示して失敗とする。置き換え中にアプリが終了して `.previous` だけが残った場合、次の書き出しの開始時に同名の書き出しが無ければ元の名前へ戻し、あれば削除する。

## 自動書き出しと保存先

「処理完了後に自動で書き出す」の初期値はオン。保存先が設定され、公開済み文字起こしがあり、処理状態が完了または発話文の判定の再試行待ちなら自動書き出しする。未処理・処理中・一時停止・失敗・破損の状態では自動書き出ししない。

保存先は security-scoped bookmark とパスを `UserDefaults` に保存する。参照できない保存先は選び直しを求め、別フォルダーへ切り替えない。自動書き出し設定の型が不正なら「自動書き出しの設定を読めないため、自動では書き出しません。設定の「保存先」で切り替え直してください」と通知して書き出しを止める。

書き出し中は進捗を表示し、同じセッションの重複書き出しを防ぐ。書き出し済みの判定は対象フォルダーに `transcript.txt` とそのセッションの音声ファイルが両方存在すること。書き出し済みのセッションには「書き出し先を Finder で表示」が出て、書き出したフォルダーを開ける。保存済み録音の詳細には、書き出しの有無にかかわらず読める録音と読めない録音の両方で「録音データを Finder で表示」が出て、アプリ内に保存しているそのセッションのフォルダー（カタログが持つ実際の URL）を選択して Finder で開く。設定の「保存先」にある「録音データ」の「Finderで表示」は、全セッションを入れた sessions フォルダーを開く。フォルダーが存在しなければ作らずにエラーを表示する。

## アプリのウィンドウ

Dock と Finder のアプリアイコンは、暗い角丸タイルに白い紙のしおりと橙色の波形・文字の行を組み合わせたデザイン。元画像は `app/MacAmbientJev/Assets/AppIcon.png`。16・32・128・256・512 pt の標準解像度と Retina 用の画像を収めた AppIcon.icns を app bundle の Contents 内の Resources フォルダーに置き、`scripts/app_info_plist.sh` が生成する Info.plist の CFBundleIconFile で指定する。

メインウィンドウ「MacAmbientJev」は単一インスタンスとし、同時に複数は開かない。File メニューの New Window とそのショートカット Command-N は提供しない。

メインウィンドウは起動時に開く。SwiftUI の主シーンに `Window` を使うため、メインウィンドウを閉じるとアプリは終了し、Dock アイコンをクリックすると再起動してメインウィンドウを開く。`defaultLaunchBehavior(.presented)` により、復元するウィンドウがない起動時と、実行中のアプリに可視ウィンドウがない状態での Dock クリック時にもメインウィンドウを表示する。

ボタン・切替・入力欄などの操作要素には、マウスオーバーで説明（`help(_:)`）を出す。文面は Apple HIG（日本語版「ヘルプの提供」）に従い、要素が行う操作を体言止めで 60 字以内にまとめ、要素名を繰り返さず、文末の句点を付けない。無効な状態では操作できない理由を出す。一行に切り詰めたパス・状態・読み込みエラーは、全文をマウスオーバーで出す。

## 保存済み録音の一覧

保存済み録音はメイン画面のボタンで開く独立したウィンドウ「保存済み録音」に表示する。通常のウィンドウなので閉じるボタンと Command-W で閉じられ、開いたままでもアプリを終了できる。

一覧は作成日時の新しい順。セッション情報を読めない項目は読める項目の後ろに置き、理由を表示する。入力元は「マイク」「システム音声」「読み込み音声」で区別する。右側の詳細は縦にスクロールし、長い読み込みエラーでも左の一覧の高さを変えない。

| 状態 | 表示 |
| --- | --- |
| 未確定・公開済み結果なし | 未処理 |
| 確定処理の実行中 | 処理中 |
| 熱による一時停止 | 一時停止中（発熱） |
| 完了・公開済み文字起こしあり | 文字起こしあり |
| 完了・公開済み文字起こしなし | 処理完了 |
| 完了・判定の保留あり | 文字起こしあり・発話文の判定を再試行 |
| 確定処理失敗 | 再処理が必要: 理由 |
| processing_metadata.json の読み取り失敗 | 文字起こしデータが破損しています（音声から再処理できます） |

音声がない場合は「保存済み音声がありません」、音声を読めない場合は「音声を読めません: 理由」を処理状態より優先して表示する。セッション情報の欠損・破損、フォルダー名と manifest の不整合、完全セッション ID の重複は項目全体を読み込みエラーとする。行の identity と選択は実フォルダー URL を使い、UUID を読めないフォルダーも個別に選べる。

再処理には読めるセッション情報と利用できる原音声が必要。派生 metadata の一般的な破損だけなら原音声から再処理できるが、schema version の欠損・未対応は再処理でも拒否する。破損状態の書き出しは許可しない。書き出しにはさらに公開済み文字起こしが必要。録音中は保存済み録音の選択を無効にし、録音・読み込み中や同じセッションの処理待ち・処理中は再処理を重ねて開始しない。

一覧は active ASR run のイベントログと active transcript payload を読み取り専用で検証する。ログが欠損・不正、または不完全な末尾を含む場合は破損状態となり、文字起こしを公開せず書き出しを無効にする。再処理は利用可能な原音声から行える。

## 実装

- [SessionExporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionExporter.swift): 音声書き出し、作業用フォルダー、公開と置き換え。
- [TranscriptTextRenderer.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/TranscriptTextRenderer.swift): 行の描画。
- [SavedTranscriptLoader.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SavedTranscriptLoader.swift): 保存済み run からの文字起こしの読み込み。
- [SavedSessionCatalog.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SavedSessionCatalog.swift): 音声・派生結果の状態と再処理可否。
- [AppState+SavedSessions.swift](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+SavedSessions.swift): 保存先、書き出し、一覧操作。
- [ExportDestination.swift](../app/MacAmbientJev/Sources/MacAmbientJev/ExportDestination.swift): 保存先参照と設定検証。
