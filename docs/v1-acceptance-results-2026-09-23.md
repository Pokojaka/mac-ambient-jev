# V1 受け入れ検証記録（2026-09-23）

2026-09-24 の作業範囲変更により、注釈付き golden corpus の作成と誤除外精度の評価は今回実施しない。下記の候補語に関する過去の測定は残すが、用語保持・誤低優先度・誤背景の受け入れ合格には使わない。14秒で区間を分割した直後の4ミリ秒端数も、独立した発話を VAD が検出した結果ではない。

## 評価データ

実講義3件（約74分、88分、84分）と、情報セキュリティ基礎の会話を含む20分の抜粋をローカルに配置した。録音・元の文字起こし・候補 annotation・生成結果は `test-data/recordings/local/` または元の授業フォルダにのみ置き、Git 管理対象に含めない。保持必須語は既存の時刻付き文字起こしから選んだ候補であり、音声を独立に確認した正解 annotation ではない。

## 自動検証

- Xcode 27.0 と Metal Toolchain を導入した。フル Xcode で通常の SwiftPM ビルドが可能になった。
- `scripts/verify_v1.sh` の通常経路が成功し、Core 101件と Runtime 13件が成功した。`.build/MacAmbientJev.app` を生成し、MLX の `default.metallib` を含む4つの SwiftPM resource bundle を同梱した。
- 場面転換の観測値がない場合、誤って振動0件と判定せず、場面転換誤差と振動件数をともに `null` として出力することをテストと CLI で確認した。
- Qwen3-ASR 1.7B 8-bit の実モデル smoke は `xcrun xctest` 直接起動で成功し、20秒の日本語音声を文字起こしした。2026-09-24 に `RUN_MODEL_TESTS=1 ASR_SMOKE_AUDIO="$PWD/test-data/recordings/local/_smoke/audio.wav" bash scripts/verify_v1.sh` も最後まで成功し、`V1 verification passed` を確認した。
- 情報セキュリティ基礎の20分抜粋は106区間の ASR・話者分離・場面判定・範囲整理まで完了した。実時間310.99秒、最大 RSS 2,588,688,384 bytes、peak memory footprint 7,666,208,968 bytes。候補必須語の保持率は1.0、観測した場面転換は39件、30秒以内の往復は10件。誤低優先度・誤背景・転換誤差は未注釈で `null`。
- 約73.6分の既存録音は342区間を最後まで処理した。実時間2564.92秒、最大 RSS 2,628,960,256 bytes、peak memory footprint 7,803,523,536 bytes。候補必須語の保持率は1.0。誤低優先度・誤背景・場面転換指標は未注釈または観測ファイル未作成のため `null`。
- 約87.6分の `20251107_131643` は処理開始から404.26秒で MLX が異常終了した。522区間のうち382区間は `asr.completed` まで記録されたが、`segments.json` は生成できていない。次の `seg_000383` は48 kHzで192フレーム（4ミリ秒）しかなく、Qwen3 の特徴量が0フレームとなって `stacked([])` が異常終了した。最大 RSS 2,576,187,392 bytes、peak memory footprint 7,221,333,568 bytes。実行中にプロセスの強制休止も試したため、休止が異常終了に与えた影響はこの結果だけでは判定できない。新しく検出する極短区間を除外し、既に保存された極短区間は復旧時に空の文字起こしとして完了させる修正を追加した。実モデルでの復旧処理は未検証。

## 受け入れ判定

現時点では V1 を合格と判定しない。上記の保持必須語は既存の Whisper 文字起こしから選んだ候補で、音声を独立に確認した正解 annotation ではない。誤低優先度・誤背景の正解 annotation は空であり、CLI の通常処理では Jev を使わないため内容優先度は未設定、音響範囲は主に `unknown` だった。両指標のゼロ件を合格根拠にしない。残り2件の長時間録音、授業から討論への切替区間の追加評価、滞留時間・復旧範囲も未完了。

マイクを使用しない方針のため、ライブ録音、録音中の強制終了、マイク権限の手動確認は未検証とする。Jev の実通信はアプリで API キーを入力した後に確認する予定であり、現時点で未検証である。

ライブ ASR には熱状態に応じた区間間の待機を追加した。通常時は待機せず、熱状態が高い場合も30秒以上待っている区間を優先する。録音中の発熱・待ち時間・音声保存への影響は、マイクを使わない方針のため実測していない。

## 2026-09-24 追加検証

- 変更後の `RUN_MODEL_TESTS=1` 検証は Core 112件、Runtime 13件、実 Qwen3-ASR smoke、リリースアプリのビルドまで成功した。ログは `test-data/recordings/local/_v1-run/verify-current.log`。この後に熱状態の開始条件と計測スクリプトを変更したため、最終コードでの検証は別途行う。
- 20秒の音声を通常と `--low-heat` で処理し、両方とも同じ2区間の本文を出した。低発熱実行では ASR の完了イベント後に約2.004秒休止した。両 run の `run.json` は `test-data/recordings/local/_smoke/smoke-normal-20260923T195118Z/` と `smoke-lowheat-20260923T195140Z/` に保存した。
- 18分の討論抜粋は98区間を処理した。実時間718秒、今回処理した音声の ASR RTF 0.465、低発熱休止207秒、peak memory footprint 7,298 MiB。142件の熱状態サンプルはすべて `nominal`。最初と最後の5分間の ASR footprint 中央値差は2,121 MiBで、512 MiBの条件を超えた。結果は `test-data/recordings/local/20251017_security_discussion_15to33/20251017_security_discussion_15to33-20260923T200136Z/run.json`。注釈付き corpus の精度評価としては使わない。
- 約87.6分録音の保存済みセッションを Git 管理外へ複製して復旧した。復旧前後で原本のイベントログは不変。復旧前は382区間完了、140区間 pending。復旧後は522区間の完了 ID がすべて一意で pending は0。`seg_000383` は空の完了イベントを残したが、表示用 `segments.json` には含まない。再度 CLI を呼んでも出力の SHA-256 は同一だった。復旧起動分のみの ASR RTF は0.438、休止298秒、peak memory footprint 7,454 MiB。193件の熱状態サンプルはすべて `nominal`。`oldest_pending_age_ms` には過去の異常終了から再開までの待ち時間を含む。結果は `test-data/recordings/local/20251107_131643/20251107_131643_recovery-20260923T201411Z/run.json` と `test-data/recordings/local/_v1-run/recovery-copy/before.json`。
- 約84.3分録音は604区間の ASR、話者分離、場面判定、音響範囲整理まで完了した。実時間3,426秒、今回処理した音声の ASR RTF 0.518、低発熱休止1,287秒、peak memory footprint 7,445 MiB。663件の熱状態サンプルはすべて `nominal`。ASR 中の最初と最後の5分間の footprint 中央値差は1,161 MiBで、指定された512 MiB以下の条件を満たさない。開始後5分以降の5分窓の中央値は約6,545〜6,588 MiBで横ばいだったが、判定の窓を事後変更して合格にはしない。結果は `test-data/recordings/local/20260119_080630/20260119_080630-20260923T203108Z/run.json`。

長時間ファイル処理で熱状態は安定し、既存セッションの ASR 復旧も成功した。一方、メモリ増加の受け入れ条件は約84.3分 run で **FAILED**。原設計の録音実機、Jev 実通信、注釈付き誤除外評価も今回検証していないため、V1 全体は **NOT VERIFIED** のままとする。ファイル入力で測った pending age、復旧、メモリをライブ録音の測定値として扱わない。

最終コードでは `test-data/recordings/local/_v1-run/verify-final.log` の `RUN_MODEL_TESTS=1` 検証が成功した。Core 112件、Runtime 13件、Qwen3-ASR 実モデル smoke、リリースアプリビルドが通った。長時間 run の実行後に計測スクリプトの欠落メトリクス検出、入力時間、ソーススナップショットの記録と CLI の熱状態開始条件を追加した。この追加部分は最終の全自動検証を通したが、上記の長時間測定時にはまだ適用されていないため、測定結果を事後更新しない。

`SessionRecoveryScanner` の対象限定の読み取り処理を整理した後も、`test-data/recordings/local/_v1-run/verify-final-after-inspect.log` で同じ実モデル付き全検証が成功した。計測スクリプトの最終版は `test-data/recordings/local/_smoke/smoke-final-20260923T214136Z/run.json` で20秒ファイル入力を完了し、録音時間、熱サンプル、メモリサンプル、ソーススナップショットのハッシュを記録した。

ASR を fake engine で停止したまま別の `DurableAudioWriter` が音声 chunk を確定できることも追加テストで確認した。これは録音 callback の実機試験ではない。最後の `test-data/recordings/local/_v1-run/verify-final-all.log` では Core 113件、Runtime 13件、実モデル smoke、アプリビルドが成功した。対象の session と録音データは Git 管理外に保持した。

### 低発熱モードのメモリ再測定

先の **FAILED** はその時点の実測判定として残す。同じ18分音声を用いた追加計測では、ASR 中の MLX 使用中メモリは約2.4 GiBでほぼ一定だった。一方、再利用可能な MLX キャッシュは約1.8 GiBから設定上限の4 GiBまで増え、`phys_footprint` の増加と一致した。計測ログは `test-data/recordings/local/20251017_security_discussion_15to33/memory-trace-baseline-20260923T224814Z/` にある。この run の最初と最後の5分間の中央値差は2,058 MiB、peak は7,284 MiB、ASR RTF は0.432だった。

CLI 専用 `--low-heat` では、MLX キャッシュ上限を既存値以下の2 GiBに制限した。通常の CLI 処理とアプリ内のライブ ASR は変更していない。再測定結果は以下のとおり。各 run は5秒間隔の ASR メモリサンプルを最初と最後の5分間に48件以上含み、入力ファイルの SHA-256 は比較対象と一致する。

| ファイル処理 | 修正後の中央値差 | 修正後の peak footprint | ASR RTF | 出力と熱状態 | 結果 |
| --- | ---: | ---: | ---: | --- | --- |
| 同じ18分抜粋 | 41 MiB | 5,252 MiB | 0.398 | 98区間の本文が修正前と一致。129サンプルがすべて `nominal` | VERIFIED |
| 同じ約84.3分録音 | 3.9 MiB | 5,413 MiB | 0.443 | 604区間の本文が修正前と一致。617サンプルがすべて `nominal` | VERIFIED |
| 保存済み約87.6分セッションの別コピーを復旧 | -3.8 MiB | 5,406 MiB | 0.412 | 521表示区間の本文が修正前と一致。188サンプルがすべて `nominal` | VERIFIED |

18分の結果は `test-data/recordings/local/20251017_security_discussion_15to33/memory-cap-2g-20260923T230127Z/run.json`、約84.3分は `test-data/recordings/local/20260119_080630/memory-cap-2g-long-20260923T231245Z/run.json` にある。後者の ASR メモリ窓には最初59件、最後58件の有効サンプルがある。復旧結果は `test-data/recordings/local/20251107_131643/memory-cap-2g-recovery-20260924T000710Z/run.json`。復旧後の522区間の完了 ID に重複はなく、`seg_000383` は表示用出力から除いた。原本イベントログの SHA-256 も不変だった。通常 CLI の20秒再実行では休止0秒で、キャッシュ上限は Qwen3-ASR が設定する4 GiBのままだった。ログは `test-data/recordings/local/_smoke/memory-normal-control-20260924T002400Z/`。

最終コードの `RUN_MODEL_TESTS=1` 検証は `test-data/recordings/local/_v1-run/verify-memory-cap.log` に保存した。Core 113件、Runtime 13件、Qwen3-ASR 実モデル smoke、アプリビルドが成功した。

約84.3分の**ファイル処理のメモリ条件**は修正後の実行で **VERIFIED**。マイクを使ったライブ録音、録音中の強制終了、Jev の実通信、注釈付き精度評価は引き続き未検証で、V1 全体は **NOT VERIFIED**。

### アプリからの実機確認の準備

`scripts/build_app.sh` で `.build/MacAmbientJev.app` を再生成した。ad-hoc 署名、sandbox のマイク入力・ネットワーク権限、`NSMicrophoneUsageDescription` の日本語文、MLX の `default.metallib` を確認し、`open` でアプリのプロセスが起動することを確認した。設定画面に Jev の接続確認ボタンとマイク権限・録音テストの案内を追加した。Jev の接続確認はアプリ設定画面でキーを保存した後にボタンを押したときだけ固定テスト文を送信する。今回の起動ではマイク録音も Jev の実通信も行っていないため、実機の結果は依然 **NOT VERIFIED**。

メイン画面のツールバーにも「設定」ボタンを追加し、`Settings` 画面を GUI から開ける経路を用意した。更新後の `.app` を再生成して起動し、署名とプロセスの生存を確認した。操作自動化の権限がないため、ボタン押下後のウィンドウ表示は手動確認待ちとする。

### 2026-09-24 録音入力の追試

ユーザーが録音ボタンを押した際、旧アプリは `AudioCaptureEngine.start(sessionID:)` のタップで Swift の実行キュー検査によりクラッシュした。コールバックを `@Sendable` にした後はクラッシュしなくなったが、直近のライブセッションは保存フレーム数が0だった。コールバックの修正だけでは録音できていなかった。

Apple は `AVAudioEngine.inputNode` のハードウェア形式を `inputFormat(forBus:)` で確認するよう案内している。同様の0フレーム事例では `outputFormat` とマイクのサンプルレート差が原因だった。ただし、この Mac の単独試験では両形式が48 kHzであり、変更後のアプリでも0フレームだったため、形式変更だけでは解決しなかった。[Apple の inputNode 説明](https://developer.apple.com/documentation/avfaudio/avaudioengine/inputnode) と [類似事例](https://github.com/Gremble-io/Detto/issues/27) を参照。

同じアプリ実行環境とマイク権限で3秒録音すると、`AVAudioEngine` は0フレーム、`AVCaptureSession` と `AVCaptureAudioDataOutput` は295,936フレームを受け取った。後者の入力を既存のリングバッファと保存処理へ接続した。18秒のマイク録音で1,728,000フレームを保存し、録音を WAV に変換して既存のファイル処理へ渡すと2区間の文字起こしを得た。録音にはテスト用の音声ファイルをスピーカーから再生した。証拠は Git 管理外の `test-data/recordings/local/_v1-run/mic-speech-capture/` にある。[Apple の音声データ出力](https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput/setsamplebufferdelegate(_:queue:)) は連続したサンプルをシリアルキュー上の delegate に渡す契約である。

通常版 `.app` のビルド、署名、起動と Core 114件、Runtime 13件は成功した。GUI の録音ボタンからの停止・ライブ ASR 表示、長時間録音、録音中の障害回復、Jev 実通信、注釈付き精度指標はこの追試では未確認。V1 全体は **NOT VERIFIED** のままとする。

### 2026-09-24 ライブ文字起こしの待ち時間

ユーザーのライブセッション `7BE8BA20-8779-4E0D-957E-7A03300214C8` は41.4秒、3,971,072フレームを保存した。発話3区間は録音中に `segment.created` と `asr.pending` になったが、アプリ内の Qwen3-ASR キャッシュは未完成のダウンロード状態で、ASR 完了イベントはなかった。初回の `asr.pending` と最初の `asr.completed` の間は218秒。ただし、この間にアプリ終了、完成済みモデルのキャッシュへの複製、再起動を含むため、218秒をモデル推論の所要時間とは扱わない。複製後の復旧では保留の3区間をすべて完了した。

モデルはアプリ設定画面の「音声認識モデル」から準備できる。録音開始時、ファイル読み込み時、ASR 復旧時にもバックグラウンドで準備し、メイン画面と設定画面に進捗を表示する。ASR から同時に準備を要求された場合は同じ処理の完了を待つ。完成済みモデルを持つアプリ環境で設定画面と同じ準備経路を実行した試験は1.81秒で完了した。

別の bundle ID で署名した `.app` を空のサンドボックスで起動し、アプリ自身のモデル準備経路で初回ダウンロードから読込完了までを測定した。実時間203.4秒で進捗0%から79%、読込80%、準備完了を確認した。保存先はこのアプリのコンテナ内で、`model.safetensors` は2,463,307,541バイト。SHA-256 `bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c` は配布元の LFS 値と一致した。記録は `test-data/recordings/local/_v1-run/model-fresh-run.log` と `model-fresh-app.log`。GUI の録音ボタンから最初の文字起こしが画面に表示されるまでの時間は未測定。

試験用起動処理を外した通常版 `.app` を再生成し、署名検証と起動を確認した。`test-data/recordings/local/_v1-run/verify-model-first-run-final.log` で Core 114件、Runtime 13件、実モデルの音声認識試験が成功した。`git diff --check` も成功。GUI の録音開始からライブ表示までの所要時間は引き続き **NOT VERIFIED**。

CLI の境界確認では、混在した import と resume、重複フラグ、不完全な計測指定の10件を、ファイルを書かずに拒否した。無音ファイルは空の `segments.json` を生成し、再起動後の inspect でも処理待ちに戻らなかった。CLI は評価用の空 `manifest.json` を自動生成しない。通常テストは Core 114件と Runtime 13件が成功した。記録は `test-data/recordings/local/_v1-run/verify-app-ready-tests.log` と `test-data/recordings/local/_smoke/final-metrics-smoke-20260924T080756Z/run.json` にある。
