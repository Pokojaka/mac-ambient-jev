# セッション保存形式

保存音声は再処理の基礎であり、文字起こし・話者・BTSJ 発話文の境界・優先度は派生結果です。発話文の境界と優先度は app bundle 同梱の Core ML 発話文モデルが判定します。保存 key と event 名の `clause` / `節` はその発話文単位の識別名です。派生結果は追記専用のイベントログに残し、処理 metadata が選ぶ run だけを現在の結果として公開します。処理の流れは [architecture.md](architecture.md) を参照してください。

以下の表は **JSON 上の実際のキーと値**です。イベントと処理 metadata は snake_case のキーを使いますが、checkpoint と音声用 JSONL は camelCase です。String enum の値はキー変換の対象ではなく、`clauseBoundary`、`contentPriority`、`lowPriority` などは camelCase のままです。

## 保存場所とセッションフォルダー

Windows の共通コアは LocalAppData/mac-ambient-jev 配下を使い、macOS の sandbox パスは構築しません。OS ごとの取得方法と Windows の実行範囲は [windows.md](windows.md) を参照してください。

GUI アプリは sandbox 内で動作し、標準のセッション保存先は `~/Library/Containers/app.mac-ambient-jev/Data/Library/Application Support/mac-ambient-jev/sessions` です。全てのセッション CLI は各モードで `--sessions-root DIRECTORY` を必須とし、CLI が既定保存先を選ぶことはありません。非 sandbox の `~/Library/Application Support/mac-ambient-jev/sessions` とその cache、および sandbox 側の app data/cache は CLI の保護対象です。明示 root はこれらの領域と祖先・子孫関係にならず、symlink 経由でも重ならない必要があります。各 Application Support の mac-ambient-jev 以下に sessions と音声処理モデルの models、各ユーザーの Caches 以下の mac-ambient-jev にキャッシュを置きます。発話文判定モデルはここに置かず、app bundle の Resources 内 `clause-tagger` ディレクトリから読みます（[発話文判定](decision-engine.md#モデルの同梱と更新)）。`AppPaths` は sessions root のみ上書きでき、models root は上書きできません。設定の「録音データ」と保存済み録音の詳細から sessions フォルダーを Finder で開けます。App の設定は UserDefaults / AppStorage にあり、セッション JSON のフィールドではありません。

フォルダー名は `YYYY-MM-DD_HH-mm-ss_<stem>_<UUID先頭8桁の小文字hex>` です。作成時に一度取得した日時を、明示した time zone のローカル時刻として Gregorian calendar・`en_US_POSIX` で表します。年は ASCII 4 桁（0001–9999）。アプリと CLI は `.current` を渡します。マイク・システム音声の録音は stem が `録音`、読み込みは元ファイル名の最後の拡張子を除いた stem です。

stem の Windows 禁止文字（`<>:"/\|?*` と U+0000–001F）、先頭の `.`、末尾に連続する `.` と空白は `-` に置換します。CON・PRN・AUX・NUL・COM1–9・LPT1–9（数字の上付き ¹²³ を含み、最初の拡張子より前を大文字小文字を区別せず判定）は先頭に `-` を付けます。固定部分は UTF-8 29 byte、stem は Swift Character の境界で 226 byte 以下に切り詰め、切り詰め後にも名前を検証し、全体を 255 byte 以下にします。この規則は全 OS で共通です。読み取り時には禁止文字・末尾のドットや空白・予約名を含む stem を修復せず拒否します。合成文字は分割せず、manifest の元ファイル名は正規化・変更しません。元ファイル名の NUL、空の stem、最初の Character が上限に入らない名前、形式で表せない日時は明示エラーです。同名の既存フォルダーは上書きしません。名前の辞書順は作成時に記録したローカル時刻順であり、DST や time zone の変更をまたぐ UTC 順ではありません。

セッション identity は `session.json` の **完全な UUID** です。`SessionLayout` は実際の `sessionURL` だけを受け取り、ID から URL を生成しません。`SessionDirectoryLocator` は root 直下の全ディレクトリの manifest を読み、完全な UUID の一致を数えます。0 件は `notFound`、複数件は名前順のフォルダー一覧付き `multipleMatches`、1 件は名前の検証後に URL を返します。無関係な壊れた manifest は identity を提供しません。一致した manifest のフォルダー名が不正なら、その検証エラーを返します。

lookup・一覧・復旧は列挙で得た実フォルダー名を使い、指定された root URL の表記を保ちます。作成時に返した URL と、同じ root から取得した行・lookup の URL は同じ identity として扱えます。

読み取りでは固定 19 byte の日時と最後の `_` に続く小文字 ASCII hex 8 桁を解析し、日時の Gregorian 妥当性、manifest UUID の接頭辞、同じ規則で算出した source stem を検証します。日時の妥当性は読み取り時のローカル time zone に依存しません。フォルダーの日時と `created_at` は比較せず、読み取り時に作成日時や ID から名前・URL を再計算したり、フォルダーを改名したりしません。

一覧と復旧は非表示を含む全直下ディレクトリを対象とし、通常ファイルは対象外です。manifest の欠損・破損、名前の不正、UUID 接頭辞・source stem の不一致はフォルダーごとのエラーとして表示し、健全な他のセッションは処理を続けます。同じ完全 UUID の複数フォルダーは全て読み込みエラー・復旧失敗とし、二重に処理しません。保存済み一覧の行 identity と選択は URL。壊れた manifest に UUID を捏造せず、読み取れた UUID だけを保持します。正常行の再処理・書き出し操作は UUID を使います。

根拠: [SessionFolderName.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionFolderName.swift)、[SessionDirectoryLocator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionDirectoryLocator.swift)、[SavedSessionCatalog.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SavedSessionCatalog.swift)。

### セッション内のファイルアクセス境界

Windows では root を CreateFileW で検査し、固定した親 handle から NtCreateFile で子を開きます。reparse point は全て拒否します。原子保存は同一ディレクトリの排他的な一時ファイルを FlushFileBuffers で同期し、NtSetInformationFile で開いたファイル自身を置換して親を同期します。ログは LockFileEx で排他制御します。API の失敗はエラーにし、保証の弱い経路へ切り替えません。詳細は [windows.md](windows.md) を参照してください。以下の POSIX descriptor の説明は macOS と Linux に適用します。

`sessionsRoot` 自体と直下のセッションフォルダー、セッション以下の全ディレクトリ・ファイルに symlink は使えません。`session.json`、`events.jsonl`、`processing_metadata.json`、audio ディレクトリの `storage.json`、checkpoint・chunk index・gap log・PCM chunk、保存済み original・FLAC、処理中の CAF・FLAC partial も同じ規則です。末尾ファイルだけでなく `audio`・`processing`・`derived` などの親ディレクトリの symlink も、読み書き・列挙・復旧・削除で明示エラーにします。catalog と復旧はリンクされたセッションをエラー行として扱い、リンク先をセッションとして処理しません。

`SessionFileAccess` は呼出し元が明示した実 root を `O_DIRECTORY | O_NOFOLLOW` で開き、子ディレクトリを固定した descriptor から `openat` でたどります。通常ファイルは `O_NOFOLLOW` で開いた descriptor を使い、書込み用一時ファイルは同じ実ディレクトリに排他的に作成して `renameat` で公開します。公開前にファイルと公開後にディレクトリを同期します。音声 encoder・decoder は `SessionFileAccess` が session root に固定して開いた handle を使うため、URL を事前検証してから AVAudioFile 等で開き直す経路はありません。開いた後でパスが置き換わっても、その操作は開いた元のファイルを使い、symlink の外部対象を変更しません。

音声 API は所有する `sessionURL` を明示的に受け取り、処理ディレクトリだけを root にして親の検査を省きません。境界より上の、呼出し元が選んだ保存場所の ancestry（macOS の `/var` などの OS alias を含む）はこの規則の対象外です。CLI の保護領域の重なり検査は別途 symlink 解決後にも行い、選択した root 自体をリンク先へ置き換えません。外部から選んだ import 元と、書き出し先のフォルダー・`segments.json` 等の外部 artifact はセッション内アクセス境界の対象外ですが、書き出すセッション側の original・FLAC は descriptor から読みます。

根拠: [SessionFileAccess.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionFileAccess.swift)、[DescriptorAudioFile.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/DescriptorAudioFile.swift)。

セッションの構成は次のとおりです。これは生成されるファイル配置であり、リポジトリ内のファイルではありません。

```text
2023-11-15_07-13-20_録音_0123abcd/
├── session.json
├── events.jsonl
├── processing_metadata.json          処理開始後
└── audio/
    ├── storage.json                  保存音声の権威。セッション作成時に書く
    ├── recording.flac                録音の FLAC 保存形式（storage.json が recordingFLAC のとき）
    ├── original.<元の拡張子>          import のみ。拡張子なしなら original
    ├── processing/
    │   ├── checkpoint.json
    │   ├── audio-chunks.jsonl
    │   ├── audio-gaps.jsonl
    │   └── chunk-000000.f32le ...     0 始まりの連番
    └── derived/
        └── diarization-input.caf     発話区間のある確定処理の話者分離入力
```

### storage.json

`storage.json` は `.sortedKeys` で書く JSON で、セッション作成時に初期状態を書きます。次の 4 つがエンコーダーの出力そのままです（[SessionAudioStorageFormatTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/SessionAudioStorageFormatTests.swift) が同じ bytes を検証します）。`timeline` の中身は `TimelineAudioInfo` で、`committedFrames` が録音の長さ（フレーム数）、`gapEvents` が欠落記録です。`sampleRate` は 16000、`channelCount` は 1 に固定です。

```json
{"state":"recordingPCM"}
```

```json
{"state":"recordingFLAC","timeline":{"channelCount":1,"committedFrames":9600000,"gapEvents":[{"frameCount":8000,"reason":"overflow","startFrame":160000}],"sampleRate":16000}}
```

```json
{"state":"importedOriginal","timeline":null}
```

```json
{"state":"importedOriginal","timeline":{"channelCount":1,"committedFrames":9600000,"gapEvents":[{"frameCount":8000,"reason":"overflow","startFrame":160000}],"sampleRate":16000}}
```

状態ごとの audio ディレクトリの中身は次のとおりです。確定処理の終了後は、derived ディレクトリと import の processing ディレクトリは残りません。

| 状態 | 作られる時 | audio ディレクトリの中身 |
| --- | --- | --- |
| `recordingPCM` | 録音セッションの作成時から FLAC 化まで | `storage.json`、processing ディレクトリ（PCM chunk）。確定処理の間だけ derived ディレクトリ |
| `recordingFLAC` | FLAC 化の完了時 | `storage.json`、`recording.flac` |
| `importedOriginal` | import セッションの作成時から | `storage.json`、`original*`。確定処理の間だけ processing ディレクトリ（処理タイムライン）と derived ディレクトリ |

- `storage.json` が保存音声の形を決める唯一の権威で、3 状態のどれかです。`recordingPCM` は processing ディレクトリの PCM chunk が録音です。`recordingFLAC` は `timeline`（長さと欠落記録）を持ち、`recording.flac` が録音です。`importedOriginal` は `timeline`（直近の処理タイムライン構築の長さと欠落記録。構築前は null）を持ち、original が元です。ファイルの欠落・破損・セッションの作成方法との不一致はセッションごとのエラーで、推測で補いません。状態が `recordingFLAC` なら PCM が残っていても読まず、FLAC が欠落または復号できなければエラーです。
- 録音は `recordingPCM` の間、処理タイムライン自体が保存音声です。入力の全 channel を平均し、連続 SRC を通した **16,000 Hz・mono・32-bit float PCM** を保存します。
- import では元ファイルを無再圧縮コピーした `original` または original に元の拡張子を付けたファイルが保存音声です。audio 直下の該当する通常ファイルは **ちょうど 1 つ**必要です。0 個または複数個ならエラーです。元の外部ファイルを再処理の入力にはしません。
- import の処理タイムラインは **16,000 Hz・mono・32-bit float PCM** の派生物です。保存済み original を bounded buffer で読み、全 channel の平均後に連続 SRC を行います。`processSession` は確定処理のたびに処理タイムラインを削除して original から作り直します。original の bytes は変更しません。予期しない EOF・不正 PCM・変換失敗は明示エラーです。
- `derived` の CAF は処理用の派生音声で、確定処理がセッション情報を読めない開始失敗を除く全ての結果（完了・失敗・一時停止・その他の開始失敗）で削除します。import の処理タイムラインと `recording.flac.partial` も同じ扱いです。録音の PCM は一時ファイルではなく、FLAC 状態を保存するまで権威です。録音の書き出し音声は `recording.flac` のコピー、import の書き出し音声は original のコピーであり、内部 PCM chunk と外部書き出しは別物です。

### 録音の FLAC 化

確定処理が文字起こしを公開した後、`RecordingAudioCompactor` は `recordingPCM` の録音を `recording.flac`（16 kHz・mono・16-bit FLAC）へ変換し、PCM を削除します。符号化器 `RecordingFLAC` と復号器 `FLACTimelineReader` は `MacAmbientJevCore` にある Foundation を使う portable な pure Swift 実装で、macOS・Linux・Windows で共通です。出力は native FLAC で、metadata block は STREAMINFO だけです。

各 FLAC frame は公称 4,096 frame で、最後の frame だけは短くできます。STREAMINFO の total samples は `storage.json` の `committedFrames` と正確に一致します。STREAMINFO の block size 最小値・最大値は [RFC 9639](https://www.rfc-editor.org/rfc/rfc9639.html) に従って短い最終 frame を除く公称 block size（4,096）を記録し、frame size 最小値・最大値は実際に符号化した frame の byte 数から記録します。MD5 は signed 16-bit little-endian PCM 全体から計算します。

符号化器は各 block で CONSTANT、VERBATIM、FIXED の次数 0〜4 を比較し、符号化 bit 数が最小の形式を選びます。FIXED の残差は Rice method 0、partition order 0〜8 を評価します。サンプルは有限値のみを受け付け、`[-1, 1]` に clamp して 32,768 倍し、最も近い整数へ丸めます（ちょうど中間の値はゼロから離れる方向）。その後 Int16 範囲へ clamp します。非有限値は明示エラーです。

`FLACTimelineReader` は開くときに STREAMINFO の形式（16 kHz・mono・16-bit）と total samples が `committedFrames` に一致することを検証します。全音声検証では frame を順に読み、header CRC-8、frame CRC-16、frame 数、MD5 を検証し、切り詰め・末尾の余分な bytes・長さ不一致をエラーにします。PCM との比較検証では全ての量子化済み sample が一致することも確認します。decoder は fixed-blocking の CONSTANT・VERBATIM・FIXED・LPC subframe、Rice・Rice2 residual、wasted bits を読み取ります。可変 block、対応しない format や符号化、CRC 不一致、切り詰め、余分な末尾 bytes、長さ不一致は明示エラーです。

frame index は byte offset と先頭 sample（および小さな frame 情報）だけを保持し、最初の random read 時の構造 scan、または全音声検証時に一度だけ構築します。random read は要求範囲と交差する frame だけを復号します。音声全体の PCM は保持せず、メモリ使用量は小さな frame index を除いて録音時間に比例しません。ファイル I/O は `SessionFileAccess` が session root に固定した handle を使います。

1. processing ディレクトリの checkpoint と PCM を検証します。`committedFrames` が 0 の録音は compactor の `committedFrames > 0` guard により変換対象にならず、`recordingPCM` のままで FLAC を作りません（`audioSource` は nil です）。`RecordingFLAC.write` を 0 frame で直接呼んだ場合も、出力ファイルを開く前に明確な empty-recording error を返します。
2. 古い `recording.flac.partial` を削除し、`RecordingFLAC` で `recording.flac.partial` へ書き込み、synchronize します。
3. partial の STREAMINFO と全 frame を検証し、total samples が `committedFrames` と正確に一致することを確認します。全 frame を順次復号して CRC と MD5 を検証し、PCM source の全 sample の量子化値とも比較します。読み書きと検証は FLAC block 単位の streaming 処理で、音声全体の PCM を保持しない bounded-memory です。短い読み取り、PCM 不一致、復号失敗はエラーです。
4. `recording.flac` へ rename して公開し、`storage.json` を `recordingFLAC(timeline)` に保存します。この保存が権威を切り替える唯一の操作です。
5. processing ディレクトリを削除して audio ディレクトリを synchronize します。

変換は確定処理が文字起こしを公開した直後（文字起こし無しの完了を含む）に確定処理自身が行い、起動時にも再実行します。変換の失敗は「文字起こしは保存しましたが、録音を FLAC にできませんでした: …」として報告し、公開済みの文字起こしと PCM は残ります。一時ファイルの削除に失敗した場合は、一時停止した実行なら一時停止のまま削除エラーだけを状態文として報告し、完了した実行なら「文字起こしは保存しましたが、音声の一時ファイルを削除できませんでした: …」、失敗した実行なら元のエラーに「。音声の一時ファイルを削除できませんでした: …」を続けて報告します。変換の対象は、公開済みの run 集合（`activeRuns`）があり音声が空でない `recordingPCM` の録音です。finalization の状態は問いません。

### 起動時の保存整理

アプリは起動時に、録音中のセッションを除く全セッションの保存整理を、キューへ何も入れる前に 1 件ずつ最後まで実行します。状態は「保存済み録音の音声を整理しています（n件）」です。`recordingPCM` で変換が必要なものと、`recordingFLAC` で PCM が残るものは変換（収束）、それ以外で一時ファイルが残るものは削除です。音声ソースは使う時点で `storage.json` から決めるため、整理後の再走査はありません。整理中は処理キューを開始せず、その間の要求は整理後に順に処理します。整理中に要求されたセッションは、その起動の復旧対象から外します。整理に失敗したセッションはその起動では復旧対象にせず、フォルダー名を付けて「保存済み録音の音声を整理できなかったセッションが n 件あります: …」と報告します。復旧できないセッションの報告と合わせるときは、復旧できない報告を先にして「。」でつなぎます。

整理が終わった時点で、処理状態とライブ文字起こしのヘッダーから整理中の表示を解除します。整理中の表示がまだ残っている欄だけを整理前の状態へ戻し、その間に録音や文字起こし処理が更新した状態は上書きしません。復旧対象がある場合は復旧の表示へ進み、整理に失敗した場合は処理状態に明示エラーを残します。復旧対象がなく整理だけが完了した場合も、整理中の表示は残りません。

どの時点で中断しても、再実行は `storage.json` を見て同じ終状態に収束します。`recordingPCM` のまま `recording.flac` が残っていれば、PCM と完全一致する場合だけ採用し、不一致や破損なら削除して PCM から作り直します。`recordingFLAC` では FLAC を全復号して検証し、失敗すれば PCM に触れずエラーにします。`importedOriginal` は変換対象外です。

根拠: [AppPaths.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AppPaths.swift)、[SessionLayout.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionLayout.swift)、[AudioImporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioImporter.swift)、[AudioCaptureEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevCapture/AudioCaptureEngine.swift)、[TimestampedMonoSink.swift](../app/MacAmbientJev/Sources/MacAmbientJevCapture/TimestampedMonoSink.swift)、[RecordingFLAC.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/RecordingFLAC.swift)、[FLACTimelineReader.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/FLACTimelineReader.swift)、[SessionFileAccess.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionFileAccess.swift)、[AudioFileTimelineBuilder.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)、[SessionExport.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/SessionExport.swift)。

## session.json

`SessionManifest` を atomic write します。全フィールドは次の 5 種です。source は JSON の nested object ではなく、この形に分解されます。

| キー | 型 | 条件・意味 |
| --- | --- | --- |
| `session_id` | UUID 文字列 | 必須。完全なセッション identity。先頭 8 桁を小文字にした値がフォルダー名の末尾と一致する |
| `created_at` | ISO 8601 文字列 | 必須。セッション作成時刻。import では読み込み時刻 |
| `source_kind` | String | 必須。`recording` または `imported` |
| `capture_source` | String | recording で必須。`microphone` または `systemAudio`。import の書き込みでは出力しない |
| `original_filename` | String | imported で必須、空文字は不正。元ファイルの拡張子を含む名前。recording の書き込みでは出力しない |

録音元と元ファイル名は `SessionSource.recording(CaptureSource)` / `.imported(originalFilename:)` で表現します。import を microphone として保存する形式ではありません。manifest に schema version フィールドはありません。

根拠: [SessionManifest.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionManifest.swift)、[SessionBootstrapper.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionBootstrapper.swift)、[SessionRecoveryScanner.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecoveryScanner.swift)。

## events.jsonl

### 共通 envelope

1 行は 1 発話ではなく 1 イベントです。`SessionWriter` が JSON に LF を付けて append し、書き込みごとに synchronize します。actor とファイルの排他ロックを使い、別 writer によるサイズ変更を検出したら末尾を読み直します。

| キー | 型 | 意味 |
| --- | --- | --- |
| `event_seq` | UInt64 | 必須。セッション内のイベント番号。新しい append は最後の番号 + 1、最初は 1 |
| `event_id` | UUID 文字列 | 必須。イベントごとに生成 |
| `event_type` | String | 必須。下記のイベント種別 |
| `schema_version` | Int | 必須。値は `3` だけ。reader は他の値・欠落の行を読まずにエラーにし、`SessionWriter` は既存ログにその行があれば追記しない |
| `session_id` | UUID 文字列 | 必須。所属セッション |
| `processing_run_id` | String | optional。処理段階の run ID |
| `segmentation_run_id` | String | optional。区間が所属する segmentation run ID |
| `segment_id` | String | optional。区間 ID。run 内の区間を識別する |
| `source_start_frame` | Int64 | optional。保存タイムライン上の開始フレーム |
| `source_end_frame` | Int64 | optional。保存タイムライン上の終了フレーム（含まない） |
| `created_at` | ISO 8601 文字列 | 必須。イベント生成時刻。音声時刻ではない |
| `payload` | 種別ごとの JSON object | 必須 |

optional の nil は writer の JSON から省略します。音声区間の共通座標は `[source_start_frame, source_end_frame)` です。sample rate は checkpoint を参照します。イベント順序は `created_at` ではなく `event_seq` で扱います。

根拠: [EventEnvelope.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/EventEnvelope.swift)、[SessionWriter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionWriter.swift)、[Materialization.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)。

### イベント種別と payload

表中の run は `processing_run_id`、seg run は `segmentation_run_id`、範囲は envelope の source frame です。

| `event_type` | envelope の付加情報 | `payload` の全フィールド |
| --- | --- | --- |
| `processing.run.started` | run | `stage`: String、`provenance`: 下記の object |
| `processing.run.completed` | run | `stage`: String、`succeeded`: Bool、`completed_count`: Int、`failed_count`: Int |
| `segment.created` | seg run、segment、開始・終了範囲 | 空 object `{}` |
| `asr.pending` | run、seg run、segment、開始・終了範囲 | 空 object `{}`。確定処理でのみ出力する |
| `asr.completed` | run、seg run、segment、開始・終了範囲 | `text`: String、`detected_language`: optional String、`engine`: String、`model`: optional String、`outcome`: `recognized` または `empty` |
| `asr.failed` | run、seg run、segment、開始・終了範囲 | `kind`: 下記の失敗種別、`message`: String |
| `speaker.span` | run、開始・終了範囲 | `speaker_id`: String、`start_frame`: Int64、`end_frame`: Int64、`confidence`: optional Double |
| `clause_boundaries.assessed` | run（境界判定 run） | 下記の境界判定 object |
| `clause_boundaries.pending` | run（境界判定 run） | `source`: 区間参照、`reason`: 保留理由、`message`: String |
| `clauses.closed` | run（境界判定 run） | 下記の節 object。複数行にまたがるため envelope の segment は使わない |
| `content_priority.assigned` | run（優先度 run） | `assignments`: 判定 object の配列、`request`: リクエスト記録または null |

`stage` の raw value は `segmentation`、`asr`、`diarization`、`clauseBoundary`、`contentPriority` です。metadata のキー `clause_boundary` / `content_priority` と、stage の値 `clauseBoundary` / `contentPriority` を混同しないでください。

`asr.completed.outcome` は本文の全 Unicode scalar が空白・改行・句読点（Foundation の whitespacesAndNewlines と punctuationCharacters の文字集合）なら `empty`、それ以外は `recognized` です。`engine` と `model` は認識した実エンジンの provenance から取ります。本番の engine は `qwen3-asr-swift`、外部モデル ID は aufklarer/Qwen3-ASR-1.7B-MLX-8bit です（リポジトリパスではありません）。認識不能を特定の日本語文面との一致で判定しません。

`asr.failed.kind` は `engine_unavailable`（準備できないエンジン）、`audio_unreadable`（区間音声読取失敗）、`transcription_failed`（認識呼び出し失敗）のいずれかです。TIMEOUT の専用種別はありません。

イベントには空本文を含む全区間が残ります。ライブの `segment.created` / `asr.completed` は暫定結果で、確定処理では新しい segmentation / ASR run を作ります。`speaker.span` の ID はエンジンの raw ID で、表示用の Speaker 番号をイベントへ書き戻しません。

`processing.run.completed` の count は段階ごとの処理対象件数です。segmentation / ASR は区間、diarization は span を数えます。clauseBoundary は判定が成立した区間と保留の区間、contentPriority は可視本文のある発話文の成立数と保留数を数えます。decision run は判定保留があっても `succeeded: true` を出し、`failed_count` に保留数を保存します。これはローカル必須処理の失敗を意味しません。保存破損や参照の不整合は保留に変換せず、エラーにします。

検証済み VAD が0区間の確定処理では segmentation / diarization / ASR の各 run に provenance を持つ開始と、成功・完了0件・失敗0件の完了を保存します。対象がないため `segment.created`、ASR 区間イベント、`speaker.span` は作りません。derived 内の話者分離入力 CAF を生成・参照せず、保存音声も変更しません。3 run の保存検証後、空の transcript と `complete` を公開し、`active_runs` はローカル必須3段階だけを新しい run へ切り替え、任意の decision pointer は nil、両保留配列は空にします。発話文判定の呼出しは0です。再処理でも新しい run を作り、完了した空結果を未完了扱いで自動復旧しません。

根拠: [ActiveRuns.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ActiveRuns.swift)、[ASREventPayloads.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)、[PipelineCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/PipelineCoordinator.swift)、[TranscriptTypes.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptTypes.swift)、[DiarizationCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DiarizationCoordinator.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[LiveASRSession.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/LiveASRSession.swift)。

### 発話文判定イベント

区間参照（`source`）は `segmentation_run_id`、`segment_id`、`asr_run_id`、`asr_event_seq` を持つ object で、`asr_event_seq` はその区間の `asr.completed` の `event_seq` です。原文の範囲は ASR 原文の UTF-16 code unit の半開区間 `{"start":0,"end":4}` で、両端は Character 境界です。原文は正規化・trim しません。

`clause_boundaries.assessed` の payload:

| キー | 型 | 意味 |
| --- | --- | --- |
| `source` | 区間参照 | 判定した区間 |
| `candidates` | object 配列 | `id`（`b0001` 等）と `offset_utf16`。原文の `、。？！?!` の直後で、原文末尾を除く。候補なしは空配列 |
| `probabilities` | 候補 ID → Double | 各候補のモデルによる境界確率 |
| `next_head` | object または null | 判定に用いた次区間の `source` と先頭 `text`（60 Character 以内）。終端は null |
| `continuation_probability` | Double または null | `next_head` があるときだけ値を持つ |
| `filler_ranges` | `{start,end}` object 配列 | 必須。原文 ASR text 上の F 判定範囲。該当なしも `[]` を保存し、token 確率・token label・投影済み本文は保存しない |
| `request` | object または null | `assessed` は成功した判定呼出しの記録を持つ（候補なしの終端区間も F 範囲判定のため呼び出す）。`carried_over` は判定呼出しを行わず null |
| `source_decision` | object | `{"kind":"assessed"}` または `{"kind":"carried_over","source_boundary_run_id":…,"source_event_seq":…}` |

`filler_ranges` の各範囲は原文 ASR text の UTF-16 code unit 半開区間で、`start < end`、原文内 bounds、両端 Character 境界を満たします。配列は原文順でソートされ、範囲間に重なりや隣接はありません（直前の `end` は次の `start` より小さい）。値の形は `[ {"start":0,"end":2} ]`、該当なしは `[]` です。境界 assessment は `source_decision.kind` が `assessed` の場合に成功呼出しの `request` を必須とし、`carried_over` の場合は呼出しを行わず `request: null` とします。未判定・初期化失敗・呼出し失敗は assessment でなく `clause_boundaries.pending` に記録し、架空の確率や F 範囲を入れません。`source_decision` は assessment 自身の判定を示す `assessed` または request を持たない `carried_over` だけです。引き継ぎは元イベントと同じ区間・候補・全確率・次区間先頭・F 範囲であることを検証し、元の判定呼出しを再 request として扱いません。`filler_ranges` は decoder の必須キーで、欠落・型違い・不正範囲は読取エラーです。

| `reason` | 意味 |
| --- | --- |
| `not_requested` | 公開済みの境界判定 run がなく、判定していない |
| `initialization_failed` | モデルを初期化できなかった |
| `request_failed` | 判定呼出しが失敗した |
| `asr_gap` | 次区間の ASR が失敗した |

`clauses.closed` の payload:

```json
{"reference":{"boundary_run_id":"boundary_example","clause_id":"c12_0"},
 "parts":[{"source":{"segmentation_run_id":"seg_example","segment_id":"seg_000001","asr_run_id":"asr_example","asr_event_seq":12},"range":{"start":0,"end":3}},
          {"source":{"segmentation_run_id":"seg_example","segment_id":"seg_000002","asr_run_id":"asr_example","asr_event_seq":15},"range":{"start":0,"end":4}}],
 "termination":{"kind":"internal_boundary","source":{"segmentation_run_id":"seg_example","segment_id":"seg_000002","asr_run_id":"asr_example","asr_event_seq":15},"candidate_id":"b0001"}}
```

persisted `節` / `clause` はモデルが判定する BTSJ 発話文単位の識別名で、別 splitter の節を意味しません。両境界・継続確率は厳密に `> 0.5` の場合だけ採用します。候補 offset は原文 `、。？！?!` 直後の UTF-16 offset（原文末尾を除く）です。発話文 ID は `c<最初の part の asr_event_seq>_<開始 offset>` で、本文 hash や行内連番ではありません。parts は時間順で、二つ目以降は区間先頭から始まります。`termination.kind` は `internal_boundary`（採用候補）、`not_continued`（継続 no）、`stream_end`（録音停止・最後の区間・空の次区間。文法的な境界ではない）です。発話文本文は保存せず、原文とその区間の `clause_boundaries.assessed.filler_ranges` から導きます。

`clause_boundaries.assessed` と `content_priority.assigned` の `request` record は `request_id` と `input_tokens` だけを持ちます。境界では候補が空でも成功した判定呼出しに record を付け、優先度では一回の判定呼出しの全結果を一イベントに保存して record を一度だけ付けます。request record の decoder に default はなく、必須キーの欠落・型不一致・不正値は読み取りエラーです。

| request key | 型 | 保存値 |
| --- | --- | --- |
| `request_id` | String | `decisionreq_<小文字UUID>` |
| `input_tokens` | Int | モデルが実際に読んだ全 sequence の token 数合計。0 以上 |

request を処理したモデルは、そのイベントの run の `processing.run.started` provenance（`model_id` / `model_revision`）が示します。

```json
{"assignments":[
  {"reference":{"boundary_run_id":"boundary_example","clause_id":"c12_0"},"priority":"lowPriority","needs_retry":false,
   "decision":{"kind":"classified","request_id":"decisionreq_00000000-0000-4000-8000-000000000001","answer_key":"u0001",
               "response":{"priority":"lowPriority","confidence":0.95,"probabilities":{"PRIMARY":0.025,"LOW_PRIORITY":0.975}}}}],
 "request":{"request_id":"decisionreq_00000000-0000-4000-8000-000000000001","input_tokens":288}}
```

| `decision.kind` | `priority` | `needs_retry` | その他のキー |
| --- | --- | --- | --- |
| `classified` | 表示用の優先度（LOW は confidence ≥ 0.90 のときだけ） | false | `request_id`（同じイベントの request）、`answer_key`、`response` |
| `retry_pending` | null | true | `reason`（境界保留と同じ値）、`message` |
| `carried_over` | 元の値 | `source_needs_retry` と同じ | `source_priority_run_id`、`source_event_seq`、`source_clause`、`source_needs_retry` |

`content_priority.assigned.request` は成功した結果だけに付けるため、呼出し失敗の保留も null です。carry-over と未判定 pending は呼出し自体がなく、利用計数にも加えません。carry-over は元 run・イベント・発話文が実在し、優先度と保留状態が一致することを検証します。本文比較は各 boundary run の保存 F 範囲をそれぞれの ASR 原文に適用した UTF-8 bytes で行い、parts の一致だけでは引き継ぎません。保留のまま引き継いだ発話文は保留のままです。

新しい優先度判定と保留は、ライブ・確定・再試行とも原文順に最大40発話文ずつ `content_priority.assigned` に保存します。一回の `classifyPriorities` 呼出しで1〜40 sequence を処理し、失敗した batch は全対象を `request: null` の保留にします。未判定 batch にも同じ粒度を使います。取り消しには保留イベントを作りません。判定呼出しのない carry-over event は batch 上限に含めません。

根拠: [ClauseRecords.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseRecords.swift)、[ClauseBoundaryAssembly.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseBoundaryAssembly.swift)、[共通の直列 batch](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClausePriorityBatches.swift)、[DecisionEnrichmentCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionEnrichmentCoordinator.swift)、[JSON 形状のテスト](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/DecisionEnrichmentCoordinatorTests.swift)、[確定・再試行の batch 保存](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/PriorityBatchPersistenceTests.swift)。

### run の来歴

`processing.run.started.payload.provenance` の全フィールドは次のとおりです。

| キー | 型 | 意味 |
| --- | --- | --- |
| `engine` | String | 実装・エンジンの名前 |
| `model` | optional String | モデル ID。モデルを使わない段階では省略 |
| `version` | String | 実装または依存 package の version / revision |
| `configuration` | String → String の object | その run の設定。数値も文字列で保存 |

判定 run は開始時に読み込んだモデル、または読み込めなかったことの provenance を `processing.run.started` に保存します。run の `configuration` は全て string 値です。境界判定の `span_policy` は、F 範囲の投影方針を識別します。

| 段階 | engine / model / version | configuration |
| --- | --- | --- |
| segmentation | `fluidaudio-silero-vad` / FluidAudio の Repo.vad.rawValue / `FluidAudio@0.15.8` | `pre_roll_seconds` = `0.1`、`max_segment_seconds` = `14.0`、`min_silence_seconds` = `0.75`、`vad_threshold` = `0.5`、`split_search_window_seconds` = `2.0`、`split_energy_frame_seconds` = `0.02`、`minimum_independent_segment_seconds` = `0.5` |
| asr | `qwen3-asr-swift` / 外部モデル ID aufklarer/Qwen3-ASR-1.7B-MLX-8bit / `speech-swift@c4c2fabbe825a9290c19e2f45d54ca3eae96b003` | `language=ja`、`minimum_input_seconds=0.02` |
| diarization | `fluidaudio-offline-diarizer` / FluidAudio の Repo.diarizer.rawValue / `FluidAudio@0.15.8` | `config` = FluidAudio の OfflineDiarizerConfig.default、`embedding.min_segment_duration_seconds` = `0.3` |
| clauseBoundary | `coreml-clause-tagger` / 外部 model ID sbintuitions/modernbert-ja-30m-multitagger / version = model の64桁 state-hash revision | `model_id` と `model_revision` は実際にロードした identity、`unit_policy=btsj-utterance-sentence`、`mode` は `live`、`final`、`retry`、`candidate_characters=、。？！?!`、`boundary_threshold=0.5`、`continuation_threshold=0.5`（いずれも厳密な `>` 判定）、`next_head_character_limit=60`、`window_content_tokens=190`、`window_policy=whole-piece-max-min-context`、`span_policy=argmax-o-f-d-f-only`、`span_window_policy=whole-piece-max-min-context`、`encoding_revision=1`、`max_tokens=192`、`compute_units=cpu-only`、`text_policy=neutral-punctuation-piecewise` |
| contentPriority | `coreml-clause-tagger` / 外部 model ID sbintuitions/modernbert-ja-30m-multitagger / version = model の64桁 state-hash revision | 実際の `model_id` / `model_revision`、`unit_policy=btsj-utterance-sentence`、`mode` は `live`、`final`、`retry`、`minimum_demotion_confidence=0.9`、`maximum_targets=40`、`encoding_revision=1`、`max_tokens=192`、`compute_units=cpu-only`、`text_policy=filler-removed-neutral-punctuation-piecewise` |
| decision unavailable | `unavailable` / `model=nil` / version `1` | `mode=live`、`unit_policy=btsj-utterance-sentence` |

判定 run の `model`、configuration の `model_id` / `model_revision`、`version` は実際にロードした外部 model ID と state-hash revision です。`unavailable` は、ライブ run の開始時にモデルを読み込めなかった、または ASR gap などでモデルを取得しないまま run を始めた場合です。成功 request record はモデルを記録せず、その run の provenance が request を処理したモデルを示します。

ライブの境界判定 run と優先度 run は判定結果を逐次保存し、対象列の終端で完了イベントを出します。確定処理への移行で取り消した run は完了イベントなしでも保存済み結果を保持します。ライブ run は metadata の `active_runs` に選ばず、確定処理は独立した境界・優先度 run の pointer を公開します。CLI の `ContentPriorityAccess.disabled` は Core ML tagger による判定を無効にし、必須の segmentation・diarization・ASR は実行した上で、任意の decision run を実行しません。ライブ ASR は完了イベントへ engine / model を記録しますが、確定処理と同じ started provenance を各 ASR run に出すわけではありません。

根拠: [RunProvenance.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/RunProvenance.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FinalTranscriptPipeline.swift)、[FluidVADSegmentationEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidVADSegmentationEngine.swift)、[NativeQwen3ASREngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeQwen3ASREngine.swift)、[FluidOfflineDiarizationEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidOfflineDiarizationEngine.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)。

ローカル判定と固定 model path の実装: [AppPaths.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AppPaths.swift)、[LocalClauseTagger.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)、[ClauseTaggerModel.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerModel.swift)、[ClauseTaggerTokenizer.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerTokenizer.swift)、[ClauseTaggerEncoding.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerEncoding.swift)。

## processing_metadata.json

`ProcessingMetadataStore` が明示した CodingKey の JSON を atomic write します。`schema_version` はイベントログと同じ `EventLogSchema.version` の値 `3` を必須とします。値の相違・欠落・型違いは payload の読取より先に拒否し、明示的な再処理でも置換しません。モデル・実装 version 群はここにはありません。

| キー | 型 | 意味 |
| --- | --- | --- |
| `schema_version` | Int | 必須。値は `3` だけ |
| `finalization_attempt` | object または null | 最新の確定処理の状態 |
| `active_runs` | object または null | 一括公開された現在の run 集合 |
| `pending_clause_boundary_segments` | 区間参照の配列 | 必須。公開済み snapshot で境界判定が未成立の区間。時間順 |
| `pending_content_priority_clauses` | 発話文参照の配列 | 必須。公開済み境界判定 run の閉じた非空発話文のうち、優先度が未成立のもの。原文順 |

保留の配列は重複を許さず、イベントログと一致しない場合（未知の区間・発話文、別 run、成立済み対象を含むなど）は読取・再試行前にエラーにします。境界保留配列は境界判定未成立の区間だけを含み、保留区間に続く未解決行を重複して加えません。

finalization_attempt の全フィールド:

| キー | 型 | 意味 |
| --- | --- | --- |
| `attempt_id` | String | 確定処理の試行 ID |
| `state` | String | `running` / `paused` / `failed` / `complete` |
| `failure_reason` | String または null | failed の理由 |

active_runs の全フィールドは optional String の `segmentation`、`asr`、`diarization`、`clause_boundary`、`content_priority` です。`clause_boundary` と `content_priority` は任意の decision run pointer です。どちらもローカル必須3段階ではありません。成功判定用の内部集合は JSON に保存しません。

開始時は公開済み active_runs と保留を保持したまま running にします。ローカル必須3段階が全て成功したときだけ、complete、新しい active_runs（segmentation・ASR・diarization の run、decision pointer は未設定）、全ての非空区間の境界保留を**一回の write** で保存し、優先度の保留を空にします。公開と保留保存の間にクラッシュ窓はありません。その後、App でモデルを読み込めれば境界・優先度 run を実行し、run pointer と両保留配列を一回の write で公開します。モデルを初期化できなければ判定 run を公開せず、境界保留を残します。CLI の `ContentPriorityAccess.disabled` は判定を実行せず、任意 decision run pointer は設定しません。公開時に active_runs が snapshot の作成元と変わっていれば公開しません。優先度だけの再試行は優先度 run pointer と保留配列だけを更新します。failed / paused は公開済みの結果を置き換えません。

復旧対象は running / paused の試行、またはまだ active_runs のない保存音声です。復旧は新しい確定 run の全量実行です。failed を自動で無限再試行しません。complete で保留配列が空でなければ、利用者の判定再試行の対象です。起動時の復旧は保留を再試行しません。公開済み snapshot より新しい未公開の確定・再試行の判定 run がある場合だけ、起動時の復旧が保留を対象に判定 run をやり直します。どちらも両配列をイベントログで検証し、公開済み snapshot から再構築します。未公開 run の結果は使いません。破損した metadata は自動復旧時には理由を報告して保持し、利用者の明示的な再処理だけが置換を許可します。schema_version の相違・欠落・型違いは置換の対象外で、読取・追記・復旧・再処理をエラーにします。

根拠: [ProcessingMetadata.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)、[ActiveRuns.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ActiveRuns.swift)、[SessionRecoveryScanner.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecoveryScanner.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/NativeSessionProcessor.swift)。

## checkpoint と PCM タイムライン

### checkpoint.json

`AudioCheckpoint` をキー変換なしで保存します。以下はすべて必須で、空の配列も省略しません。

| キー | 型 | 意味 |
| --- | --- | --- |
| `committedFrames` | Int64 | 完全に公開された音声のフレーム数 |
| `sampleRate` | Double | `16000` |
| `channelCount` | Int | `1` |
| `sampleFormat` | String | `float32LE` |
| `chunkFiles` | String 配列 | タイムライン順の chunk basename。重複・空・`.`・`..`・`/` を含む名前は不正 |
| `chunkFrameCounts` | Int 配列 | chunkFiles と同じ長さ。各値は 1〜Int32.max。合計が committedFrames に一致 |
| `gapEvents` | object 配列 | durable 音声内に含まれる欠落記録 |

gapEvents の object は `startFrame`: Int64（0 以上）、`frameCount`: Int64（正）、`reason`: String です。reason の raw value は `missingCallback`、`overflow`、`invalidBuffer`、`stopTail` です。gap は無音補填した範囲であり、時刻を詰めて削除しません。

### 音声用 JSONL と chunk

- `audio-chunks.jsonl`: 1 行が `{"index":0,"frames":8000}` のような commit object。index は 0 始まりの chunk 番号、frames は canonical フレーム数です。
- `audio-gaps.jsonl`: 1 行が `{"startFrame":0,"frameCount":160,"reason":"missingCallback"}` のような canonical 座標の gap object。checkpoint の gapEvents と同じ型で、snake_case ではありません。
- chunk の basename は chunk- に 6 桁の index と .f32le を付けたものです。ヘッダーのない little-endian mono Float32 を保存し、期待バイト数は frames × 4 です。
- 録音の通常 chunk 長は 0.5 秒、import は 5 秒です。checkpoint / finish ではメモリ上の端数 chunk も flush するため、すべての chunk が同じ長さとは限りません。

chunk を atomic write して synchronize した後、その index を append / synchronize します。gap は補填無音を chunk に入れる前にログへ同期します。checkpoint は atomic write の snapshot です。メモリ上の未 flush 音声は committedFrames に含めません。

読取時には snapshot、chunk index、連続する公開済み chunk を合わせて最新の checkpoint を復元します。snapshot 更新前にクラッシュしても、末尾に完全な連番 chunk があれば取り込みます。各 chunk のサイズ・channel 幅・記録フレーム数を検証し、不一致・欠損は明示エラーにします。gap は実際の durable 範囲まで切り詰め、音声の公開前に残った gap 全体を有効とはみなしません。音声用 JSONL の commit として採用するのは LF 終端の行です。

`ProcessingTimeline` の型は `version`（1）、`sampleRate`、`channelCount`、`sampleFormat` を持ち、frame からミリ秒への変換を定義します。独立した timeline JSON ファイルは保存せず、永続音声の自己記述情報は、`recordingPCM` と import の処理タイムラインでは checkpoint に、`recordingFLAC` では `storage.json` の `timeline` にあります。保存済みセッションとエンジン入力は非 canonical 形式を拒否します。表示時刻は frame × 1000 / 16000 の小数部を 0 方向に切り捨てます。イベントの source frame は保存タイムラインの座標であり、入力デバイスや original の frame 座標ではありません。VAD・ASR・話者分離で再度 mono 化や SRC は行いません。

根拠: [DurableAudioWriter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DurableAudioWriter.swift)、[ProcessingTimeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingTimeline.swift)、[ProcessingTimelineReader.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingTimelineReader.swift)、[AudioBlockRing.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioBlockRing.swift)、[LiveTranscriptionCadence.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveTranscriptionCadence.swift)、[ASR.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASR.swift)。

## 読取・復旧と公開ビュー

イベント JSONL では、末尾の LF 未終端かつ不正な JSON 行だけを復旧時に無視・切り詰められます。途中の不正行、LF 終端の不正行は破損として扱います。完全な JSON の最終行に LF がない場合、SessionWriter は LF を足して保持します。イベント番号がある行では正の整数であることを検証します。

イベント header の `event_seq` は正の整数で、ログ順に厳密に増加します。重複・逆転は reader と既存ログへの append の両方で拒否し、破損した番号を並べ替えて補正しません。

保存済みセッション一覧は active ASR run がある場合、イベントログを変更せずに読み込み、JSONL と active transcript event payload を検証します。ログが欠損・不正、または不完全な末尾を含む場合は派生結果を破損として表示し、公開 transcript を持たない扱いにします。active transcript がない未処理セッションではログを要求しません。

ライブ→確定の固定には `SessionWriter.readDurableLog` を使い、append と同じファイルロックを取って synchronize 完了後のログを読みます。読取は破損末尾を切り詰めずエラーにし、固定後のイベントは再利用対象に追加しません。公開 reader・再試行・catalog は公開 run と参照先の source／carry 元だけを厳密に解釈し、carry 元も再帰的に境界組み立てと優先度整合を検証します。

`EventLogTranscriptReader` は全行の header（`schema_version` を含む）を読み、必要な既知イベントの run ID を要求します。非 active run や未知イベントの payload は解釈せず、active run の必要フィールド欠落・型違いはエラーです。ASR outcome と text の不一致もエラーです。発話文判定イベントは reader、再試行分析（`DecisionRetryAnalyzer`）、ライブ再利用、保存済み一覧が共通 decoder で検証します。保存済み境界判定から発話文を再組み立てし、保存結果と比較します。完了 run は全ての非空区間を覆い、組み立て結果と完全一致しなければなりません。未完了のライブ run は組み立て結果の先頭部分であれば読めます。候補・次区間先頭・範囲・参照・引き継ぎ元の不一致はエラーです。読み取り・検証で判定を再実行しません。

`EventLogTranscriptReader` は header・ローカル transcript の decoding を担当し、発話文イベントの共有解析・source/carry 検証・組み立て replay は [ClauseEventLog.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseEventLog.swift) にあります。公開済み run の完了・pending 整合は [PublishedTranscriptValidation.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/PublishedTranscriptValidation.swift)、再試行対象の検証と計数は [DecisionRetryAnalyzer.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionRetryAnalyzer.swift) が担当します。reader・再試行・catalog・ライブ再利用は同じ `ClauseEventLog` を使い、独立した発話文 decoder を持ちません。

`TranscriptMaterializer` が公開 run の区間・ASR・話者・節の境界・優先度を適用します。materialization はモデルを読み込み・実行せず、保存済み assessment の `filler_ranges` だけを原文へ投影します。assessment がまだない区間、境界 pending / failed、判定を無効にした CLI では原文をそのまま表示本文に使います。assessment がある区間は F 範囲を除去した後、保存済み LOW の clause slice をさらに除去します。CLI の `segments.json` は配列で、各 object の全キーは次のとおりです。

| キー | 型 |
| --- | --- |
| `segment_id` | String |
| `source` | 区間参照 |
| `start_ms`, `end_ms` | Int64 |
| `text` | String。ASR 原文 |
| `display_text` | String。フィラーと保存済み LOW 発話文を除いた表示本文 |
| `speakers` | object 配列。各 object は `id`: String、`start_ms` / `end_ms`: Int64、`confidence`: optional Double |
| `clause_state` | `awaiting_next_segment` / `boundary_pending` / `priority_pending` / `classified` |
| `clause_slices` | object 配列。各 object は `reference`: 節参照、`source_range`: 原文の範囲、`priority`: `primary` / `lowPriority` / null、`needs_retry`: Bool |

原文が空の区間は公開 JSON・ライブ表示・テキスト書き出しに出しません。イベントログからは削除しません。`isDiarized` と話者の `displayLabel` は画面用の内部情報で、公開 JSON に出しません。`segments.json.text` とイベント中の ASR 本文は原文のままで、Linux の CER 評価などはこの原文を読みます。`display_text` は画面と同じ表示本文です。区間をまたぐ節の全 parts は各行に複製せず、`clause_slices` の節参照から `clauses.closed` を辿ります。全範囲の境界が未成立の行は `clause_slices` が空で `boundary_pending` です。部分的な未解決範囲がある行も `boundary_pending` ですが、独立して閉じた保存済み節の slice は保持します。フィラーだけ・全 LOW で `display_text` が空になった行も、原文があれば JSON に残します。テキスト書き出し `transcript.txt` は画面と同じ発話と表示本文を使い、表示本文が空白・改行だけになる行は除外します。話者ラベルは 80% 以上を占める 1 人、満たさなければ併記します。

根拠: [SessionRecovery.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecovery.swift)、[EventLogTranscriptReader.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/EventLogTranscriptReader.swift)、[Materialization.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[SessionExport.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/SessionExport.swift)、[ファイル処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)。
