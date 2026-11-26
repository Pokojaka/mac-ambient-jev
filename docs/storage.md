# セッション保存形式

保存音声は再処理の基礎であり、文字起こし・BTSJ 発話文の境界・優先度は派生結果です。発話文の境界と優先度は app bundle 同梱の Core ML 発話文モデルが判定します。保存 key と event 名の `clause` / `節` はその発話文単位の識別名です。派生結果は追記専用イベントログに残し、最新の `pipeline.started` と後続の `pipeline.decisions.replaced` が現在世代と選択中の判定 run を決めます。処理 metadata は進行状態だけを持ち、run の選択には使いません。処理の流れは [architecture.md](architecture.md) を参照してください。

以下の表は **JSON 上の実際のキーと値**です。イベントと処理 metadata は snake_case のキーを使いますが、checkpoint と音声用 JSONL は camelCase です。String enum の値はキー変換の対象ではなく、`clauseBoundary`、`contentPriority`、`lowPriority` などは camelCase のままです。

## 保存場所とセッションフォルダー

Windows の共通コアは LocalAppData/mac-ambient-jev 配下のセッション・モデルを使い、macOS の sandbox パスは構築しません。WinUI shell は同じ app root の logs フォルダーを所有します。OS ごとの取得方法と Windows の実行範囲は [windows.md](windows.md) を参照してください。

GUI アプリは sandbox 内で動作し、標準のセッション保存先は `~/Library/Containers/app.mac-ambient-jev/Data/Library/Application Support/mac-ambient-jev/sessions` です。全てのセッション CLI は各モードで `--sessions-root DIRECTORY` を必須とし、CLI が既定保存先を選ぶことはありません。非 sandbox の `~/Library/Application Support/mac-ambient-jev/sessions` とその cache、および sandbox 側の app data/cache は CLI の保護対象です。明示 root はこれらの領域と祖先・子孫関係にならず、symlink 経由でも重ならない必要があります。各 Application Support の mac-ambient-jev 以下に sessions と音声処理モデルの models、各ユーザーの Caches 以下の mac-ambient-jev にキャッシュを置きます。発話文判定モデルはここに置かず、app bundle の Resources 内 `clause-tagger` ディレクトリから読みます（[発話文判定](decision-engine.md#モデルの同梱と更新)）。`AppPaths` は sessions root のみ上書きでき、models root は上書きできません。設定の「録音データ」と保存済み録音の詳細から sessions フォルダーを Finder で開けます。App の設定は UserDefaults / AppStorage にあり、セッション JSON のフィールドではありません。

フォルダー名は `YYYY-MM-DD_HH-mm-ss_<stem>_<UUID先頭8桁の小文字hex>` です。作成時に一度取得した日時を、明示した time zone のローカル時刻として Gregorian calendar・`en_US_POSIX` で表します。年は ASCII 4 桁（0001–9999）。Mac のアプリと CLI は `.current` を渡し、Windows の engine は OS のローカル時間帯を渡します（[windows.md](windows.md)）。マイク・システム音声の録音は stem が `録音`、読み込みは元ファイル名の最後の拡張子を除いた stem です。

stem の Windows 禁止文字（`<>:"/\|?*` と U+0000–001F）、先頭の `.`、末尾に連続する `.` と空白は `-` に置換します。CON・PRN・AUX・NUL・COM1–9・LPT1–9（数字の上付き ¹²³ を含み、最初の拡張子より前を大文字小文字を区別せず判定）は先頭に `-` を付けます。固定部分は UTF-8 29 byte、stem は Swift Character の境界で 226 byte 以下に切り詰め、切り詰め後にも名前を検証し、全体を 255 byte 以下にします。この規則は全 OS で共通です。読み取り時には禁止文字・末尾のドットや空白・予約名を含む stem を修復せず拒否します。合成文字は分割せず、manifest の元ファイル名は正規化・変更しません。元ファイル名の NUL、空の stem、最初の Character が上限に入らない名前、形式で表せない日時は明示エラーです。同名の既存フォルダーは上書きしません。名前の辞書順は作成時に記録したローカル時刻順であり、DST や time zone の変更をまたぐ UTC 順ではありません。

セッション identity は `session.json` の **完全な UUID** です。`SessionLayout` は実際の `sessionURL` だけを受け取り、ID から URL を生成しません。`SessionDirectoryLocator` は root 直下の全ディレクトリの manifest を読み、完全な UUID の一致を数えます。0 件は `notFound`、複数件は名前順のフォルダー一覧付き `multipleMatches`、1 件は名前の検証後に URL を返します。無関係な壊れた manifest は identity を提供しません。一致した manifest のフォルダー名が不正なら、その検証エラーを返します。

lookup・一覧・復旧は列挙で得た実フォルダー名を使い、指定された root URL の表記を保ちます。作成時に返した URL と、同じ root から取得した行・lookup の URL は同じ identity として扱えます。

読み取りでは固定 19 byte の日時と最後の `_` に続く小文字 ASCII hex 8 桁を解析し、日時の Gregorian 妥当性、manifest UUID の接頭辞、同じ規則で算出した source stem を検証します。日時の妥当性は読み取り時のローカル time zone に依存しません。フォルダーの日時と `created_at` は比較せず、読み取り時に作成日時や ID から名前・URL を再計算したり、フォルダーを改名したりしません。

一覧と復旧は非表示を含む全直下ディレクトリを対象とし、通常ファイルは対象外です。manifest の欠損・破損、名前の不正、UUID 接頭辞・source stem の不一致はフォルダーごとのエラーとして表示し、健全な他のセッションは処理を続けます。同じ完全 UUID の複数フォルダーは全て読み込みエラー・復旧失敗とし、二重に処理しません。保存済み一覧の行 identity と選択は URL。壊れた manifest に UUID を捏造せず、読み取れた UUID だけを保持します。正常行の再処理・書き出し操作は UUID を使います。

根拠: [SessionFolderName.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionFolderName.swift)、[SessionDirectoryLocator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionDirectoryLocator.swift)、[SavedSessionCatalog.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SavedSessionCatalog.swift)。

### セッション内のファイルアクセス境界

Windows では root を CreateFileW で検査し、固定した親 handle から NtCreateFile で子を開きます。reparse point は全て拒否します。原子保存は同一ディレクトリに排他的な一時ファイルを作成して FlushFileBuffers で同期し、`writeAtomically` は `msj_rename` helper で公開します。公開 file access API は helper 呼び出し前にファイルを flush し、呼び出し後に親ディレクトリを flush します。`msj_rename` は `FILE_RENAME_REPLACE_IF_EXISTS | FILE_RENAME_POSIX_SEMANTICS` を設定して NtSetInformationFile を呼び出すだけです。`SessionFileAccess.rename` も同じ helper を使います。ログは LockFileEx で排他制御します。API の失敗はエラーにし、保証の弱い経路へ切り替えません。詳細は [windows.md](windows.md) を参照してください。以下の POSIX descriptor の説明は macOS と Linux に適用します。

`sessionsRoot` 自体と直下のセッションフォルダー、セッション以下の全ディレクトリ・ファイルに symlink は使えません。`session.json`、`events.jsonl`、`processing_metadata.json`、audio ディレクトリの `storage.json`、checkpoint・chunk index・gap log・PCM chunk、保存済み original・FLAC、`.recording.flac.partial` も同じ規則です。末尾ファイルだけでなく `audio`・`processing` などの親ディレクトリの symlink も、読み書き・列挙・復旧・削除で明示エラーにします。catalog と復旧はリンクされたセッションをエラー行として扱い、リンク先をセッションとして処理しません。

`SessionFileAccess` は呼出し元が明示した実 root を `O_DIRECTORY | O_NOFOLLOW` で開き、子ディレクトリを固定した descriptor から `openat` でたどります。通常ファイルは `O_NOFOLLOW` で開いた descriptor を使い、書込み用一時ファイルは同じ実ディレクトリに排他的に作成して `renameat` で公開します。公開前にファイルと公開後にディレクトリを同期します。Apple と Windows の音声 decoder は `SessionFileAccess` が session root に固定して開いた handle を decode の全期間使います。URL を事前検証した後に path から開き直す経路はありません。Windows の decoder が CRT descriptor や Media Foundation の byte stream を使う場合も、元の固定 handle の duplicate から作られます。開いた後でパスが置き換わっても、その操作は開いた元のファイルを使い、symlink の外部対象を変更しません。

音声 API は所有する `sessionURL` を明示的に受け取り、処理ディレクトリだけを root にして親の検査を省きません。境界より上の、呼出し元が選んだ保存場所の ancestry（macOS の `/var` などの OS alias を含む）はこの規則の対象外です。CLI の保護領域の重なり検査は別途 symlink 解決後にも行い、選択した root 自体をリンク先へ置き換えません。外部から選んだ import 元と、書き出し先のフォルダー・`segments.json` 等の外部 artifact はセッション内アクセス境界の対象外ですが、書き出すセッション側の original・FLAC は descriptor から読みます。

根拠: [SessionFileAccess.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionFileAccess.swift)、[DescriptorAudioFile.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/DescriptorAudioFile.swift)、[Windows AudioImportDecoder.swift](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/AudioImportDecoder.swift)。

セッションの構成は次のとおりです。これは生成されるファイル配置であり、リポジトリ内のファイルではありません。

```text
2023-11-15_07-13-20_録音_0123abcd/
├── session.json
├── events.jsonl
├── processing_metadata.json          処理開始後
└── audio/
    ├── storage.json                  保存音声の権威。セッション作成時に書く
    ├── recording.flac                録音の FLAC 保存形式（storage.json が recordingFLAC のとき）
    ├── .recording.flac.partial       FLAC 化中の一時ファイル
    ├── original.<元の拡張子>          import のみ。拡張子なしなら original
    └── processing/
        ├── checkpoint.json
        ├── audio-chunks.jsonl
        ├── audio-gaps.jsonl
        └── chunk-000000.f32le ...     0 始まりの連番
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

状態ごとの audio ディレクトリの中身は次のとおりです。`.recording.flac.partial` は FLAC 化中だけ存在する一時ファイルで、確定処理の終了処理と起動時の保存整理で削除します。import の processing ディレクトリも確定処理の終了後は残りません。

| 状態 | 作られる時 | audio ディレクトリの中身 |
| --- | --- | --- |
| `recordingPCM` | 録音セッションの作成時から FLAC 化まで | `storage.json`、processing ディレクトリ（PCM chunk） |
| `recordingFLAC` | FLAC 化の完了時 | `storage.json`、`recording.flac` |
| `importedOriginal` | import セッションの作成時から | `storage.json`、`original*`。確定処理の間だけ processing ディレクトリ（処理タイムライン） |

- `storage.json` が保存音声の形を決める唯一の権威で、3 状態のどれかです。`recordingPCM` は processing ディレクトリの PCM chunk が録音です。`recordingFLAC` は `timeline`（長さと欠落記録）を持ち、`recording.flac` が録音です。`importedOriginal` は `timeline`（直近の処理タイムライン構築の長さと欠落記録。構築前は null）を持ち、original が元です。ファイルの欠落・破損・セッションの作成方法との不一致はセッションごとのエラーで、推測で補いません。状態が `recordingFLAC` なら PCM が残っていても読まず、FLAC が欠落または復号できなければエラーです。
- 録音は `recordingPCM` の間、処理タイムライン自体が保存音声です。入力の全 channel を平均し、連続 SRC を通した **16,000 Hz・mono・32-bit float PCM** を保存します。
- import では元ファイルを無再圧縮コピーした `original` または original に元の拡張子を付けたファイルが保存音声です。audio 直下の該当する通常ファイルは **ちょうど 1 つ**必要です。0 個または複数個ならエラーです。元の外部ファイルを再処理の入力にはしません。
- import の処理タイムラインは **16,000 Hz・mono・32-bit float PCM** の派生物です。macOS と Windows の builder は保存済み original を bounded buffer で読み、全 channel を算術平均してから連続 SRC を行います。Linux の [`PortableImportedAudioTimelineBuilder`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableImportedAudioTimelineBuilder.swift) は miniaudio 0.11.23 で WAV・FLAC・MP3 を読みますが、入力が既に 16,000 Hz・mono でなければエラーにし、channel mixing と SRC を行いません。どの OS でも original の bytes は変更しません。予期しない EOF・不正 PCM・変換失敗は明示エラーです。
- macOS と Windows の import builder は共有の `ImportedAudioPCM.downmix` で全 channel の算術平均を作り、共有の `ImportedAudioTimelineWriter` で canonical timeline を書きます。両者とも 5 秒単位の chunk を使い、chunk index は 0 始まりです。したがって PCM chunk・audio-chunks.jsonl・checkpoint の形式と index 規則は同じです。Linux の builder は入力の channel mixing や SRC を行わず、canonical な入力を timeline に書きます。
- Windows は WAV・FLAC・MP3 を miniaudio 0.11.23 で、M4A・AAC を Media Foundation Source Reader で decode します。M4A/AAC は session handle の read-only IStream を IMFByteStream に包んで Source Reader に渡し、pathname を再度開きません。Windows の canonical 境界は累積 source frame 数 `n` ごとに `round(n × 16000 / sourceRate)`（最も近い整数、ちょうど中間はゼロから離れる方向）で決めます。EOS では bounded zero input で変換器を進め、丸めた終端境界までを出力し、それを越える filter tail は捨てます。
- macOS の AVAudioConverter は通常の priming 後に EOS まで drain し、正確な変換長の floor または ceil にあたる出力を全て保持します。Windows の境界丸め・tail trimming と macOS の EOS 出力長は同じ規則ではありません。また、異なる converter の出力 sample 値は bit-identical ではありません。
- Windows の Media Foundation AAC decode は Source Reader が返す PCM を EOS まで消費します。platform codec padding が decoded frames に含まれる場合もそのまま source timeline に含め、再生時間等から推定した padding trimming は行いません。
- 各 platform の timeline builder は Core の [`ImportedAudioTimelineBuilding`](../app/MacAmbientJev/Sources/MacAmbientJevCore/ImportedAudioTimelineBuilding.swift) を実装し、セッションに保存済みの original だけを読み、コピーせずに processing timeline を作って checkpoint を返します。builder は `storage.json` を書きません。共通 Pipeline の [`SessionProcessingAudio`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingAudio.swift) は注入された builder を `SessionLayout.processingDirectory`（audio 配下の処理ディレクトリ）とともに呼び、checkpoint から reader を作成して音声を検証した後、`.importedOriginal(reader.info)` を `storage.json` に保存します。
- `SessionTransientAudio.urls` は `.recording.flac.partial` を全 source の削除対象にし、import の場合だけ processing ディレクトリも加えます。録音の PCM は一時ファイルではなく、FLAC 状態を保存するまで権威です。録音の書き出し音声は `recording.flac` のコピー、import の書き出し音声は original のコピーであり、内部 PCM chunk と外部書き出しは別物です。

根拠: [共有 ImportedAudioTimelineWriter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ImportedAudioTimelineWriter.swift)、[CanonicalAudio.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/CanonicalAudio.swift)、[macOS AudioFileTimelineBuilder.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[macOS CanonicalAudioResampler.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/CanonicalAudioResampler.swift)、[Windows AudioFileTimelineBuilder.swift](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/AudioFileTimelineBuilder.swift)、[Windows CanonicalAudioResampler.swift](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/CanonicalAudioResampler.swift)、[Windows AudioImportDecoder.swift](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/AudioImportDecoder.swift)、[CWindowsAudio.cpp](../app/MacAmbientJev/Sources/CWindowsAudio/CWindowsAudio.cpp)、[CMiniaudio README](../app/MacAmbientJev/Sources/CMiniaudio/README.md)。

### 録音の FLAC 化

`RecordingAudioCompactor` は現在 generation の処理が drain され、入力が seal 済みで checkpoint の frame 数・sample rate と一致し、segmentation・全 segment の ASR が成功した場合だけ `recordingPCM` を `recording.flac`（16 kHz・mono・16-bit FLAC）へ変換して PCM を削除します。世代・音声の検証が終わるまでは権威ある PCM を compact しません。`.recording.flac.partial` の cleanup は PCM compact とは別です。符号化器 `RecordingFLAC` と復号器 `FLACTimelineReader` は `MacAmbientJevCore` にある Foundation を使う portable な pure Swift 実装で、macOS・Linux・Windows で共通です。出力は native FLAC で、metadata block は STREAMINFO だけです。

各 FLAC frame は公称 4,096 frame で、最後の frame だけは短くできます。STREAMINFO の total samples は `storage.json` の `committedFrames` と正確に一致します。STREAMINFO の block size 最小値・最大値は [RFC 9639](https://www.rfc-editor.org/rfc/rfc9639.html) に従って短い最終 frame を除く公称 block size（4,096）を記録し、frame size 最小値・最大値は実際に符号化した frame の byte 数から記録します。MD5 は signed 16-bit little-endian PCM 全体から計算します。

符号化器は各 block で CONSTANT、VERBATIM、FIXED の次数 0〜4 を比較し、符号化 bit 数が最小の形式を選びます。FIXED の残差は Rice method 0、partition order 0〜8 を評価します。FIXED の各予測次数について、最細 partition order の各 partition の絶対残差和・負の残差数と、`k=1〜14` の Rice quotient 和を一度だけ正確に集計し、隣接 partition を併合して粗い partition order を評価します。各 partition order で `k=0〜14` の正確な符号化コストを評価し、block 間で固定サイズの作業用 buffer 群を再利用します。サンプルは有限値のみを受け付け、`[-1, 1]` に clamp して 32,768 倍し、最も近い整数へ丸めます（ちょうど中間の値はゼロから離れる方向）。その後 Int16 範囲へ clamp します。非有限値は明示エラーです。

`FLACTimelineReader` は開くときに STREAMINFO の形式（16 kHz・mono・16-bit）と total samples が `committedFrames` に一致することを検証します。全音声検証では frame を順に読み、header CRC-8、frame CRC-16、frame 数、MD5 を検証し、切り詰め・末尾の余分な bytes・長さ不一致をエラーにします。PCM との比較検証では全ての量子化済み sample が一致することも確認します。decoder は fixed-blocking の CONSTANT・VERBATIM・FIXED・LPC subframe、Rice・Rice2 residual、wasted bits を読み取ります。可変 block、対応しない format や符号化、CRC 不一致、切り詰め、余分な末尾 bytes、長さ不一致は明示エラーです。

frame index は byte offset と先頭 sample（および小さな frame 情報）だけを保持し、最初の random read 時の構造 scan、または全音声検証時に一度だけ構築します。random read は要求範囲と交差する frame だけを復号します。音声全体の PCM は保持せず、メモリ使用量は小さな frame index を除いて録音時間に比例しません。ファイル I/O は `SessionFileAccess` が session root に固定した handle を使います。

1. processing ディレクトリの checkpoint と PCM を検証します。`committedFrames` が 0 の録音は compactor の `committedFrames > 0` guard により変換対象にならず、`recordingPCM` のままで FLAC を作りません（`audioSource` は nil です）。`RecordingFLAC.write` を 0 frame で直接呼んだ場合も、出力ファイルを開く前に明確な empty-recording error を返します。
2. 古い `.recording.flac.partial` を削除し、`RecordingFLAC` で `.recording.flac.partial` へ書き込み、synchronize します。
3. partial の STREAMINFO と全 frame を検証し、total samples が `committedFrames` と正確に一致することを確認します。全 frame を順次復号して CRC と MD5 を検証し、PCM source の全 sample の量子化値とも比較します。読み書きと検証は FLAC block 単位の streaming 処理で、音声全体の PCM を保持しない bounded-memory です。短い読み取り、PCM 不一致、復号失敗はエラーです。
4. `recording.flac` へ rename して公開し、`storage.json` を `recordingFLAC(timeline)` に保存します。この保存が権威を切り替える唯一の操作です。
5. processing ディレクトリを削除して audio ディレクトリを synchronize します。

変換は現在世代のローカル両段階が完全成功し metadata が同世代の `complete` を示した後に実行し、起動時も同条件を再検証して必要な保存整理を再開します。変換の失敗は「文字起こしは保存しましたが、録音を FLAC にできませんでした: …」として報告し、公開済みの文字起こしと PCM は残ります。一時ファイルの削除に失敗した場合は、一時停止した実行なら一時停止のまま削除エラーだけを状態文として報告し、完了した実行なら「文字起こしは保存しましたが、音声の一時ファイルを削除できませんでした: …」、失敗した実行なら元のエラーに「。音声の一時ファイルを削除できませんでした: …」を続けて報告します。`recordingPCM` の compact は generation status・sealed/checkpoint frame 数と sample rate・segmentation/ASR completion・全 ASR 成功数の一致が確認できた録音だけです。open generation の権威 PCM は残します。一時停止・保留・失敗では録音 PCM を削除せず、変換と一時ファイルの削除は完了通知（完了状態の更新、保存済み一覧の更新、自動書き出し）より前に終えます。

### 起動時の保存整理

アプリは起動時に、録音中のセッションを除く全セッションの保存整理を、キューへ何も入れる前に 1 件ずつ最後まで実行します。状態は「保存済み録音の音声を整理しています（n件）」です。`recordingPCM` は最新世代が complete で、sealed/checkpoint frame・rate と segmentation/ASR 成功数が一致する場合だけ compact します。`recordingFLAC` に処理 PCM が残る場合は FLAC を検証して PCM を除去し、その他の transient cleanup は FLAC 化と独立して実行します。音声ソースは使う時点で `storage.json` から決めるため、整理後の再走査はありません。整理中は処理キューを開始せず、その間の要求は整理後に順に処理します。整理中に要求されたセッションは、その起動の復旧対象から外します。整理結果の map は成功したセッションを含まず、未完了の session UUID ごとに `SessionMaintenanceIssue.failed`（実際の保存整理エラー）または `SessionMaintenanceIssue.interruptedByShutdown`（shutdown cancellation が発生した現在の item と残りの item）を返します。実エラーと cancellation が同じ item で起きた場合、その item は `.failed` として残し、後続の未実行 item は `.interruptedByShutdown` になります。どちらの issue も、そのセッションの保存整理が成功するまでは推論復旧の対象にしません。次回起動時に未完了の保存整理を再検出し、成功した後に限り推論復旧へ進みます。実際の整理エラーはフォルダー名を付けて「保存済み録音の音声を整理できなかったセッションがn件あります: …」と報告します。shutdown interruption は「終了処理のため保存済み録音の音声整理が中断されたセッションがn件あります。次回起動時に再実行します: …」と報告します。復旧できないセッションの報告と合わせるときは、復旧できない報告を先にして「。」でつなぎます。

整理が終わった時点で、処理状態とライブ文字起こしのヘッダーから整理中の表示を解除します。整理中の表示がまだ残っている欄だけを整理前の状態へ戻し、その間に録音や文字起こし処理が更新した状態は上書きしません。shutdown interruption だけの報告は処理状態に次回起動時の再実行を示す文を残しますが、App の `processingState` を `.partialFailure` にせず、ライブ文字起こしのヘッダーは整理前の状態へ戻します。実際の保存整理エラーまたは復旧失敗を含み、復旧対象がない報告は `.partialFailure` になります。復旧対象がなく整理だけが完了した場合も、整理中の表示は残りません。

どの時点で中断しても、再実行は `storage.json` を見て同じ終状態に収束します。`recordingPCM` のまま `recording.flac` が残っていれば、PCM と完全一致する場合だけ採用し、不一致や破損なら削除して PCM から作り直します。`recordingFLAC` では FLAC を全復号して検証し、失敗すれば PCM に触れずエラーにします。`importedOriginal` は変換対象外です。

根拠: [AppPaths.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AppPaths.swift)、[SessionLayout.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionLayout.swift)、[AudioImporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioImporter.swift)、[AudioCaptureEngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevCapture/AudioCaptureEngine.swift)、[TimestampedMonoSink.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/TimestampedMonoSink.swift)、[RecordingFLAC.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/RecordingFLAC.swift)、[FLACTimelineReader.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/FLACTimelineReader.swift)、[SessionFileAccess.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionFileAccess.swift)、[AudioFileTimelineBuilder.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)、[SessionExporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionExporter.swift)。起動時の保存整理は [RecordingAudioCompactor.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/RecordingAudioCompactor.swift)、[SessionRecoveryEffects.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionRecoveryEffects.swift)、[SessionProcessingCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingCoordinator.swift)、[AppState+Processing.swift](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+Processing.swift) を参照してください。

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
| `schema_version` | Int | 必須。値は `4` だけ。reader は他の値・欠落の行を読まずにエラーにし、`SessionWriter` は既存ログにその行があれば追記しない |
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
| `pipeline.started` | なし | `id`: UUID、`runs`: 下記の run ID object、`sample_rate`: Double、`segmentation_provenance` / `asr_provenance`: provenance object |
| `pipeline.decisions.replaced` | なし | `generation_id`: UUID、`previous`: optional `{boundary: String, priority: String}`、`replacement`: `{boundary: String, priority: String}` |
| `processing.run.started` | run | `stage`: String、`provenance`: 下記の object |
| `processing.run.completed` | run | `stage`: String、`succeeded`: Bool、`completed_count`: Int、`failed_count`: Int |
| `segment.created` | seg run、segment、開始・終了範囲 | `speech_ranges`: `[[Int64]]` |
| `segmentation.progress` | seg run | `consumed_frames`: Int64 |
| `segmentation.input.sealed` | seg run | `frame_count`: Int64 |
| `segmentation.completed` | seg run | `consumed_frames`: Int64、`segment_count`: Int |
| `asr.pending` | run、seg run、segment、開始・終了範囲 | 空 object `{}`。確定処理でのみ出力する |
| `asr.completed` | run、seg run、segment、開始・終了範囲 | `text`: String、`detected_language`: optional String、`engine`: String、`model`: optional String、`outcome`: `recognized` または `empty` |
| `asr.failed` | run、seg run、segment、開始・終了範囲 | `kind`: 下記の失敗種別、`message`: String |
| `clause_boundaries.assessed` | run（境界判定 run） | 下記の境界判定 object |
| `clause_boundaries.pending` | run（境界判定 run） | `source`: 区間参照、`reason`: 保留理由、`message`: String |
| `clauses.closed` | run（境界判定 run） | 下記の節 object。複数行にまたがるため envelope の segment は使わない |
| `content_priority.assigned` | run（優先度 run） | `assignments`: 判定 object の配列、`request`: リクエスト記録または null |

`segment.created` 1件が1 segment（grouped speech ranges）を表し、`speech_ranges` は空でない配列です。各 `[lower, upper)` は `0 <= lower < upper` の非負フレーム範囲で、lower 順に昇順かつ相互に重なりません（隣接可）。先頭 lower から末尾 upper までの外側範囲は canonical 16 kHz で30秒以下で、envelope の `source_start_frame` / `source_end_frame` はそれぞれ先頭 lower / 末尾 upper です。ASR は各範囲だけを読み連結し、範囲間の gap は読みません。例: `{"speech_ranges":[[0,16000],[24000,40000]]}`。

`stage` の raw value は `segmentation`、`asr`、`clauseBoundary`、`contentPriority` です。metadata のキー `clause_boundary` / `content_priority` と、stage の値 `clauseBoundary` / `contentPriority` を混同しないでください。

`pipeline.started.payload.runs` は `segmentation` と `asr` の ID を必須とし、`clause_boundary` と `content_priority` は両方とも存在するか、両方とも省略します。最新の `pipeline.started` だけが現在世代を定め、それ以前の世代の event payload は論理的に選択対象外になります（ログから物理削除せず、形式移行もしません）。この generation の run ID と最後の decision replacement が materializer への投影入力であり、metadata に active ID は保存しません。`pipeline.decisions.replaced` は同じ `generation_id` の現在の decision pair と optional `previous` が一致することを検証し、必須の `replacement` pair を一つの event で選択します。再試行 pair 全体の判定結果と完了成功を検証した後にだけ event を追記します。優先度だけの再試行では既存 boundary ID と新しい priority ID を組にし、失敗・進行中の pair は選択しません。同じ generation で一度でも選択された priority run ID（初期 pair と以前の replacement の priority）は再選択できず、読取は不正ログとして拒否します。

`asr.completed.outcome` は本文の全 Unicode scalar が空白・改行・句読点（Foundation の whitespacesAndNewlines と punctuationCharacters の文字集合）なら `empty`、それ以外は `recognized` です。`engine` と `model` は認識した実エンジンの provenance から取ります。Mac の本番 engine は `onnxruntime-haas-tdt`、model は [Sanami/haas-ja-onnx/int8dyn](https://huggingface.co/Sanami/haas-ja-onnx/tree/354baedfd9612b00e74cc1ae87dff7f2c558db6f) です。認識不能を特定の日本語文面との一致で判定しません。

`asr.failed.kind` は `engine_unavailable`（準備できないエンジン）、`audio_unreadable`（区間音声読取失敗）、`transcription_failed`（認識呼び出し失敗）のいずれかです。TIMEOUT の専用種別はありません。

選択された segmentation / ASR run の組で、`asr.completed` は `empty` を含めその区間の終端です。同じ区間の成功結果が重複すれば整合性エラーです。`asr.failed` は診断記録で完了ではなく、prepare・音声読取・認識の最初の失敗で試行を止め、その区間と後続を pending のまま残します。次に開いたときは、未完了区間だけを古い順に処理します。

これらも現行 schema 4 のイベントであり、schema 4 以外の reader はありません。`segmentation.progress.consumed_frames` は無音を含む実際に VAD が消費した frame 数（読取・buffer 済み数や最後の speech 位置ではない）で、入力が未 seal の間は 4096 frame 境界で進みます。今回出力した全 segment の `segment.created` が durable になった後だけ progress を保存します。

`segmentation.input.sealed.frame_count` は EOF の正確な最終 frame 数を単一の EOF flush 前に保存します。`segmentation.completed` は EOF までの正確な `consumed_frames` と、全 `segment.created` を保存した後の `segment_count` を記録します。`ProcessingLogState` は現在世代の segmentation・ASR event を復元し、入力が seal された後の完了検証では seal frame 数と保存 checkpoint の frame 数を照合します。

未完了 run の `VADSession.open` は reader を sample 0 から replay し、segment prefix を ordinal・ID・全 speech ranges で照合します。一致した prefix は再保存せず、owner は新しい tail の `segment.created` を返す前に保存するため、別の segment-writing path で再登録しません。mismatch・EOF で不足する prefix・frame count 不一致は `SegmentationConsistencyError` を投げ、error 後は reopen が必要です。並行操作は拒否します。

完了済み segmentation は processor factory と VAD を使わず、復元済み segment は `segments` から参照できます。`processAvailable` は 4096 sample 未満の端数を保持し、polling / pause では flush せず EOF `finish` でだけ flush します。VAD / Core ML / assembler の状態は保存せず、progress は restart seek point ではありません。実装: [VADSession.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/VADSession.swift)、[ProcessingLogState.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingLogState.swift)、[SegmentationEvents.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SegmentationEvents.swift)。

現在世代の open な段階でも、保存済み `segment.created` と `asr.completed` から得られる部分行を投影します。新しい `pipeline.started` で現在世代を reset すると、以前の世代の行は選択されず、現在表示は空から始まります。空本文を含む全区間は event log に残ります。

`processing.run.completed` の count は段階ごとの処理対象件数です。segmentation / ASR は区間、clauseBoundary は判定が成立した区間と保留の区間、contentPriority は可視本文のある発話文の成立数と保留数を数えます。現在世代のローカル完了には segmentation・ASR 両 run の成功と正確な count を要求し、全 segment の ASR 成功と seal frame 数の一致も検証します。通常の decision run は判定保留があっても `succeeded: true` を出し、`failed_count` に保留数を保存します。これはローカル必須処理の失敗を意味しません。再試行 run の実際の失敗は `succeeded: false` です（再試行 run の終了・count 規則は下記）。保存破損や参照の不整合は保留に変換せず、エラーにします。

検証済み VAD が0区間の現在世代では segmentation と ASR の run を開始し、両方の `processing.run.completed` は `succeeded: true`、`completed_count: 0`、`failed_count: 0` です。対象がないため `segment.created`、`asr.pending`、ASR 結果イベントは作りません。ASR の prepare・推論と発話文判定は行わず、保存音声も変更しません。空の transcript を投影し、decision 対象がないため判定 event・pending はありません。選択 run ID は generation event log にあり、metadata には保存しません。再処理では新しい世代を開始し、前世代の結果は論理的に選択対象外になります。

根拠: [ActiveRuns.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ActiveRuns.swift)、[ASREventPayloads.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREventPayloads.swift)、[SegmentEvents.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SegmentEvents.swift)、[PipelineCoordinator.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/PipelineCoordinator.swift)、[TranscriptTypes.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/TranscriptTypes.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)、[LiveASRSession.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/LiveASRSession.swift)。

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
| `filler_ranges` | `{start,end}` object 配列 | 必須。原文 ASR text の UTF-16 座標で表す、表示本文から除去する F（フィラー）・B（相づち）の範囲。該当なしも `[]` を保存し、token 確率・token label・投影済み本文は保存しない |
| `request` | object または null | `assessed` は成功した判定呼出しの記録を持つ（候補なしの終端区間も F・B除去範囲の判定のため呼び出す）。`carried_over` は判定呼出しを行わず null |
| `source_decision` | object | `{"kind":"assessed"}` または `{"kind":"carried_over","source_boundary_run_id":…,"source_event_seq":…}` |

`filler_ranges` の各範囲は原文 ASR text の UTF-16 code unit 半開区間で、`start < end`、原文内 bounds、両端 Character 境界を満たします。配列は原文順でソートされ、範囲間に重なりや隣接はありません（連続して除去する Character は一つの範囲にまとめ、各範囲の `end` は次の `start` より小さくなります）。値の形は `[ {"start":0,"end":2} ]`、該当なしは `[]` です。O=0、F=1、D=2、B=3 の4 label を token ごとに argmax し、同率では低い index を選びます。各 Unicode scalar の label が F または B で、Swift Character を構成する全 scalar が F/B の場合は、その Character 全体を除去します。F と B が混在する Character も除去し、いずれかの scalar が O または D なら Character 全体を保持します。境界 assessment は `source_decision.kind` が `assessed` の場合に成功呼出しの `request` を必須とし、`carried_over` の場合は呼出しを行わず `request: null` とします。通常の pipeline 処理で未判定・初期化失敗・呼出し失敗となった区間は assessment でなく `clause_boundaries.pending` に記録し、架空の確率や F・B除去範囲を入れません。明示的な判定再試行における新規呼出し失敗は処理を失敗させ、置換 event を追記しません。`source_decision` は assessment 自身の判定を示す `assessed` または request を持たない `carried_over` だけです。引き継ぎは元イベントと同じ区間・候補・全確率・次区間先頭・F・B除去範囲であることを検証し、元の判定呼出しを再 request として扱いません。`filler_ranges` は decoder の必須キーで、欠落・型違い・不正範囲は読取エラーです。

| `reason` | 意味 |
| --- | --- |
| `initialization_failed` | モデルを初期化できなかった |
| `request_failed` | 判定呼出しが失敗した |

`clauses.closed` の payload:

```json
{"reference":{"boundary_run_id":"boundary_example","clause_id":"c12_0"},
 "parts":[{"source":{"segmentation_run_id":"seg_example","segment_id":"seg_000001","asr_run_id":"asr_example","asr_event_seq":12},"range":{"start":0,"end":3}},
          {"source":{"segmentation_run_id":"seg_example","segment_id":"seg_000002","asr_run_id":"asr_example","asr_event_seq":15},"range":{"start":0,"end":4}}],
 "termination":{"kind":"internal_boundary","source":{"segmentation_run_id":"seg_example","segment_id":"seg_000002","asr_run_id":"asr_example","asr_event_seq":15},"candidate_id":"b0001"}}
```

persisted `節` / `clause` はモデルが判定する BTSJ 発話文単位の識別名で、別 splitter の節を意味しません。両境界・継続確率は厳密に `> 0.5` の場合だけ採用します。候補 offset は原文 `、。？！?!` 直後の UTF-16 offset（原文末尾を除く）です。発話文 ID は `c<最初の part の asr_event_seq>_<開始 offset>` で、本文 hash や行内連番ではありません。parts は時間順で、二つ目以降は区間先頭から始まります。`termination.kind` は `internal_boundary`（採用候補）、`not_continued`（継続 no）、`stream_end`（録音停止・最後の区間・空の次区間。文法的な境界ではない）です。発話文本文は保存せず、原文とその区間の `clause_boundaries.assessed.filler_ranges`（保存済み F・B除去範囲）から導きます。

`clause_boundaries.assessed` と `content_priority.assigned` の `request` record は `request_id` と `input_tokens` だけを持ちます。境界では候補が空でも成功した判定呼出しに record を付け、優先度では一回の判定呼出しの全結果を一イベントに保存して record を一度だけ付けます。request record の decoder に default はなく、必須キーの欠落・型不一致・不正値は読み取りエラーです。読み取れない request record が `metadata` キーを持つ場合は、`input_tokens` 導入前の旧形式として「壊れています」ではなく旧形式のため確定できないことと、元の音声を読み込み直す対処を示すエラーにします。旧形式を変換して読む経路はありません。

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

`content_priority.assigned.request` は成功した結果だけに付けるため、呼出し失敗の保留も null です。carry-over と未判定 pending は呼出し自体がなく、利用計数にも加えません。carry-over は元 run・イベント・発話文が実在し、優先度と保留状態が一致することを検証します。引き継ぎ元と先の発話文は parts が同一で、各 boundary run の保存済み F・B除去範囲をそれぞれの ASR 原文に適用した UTF-8 bytes も一致する必要があり、どちらかが違えば読込を拒否します。保留のまま引き継いだ発話文は保留のままです。

初回の優先度判定と保留は原文順に最大40発話文ずつ `content_priority.assigned` に保存します。一回の `classifyPriorities` 呼出しで1〜40 sequence を処理し、失敗した batch は全対象を `request: null` の保留にします。未判定 batch にも同じ粒度を使います。明示的な判定再試行は、新たに要求した境界または優先度判定の実際の失敗で停止し、再試行で得た部分結果を選択しません。再試行 pair 全体の判定結果と完了成功を検証した後に `pipeline.decisions.replaced` を追記し、boundary と priority を一括選択します。`processing.run.completed` だけでは選択状態を変えません。判定失敗時は、失敗終了 cleanup の直前に task cancellation を一度だけ確認します。この確認で cancellation があれば、failed completion を書かず、durable outcome 前の一時停止として扱います。確認後に cleanup を開始したら、以後は cancellation を確認せず（writer 内を含む）、その再試行で開始した各 run に一度ずつ `succeeded: false` の `processing.run.completed` の保存を試みます。優先度判定失敗後に再構築済みの境界 run も対象です。全ての失敗完了保存が成功した場合は durable failed end とし、その `.failed` は後から届く cancellation や設定変更・shutdown でも held / cancelled に変わりません。起動時に自動再実行せず、公開済み pending の再試行は利用者の明示操作に限ります。`completed_count` は durable に完了・引き継がれた対象だけを数え、`failed_count` は durable な pending の対象（引き継がれた pending を含む）と、失敗した現在の判定 request の対象を数えます（優先度 inference batch の失敗では batch の全対象）。未実行の対象は数えません。失敗時は以前に選択された decision pair と公開済み pending を保持します。失敗完了の保存で実 I/O error が起きても各開始 run の保存を試み、キャンセルで抑制せず、元の判定エラーと全ての保存エラーを明示的に合わせて伝播します。いずれかの保存が失敗した場合、failed end の durability は保証しません。replacement event がない未完了 run は選択対象外で、復旧時は現在選択済み pair と pending から再構築します。`processing.run.completed` が `succeeded: false` で durable に保存された run は起動時復旧の対象にせず、公開済み pending の再試行は利用者の明示操作に限ります。

CancellationError または取り消し済み task を一時停止とするのは、durable outcome の前で、かつ失敗終了 cleanup 開始前に限ります。その場合は pending event や失敗 run completion を作らず、既に選択された pair を保持します。失敗 cleanup を開始する直前に cancellation を一度確認し、開始後は run completion の writer 内を含め再確認しません。`pipeline.decisions.replaced` が追記された後は、遅れて届く cancellation や設定・shutdown による pause があっても completed を維持し、held / cancelled に変更したり `resumeHeld` で再実行したりしません。`pipeline.decisions.replaced` の追記は writer が file lock の中で log を読み直し、generation と選択中 pair が事前検証時の pair と一致する場合だけ書きます。一致しなければ何も書かず `selectionConflict` で `.failed` になります。追記自体が error を返した場合は選択の成否が不明なので、cancellation の有無にかかわらず一時停止にせず、セッションを開き直すよう求める `selectionOutcomeUnknown` で `.failed` になります。失敗終了 cleanup で全ての `succeeded: false` completion が durable に保存された場合も `.failed` を維持し、遅れて届く cancellation や設定変更・shutdown で held / cancelled に変更しません。一方、`succeeded: true` の run completion があっても replacement event 追記前なら未選択であり、選択済み pair と pending から再開します。起動時の判定復旧は replacement event のない未選択 retry pair を対象とし、選択済み pair と pending から再構築します。未選択 run の部分結果は使いません。durable failed end の run は復旧対象にせず、公開済み pending の再試行は利用者の明示操作に限ります。判定呼出しのない carry-over event は batch 上限に含めません。

根拠: [ClauseRecords.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseRecords.swift)、[ClauseBoundaryAssembly.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseBoundaryAssembly.swift)、[共通の直列 batch](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClausePriorityBatches.swift)、[DecisionRunProvenance.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionRunProvenance.swift)、[JSON 形状のテスト](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/BoundaryAssessmentTests.swift)、[優先度 batch の保存](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/PriorityBatchPersistenceTests.swift)。

### run の来歴

`processing.run.started.payload.provenance` の全フィールドは次のとおりです。

| キー | 型 | 意味 |
| --- | --- | --- |
| `engine` | String | 実装・エンジンの名前 |
| `model` | optional String | モデル ID。モデルを使わない段階では省略 |
| `version` | String | 実装または依存 package の version / revision |
| `configuration` | String → String の object | その run の設定。数値も文字列で保存 |

判定 run は開始時に読み込んだモデル、または読み込めなかったことの provenance を `processing.run.started` に保存します。run の `configuration` は全て string 値です。境界判定の `span_policy` は、F・B除去範囲の投影方針を識別します。

| 段階 | engine / model / version | configuration |
| --- | --- | --- |
| segmentation（Mac） | `fluidaudio-silero-vad` / FluidAudio の Repo.vad.rawValue / `FluidAudio@0.15.8` | `pre_roll_seconds` = `0.1`、`max_speech_range_seconds` = `14.0`、`max_segment_span_seconds` = `30.0`、`min_silence_seconds` = `0.75`、`vad_threshold` = `0.5`、`split_search_window_seconds` = `2.0`、`split_energy_frame_seconds` = `0.02`、`minimum_independent_speech_range_seconds` = `0.5` |
| segmentation（Linux / Windows） | `onnxruntime-silero-vad` / 固定 model のファイル名 `silero_vad_16k_op15.onnx` / `silero-vad@5cd7945676eb32225748052e2e6a0580e4686a08+onnxruntime@1.31.0` | Mac の segmentation と同じ8キーに、portable 固有の7キー（`negative_vad_threshold` = `0.35`、`chunk_samples` = `4096`、`frame_samples` = `512`、`frame_aggregation` = `noisy-or`、`model_sha256` = 固定 model の SHA-256、`intra_op_threads`、`graph_optimization_level` = `ORT_ENABLE_ALL`）を加える。詳細は [windows.md](windows.md#silero-vad-の区間検出) |
| asr（Mac） | `onnxruntime-haas-tdt` / [Sanami/haas-ja-onnx/int8dyn](https://huggingface.co/Sanami/haas-ja-onnx/tree/354baedfd9612b00e74cc1ae87dff7f2c558db6f) / `haas-ja-v1.0@354baedfd9612b00e74cc1ae87dff7f2c558db6f+onnxruntime@1.31.0` | `language=ja`、`decoding=tdt-greedy`、`max_symbols_per_frame=10`、`intra_op_threads=4`、`minimum_input_seconds=0.02`、`maximum_input_seconds=30.0` |
| asr（Linux / Windows） | `onnxruntime-qwen3-asr` / `${size.repository}@${size.commit}`（選択サイズごとに固定） / `onnxruntime-<runtimeVersion>`（現在 `1.31.0`） | `language=ja`、`minimum_input_seconds=0.02`、`quantization=int4`、`mel_variant=whisper-slaney-128-nfft400-hop160-reflect-global-log10`、`max_new_tokens=448`、`no_repeat_ngram=3 when input_seconds > 15; disabled otherwise`、`intra_op_threads=指定値 N`、`inter_op_threads=1`、`cpu_memory_arena=false`、`graph_optimization_level=ORT_ENABLE_ALL` |
| clauseBoundary | `coreml-clause-tagger`（Mac）または `onnx-clause-tagger`（Linux / Windows）/ 外部 model ID Pokojaka/modernbert-ja-30m-utterance-tagger / version = model の64桁 state-hash revision | `model_id` と `model_revision` は実際にロードした identity、`unit_policy=btsj-utterance-sentence`、`candidate_characters=、。？！?!`、`boundary_threshold=0.5`、`continuation_threshold=0.5`（いずれも厳密な `>` 判定）、`next_head_character_limit=60`、`window_content_tokens=190`、`window_policy=whole-piece-max-min-context`、`span_policy=argmax-o-f-d-b-remove-f-b`、`span_window_policy=whole-piece-max-min-context`、`encoding_revision=1`、`max_tokens=192`、`compute_units=cpu-only`、`text_policy=neutral-punctuation-piecewise` |
| contentPriority | `coreml-clause-tagger`（Mac）または `onnx-clause-tagger`（Linux / Windows）/ 外部 model ID Pokojaka/modernbert-ja-30m-utterance-tagger / version = model の64桁 state-hash revision | 実際の `model_id` / `model_revision`、`unit_policy=btsj-utterance-sentence`、`minimum_demotion_confidence=0.9`、`maximum_targets=40`、`encoding_revision=1`、`max_tokens=192`、`compute_units=cpu-only`、`text_policy=filler-backchannel-removed-neutral-punctuation-piecewise` |
| decision unavailable | `unavailable` / `model=nil` / version `1` | `unit_policy=btsj-utterance-sentence` |

判定 run の `model`、configuration の `model_id` / `model_revision`、`version` は実際にロードした外部 model ID と state-hash revision です。`unavailable` は tagger を読み込めなかった provenance です。成功 request record はモデルを記録せず、その run の provenance が request を処理したモデルを示します。

保存済み transcript の読込・materialization は選択済み run と event を使い、現在の `model_id` とは照合しません。同一 generation 内の判定再試行で成功済み判定を引き継ぐ場合は、元・再試行側の保存済み `filler_ranges` を適用した本文の UTF-8 bytes まで照合し、parts の一致だけでは引き継ぎません。

segmentation・ASR の `processing.run.started` provenance は `pipeline.started` に保存した値と一致しなければなりません。各段階は開いたまま進捗・部分結果を保存し、入力 seal 後に全区間の成功結果と正確な count を検証して完了します。CLI の `ContentPriorityAccess.disabled` は任意の decision run を行わず、generation の初期 `runs` では両 decision ID を省略します。

根拠: [RunProvenance.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/RunProvenance.swift)、[FinalTranscriptPipeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift)、[FluidFinalTranscriptVADSegmenter.swift](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/FluidFinalTranscriptVADSegmenter.swift)、[SileroFinalTranscriptVADSegmenter.swift](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/SileroFinalTranscriptVADSegmenter.swift)、[HaasASREngine.swift](../app/MacAmbientJev/Sources/MacAmbientJevHaasASR/HaasASREngine.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)。

ローカル判定と固定 model path の実装: [AppPaths.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AppPaths.swift)、[LocalClauseTagger.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/LocalClauseTagger.swift)、[ClauseTaggerModel.swift](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/ClauseTaggerModel.swift)、[ClauseTaggerTokenizer.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerTokenizer.swift)、[ClauseTaggerEncoding.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerEncoding.swift)。

## processing_metadata.json

`ProcessingMetadataStore` が明示した CodingKey の JSON を atomic write します。キーは `schema_version`、`generation_id`、`state`、optional `failure_reason` だけで、`schema_version` はイベントログと同じ `4` です。欠落・未対応 version は直ちに拒否し、明示的な再処理でも置換しません。

| キー | 型 | 意味 |
| --- | --- | --- |
| `schema_version` | Int | 必須。値は `4` だけ |
| `generation_id` | UUID | 必須。状態が属する pipeline generation |
| `state` | String | 必須。`running` / `paused` / `failed` / `complete` |
| `failure_reason` | optional String | 失敗・一時停止の理由。nil は省略 |

状態ファイルは表示・復旧用の status だけで、generation event log が現在の run と結果を決めます。metadata の `generation_id` が最新の `pipeline.started` の `id` と一致しない場合、その status は stale として無視します。新 generation marker は前世代を論理的に reset し、以前の event を移行・再選択しません。


新しい処理は `pipeline.started` で generation と run ID 群を開始し、metadata に同じ `generation_id` の `running` status を保存します。開いている段階の部分結果は最新世代から投影し、新 generation 開始時は前世代の行を選ばず空から始めます。ローカル必須段階は seal 済みの音声 frame 数に対して segmentation・ASR の全 segment 成功と正確な count を検証して完了します。初期 payload の decision IDs は両方存在するか両方省略し、対象がある場合に判定を実行します。decision pending を含む成功結果も選択できます。CLI の `ContentPriorityAccess.disabled` は両 decision ID を省略し、任意の判定を実行しません。metadata の `paused` / `failed` status は選択済み event を置き換えません。

起動復旧は最新 generation の `pipeline.started`、その run 完了 event と一致する metadata status を基にします。`running` / `paused` は同世代の未完了処理を続け、`complete` は封印 frame 数・全ローカル結果・count を再検証してから pending または未公開 decision retry を扱います。`failed` は自動再実行しません。decision retry の未選択 run は部分結果を投影せず、公開済み pair から再構築します。generation ID が異なる古い status は無視します。metadata が読めない場合は自動復旧で理由を報告し、明示的な再処理でも未対応 schema version は置換しません。

根拠: [ProcessingMetadata.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingMetadata.swift)、[ActiveRuns.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ActiveRuns.swift)、[SessionRecoveryScanner.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecoveryScanner.swift)、[NativeSessionProcessor.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/NativeSessionProcessor.swift)。

## checkpoint と PCM タイムライン

### checkpoint.json

`AudioCheckpoint` をキー変換なしで保存します。以下はすべて必須で、空の配列も省略しません。

| キー | 型 | 意味 |
| --- | --- | --- |
| `committedFrames` | Int64 | 完全に公開された音声のフレーム数 |
| `sampleRate` | Double | `16000` |
| `channelCount` | Int | `1` |
| `sampleFormat` | String | `float32LE` |
| `chunkFiles` | String 配列 | タイムライン順の chunk basename。重複・空・`.`・`..`・Windows 禁止文字や制御文字・末尾のドット/空白・予約名は不正 |
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

`ProcessingTimeline` の型は `version`（1）、`sampleRate`、`channelCount`、`sampleFormat` を持ち、frame からミリ秒への変換を定義します。独立した timeline JSON ファイルは保存せず、永続音声の自己記述情報は、`recordingPCM` と import の処理タイムラインでは checkpoint に、`recordingFLAC` では `storage.json` の `timeline` にあります。保存済みセッションとエンジン入力は非 canonical 形式を拒否します。表示時刻は frame × 1000 / 16000 の小数部を 0 方向に切り捨てます。イベントの source frame は保存タイムラインの座標であり、入力デバイスや original の frame 座標ではありません。VAD・ASR で再度 mono 化や SRC は行いません。

根拠: [DurableAudioWriter.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DurableAudioWriter.swift)、[ProcessingTimeline.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingTimeline.swift)、[ProcessingTimelineReader.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ProcessingTimelineReader.swift)、[AudioBlockRing.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioBlockRing.swift)、[LiveTranscriptionCadence.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/LiveTranscriptionCadence.swift)、[ASR.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ASR.swift)。

## 読取・復旧と公開ビュー

イベント JSONL では、末尾の LF 未終端かつ不正な JSON 行だけを復旧時に無視・切り詰められます。途中の不正行、LF 終端の不正行は破損として扱います。完全な JSON の最終行に LF がない場合、SessionWriter は LF を足して保持します。イベント番号がある行では正の整数であることを検証します。

イベント header の `event_seq` は正の整数で、ログ順に厳密に増加します。重複・逆転は reader と既存ログへの append の両方で拒否し、破損した番号を並べ替えて補正しません。

保存済みセッション一覧は `pipeline.started` がある場合、イベントログを変更せずに読み込み、最新世代の選択 run と transcript event payload を検証します。ログが欠損・不正、または不完全な末尾を含む場合は派生結果を破損として表示し、公開 transcript を持たない扱いにします。generation のない未処理セッションではログを要求しません。

読取は `SessionWriter.readDurableLog` で append と同じファイルロックを取り、synchronize 済みのログを読みます。最新 `pipeline.started` が現在 generation を定め、それ以前の generation payload は論理的に選択対象外です。reader・再試行・catalog は現在の選択 run と参照先の source／carry 元を厳密に解釈し、carry 元も再帰的に境界組み立てと優先度整合を検証します。

`EventLogTranscriptReader` は全行の header（`schema_version` を含む）を読み、必要な既知イベントの run ID を要求します。非選択 run や未知イベントの payload は解釈せず、選択 run の必要フィールド欠落・型違いはエラーです。ASR outcome と text の不一致もエラーです。発話文判定イベントは reader、再試行分析（`DecisionRetryAnalyzer`）、同世代の carry-over、保存済み一覧が共通 decoder で検証します。保存済み境界判定から発話文を再組み立てし、保存結果と比較します。完了 run は全ての非空区間を覆い、組み立て結果と完全一致しなければなりません。open な現在世代は組み立て済み部分結果を読めます。候補・次区間先頭・範囲・参照・引き継ぎ元の不一致はエラーです。読み取り・検証で判定を再実行しません。

`EventLogTranscriptReader` は header・ローカル transcript の decoding を担当し、発話文イベントの共有解析・source/carry 検証・組み立て replay は [ClauseEventLog.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseEventLog.swift) にあります。公開済み run の完了・pending 整合は [PublishedTranscriptValidation.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/PublishedTranscriptValidation.swift)、再試行対象の検証と計数は [DecisionRetryAnalyzer.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/DecisionRetryAnalyzer.swift) が担当します。reader・再試行・catalog・同世代 carry-over は同じ `ClauseEventLog` を使い、独立した発話文 decoder を持ちません。

[DecisionSessionRecovery](../app/MacAmbientJev/Sources/MacAmbientJevCore/EventLogTranscriptReader.swift) は、明示された segmentation / ASR / boundary / priority run ID を durable JSONL に照合し、共通 `ClauseEventLog` replay から有効な durable prefix、処理済み入力、未完了 parts、未記録の `clauses.closed` record の決定的な末尾分、および未割当の非空 clause を返します。保存済み outcome（pending を含む）は再 request しません。`LiveContentPrioritySession` actor は `open` 時に返された closure を永続化し、未割当の非空 clause だけを分類します。reader は replay と結果返却のみを担います。新しい event/schema を追加せず、公開 metadata や起動時 recovery の仕様も変えません。

`TranscriptMaterializer` が公開 run の区間・ASR・発話文境界・優先度を適用します。materialization はモデルを読み込み・実行せず、保存済み assessment の `filler_ranges`（F・B除去範囲）だけを原文へ投影します。assessment がない区間、境界 pending / failed、判定を無効にした CLI では F・B除去範囲を使わず原文を基にし、どの場合も表示本文の最終段階で数字表記変換を適用します。assessment がある区間は F・B除去範囲を適用した後、保存済み LOW の clause slice をさらに除去します。CLI の `segments.json` は配列で、各 object の全キーは次のとおりです。

| キー | 型 |
| --- | --- |
| `segment_id` | String |
| `source` | 区間参照 |
| `start_ms`, `end_ms` | Int64 |
| `text` | String。ASR 原文 |
| `display_text` | String。F・B除去範囲と保存済み LOW 発話文を適用し、最後に数字表記変換した表示本文 |
| `clause_state` | `awaiting_next_segment` / `boundary_pending` / `priority_pending` / `classified` |
| `clause_slices` | object 配列。各 object は `reference`: 節参照、`source_range`: 原文の範囲、`priority`: `primary` / `lowPriority` / null、`needs_retry`: Bool |

原文が空の区間は公開 JSON・ライブ表示・テキスト書き出しに出しません。イベントログからは削除しません。`segments.json.text` とイベント中の ASR 本文は原文のままで、Linux の CER 評価などはこの原文を読みます。`display_text` は画面と同じ表示本文で、判定結果がない場合も最終段階の数字表記変換を適用します。区間をまたぐ発話文の全 parts は各行に複製せず、`clause_slices` の発話文参照から `clauses.closed` を辿ります。全範囲の境界が未成立の行は `clause_slices` が空で `boundary_pending` です。部分的な未解決範囲がある行も `boundary_pending` ですが、独立して閉じた保存済み発話文の slice は保持します。フィラー・相槌だけの行や全 LOW の行で `display_text` が空になった行も、原文があれば JSON に残します。テキスト書き出し `transcript.txt` は画面と同じ発話と表示本文を使い、表示本文が空白・改行だけになる行は除外します。

根拠: [SessionRecovery.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionRecovery.swift)、[EventLogTranscriptReader.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/EventLogTranscriptReader.swift)、[Materialization.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/Materialization.swift)、[SessionExporter.swift](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionExporter.swift)、[ファイル処理 CLI](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)。
