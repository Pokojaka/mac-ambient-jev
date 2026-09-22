# 評価 fixture

このディレクトリには、リポジトリで共有できる合成 fixture と annotation schema の例だけを置く。

実講義、会話、個人録音など、第三者の音声や共有権限が不明な音声は commit しない。
実音声を評価するときは、リポジトリ外の任意ディレクトリに音声・annotation・materialized segments を置き、パスだけを評価コマンドへ渡す。

## Manifest schema

```json
{
  "id": "lecture-ja-001",
  "audio": "/absolute/or/relative/path/lecture-ja-001.wav",
  "annotations": {
    "scene_transitions": [
      {"time_ms": 120000, "to": "discussion"}
    ],
    "must_keep_terms": ["RSA", "公開鍵"],
    "must_not_be_low_priority": [42],
    "must_not_be_background": [42]
  }
}
```

`must_not_be_low_priority` と `must_not_be_background` は、評価対象の materialized segment 配列に対する 0-based index とする。
segment ID ではなく index を使うのは、V1 の評価 fixture を単純に保つためである。V2 で corpus を拡大する場合は stable segment ID への移行を検討する。

## Synthetic fixture

CI では音声ファイルを必要としない合成 segment を使い、少なくとも次を固定する。

- 必須技術用語が保持される
- 保持必須 segment が `LOW_PRIORITY` へ誤分類されない
- 保持必須 segment が discussion 中に background-only と誤判定されない
- 明示した場面転換の誤差を測定できる
