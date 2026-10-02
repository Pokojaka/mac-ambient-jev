# Nemotron 3 話者認識テスト（2026-09-27）

## 実行条件

- 実装: [NVIDIA NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp)、commit `97a15afa5caa9bce5baaa86c1184103877af4101`。
- モデル: [nvidia/Nemotron-3-Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization)、revision `f667ed73aee57d40cc39428eb768b4fd87a0a29e`、GGUF `q8_0`。モデルファイルの SHA-256 は `08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1`。
- 実行環境: Apple M4、16 GiB、Metal バックエンド。NeMo-Speech.cpp の `metal-diar` プリセットでビルド。CMake 4.1.1 と同梱ビルド手順の SentencePiece の互換性問題は、SentencePiece の設定に `CMAKE_POLICY_VERSION_MINIMUM=3.5` を指定して解消した。
- 8 分音声と 5 分音声は既定の V3 streaming、41.5 秒音声は `--preset v3-offline` で実行した。出力形式は JSON。

## 結果

| 音声 | 話者 ID | 検出された話者交代 | 判定 |
| --- | --- | --- | --- |
| A→B→A→B、480 秒 | `1→2→1→2` | 3 回 | 既知の 3 境界をすべて検出。余分な話者交代なし。 |
| 『ごん狐』冒頭 300 秒、単一話者 | `1` | 0 回 | 55 発話区間のすべてが同じ ID。 |
| A→B 間に 1.5 秒の無音、41.5 秒 | `1→2` | 1 回 | 無音を挟む 20.069–21.641 秒で交代。 |

8 分音声の 67 発話区間には話者 ID `1` と `2` のみが現れた。既知の接続点は 120、240、360 秒。隣接する異なる話者区間の終端と始端の中点を検出時刻として、誤差を計算した。

| 接続点 | 前話者の終端 | 次話者の始端 | 検出時刻 | 絶対誤差 |
| ---: | ---: | ---: | ---: | ---: |
| 120.000 秒 | 120.089 秒 | 120.151 秒 | 120.120 秒 | 0.120 秒 |
| 240.000 秒 | 239.999 秒 | 239.741 秒 | 239.870 秒 | 0.130 秒 |
| 360.000 秒 | 360.089 秒 | 359.901 秒 | 359.995 秒 | 0.005 秒 |

2、3 番目の境界では隣接話者の区間が約 0.26 秒、0.19 秒重複する。中点は便宜的な代表時刻であり、重複がない一意の境界をモデルが出したという意味ではない。

既存アプリの保存済み評価出力でも 8 分音声の 4 ブロックの主話者は `S1→S2→S1→S2` だった。NeMo は同じ話者 ID の再出現を保ちながら、3 接続点近くに話者区間を配置した。アプリの出力は文字起こし区間に紐付く span であり、NeMo の発話区間とは粒度が違うため、この結果だけで優劣を断定しない。

## 入力と再現

入力音声の作成方法と元音源は [朗読音声の評価素材](aozora-audio-fixtures-2026-09-25.md) を参照。

| 入力 | SHA-256 | ローカル出力 |
| --- | --- | --- |
| `/private/tmp/mac-ambient-jev-two-readers-abab.wav` | `a31927a8d9e6ef5c01aa6c9df68ea622c4b9bfe3ea5620b5204f23fec23c39dd` | `/private/tmp/nemotron3-abab.json` |
| `/private/tmp/mac-ambient-jev-gongitsune-5m.wav` | `c2dec92204d9b4a40258b330b7ac830ee87342565cacedf3e06e51abca732654` | `/private/tmp/nemotron3-gongitsune-5m.json` |
| `/private/tmp/mac-ambient-jev-ab-boundary-with-silence.wav` | `b9f490344a696770630bf1749de965f2659d472c22f7638e0b87bf234d632645` | `/private/tmp/nemotron3-ab-silence-offline.json` |

実行例（モデルの取得とバイナリのビルド後）:

```sh
nemo-speech diarize /private/tmp/mac-ambient-jev-two-readers-abab.wav --device metal --format json --output /private/tmp/nemotron3-abab.json
```

## 評価の制限

A→B→A→B 音声は異なる朗読音源の切り貼りであり、自然な会話、重なり発話、騒音、短い相づちは検証していない。『ごん狐』も正解話者区間を全時刻に付与した素材ではない。したがって、このテストから DER（diarization error rate）は算出しない。発話区間外の無音、語単位の話者割当て、ライブ処理の遅延も評価対象外。
