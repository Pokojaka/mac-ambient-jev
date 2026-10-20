# 授業文字起こしを想定した ASR 比較（2026-10-16）

## 入力と評価条件

- 基準コード: `330c623`。MacBook Air M4、16 GB。アプリのシステム音声モードで、[対象動画](https://www.youtube.com/watch?v=T-jKleBEeM4)の冒頭 5 分 38 秒を原速再生して録音した。全編 42 分 12 秒の評価ではない。
- 保存音声は 16 kHz mono float32、347.78675 秒。開始・停止時の余白を含む。保存 checkpoint を連結した `capture.f32le` の SHA-256 は `1d7ca5714c06745b97374a3d7be662edae8bb2855be91e4b60ee2e8ce180205d`。音声欠落は frame 1715712 から 684 frames（42.75 ms）、`missingCallback` の 1 回。
- ブラウザーの字幕 export で日本語字幕を取得。字幕 metadata は `authored or unspecified`。話者略号を除き、録音終端で参照文を切った。参照文は raw 2852 文字、正規化後 2427 文字。SHA-256 は `0ebfeea8f7cd4fc6d316a2987e01bdd2e01566a82ef5c5eb68b8b2bcc2eafa2a`。
- 字幕は発声された「ラージ A」「スモール a」を記号にするなど編集されている。以下の CER は**字幕との文字差**であり、独立した聴取による逐語正解への誤り率ではない。全条件を同じ参照文で比較した。
- 音声・字幕・認識原文・実験 harness・結果 JSON・ログは非追跡の `test-data/recordings/local/youtube-T-jKleBEeM4-20261016/` に保持。字幕・タイトル・正解専門語を認識モデルへ入力していない。F 除去・LOW 除去後の表示文は採点せず、ASR 原文を使う。

## モデルと再現性

- `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`、affine 8-bit、group size 64。重み SHA-256 は `bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c`。
- `speech-swift@c4c2fabbe825a9290c19e2f45d54ca3eae96b003`、MLX Swift 0.31.6。greedy、最大 448 tokens。通常は language=`ja`、context なし。
- 保存済みライブ 26 区間を同じ float32 音声で再推論すると、26 区間すべてで原文が一致した。
- 採点には本リポジトリの `CharacterErrorRate`、`JapaneseTextNormalizer`、`ASREvaluation` を使用。normalizer version 1（NFKC、空白・句読点除去）。

## 話者分割だけを変えた比較

現行確定処理の 48 区間をイベントの正確な source frame で取り出し、`_turn_` 子区間を同じ親 VAD 区間へ戻した 26 区間と比較した。両条件の入力は同じ `capture.f32le`、同じモデル・言語・デコード設定で、入力 sample 総数も 5,383,744 で一致する。48 区間のうち 18 区間は 5 秒未満、最短は約 0.796 秒だった。

| 条件 | 区間数 | 正規化 CER | 置換 | 削除 | 挿入 | raw CER |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 話者交代で細分化 | 48 | 21.5904% | 191 | 174 | 159 | 28.6115% |
| 親 VAD 区間を保持 | 26 | 20.0659% | 172 | 157 | 158 | 27.4544% |

正規化後の編集数は 524 から 487 へ 37 減少（1.5245 ポイント）。親 VAD 区間では「入職者」が「入植者」、「交差」「講座」が「交雑」になる例があった。一方、「潜性遺伝子」など専門語の誤認識は残っており、解消したとは扱わない。

区間ごとの warm 推論時間の合計は 109.05 秒と 101.78 秒。モデル準備・VAD・話者分離を含まず、一回ずつの実行なので速度の保証値にはしない。16-bit WAV を経由した現行確定パイプラインの値は 21.8789% で、上の同一 float32 比較とは分けた。

話者交代で音声を短く切る影響を示す一録音での結果である。講義中の相づち・質問にも同じ切断処理は作用するが、授業全般で同じ改善幅になることを示した評価ではない。話者ごとの正確な本文時刻の評価も行っていない。

## 採用根拠にしなかった条件

以下は元のライブ 26 区間を基準にした同一録音の比較。長時間条件では 15 秒超の依存側 adaptive n-gram 制限を無効化し、長さの影響と混ぜなかった。

| 条件 | 正規化 CER |
| --- | ---: |
| 現行ライブ（ja） | 20.0659% |
| 言語名を Japanese だけに変更 | 20.1483% |
| 隣接する元区間を二つずつ結合 | 19.2419% |
| 過去認識文の末尾 200 文字を context に渡す | 29.0894% |
| 静音切断の最大長を 20 秒へ変更 | 21.0548% |
| 同 28 秒 | 19.9423% |
| 同 40 秒 | 20.1483% |
| 同じ重みを Python mlx-audio / HF 前処理で推論 | 20.4368% |
| Swift モデルで前処理だけ 400 点 FFT へ変更 | 20.8076% |

隣接二つの結合と、一般の 28 秒窓は同じ区間ではない。結合の値だけから 28 秒化を選ばない。言語名変更・過去認識文 context・前処理変更も、この録音の精度改善として採用する根拠にはならなかった。実験用の依存ソース変更は復元した。

## 一次資料との照合

[Qwen 公式 processor](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/core/transformers_backend/processing_qwen3_asr.py)は Hugging Face の WhisperFeatureExtractor を使う。[HF の前処理](https://github.com/huggingface/transformers/blob/main/src/transformers/models/whisper/feature_extraction_whisper.py)は 400 点 FFT・201 周波数 bin。[固定した Swift 実装](https://github.com/soniqo/speech-swift/blob/c4c2fabbe825a9290c19e2f45d54ca3eae96b003/Sources/Qwen3ASR/AudioPreprocessing.swift)は 400 点窓を 512 点へ zero pad し、512 点 grid の mel bank を使う。この仕様差を見つけたが、前処理だけを変更した上記実測では改善しなかった。

[Qwen 公式推論](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py)の日本語名は `Japanese`。Swift 側は文字列をそのままプロンプトへ渡している。言語名の不一致はソース上の問題として区別し、その修正だけで認識精度が上がるとはしない。

## ひらがな読みでの補助評価

読み変換の識別子は cf-ja-reading-v2。同じ参照文と認識原文を、macOS 27.0.1（26A434）の `CFStringTokenizer`、locale `ja` により読みへ変換し、Latin transcription をひらがなへ変換した。NFKC 後の `%` は「パーセント」へ、数字列は日本語の NumberFormatter spellOut で漢数字へそろえ、読みの取得後に既存 normalizer version 1 で空白・句読点を除いた。英字記号は大文字・小文字を含め保持する。長音は OS の読み変換による表現で統一される。辞書で読みが得られない日本語はエラーとし、黙って別方式に置き換えない。

「聾者／老者」→「ろうしゃ」、「潜性／先生」→「せんせい」、「入植者／入職者」→「にゅうしょくしゃ」、「150人／百五十人」→「ひゃくごじゅうにん」、「10%／十パーセント」→「じゅうぱあせんと」の固定例を検証した。変換後の全文、保持した英字の一覧、スコアは local ディレクトリの `*-kana.json`、`kana-scores.json`、実行ソースは `kana-score.swift` に保持した。読み参照は 2965 文字。

| 条件 | 漢字を含む正規化 CER | 読み CER |
| --- | ---: | ---: |
| 話者交代で細分化、同一 float32 | 21.5904% | 14.3002% |
| 親 VAD 区間を保持、同一 float32 | 20.0659% | 13.0523% |
| 言語名 Japanese のみ | 20.1483% | 13.0185% |
| 隣接する元区間を二つずつ結合 | 19.2419% | 12.6476% |
| 過去認識文 context | 29.0894% | 20.5059% |
| 20 秒の静音切断 | 21.0548% | 13.7605% |
| 28 秒の静音切断 | 19.9423% | 13.4570% |
| 40 秒の静音切断 | 20.1483% | 13.0860% |
| Swift 前処理だけ 400 点 FFT | 20.8076% | 13.1197% |

話者分割を外す変更は読みでも 1.2479 ポイント改善した。漢字表記だけの改善ではない。一方、同音異義語の意味の誤りは読み CER では見えなくなる。「入植者／入職者」の改善もこの指標では評価できない。字幕の A/a/AA という編集と発声「ラージ A／スモール a」の違い、OS 辞書の読み推定誤りも残る。読み CER は補助値として、漢字を含む値と併記する。

## 長文音声での追加比較と反映内容

元のライブ先頭から末尾まで約 336.5 秒の連続音声を一回で認識し、短い区間への分割を完全に外した。language=`ja`、maxTokens=8192、15 秒超の adaptive n-gram 制限は無効、同じモデル・float32 音声を使った。字幕・過去の認識文は入力していない。

- 漢字を含む正規化 CER: 19.3655%（置換160・削除126・挿入184）。
- 読み CER: 13.3895%（置換106・削除120・挿入171）。
- warm 推論: 167.76 秒、準備を含むテスト全体169.70秒。

漢字を含む値は親 VAD 区間より下がったが、読みは13.0523%から悪化した。長文化を精度改善として製品に採用する根拠にはしない。

製品には、確定 ASR へ親 VAD 区間を保って渡す変更を反映した。詳細な話者 span と既存の80%見出し規則を保持する。言語名はモデルの support_languages にある `Japanese` にそろえ、実モデルの integration test で照合する。言語名だけを変えた比較は漢字20.1483%・読み13.0185%であり、精度差が大きいとは扱わない。

## 更新後の共通確定パイプライン

更新した `MacAmbientJevProcessRecording` で、同じ capture.wav を `--keep-session` と明示した `--sessions-root` で全量処理した。VAD・話者分離・ASR が成功し、26区間・finalization complete となった。保存イベントの実 ASR provenance は `language=Japanese`。Core ML の発話文判定は CLI の規定どおり無効で、ASR 原文だけを比較する。

比較前後のセッション内 original.wav は、ともに SHA-256 `001a6a06762e1d5fc83e4976f7b537f42bb5714566e252db26da71a3cec60612` で一致した。前後とも同じ16-bit WAV を入力した共通パイプラインの比較であり、上記の同一float32による話者分割だけの切り分けとは区別する。

| 実処理 | 区間数 | 漢字を含む正規化 CER | 置換・削除・挿入 | 読み CER | 読みの置換・削除・挿入 |
| --- | ---: | ---: | --- | ---: | --- |
| 変更前 | 48 | 21.8789% | 197・173・161 | 14.4688% | 111・173・145 |
| VAD区間保持 + Japanese指定 | 26 | 19.8187% | 179・144・158 | 12.6476% | 98・132・145 |

漢字を含む値は2.0602ポイント、読みは1.8212ポイント下がった。字幕の記号編集や自動読み変換の限界を含むため、逐語正解への誤り率としては扱わない。結果は `final-improved-segments.json`、`pipeline-ab-scores.json` と保持したセッションに保存した。

## 検証

以下を実行し成功した。FLAC の AudioConverter と Metal GPU の検証は sandbox 外の承認済み実行を使用した。

- `python3 -B scripts/check_portable_core.py`
- `python3 scripts/check_doc_references.py`
- `swift build --package-path app/MacAmbientJev`
- `swift test --package-path app/MacAmbientJev`
- `bash scripts/verify_v1.sh`（アプリの release build、署名、同梱モデル・shader、CLI 検証を含む）
- 今回の音声から切り出した14秒弱の WAV で `RUN_MODEL_TESTS=1` の ASRIntegrationTests を実行。モデル定義の言語名との照合と実認識が成功した。SwiftPM の単体実行では、同じビルド済みアプリの MLX shader を一時的にテスト実行ファイル横へ置いた。

Mac のロック解除後、更新したアプリを起動し、2026年10月16日0:42のシステム音声録音を「保存済み録音」から再処理した。GUIでも26区間での完了、Speaker 1 / Speaker 2 の併記、書き出し成功を確認した。録音元はシステム音声へ戻し、改善後の結果を表示した。上の数値比較は、同一WAVを用いたCLIのASR原文を対象とし、GUIのF・LOW除去後の表示文を採点した値ではない。
