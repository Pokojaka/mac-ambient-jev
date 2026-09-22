# ローカル評価用録音データ

実講義、会話、個人録音などの実データは `test-data/recordings/local/` に置く。

この `local/` ディレクトリは `.gitignore` で除外されているため、録音本体・annotation・評価途中の生成物をまとめて置いてよい。

推奨構成:

```text
test-data/recordings/local/
├── lecture-ja-001/
│   ├── audio.wav
│   ├── manifest.json
│   ├── segments.json
│   └── scene-transitions.json
├── discussion-ja-001/
│   ├── audio.m4a
│   ├── manifest.json
│   └── segments.json
└── ...
```

## manifest.json

```json
{
  "id": "lecture-ja-001",
  "audio": "audio.wav",
  "annotations": {
    "scene_transitions": [
      {
        "time_ms": 120000,
        "to": "discussion"
      }
    ],
    "must_keep_terms": [
      "RSA",
      "公開鍵"
    ],
    "must_not_be_low_priority": [
      42
    ],
    "must_not_be_background": [
      42
    ]
  }
}
```

## 録音から segments.json を生成

音声ファイルだけ置けば、同じディレクトリに `segments.json` と、未作成の場合は空の `manifest.json` を生成できる。

```bash
swift tools/process-recording.swift \
  test-data/recordings/local/lecture-ja-001/audio.m4a
```

既存の `manifest.json` は上書きしない。

## 評価

リポジトリのルートから次の形で実行する。

```bash
swift tools/evaluate-session.swift \
  test-data/recordings/local/lecture-ja-001/manifest.json \
  test-data/recordings/local/lecture-ja-001/segments.json \
  test-data/recordings/local/lecture-ja-001/scene-transitions.json
```

最初は annotation がなくてもよい。まず録音ファイルだけ置き、パイプラインを通した後に保持必須語・誤除外禁止区間・場面転換時刻を追加していく運用を想定する。

## 1件を処理して評価まで実行

```bash
swift tools/test-recording.swift \
  test-data/recordings/local/lecture-ja-001/audio.m4a
```

このコマンドは `segments.json` を生成した後、そのまま評価し、同じディレクトリへ `report.json` を保存する。
`scene-transitions.json` が存在する場合は自動的に評価へ含める。

通常、処理中に作成するアプリ側セッションは終了時に削除する。
パイプラインのデバッグでセッションを残したい場合だけ、下位コマンドを直接使う。

```bash
swift run --package-path app/MacAmbientJev \
  MacAmbientJevProcessRecording \
  --keep-session \
  test-data/recordings/local/lecture-ja-001/audio.m4a
```

## corpus を一括実行

`test-data/recordings/local/` 直下の各ディレクトリを走査し、音声ファイルがある corpus をまとめて処理できる。

```bash
swift tools/test-corpus.swift
```

既に `report.json` がある corpus はスキップする。全件を再処理する場合:

```bash
swift tools/test-corpus.swift --force
```

別の corpus root を指定する場合:

```bash
swift tools/test-corpus.swift /path/to/corpus
```
