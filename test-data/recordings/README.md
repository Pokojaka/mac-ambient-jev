# ローカル評価用録音データ

実講義、会話、個人録音などの実データは `test-data/recordings/local/` に置く。

この `local/` ディレクトリは `.gitignore` で除外されているため、録音本体・annotation・評価途中の生成物をまとめて置いてよい。

推奨構成:

```text
test-data/recordings/local/
├── lecture-ja-001/
│   ├── audio.wav
│   └── segments.json
└── ...
```

注釈付きの評価（`manifest.json` の annotation、`tools/evaluate-session.swift`、`tools/test-recording.swift`、`tools/test-corpus.swift`）は設計から外した。理由と削除予定は `docs/evaluation.md` を参照する。

## 録音から segments.json を生成

音声ファイルだけ置けば、同じディレクトリに `segments.json` を生成できる。

```bash
swift tools/process-recording.swift \
  test-data/recordings/local/lecture-ja-001/audio.m4a
```

通常、処理中に作成するアプリ側セッションは終了時に削除する。
パイプラインのデバッグでセッションを残したい場合だけ、`--keep-session` を付ける。

```bash
swift run --package-path app/MacAmbientJev \
  MacAmbientJevProcessRecording \
  --keep-session \
  test-data/recordings/local/lecture-ja-001/audio.m4a
```
