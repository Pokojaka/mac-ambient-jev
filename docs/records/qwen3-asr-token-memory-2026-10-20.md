# Qwen3-ASR token parity と複数回推論 RSS 記録（2026-10-20 JST）

## 要約

0.6b Qwen3-ASR の short / long fixture について、独立 Python reference fixture の再生成と Swift release engine の token parity を確認した。ONNX Runtime の CPU memory arena 有効・無効の両設定で生成 token ID（stop token を含む）と text が一致した。別々の fresh process で長い fixture を50回認識した Linux aarch64 測定では、無効設定の warm RSS が有効設定より低く、実行時間もこの一回の測定では短かった。これを根拠に、Qwen3-ASR の3 session だけ CPU memory arena disabled を固定採用する。実行時 selector や実験経路は設けない。

これは固定 fixture と50回の測定であり、任意の入力を長時間処理した場合や Windows 上のメモリ安定性を保証しない。Windows の benchmark API はこの記録時点で Windows 上で compile / run していない。1.7b は測定していない。

## provenance

- Worktree base commit: `795c760`（測定時は uncommitted changes を含む）。
- Linux: `linux/aarch64`、`swift:6.2-noble` image digest `sha256:d6f8f6112e9a63da0a4a151d6b93acd16699d35c0b82531ac1a245f5af210197`、Swift 6.2.4、ONNX Runtime 1.31.0、Docker resource limit 10 CPUs / 7.75 GiB。
- Model: `andrewleech/qwen3-asr-0.6b-onnx` commit `4fc24a1402e74db89c4d2ef256875e71680128c4`、int4 decoder。directory は read-only で container に mount した。
- 独立 Python reference は Python 3.12.3、NumPy 2.2.6、Transformers 4.57.1、tokenizers 0.22.2、ONNX Runtime 1.31.0 を使用。CPUExecutionProvider、CPU arena enabled、intra-op 2 / inter-op 1。venv は Docker 内 `/tmp` に作成し、model は read-only mount のままにした。
- [`qwen3_asr_token_reference.json`](../../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_token_reference.json) の reference metadata は `platform=Linux`、`architecture=aarch64`、`intra_op_threads=2`、`inter_op_threads=1`。fixture update では `platform` と `architecture` のみを追加し、clips、model provenance / files、package metadata と version は変更していない。

| model file | bytes | SHA-256 |
| --- | ---: | --- |
| `encoder.onnx` | 745,762,694 | `3c027f880f677615de85e1f6934906e1d5d77624b724096d33accef99c753eed` |
| `decoder_init.int4.onnx` | 355,390 | `6d54633bbb9e6b1ecf372f218d04adb3bf6f2bfc442ce55c988526d532896faa` |
| `decoder_step.int4.onnx` | 354,888 | `7eaa4f31d5eb6ae2937ff45222c32f692f2d5ac29b46cbae9046da332a9f317d` |
| `decoder_weights.int4.data` | 962,460,672 | `d68cd1c0695a7ba42651d06b1bc1158e2e58af5f9adbb6dba874fbbb8a4f22cf` |
| `embed_tokens.bin` | 311,164,928 | `e80150119fa5f7e56e85aed64c3a02d5c78eb7a37cfdcb973d0987316f15bee2` |
| `tokenizer.json` | 11,429,377 | `bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92` |

| fixture | samples | WAV SHA-256 |
| --- | ---: | --- |
| short | 52,907 | `2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9` |
| long | 295,424 | `d50f7f2a1fe9665279689e53297772aeb52c43d9068c82ab21b21fa62cac78b2` |

参照 JSON には、インストール済み全 distribution の version、生成 ID、text、model/WAV の provenance を記録する。

## 実モデル test の first / repeat baseline

以下は living docs から移した既存 baseline measurements で、記載済みの測定条件は Linux aarch64、`swift:6.2-noble`、Swift 6.2.4、ONNX Runtime 1.31.0、0.6b、intra-op 2 threads、release build。elapsed は `prepare()` 後の `transcribe()` のみで、準備時間を含まない。

| fixture | CER (上限) | first elapsed / RTF | repeat elapsed / RTF |
| --- | ---: | ---: | ---: |
| short | 0 (0.05) | 1.343336459 秒 / 0.4062483857 | 1.638131459 秒 / 0.4953995378 |
| long | 0.08791208791208792 (0.15) | 7.885876129 秒 / 0.4270946777 | 7.837488004 秒 / 0.4244740037 |

short の認識文は参照文「今日は音声認識の動作を確認します。」と一致した。long の認識文は「通信アイテムを認証した後、セッション鍵を共有し、その鍵を使って以降の通信内容を暗号化する流れを考えます。今日の講義ではベース推定について説明します。この場合、公開鍵はどこで配布されるのでしょうか。」だった。

## parity

Linux aarch64、Swift 6.2.4 release engine（intra-op 2 / inter-op 1）で各 arena mode を別々の fresh process で実行し、その mode の複数回 RSS benchmark より先に `ONNXQwen3ASRModelTests` の実モデル test を実行した。short は11/11、long は64/64の token ID が一致し、どちらも stop ID `151645` を含む。両 fixture の text も一致し、step ごとの不一致はなかった。既存 CER は short 0、long 8/91 = 0.08791208791208792 のままで、両 mode 同一だった。ここでの parity はこの固定 fixture と記載環境での token / text 比較であり、任意の platform への保証でも mel または logits の bit identity でもない。

## repeated-call RSS benchmark

各 mode は parity test と分けた fresh process で測定した。engine は一度だけ prepare し、18.464秒 / 295,424 sample の long WAV を連続50回 `transcribe` した。各呼び出しの text は一致した。trim、allocator flush、RSS 調整は行っていない。arena 有効 run を先に、無効 run を後に逐次実行した。両 build で同じ release 設定・model・入力・thread 数を使い、3つの Qwen session の arena 設定だけを変えた。

arena enabled の測定は、wrapper に必須の `cpuMemoryArenaEnabled` bool を追加する前の source state で生成したため、ONNX Runtime 1.31.0 の既定 arena 有効を使った（[`SessionOptions` header](https://raw.githubusercontent.com/microsoft/onnxruntime/v1.31.0/onnxruntime/core/framework/session_options.h) の `enable_cpu_mem_arena = true`、[v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)）。現行 API で `true` を明示する動作はこの default と同じである。arena disabled の測定では encoder、decoder_init、decoder_step の各 session options に `DisableCpuMemArena` を `CreateSession` 前に適用した。engine / model / constructor に runtime toggle はなく、この比較は異なる compile-time source state の build 同士である。現在の製品設定は3 session とも disabled。

### RSS

RSS の測定値は Linux `/proc/self/status` の VmRSS kB を1024倍した byte 数。MiB は byte 数を1,048,576で割った値。

| phase | arena enabled bytes | arena enabled MiB | arena disabled bytes | arena disabled MiB |
| --- | ---: | ---: | ---: | ---: |
| prepare | 1,695,510,528 | 1,616.96 | 1,693,339,648 | 1,614.89 |
| call 1 | 2,691,137,536 | 2,566.47 | 1,767,972,864 | 1,686.07 |
| call 10 | 3,133,628,416 | 2,988.46 | 1,912,872,960 | 1,824.26 |
| call 25 | 3,135,713,280 | 2,990.45 | 1,945,313,280 | 1,855.20 |
| call 50 | 3,138,744,320 | 2,993.34 | 1,915,498,496 | 1,826.76 |
| unload | 1,511,903,232 | 1,441.86 | 1,664,278,528 | 1,587.18 |

両 mode とも warm-up 後の RSS はおおむね plateau したが、厳密に一定ではない。call 10 から50の RSS 増分は enabled 4.87890625 MiB、disabled 2.50390625 MiB。disabled は call 25 が記録上の peak で、call 50 では低下した。unload 後は disabled が enabled より高く、両 mode の値は異なり、いずれも非ゼロだった。prepare 前の RSS は測定していないため、初期の空 process RSS と比較できない。process runtime や OS allocator が memory を保持することはありうるが、この結果のみから native tensor leak や allocator retention の原因を断定できない。

### 時間

RTF denominator は 50 × 18.464 = 923.2秒の音声。total elapsed は loop 内の認識時間で、prepare / unload を除外し、text check と出力を含む（付随処理は小さい）。

| mode | call 1 elapsed | total elapsed (50 calls) | total RTF |
| --- | ---: | ---: | ---: |
| arena enabled | 8.834845380 s | 390.051491928 s | 0.4224994496620451 |
| arena disabled | 7.979064878 s | 309.938635223 s | 0.3357220918793328 |

この一回の逐次比較では disabled の total elapsed は小さかったが、単一 host run での差であり、一般的な速度優位を主張しない。

## decision と限界

- Qwen3-ASR の encoder / decoder_init / decoder_step のみ `cpuMemoryArenaEnabled: false` を固定使用する。warm RSS が小さく、この測定で処理速度も十分だった。
- mode を選ぶ環境変数、constructor parameter、experimental path は追加しない。汎用 `ONNXSession` の必須 `cpuMemoryArenaEnabled` 引数と native 呼び出しの error check は維持する。Silero の session は明示的に `true` を使う。
- 固定 18.464秒 clip の50回は、任意の音声・長時間稼働の安定性、Windows の RSS、または1.7b model の挙動を証明しない。benchmark API の Windows implementation はこの session では Windows 上で compile / run していない。

## 再現

Python reference fixture の既存生成手順と依存 pin は [Windows / Linux Qwen3-ASR docs](../windows.md#独立-token-reference-と-完全一致-test) に記載する。Docker 内で `/tmp` に Python 3.12 venv を作り、model を read-only mount して次を実行する。fixture の再生成結果は既存 JSON と完全一致した。

```bash
docker run --rm \
  -v "$PWD:/src" \
  -v "/absolute/path/to/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:ro" \
  -w /src swift:6.2-noble bash -lc '
    apt-get update -qq &&
    apt-get install -y -qq python3-venv >/dev/null &&
    export TMPDIR=/tmp &&
    TOKEN_TMP="$(mktemp -d "${TMPDIR:?}/qwen3-token.XXXXXX")" &&
    python3 -m venv "${TOKEN_TMP:?}/venv" &&
    "${TOKEN_TMP:?}/venv/bin/python" -m pip install \
      numpy==2.2.6 transformers==4.57.1 tokenizers==0.22.2 onnxruntime==1.31.0 &&
    "${TOKEN_TMP:?}/venv/bin/python" scripts/generate_qwen3_asr_token_reference.py \
      --model-directory /models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4 \
      --output /src/app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_token_reference.json
  '
```

[RSS benchmark の説明](../windows.md#複数回推論の-rss-benchmark)にある既存の opt-in command を使い、read-only model mount と mode ごとの fresh release process で測定する。この比較は runtime override ではなく、source/build の比較である。元の arena-enabled measurement は必須 bool wrapper を追加する前に ORT default で生成したが、現行 API で enabled mode を再現するときは Qwen の3つの session 作成箇所（encoder、decoder_init、decoder_step）すべてで `cpuMemoryArenaEnabled: true` を明示して build し、fresh process で parity test と benchmark を実行する。次に3箇所すべてを `false` に戻して release build を作り直し、別の fresh process で parity test と benchmark を再実行する。汎用 `ONNXSession` の必須条件や Silero の明示的な `true` は変更しない。benchmark の環境変数は test の opt-in と model の選択にのみ使い、arena の動作は制御しない。

## 検証記録と参照元

この記録に関連して pass した検査: ONNX tests 22件、engine tests 15件、RSS parser tests 5件、Python reference tests 19件、`python3 scripts/check_doc_references.py`、`python3 -B scripts/check_portable_core.py`。Linux の portable build/test は次のコマンドで検証し、exit code 0 で完了した。通常実行のため、model と benchmark の opt-in は有効化していない。

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.2-noble bash -lc 'apt-get update -qq && apt-get install -y -qq python3 curl >/dev/null && bash scripts/verify_portable.sh'
```

```text
Test run with 781 tests in 33 suites passed after 34.056 seconds.
Portable Core, Pipeline, and ONNX build/test verification passed
```

- Transformers 4.57.1 [Whisper feature extractor source](https://raw.githubusercontent.com/huggingface/transformers/v4.57.1/src/transformers/models/whisper/feature_extraction_whisper.py)
- ONNX Runtime [v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)、[OrtApi](https://onnxruntime.ai/docs/api/c/struct_ort_api.html)、[`SessionOptions` header](https://raw.githubusercontent.com/microsoft/onnxruntime/v1.31.0/onnxruntime/core/framework/session_options.h)
- tokenizers 0.22.2 [API](https://huggingface.co/docs/tokenizers/v0.22.2/api/tokenizer) と [release](https://github.com/huggingface/tokenizers/releases/tag/v0.22.2)
- Microsoft [GetProcessMemoryInfo API](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo)
- Swift 6.2 `winsdk` [module map](https://raw.githubusercontent.com/swiftlang/swift/swift-6.2-RELEASE/stdlib/public/Platform/winsdk.modulemap)（PSAPI header import）
- man-pages 6.19 [`proc_pid_status(5)`](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html)

## Windows ARM64 VM（2026-10-20）

Windows 11 ARM64 の VMware Fusion VM（Swift 6.2.0、ONNX Runtime 1.31.0、debug build、intra-op 2 / inter-op 1）で、0.6B の token parity と50回の memory benchmark を `--filter "ONNXQwen3ASRModelTests|Qwen3ASRResidentMemoryTests"` で実行しました。arena は無効です。

- token parity: short 11/11、long 64/64 で完全一致。
- working set（MiB）: prepare 後 1,604.2、1回目 1,682.4、10回目 1,682.3、25回目 1,682.5、50回目 1,682.5、unload 後 265.0。
- 50回合計の RTF は 0.750（debug build のため Linux の release 値とは比較しません）。
