# Windows の共通コア

Windows では Swift 6.2 で共通 Core / Pipeline、WindowsSupport、ONNX、PortableRuntime、評価 CLI 3 本と Core / Pipeline / WindowsSupport / ONNX / PortableRuntime のテストをビルド・実行できます（[Swift 6.2 release](https://www.swift.org/blog/swift-6.2-released/)）。Linux では共通 Core / Pipeline、CMiniaudio、ONNX、PortableRuntime、評価 CLI 3 本と Core / Pipeline / ONNX / PortableRuntime のテストをビルド・実行します。共通 Core の [`RecordingFLAC`](../app/MacAmbientJev/Sources/MacAmbientJevCore/RecordingFLAC.swift) と [`FLACTimelineReader`](../app/MacAmbientJev/Sources/MacAmbientJevCore/FLACTimelineReader.swift) は、録音用の正規 `recording.flac`（16 kHz mono 16-bit）の streaming encoder / reader API と CRC / MD5 検証を提供し、Windows でも利用できます。共通の [`MacAmbientJevPipeline`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline) と [`MacAmbientJevPipelineTests`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests) は Windows / Linux の build / test 対象です。WindowsSupport は WAV / FLAC / MP3 / M4A / AAC の streaming import と canonical timeline 生成 API を提供しますが、これは Windows の録音・capture や GUI・engine を含む完全な import / finalization pipeline が実装済みであることを意味しません。録音・capture、ASR、話者分離、発話文判定を統合する Windows processing engine、GUI、インストーラーは実行対象に含まれません。PortableRuntime は Silero VAD による確定処理用の区間検出とライブ VAD を提供しますが（[Silero VAD の区間検出](#silero-vad-の区間検出)）、これらの処理 pipeline には接続されていません。macOS のアプリは Apple Silicon と macOS 15 以降で動作します。

## ONNX Runtime

Windows / Linux の ONNX 実行には Microsoft ONNX Runtime の固定版 1.31.0 を使います（[公式 v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)、[C API](https://onnxruntime.ai/docs/get-started/with-c.html)、[OrtApi](https://onnxruntime.ai/docs/api/c/struct_ort_api.html)）。[`CONNXRuntime`](../app/MacAmbientJev/Sources/CONNXRuntime/module.modulemap) は取得した ONNX Runtime C header を読み込む `systemLibrary` module です。[`MacAmbientJevONNX`](../app/MacAmbientJev/Sources/MacAmbientJevONNX/ONNXSession.swift) はこの C module だけに直接依存し、[`MacAmbientJevONNXTests`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/ONNXSessionTests.swift) は Windows / Linux のみで定義します。macOS は ONNX target を定義せず、ONNX Runtime SDK を取得しません。

公開 API は `ONNXEnvironment(loggingID:)`、`ONNXSession(environment:modelURL:intraOpThreads:)`、`ONNXTensor`、`ONNXValue`、`ONNXRuntimeError` です。すべての引数が必須です。呼び出し側が `ONNXEnvironment` を1つ生成してプロセススコープで保持し、すべての session に共有します。ORT environment はプロセス全体で使うためのもので、wrapper は global singleton を提供しません。`ONNXEnvironment` は環境作成前に読み込まれた ONNX Runtime の版が固定 1.31.0 と一致することを確認し、一致しない場合は実際の版を含む日本語エラーを返して環境を作成しません（異なるシステム DLL は使用できません）。`ONNXEnvironment` は OrtEnv を所有して解放します。ORT は OrtEnv を複数 thread から共有できるとしており、wrapper は作成後に変更しないため `@unchecked Sendable` で、固定版は `ONNXEnvironment.runtimeVersion` として公開します。`ONNXSession` は environment を強参照で保持し、自身の native session だけを所有・解放します。モデル URL は明示し、モデルや SDK の path を環境変数・config から読み取る override はありません。`intraOpThreads` は各 session で選ぶ正の Int32 表現可能な Int で、全 session 共通の値ではありません。inter-op thread 数は 1 固定です。`ONNXTensor` は `.float32(shape:values:)` と `.int64(shape:values:)` のみを持ち、値はそれぞれ `[Float]` と `[Int64]` です。shape `[]` は値1個の scalar、0 extent を含む shape は値0個です。負の次元、要素数の不一致、要素数または byte 数の overflow は `ONNXValue` の作成時に検証します。`run(inputs:outputNames:)` は名前付き複数入力を受け取り、指定した順序の出力テンソルを返します（入力は `ONNXValue` へコピーして `runValues` に渡し、出力は `tensor()` でコピーして返す薄い層です）。出力で読み取れる要素型は float32 と int64 だけで、ほかの型は `ONNXRuntimeError` になります。空または NUL を含む入出力名、重複する入力名、空の出力一覧も拒否します。`ONNXValue` は float32 / int64 の ORT 値（OrtValue）を所有する不透明なハンドルで、deinit で解放します。`ONNXValue(environment:tensor:)` が `ONNXTensor` から作る（コピー1回）ほか、`runValues(inputs:outputNames:)` が名前付き `ONNXValue` を受け取って出力を `ONNXValue` で返します。`runValues` は入出力のテンソルデータを Swift 側へコピーしないため、ある step の出力（例: Qwen3-ASR decoder の `present_keys` / `present_values`）を次の step の入力（`past_keys` / `past_values`）へそのまま渡せ、数百 MB の KV cache が Swift 配列を往復しません。`shape` は作成時に取得済みの値を返す安価なアクセサです。`tensor()` は全体を `ONNXTensor` にコピーし、`float32LastRow()` は形状 `[1, S, V]`（`S >= 1`）の float32 テンソルの最終行だけを `[Float]`（長さ `V`）にコピーします（`[1, S, 151936]` の logits 全体をコピーしないため）。`ONNXValue` は float32 と int64 のテンソルだけを表し、出力がほかの型の場合は `runValues` が `ONNXRuntimeError` を返します。`float32LastRow()` は float32 以外または形状が `[1, S, V]`（`S >= 1`）でない値を `ONNXRuntimeError` で拒否します。別の `ONNXEnvironment` で作った値を session に渡すことも拒否します。`ONNXValue` は作成後に変更せず ORT は入力値を読み取るだけなので thread 間で受け渡せますが、1つの値を同時に複数の session run で使いません。入出力名と ORT status のエラーは `run` と同じ `ONNXRuntimeError` です。ファイル URL の native filesystem representation を使い、Windows では native UTF-8 path を UTF-16 に変換して ORT に渡します（`URL.path` は使いません）。CPU provider のみを使い telemetry を無効にし、fallback はありません。ORT status は日本語の処理状況と ORT のメッセージを含む `ONNXRuntimeError` として返します。

ONNX のテストは [`affine.onnx`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/affine.onnx) を用いて、名前付き型付きテンソル推論、`ONNXValue` 作成時の検証、environment / session の寿命とエラー処理、日本語・絵文字を含むパスを確認します（[テスト](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/ONNXSessionTests.swift)）。[`cache.onnx`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/cache.onnx)（`past` に `step` を第2軸で連結した `present` と、int64 の `count` に 1 を足した `count_out`）は、出力 `ONNXValue` を次の run の入力へ渡す連鎖、最終行の読み出し、名前と形状の誤りのエラーを確認します（[テスト](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/ONNXValueTests.swift)）。両 fixture は [`generate_onnx_fixture.py`](../scripts/generate_onnx_fixture.py) が決定的に生成します。

[`fetch_onnxruntime.py`](../scripts/fetch_onnxruntime.py) は Python 3.12 以上の標準ライブラリのみを使い、Python 3.12 未満は明示的なエラーで拒否します。Windows x64 / arm64 と Linux x64 / aarch64 の asset を単一の公式 v1.31.0 release から `.build/onnxruntime/1.31.0/` に取得し、それ以外の OS / architecture は明示エラーです。自動 retry はありません。既存の展開先は内容を検証して抽出せず再利用し、header の更新時刻を保持します。展開先が無効なら、削除が必要な directory の path を示して失敗します。新しい展開先を作る場合は、アーカイブの SHA-256 を抽出・公開前に照合します。有効な展開先を再利用するときはアーカイブをハッシュしません。展開先がない場合は、スクリプトが作成した残存 `.extract-*` directory と download 一時ファイルを削除してから、一時 staging に展開します。tar の `data` filter を使い、ZIP の絶対 / drive path を拒否します（[Python `tarfile`](https://docs.python.org/3.12/library/tarfile.html)、[`zipfile`](https://docs.python.org/3.12/library/zipfile.html)）。期待する root が staging 内に1つだけあることと、header・platform library・`LICENSE`・ThirdPartyNotices.txt を検証し、未作成の展開先へ `os.replace` で公開します（[`os.replace`](https://docs.python.org/3.12/library/os.html#os.replace)）。

| archive | SHA-256 |
| --- | --- |
| `onnxruntime-win-x64-1.31.0.zip` | `3958d8a44984160692c1b4ffd0de3cb48f8c39f9d34bb31e433db06e30b82195` |
| `onnxruntime-win-arm64-1.31.0.zip` | `ef6206fa8d6975878d93a97035d280240ce5764c126a7430e5427e18923316d5` |
| `onnxruntime-linux-x64-1.31.0.tgz` | `cc5c72baf5ae5c8238a6841f0897227be2d02826b9cf98eaf02fdefaeeb03a57` |
| `onnxruntime-linux-aarch64-1.31.0.tgz` | `c5b8b3cca31f3d643a3b313b8f42e2d0f16a4fcefd02cda343d97bd5306afaab` |

SwiftPM は取得 SDK の header / library へ固定したリポジトリ内パスで接続します。Windows は import library の絶対パス、Linux は versioned `.so` の絶対パスと取得済み library directory の絶対 rpath を使い、pkg-config や system library search は使いません。SDK 不足時は fetch command 付きの manifest error で停止します。SwiftPM は Linux / Windows で ONNX Runtime SDK を `binaryTarget` として扱えず、`systemLibrary` target に binary を同梱できないため、fetch した local SDK を使います。`systemLibrary` に `cSettings` がないため、共通の `-Xcc -I` include 設定を `MacAmbientJevONNX` と `MacAmbientJevONNXTests` の target-local `swiftSettings` に個別適用します（[SwiftPM PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)）。fetcher の asset/version/platform 対応と manifest の compile-time version/platform 対応は、manifest で Python を実行せずに link / path を決定・検証するため双方に必要です。version literal は各 source に1つずつ置き、path / version は shim、PowerShell runner、workflow に重複させません。local SDK と linker `unsafeFlags` に依存するため、これは外部配布用 Swift package ではなくリポジトリ内の開発 build です。

Headless Pipeline consumer と P4 engine の run loop は DispatchQueue.main と MainActor executor の処理を継続して drain する必要があります。Pipeline の processing / live transcription coordinators は `@MainActor` で動作し、[`MicInputVolumeController`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/MicInputVolumeController.swift) も DispatchQueue.main.asyncAfter で timeout を進めます。どちらかを drain しないと coordinator の処理や timer callback が進みません。状態型と coordinator の責務は [architecture.md](architecture.md) を参照してください。

## Silero VAD フレーム推論

`MacAmbientJevONNX` の `SileroVAD` は、Silero VAD の単一16 kHz mono frame から speech probability を返す stateful API です。公開 API は `SileroVAD(environment:modelURL:intraOpThreads:)`、`SileroVAD.frameSamples`、`speechProbability(frame:)`、`snapshot()`、`restore(_:)`、`reset()` で、初期化引数はすべて必須です。`snapshot()` は recurrent state と context の値を保存し、`restore(_:)` はそれを戻します。数 frame を進めた後に失敗した処理を取り消すために使います。`frameSamples` は512です。モデル URL を明示し、実行時に環境変数から推論モデルを探しません。`MacAmbientJevONNX` は Foundation と `CONNXRuntime` のみに依存し、プロセス共有の `ONNXEnvironment` は呼び出し側が作成・共有します。インスタンスは状態を持ち、Swift concurrency 上は non-sendable であるため、呼び出し側が呼び出しを直列化します。

固定 ONNX model は upstream v6.2.3 release の commit `5cd7945676eb32225748052e2e6a0580e4686a08` にある [src/silero_vad/data/silero_vad_16k_op15.onnx](https://raw.githubusercontent.com/snakers4/silero-vad/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/data/silero_vad_16k_op15.onnx) です。この opset 15 export は v6.2.1 の Silero VAD model weights を使います。取得した実ファイルの SHA-256 は `7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49` です。upstream の [model.py](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/model.py) は opset 15 用にこのファイルを選びます。この API は16 kHz のみを受け取ります。固定 revision の [LICENSE](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/LICENSE) は MIT License、Copyright (c) 2020-present Silero Team です（[v6.2.3 release](https://github.com/snakers4/silero-vad/releases/tag/v6.2.3)）。

ONNX 推論では `input[1, 576]`、`state[2, 1, 128]`、`sr[] = 16000` を渡し、出力 `output[1, 1]` と `stateN[2, 1, 128]` を検証します。1 frame は `SileroVAD.frameSamples` の512 sample（16 kHz で32 ms）です。新しい frame に64 sample context を連結し、初期 context と recurrent state `[2, 1, 128]` はゼロです。推論に成功した場合に限り `stateN` と新しい frame の末尾64 sample を次 frame 用に保持します。`reset()` は session を保持したまま state と context をともにゼロに戻します。state の初期化・reset は固定 revision の上流 [`reset_states` (L103–107)](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/utils_vad.py#L103-L107)、frame 推論は [`__call__` (L109–144)](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/utils_vad.py#L109-L144) の実装を mirror します。単体 API は frame の padding、chunking、sample-rate conversion を行いません。512 sample 以外または有限でない入力は明示的なエラーとなります。確率出力は float32 `[1, 1]`、有限値かつ `[0, 1]` 内であることを検証し、state 出力は float32 `[2, 1, 128]` で有限であることを検証します（state の値域は制約しません）。検証に成功する前に状態を更新しません。

Mac は FluidAudio 0.15.8 の Core ML artifact `silero-vad-unified-256ms-v6.2.1` を使います（[FluidAudio VAD docs](https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.8/Documentation/VAD/GettingStarted.md)、[release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.8)、[artifact metadata](https://huggingface.co/FluidInference/silero-vad-coreml/commit/b419383c55c110e2c9271fa6ee0ea83d03c70d96)、[model README](https://huggingface.co/FluidInference/silero-vad-coreml/raw/main/README.md)）。segmentation layer は16 kHz の連続 recurrent state で連続する512-sample frameを8個処理し、各 frame probability を noisy-OR `1 − Π(1 − p_i)` で集約した256 msごとの確率に threshold 0.50 を適用します。最後の部分 chunk は最後の sample の反復で埋めます。ONNX の `SileroVAD` は同じ v6.2.1 weights を使う opset 15 export から frame probability を返します。ONNX 側は PortableRuntime の `SileroChunkScorer` が同じ8 frame/noisy-OR/部分 chunk の最後の sample 反復で256 msごとの確率を作り、threshold 0.50 は Pipeline の区間検出が適用します。この集約は `SileroVAD` 単体 API の処理ではありません（[Silero VAD の区間検出](#silero-vad-の区間検出)）。

[`fetch_silero_vad.py`](../scripts/fetch_silero_vad.py) は Python 3.12 以上の標準ライブラリのみを使う引数なし fetcher です（[Python 3.12 release](https://docs.python.org/3.12/whatsnew/3.12.html)）。固定 raw GitHub URL だけから取得し、retry や代替 URL は使わず、ダウンロード後と既存ファイルの再利用時に SHA-256 を検証します。不一致は再ダウンロードせずエラーにします。symlink、リポジトリ外 path、通常ファイルでない cache entry を拒否し、一時ファイルを検証してから `os.replace` で公開します。成功時の stdout は検証済み絶対 path 1行のみで、保存先は `.build/silero-vad/5cd7945676eb32225748052e2e6a0580e4686a08/silero_vad_16k_op15.onnx` です。両 fetcher は [`pinned_download.py`](../scripts/pinned_download.py) を共有し、repository directory の検証と hash 検証付き atomic file download を行います。download staging は Python 3.12 の [`tempfile.mkstemp`](https://docs.python.org/3.12/library/tempfile.html#tempfile.mkstemp) を使います。ONNX Runtime の archive extraction は fetcher 固有です。

モデル path の環境変数 `MAC_AMBIENT_JEV_SILERO_MODEL` は ONNX と PortableRuntime の test harness 専用です。未設定・空・欠損の場合は fetch command を示すエラーになり、test は skip しません。`MacAmbientJevONNXTests` は連続無音 frame の確率が0.1未満、有声 RMS 0.01 以上の frame の70%以上で確率が0.5以上となること、reset 後の bitwise 再現性と speech 後に reset した無音の一致、recurrent state / context の frame 間引継ぎを検証します。不正 frame と非有限値は状態を変えません。固定 revision の上流参照確率も許容差 `1e-4` で照合します。Linux で手動設定する場合は repository root で次を実行します。Bash は fetch 結果を先に変数へ代入してから `export` し、失敗 status を保持します（[Bash simple command expansion](https://www.gnu.org/software/bash/manual/html_node/Simple-Command-Expansion.html)）。

```bash
set -e
model="$(python3 scripts/fetch_silero_vad.py)"
export MAC_AMBIENT_JEV_SILERO_MODEL="$model"
python3 -B scripts/test_fetch_silero_vad.py
python3 -B scripts/test_pinned_download.py
python3 -B scripts/test_generate_silero_reference.py
```

同梱の [`silero_speech.wav`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/silero_speech.wav) は mono PCM16・16 kHz で、SHA-256 は `c807432e609c0357593243253e089ae5710755ac6bd2ac30d74420fef09d9731` です。元の英文は “Hello, this is a speech recording for voice activity detection.” です。[`generate_silero_speech_fixture.py`](../scripts/generate_silero_speech_fixture.py) は Ubuntu 24.04 を含む `swift:6.2-noble` image の espeak-ng と espeak-ng-data `1.51+dfsg-12build1` で en-us、speed 150、pitch 50、amplitude 100 を指定して生成します。生成した22,050 Hz 音声を整数有理数 linear interpolation（ties-to-even）で16 kHz に変換し、512 sample 境界までゼロ padding します。この変換は fixture 専用で、アプリの SRC ではありません。再生成コマンドは次のとおりです。

```bash
docker run --rm -v "$PWD:/repo" -w /repo swift:6.2-noble bash -lc 'apt-get update && apt-get install -y python3 espeak-ng=1.51+dfsg-12build1 espeak-ng-data=1.51+dfsg-12build1 && python3 scripts/generate_silero_speech_fixture.py'
```

fixture は eSpeak NG（GPL-3.0-or-later）の出力で、eSpeak NG は生成にのみ使用して同梱せず、元の英文・音声は CC0-1.0 です（[COPYING](https://raw.githubusercontent.com/espeak-ng/espeak-ng/1.51/COPYING)、[guide](https://github.com/espeak-ng/espeak-ng/blob/1.51/docs/guide.md)）。

[`silero_reference.json`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/silero_reference.json) は固定 revision の上流 [utils_vad.py](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/utils_vad.py#L103-L144) にある OnnxWrapper が生成した参照値を保存します。reference generator は上流 script の SHA-256 `15d0f6b3ef9590e22ca2f146e1436f6901da356cb552d3183df4100862b333cb` を照合し、PCM16 を `32768` で正規化します。有声 frame の確率0.5以上の割合が0.70未満、または無音 frame の確率が0.1以上なら、reference JSON を書き込む前に失敗します。再生成には `uv` と次の固定依存を使います。

```bash
uv run --with onnxruntime==1.31.0 --with numpy==2.5.4 --with torch==2.14.1 --with packaging==26.3 python scripts/generate_silero_reference.py --model "$(python3 scripts/fetch_silero_vad.py)"
```

参照 frame index は `0, 1, 2, 4, 8, 16, 32, 48, 64, 80, 100, 120, 140` です。Swift test は同梱 JSON を使うため、実行時に Python は必要ありません。

## Silero VAD の区間検出

Linux / Windows の確定処理 VAD とライブ VAD は、Mac と同じ区間規則を Silero VAD の確率に適用します。規則は Mac と共有する部分を Pipeline、ONNX Runtime を使う部分を PortableRuntime に置きます。

| 型 | target | 役割 |
| --- | --- | --- |
| `VADSegmentationParameters` | Pipeline | 区間規則の定数。chunk 4,096 sample（256 ms）、開始閾値 0.50、pre-roll 0.10 秒、最大区間 14.0 秒、無音 0.75 秒、分割探索 2.0 秒、エネルギー frame 0.02 秒、独立区間の最短 0.5 秒。Mac の `FluidVADSegmentationEngine` も同じ値を使う |
| `VADSegmentationState` | Pipeline | VAD event から [`SegmentationAssembler`](../app/MacAmbientJev/Sources/MacAmbientJevCore/Segmentation.swift) で区間を作る。pre-roll、14 秒到達時の最も静かな 20 ms frame での分割、独立区間の最短長を扱う。Mac と共有する |
| `VADStreamingStateMachine` | Pipeline | chunk ごとの確率から発話の開始・終了 event を作る |
| `VADChunkScoring` | Pipeline | 部分 chunk の最後の sample 反復による padding と、8 frame の noisy-OR |
| `VADProbabilitySegmenter` | Pipeline | `VADStreamingStateMachine` と `VADSegmentationState` を連結し、chunk の確率から区間を作る。ONNX Runtime を使わずにテストできる |
| `SileroChunkScorer` | PortableRuntime | 4,096 sample を8個の512-sample frame として1つの `SileroVAD` に順に通し、`VADChunkScoring` で256 msの確率にする。recurrent state は chunk をまたいで続く |
| `SileroVADSegmentationEngine` | PortableRuntime | `VADChunkSegmenting` の実装。`SileroChunkScorer` と `VADProbabilitySegmenter` を持つ |
| `SileroFinalTranscriptVADSegmenter` | PortableRuntime | `FinalTranscriptVADSegmenter` の実装。`environment`、`modelURL`、`intraOpThreads` はすべて必須 |
| `SileroLiveVADSessionFactory` | PortableRuntime | `LiveVADSession` を作る。引数は Mac の `MacLiveVADSessionFactory` に `environment`、`modelURL`、`intraOpThreads` を加えたもの |

PortableRuntime は Mac の `MacAmbientJevRuntime` に対応する、Linux / Windows の推論 engine の置き場で、Core、Pipeline、MacAmbientJevONNX に依存します。MacAmbientJevONNX は Foundation と `CONNXRuntime` だけに依存する汎用層のままにし、Core の型に依存する engine を分けています。`scripts/check_portable_core.py` は PortableRuntime の import も検査します。

発話の開始・終了判定は FluidAudio 0.15.8 の [`streamingStateMachine`](https://raw.githubusercontent.com/FluidInference/FluidAudio/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/VAD/VadManager+Streaming.swift)（Apache-2.0）から、アプリが使う経路だけを移植した `VADStreamingStateMachine` です。出典は [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md#fluidaudio) に記載しています。Mac の `FluidVADSegmentationEngine` は FluidAudio の streaming API をそのまま使います。

- 確率が0.50以上なら無音の計測を解除します。未開始なら、その chunk の先頭 sample を開始位置にして発話を開始します。
- 発話中に確率が終了閾値 0.35（開始閾値 0.50 から FluidAudio の offset 0.15 を引いた値）を下回ると、その chunk の末尾から無音を数え始めます。0.35 以上 0.50 未満の確率は無音の開始も解除も行いません。
- 無音が0.75秒（12,000 sample）以上続くと発話を終了します。終了位置は、無音を数え始めた位置から現在の chunk の長さを引いた sample です。
- speech padding は0です。pre-roll は区間組み立てが加えます。
- 処理済み sample 数には部分 chunk の実際の長さを足します。padding した sample は数えません。

chunk の途中で ORT がエラーを返した場合、`SileroChunkScorer` は `SileroVAD.snapshot()` で state を戻してから error を投げます。同じ chunk を再度渡しても、結果は失敗がなかった場合と一致します。

確定処理の来歴は `engine = onnxruntime-silero-vad`、`model = silero_vad_16k_op15.onnx`、`version = silero-vad@<commit>+onnxruntime@1.31.0` です。configuration の値は [storage.md](storage.md#run-の来歴) にあります。固定 model の commit と SHA-256 は `SileroVADModel` に置き、`test_fetch_silero_vad.py` が `fetch_silero_vad.py` の値との一致を検査します。

### Mac との一致

Mac の FluidAudio（Core ML、`silero-vad-unified-256ms-v6.2.1`）と Silero の ONNX は同じ v6.2.1 weights ですが、Core ML は mixed float16 で動作し、recurrent state を frame ごとに float16 へ丸めます。ONNX は float32 です。256 msごとの確率は同じ値になりません。parity fixture では次の3点を検査します。

1. 区間の開始・終了 frame が完全に一致します（許容差 0 frame）。
2. すべての chunk で、ONNX と Core ML の確率が開始閾値 0.50 と終了閾値 0.35 のそれぞれに対して同じ側にあります。
3. chunk ごとの確率差は 0.25 以下です。

[`vad_parity.json`](../app/MacAmbientJev/Tests/MacAmbientJevVADFixtures/vad_parity.json) は Mac の FluidAudio が2つの入力に対して出した256 msごとの確率と区間です。入力は `silero_speech.wav`（4.5秒）から作ります。`speech_clip` はその音声そのもので、部分 chunk で終わります。`pauses_and_long_utterance` は0.75秒未満・以上の無音、約19秒続く発話（14秒の分割を起こす）、音声の途中で終わる部分 chunk を含む約43秒です。入力の組み立ては [VADParityFixture.swift](../app/MacAmbientJev/Tests/MacAmbientJevVADFixtures/VADParityFixture.swift) にあり、追加の音声ファイルはありません。

測定値は次のとおりです。`speech_clip` は18 chunk、最大差 0.0373（最後の部分 chunk）、平均差 0.0021 です。`pauses_and_long_utterance` は168 chunk、最大差 0.2015（chunk 20、発話終了の直後で ONNX 0.665、Core ML 0.867）、平均差 0.0130 です。どちらも全 chunk が両閾値に対して同じ側にあり、区間の開始・終了 frame は完全に一致します。ONNX が閾値に最も近い chunk は chunk 122（ONNX 0.505、Core ML 0.621）で、余裕は 0.005 です。確率差は最大 0.2 あるため、確率が閾値付近にある chunk を含む録音では、Mac と Linux / Windows で区間が異なることがあります。区間の完全一致は fixture の2入力で確認した結果で、任意の録音に対する保証ではありません。

fixture は Mac で次のコマンドにより生成します。

```bash
MAC_AMBIENT_JEV_WRITE_VAD_PARITY=1 swift test --package-path app/MacAmbientJev --filter VADParityFixtureTests/writeParityFixture
```

Mac の [VADParityFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/VADParityFixtureTests.swift) は、実行ごとに FluidAudio の出力が保存済み fixture と一致すること（確率差 0.05 以下、区間は完全一致）と、fixture の FluidAudio の確率を `VADProbabilitySegmenter` に通すと fixture の区間と完全に一致すること（移植した状態機械と FluidAudio の状態機械の一致）を検査します。Linux / Windows の [SileroVADParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/SileroVADParityTests.swift) は、同じ入力を Silero engine に通して上の3点を検査します。[SileroVADEngineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/SileroVADEngineTests.swift) は、ライブ VAD が durable chunk に分けた音声から同じ区間を作ること、provenance、失敗した chunk の再試行を検査します。ORT を使わない状態機械と区間組み立ては [VADStreamingTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/VADStreamingTests.swift) と [VADSegmentationStateTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/VADSegmentationStateTests.swift) が検査します。

## 熱状態

Pipeline の [`ThermalMonitoring`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/ThermalMonitoring.swift) contract は `isCritical`（確定処理の pause / resume 判定）と `liveASRDecision`（live ASR の policy）です。Windows の `WindowsNoThermalMonitoring` は thermal state を読み取らず、`isCritical == false` と `.processNow` を返します。Windows では熱状態を測定・推定せず、nominal state を設定することもありません。Windows では熱状態によるライブ ASR 待機・確定処理一時停止を行いません（[製品ルールの熱状態](decisions.md#熱状態)）。

Mac の [`MacThermalMonitor`](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/MacThermalMonitor.swift) は `ProcessInfo.thermalState` を使う具体実装です。Mac の nonoptional `state` / `pressure` と live/finalization の policy 境界は [architecture.md](architecture.md#portable-core-の境界) を参照してください。Mac app とファイル処理・システム音声・遅延計測 CLI が同じ監視元を使います。

## 音声 import API

`MacAmbientJevWindowsSupport` の `AudioFileTimelineBuilder` は、Core の `AudioImporter` がセッションへ無再圧縮コピーした original を bounded chunk 単位で読み、mono 化・sample-rate conversion 後の 16 kHz mono float32 PCM processing timeline を生成します。`.wav` / `.flac` / `.mp3` は miniaudio 0.11.23、`.m4a` / `.aac` は Windows Media Foundation AAC Source Reader で decode します。miniaudio の参照版は [0.11.23 release](https://github.com/mackron/miniaudio/releases/tag/0.11.23) です。拡張子の大文字・小文字は区別しません。未対応の拡張子、拡張子なし、対応拡張子でも decode できないファイルは、日本語の明示的なエラーで拒否し、別 decoder へ fallback しません。native read / seek error は EOF として扱わず、エラーとして伝播します。

入力は `SessionFileAccess.openHandle` で開いた session-pinned file handle です。miniaudio はこの handle の descriptor を読み、Media Foundation は同じ handle を複製して read-only IStream / byte stream を作り、MFCreateSourceReaderFromByteStream に渡します。Media Foundation が元ファイルの URL / pathname を再度開く経路はありません。詳細は Microsoft の [Source Reader によるメディアデータ処理](https://learn.microsoft.com/en-us/windows/win32/medfound/processing-media-data-with-the-source-reader) と [MFCreateSourceReaderFromByteStream](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-mfcreatesourcereaderfrombytestream) を参照してください。

各 chunk の全 channel を算術平均して mono にし、Core の `CanonicalAudioConverting` API を実装する Windows resampler へ渡します。16 kHz 以外では miniaudio 0.11.23 の公開 `ma_linear_resampler` API と order 8 Butterworth 低域フィルター（linear LPF8）を使います。公開 `ma_linear_resampler_config.lpfNyquistFactor` を `0.95` に設定し、カットオフを `min(sourceRate, 16000) / 2 × 0.95` とします。48 kHz から 16 kHz への downsampling cutoff は 7,600 Hz です。C wrapper は実際の 4 個の biquad section の Q 値（0.50979557910415918、0.60134488693504529、0.89997622313641557、2.5629154477415055）から DC group delay を計算し、最も近い整数の output frame 数へ丸めて返します。Swift 側はその frame 数を先頭出力から補償します。EOS では filter state をゼロ入力で進め、filter tail を音声時間に加えず、`CanonicalAudio.boundary(sourceFrames, sampleRate: sourceRate)` が定める（`round(sourceFrames * 16000 / sourceRate)`）半開区間の frame 数に切り詰めます。source rate は正の整数 UInt32 のみ受け付け、16 kHz は変換なしで通します。

Media Foundation AAC Source Reader は decode した native frames を canonical timeline に含め、AAC encoder priming / padding を除去しません。また、Media Foundation は AAC encoder priming を示す marker を付けません。Apple が encode した M4A は一般に 48 kHz で 2,112 frames（約 44 ms）の priming を含みます。Windows import ではこの priming を保持するため、Mac import より duration が長くなり、信号・イベント時刻も priming 分だけ後ろになります。Windows は累積 source extent を丸めた frame 境界まで出力します。一方、AVAudioConverter は EOS まで drain して正確な変換長の floor または ceil にあたる出力を保持します。同じ decoded source extent を SRC した場合、終端 frame 数は boundary rounding により Apple と Windows で最大 1 frame 異なることがあります。これは AAC priming の保持による差とは別です。sample 値も platform 間で bit-identical ではありません。

`ImportedAudioTimelineWriter` は Core 共通 API で、AppleSupport と WindowsSupport の両 builder が再利用します。mono canonical PCM を 5 秒単位の durable storage chunk と checkpoint に書き込みます。timeline metadata の公開は builder の外側、呼び出し側が行います。この Windows import API は live capture、UI、session processing engine へ接続されていません。WASAPI backend は capture path 向けに CMiniaudio にコンパイルされますが、Windows の capture 実装はありません。

### WindowsSupport テスト

`MacAmbientJevWindowsSupportTests` はテスト中に生成する WAV と同梱の FLAC / MP3 / M4A / AAC fixture により、デコード、import copy の保持、timeline frame boundary、再構築時の partition invariant、symlink を含む session 境界、未対応拡張子・破損ファイルに対する日本語エラーを検証します。

RIFF / RIFX WAV では、miniaudio 0.11.23 の `dr_wav` が宣言 data size を clamp する前に、セッションに固定された file handle 上で data chunk の payload 先頭位置 + 宣言 data size をファイルの物理サイズと照合します（[miniaudio 0.11.23 source](https://raw.githubusercontent.com/mackron/miniaudio/0.11.23/miniaudio.h)）。RIFF / RIFX container の宣言 extent はこの判定に使いません。data size が `0xFFFFFFFF` の WAV は物理サイズとの照合対象から除外し、streaming WAV を受け入れます。data payload 全体が物理サイズ内にあれば、後続 LIST chunk の実体が宣言より短い場合、RIFF outer size が物理サイズと 8 bytes 異なる場合、最後の data pad byte が欠けている場合も音声を受け入れます。回帰テストは streaming、短い trailing LIST、8 bytes 大きい outer size の各 WAV で import 成功を確認します。

RF64 WAV / FLAC では、デコード位置が宣言 frame 数に達する前に miniaudio が終端を返した場合、基礎ファイルの位置が物理終端にあるときに限り `AudioImportError.unexpectedEOF` とし、物理終端より前なら `MA_INVALID_DATA` によるデコード失敗とします。発生した read error は decoder の再 read でも保持されます。回帰テストでは、途中の FLAC subframe header の破損を物理 EOF より前のデコード失敗として確認します。CRC だけが壊れた FLAC では decoder が frame を skip して物理 EOF まで進むことがあり、CRC error 全般を個別のデコード失敗として検出するわけではありません。`AudioImportError.unexpectedEOF` の日本語メッセージは `音声ファイルが宣言されたフレーム数より前に終了しました。` です。

FLAC STREAMINFO の総サンプル数が 0 の場合、timeline model が宣言済み長さを必要とするため、デコーダー作成時に `AudioImportError.missingTotalSampleCount` を返します。日本語メッセージは `FLAC の総サンプル数が記録されていません。` です。借用した CRT descriptor を write-only descriptor に置き換えて `MA_IO_ERROR` を誘発するテストでは、native I/O エラーが clean EOF として扱われず、終端エラーとして保持されることも確認します。

fixture は [generate_windows_audio_fixtures.py](../scripts/generate_windows_audio_fixtures.py) が [FFmpeg 8.0](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.0/Changelog) で生成します。resampler の仕様と miniaudio 0.11.23 の出典は [CMiniaudio README](../app/MacAmbientJev/Sources/CMiniaudio/README.md) と [miniaudio 0.11.23 release](https://github.com/mackron/miniaudio/releases/tag/0.11.23) を参照してください。Media Foundation の byte-stream API は [WinSDK 26100: MFCreateSourceReaderFromByteStream](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-mfcreatesourcereaderfrombytestream) を参照してください。

Resampler の連続 SRC テストは 8 / 16 / 22.05 / 44.1 / 48 / 96 kHz を使い、WAV と SRC の interior sine error を 0.025 未満、whole-buffer と異なる read partition 間の差を 1e-6 未満で検査します。別の regression test は、48 kHz の同振幅 1 kHz / 11 kHz tone を 16 kHz へ downsample し、11 kHz tone の rejection が 30 dB 以上であることを確認します。

FLAC / MP3 fixture は 48 kHz stereo、375 Hz の音声です。M4A / AAC の marker fixture は 48 kHz stereo で、silence、700 Hz から 3,700 Hz への chirp、silence、375 Hz sine の順に信号を配置します。M4A / AAC は Media Foundation の AAC priming を trim せず、marker の onset と canonical timeline 上の位置を確認します。marker は `abs(sample) > 0.05` で検出します。FLAC / MP3 の compressed interior sine error と M4A / AAC の sine error は 0.06 未満です。

FLAC 形式の仕様は [RFC 9639 (December 2024)](https://www.rfc-editor.org/rfc/rfc9639.html) を参照してください。

## Qwen3-ASR の prompt と token decoder

Linux / Windows の ONNX ASR engine は、PortableRuntime の [Qwen3ASR](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Qwen3ASR) ディレクトリにある prompt 生成と token id から text への復元を使います。どちらも ONNX Runtime を呼ばない純粋な Swift で、モデルの入出力は別の層が扱います。

`Qwen3ASRPrompt(audioTokenCount:)` は、encoder の出力 token 数 N（1以上）から decoder に渡す `input_ids`（Int64）を作ります。N が0以下なら `Qwen3ASRError.invalidAudioTokenCount` で失敗します。言語は日本語に固定し、引数にしません。並びは Mac engine（speech-swift）の prompt と同じです。

```text
[151644, 8948, 198, 151645, 198, 151644, 872, 198, 151669]
+ [151676] * N
+ [151670, 151645, 198, 151644, 77091, 198, 11528, 11937, 151704]
```

先頭の9個が `<|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>`、末尾が `<|audio_end|><|im_end|>\n<|im_start|>assistant\nlanguage Japanese<asr_text>` です。decoder graph の `audio_offset` は `Qwen3ASRPrompt.audioOffset`（9、最初の `<|audio_pad|>` の位置）です。

`Qwen3ASRTokenDecoder` は Hugging Face 形式の tokenizer.json から、復元に必要な `model.vocab` と `added_tokens`（`id`、`content`、`special`）だけを読みます。vocab の各 token は文字ごとに GPT-2 の ByteLevel の byte-unicode 表で byte に戻し、id ごとの byte 列にします。`special` の added token は text を出さず、それ以外の added token（`<think>`、`<asr_text>` など）は `content` をそのまま UTF-8 として使います。復元した byte 列全体は厳密に UTF-8 として解釈し、不正な列（1文字が複数 token に分かれた途中で終わる場合を含む）はエラーです。次の場合は明確なエラーで失敗します。

- ファイルがない、または JSON として不正
- `model.type` が BPE でない、または `decoder.type` が ByteLevel でない
- vocab に ByteLevel の文字集合にない文字がある
- id が vocab と added token の間、または added token 同士で重複する
- 復元時の id が tokenizer にない

`transcript(generatedIDs:endedAtTokenCap:)` は生成 id から認識結果の text を作ります。id が151704（`<asr_text>`）を含む場合は、最後の出現より後ろだけを使います。マーカーは `<asr_text>` が special ではなく text として復元されてしまうため、復元後の text ではなく id で探します。停止 token（151645 `<|im_end|>`、151643 `<|endoftext|>`）を除いて復元し、前後の空白と改行を削ります。マーカーがなければ全体を復元します。Mac の Qwen3ASR モデル（speech-swift）はマーカーを復元後の text から探して最初の出現より後ろを取り、前後の空白（改行は除く）を削ります。Linux / Windows は最後の出現より後ろを取り、改行も削る点と、未知の id を黙って飛ばさず失敗させる点で異なります。

[`fetch_qwen3_asr_tokenizer.py`](../scripts/fetch_qwen3_asr_tokenizer.py) は `fetch_silero_vad.py` と同じ仕様の引数なし fetcher で、[`pinned_download.py`](../scripts/pinned_download.py) を使います。取得元は [andrewleech/qwen3-asr-1.7b-onnx](https://huggingface.co/andrewleech/qwen3-asr-1.7b-onnx) の commit `df916193ac67e59347769891a21e10d81d12acdd` の tokenizer.json（11,429,377 byte、SHA-256 `bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92`）で、保存先は `.build/qwen3-asr-tokenizer/<commit>/` 配下、成功時の stdout は検証済み絶対 path 1行のみです。自己 test は `test_fetch_qwen3_asr_tokenizer.py` です。

tokenizer の path は test 専用の環境変数 `MAC_AMBIENT_JEV_QWEN3_TOKENIZER` で渡します。未設定・空・欠損の場合は fetch command を示すエラーになり、test は skip しません。`verify_portable.sh`、`test-windows.ps1`、`portable-core.yml` の Linux job が fetch して設定します。

[`qwen3_tokenizer_golden.json`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_tokenizer_golden.json) は実際の tokenizer.json を Python の `tokenizers` 0.23.3（`skip_special_tokens=True`）で復元した期待値です。日本語、ASCII 混在、句読点、改行、絵文字、1文字が複数 token に分かれる場合、special / 非 special の added token、transcript の規則を含みます。再生成は次のとおりで、同じ入力から同じ JSON を出力します。

```bash
uv run --python 3.12 --with tokenizers==0.23.3 python scripts/generate_qwen3_tokenizer_fixture.py --tokenizer "$(python3 scripts/fetch_qwen3_asr_tokenizer.py)"
```

Swift の test は [Qwen3ASRPromptTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRPromptTests.swift) と [Qwen3ASRTokenDecoderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRTokenDecoderTests.swift) にあり、上の fixture との照合と、合成した小さな tokenizer による各エラーの検査を行います。

### Qwen3-ASR ONNX モデルの取得

[`fetch_qwen3_asr_model.py`](../scripts/fetch_qwen3_asr_model.py) は Python 3.12 以上の標準ライブラリだけで動きます。CLI はサイズと保存先の両方を必須とし、サイズは `0.6b` または `1.7b` だけです。既定のサイズ・保存先はありません。

```text
python3 scripts/fetch_qwen3_asr_model.py <size> <destination>
```

`destination` は絶対パスで指定する、事前に存在するディレクトリです。相対パス、未作成のパス、ディレクトリでないパスは拒否されます。保存先の基底ディレクトリ（destination）は呼び出し側が事前に作成してください。fetcher は基底ディレクトリを作らず、モデルを `<destination>/qwen3-asr-<size>-int4-<commit>/` に取得します。作成するモデル保存先はこの子 directory のみです。以下は使用例であり、既定値ではありません。

```bash
# /absolute/path/to/models は事前に作成しておく
python3 scripts/fetch_qwen3_asr_model.py 0.6b /absolute/path/to/models
```

```powershell
# D:\Models\qwen3-asr-onnx は事前に作成しておく
python scripts/fetch_qwen3_asr_model.py 1.7b D:\Models\qwen3-asr-onnx
```

取得元は Apache-2.0 の Hugging Face repository を commit 固定で使います: [andrewleech/qwen3-asr-0.6b-onnx (`4fc24a1402e74db89c4d2ef256875e71680128c4`)](https://huggingface.co/andrewleech/qwen3-asr-0.6b-onnx/tree/4fc24a1402e74db89c4d2ef256875e71680128c4) と [andrewleech/qwen3-asr-1.7b-onnx (`df916193ac67e59347769891a21e10d81d12acdd`)](https://huggingface.co/andrewleech/qwen3-asr-1.7b-onnx/tree/df916193ac67e59347769891a21e10d81d12acdd)。取得 URL はこれらの固定 commit を直接指定し、[Hub REST API](https://huggingface.co/docs/hub/api) を使った最新版の解決、retry、代替 URL / filename への fallback は行いません。両 repository には `encoder.onnx` と、サイズ・SHA-256 が同じ `encoder.int4.onnx` の両方がありますが、fetcher は `encoder.onnx` を取得し、別名を試しません。

モデル directory には次の6ファイルを取得します: `encoder.onnx`、`decoder_init.int4.onnx`、`decoder_step.int4.onnx`、`decoder_weights.int4.data`、`embed_tokens.bin`、tokenizer.json。decoder の ONNX proto が参照する external-data の場所は厳密に `decoder_weights.int4.data` です。このファイルは同じ directory にこの名前で置く必要があります。[`pinned_download.py`](../scripts/pinned_download.py) が新規・既存ファイルの SHA-256 を検証し、fetcher はさらに各ファイルの正確な byte 数を検証します。不一致は再ダウンロードせず失敗します。 全6ファイルが存在し、サイズと SHA-256 がすべて一致する場合は、再実行してもネットワークから取得せず同じモデル directory を返します。

モデル重みの保存先は `.build` cache ではなく、指定した外部 directory です。外部の永続保存先は worktree 間で共有できます。既存の [`fetch_qwen3_asr_tokenizer.py`](../scripts/fetch_qwen3_asr_tokenizer.py) は tokenizer のみを `.build/qwen3-asr-tokenizer/<commit>/` に保存します。

成功時の stdout は取得したモデル directory の絶対パス1行だけです。終了コードは成功が `0`、引数・サイズ・保存先の不正が `2`、Python version、取得、integrity、OS の失敗が `1` です。[`test_fetch_qwen3_asr_model.py`](../scripts/test_fetch_qwen3_asr_model.py) はネットワーク上のモデル重みに依存しない offline self-test で、[`verify_portable.sh`](../scripts/verify_portable.sh) と [`test-windows.ps1`](../scripts/test-windows.ps1) から実行されます。これらの runner は full model weights を自動取得しません。この取得スクリプトと helper はモデル配布用であり、Qwen3-ASR engine の統合を意味しません。

### Qwen3-ASR の embedding と greedy 生成

PortableRuntime には、実モデルを使わずにテストできる純粋 Swift の embedding・生成・text helper があります。これらは部品であり、Qwen3-ASR engine として統合されていません。`Qwen3ASREmbeddingTable(contentsOf:vocabSize:hiddenSize:)` は `embed_tokens.bin` を FP16 little-endian、row-major として読み、実際の語彙数 `151936` と hidden size `1024` / `2048` などを呼び出し側が明示します。ファイルサイズが `vocabSize * hiddenSize * 2` と完全一致することと token ID の範囲を検証し、immutable な `Foundation.Data` を `.alwaysMapped` で memory map し、[`row(_ id: Int64) throws -> [Float]`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Qwen3ASR/Qwen3ASREmbeddingTable.swift) で選択した行だけを Float32 に変換します。ファイル全体を Swift 配列へコピーしません（[Foundation 6.2 の Data 読み込み実装](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BReading.swift)）。

`Qwen3ASRDecoderModel` は associated type Cache と `prefill(promptIDs:audioOffset:)` / `step(tokenID:position:cache:)` を定義します。prefill は位置 `0..<S` を使う契約で、最初の step は `S`、以降は1ずつ増加します。不透明な cache は Swift 配列へ変換せず各 step に渡します。汎用の `Qwen3ASRGreedyDecoder(model:)` の `generate(promptIDs:audioOffset:maxNewTokens:noRepeatNgramSize:)` は生成 ID、終了理由 `.stopToken(id)` / `.tokenCap`、`endedAtTokenCap` を返します。全引数を明示し、token cap は正数、no-repeat n-gram は `nil` または `3` のみです。停止 ID `151645` / `151643` は結果に含め、その後の step は行いません。同点では小さい ID を選び、空または NaN を含む logits はエラーです。3-gram 抑制は prompt ではなく生成済み ID だけを対象にします。engine 側の cap `448` と、音声が15秒を超える場合に3-gram抑制を有効にする方針は呼び出し側の責務です（[speech-swift の対応処理](https://github.com/soniqo/speech-swift/blob/c4c2fabbe825a9290c19e2f45d54ca3eae96b003/Sources/Qwen3ASR/Qwen3ASR.swift#L1093-L1108)）。

`transcript(generatedIDs:endedAtTokenCap:)` は既存の marker・stop token 除外・trim 規則を保ち、`endedAtTokenCap == true` の場合に限って、有効な不完全 trailing UTF-8 byte を取り除いてから厳密に decode します。それ以外の不正 UTF-8 はエラーです。`endedAtTokenCap == false` の場合と `decode(_:)` は常に厳密です。Mac は切れた byte を U+FFFD に置換しますが、ここでは cap 到達時に限り不完全末尾を除く点が異なります。[embedding tests](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASREmbeddingTableTests.swift) は合成 FP16、[greedy tests](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRGreedyDecoderTests.swift) は scripted logits を使い、モデル重みは不要です。既存の [token decoder tests](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRTokenDecoderTests.swift) も参照してください。

## Qwen3-ASR の log-mel 前処理

PortableRuntime の [`Qwen3ASRMelFrontend`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Qwen3ASR/Qwen3ASRMelFrontend.swift) は、ONNX Runtime を使わず Qwen3-ASR encoder 用 log-mel 特徴量を計算します。公開 API は `Qwen3ASRMelFrontend.init()` と `compute(samples: [Float]) throws -> Qwen3ASRMelSpectrogram` です。入力は呼び出し側が用意する16 kHz mono 音声で、この API は resampling しません。結果の `values: [Float]` は row-major の 128×T、`frameCount: Int` は T で、encoder 入力は `[1, 128, T]` です。

入力は非空・有限で、reflect padding のため最低201 sample 必要です。`T = floor(N / 160)` が120,000を超える場合は、出力確保や入力走査より前に拒否します。エラーは `Qwen3ASRMelError.emptyInput`、`inputTooShort(sampleCount:)`、`nonFiniteSample(index:)`、`tooManyFrames(Int)` で、代替処理はしません。

400 sample の periodic Hann window、hop 160、中央に左右200 sample の reflect padding を使い、保持する T frame だけを計算します。各 frame は400点の非正規化 DFT から201個の power bin を作ります。Slaney scale、128 mel、0–8,000 Hz、HTK なし、area normalization の mel filter を適用します。filter は Swift で動的に計算し、大きな固定 table は持ちません。FFT は25個の長さ16の radix-2 FFT と25項の合成で構成し、twiddle と疎な filter を cache します。ONNX Runtime、Accelerate、外部 FFT library は使わず、中間計算は Double として、大きな有限 Float 入力でも power が overflow しないようにします。各 mel 値を `log10(max(mel, 1e-10))` に変換し、保持 frame 内の最大値を M として `max(x, M - 8)` に clamp した後に `(x + 4) / 4` で正規化します。出力から除外する frame は計算せず、最大値と clamp にも含めません。

[`Qwen3ASRMelFrontendTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRMelFrontendTests.swift) は、[`qwen3_mel_golden.json`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_mel_golden.json) に対する golden 一致、入力検証、境界、正規化を検査します。6入力は、1秒の440/1,000 Hz sine mix（16,000 sample、100 frame）、180–6,200 Hz chirp（3,791、23）、0.3秒 envelope sine（4,800、30）、最後の sample（index 479）に peak を置く `last_frame_peak`（480、3）、最小 reflect 入力（201、1）、および index 558 だけに peak を置く `dropped_only_peak`（559、3）です。480-sample peak は保持 frame の window にも入るため dropped-only ではありません。559 sample では保持 window の末尾が source index 519 なので、index 558 の peak は除外 frame のみに入り、同じ長さの無音と出力が完全一致することも検査します。golden の入力は Float32 little-endian Base64、出力は row-major 全値を丸めずに JSON に保存し、Swift 照合許容差は `2e-7` です。

golden は Transformers 4.57.1 の WhisperFeatureExtractor(feature_size=128, sampling_rate=16000, hop_length=160, n_fft=400, dither=0) を使い、`_np_extract_fbank_features(audio[None, :], device='cpu')[0]` を明示的に呼び出して生成します。各入力をそのまま渡すため30秒への padding / truncation はせず、Torch 実装を自動選択しません。librosa の float64 Slaney mel filter（fmax 8,000 Hz）は公式 filter と丸め誤差の範囲で一致します。NumPy DFT の実装差を別途見る openai-whisper chirp cross-check の許容差は `5e-5` で、Swift golden の `2e-7` とは別の照合です。生成元は [Transformers Whisper feature extractor v4.57.1](https://github.com/huggingface/transformers/blob/v4.57.1/src/transformers/models/whisper/feature_extraction_whisper.py) と [openai-whisper audio.py v20250625](https://github.com/openai/whisper/blob/v20250625/whisper/audio.py) です。生成環境は Python 3.12.14、NumPy 2.2.6、librosa 0.11.0、Transformers 4.57.1、torch 2.8.0、openai-whisper 20250625 で、全47 distribution の version は fixture metadata に provenance として記録します（Swift test は version を検査しません）。librosa の変更履歴と Transformers release は [librosa 0.11.0 changelog](https://librosa.org/doc/0.11.0/changelog.html) と [Transformers v4.57.1 release](https://github.com/huggingface/transformers/releases/tag/v4.57.1) を参照してください。

fixture の再生成は、macOS arm64 で記録された生成環境の依存集合を fixture metadata から pin して実行します。host によって installed distribution metadata が変わる場合があります。Python 仮想環境と uv cache は `${TMPDIR}` 内に作り、削除しません（worktree 内には作成しません）。[`generate_qwen3_mel_fixture.py`](../scripts/generate_qwen3_mel_fixture.py) は引数なしで実行します。

```bash
set -eu
MEL_TMP="$(mktemp -d "${TMPDIR:?}/qwen3-mel.XXXXXX")"
export UV_CACHE_DIR="${MEL_TMP:?}/uv-cache"
uv venv --python 3.12.14 "${MEL_TMP:?}/venv"
python3 - "${MEL_TMP:?}/requirements.txt" <<'PY'
import json,sys
from pathlib import Path
fixture=json.loads(Path('app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_mel_golden.json').read_text())
versions=fixture['metadata']['versions']['distributions']
Path(sys.argv[1]).write_text(''.join(f'{name}=={version}\n' for name,version in sorted(versions.items())))
PY
uv pip install --python "${MEL_TMP:?}/venv/bin/python" -r "${MEL_TMP:?}/requirements.txt"
"${MEL_TMP:?}/venv/bin/python" scripts/generate_qwen3_mel_fixture.py
```

Performance test は30秒（480,000 sample）の入力を同期実行し、初回と3回の warm 実行を計測します。`QWEN3_MEL_BENCHMARK=1` を設定した場合だけ実行し、既定では skip します。release build の opt-in command は次のとおりです。

```bash
QWEN3_MEL_BENCHMARK=1 swift test --package-path app/MacAmbientJev -c release --filter Qwen3ASRMelFrontendPerformanceTests --no-parallel
```

Release / Debug の実測値、fixture 誤差、Linux test 結果は[2026-10-19 の計測記録](records/qwen3-mel-2026-10-19.md)を参照してください。

## ビルドと検証

Linux / Windows では Core のみの作業を含むすべての `swift build` の前に、リポジトリルートで ONNX Runtime fetch が必要です（Linux: `python3 scripts/fetch_onnxruntime.py`、Windows: `python scripts/fetch_onnxruntime.py`）。Python 3.12 以上を使います。Silero model fetch は build には不要で、`swift test` に必要です。テスト前に `fetch_silero_vad.py` の出力を `MAC_AMBIENT_JEV_SILERO_MODEL` に、`fetch_qwen3_asr_tokenizer.py` の出力を `MAC_AMBIENT_JEV_QWEN3_TOKENIZER` に設定します。

Swift 6.2 の Windows toolchain、対応する Visual Studio の C++ Build Tools と Windows SDK、Python 3.12 以上を用意し、リポジトリルートから実行します。全 check、ONNX Runtime SDK 取得、全適用 target の build、DLL 配置、全 test を行うコマンドは次のとおりです。

```powershell
./scripts/test-windows.ps1
```

各段階の失敗で非 0 終了します。runner は ONNX Runtime SDK / Silero model / Qwen3-ASR tokenizer fetch の stdout を UTF-8 として受け取り、終了コードと単一行出力を確認します。ONNX Runtime root は絶対 path の既存 directory として検証します。Silero path は fetcher が絶対 path と通常 file を検証し、runner は再検証しません。Silero path を test 専用 `MAC_AMBIENT_JEV_SILERO_MODEL` に設定し、ONNX Runtime SDK root の lib/onnxruntime.dll を Swift の実行 bin directory へコピーします。Silero fetcher、Qwen3-ASR tokenizer fetcher、pinned download helper、reference generator の self-test も実行します。Qwen3-ASR tokenizer の path は test 専用の `MAC_AMBIENT_JEV_QWEN3_TOKENIZER` に設定します。手動で同じ build / test を行う場合は、次のように取得し、build 後に Swift の実行 bin directory へ DLL を配置してから `swift test` を実行します。

```powershell
$env:PYTHONIOENCODING = 'utf-8'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$runtimeRoot = python scripts/fetch_onnxruntime.py
if ($LASTEXITCODE -ne 0) { throw 'ONNX Runtime fetch failed' }
python -B scripts/test_portable_core.py
python -B scripts/check_portable_core.py
python scripts/test_doc_references.py
python scripts/check_doc_references.py
python -B scripts/test_fetch_onnxruntime.py
$sileroModelPathLines = @(python scripts/fetch_silero_vad.py)
if ($LASTEXITCODE -ne 0) { throw 'Silero VAD fetch failed' }
if ($sileroModelPathLines.Count -ne 1) { throw 'Silero VAD fetch must return exactly one output line' }
$env:MAC_AMBIENT_JEV_SILERO_MODEL = [string]$sileroModelPathLines[0]
$qwen3TokenizerPathLines = @(python scripts/fetch_qwen3_asr_tokenizer.py)
if ($LASTEXITCODE -ne 0) { throw 'Qwen3-ASR tokenizer fetch failed' }
if ($qwen3TokenizerPathLines.Count -ne 1) { throw 'Qwen3-ASR tokenizer fetch must return exactly one output line' }
$env:MAC_AMBIENT_JEV_QWEN3_TOKENIZER = [string]$qwen3TokenizerPathLines[0]
python -B scripts/test_fetch_silero_vad.py
if ($LASTEXITCODE -ne 0) { throw 'Silero VAD fetcher self-test failed' }
python -B scripts/test_fetch_qwen3_asr_tokenizer.py
if ($LASTEXITCODE -ne 0) { throw 'Qwen3-ASR tokenizer fetcher self-test failed' }
python -B scripts/test_pinned_download.py
if ($LASTEXITCODE -ne 0) { throw 'Pinned download helper self-test failed' }
python -B scripts/test_generate_silero_reference.py
if ($LASTEXITCODE -ne 0) { throw 'Silero reference generator self-test failed' }
swift build --package-path app/MacAmbientJev
$binDir = (swift build --show-bin-path --package-path app/MacAmbientJev).Trim()
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'lib/onnxruntime.dll') -Destination (Join-Path $binDir 'onnxruntime.dll') -Force
swift test --package-path app/MacAmbientJev
```

`swift test` は DLL を Swift の実行 bin directory に置いた後に実行します。

ARM64 の Windows 11 では、管理者の PowerShell で [setup-winvm.ps1](../scripts/setup-winvm.ps1) を 1 回実行すると、
Visual Studio 2022 Build Tools（MSVC と Windows SDK 26100）、Swift 6.2、Python 3.12 を入れ、
symlink の作成に必要な開発者モードを有効にします。実行後はサインインし直してから検証します。

Core の FLAC テストは codec の round-trip と破損データの拒否を検証します。参照用 `flac` CLI との比較は `PATH` から実行ファイルを解決できる場合だけ実行し、見つからない場合は Swift Testing の `enabled` trait で無効になります。`flac` はテスト専用で、実行時依存ではありません。詳細は [RecordingFLACEncoderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/RecordingFLACEncoderTests.swift) と [FLACTimelineReaderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACTimelineReaderTests.swift) を参照してください。

Windows の `swift build` は Core、Pipeline、CWindowsSession、CMiniaudio、CWindowsAudio、WindowsSupport、`CONNXRuntime`、MacAmbientJevONNX、PortableRuntime と評価 CLI 3 本を build します。`swift test` は Core、Pipeline、WindowsSupport、ONNX、PortableRuntime の各 test target を filter 指定なしで実行します。WindowsSupport の音声 fixture と ONNX fixture（Silero speech / reference fixture を含む）も各 test target に含まれます。これは [`test-windows.ps1`](../scripts/test-windows.ps1) と [portable CI](../.github/workflows/portable-core.yml) の実行内容です。ONNX Runtime の Windows DLL はテスト実行 bin directory に配置し、Silero model を test 用に取得します。macOS 専用 framework や Mac 用モデルは取得しません。
評価 CLI の参照文・artifact の形式は [testing.md](testing.md) と [linux.md](linux.md) を参照してください。
参照文のファイル指定は相対パスと Windows の絶対パスを扱います。

[portable-core.yml](../.github/workflows/portable-core.yml) は、共通 Core / Pipeline、Windows 音声関連ソースとテスト、ONNX source / tests / fixture、fixture 生成スクリプト、Silero fetch / fixture script の変更を含む main への push とレビュー可能な pull request で、Linux と Windows の build/test を実行します。
Linux は CMiniaudio、Core、Pipeline、`CONNXRuntime`、MacAmbientJevONNX、PortableRuntime と評価 CLI 3 本を build し、Core、Pipeline、ONNX、PortableRuntime の tests を実行します。workflow は ONNX Runtime SDK、Silero model、Qwen3-ASR tokenizer をそれぞれ fetch し、検証した path を `MAC_AMBIENT_JEV_SILERO_MODEL` と `MAC_AMBIENT_JEV_QWEN3_TOKENIZER` として `GITHUB_ENV` に書き込みます。`test_portable_core.py`、ONNX Runtime / Silero / Qwen3-ASR tokenizer fetcher、pinned download helper、Silero reference generator の各 self-test、`check_portable_core.py`、`test_doc_references.py`、`check_doc_references.py` は check step で実行し、`swift build` と `swift test` はそれぞれ別 step で実行します。Linux workflow は `verify_portable.sh` を実行しません。ローカルの [verify_portable.sh](../scripts/verify_portable.sh) は別の実行手順で、ONNX Runtime SDK、Silero model、Qwen3-ASR tokenizer を fetch し、path を環境変数に設定したうえで Silero fetcher、Qwen3-ASR tokenizer fetcher、pinned download helper、Silero reference generator の self-test、portable checker、SwiftPM manifest check、build、test を実行します。
Windows は Core、Pipeline、CWindowsSession、CMiniaudio、CWindowsAudio、WindowsSupport、`CONNXRuntime`、MacAmbientJevONNX、PortableRuntime と評価 CLI 3 本を build し、Core、Pipeline、WindowsSupport、ONNX、PortableRuntime の tests を実行します。Windows CI は [test-windows.ps1](../scripts/test-windows.ps1) が ONNX Runtime SDK、Silero model、Qwen3-ASR tokenizer の fetch、各 check、ONNX Runtime / Silero / Qwen3-ASR tokenizer fetcher、pinned download helper、Silero reference generator の各 self-test、Package の全適用 target の `swift build`、DLL 配置、全適用 test target の `swift test` を行います。
Draft PR では portable と macOS の CI を起動せず、作業中の Linux 検証はローカルにまとめます。
手動実行は Windows のみが既定で、run_linux を有効にすると Linux も実行します。
同じブランチ・PR の古い実行は自動で取り消します。Windows のテストには symlink の作成権限が必要です。
macOS の app bundle と録音・GUI の検証は [ci.yml](../.github/workflows/ci.yml) と Mac で行います。

## 保存先と境界

既定の保存先は SHGetKnownFolderPath で取得する LocalAppData 配下です。
取得に失敗した場合はエラーにし、環境変数や macOS のパスで補いません。
セッションは LocalAppData/mac-ambient-jev/sessions、モデルは同じアプリ root の models、
キャッシュは LocalAppData/Caches/mac-ambient-jev に置きます。
LocalAppData はシステムの既知フォルダーであり、これらは生成される保存先です。

SessionFileAccess は Windows 専用の CWindowsSession を使います。
明示された root を CreateFileW の FILE_FLAG_OPEN_REPARSE_POINT 付きで開き、
子要素は固定した親 handle を基点に NtCreateFile で開きます。
reparse point（symlink、junction を含む）、通常ファイルでない末尾、境界外パスは拒否します。
親が途中で改名されても、検査後に絶対パスから開き直すことはありません。

一時ファイルは同じ親 handle 配下に排他的に作り、FlushFileBuffers 後、
NtSetInformationFile の FileRenameInformation で開いた一時ファイル自身を原子的に公開します。
公開先も固定したディレクトリ handle で指定し、公開後にディレクトリを同期します。
MoveFileExW のパスを再解決する方式は使いません。同期・原子置換をファイルシステムが拒否した場合は
エラーを返し、通常のコピーや未同期の保存へ切り替えません。
ファイルとディレクトリの同期には書き込み権限が必要です。
読み取り・列挙・サイズ取得・ログの durable read はディレクトリの書き込み権限を要求しません。
root の Win32 パスは明示的な長いパス形式で開き、MAX_PATH を超える保存先も同じ境界検査を使います。

イベントログの追記と durable read は LockFileEx で全範囲を排他ロックし、
handle を閉じるまで保持します。復旧の途中で破損した末尾を読むことを防ぎ、
複数 writer が同じイベント番号を発行しません。

セッション名と PCM chunk 名には Windows と POSIX に共通の名前規則を適用します。
詳細は [storage.md](storage.md) を参照してください。

PCM chunk 一覧は大文字に変換した名前でも一意である必要があります。
大小文字を区別しないファイルシステムで同じ音声を二重に数える索引を拒否します。
