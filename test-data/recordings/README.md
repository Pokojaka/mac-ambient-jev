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