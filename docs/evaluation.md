# V1 評価手順

## 方針（2026-09-28 決定）

ユーザーは正解 annotation を整備しない。そのため、人手の注釈を前提とする評価は設計から外す。

- 外す項目: 保持必須語の保持率（`technical_term_retention`）、誤低優先度（`false_low_priority_count`）、誤背景（`false_background_count`）、場面転換時刻の誤差（`scene_transition_error_ms`）、15〜30分の golden corpus
- 代わりの確認: 保持すべき発話が消えていないか、表示が妥当かは、ユーザーがマイクを使った実機試験で確認する（`docs/v1-acceptance.md`）
- ASR 精度の回帰: 正解文を機械的に得られる ASR 評価 corpus（VOICEVOX の台本、青空文庫の本文、CSJ・RWCP の公式転記）で CER を測る。Issue #2・#4・#6 を参照

上記の評価器コード（`GoldenCorpusEvaluation` の誤除外部分、`MacAmbientJevEvaluateSession`、`tools/evaluate-session.swift`、`tools/test-recording.swift`、`tools/test-corpus.swift`、manifest の annotation）は、`work/linux-asr-evaluation` を main にマージした後に削除する。ASR 評価 corpus 側は同じ型を使っているため、削除と同時に名前を ASR 評価用に改める。それまで既存のコードは残るが、出力する注釈系の指標を合否判定に使わない。

## 注釈なしで測る項目

- `scene_oscillation_count`: 観測された場面転換列で30秒以内に A→B→A と戻る短周期振動の件数。観測データが未提供なら `null`、明示的な空配列なら `0`
- `asr_rtf`: ASR real-time factor
- `peak_memory_mb`: 最大メモリ使用量
- `oldest_pending_age_ms`: 最古の未処理作業の滞留時間

RTF・メモリ・pending age は長時間試験で計測する。計測方法と閾値は `docs/v1-acceptance.md` と `docs/superpowers/specs/2026-09-24-v1-completion-execution-design.md` を参照する。
