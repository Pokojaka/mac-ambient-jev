# Qwen3-ASR ONNX CER 計測記録（2026-10-20）

## 結果と判定

製品候補の品質ゲートは、10件の corpus それぞれで求めた編集距離の合計を、各件の参照文字数の合計で割って計算した正規化 CER について、**PASS ⇔ ONNX 1.7B の CER ≤ Mac の CER + 2.00 percentage points** とする。参照文や認識文を corpus 全体で連結して編集距離を計算したものではない。音声や参照文の内容は本記録に含めない。

| 実行 | 正規化編集数 / 参照文字数 | 正規化 CER | raw 編集数 / 参照文字数 | raw CER | 判定 |
| --- | ---: | ---: | ---: | ---: | --- |
| Mac 基準 | 18 / 250 | 7.20% | 28 / 265 | 10.5660% | 基準 |
| Linux ONNX 1.7B | 17 / 250 | 6.80% | 18 / 265 | 6.7925% | **PASS**、Mac より −0.40 pt |
| Linux ONNX 0.6B | 30 / 250 | 12.00% | 32 / 265 | 12.0755% | 記録値のみ、1.7B ゲート対象外 |
| Colab `ja` | 3 / 250 | 1.20% | 4 / 265 | 1.5094% | prompt 実験、ゲート対象外 |
| Colab `Japanese` | 3 / 250 | 1.20% | 3 / 265 | 1.1321% | prompt 実験、ゲート対象外 |

Mac 基準からの上限は **9.20%**（7.20% + 2.00 pt）。Linux 1.7B の実測 6.80% はこの上限以下である。Windows 1.7B の品質判定は **PASS（導出、Windows corpus 未測定）** とする。これは2026-10-20に採用したユーザー判断であり、Linux 1.7B の corpus 結果と、固定 token fixture における Windows と Python ORT の parity（short 11/11、long 64/64、stop token を含む）を根拠として同じゲート判定を導いたもの。既存の [Windows ARM64 parity 記録](qwen3-asr-token-memory-2026-10-20.md#windows-arm64-vm2026-10-20) と [token reference metadata](../../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_token_reference.json) を参照。Linux aarch64 でも同じ固定 fixture は short 11/11、long 64/64 で Python ORT reference と一致した。

この parity fixture は **0.6B の short / long 固定入力だけ**であり、1.7B や本 corpus ではない。したがって Windows の判定は、1.7B / corpus の同一性を示す新たな実証ではない。Windows corpus はユーザー判断により実行せず、Windows の RTF / model-load も測定していない。いずれの結果も platform 間の一般的な bit identity を主張しない。

## 入力、評価法、機密性

- Corpus は10件、合計 **47.8401875 秒**。正規化参照文字数は250、raw 参照文字数は265。別途、私有録音から先頭180秒ずつ切り出した excerpt 3件（合計540秒）を Mac transcript との比較にのみ使った。excerpt はゲート対象ではない。
- 10 corpus 音声は VOICEVOX 0.25.2 の一回限りの合成・変換で作成し、FFmpeg 8.0 で24 kHzから16 kHz mono PCM16へ変換した。プラットフォーム間では同一の事前変換済み入力を使い、各プラットフォームでの再サンプリングはしていない。VOICEVOX engine image digest は `52bfd61345fe6896a3d0014e0efd1931f6d2f91f501f3c27181e7bce05b47d68`。
- 以下は manifest の数値と voice credit / style だけを転記した一覧。各行は別の voice character。

| Corpus ID | 秒 | VOICEVOX credit | Style |
| --- | ---: | --- | --- |
| `general-001` | 2.965375 | 四国めたん | ノーマル (2) |
| `security-001` | 5.664000 | ずんだもん | ノーマル (3) |
| `network-001` | 4.4906875 | 春日部つむぎ | ノーマル (8) |
| `statistics-001` | 3.5306875 | 雨晴はう | ノーマル (10) |
| `numbers-001` | 4.672000 | 波音リツ | ノーマル (9) |
| `english-001` | 4.384000 | 玄野武宏 | ノーマル (11) |
| `filler-001` | 3.1146875 | 白上虎太郎 | ふつう (12) |
| `question-001` | 3.5946875 | 青山龍星 | ノーマル (13) |
| `long-001` | 8.821375 | 冥鳴ひまり | ノーマル (14) |
| `proper-001` | 6.6026875 | 九州そら | ノーマル (16) |

- 計測用に生成した音声、tracked corpus から準備した参照文の作業用コピー、terms、query / metadata、生成 transcript、private excerpt transcript は ignored `.build` scratch 内に限る。10件の corpus reference 自体は tracked [`voicevox-ja-core-v1.json`](../../tools/corpora/voicevox-ja-core-v1.json) にある。本記録には音声、私有 excerpt の transcript text、録音元の path を掲載しない。excerpt は識別子と数値のみで報告する。
- Mac は `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`、`speech-swift` revision `c4c2fabbe825a9290c19e2f45d54ca3eae96b003` を使用。Linux 1.7B ONNX は `andrewleech/qwen3-asr-1.7b-onnx` commit `df916193ac67e59347769891a21e10d81d12acdd`、0.6B ONNX は `andrewleech/qwen3-asr-0.6b-onnx` commit `4fc24a1402e74db89c4d2ef256875e71680128c4` を使用。ONNX model の固定 file identity は [model manifest](../../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/qwen3_asr_models.json) にある。

## 実行環境と測定範囲

| 項目 | Mac | Linux ONNX |
| --- | --- | --- |
| Host / OS | Apple M4 Apple Silicon、10 CPU、16 GiB、macOS 27.0.1 arm64 | Mac と**同じ host 上の Docker**。別の bare-metal machine ではない |
| 実行環境 | Swift 6.4 debug、`MacAmbientJevProcessRecording` / `ProcessRecording`、`run_mac.sh` | `swift:6.2-noble` image ID `sha256:d6f8f6112e9a63da0a4a151d6b93acd16699d35c0b82531ac1a245f5af210197`、aarch64 Ubuntu noble / glibc 2.39、Linux 6.12.76-linuxkit、Swift 6.2.4 release、Python 3.12.3 |
| ASR / runtime | MLX。full app processing path | ONNX Runtime 1.31.0 CPU Execution Provider、release `MacAmbientJevTranscribeFile` |
| Thread / arena | speech-swift の実行設定 | intra-op 2、inter-op 1。ASR CPU memory arena disabled、Silero arena enabled |
| 資源情報 | host 10 CPU / 16 GiB | 測定時の割当は記録していない。記録作成時点の Docker 29.4.1 の割当は 10 CPU / 8,321,712,128 bytes（約7.75 GiB）。container に別の CPU / memory cap は付けていない |
| model mount | — | `/absolute/path/to/models:/models:ro`（読み取り専用） |

Linux container は同じ Mac host 上で動作したため、この比較は bare-metal OS 比較ではなく、Mac の製品処理と Linux container 内の portable CLI の比較である。Mac は mandatory diarization を含む full `ProcessRecording` を実行した。Linux は standalone Silero VAD + ASR file CLI であり、Mac と同じ full-session pipeline / diarization ではない。双方とも CER 用 artifact は全 transcript を改行結合した whole-audio envelope とした。

- Mac の `inference_seconds` は `metrics.asr.asrCallSeconds` のみ。VAD、diarization、保存等の処理時間ではない。
- Linux の `inference_seconds = segmentationSeconds + asrWallSeconds - modelLoadSeconds`。lazy VAD と persistence を含み、audio import / preflight、unload、JSON output を除く。両方の `model_load_seconds` は ASR `prepare()` のみ。
- 各 clip を fresh process で実行した。model load の変動（特に Linux 1.7B）は cache 状態を統制した比較ではなく、反復 benchmark も行っていない。RTF は集計で総 inference 秒 / 総音声秒とした。

## 正規化と corpus CER

評価は製品の `MacAmbientJevEvaluateASR` を使い、artifact schema 2 の whole-audio envelope を評価した。実装は [`ASREvaluation.swift`](../../app/MacAmbientJev/Sources/MacAmbientJevCore/ASREvaluation.swift) と [`JapaneseTextNormalizer.swift`](../../app/MacAmbientJev/Sources/MacAmbientJevCore/JapaneseTextNormalizer.swift)。normalizer version 1 は NFKC（compatibility precomposition）後に Unicode whitespace / newline と Unicode punctuation を除く。大文字・小文字や漢字・数字表記は正規化しない。各 CER は編集距離 / 参照文字数。総合値は clip ごとの百分率の平均ではなく、編集数と参照文字数を先に合算して求めた。

各セルは `編集数 / 参照文字数 (CER)`。分母は同じ正規化規則を使う全 run で共通。

| Corpus ID | Mac | Linux 1.7B | Linux 0.6B | prompt `ja` | prompt `Japanese` |
| --- | ---: | ---: | ---: | ---: | ---: |
| `general-001` | 0/16 (0.0000%) | 0/16 (0.0000%) | 0/16 (0.0000%) | 0/16 (0.0000%) | 0/16 (0.0000%) |
| `security-001` | 0/26 (0.0000%) | 1/26 (3.8462%) | 0/26 (0.0000%) | 1/26 (3.8462%) | 1/26 (3.8462%) |
| `network-001` | 0/27 (0.0000%) | 0/27 (0.0000%) | 7/27 (25.9259%) | 0/27 (0.0000%) | 0/27 (0.0000%) |
| `statistics-001` | 0/21 (0.0000%) | 0/21 (0.0000%) | 2/21 (9.5238%) | 0/21 (0.0000%) | 0/21 (0.0000%) |
| `numbers-001` | 14/21 (66.6667%) | 14/21 (66.6667%) | 14/21 (66.6667%) | 0/21 (0.0000%) | 0/21 (0.0000%) |
| `english-001` | 1/24 (4.1667%) | 0/24 (0.0000%) | 0/24 (0.0000%) | 0/24 (0.0000%) | 0/24 (0.0000%) |
| `filler-001` | 0/18 (0.0000%) | 0/18 (0.0000%) | 1/18 (5.5556%) | 0/18 (0.0000%) | 0/18 (0.0000%) |
| `question-001` | 0/22 (0.0000%) | 0/22 (0.0000%) | 4/22 (18.1818%) | 0/22 (0.0000%) | 0/22 (0.0000%) |
| `long-001` | 2/48 (4.1667%) | 2/48 (4.1667%) | 2/48 (4.1667%) | 2/48 (4.1667%) | 2/48 (4.1667%) |
| `proper-001` | 1/27 (3.7037%) | 0/27 (0.0000%) | 0/27 (0.0000%) | 0/27 (0.0000%) | 0/27 (0.0000%) |
| **全体（編集数合算 / 分母合算）** | **18/250 (7.2000%)** | **17/250 (6.8000%)** | **30/250 (12.0000%)** | **3/250 (1.2000%)** | **3/250 (1.2000%)** |

| Corpus ID | Mac raw | Linux 1.7B raw | Linux 0.6B raw | prompt `ja` raw | prompt `Japanese` raw |
| --- | ---: | ---: | ---: | ---: | ---: |
| `general-001` | 0/17 (0.0000%) | 0/17 (0.0000%) | 0/17 (0.0000%) | 0/17 (0.0000%) | 0/17 (0.0000%) |
| `security-001` | 0/27 (0.0000%) | 1/27 (3.7037%) | 0/27 (0.0000%) | 1/27 (3.7037%) | 1/27 (3.7037%) |
| `network-001` | 0/28 (0.0000%) | 0/28 (0.0000%) | 9/28 (32.1429%) | 0/28 (0.0000%) | 0/28 (0.0000%) |
| `statistics-001` | 0/22 (0.0000%) | 1/22 (4.5455%) | 2/22 (9.0909%) | 1/22 (4.5455%) | 0/22 (0.0000%) |
| `numbers-001` | 14/23 (60.8696%) | 14/23 (60.8696%) | 14/23 (60.8696%) | 0/23 (0.0000%) | 0/23 (0.0000%) |
| `english-001` | 9/25 (36.0000%) | 0/25 (0.0000%) | 0/25 (0.0000%) | 0/25 (0.0000%) | 0/25 (0.0000%) |
| `filler-001` | 0/20 (0.0000%) | 0/20 (0.0000%) | 1/20 (5.0000%) | 0/20 (0.0000%) | 0/20 (0.0000%) |
| `question-001` | 0/24 (0.0000%) | 0/24 (0.0000%) | 4/24 (16.6667%) | 0/24 (0.0000%) | 0/24 (0.0000%) |
| `long-001` | 2/51 (3.9216%) | 2/51 (3.9216%) | 2/51 (3.9216%) | 2/51 (3.9216%) | 2/51 (3.9216%) |
| `proper-001` | 3/28 (10.7143%) | 0/28 (0.0000%) | 0/28 (0.0000%) | 0/28 (0.0000%) | 0/28 (0.0000%) |
| **全体（編集数合算 / 分母合算）** | **28/265 (10.5660%)** | **18/265 (6.7925%)** | **32/265 (12.0755%)** | **4/265 (1.5094%)** | **3/265 (1.1321%)** |

## Corpus の RTF と ASR load

時間は秒、RTF は inference / 音声長。duration は各 run で共通。

| Corpus ID | 音声秒 | Mac RTF / load | Linux 1.7B RTF / load | Linux 0.6B RTF / load |
| --- | ---: | ---: | ---: | ---: |
| `general-001` | 2.965375 | 2.381747 / 2.068 | 1.854189 / 32.976 | 0.396117 / 6.919 |
| `security-001` | 5.664000 | 1.067979 / 1.754 | 0.897684 / 67.330 | 0.279330 / 5.600 |
| `network-001` | 4.4906875 | 1.305054 / 2.062 | 0.873722 / 19.724 | 0.333851 / 5.072 |
| `statistics-001` | 3.5306875 | 2.036460 / 1.721 | 0.941234 / 15.201 | 0.544439 / 5.118 |
| `numbers-001` | 4.672000 | 1.298983 / 1.841 | 0.858266 / 15.114 | 0.472083 / 5.808 |
| `english-001` | 4.384000 | 1.521377 / 1.766 | 0.821001 / 14.848 | 0.382558 / 5.380 |
| `filler-001` | 3.1146875 | 1.515676 / 1.787 | 0.965191 / 14.521 | 0.460327 / 5.389 |
| `question-001` | 3.5946875 | 1.348823 / 1.696 | 1.531894 / 15.596 | 0.566623 / 6.000 |
| `long-001` | 8.821375 | 0.776052 / 1.739 | 0.790423 / 16.459 | 0.361828 / 7.414 |
| `proper-001` | 6.6026875 | 0.852633 / 1.767 | 0.749802 / 16.702 | 0.411716 / 5.808 |
| **Corpus 全体** | **47.8401875** | **1.273950 / load 平均 1.820** | **0.958922 / load 平均 22.847** | **0.406390 / load 平均 5.851** |

| Run | 合計 inference / audio (秒) | 重み付き corpus RTF | ASR load min / mean / max (秒) |
| --- | ---: | ---: | ---: |
| Mac | 60.946028 / 47.8401875 | 1.273950 | 1.695701 / 1.820013 / 2.068052 |
| Linux 1.7B | 45.875021 / 47.8401875 | 0.958922 | 14.521167 / 22.847272 / 67.330086 |
| Linux 0.6B | 19.441790 / 47.8401875 | 0.406390 | 5.071936 / 5.850908 / 7.414217 |

Colab prompt artifact には model-load / per-clip runtime がなく、summary にもないため、RTF・load を付与していない。

## Private excerpt の Mac pseudo-reference 比較

下表は Mac transcript を pseudo-reference とした一致度で、ground truth ではない。CER は `1 − accuracy` と解釈できず、モデルの正解率として扱わない。3 clip は各180.0秒。文章は掲載せず、識別子、編集数、参照文字数、CER のみ記録する。

| Excerpt ID | 1.7B normalized edits / ref | 1.7B normalized CER | 1.7B raw edits / ref | 1.7B raw CER | 0.6B normalized edits / ref | 0.6B normalized CER | 0.6B raw edits / ref | 0.6B raw CER |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `excerpt-001` | 72/817 | 8.8127% | 83/888 | 9.3468% | 97/817 | 11.8727% | 124/888 | 13.9640% |
| `excerpt-002` | 71/927 | 7.6591% | 89/985 | 9.0355% | 171/927 | 18.4466% | 197/985 | 20.0000% |
| `excerpt-003` | 27/667 | 4.0480% | 39/724 | 5.3867% | 101/667 | 15.1424% | 125/724 | 17.2652% |
| **合計** | **170/2411** | **7.0510%** | **211/2597** | **8.1248%** | **369/2411** | **15.3049%** | **446/2597** | **17.1737%** |

excerpt 速度も summary の値を記録する。RTF は clip ごと、load は ASR model load 秒。

| Excerpt ID | 音声秒 | Mac RTF / load | Linux 1.7B RTF / load | Linux 0.6B RTF / load |
| --- | ---: | ---: | ---: | ---: |
| `excerpt-001` | 180.0 | 0.324139 / 1.748 | 0.686445 / 16.695 | 0.344327 / 5.658 |
| `excerpt-002` | 180.0 | 0.357949 / 1.792 | 0.546691 / 15.379 | 0.349588 / 6.949 |
| `excerpt-003` | 180.0 | 0.348675 / 2.144 | 0.508993 / 16.300 | 0.280519 / 6.929 |
| **540秒の重み付き RTF / load min / mean / max** | **540.0** | **0.343588 / 1.747666 / 1.894384 / 2.143578** | **0.580709 / 15.378795 / 16.124623 / 16.694892** | **0.324811 / 5.658413 / 6.512341 / 6.949278** |

## Colab prompt 実験（製品外）

これは **Google Colab x86_64 CPU VM** で完了した全 WAV 推論であり、Mac host や local Docker の推論ではない。Qwen3-ASR 1.7B int4 の同じ pinned commit `df916193ac67e59347769891a21e10d81d12acdd` を使い、製品の VAD / diarization segmentation は通していない。

- 実行環境: Python 3.12.3、NumPy 2.2.6、Transformers 4.57.1、tokenizers 0.22.2、ONNX Runtime 1.31.0 CPUExecutionProvider、intra-op 2 / inter-op 1、CPU arena enabled。モデルは hidden size 2048 の `andrewleech/qwen3-asr-1.7b-onnx`。
- 言語 tag は `ja`（token IDs `11528, 11937`）と `Japanese`（`11528, 10769`）。各 run は明示した10 corpus WAV を全体として処理した。
- 保存済み JSON の `clips[].text` を converter が文字列としてそのまま artifact 化し、製品 evaluator に渡した。再推論、token の再 decode、evaluator 前の追加正規化はしていない。両 tag 間の生成 text は10件中9件で完全一致した。残る `statistics-001` では `ja` が参照文にない読点を1個多く出力し、それ以外は同じだった。
- 両 tag の正規化 CER は3/250 = 1.20%。raw CER は `ja` が4/265 = 1.5094%、`Japanese` が3/265 = 1.1321%。normalized score は同じ。
- 保存ログの約154秒（`ja`）/145秒（`Japanese`）は model load、hash / setup を含む生成全体の wall elapsed で、inference-only 秒ではない。model load time と clip ごとの RTF は**利用可能な値なし**。推定値は作らない。

この prompt score と製品 pipeline score の差から tag の効果は分離できない。全 WAV と製品 VAD segmentation の違い、および CPU VM と製品実行環境の違いが交絡する。prompt 実験を理由とした製品変更は行っていない。

prompt 実験と製品 pipeline の差（3/250 対 17〜18/250）の大半は `numbers-001` の1件（14/21）である。Mac MLX、Linux ONNX 1.7B、0.6B はいずれも数字を漢数字で出力し、Colab の全 WAV 推論は算用数字で出力した。normalizer は漢数字と算用数字を同一視しないため、この差は聞き取りの誤りではなく表記の違いとして計上されている。`numbers-001` を除くと Mac は4/229、Linux 1.7B は3/229、Colab は両 tag とも3/229 である。engine の異なる Mac と Linux が同じ表記になる原因は本記録では特定していない。

## 再現手順と記録範囲

以下の `.build/qwen3-asr-cer/` 配下の script（`prepare_inputs.py`、`run_mac.sh`、`run_platform.py`、`run_prompt.py`、`score.py` とその tests）は git 管理外の作業用 script であり、リポジトリには含まれない。そのため、この手順はリポジトリだけからは再実行できない。測定時に実行した手順として記録する。元 JSON / logs も同じ管理外 directory に置く。

### 入力準備と実測 runner

入力がすでに揃っている場合、再変換しない。入力がない場合に限る音声準備コマンド:

```bash
python3 .build/qwen3-asr-cer/prepare_inputs.py --base-url http://127.0.0.1:50021
```

過去の Mac 実測は debug build の `ProcessRecording` を使い、次の手順で実行した。

```bash
bash .build/qwen3-asr-cer/run_mac.sh
```

Linux は `/src` に worktree を mount した container 内で release CLI を build し、次の runner 引数で測定した。これは再実行命令ではなく、記録された実行手順である。`p32-j6b-runner` container は停止済みで、今回 restart していない。

```bash
# 作業ディレクトリ /src
swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevTranscribeFile
python3 -B .build/qwen3-asr-cer/run_platform.py onnx \
  --binary /src/app/MacAmbientJev/.build/aarch64-unknown-linux-gnu/release/MacAmbientJevTranscribeFile \
  --platform linux --sizes 1.7b 0.6b --threads 2 \
  --models-root /models \
  --silero-model /src/.build/silero-vad/5cd7945676eb32225748052e2e6a0580e4686a08/silero_vad_16k_op15.onnx
```

Model mount は読み取り専用。runner は clip ごとに fresh child process を開始する。

### 保存済み Colab 結果の変換と scoring

`run_prompt.py` は Colab の保存済み JSON を読む**変換だけ**であり、model を推論しない。実行は両方の既存出力から `ja` / `Japanese` artifacts を作る。destination directory が既にあれば converter は拒否するため、**既存 prompt root を削除してから実行する手順ではない**。出力が既に存在する場合は再変換不要。

```bash
python3 -B .build/qwen3-asr-cer/run_prompt.py
```

全5 run の score と gate は製品 evaluator で算出する。

```bash
python3 -B .build/qwen3-asr-cer/score.py \
  --evaluator app/MacAmbientJev/.build/out/Products/Debug/MacAmbientJevEvaluateASR \
  --runs mac linux/1.7b linux/0.6b prompt/ja prompt/Japanese \
  --output .build/qwen3-asr-cer/summary.json
```

Scorer は保存済み全 artifact を先に検証し、所有権と実 path を確認した自分専用の `scores` directory だけを reset する。raw transcript / run logs は変更しない。excerpt 比較の pseudo-reference は scorer が `scores` 内に作る。

Colab の generator は `/content/venv312/bin/python /content/repo/scripts/generate_qwen3_asr_token_reference.py` を使い、`--model-size 1.7b`、明示した10件 corpus manifest、`--language-tag`、pinned model directory、`--output /content/repo/out-${tag}.json` を渡した。実行時の絶対 model / manifest path は保存ログに残っていないため、変数で示す。

```bash
for tag in ja Japanese; do
  /content/venv312/bin/python /content/repo/scripts/generate_qwen3_asr_token_reference.py \
    --model-size 1.7b \
    --audio-manifest "${COLAB_AUDIO_MANIFEST:?set explicit 10-corpus manifest}" \
    --language-tag "$tag" \
    --model-directory "${COLAB_MODEL_DIRECTORY:?set pinned 1.7b model directory}" \
    --output "/content/repo/out-${tag}.json"
done
```

保存結果の model commit、file hashes、x86_64 / package metadata は converter により pinned manifest と照合されている。prompt outputs は同一の manifest corpus WAV の SHA-256 と sample count に結び付いている。

### 検証と参照

token-reference tests 43件と、管理外の `.build/qwen3-asr-cer` Python tests 48件は pass。`python3 scripts/check_doc_references.py` は pass。この checker は `docs/records` を対象外とするため、記録内のローカル参照先は既存ファイルと手動で照合した。Swift full build と test はともに exit 0。9つの Swift Testing run summary は順に32、7、202、4、454、37、7、54、44 tests（合計841件）を報告した。test 実行では `RUN_MODEL_TESTS` を unset し、corpus inference は再実行していない。

```bash
python3 -B scripts/test_generate_qwen3_asr_token_reference.py
python3 -B -m unittest discover -s .build/qwen3-asr-cer -p 'test_*.py'
python3 scripts/check_doc_references.py
swift build --package-path app/MacAmbientJev --scratch-path .build/qwen3-asr-cer/mac-build --disable-automatic-resolution --jobs 2
env -u RUN_MODEL_TESTS swift test --package-path app/MacAmbientJev --scratch-path .build/qwen3-asr-cer/mac-build --disable-automatic-resolution --jobs 2
git diff --check
```

外部仕様・実装参照: ONNX Runtime [v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0) と [Python API summary](https://onnxruntime.ai/docs/api/python/api_summary.html)、tokenizers [v0.22.2 API](https://huggingface.co/docs/tokenizers/v0.22.2/api/tokenizer)、Qwen3-ASR [upstream inference source](https://raw.githubusercontent.com/QwenLM/Qwen3-ASR/main/qwen_asr/inference/qwen3_asr.py)。Windows / Linux の既存 CLI 手順は [Windows / Linux docs](../windows.md) を参照。
