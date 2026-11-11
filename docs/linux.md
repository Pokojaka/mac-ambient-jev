# Linux 音声評価

portable 評価 CLI は `Package.swift` にある `MacAmbientJevEvaluateSession` と `MacAmbientJevEvaluateASR` の2本です。`MacAmbientJevProcessRecording` は音声を session に import し、VAD→ASR→任意の clause decisions を行って transcript を出力します。`MacAmbientJevTranscribeFile` は `FileTranscriptionPipeline` で単一ファイルを処理し、評価用 artifact を出力します。Swift の共通部分と通常検証は [testing.md](testing.md) を参照してください。

`MacAmbientJevEvaluateSession` は `<manifest.json> <segments.json>`、`MacAmbientJevEvaluateASR` は `<reference.txt> <asr-artifact.json> [--output asr-evaluation.json]` を受け取ります。

## 環境と実行範囲

- Python 3.12 以上。ASR の依存は `tools/linux-audio/asr/pyproject.toml` にあり、`qwen-asr==0.0.6` を使う。
- Python unit test には pytest が必要。音声変換には ffmpeg、Swift 評価器には Swift 6 系が必要。
- runner の device は `cpu`、`cuda`、`cuda:N` のいずれか。CUDA を指定して利用できない場合は失敗し、CPU へ切り替えない。

以下はリポジトリルートから実行する。音声・参照文・出力先は、自分の実在するファイルや保存先を指す環境変数に設定する。

```bash
export PYTHONPATH="$PWD/tools/linux-audio${PYTHONPATH:+:$PYTHONPATH}"
bash scripts/verify_linux_audio.sh --smoke
```

`tools/linux-audio/run_suite.py` は smoke/full のどちらでも portable Core 検証、Python unit test、ffmpeg の有無、qwen_asr の有無を確認する。smoke はモデル推論を実行しない。

| 全体状態 | 終了コード | 意味 |
| --- | --- | --- |
| `PASS` | 0 | 実行対象の check がすべて成功 |
| `FAIL` | 1 | 少なくとも一つの check が失敗 |
| `SKIPPED_MISSING_DEPENDENCY` | 2 | 失敗はないが、依存・必要 fixture・artifact が欠けている |

FAIL は SKIP より優先する。標準出力は `overall`、`exit_code`、`checks` の JSON。各 check は `name`、`status`、必要に応じて `detail` を持つ。`--json` で同じ summary の保存先を指定できる。SKIP は推論や精度の合格を意味しない。

## 全量評価

ASR の必須引数は `--full-audio`、`--full-asr-reference`、`--work-root`、`--device`。参照文は UTF-8 で、通常の文字は必須、`(F x)`（フィラー）/`(D x)`（言い直し断片）の非入れ子 ASCII 範囲だけを任意とする。

```bash
bash scripts/verify_linux_audio.sh --full \
  --full-audio "$AUDIO_WAV" \
  --full-asr-reference "$REFERENCE" \
  --work-root "$WORK_ROOT" \
  --device cpu \
  --json "$SUMMARY_JSON"
```

summary だけ省略できる。full 用の引数を smoke に渡すことはできない。full は Qwen3-ASR の既定 1.7B モデルを実行し、単一 CER 評価と baseline 作成まで行う。PASS は CER 閾値判定や baseline 比較を含まない。`run_suite.py` は `--full-asr-reference` の参照文を読み（`reference.txt` は生成しない）、`work_root` に `qwen3-asr.json`（ASR artifact）、`asr-evaluation.json`、`qwen3-asr-current.json` を出力する。

## ASR 実行と CER

`tools/linux-audio/asr/qwen3_asr.py` は公式 qwen-asr の Transformers backend を使う。既定モデル ID は Qwen/Qwen3-ASR-1.7B（Hugging Face の ID であり、リポジトリ内のパスではない）、revision は `7278e1e70fe206f11671096ffdd38061171dd6e5`。モデルを変える場合は `--revision` が必要。

```bash
python3 -m asr.qwen3_asr "$AUDIO_WAV" \
  --output "$ASR_ARTIFACT" \
  --device cpu \
  --language Japanese

swift run --package-path app/MacAmbientJev MacAmbientJevEvaluateASR \
  "$REFERENCE" "$ASR_ARTIFACT" --output "$ASR_EVALUATION"
```

推論設定は dtype `bfloat16`、batch size 1、max new tokens 4096、context は空文字。指定 device と language も来歴に保存する。参照文を先に parse し、mark の構文を本文に含めず、必須片と任意片それぞれに既存 normalizer version 1（NFKC、空白・句読点除去）を適用する。ASCII 括弧は `(F x)` / `(D x)` 以外、未知 tag、閉じていない・入れ子の mark を拒否し、エラー位置は1始まりの Swift 文字位置で示す。

hypothesis には同じ normalizer だけを適用し、注釈 parse や任意文字の除去はしない。編集距離は任意文字の削除を0、必須文字の削除を1、置換と挿入を各1とし、CER rate は必須参照文字数を分母にする。必須参照が空なら距離0の rate は0、それ以外は1。報告は top-level `cer` object と `normalizer_version` を持ち、`cer` は `rate`、`substitutions`、`deletions`（必須文字のみ）、`insertions`、`required_reference_characters`、`optional_reference_characters`、`hypothesis_characters` を持つ。文字数・編集操作数は Swift の文字単位（Character）。

## セッション全体のファイル処理 CLI

`MacAmbientJevProcessRecording` は音声を session に import し、[`SessionFileProcessingService`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionFileProcessingService.swift) と [`FinalTranscriptPipeline`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FinalTranscriptPipeline.swift) で VAD→ASR→任意の clause decisions を行う portable CLI です。session の状態確認と finalization / decisions の再開も行えます。

```text
MacAmbientJevProcessRecording --sessions-root ROOT [--keep-session] [--low-heat] [--with-decisions] --threads N AUDIO [OUTPUT]
MacAmbientJevProcessRecording --inspect-session UUID --sessions-root ROOT
MacAmbientJevProcessRecording --resume-session UUID --sessions-root ROOT [--low-heat] [--with-decisions] --threads N OUTPUT
```

`--sessions-root` は必須です。symlink ではなく、application support / cache の保護領域と重ならない安全な保存先を明示してください。import では必要に応じて session root を作成します。Portable の import / resume は `--threads N` が必須で、`N` は `1...min(4, 論理 CPU 数)` の整数です。ASR と decisions 用 tagger の ONNX session は `N`、VAD は常に1 thread で動作します。model 不要の `--inspect-session` は `--threads` を受け付けず、macOS の CLI では `--threads` 自体を指定できません。Portable の resume は export-only の場合も `--threads` が必要です。

Import の `AUDIO` に続く `OUTPUT` は省略でき、省略時は音声ファイルの親 directory に `segments.json` を作成します。import 時は stdout に `session_id: UUID` を出力します。`--keep-session` を指定しない import session は成功時・失敗時とも処理後に削除されます。失敗した session を調査または再開するために残す場合は、import に `--keep-session` を指定してください。`--inspect-session` と `--resume-session` の UUID にはこの `session_id` を使います。session root 直下の manifest を検索し、該当 manifest の `session_id` で folder を特定します。`--resume-session` は必須の `OUTPUT` へ export し、その path は symlink 解決後も対象 session folder の外でなければなりません。

`--inspect-session` は recovery action と storage maintenance の状態だけを返し、`--low-heat`、`--with-decisions`、`--threads`、`--keep-session`、measurement options や位置引数は指定できません。JSON の object は `{ "session_id": "...", "action": "...", "maintenance": null }` の3 key のみで、maintenance がない場合は `null` です。`--run-id`、`--metrics-output`、`--thermal-output`、`--memory-output` は Mac 専用の measurement options で、Linux / Windows はこれらを filesystem/session side effect より前に拒否します。

`--low-heat` は Portable では ASR の認識済み segment 間に約2秒の pacing wait を入れるだけです。Linux / Windows では thermal monitoring、thermal start gate、thermal state による pause は行いません。

Decisions は既定で無効です。`--with-decisions` のとき、認識テキストがある export は clause-boundary と content-priority の両 run が公開済みで、pending decision target がない場合に限り成功します。decision request が失敗した場合は session 内の公開済み local transcript は保持されますが、成功 export は作らず CLI は非0で終了します。その失敗 session が必要なら import に `--keep-session` を指定してください。認識テキストがない場合は空の `[]` を正常に export し、decision run は不要です。完了済み decisions の session を `--with-decisions` 付きで resume する場合は、recognized segment 配列を export し、model resources を作らず inference event も追加しません。decisions だけを retry する resume は ASR 推論を行いませんが、portable の基本 engine bundle は構築します。

成功時の import / resume output は、pretty-printed・sorted JSON の `MaterializedTranscriptSegment` 配列です。各要素は `segment_id`、`source`、`start_ms`、`end_ms`、`text`、`display_text`、`clause_state`、`clause_slices` を持ちます。

### Portable inference environment

`PortableProcessingConfiguration.resolve` は import と inference が必要な resume のときだけ portable model environment を読みます。inspect と export-only resume は model environment を読みません。decision-only retry は ASR 推論を行わない場合も、base engine bundle を作るため次の基本 model 設定を必要とします。

| 環境変数 | 必要な値 |
| --- | --- |
| `MAC_AMBIENT_JEV_SILERO_MODEL` | 絶対 path の既存 Silero ONNX model file |
| `QWEN3_ASR_ONNX_MODEL_DIRECTORY` | 絶対 path の既存 Qwen3-ASR ONNX model directory |
| `QWEN3_ASR_ONNX_MODEL_SIZE` | `0.6b` または `1.7b` のいずれか（大文字・空白なし） |
| `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` | `--with-decisions` の場合のみ必要な、絶対 path の既存 clause-tagger model directory |

値に default はありません。model path を指定する CLI option、暗黙 download、path / model の fallback もありません。欠落・不正な設定は import session の bootstrap または resume の storage maintenance より前に失敗します。configuration の path/type 検査は model integrity 全体の preflight ではありません。Silero の pin 検証は engine bundle 構築時に行い、各 ONNX engine の model file / graph の検証・load は engine の prepare/load 時に行います。全 model の hash を session mutation 前に一括検証する契約ではありません。asset の取得方法は [Silero VAD](windows.md#silero-vad-フレーム推論)、[Qwen3-ASR](windows.md#qwen3-asr-onnx-モデルの取得)、[clause tagger](windows.md#発話文タガー-onnx-モデルの取得) を参照してください。CLI はそれらを自動実行しません。

Linux import は既存の CMiniaudio decoder を使い、WAV / FLAC / MP3 のみを受け付け、入力は既に 16 kHz mono である必要があります。channel mixing や sample-rate conversion はしません。`--threads` や model environment は下記の `MacAmbientJevTranscribeFile` の設定とは別です。

Linux での実行例です。path と `N` は実在する環境に合わせて明示してください。model assets と ONNX Runtime SDK の準備は上記リンク先と [ONNX Runtime](windows.md#onnx-runtime) の既存手順を参照してください。

```bash
export MAC_AMBIENT_JEV_SILERO_MODEL="/absolute/path/to/silero_vad_16k_op15.onnx"
export QWEN3_ASR_ONNX_MODEL_DIRECTORY="/absolute/path/to/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4"
export QWEN3_ASR_ONNX_MODEL_SIZE="0.6b"
export MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY="/absolute/path/to/models/clause-tagger"
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --sessions-root "/absolute/path/to/sessions" \
  --keep-session --with-decisions --threads 1 \
  "/absolute/path/to/recording-16k-mono.wav" \
  "/absolute/path/to/output/segments.json"
```

実装と関連 test は [`ProcessRecordingArguments.swift`](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/ProcessRecordingArguments.swift)、[`main.swift`](../app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift)、[`ProcessRecordingArgumentsTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ProcessRecordingArgumentsTests.swift)、[`ProcessRecordingSafetyTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ProcessRecordingSafetyTests.swift)、[`SessionFileProcessingServiceTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionFileProcessingServiceTests.swift)、[`FinalTranscriptPipelineTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/FinalTranscriptPipelineTests.swift)、[`PortableProcessingConfiguration.swift`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableProcessingConfiguration.swift)、[`PortableProcessingConfigurationTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/PortableProcessingConfigurationTests.swift) を参照してください。

## ファイル文字起こし CLI

`MacAmbientJevTranscribeFile` は [`FileTranscriptionPipeline`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FileTranscriptionPipeline.swift) を使い、Silero VAD→ASR で区間別 transcript、primary JSON、評価用 artifact を出力します。この CLI に thermal 制御や pacing wait はありません。

確定処理の区間規則は [Silero VAD の区間検出](windows.md#silero-vad-の区間検出) と同じです。4,096 sample / 256 ms chunk、開始閾値 0.50・終了閾値 0.35、pre-roll 0.10 秒、最大区間 14 秒、無音 0.75 秒、分割探索 2.0 秒、energy frame 0.02 秒、独立区間の最短 0.5 秒を使います。

```text
MacAmbientJevTranscribeFile <audio-file> --silero-model <path> --asr-model-directory <dir> --asr-model-size <0.6b|1.7b> --threads <n> --output <file.json> --artifact-output <artifact.json>
```

`--help` だけを渡した場合は usage を表示して終了コード 0 で終了します。音声ファイルは必須の先頭位置引数です。6 個の option はそれぞれ必須で一度だけ指定し、option/value の組は任意の順に並べられます。

| option | 内容 |
| --- | --- |
| `--silero-model <path>` | Silero VAD ONNX model file |
| `--asr-model-directory <dir>` | 選択した Qwen3-ASR ONNX model の既存 directory |
| `--asr-model-size <0.6b\|1.7b>` | 取得した model のサイズ |
| `--threads <n>` | 正の Int32 範囲内の整数。ASR と VAD のすべての ONNX session の intra-op thread 数に使う |
| `--output <file.json>` | 区間時刻と区間別 transcript を保存する primary JSON |
| `--artifact-output <artifact.json>` | `MacAmbientJevEvaluateASR` 用 artifact v2 |

認識言語は日本語 (`ja`) 固定で、detected-language field は出力しません。6 個の option に default や環境変数 override はありません。不明・重複・欠落 option、余分な引数、不正な値は非 0 で失敗します。入力、Silero model、ASR model directory は読み取り可能な既存の通常ファイル / directory でなければなりません。出力先の親 directory は事前に存在する必要があります。`--output` と `--artifact-output` は既存 path を指定すると、処理開始前に非 0 で拒否されます。入力、primary 出力、artifact 出力は、path 標準化と symlink 解決後に互いに異なる必要があります。

音声 import と VAD の前に、CLI は Silero model の pinned SHA-256 を検証し、選択した ASR model manifest が列挙する6ファイルの存在・通常ファイル型・readability・正確な byte 数を確認します。この preflight は VAD 区間が空の場合も実行しますが、ASR model ファイルの SHA-256 は検証しません。preflight は測定時間に含まれません。VAD が空の区間一覧を返した場合も処理は成功し、primary の `segments` は空、artifact の hypothesis は空文字です。この場合 ASR model の load / inference は行いません。

`MacAmbientJevTranscribeFile` は PortableRuntime の [`PortableAudioFileImporter.open(inputURL:sessionURL:)`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableAudioFileImporter.swift) を呼びます。Core の [`AudioImporter`](../app/MacAmbientJev/Sources/MacAmbientJevCore/AudioImporter.swift) が入力を一度だけ `sessionURL/audio/original.*` にコピーし、[`PortableImportedAudioTimelineBuilder`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/PortableImportedAudioTimelineBuilder.swift) は保存済み original を再コピーせず、[`SessionLayout.processingDirectory`](../app/MacAmbientJev/Sources/MacAmbientJevCore/SessionLayout.swift)（audio directory 内の processing subdirectory）に processing timeline を作ります。共通 Core の [`ImportedAudioTimelineBuilding`](../app/MacAmbientJev/Sources/MacAmbientJevCore/ImportedAudioTimelineBuilding.swift) contract を使い、読み込み buffer は最大 8,192 frame、processing timeline は5秒単位の durable chunk に保存します。Linux は [`CMiniaudio`](../app/MacAmbientJev/Sources/CMiniaudio/README.md) 0.11.23 で WAV / FLAC / MP3 を読み、入力がすでに16 kHz mono であることを要求します。Linux では channel mixing と sample-rate conversion をせず、非対応形式・非 canonical 入力・decoder error は既存の明示エラーとして返し、別 decoder へ fallback しません。Windows は既存の WindowsSupport [`AudioFileTimelineBuilder`](../app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport/AudioFileTimelineBuilder.swift) に decode と SRC を委譲し、WAV / FLAC / MP3 / M4A / AAC を扱います。AAC encoder priming と canonical frame boundary の規則は [音声 import API](windows.md#音声-import-api) を参照してください。

`MacAmbientJevProcessRecording` は [`SessionProcessingAudio`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionProcessingAudio.swift) に builder を必須注入し、保存済み録音を [`SessionAudioReaders`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/SessionAudioReaders.swift) で開きます。成功した録音の finalization は [`RecordingAudioCompactor`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/RecordingAudioCompactor.swift) で audio directory 内の `recording.flac` に compact して PCM processing timeline を削除します。import 元は audio directory の original file に保持し、processing timeline は一回の finalization 用に作成・削除します。

Linux で必要なら、既存の ffmpeg を使って事前に mono PCM16 / 16 kHz WAV を作れます。これは利用者が明示的に行う前処理であり、CLI の fallback ではありません。

```bash
ffmpeg -nostdin -i "$SOURCE_AUDIO" -map_metadata -1 -vn -ac 1 -ar 16000 -c:a pcm_s16le "$NORMALIZED_WAV"
```

invalid input や処理失敗では出力 JSON を作りません。CLI は import した original、processing timeline、event files を一時 scratch directory に置き、処理後に削除します。処理と scratch 削除の両方が失敗した場合は両方の error を報告し、削除だけが失敗した場合も filesystem error として返します（[`TranscribeFileCommand`](../app/MacAmbientJev/Sources/MacAmbientJevTranscribeFile/TranscribeFileCommand.swift)）。ユーザーの永続 session は作成しません。primary JSON と artifact JSON はそれぞれ atomic file write しますが、2 ファイルの pair 全体は transactional ではありません。

primary JSON の top-level keys は `schema_version`（常に `1`）、`asr`、`vad`、`segments`、`runtime` です。`asr` と `vad` はそれぞれ `RunProvenance` の `engine`、`model`、`version`、`configuration` を持ちます。`segments` は時系列の `start_ms`、`end_ms`、`text` 要素の配列で、frame 境界を最も近い整数 millisecond に ties-to-even で丸めます。`runtime` は `audio_seconds`、`model_load_seconds`、`inference_seconds`、`rtf` を持ちます。

primary の区間別時刻が発話境界を表し、評価 artifact の区間は全音声を包む CER 用 envelope です。

`model_load_seconds` は `PipelineCoordinator` が計測する `ASR.prepare()` のみです。`inference_seconds` は `segmentationSeconds + asrWallSeconds - model_load_seconds` で、lazy VAD model load / inference と event persistence を含みます。audio import、モデル identity preflight、ONNX environment の生成、model unload / scratch cleanup、JSON 出力は含みません。`rtf = inference_seconds / audio_seconds` です。負値または非有限の計測値・算出指標はエラーになり、0 へ clamp しません。この RTF は ASR-only warm RTF ではありません。

### Linux release build と実行

Python 3.12 以上、Swift 6.2 系、ONNX Runtime SDK、Silero model が必要です。Linux では入力音声を 16 kHz mono に用意してください。以下の `/absolute/path/...` は置換する例であり、既定 path ではありません。指定した入力、model directory、出力親 directory は事前に存在させます。

```bash
set -eu
python3.12 scripts/fetch_onnxruntime.py
SILERO_MODEL="$(python3.12 scripts/fetch_silero_vad.py)"
swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevTranscribeFile
BIN_DIR="$(swift build --package-path app/MacAmbientJev -c release --show-bin-path)"
"$BIN_DIR/MacAmbientJevTranscribeFile" \
  "/absolute/path/to/audio-16k-mono.wav" \
  --silero-model "$SILERO_MODEL" \
  --asr-model-directory "/absolute/path/to/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4" \
  --asr-model-size 0.6b \
  --threads 2 \
  --output "/absolute/path/to/output/segments.json" \
  --artifact-output "/absolute/path/to/output/asr-artifact.json"
```

ASR model directory は対応する固定 repository / revision の model を事前に取得した directory です（[Qwen3-ASR ONNX model fetcher](windows.md#qwen3-asr-onnx-モデルの取得)）。Silero fetcher は Python 3.12 以上を要求します。

ONNX 発話文タガー（ClauseTagger.onnx、tokenizer.json、export.json、LICENSE.txt、LICENSE.md）は、Hugging Face の [Pokojaka/modernbert-ja-30m-utterance-tagger](https://huggingface.co/Pokojaka/modernbert-ja-30m-utterance-tagger/tree/5c0213592cf8d59fc0b665183ab7536ddde05d1f) の commit `5c0213592cf8d59fc0b665183ab7536ddde05d1f` から `CLAUSE_TAGGER="$(python3.12 scripts/fetch_clause_tagger.py --format onnx)"` で取得します。model ID は Pokojaka/modernbert-ja-30m-utterance-tagger、model revision は `90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9` です。検証済み directory は `.build/clause-tagger-onnx/5c0213592cf8d59fc0b665183ab7536ddde05d1f/clause-tagger-onnx/` で、stdout の絶対 path を Swift の `ClauseTaggerAssets` に渡します。実モデルを使う test はこの directory を必須の環境変数 `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` に設定して実行し、未設定や存在しない directory では skip せず失敗します。5ファイルの pin と検証、共有 manifest、取得処理の詳細は [windows.md](windows.md#発話文タガー-onnx-モデルの取得) を参照してください。Linux でも同じ manifest と fetcher を使います。

### artifact v2 の検証と CER 評価

`--artifact-output` は既存の schema v2 ASR artifact です。Python validator と portable evaluator は次のように実行します。

```bash
PYTHONPATH=tools/linux-audio python3 -c 'import json,sys; from common.artifact import validate_asr_artifact; validate_asr_artifact(json.load(open(sys.argv[1], encoding="utf-8")))' \
  "/absolute/path/to/output/asr-artifact.json"
swift run --package-path app/MacAmbientJev MacAmbientJevEvaluateASR \
  "/absolute/path/to/output/reference.txt" \
  "/absolute/path/to/output/asr-artifact.json" \
  --output "/absolute/path/to/output/asr-evaluation.json"
```

### 実モデル CLI の opt-in test

[`test_transcribe_file_cli_model.py`](../tools/linux-audio/tests/test_transcribe_file_cli_model.py) は release CLI と evaluator を build し、両方の出力、artifact validator、長い fixture に対する CER `<= 0.15` を検査します。既定では skip です。`RUN_MODEL_TESTS=1` のときは `QWEN3_ASR_ONNX_MODEL_DIRECTORY`（絶対 path の既存 readable directory）、`QWEN3_ASR_ONNX_MODEL_SIZE`（`0.6b` または `1.7b`）、`MAC_AMBIENT_JEV_SILERO_MODEL`（readable model file）が必須で、設定欠落時は test failure です。repository root から実行します。

```bash
set -eu
cd tools/linux-audio
export RUN_MODEL_TESTS=1
export QWEN3_ASR_ONNX_MODEL_DIRECTORY="/absolute/path/to/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4"
export QWEN3_ASR_ONNX_MODEL_SIZE=0.6b
SILERO_MODEL="$(python3.12 ../../scripts/fetch_silero_vad.py)"
export MAC_AMBIENT_JEV_SILERO_MODEL="$SILERO_MODEL"
uv run --python 3.12 --with pytest python -m pytest -q tests/test_transcribe_file_cli_model.py
```

CLI の unit tests は引数・path・import decode に加え、モデル不要で primary JSON / artifact の完全な payload schema、VAD segment text の順序と改行 join、provenance、RTF、計測値・configuration・path の error を検査します（[`TranscribeFileTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevTranscribeFileTests/TranscribeFileTests.swift)）。PortableRuntime の [`PortableAudioImportTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/PortableAudioImportTests.swift) はモデル不要で stored-original builder が再コピーしないことと、Linux の非 canonical / 非対応入力の拒否を検査します。実モデルを使う Python integration test は opt-in で、release CLI の出力と CER を検査します。pipeline helper tests は [`FileTranscriptionPipelineTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/FileTranscriptionPipelineTests.swift) にあります。

## 評価 artifact のスキーマ v2

厳密な Python validator は `tools/linux-audio/common/artifact.py` にあり、固定キー以外を拒否します。ASR artifact の `engine` は7 key で、`name` は `qwen3-asr`、backend は `transformers` または CPU 専用 `onnxruntime` です。`model`、`revision`、`device`、`package_versions`、`inference_config` も持ち、設定辞書と package map は空にできません。来歴を含む形式確認には Python validator を使います。

`runtime` は `audio_seconds`、`model_load_seconds`、`inference_seconds`、`rtf`。有限の非負数で、audio の長さは正、RTF は inference/audio に一致する。Python Transformers runner では cold model load とロード後の warm 推論を分けます。file CLI の同じフィールドは [CLI の計測定義](#ファイル文字起こし-cli) に従い、ASR-only warm RTF を示しません。CUDA では `resident_vram_mb` と `peak_vram_mb` がさらに必須で、CPU ではこの二つのキーを持たない。単位は 1024² bytes。resident はモデルロード直後の PyTorch allocated memory、peak は推論中の allocated memory の最大値であり、GPU 全体の使用量ではない。

### ASR の artifact

トップレベルは `schema_version: 2`、`engine`、`segments`、`runtime` のみ。`segments` は全音声を包む一つの区間で、発話時刻の精度を表すものではなく CER の hypothesis 用である。区間は次の四キーを持つ。

- `start_ms`: 整数 0。
- `end_ms`: audio_seconds × 1000 を round した整数。
- `text`: 認識文。空文字も形式上は許可する。
- `language`: Transformers backend ではエンジンが返した言語。file CLI の ONNX backend では設定済みの `ja` であり、検出言語ではない。

file CLI の評価 artifact も厳密な schema v2 です。ONNX artifact のトップレベルは `schema_version`、`engine`、`segments`、`runtime`、各 segment は4キーです。Python validator は `runtime` のキー集合・型・非負値・RTF 整合条件を含めて検証します。primary JSON にある VAD segment の開始・終了時刻が実際の区間境界です。v2 の単一 segment は CER 用全音声 envelope です。

#### file CLI の ONNX ASR engine

`engine` は `name: qwen3-asr`、`backend: onnxruntime`、`device: cpu` です。`package_versions` はロード中の runtime が返す実際の version を記録し、`onnxruntime` は固定版 `1.31.0` です。`model` と `revision` はサイズに対応する pinned repository と commit です。

| size | `model` | `revision` |
| --- | --- | --- |
| `0.6b` | [andrewleech/qwen3-asr-0.6b-onnx](https://huggingface.co/andrewleech/qwen3-asr-0.6b-onnx/tree/4fc24a1402e74db89c4d2ef256875e71680128c4) | `4fc24a1402e74db89c4d2ef256875e71680128c4` |
| `1.7b` | [andrewleech/qwen3-asr-1.7b-onnx](https://huggingface.co/andrewleech/qwen3-asr-1.7b-onnx/tree/df916193ac67e59347769891a21e10d81d12acdd) | `df916193ac67e59347769891a21e10d81d12acdd` |

`inference_config` は次の10キーのみです。validator は余分なキーを拒否します。

| key | fixed value |
| --- | --- |
| `language` | `ja` |
| `quantization` | `int4` |
| `minimum_input_seconds` | `0.02` |
| `mel_variant` | `whisper-slaney-128-nfft400-hop160-reflect-global-log10` |
| `max_new_tokens` | `448` |
| `no_repeat_ngram` | `3 when input_seconds > 15; disabled otherwise` |
| `intra_op_threads` | CLI の `--threads` 値（正の Int32） |
| `inter_op_threads` | `1` |
| `cpu_memory_arena` | `false` |
| `segmentation` | `silero-final-transcript` |

`asr.configuration` と `engine.inference_config` の `intra_op_threads`、`inter_op_threads`、`cpu_memory_arena` は ASR の3 ONNX session で実際に使う設定です（CLI の `--threads` 値、`1`、`false`）。`engine.inference_config` のこれらの値は ASR session のみを表します。Silero session は `--threads` の値を intra-op に使い、CPU memory arena を有効にします。

`segments` は一要素だけです。`start_ms` は整数 `0`、`end_ms` は `round(audio_seconds * 1000)`、`text` は VAD 区間の認識 text を順に改行文字 `\n` で結合した文字列、`language` は設定された `ja` です。結合規則は Mac の `ASRSessionEvaluator` と同じです。これは CER の全音声 envelope であり、区間ごとの実時刻は表しません。`MacAmbientJevEvaluateASR` はこの artifact を参照文と別途評価します。

## baseline のスキーマ v2

`tools/linux-audio/common/baseline.py` の record は `schema_version: 2`、`engine`、`conditions`、`corpus`、`metrics` のちょうど5 key です。`engine` は `qwen3-asr` / `transformers` の artifact 来歴、`conditions` は `normalizer_version` だけ、`corpus` は小文字 SHA-256 の `audio` と `reference` です。

`metrics` は有限値の `cer`、`rtf`、`model_load_seconds` で、CUDA では実測 `resident_vram_mb` と `peak_vram_mb` も含みます。suite は `reference_path` で渡された参照文を読み、work root に `qwen3-asr.json`（ASR artifact）、`asr-evaluation.json`、`qwen3-asr-current.json` を作ります。

`compare_baseline` は engine、conditions、corpus の完全一致時だけ各 metric の baseline/current/delta を返します。record は有限の数値 metrics のみを持ちます。比較関数は suite に自動接続されていません。

## VOICEVOX の評価 corpus

固定台本は `tools/corpora/voicevox-ja-core-v1.json` にある。`tools/linux-audio/common/voicevox_cli.py` は VOICEVOX の `/audio_query` が返す JSON を synthesis に渡し、WAV と query を保存します。API endpoint はリポジトリ内のパスではありません。

```bash
python3 -m common.voicevox_cli \
  --base-url http://127.0.0.1:50021 \
  --text '今日は音声認識の動作を確認します。' \
  --style-id 3 \
  --output "$VOICEVOX_WAV" \
  --query-output "$VOICEVOX_QUERY"
```

## CSJ の評価素材と外部音声

`tools/linux-audio/prepare_fixture.py` は schema version 1 の manifest を受け取る。必要な `resources` は role `audio` と `csj-transcript` が一つずつで、各 resource に `url`、`filename`、固定した `sha256` を指定する。

```bash
python3 tools/linux-audio/prepare_fixture.py "$CORPUS_MANIFEST" \
  --cache-root "$CACHE_ROOT" --output-root "$FIXTURE_ROOT"
```

生成物は mono PCM16 / 16 kHz の `audio.wav`、`reference.txt`、`fixture.json` です。`fixture.json` の top-level は `schema_version`、`id`、`files` で、`files` は `audio` と `reference` の2 keyです。参照文は UTF-8 です。

音声正規化 `normalize_to_wav` は source と destination に異なるファイルを要求する。同一ファイルへ解決されるパス（シンボリックリンクを含む）は、出力先を変更する前に ValueError で拒否する。成功時は mono PCM16 / 16 kHz WAV を出力する。

`tools/linux-audio/common/csj.py` の parser は番号・秒単位 start-end・英字ラベルを持つ header と、surface と katakana を `&` で区切る本文を読み、空行と `%` コメントを無視します。CSJ の入れ子 F/D/? 注釈では外側 F/D を任意 mark として保ち、その内側の注釈を外側の本文へ平坦化します。`(? x)` は必須の `x`、`(?)` は空になり、任意 mark の外側にある `?` wrapper 内の F/D mark は保ちます。header の `<笑>`・`<雑音>` 等は非言語区間で、本文や参照文を持ちません。未知の書式、本文のない speech、非言語区間の本文、不正時刻は明示エラーです。

既存 cache の SHA-256 不一致は直ちに失敗し、暗黙の再取得で上書きしない。新規 download も hash を検証してから公開する。外部音声は Git に入れず、利用条件と音声・参照文の対応を確認してローカルで準備する。`tools/corpora/public-ja-candidates-v1.json` は CSJ、RWCP、青空文庫/LibriVox の候補一覧であり、prepare 用の hash 固定済み resource manifest ではない。

## CI の実推論

`.github/workflows/linux-asr-real-inference.yml` は workflow_dispatch と指定 branch 上の path filter に合致する push を入口にします。Ubuntu / Python 3.12 / CPU PyTorch 2.10.0 / qwen-asr 0.0.6 で実行し、二モデルを独立した matrix job で判定します。fail-fast は無効です。

- 1.7B: モデル ID Qwen/Qwen3-ASR-1.7B、revision `7278e1e70fe206f11671096ffdd38061171dd6e5`。
- 0.6B: モデル ID Qwen/Qwen3-ASR-0.6B、revision `5eb144179a02acc5e5ba31e748d22b0cf3e303b0`。

各 job は Python unit test、VOICEVOX による日本語音声の生成、16 kHz mono 化、指定モデルの CPU 推論、artifact validator、portable Swift CER 評価を行います。平文参照文は全て必須文字として、非空の認識文・revision 一致・CER 10% 以下を確認します。1.7B の失敗を 0.6B の成功で代替しません。Docker image ID/digest、VOICEVOX engine version・人物一覧・query、音声 hash、推論結果、評価、runner 情報を artifact として保存し、保持期間は 3 日です。
