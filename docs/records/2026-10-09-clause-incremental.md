# ライブ節イベント増分更新の計測

## 条件

- 実施日: 2026-10-09。
- macOS 27.0.1（26A434）、arm64、SwiftPM debug 構成。
- [LiveClauseIncrementalBenchmark.swift](../../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveClauseIncrementalBenchmark.swift) を使用。
- 一時ディレクトリの実 PCM、SessionWriter、注入 ASR で 40・400・2500 区間の LiveASRSession を用意する。実モデル・Jev HTTP・Keychain・UserDefaults・音声デバイス・GUI・利用者の保存済みセッションを使わない。
- 変更前の比較対象はテスト専用 actor に再現した、全イベントの結合 → TranscriptMaterializer の全履歴 materialization → snapshot 公開。変更後は実 LiveASRSession.applyClauseEvents。旧コミットを別プロセスで実行した数値ではない。
- 各規模で先行区間の境界・節を登録した後、末尾 21 区間について境界イベント・節閉鎖イベント・優先度保留イベントの 3 件を一 batch で反映する。warmup 1 回を除外し、20 回を計測する。全履歴側と増分側で source とイベント履歴を同一にし、各 snapshot の完全一致を計測区間外で検証する。
- ContinuousClock による経過時間。中央値はソート後の index 10、p90 は index 17。音声・イベント fixture の作成、ASR、正しさの照合は計測区間外。イベントのディスク append・HTTP・実画面描画の遅延を含まない。

```bash
RUN_MODEL_TESTS=0 RUN_KEYCHAIN_TESTS=0 CLAUSE_INCREMENTAL_BENCHMARK=1 \
  swift test --package-path app/MacAmbientJev --disable-automatic-resolution \
  --filter liveClauseIncrementalBenchmark
```

## 結果

単位は µs、各行 20 標本。

| 区間数 | 全履歴 中央値 | 全履歴 p90 | 全履歴 min–max | 増分 中央値 | 増分 p90 | 増分 min–max | 中央値比 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 40 | 2209.208 | 2392.750 | 1857.792–2471.041 | 60.375 | 77.167 | 56.041–160.917 | 36.59× |
| 400 | 22848.625 | 23461.750 | 22117.291–23890.708 | 81.917 | 114.333 | 58.417–662.292 | 278.92× |
| 2500 | 144967.541 | 147079.500 | 141997.208–152467.709 | 152.542 | 181.375 | 114.458–239.084 | 950.35× |

2500 区間では、中央値が **144.968 ms → 0.153 ms**、p90 が **147.080 ms → 0.181 ms**。全 snapshot の同一性検証は成功し、benchmark は exit 0。

## 解釈と限界

増分側は source/reference 索引と継続 cursor を保持し、batch が触る行だけを再構築する。rollback は変更項目の journal、開いた長い末尾は immutable link を使うため、更新のたびに全履歴の索引・末尾をコピーしない。通常の全履歴 materialization は保存済み再読込みの正しさの基準として残る。

保存する原文・イベント・行・節と索引は履歴長に比例する。総メモリが一定であることや、全操作が定数時間であることはこの結果から主張しない。古い snapshot を保持した場合の配列 copy-on-write、配列の容量拡張、時間順外の挿入、長い跨ぎ節に実際に含まれる全行の更新は履歴または節の長さに比例し得る。この計測は RSS・phys_footprint・実 GUI の保持する snapshot 数を測っていない。

単一機器の debug 標本であり、実 Jev の待ち時間・モデル推論・GUI の体感速度の保証ではない。通常テストは時間閾値で失敗させない。別の回帰検証で 257 区間の跨ぎ節、空区間、ASR gap、LOW と保留、invalid batch の rollback、取得済み snapshot の不変性を確認する。
