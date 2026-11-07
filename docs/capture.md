# 録音キャプチャと入力音量

入力元は「マイク」と「システム音声」です。録音中は入力元を変更できません。アプリを開いただけではマイク録音を開始せず、利用者の録音開始操作で権限確認とキャプチャを行います。保存と[ライブ認識](live.md)は別状態で、認識の遅れや発熱によるライブ停止だけでは録音を止めません。

## 入力元と権限

### マイク

macOS の既定マイクを使います。権限がなければ開始しません。

> マイクへのアクセスが許可されていません。システム設定の「プライバシーとセキュリティ」→「マイク」で許可してください。

最初の音声バッファを 3 秒以内に受信できなければ開始失敗です。入力デバイス切断、AVCapture の動作エラー・中断、音声形式変更、音声バッファが 3 秒届かない状態では停止します。小さい声や無音のバッファが届くことと、入力バッファ自体が途絶えることは区別します。

### システム音声

Core Audio のグローバルタップで Mac の再生音声を取得し、マイクを使いません。出力デバイスを変更せず、再生音声をミュートしません。再生がない間の無音は正常です。入力音量の自動調整も行いません。

出力デバイスの切り替えではグローバルタップの録音を継続します。デバイスの sample clock が巻き戻る場合は、利用可能な host time の経過時間を使って保存フレーム位置をつなぎ、タイムラインの時刻を巻き戻しません。切り替え中に音声が欠けた時間は gap として無音で補います。タップの音声形式が変わる場合は「システム音声の形式が変わったため、録音を停止しました」と表示して保存・停止します。

権限が未許可なら macOS の確認応答を待ちます。この待機には、最初の音声バッファの 3 秒制限を適用しません。拒否、または権限状態を確認できない場合は開始しません。許可を設定しても開始できない場合はアプリを終了して開き直します。

> システム音声の録音が許可されていません。システム設定の「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」で許可してください。許可しても録音を開始できない場合は、アプリを終了して開き直してください。

> システム音声の権限を確認できません。このmacOSではシステム音声を録音できません

## 保存する音声と欠落

システム音声の IO コールバックは Core Audio の IO スレッドから直接呼び出します。通常の dispatch queue へ同期転送せず、音声形式変更の通知だけを専用 queue で受けます。通知は atomic flag で入力を無効化し、コールバックが所有するタイムスタンプや音声バッファには触れません。

キャプチャした全入力チャンネルをフレームごとに平均し、serialized drain で **16,000 Hz・mono・32-bit float PCM** に正規化して保存します。片側チャンネルだけを選ぶ方式ではありません。必要容量はこの実保存形式から計算します。import も全 channel を平均して同じ形式に正規化します。この PCM は録音中と確定処理が終わるまでの保存形式で、確定処理の後は 16 kHz・mono・16-bit の FLAC に変換して PCM を削除します（[保存形式](storage.md)）。

コールバックは保存待ちや ASR 待ちをせず、リングへ音声を渡します。リングは 512 フレーム単位の入力を基準に少なくとも 10 秒分を保持する容量を確保します。処理速度不足でリングがあふれた場合、不正な入力バッファ、PTS の欠落、停止時の末尾欠落は gap として記録し、欠落区間を無音で補って時間軸を維持します。補った無音は実際に録音した発話として入力音量調整に使いません。欠落の可能性は保存後にも注意として表示します。

コールバックは device-rate の downmix・channel 別 metering・enqueue だけを行い、SRC は行いません。ring と PTS は device-frame 座標、durable gap・chunk・checkpoint・健全 prefix は canonical-frame 座標です。境界は累積 `round(sourceFrame × 16000 / deviceRate)`（ちょうど半分は 0 から遠い側）で写し、512-frame block ごとには丸めません。重複は source 座標で除き、欠落は source 座標で一度だけ無音補填して同じ converter を通します。filter state は block 間で維持し、通常 priming と一度だけの EOS flush を使います。録音全体の canonical 長は AVAudioConverter が filter phase で決める終端で、正確な長さ `sourceFrames × 16000 / deviceRate` の floor か ceil です。block の分け方には依存しません。この範囲外なら変換失敗として停止し、出力を足したり捨てたりしません。gap は実際に公開した範囲へ切り詰めます。

writer append が途中で失敗しても、消費済み converter input は再投入しません。未受理の canonical output を保持し、writer checkpoint で受理済み prefix を照合して残りだけを再送します。drain・snapshot・finish は writer await を跨いで一つの FIFO lane に直列化します。device-format metering と入力形式変更の検出は正規化前の形式を使います。

有効な音声を得られず開始に失敗した空セッションは削除します。保存音声があるセッションや保存状態が破損しているセッションは保持します。空セッションの削除が失敗した場合は、開始失敗の原因と削除失敗を併記します。

## スリープ防止の範囲

録音中は IOKit の user-idle system sleep 防止 assertion と、`ProcessInfo` の activity（userInitiated、idleSystemSleepDisabled、latencyCritical）を保持します。自動的なシステムスリープと App Nap による録音中断を抑えるためのもので、ディスプレイの消灯は妨げません。

Mac の蓋を閉じる操作や利用者が明示的に選ぶスリープは防げません。録音中は蓋を閉じず、スリープ操作を避けてください。停止時、開始の後片付け時、アプリ終了時には assertion と activity を解放します。IOKit assertion の取得が失敗した場合も activity は保持し、警告を出して録音を続けます。

## 空き容量ポリシー

開始時の必要量は、保存する 16 kHz mono float32 に対する次の式です。入力の sample rate・channel 数には依存しません。

```text
ceil(16000 × 1 × 4 bytes × 90 × 60 seconds) + 256,000,000 = 601,600,000 bytes
```

601,600,000 bytes が必要です。これは 90 分分の PCM と余裕の予約基準であり、90 分で録音を必ず終了する制限ではありません。

- 取得した空き容量が必要量未満なら開始を拒否します。必要量と同じなら開始できます。
- 空き容量取得の例外、またはボリュームが容量を報告しない場合も開始を拒否します。容量不明のまま警告だけで開始しません。
- 録音中は 30 秒ごとに確認し、128,000,000 bytes **未満**なら録音を停止して保存します。
- 録音中の取得失敗は「録音中の空き容量を確認できませんでした」と注意を出し、その時点では録音を継続します。開始前の拒否とは異なります。

実際の開始拒否は「90分の録音に必要な空き容量がありません（必要: … MB）」または「空き容量を確認できないため録音を開始できません: …」です。空き容量不足で停止する表示は「空き容量が不足しています。録音を停止して保存しました」です。

## マイク入力音量の自動調整

設定の「マイクの入力音量を自動調整する」は初期状態でオンです。録音開始前に決め、録音中には切り替えられません。対象は macOS のシステム入力音量で、同じマイクを使う他のアプリにも反映されます。保存音声へのデジタルゲインではありません。システム音声、ファイル読み込み、保存済みセッションの再処理は入力音量に触れません。

VAD が発話と判定した区間の音量を、小さい声に対する調整の根拠にします。発話判定のない音が小さくても上げません。音割れは入力チャンネルごとのピーク・クリップ率から監視し、発話検出が止まってもこの監視は続けます。

| 根拠 | 調整 |
| --- | --- |
| 小さい声が継続 | 0.05 ずつ上げる。最短 5 秒間隔 |
| 大きい声が継続 | 0.05 ずつ下げる。最短 2 秒間隔 |
| クリップ | 0.10 ずつ下げる。最短 0.5 秒間隔 |

調整後は 1.5 秒の安定待ちを入れます。調整できない機器、自動調整オフ、すでに最大音量でも小さい声・音割れの注意は表示します。目的は入力レベルの調整であり、ASR の精度向上を保証するものではありません。

### 手動変更・デバイス変更・復元

停止時の復元は、アプリが変更し、現在値もアプリの最後の変更値と一致する音量要素だけが対象です。手動で変更された値を上書きしません。変更完了を確認できない要素は復元しません。読み取り・書き込みと他アプリの操作は不可分な一操作ではありません。

録音中に手動の入力設定変更を検知すると、その録音の自動調整を停止します。既定入力デバイスが変わった場合は全音量要素の ownership を放棄し、停止時も旧マイク・新マイクのどちらにも復元の書き込みをしません。次の録音まで自動調整を再開しません。

アプリ終了・強制終了・クラッシュでは、入力音量を元に戻しません。必要ならシステム設定の「サウンド」で確認します。調整失敗・復元失敗の赤いエラーは停止後も次の録音を始めるまで残ります。

## 注意とエラーの表示

発話音量の監視不能、声の小ささ／音割れの注意、自動調整の状態は独立した表示です。監視不能と音量注意を同時に表示できます。30 秒続く無音の注意も別です。

| 状態 | 表示文言 | 扱い |
| --- | --- | --- |
| 入力音量を変更できない機器 | このマイクは入力音量を変更できないため、自動調整を使えません。 | 橙色の非致命な注意。録音継続 |
| 手動設定変更 | 入力設定が変更されたため、この録音では自動調整を止めています。 | 橙色の注意 |
| 既定入力デバイス変更 | 既定の入力デバイスが変わったため、この録音では自動調整を止めています。録音前の入力音量には戻しません。 | 橙色の注意 |
| 小さい声 | 声が小さく録音されています。マイクに近づくか、入力音量を確認してください。 | 橙色の注意 |
| 音割れ | 音が大きすぎて、声がひずんでいます。マイクから少し離れるか、入力音量を下げてください。 | 橙色の注意 |
| VAD 監視不能 | 発話検出が使えないため、声の大きさを確認できません。マイクの位置と入力音量を確認してください。 | 橙色の注意 |
| マイクの無音 | マイク入力が30秒以上無音です。ミュート設定を確認してください | 橙色の注意 |
| システム音声の無音 | システム音声が30秒以上無音です | 橙色の注意 |

入力音量への書込失敗は「入力音量を自動調整できませんでした（…）。この録音では自動調整を止めています。」、復元失敗は「入力音量を元に戻せませんでした（…）。システム設定の「サウンド」で入力音量を確認してください。」という赤いエラーです。括弧内には「マイクが変更を受け付けませんでした」「変更が完了したか確認できませんでした」など、実際の原因を表示します。

キャプチャ障害の文言は入力元に合わせます。

| 原因 | 表示文言 |
| --- | --- |
| マイクで最初の音声がない | マイクから音声が届きませんでした。入力デバイスとマイク権限を確認してください |
| システム音声で最初の音声がない | システム音声が届きませんでした。再生中の音声とシステムオーディオ録音の権限を確認してください |
| マイクの入力停止 | マイクから音声が届かなくなりました。録音を停止しました |
| システム音声の入力停止 | システム音声が届かなくなりました。録音を停止しました |
| マイク切断 | マイクが切断されました。録音を停止しました |
| マイク動作エラー | マイクの動作エラーが発生しました。録音を停止しました |
| マイク入力中断 | マイク入力が中断されました。録音を停止しました |

Bluetooth マイクの入力が 24 kHz 以下なら「Bluetoothマイクは音質が低下します」と注意を出します。スリープ防止のシステム assertion が取得できない場合は「スリープ防止を設定できませんでした。録音中はスリープを避けてください」と注意を出し、録音を継続します。

## 保存障害と健全範囲の確定処理

保存エラーは「録音の保存に失敗しました: …」に原因を続けます。原因には「保存済み音声の断片 … が壊れています」「保存済み音声の長さが索引と一致しません」「空き容量が不足したため … を書き込めませんでした」などがあり、実際の chunk や索引のファイル名を保持します。

writer 障害時は録音を停止し、赤い障害表示を維持しながらライブ ASR を取り消します。最終 flush が成功すればその checkpoint、flush が失敗すれば writer がすでに公開した chunk までを健全な保存範囲として[共通確定処理](final.md)に送ります。健全範囲に実際に取得した音声がなければ、確定処理へ進めずエラーになります。欠落を埋めた無音だけは取得音声とは扱いません。

システム音声タップの停止では、各資源の解放をすべて試み、失敗した操作名を付けて「システム音声の取得資源を解放できませんでした（…）。アプリを終了して開き直してください」というエラーを返します。開始失敗に伴う解放失敗は元のエラーと併記します。録音保存が成功し、解放だけが失敗した通常停止では、音声を保持し警告として表示します。writer 障害や入力障害による自動停止では元の障害表示を維持し、停止時に発生した別の解放・停止エラーも赤い表示に併記します。同じ原因が重複して返された場合は一度だけ表示します。

## Windows のキャプチャ

Windows では miniaudio の WASAPI 共有モードでマイク（`ma_device_type_capture`）またはシステム音声（`ma_device_type_loopback`、再生エンドポイント）を取得します。両方に `performanceProfile = ma_performance_profile_conservative`、`periodSizeInMilliseconds = 100`、`periods = 3`、`wasapi.usage = ma_wasapi_usage_pro_audio` を要求し、MMCSS task profile に `Pro Audio` を指定します。入力 ring は10秒以上の音声を保持します。period は backend への要求 / hint で、実際の period や frame 数を保証しません。排他モード・他 backend・形式の代替経路はありません。同時に録音する入力元は一つです。入力デバイスは「既定」または列挙した endpoint ID で選びます。microphone の「既定」は開始時に解決した endpoint ID に pin し、明示した microphone と loopback は同じ ID だけを再 open します。loopback の「既定」だけは新しい default output を追います。endpoint 一覧は `WindowsWASAPICaptureFactory.devices(source:)` が返します（`devices.list` 用）。詳細は [Windows の engine capture 規則](windows.md)を参照してください。

device-loss の再接続は injected clock と device factory を使う明示的な `capturing` → `waiting` → `capturing` / `stopped` state machine が担います。native device loss だけが初回の固定30秒待機を開始します。待機中は native operational open / start error（vendored miniaudio 0.11.23 の `MA_NO_DEVICE`、`MA_UNAVAILABLE`、`MA_FAILED_TO_OPEN_BACKEND_DEVICE = -401` を含む）と、各候補の first buffer 前の worker / active-output stall、suspended、native failure を fence して破棄し、元の deadline まで0.25秒間隔で再試行します。再度の loss や endpoint unavailable で deadline は延長しません。この待機中だけの retry は初回 start と通常の running failure を変えず、それらは fatal です。validation failure、unsafe cleanup、writer error も fatal で、任意の retry や fallback はしません。native worker は callback error で停止し、callback / native thread 内で device の停止・初期化・再接続は行いません。`WindowsCaptureSource` が同じ session / writer を保ったまま新しい segment / converter で再 open します。

30秒 deadline は injected `qpc100ns`（QueryPerformanceCounter）で測り、sleep / hibernate / connected standby 中の経過も含みます（Microsoft の [high-resolution timestamp guidance](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps)）。deadline は `min(observedLossQPC + 30 seconds, lastCapturedEndQPC + 30 seconds)` です。期限を過ぎた最初の control tick は device を enumerate / reopen せず停止へ進み、sleep が長くても数時間の gap は作りません。ただし deadline 前に有効な first-buffer evidence を受信済みなら、control tick が遅れてもその証拠を認めて復帰し、deadline 後の first packet は破棄します。成功した packet reconnect は、最後に captured した end から最初の復帰 packet の mapped PTS までを native open / start latency も含む単一の `missingCallback` interval として記録し、`audio_gap_count` を一度だけ増やします。timeout 時は missing tail を deadline で閉じます。

待機中は capture silence を生成せず、復帰待ち中は状態を `録音デバイスの復帰を待っています` と表示します。loopback reconnect preparation は actual packet または有効な idle-health buffer evidence まで writer への書き込みを保留します。idle candidate は待機が3秒以上でも古い waiting interval を captured silence に変えません。250 ms delivery grace を保ち、reopen 後に settled した idle frame だけを有効な silence として補い、通常の0.5秒 fill cap と3秒 active-output / stall safety を維持します。first valid buffer より前に active output から idle へ移って packet がない区間は、trustworthy idle fill まで単一の missing interval に留め、隣接する `invalidBuffer` gap や precondition failure を起こしません。device 復帰待ち以外の通常の idle loopback policy は変わりません。timeout は `waiting_for_device` から直接 `stopping` へ進み、録音を durable に停止して通常の finalization を enqueue した後、`device_lost` warning として `録音デバイスが30秒以内に復帰しなかったため録音を停止しました。録音は保存されています` を通知します。これは `recording` への一時遷移や process fatal error ではなく、engine は command 処理を続けます。

capture device の start 成功後、stream ごとに実際の capture stream 情報を stderr に1行だけ出力します。48 kHz・stereo の形式は `Windows capture stream (sampleRate: 48000, channels: 2, bufferFrames: N, periodFrames: M, mmcss: true)` です。sample rate・channel 数、WASAPI buffer frame 数 `N`、period frame 数 `M`、MMCSS の状態は、要求した hint ではなく実際の capture 情報を使います。buffer frame 数の query に失敗した場合は開始を失敗させ、推定値で置き換えません。

**パケット hook。** 標準の miniaudio コールバックにはタイムスタンプがなく、WASAPI の GetBuffer はデバイス位置と QPC を捨てます。そこで同梱ヘッダーの `ma_device_read__wasapi` に、`MJA_WASAPI_PACKET_READ` が定義されている場合だけ元の読み取りループを置き換える 4 行の hook を加えています。hook は GetBuffer のパケットを、フレーム数・デバイス位置・QPC（100 ns 単位）・フラグとともに最大 512 フレームに分割して渡し、分割後も元パケットの位置と offset を保持します。成功した各 GetBuffer の直後に同じ100 ns単位の read QPC を取得し、全断片へ同じ値を渡します。ingress は read QPC を診断値としてのみ扱い、packet QPC より前でも拒否しません。`readLagMs` は符号付きで計算し、負値もそのまま報告します。read QPC が最初の断片から変わる場合は `.invalidPacket` で停止します。この経路が取得モードの唯一の入力で、通常の data callback は何も処理しません。native PCM（u8 / s16 / s24 / s32 / f32）は有界な scratch で float32 に変換し、チャンネル数とソースレートは保持します。チャンネル平均は `TimestampedMonoSink`、SRC は `AudioCaptureDrain` で一度だけ行います。

**タイムスタンプ。** デバイスフレームを録音開始時の QPC epoch からの座標へ写します。ループバックでは、後述の符号付き clock offset に対して1 device period 未満の timestamp jitter を除き、`qpcDeltaFrames` が `deviceDeltaFrames` を許容（2 フレームまたは 2 ms の大きい方）を超えて上回る前進を、後述の現在の先行量または trailing idle silence の条件に従って再アンカーします。`DISCONTINUITY` がなくても、health が active でも、health 未受信でも同じです。受け入れ可否と、その前の未カバー区間を有効な無音にするか欠落にするかは別の判定です。初期アンカーとフラグ付き位置リセットでは、ホスト座標が `sink.lastEndFrame` より前に戻らない場合、または trailing idle silence 内で250 ms以内の再アンカー条件を満たす場合だけ受け入れ、一般的な先行量による重複の免除はしません。再起動・ジャンプ両方の逆行判定は `sink.lastEndFrame` を使います。後述の baseline 相対 jitter 条件を満たさず device delta が QPC delta を許容を超えて上回る不整合、QPC 逆行、フラグなしの非ループバックのジャンプ、`TIMESTAMP_ERROR`、その他の不正な位置リセット・フラグ／形式／NaN は、欠落時間を推測せず停止します。`SILENT` パケットは有効な無音（`sink.silence`）です。ゼロ値が連続する通常パケットも有効な音声として扱います。`SILENT` でも既知欠落でもない実 PCM の各パケット／断片は、実 PCM の値がすべてゼロでも、再アンカー後の開始座標が `sink.lastEndFrame` より前なら `.timestamp` で停止します。実 PCM を切り捨てて合成無音や gap に置き換えません。

**ループバックの無音。** ループバックは再生がない間パケットを返さないことがあり、デバイス位置は届けたフレームだけを数える場合と、無再生中の経過も含めて進む場合があります。同じ native producer thread で、利用可能なパケットを全て読んだ後に健全性を通知します。外部再生（エンジンとその子孫を除くセッションのプロセス）がないと明示的に観測されている間は、watermark を後述の drift 変換で device timeline へ変換してから250 ms引いた確定済み範囲を、1回あたり最大0.5秒の有効な無音として埋めます。この確定済み位置までの未カバー区間が 3 秒以上なら `.suspended` で停止します。active health は無音を補填せず、idle→active で active の無パケット timer をリセットします。再生中にパケットが 3 秒届かない場合、worker heartbeat が 3 秒途切れる場合、再生状態が不明な場合も停止します。既存の3秒 first-buffer safety も維持し、マイクのパケット途絶は共通の 3 秒 stall 判定に従います。

- **健全性補填と末尾 gap の 250 ms 猶予。** ループバックの健全性通知による無音補填と、再生終了時（出力状態 1→0）の末尾 gap（`activeTail`）は、watermark の host 位置を device timeline へ変換してから 250 ms 引いた位置までに限ります。変換は前進再アンカーと同じ drift 変換です。device clock drift による遅れだけを引き、idle silence への重複アンカーによる先行は drift の有無にかかわらず引かないため、遅れて届く packet に対する250 ms の猶予を保ちます。これは遅れて届く音声を決して先回りしない保証ではありません。実 PCM がすでに書き込まれた範囲へ後から重なった場合は、切り捨てず `.timestamp` で停止します。末尾 gap が 3 秒以上なら停止し、それより後ろは後続の idle 健全性通知で無音として補います。
- **初回の capture startup。** 新規録音では、native start の前に確定した epoch と最初の有効パケットの QPC の間を通常の無音で保存します。マイクとループバックの両方に適用し、開始時の約100–165 msなどの遅延は `missingCallback`、dropout、停止後の欠落警告を作りません。最初のパケットの到着と補填区間は既存の3秒 first-buffer deadline 未満に限り、補填だけで readiness を作りません。再接続 segment には適用せず、復帰待ちの未確認区間は欠落として保持します。
- **QPC jitter と符号付き clock offset。** producer は単一の符号付き浮動小数点値 `clockOffsetFrames` を保持し、`lag = hostFrame - mappedStartFrame`（正は遅れ、負は先行）を追跡します。device mapping を受理した native packet 全体につき一度、baseline より小さい lag へは直ちに下げ、lag に向けた増加は `devicePeriod × 200e-6`（200 ppm）以下に抑えます。`resetAnchor` は `hostFrame - frame` を設定し、負値も保持します。`DISCONTINUITY` のない連続したループバック packet（device delta が直前の native packet 全体の frame 数と一致）で `abs(qpcDeltaFrames - deviceDeltaFrames) > tolerance` の場合、`-tolerance <= lag - clockOffsetFrames < devicePeriod` なら device mapping を受け入れます。`tolerance` は2 frames または2 msの大きい方、`devicePeriod` は実際に完了した直前の native packet 全体の frame 数で、512-frame 断片ではありません。この jitter で再アンカー・追加無音・counted gap は作らず、全 PCM と raw QPC を保持します。範囲外や `DISCONTINUITY` は前進・重複の規則に従い、許容以上の device 先行不整合や QPC 逆行は停止します。
- **現在の先行量と QPC 前進再アンカー。** 受理した各パケットの開始時点で正の先行量を 変換後の host 座標に対する `max(0, mappedStartFrame - timelineFrame)` に更新し、アンカー調整と device clock drift の累積を反映します。host 座標から device timeline への変換は `hostFrame - round(max(0, clockOffsetFrames + anchorShiftFrames))` で、丸めのちょうど半分は0から遠い側です。`anchorShiftFrames` は直近の再アンカーで目標より後ろの末尾へ進めた frame 数で、再アンカーごとに更新します。この和が device clock drift による遅れで、idle silence への重複アンカーによる先行は変換に含めず、先行量の重複許容で扱います。jitter を除く QPC 前進再アンカーは、ループバックの idle／active／health 未受信、およびフラグで許可された非ループバックの前進のすべてにこの変換を使います。ループバックで目標が `sink.lastEndFrame` より前でも、重複が直前の先行量と許容の合計以内なら末尾へ clamp します。末尾が PCM／欠落でも全 PCM と全断片を保持します。それを超える重複は次項の trailing idle silence 条件を満たす場合以外 `.timestamp` で停止します。先行量は通常の連続 PCM、初期アンカー、フラグ付き位置リセットの重複を一般的に免除しません。
- **無再生区間からの復帰と再アンカー。** idle 観測だけでは、通常経路や jitter 経路で受理した device mapping を raw host 座標へ再同期しません。device mapping を保ち、未カバーの idle device suffix は次項の latch に従って補います。初期アンカー・フラグ付き位置リセットは raw `hostFrame` を目標にします。これらと offset 変換した QPC 前進再アンカーの目標が、健全性通知で合成した連続した末尾の idle silence 内、かつ `sink.lastEndFrame` の250 ms以内なら、アンカーを末尾へ進めます。reset 後の offset は `hostFrame - frame` で、raw host なら0、末尾への clamp 後は負にもなります。直後の health が active でも、末尾に PCM／欠落を追加していなければこの根拠を保持します。全 PCM／断片を残し、後続の device-contiguous packet にも調整したアンカーを使い、raw QPC は変えません。この末尾無音の規則は250 ms超、idle silence より前、既存 PCM／欠落への重複を許可しません。
- **idle 観測の latch と未カバー区間。** producer 所有の `idleObservedSincePacket` は idle health を受けるたびに true になり、パケット全体が完全に受理されたときだけ消費します。再開後の最初のパケットより先に active health が届いても消えません。受け入れたパケットの mapped start が末尾より先にあり、この latch が true なら、`[sink.lastEndFrame, mappedStartFrame)` をパケットより先に有効な無音で埋めます。初期アンカー・位置リセット・QPC 前進再アンカーだけでなく、QPC と device の delta が許容内で一致し、通常の device mapping のまま復帰する場合にも適用します。`DISCONTINUITY`／`SILENT` の有無（flags 0／1／2／3）でこの判定は変えません。これは gap／dropout ではなく、既存の未カバー区間3秒未満の制限を適用し、3秒以上なら `.suspended` で停止します。latch が false の場合、再アンカーによる未カバー区間は明示的に `sink.missing` へ渡して `.invalidBuffer`、通常 mapping の未カバー区間は ring／drain の `missingCallback` として記録します。`SILENT` も通常の全ゼロ PCM も、パケット全体を受理すれば latch を消費し、その後の active 中の欠落を無音へ変更しません。active health しかない場合や health 未受信でもループバックの QPC 前進再アンカー自体は受け入れますが、欠けた時間を黙って失ったり、有効な無音と偽ったりしません。マイクの QPC 前進はフラグがなければ停止します。
- **timestamp failure の診断。** 最初に失敗したチェックの固定コードと診断の発生元を allocation-free な producer atomics に latch し、後続の失敗で置き換えません。パケット由来では `qpcDeltaFrames`、`deviceDeltaFrames`、`packetFlags`、`idleObserved` も保持します。delta は符号付き optional 値で、直前のパケットがない場合や invalid QPC などで算出できない値は不明のまま保持し、0 と捏造しません。文字列化は control lane で行い、パケット由来の source の停止理由は `(check: NAME, qpcDeltaFrames: N, deviceDeltaFrames: N, packetFlags: N, idleObserved: true)` の形です。delta が算出不能ならその値は `unavailable`、idle 観測がなければ `false` です。health 通知由来の timestamp failure は発生元を `origin: health` と明示し、無関係なパケットの delta と `packetFlags` は診断に含めません。チェック名は `idleAnchorOverlap`、`pcmOverlap`、`qpcRegression`、`clockMismatch`、`nativeTimestampError` などです。`TIMESTAMP_ERROR`、QPC 逆行、不正な位置リセット、baseline 相対 jitter 条件を満たさない device が QPC より先行する不整合、フラグなしの非ループバックのジャンプは fatal です。

- **counted ingress gap の診断。** 明示的な欠落と、通常の packet timeline が ring に残す暗黙の前進欠落は、1-frame の欠落も数え、producer が固定64件の SPSC queue に allocation-free な snapshot として記録します。check は `qpcForward`、`deviceReset`、`knownMissing`、`activeTail`、`packetTimeline`、`reconnectIdle` です。control lane が通常の source poll と native producer の停止 fence 後に取り出し、stderr に `Windows capture counted gap` として出力します。`startFrame`、`endFrame`、`frameCount` と delta は device-rate 座標で、`sampleRate` も出力します。`qpcDeltaFrames`、`deviceDeltaFrames` は算出不能なら `unavailable`、そのほか `packetFlags`、`idleObserved`、optional な符号付き `readLagMs = (readQPC - packetQPC) / 10000`（100-ns 値の差を安全に計算し、ミリ秒未満を0方向へ切り捨て。負値もそのまま報告）、`origin: packet`／`health` を含みます。不明な read lag は `unavailable` です。health 由来では `packetFlags` は `unavailable`、`readLagMs` は nil とし、直前のパケットのフラグや read lag を流用しません。queue が満杯なら snapshot は記録せず、producer の atomic counter で診断の drop 数を数えます。control lane は drain ごとに前回の drain 以降の drop 数を stderr の1行で報告して counter を reset します。診断 queue の overflow は gap の記録・適用や録音を止めません。これは timestamp failure 診断とは独立し、ring overflow や `stopTail` を含む全 dropout の内訳を列挙するものではありません。

Windows engine adapter の `didOverflow` は名前にかかわらず保存済みの全欠落を表し、checkpoint に `missingCallback`、`invalidBuffer`、`overflow`、`stopTail` のいずれかがあれば true です。停止後の警告もこの欠落情報に従い、通常の startup padding と idle silence だけなら警告しません。

**環境監視。** 専用スレッドが 100 ms ごとに、エンドポイントの有効性、既定デバイスの変更（default loopback を選んだ場合だけ。microphone の既定は開始時に pin した endpoint ID を使う）、ループバックでは外部再生の有無を観測します。デバイス列挙子はこのスレッドで一度だけ作って使い回し、COM も同じスレッドで一度だけ初期化します。ループバックの session manager／probe は、endpoint の GetState が `ACTIVE` を返した後、必要になった時点で遅延作成します。非 active 状態または GetState 失敗では probe を破棄し、後続の明示的な poll があれば新しい probe を作ります。監視 worker は error で停止・報告し、自身で再接続・再試行はしません。worker が停止したことと capture source の reconnect 判断は別であり、`waiting_for_device` 中に first buffer 前の候補で native / worker failure が起きれば前項の待機候補 policy で破棄・再試行し、通常の running segment で起きた capture failure は fatal として伝播します。GetSessionEnumerator など未分類の失敗も監視 worker 自身では再試行せず、running segment では fatal として扱います。プロセスツリーはアクティブなセッションの PID 集合が変わったときだけ作り直します（生存中の PID の親子関係は変わりません）。値は SRWLOCK で守り、読み取り側は一貫した 4 つ組（観測開始 QPC、完了 QPC、出力状態、エラー）を得ます。「書き込み中」エラーはありません。生存確認は完了 QPC から 1 秒（10 周期）で、遅くても完了する監視は異常ではありません。外部セッションの PID は次の規則で決めます。

- 先にアクティブなセッションを列挙し、その後でプロセスを snapshot します。セッションの PID が snapshot に無ければ、列挙後に終了したプロセスであり、自プロセスにも子孫にもなり得ないので読み飛ばします。自プロセスが snapshot に無い場合だけ不整合として停止します。
- 複数プロセスにまたがるセッション（`AUDCLNT_S_NO_SINGLE_PROCESS`）は自プロセスだけのものではないため、致命にせず、システム音声と同じ PID 0 の外部セッションとして扱います。自プロセスの音声を外部と誤認しても、ループバックはその音声も取得するためパケットが届き、害はありません。逆に外部再生を見落とすと実音声を無音で置き換えるため、安全側に倒します。

**安全機能。** 共通の capture safety の定数（最初のバッファと stall は 3 秒、無音通知 30 秒、開始予約 601,600,000 bytes、停止下限 128,000,000 bytes、30 秒ごとの確認）をそのまま使います。空き容量は検証済みの録音ディレクトリを GetDiskFreeSpaceExW に渡し、呼び出し元が使える空き bytes を Int64 に変換します（BOOL と GetLastError を確認し、Int64 の上限超過はエラー）。NULL や現在のドライブは使いません。開始前に取得できなければ録音しません。録音中の取得失敗は警告、下限未満は停止です。スリープ防止は専用の native スレッドが SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) を取得し、解放イベントを無期限に待ち（定期的な起床はしません）、同じスレッドで `ES_CONTINUOUS` を指定して解放します。終了時に解放イベントの SetEvent が失敗した場合は無期限 join を行わず、worker が使う owner とハンドルを保持して cleanup error を返します。信号に成功した場合は worker の無期限 join を行い、join に成功した場合に限ってハンドルと owner を破棄します。取得失敗は開始エラー、解放失敗は報告します。ディスプレイ関連のフラグは使いません。蓋を閉じる操作や利用者が選ぶスリープは防げず、想定外の中断では録音を停止して復旧可能な音声を残します。停止は native producer を join してからリングの末尾を確定し、`drain.finish()`、資源解放の順で行います。writer 障害では健全な checkpoint を[共通確定処理](final.md)へ送ります。device 復帰待ち中は stall・無音監視を作動させず、無音警告も抑止しますが、空き容量の30秒ごとの確認は継続し、sleep-prevention power request は保持します。再 open segment は既存 writer の checkpoint 座標から接続し、同じ writer と recording session を保ちます。復帰待ち timeout と通常停止はいずれも durable stop 後の通常 finalization 経路を使います。

Windows には入力音量の自動調整がなく、能力表示は `automatic_input_volume: "none"` です。熱状態の監視もなく、`WindowsNoThermalMonitoring` を注入して `thermal_monitoring: "none"` と表示し、常温を装う値は返しません。

WindowsSupport の ingress unit tests は仮想時計と座標・無音・gap・障害を指定し、idle 観測 latch による再開時の無音補填、合成無音との有界な重複調整と不正な重複の拒否、active／idle／health 未受信でのループバック QPC 前進再アンカーと欠落の扱いを検証します。これらの unit tests は実際の sink と ring を使います。6秒 idle 後の48 kHzで device delta 480／QPC delta 649の復帰を含め、240／480／960-frame native packets の小さな jitter、後続 PCM の保持、200 ppm の符号付き offset slew、48 kHzの各 packet 間に idle health を挟む QPC 0／649／960-frame の late／snapback、105分の50 ppm slow drift 後の停止・health 補填・delivered／elapsed-position 復帰、8.5分の20 ppm slow drift、2分超の20 ppm fast drift、idle 復帰で800-frame先行後の late QPC と snapback、idle 中も device 位置が進む elapsed-position drift、通常／jitter 経路の idle 観測後の device mapping 保持と idle device suffix 補填、drift 遅れだけを除く前進再アンカー・health 補填・`activeTail`、idle silence への先行アンカー後も drift の有無によらず猶予を保つ health 補填と idle health 中の late QPC／snapback、初期アンカー／位置リセットの raw QPC と符号付き reset、5秒ごとの400-frame QPC step、baseline 相対で1 period 以上の active jump、フラグ付き discontinuity も検証します。通常 device mapping の再開は44.1／48 kHz入力を実際の drain・SRC・writer で16 kHzへ保存し、3秒の初期 idle、58秒の PCM、6／8秒の idle、55／66 canonical frames 相当の未カバー末尾を flags 0／1／2／3 で検証します。正常な復帰が欠落を作らず PCM を保持することと、その後の active 中の実欠落を引き続き記録することを確認します。別の source integration fake tests も drain・SRC・writer を通します。fake は本番の protocol と実行ファイルからは使えません。native 側は `app/MacAmbientJev/Tests/CMiniaudioInjected/WindowsCaptureSafetyInjectedTests.c` を Windows clang で `clang <file> -o <一時 exe> -lole32` としてビルドし、SwiftPM tests とは別に実行します。ローカルで差し替えた Win32／COM 呼び出しを通じて同梱実装そのものを検証し、音声ハードウェアは使いません。

snapshot publisher stress test は 1,000,000 回読み取りを行い、teardown は publisher の完了を待ってから native state を解放します。

## 実装の根拠

- [録音開始・停止・障害表示](../app/MacAmbientJev/Sources/MacAmbientJev/AppState+Recording.swift)、[キャプチャ本体](../app/MacAmbientJev/Sources/MacAmbientJevCapture/AudioCaptureEngine.swift)、[macOS provider の空き容量と入力監視](../app/MacAmbientJev/Sources/MacAmbientJevCapture/MacCaptureProviders.swift)、[portable な capture lifecycle / policy](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/CaptureSafety.swift)
- [システム音声権限](../app/MacAmbientJev/Sources/MacAmbientJevCapture/SystemAudioPermission.swift)、[システム音声タップ](../app/MacAmbientJev/Sources/MacAmbientJevCapture/SystemAudioTap.swift)、[mono 化と入力ピーク監視](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/TimestampedMonoSink.swift)、[システム音声の出力デバイス監視](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SystemAudioOutputMonitor.swift)
- [リング容量](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioBlockRing.swift)、[保存エラー](../app/MacAmbientJev/Sources/MacAmbientJevCore/DurableAudioWriter.swift)、[取得音声の判定](../app/MacAmbientJev/Sources/MacAmbientJevCore/TimelineAudio.swift)
- [入力音量 policy](../app/MacAmbientJev/Sources/MacAmbientJevCore/MicGainPolicy.swift)、[音量 ownership と復元](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/MicInputVolumeController.swift)、[設定初期値](../app/MacAmbientJev/Sources/MacAmbientJev/AppState.swift)、[設定 UI](../app/MacAmbientJev/Sources/MacAmbientJev/SettingsView.swift)
- [日本語表示文言](../app/MacAmbientJev/Sources/MacAmbientJevCore/UserFacingStatus.swift)、[表示色・状態の分離](../app/MacAmbientJev/Sources/MacAmbientJev/MacAmbientJevApp.swift)、[読み込みのチャンネル構成](../app/MacAmbientJev/Sources/MacAmbientJevAppleSupport/AudioFileTimelineBuilder.swift)
- [Windows のキャプチャ源](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/WindowsCaptureSource.swift)、[パケット ingress](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/WindowsCaptureIngress.swift)、[安全 adapter](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/WindowsCaptureSafety.swift)、[WASAPI factory](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/WindowsWASAPICaptureFactory.swift)、[native wrapper](../app/MacAmbientJev/Sources/CMiniaudio/WindowsCapture.inc)
