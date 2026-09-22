# V1 評価手順

## 目的

V1 の評価では、文字起こし精度だけでなく「保持すべき発話を誤って除外しないこと」を優先する。
評価器は materialized transcript を入力にし、Jev・scope・scene の結果を含む最終表示状態を検査する。

## 評価項目

JSON レポートには次を出力する。

- `technical_term_retention`: annotation の `must_keep_terms` が文字起こし本文に残った割合
- `false_low_priority_count`: 保持必須 segment が `LOW_PRIORITY` になった件数
- `false_background_count`: 保持必須 segment が discussion 中に background-only となった件数
- `scene_transition_error_ms`: annotation と観測場面転換の平均絶対誤差。必要な転換が欠落した場合は `-1`
- `scene_oscillation_count`: 30 秒以内に A→B→A と戻る短周期振動の件数
- `asr_rtf`: ASR real-time factor
- `peak_memory_mb`: 最大メモリ使用量
- `oldest_pending_age_ms`: 最古の未処理作業の滞留時間

RTF・メモリ・pending age は長時間試験で計測値を与える。合成 unit test では未設定でもよい。

## ローカル corpus の配置

実講義や個人録音はリポジトリ外へ置く。例:

```text
~/mac-ambient-jev-corpus/
├── lecture-ja-001.wav
├── lecture-ja-001.manifest.json
├── lecture-ja-001.segments.json
└── lecture-ja-001.scene-transitions.json
```

`manifest.json` の形式は `app/MacAmbientJev/Tests/MacAmbientJevCoreTests/Fixtures/README.md` を参照する。

## 実行

リポジトリのルートから実行する。

```bash
swift tools/evaluate-session.swift \
  ~/mac-ambient-jev-corpus/lecture-ja-001.manifest.json \
  ~/mac-ambient-jev-corpus/lecture-ja-001.segments.json \
  ~/mac-ambient-jev-corpus/lecture-ja-001.scene-transitions.json
```

場面転換 annotation がない場合は第3引数を省略できる。

`segments.json` は `[MaterializedTranscriptSegment]` の JSON 配列とする。V1 では materialized schema を評価境界として固定し、内部 event の細部を評価ツールへ漏らさない。

## 15〜30分 golden corpus

最低でも次の種類を含める。

1. 講師1人が主に話す講義
2. 講義からグループ討論へ移る区間
3. 討論から講義へ戻る区間
4. フィラー直後に技術用語が続く発話
5. 近距離発話と遠距離発話が同一 segment に混在する区間

各 corpus について、完全な逐語 transcription は必須ではない。
V1 では「保持必須語」「誤除外禁止 segment」「場面転換時刻」を優先して annotation する。

## 回帰判定

少なくとも次を満たさない変更は V1 の改善として採用しない。

```text
false_low_priority_count == 0
false_background_count == 0
technical_term_retention == 1.0
```

scene threshold の変更では、上記を維持したうえで `scene_transition_error_ms` と `scene_oscillation_count` を比較する。
