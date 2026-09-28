# V1 受け入れ試験

## V1 完了の条件（2026-09-28 決定）

- 以下の「基本検証」「60〜90分長時間試験」「process kill 復旧」「オフライン試験」のマイク実機項目がすべて通ったときに V1 完了とする。
- マイクを使う試験はユーザーが実施して確認する。エージェントはマイクを使わず、これらの項目を自分で合格にしない。
- 話者ラベルを初登場順 Speaker 1〜7 + OTHER + UNKNOWN に変更する作業は V1 に含め、マイク試験の前に入れる。マイク試験で表示も確認する。
- 誤除外回帰と golden corpus は設計から外した。ユーザーは annotation を整備せず、保持すべき発話の確認はマイク実機試験で行う（`docs/evaluation.md`）。

## 基本検証

- [x] `bash scripts/verify_v1.sh` が成功する（2026-09-25、モデル実行テストは通常設定どおり除外）
- [x] `.build/MacAmbientJev.app` が生成される
- [x] アプリが macOS 15 以降で起動する
- [ ] マイク権限の説明が日本語で表示される
- [ ] 音声ファイル import が動作する
- [ ] UI の主要状態・エラー表示が日本語である
- [x] 既存の発話入り会話音声から切り出した75秒 excerpt の原速 replay で、最初の非空 view-model 更新までの P95 が3秒以内（6発話中6件、P50 1.159秒、P95 1.935秒。実マイク・画面描画・長時間熱状態は未検証。計測値は `docs/v1-live-latency-results-2026-09-25.md`）

録音中に durable write または入力形式の異常が発生した場合は録音状態を直ちに終了し、日本語の原因別エラーを表示する。保存済みの chunk は削除せず、保存済み録音から読み出せるようにする。中断したライブ ASR からの遅延更新は表示しない。
録音中は IOKit のアイドル時システムスリープ防止と ProcessInfo の録音用 activity を保持する。ディスプレイの消灯は妨げない。蓋を閉じた場合、Apple メニューからの明示的なスリープ、低電力時のスリープは防止できない。スリープ防止の設定に失敗しても録音は継続し、警告を表示する。
音声 callback の PTS、ring の欠落、無効入力を録音開始からのフレーム位置に合わせて無音で埋め、欠落範囲を `audio-gaps.jsonl` に永続記録する。確定 chunk は連番ファイルを原子的に公開し、フレーム数を `audio-chunks.jsonl` に追記する。録音中は増加する `checkpoint.json` を毎 chunk 書き直さず、既存 checkpoint と未反映の連番 chunk・index を復旧時に統合する。
録音開始は最初の有効な音声 buffer が約3秒以内に届かなければ失敗とし、開始中も停止できる。録音中は無音が30秒続けば警告し、入力停止・デバイス切断・セッション中断時は保存済みの音声を確定して終了する。空き容量の開始判定は選択されたデバイスのレート・チャンネル数で90分の Float32 音声と余裕分を計算する（90分での自動停止ではない）。録音中は約30秒ごとに残量を確認する。

マイク実機チェック（すべてユーザーが実施し、未検証）:

- [ ] 録音中にディスプレイを消灯させても音声が継続し、蓋を閉じたときはスリープによる中断・復旧が分かる。停止後はシステムの通常スリープに戻る
- [ ] USB マイクを録音中に抜くと日本語エラーで停止し、確定済み音声を保存済み録音から読み出せる
- [ ] AirPods を録音中に接続・切断または入力切替しても別デバイスへ無断で切り替わらず、中断を表示する。Bluetooth HFP の 16/24 kHz 入力では音質警告が出る
- [ ] whisper-stream など別の録音ツールと同時使用して、録音・タイムライン・欠落警告を確認する
- [ ] マイクをハードウェアミュートまたは無音にして30秒後に非致命的な無音警告が出て、音声再開時に消える。開始時に入力が届かない場合は3秒程度で終了し、開始中も停止できる
- [ ] 低空き容量では開始を拒否し、録音中に空き容量が不足した場合は確定済み音声を残して停止する

## Jev 実 API の接続確認

2026-09-25 にアプリの Keychain に保存済みのキーを使い、合成文だけを送信した。説明文「今日は公開鍵暗号の仕組みを説明します。」は `PRIMARY`、単独フィラー「えー。」は `LOW_PRIORITY` となり、両方とも HTTP 200、応答モデルは `jev-1.13.0` だった。録音音声や保存済み発話は送信していない。この結果は Jev の接続と単独発話の分類を示すもので、アプリ画面上の保留表示が実セッションで解消されることまでは確認していない。

## 既存音声での話者分離

2026-09-25 に既存の発話入り20秒 fixture `_smoke/audio.wav` を新しい停止後パイプラインへ入力し、実 VAD・FluidAudio 話者分離・Qwen3-ASR が正常終了した。出力は8区間で、`S1` と `S2` の両方が現れ、話者が割り当てられない区間は3件、短い空文字区間は1件保持された。元音声に対する人手の話者境界 annotation はないため、境界や話者 ID の正確さの合格判定には使わない。短い交替・重なり・0.2秒間隔の分割処理は合成 span の単体テストで検証した。既存の20分会話の segment 出力を transcript text なしで調べた結果、251 speaker spans 内の80回の隣接話者交替のうち39回は非負の間隔が200ms未満、46回が500ms未満で、中央値は272msだった。隣接 span の重なりはなかった。これは既存注釈の構造確認であり、話者境界の正確さの評価ではない。

## 60〜90分長時間試験

記録値:

```text
録音時間:
capture dropout:
ASR RTF:
peak memory:
開始時 memory:
終了時 memory:
5秒ごとの memory footprint（memory.jsonl）:
ASR 段階の最初の5分間 footprint 中央値:
ASR 段階の最後の5分間 footprint 中央値:
両中央値の増加量:
oldest pending age:
Jev success count:
Jev failure count:
Jev retry pending count:
scene oscillation count:
crash recovery loss window:
offline diarization completion time:
```

2026-09-24 のファイル入力での測定値と、実録音では未検証の項目は `docs/v1-acceptance-results-2026-09-23.md` に記載する。初回の約84.3分 run はメモリ増加の閾値を超えた。`--low-heat` の MLX キャッシュ上限を2 GiBにした後、同じ録音の再測定でファイル処理のメモリ条件を満たした。ライブ録音全体の確認項目は未完了のままとする。既存音声を使った20秒 fixture と75秒 excerpt の first-visible latency replay、4秒 rolling input 上限、および計測限界は `docs/v1-live-latency-results-2026-09-25.md` を参照する。

受け入れ条件:

- [ ] 録音 callback が ASR 待ちで停止しない
- [ ] durable audio の保存が継続する
- [ ] ASR backlog が増えても録音状態と処理状態を別々に表示できる
- [ ] 熱状態が `serious` または `critical` のとき、ライブ ASR の区間間調整が録音保存を妨げず、未処理区間数を表示する。`nominal` と `fair` では待機しない
- [ ] メモリ使用量が時間に比例して無制限に増えない
- [ ] 録音停止後に残り処理が完了できる

60〜90分のファイル import 処理では、モデル読み込み後の ASR 段階における最初と最後の重ならない各5分間で、5秒ごとの有効な `phys_footprint` サンプルを各48件以上採る。最後の中央値が最初より512 MiB超増えず、M4 16 GB 実機で peak memory footprint が12 GiB以下なら、このファイル処理のメモリ項目を VERIFIED とする。サンプル不足や途中失敗は INCONCLUSIVE、閾値超過は失敗とする。この結果で上記のライブ録音項目を合格にしない。

## ファイル import と保存済みセッションの復旧

- [x] `--inspect-session <UUID> --sessions-root <path>` は指定 root の対象セッションだけを解析し、イベントログと metadata を変更しない
- [x] `--resume-session <UUID> --sessions-root <path>` は指定 root の対象外セッションを走査・修復せず、対象の pending ASR だけを処理する
- [x] 完了済み ASR のイベントを重複させず、後段処理まで完了する
- [x] 4ミリ秒端数の完了イベントを保持し、`segments.json` に独立区間として出さない
- [x] `engine-metrics.json`、`memory.jsonl`、`run.json` の run ID と計測範囲が一致する

## process kill 復旧

録音中にアプリを強制終了し、再起動する。

- [ ] 過去の原音声を読み出せる
- [ ] 最後の未確定 chunk 以外の durable audio が残る
- [ ] `events.jsonl` の不完全な最終行だけが除外される
- [ ] 完了済み ASR が重複実行されない
- [ ] pending ASR が再投入される
- [ ] failed run が active run を置き換えない

## オフライン試験

Jev API へ接続できない状態で10分以上録音する。

- [ ] 録音が継続する
- [ ] VAD が継続する
- [ ] ASR が継続する
- [ ] 話者分離がローカルで実行できる
- [ ] scene state machine がローカル音響だけで遷移できる
- [ ] Jev 未判定発話が通常表示される
- [ ] Jev failure が録音 failure として扱われない
- [ ] 接続復旧後に再分類対象として保持される

## テスト録音データ

`test-data/recordings/local/<corpus-id>/audio.m4a` のように配置し、次を実行する。

```bash
swift tools/process-recording.swift \
  test-data/recordings/local/<corpus-id>/audio.m4a
```

生成された `segments.json` は、処理完了・復旧・処理時間・メモリの確認に使う。注釈付きの評価は行わない。

実録音データは `.gitignore` 対象とし、GitHubへ commit しない。
