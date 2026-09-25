# V1 評価手順

## 目的

V1 の評価では、文字起こし精度だけでなく「保持すべき発話を誤って除外しないこと」を優先する。
評価器は materialized transcript を入力にし、Jev・scope・scene の結果を含む最終表示状態を検査する。

## 評価項目

JSON レポートには次を出力する。

- `technical_term_retention`: annotation の `must_keep_terms` が文字起こし本文に残った割合。用語 annotation が空なら `null`
- `false_low_priority_count`: `must_not_be_low_priority` に指定した segment が `LOW_PRIORITY` になった件数。annotation が空なら `null`
- `false_background_count`: `must_not_be_background` に指定した segment が discussion 中に background-only となった件数。annotation が空なら `null`
- `scene_transition_error_ms`: annotation と観測場面転換の平均絶対誤差。転換 annotation が空、または観測データが未提供なら `null`。観測済みで必要な転換が欠落した場合は `-1`
- `scene_oscillation_count`: 観測された転換列において30秒以内に A→B→A と戻る短周期振動の件数。観測データが未提供なら `null`、明示的な空配列なら `0`
- `asr_rtf`: ASR real-time factor。未計測なら項目を出力しない
- `peak_memory_mb`: 最大メモリ使用量。未計測なら項目を出力しない
- `oldest_pending_age_ms`: 最古の未処理作業の滞留時間。未計測なら項目を出力しない

注釈のない評価項目は JSON に `null` として出力し、CLI は標準エラーにも項目名を表示する。`null` は 0 件や合格を意味せず、その項目では corpus の合否を判定できない。探索用に annotation が空の manifest を使うことはできるが、受け入れ評価の前に各判定項目を annotation する。RTF・メモリ・pending age は長時間試験で計測値を与える。合成 unit test では未設定でもよい。

`must_not_be_low_priority` と `must_not_be_background` の index は `segments.json` の範囲内を指定する。範囲外の index と空文字・空白だけの `must_keep_terms` は明示エラーになり、評価レポートを生成しない。

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

第3引数の scene-transitions JSON を省略すると観測データなしとなり、`scene_transition_error_ms` と `scene_oscillation_count` は `null` になる。場面転換が一度もなかったという観測結果を記録するときは、ファイルに `[]` を指定する。この場合、必要な転換 annotation があるのに観測が空なら誤差は `-1`、oscillation は `0` となる。

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

回帰判定の前に、対象 corpus の3項目がいずれも `null` でないことを確認する。必要な annotation が不足した report は合格として扱わない。scene threshold の変更を評価する場合も `scene_transition_error_ms` を annotation し、`null` でないことを確認する。

scene threshold の変更では、上記を維持したうえで `scene_transition_error_ms` と `scene_oscillation_count` を比較する。
