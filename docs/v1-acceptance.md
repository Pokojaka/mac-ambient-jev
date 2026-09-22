# V1 受け入れ試験

## 基本検証

- [ ] `bash scripts/verify_v1.sh` が成功する
- [ ] `.build/MacAmbientJev.app` が生成される
- [ ] アプリが macOS 15 以降で起動する
- [ ] マイク権限の説明が日本語で表示される
- [ ] 音声ファイル import が動作する
- [ ] UI の主要状態・エラー表示が日本語である

## 60〜90分長時間試験

記録値:

```text
録音時間:
capture dropout:
ASR RTF:
peak memory:
開始時 memory:
終了時 memory:
oldest pending age:
Jev success count:
Jev failure count:
Jev retry pending count:
scene oscillation count:
crash recovery loss window:
offline diarization completion time:
```

受け入れ条件:

- [ ] 録音 callback が ASR 待ちで停止しない
- [ ] durable audio の保存が継続する
- [ ] ASR backlog が増えても録音状態と処理状態を別々に表示できる
- [ ] メモリ使用量が時間に比例して無制限に増えない
- [ ] 録音停止後に残り処理が完了できる

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

## 誤除外回帰

15〜30分のローカル golden corpus で確認する。

- [ ] `false_low_priority_count == 0`
- [ ] `false_background_count == 0`
- [ ] `technical_term_retention == 1.0`
- [ ] mixed scope segment が丸ごと background 扱いされない
- [ ] 「えー、RSAでは…」のような mixed-content 発話が LOW_PRIORITY にならない

## テスト録音データ

`test-data/recordings/local/<corpus-id>/audio.m4a` のように配置し、次を実行する。

```bash
swift tools/process-recording.swift \
  test-data/recordings/local/<corpus-id>/audio.m4a
```

生成された `segments.json` を評価する。

```bash
swift tools/evaluate-session.swift \
  test-data/recordings/local/<corpus-id>/manifest.json \
  test-data/recordings/local/<corpus-id>/segments.json
```

実録音データと annotation は `.gitignore` 対象とし、GitHubへ commit しない。
