# Windows の共通コア

Windows では Swift 6.2 で共通 Core / Pipeline、WindowsSupport、ONNX、PortableRuntime、評価 CLI 3 本と file transcription CLI 1 本、および Core / Pipeline / WindowsSupport / ONNX / PortableRuntime / TranscribeFile の各 test target を build / test できます（[Swift 6.2 release](https://www.swift.org/blog/swift-6.2-released/)）。Linux でも共通 Core / Pipeline、CMiniaudio、ONNX、PortableRuntime、同じ評価 CLI 3 本と file transcription CLI 1 本を build します。共通 Core の [`RecordingFLAC`](../app/MacAmbientJev/Sources/MacAmbientJevCore/RecordingFLAC.swift) と [`FLACTimelineReader`](../app/MacAmbientJev/Sources/MacAmbientJevCore/FLACTimelineReader.swift) は、録音用の正規 `recording.flac`（16 kHz mono 16-bit）の streaming encoder / reader API と CRC / MD5 検証を提供し、Windows でも利用できます。共通の [`MacAmbientJevPipeline`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline) と [`MacAmbientJevPipelineTests`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests) は Windows / Linux の build / test 対象です。WindowsSupport の WAV / FLAC / MP3 / M4A / AAC streaming import と PortableRuntime の ONNX Qwen3-ASR engine / Silero final-transcript VAD segmenter は `MacAmbientJevTranscribeFile` の standalone file processing 経路に接続されています。Windows の録音・live capture、GUI、インストーラー、および Mac app と同じ full-session finalization pipeline は Windows にはありません。Mac の finalization は diarization を含む session pipeline を使います。PortableRuntime の live VAD API はありますが、Windows live capture 経路はありません。macOS の app は Apple Silicon と macOS 15 以降で動作します。

## ONNX Runtime

Windows / Linux の ONNX 実行には Microsoft ONNX Runtime の固定版 1.31.0 を使います（[公式 v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)、[C API](https://onnxruntime.ai/docs/get-started/with-c.html)、[OrtApi](https://onnxruntime.ai/docs/api/c/struct_ort_api.html)）。[`CONNXRuntime`](../app/MacAmbientJev/Sources/CONNXRuntime/module.modulemap) は取得した ONNX Runtime C header を読み込む `systemLibrary` module です。[`MacAmbientJevONNX`](../app/MacAmbientJev/Sources/MacAmbientJevONNX/ONNXSession.swift) はこの C module だけに直接依存し、[`MacAmbientJevONNXTests`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/ONNXSessionTests.swift) は Windows / Linux のみで定義します。macOS は ONNX target を定義せず、ONNX Runtime SDK を取得しません。

公開 API は `ONNXEnvironment(loggingID:)`、`ONNXSession(environment:modelURL:intraOpThreads:cpuMemoryArenaEnabled:)`、`ONNXTensor`、`ONNXTensorElementType`、`ONNXTensorMetadata`、`ONNXValue`、`ONNXRuntimeError` です。すべての引数が必須です。`cpuMemoryArenaEnabled` は session ごとの CPU memory arena を選ぶ必須値で、`true` では EnableCpuMemArena、`false` では DisableCpuMemArena を CreateSession より前に呼びます（[ONNX Runtime 1.31.0 OrtApi](https://onnxruntime.ai/docs/api/c/struct_ort_api.html)）。native 呼び出しの失敗は検査し、日本語の `ONNXRuntimeError` にします。この設定は session の並列度を指定する `intraOpThreads` と、別設定の memory pattern optimization（EnableMemPattern / DisableMemPattern）とは独立です。default 値も process-wide な runtime override もありません。`ONNXSession.inputMetadata()` / `outputMetadata()` は graph の順序で name・element type・shape を返し、動的次元は `-1` です。metadata と実行値で扱う要素型は float32 / int64 に限られ、非 tensor または未対応型は `ONNXRuntimeError` になります。raw `ONNXSession` の呼び出し側が `ONNXEnvironment` を生成・保持して session 間で共有します。ORT environment は process-wide に共有でき、wrapper は global singleton を提供しません。ONNX Qwen3-ASR engine は独自の environment を生成し、3 session に共有します。`ONNXEnvironment` は環境作成前に読み込まれた ONNX Runtime の版が固定 1.31.0 と一致することを確認し、一致しない場合は実際の版を含む日本語エラーを返して環境を作成しません（異なるシステム DLL は使用できません）。`ONNXEnvironment` は OrtEnv を所有して解放します。ORT は OrtEnv を複数 thread から共有できるとしており、wrapper は作成後に変更しないため `@unchecked Sendable` で、固定版は `ONNXEnvironment.runtimeVersion` として公開します。`ONNXSession` は environment を強参照で保持し、自身の native session だけを所有・解放します。モデル URL は明示し、モデルや SDK の path を環境変数・config から読み取る override はありません。`intraOpThreads` は各 session で選ぶ正の Int32 表現可能な Int で、全 session 共通の値ではありません。inter-op thread 数は 1 固定です。`ONNXTensor` は `.float32(shape:values:)` と `.int64(shape:values:)` のみを持ち、値はそれぞれ `[Float]` と `[Int64]` です。shape `[]` は値1個の scalar、0 extent を含む shape は値0個です。負の次元、要素数の不一致、要素数または byte 数の overflow は `ONNXValue` の作成時に検証します。`run(inputs:outputNames:)` は名前付き複数入力を受け取り、指定した順序の出力テンソルを返します（入力は `ONNXValue` へコピーして `runValues` に渡し、出力は `tensor()` でコピーして返す薄い層です）。出力で読み取れる要素型は float32 と int64 だけで、ほかの型は `ONNXRuntimeError` になります。空または NUL を含む入出力名、重複する入力名、空の出力一覧も拒否します。`ONNXValue` は float32 / int64 の ORT 値（OrtValue）を所有する不透明なハンドルで、deinit で解放します。`ONNXValue(environment:tensor:)` が `ONNXTensor` から作る（コピー1回）ほか、`runValues(inputs:outputNames:)` が名前付き `ONNXValue` を受け取って出力を `ONNXValue` で返します。`runValues` は入出力のテンソルデータを Swift 側へコピーしないため、ある step の出力（例: Qwen3-ASR decoder の `present_keys` / `present_values`）を次の step の入力（`past_keys` / `past_values`）へそのまま渡せ、数百 MB の KV cache が Swift 配列を往復しません。`shape` は作成時に取得済みの値を返す安価なアクセサです。`tensor()` は全体を `ONNXTensor` にコピーし、`float32LastRow()` は形状 `[1, S, V]`（`S >= 1`）の float32 テンソルの最終行だけを `[Float]`（長さ `V`）にコピーします（`[1, S, 151936]` の logits 全体をコピーしないため）。`ONNXValue` は float32 と int64 のテンソルだけを表し、出力がほかの型の場合は `runValues` が `ONNXRuntimeError` を返します。`float32LastRow()` は float32 以外または形状が `[1, S, V]`（`S >= 1`）でない値を `ONNXRuntimeError` で拒否します。別の `ONNXEnvironment` で作った値を session に渡すことも拒否します。`ONNXValue` は作成後に変更せず ORT は入力値を読み取るだけなので thread 間で受け渡せますが、1つの値を同時に複数の session run で使いません。入出力名と ORT status のエラーは `run` と同じ `ONNXRuntimeError` です。ファイル URL の native filesystem representation を使い、Windows では native UTF-8 path を UTF-16 に変換して ORT に渡します（`URL.path` は使いません）。CPU provider のみを使い telemetry を無効にし、fallback はありません。ORT status は日本語の処理状況と ORT のメッセージを含む `ONNXRuntimeError` として返します。

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

`MacAmbientJevONNX` の `SileroVAD` は、Silero VAD の単一16 kHz mono frame から speech probability を返す stateful API です。公開 API は `SileroVAD(environment:modelURL:intraOpThreads:)`、`SileroVAD.frameSamples`、`speechProbability(frame:)`、`snapshot()`、`restore(_:)`、`reset()` で、初期化引数はすべて必須です。内部の ONNX session は `cpuMemoryArenaEnabled: true` を明示します。`snapshot()` は recurrent state と context の値を保存し、`restore(_:)` はそれを戻します。数 frame を進めた後に失敗した処理を取り消すために使います。`frameSamples` は512です。モデル URL を明示し、実行時に環境変数から推論モデルを探しません。`MacAmbientJevONNX` は Foundation と `CONNXRuntime` のみに依存し、プロセス共有の `ONNXEnvironment` は呼び出し側が作成・共有します。インスタンスは状態を持ち、Swift concurrency 上は non-sendable であるため、呼び出し側が呼び出しを直列化します。

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

## ファイル文字起こし CLI

`MacAmbientJevTranscribeFile` は Linux / Windows で音声ファイルを VAD 区間ごとに文字起こしし、区間と評価 artifact を出力する計測用 portable CLI です。参照文や評価規則は受け取らず、CER は `MacAmbientJevEvaluateASR` で別途計算します。実行 helper は [`FileTranscriptionPipeline`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/FileTranscriptionPipeline.swift) で、`SileroFinalTranscriptVADSegmenter`、`PipelineCoordinator`、`ASRAudioLoader` を組み合わせます。これは mandatory diarization を含む Mac の full-session `FinalTranscriptPipeline` ではありません。話者分離・speaker-turn による区間分割、話者 tagger、thermal / pacing flag はありません。録音・live capture・GUI と full-session finalization は Windows にはありません。

確定処理の区間規則は [Silero VAD の区間検出](#silero-vad-の区間検出) と同じで、chunk 4,096 sample / 256 ms、開始閾値 0.50・終了閾値 0.35、pre-roll 0.10 秒、最大区間 14.0 秒、無音 0.75 秒、分割探索 2.0 秒、energy frame 0.02 秒、独立区間の最短 0.5 秒です。

```text
MacAmbientJevTranscribeFile <audio-file> --silero-model <path> --asr-model-directory <dir> --asr-model-size <0.6b|1.7b> --threads <n> --output <file.json> --artifact-output <artifact.json>
```

`--help` だけで終了コード 0 になります。音声 path は必須の先頭位置引数で、残りの6 option はすべて一度ずつ必須です。option/value の組は並べ替えできます。

| option | 内容 |
| --- | --- |
| `--silero-model <path>` | Silero VAD ONNX model file |
| `--asr-model-directory <dir>` | 取得済み Qwen3-ASR ONNX model directory |
| `--asr-model-size <0.6b\|1.7b>` | model size |
| `--threads <n>` | 正の Int32 範囲内の値。ASR / VAD の全 ONNX session で intra-op thread 数として使う |
| `--output <file.json>` | 区間別の primary JSON |
| `--artifact-output <artifact.json>` | `MacAmbientJevEvaluateASR` 用の評価 artifact v2 |

認識言語は `ja` 固定で、detected-language field は出力しません。6 個の option に default や環境変数 override はありません。不明、重複、欠落 option、余分な引数、不正値は非 0 で拒否します。入力音声・Silero model・ASR model directory は readable な既存 file / directory、出力先の親 directory は既存 directory でなければなりません。`--output` と `--artifact-output` は既存 path を指定すると、処理開始前に非 0 で拒否されます。入力、primary 出力、artifact 出力は path 標準化と symlink 解決後に互いに異なる必要があります。

音声 import と VAD の前に、CLI は Silero model の pinned SHA-256 を検証し、選択した ASR model manifest が列挙する6ファイルの存在・通常ファイル型・readability・正確な byte 数を確認します。この preflight は VAD 区間が空の場合も実行しますが、ASR model ファイルの SHA-256 は検証しません。preflight は測定時間に含まれません。invalid input / 処理失敗時に出力 JSON は作りません。import した original、processing timeline、event files は一時 scratch directory に書いて処理後に削除し、永続 session は作成しません。各 JSON file は個別に atomic write しますが、2 file の pair は transactional ではありません。

Windows の入力は WindowsSupport の streaming WAV / FLAC / MP3 / M4A / AAC import と canonical 16 kHz mono float timeline conversion を使います。AAC encoder priming は保持されます（[音声 import API](#音声-import-api)）。Linux の CMiniaudio 入力は WAV / FLAC / MP3 のみで、すでに 16 kHz mono が必要です。Linux では sample-rate conversion / channel mixing をせず、未対応形式や条件外の音声を明示エラーにします。Linux で必要なら利用者が ffmpeg で事前に mono PCM16 / 16 kHz WAV に変換します（CLI の fallback ではありません）。

primary JSON の exact top-level keys は `schema_version: 1`、`asr`、`vad`、`segments`、`runtime` です。`asr` / `vad` は各々 `engine`、`model`、`version`、`configuration` の provenance を持ちます。`segments` は `start_ms`、`end_ms`、`text` の配列で、canonical frame の境界を整数 millisecond に ties-to-even で丸めます。`runtime` は `audio_seconds`、`model_load_seconds`、`inference_seconds`、`rtf` です。VAD 区間が空でも成功し、segment は空、評価 artifact の hypothesis も空文字となり、ASR load / inference は行いません。評価 artifact の hypothesis は VAD 区間の認識 text を順に改行文字 `\n` で結合します。これは Mac の `ASRSessionEvaluator` と同じ規則です。artifact の一つの segment は全音声を包む CER 用 envelope であり、primary の区間境界だけが実際の segmentation 時刻です。

`asr.configuration` と artifact の `engine.inference_config` にある `intra_op_threads`、`inter_op_threads`、`cpu_memory_arena` は ASR の3 ONNX session で実際に使う設定（CLI の `--threads` 値、`1`、`false`）を表します。`inference_config` のこれらの値は ASR session のみを指します。Silero session は `--threads` の値を intra-op に使い、CPU memory arena を有効にします。`model_load_seconds` は `PipelineCoordinator` が計測する `ASR.prepare()` のみ、`inference_seconds` は `segmentationSeconds + asrWallSeconds - model_load_seconds` です。後者は lazy VAD model load / inference と event persistence を含み、audio import、モデル identity preflight、ONNX environment の生成、model unload / scratch cleanup、JSON 出力を含みません。`rtf = inference_seconds / audio_seconds` です。負値または非有限の計測値・算出指標はエラーになり、0 へ clamp しません。artifact schema、ONNX の engine / configuration values、runtime の詳細は [Linux 音声評価](linux.md#ファイル文字起こし-cli) に記載しています。

Qwen3-ASR ONNX の品質判定（Linux は CER を実測、Windows は Linux との token parity から導出）は [2026-10-20 の記録](records/qwen3-asr-onnx-cer-2026-10-20.md) にあります。

### Windows release build と実行

Python 3.12 以上、Swift 6.2 と対応する Visual Studio C++ Build Tools / Windows SDK が必要です。Silero model fetch は `python scripts/fetch_silero_vad.py` を使います。ASR model は既存の [Qwen3-ASR ONNX model fetcher](#qwen3-asr-onnx-モデルの取得) で事前取得してください。ONNX Runtime SDK と `onnxruntime.dll` は [ビルドと検証](#ビルドと検証) の既存の取得・DLL 配置手順を使います。以下の path は置換例で、既定値ではありません。`D:\Transcripts` と各 input / model file directory は事前に作成してください。

```powershell
$ErrorActionPreference = 'Stop'
$runtimeRoot = python scripts/fetch_onnxruntime.py
if ($LASTEXITCODE -ne 0) { throw 'ONNX Runtime fetch failed' }
$sileroModelPathLines = @(python scripts/fetch_silero_vad.py)
if ($LASTEXITCODE -ne 0) { throw 'Silero VAD fetch failed' }
if ($sileroModelPathLines.Count -ne 1) { throw 'Silero VAD fetch must return exactly one output line' }
$sileroModel = [string]$sileroModelPathLines[0]
swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevTranscribeFile
if ($LASTEXITCODE -ne 0) { throw 'Release CLI build failed' }
$binDir = (swift build --package-path app/MacAmbientJev -c release --show-bin-path).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve release binary path' }
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'lib/onnxruntime.dll') `
  -Destination (Join-Path $binDir 'onnxruntime.dll') -Force
& (Join-Path $binDir 'MacAmbientJevTranscribeFile.exe') `
  'D:\Audio\interview.m4a' `
  --silero-model $sileroModel `
  --asr-model-directory 'D:\Models\qwen3-asr-onnx\qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd' `
  --asr-model-size 1.7b `
  --threads 2 `
  --output 'D:\Transcripts\interview-segments.json' `
  --artifact-output 'D:\Transcripts\interview-artifact.json'
if ($LASTEXITCODE -ne 0) { throw 'File transcription failed' }
```

### Windows の実モデル CLI integration test

[`test_transcribe_file_cli_model.py`](../tools/linux-audio/tests/test_transcribe_file_cli_model.py) は release CLI と evaluator を build し、長い fixture の primary JSON、評価 artifact、CER を検証します。実行には Python 3.12 と `uv` が必要です。下記は repository root から実行し、先に上記 release build 手順と同じく `onnxruntime.dll` を release binary directory に配置してください。model directory の path は実際の既存 directory に置き換えます。

```powershell
$ErrorActionPreference = 'Stop'
$env:RUN_MODEL_TESTS = '1'
$env:QWEN3_ASR_ONNX_MODEL_DIRECTORY = 'D:\Models\qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4'
$env:QWEN3_ASR_ONNX_MODEL_SIZE = '0.6b'
$sileroModelPathLines = @(python scripts/fetch_silero_vad.py)
if ($LASTEXITCODE -ne 0) { throw 'Silero VAD fetch failed' }
if ($sileroModelPathLines.Count -ne 1) { throw 'Silero VAD fetch must return exactly one output line' }
$env:MAC_AMBIENT_JEV_SILERO_MODEL = [string]$sileroModelPathLines[0]
Push-Location tools/linux-audio
try {
  uv run --python 3.12 --with pytest python -m pytest -q tests/test_transcribe_file_cli_model.py
  if ($LASTEXITCODE -ne 0) { throw 'Model CLI integration test failed' }
} finally {
  Pop-Location
}
```

## 熱状態

Pipeline の [`ThermalMonitoring`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline/ThermalMonitoring.swift) contract は `isCritical`（確定処理の pause / resume 判定）と `liveASRDecision`（live ASR の policy）です。Windows の `WindowsNoThermalMonitoring` は thermal state を読み取らず、`isCritical == false` と `.processNow` を返します。Windows では熱状態を測定・推定せず、nominal state を設定することもありません。Windows では熱状態によるライブ ASR 待機・確定処理一時停止を行いません（[製品ルールの熱状態](decisions.md#熱状態)）。

Mac の [`MacThermalMonitor`](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/MacThermalMonitor.swift) は `ProcessInfo.thermalState` を使う具体実装です。Mac の nonoptional `state` / `pressure` と live/finalization の policy 境界は [architecture.md](architecture.md#portable-core-の境界) を参照してください。Mac app とファイル処理・システム音声・遅延計測 CLI が同じ監視元を使います。

## 音声 import API

`MacAmbientJevWindowsSupport` の `AudioFileTimelineBuilder` は、Core の `AudioImporter` がセッションへ無再圧縮コピーした original を bounded chunk 単位で読み、mono 化・sample-rate conversion 後の 16 kHz mono float32 PCM processing timeline を生成します。`.wav` / `.flac` / `.mp3` は miniaudio 0.11.23、`.m4a` / `.aac` は Windows Media Foundation AAC Source Reader で decode します。miniaudio の参照版は [0.11.23 release](https://github.com/mackron/miniaudio/releases/tag/0.11.23) です。拡張子の大文字・小文字は区別しません。未対応の拡張子、拡張子なし、対応拡張子でも decode できないファイルは、日本語の明示的なエラーで拒否し、別 decoder へ fallback しません。native read / seek error は EOF として扱わず、エラーとして伝播します。

入力は `SessionFileAccess.openHandle` で開いた session-pinned file handle です。miniaudio はこの handle の descriptor を読み、Media Foundation は同じ handle を複製して read-only IStream / byte stream を作り、MFCreateSourceReaderFromByteStream に渡します。Media Foundation が元ファイルの URL / pathname を再度開く経路はありません。詳細は Microsoft の [Source Reader によるメディアデータ処理](https://learn.microsoft.com/en-us/windows/win32/medfound/processing-media-data-with-the-source-reader) と [MFCreateSourceReaderFromByteStream](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-mfcreatesourcereaderfrombytestream) を参照してください。

各 chunk の全 channel を算術平均して mono にし、Core の `CanonicalAudioConverting` API を実装する Windows resampler へ渡します。16 kHz 以外では miniaudio 0.11.23 の公開 `ma_linear_resampler` API と order 8 Butterworth 低域フィルター（linear LPF8）を使います。公開 `ma_linear_resampler_config.lpfNyquistFactor` を `0.95` に設定し、カットオフを `min(sourceRate, 16000) / 2 × 0.95` とします。48 kHz から 16 kHz への downsampling cutoff は 7,600 Hz です。C wrapper は実際の 4 個の biquad section の Q 値（0.50979557910415918、0.60134488693504529、0.89997622313641557、2.5629154477415055）から DC group delay を計算し、最も近い整数の output frame 数へ丸めて返します。Swift 側はその frame 数を先頭出力から補償します。EOS では filter state をゼロ入力で進め、filter tail を音声時間に加えず、`CanonicalAudio.boundary(sourceFrames, sampleRate: sourceRate)` が定める（`round(sourceFrames * 16000 / sourceRate)`）半開区間の frame 数に切り詰めます。source rate は正の整数 UInt32 のみ受け付け、16 kHz は変換なしで通します。

Media Foundation AAC Source Reader は decode した native frames を canonical timeline に含め、AAC encoder priming / padding を除去しません。また、Media Foundation は AAC encoder priming を示す marker を付けません。Apple が encode した M4A は一般に 48 kHz で 2,112 frames（約 44 ms）の priming を含みます。Windows import ではこの priming を保持するため、Mac import より duration が長くなり、信号・イベント時刻も priming 分だけ後ろになります。Windows は累積 source extent を丸めた frame 境界まで出力します。一方、AVAudioConverter は EOS まで drain して正確な変換長の floor または ceil にあたる出力を保持します。同じ decoded source extent を SRC した場合、終端 frame 数は boundary rounding により Apple と Windows で最大 1 frame 異なることがあります。これは AAC priming の保持による差とは別です。sample 値も platform 間で bit-identical ではありません。

`ImportedAudioTimelineWriter` は Core 共通 API で、AppleSupport と WindowsSupport の両 builder が再利用します。mono canonical PCM を 5 秒単位の durable storage chunk と checkpoint に書き込みます。timeline metadata の公開は builder の外側、呼び出し側が行います。この Windows import API は standalone file transcription CLI に使われますが、live capture、UI、full-session processing pipeline へは接続されていません。WASAPI backend は capture path 向けに CMiniaudio にコンパイルされますが、Windows の capture 実装はありません。

### WindowsSupport テスト

`MacAmbientJevWindowsSupportTests` はテスト中に生成する WAV と同梱の FLAC / MP3 / M4A / AAC fixture により、デコード、import copy の保持、timeline frame boundary、再構築時の partition invariant、symlink を含む session 境界、未対応拡張子・破損ファイルに対する日本語エラーを検証します。

RIFF / RIFX WAV では、miniaudio 0.11.23 の `dr_wav` が宣言 data size を clamp する前に、セッションに固定された file handle 上で data chunk の payload 先頭位置 + 宣言 data size をファイルの物理サイズと照合します（[miniaudio 0.11.23 source](https://raw.githubusercontent.com/mackron/miniaudio/0.11.23/miniaudio.h)）。RIFF / RIFX container の宣言 extent はこの判定に使いません。data size が `0xFFFFFFFF` の WAV は物理サイズとの照合対象から除外し、streaming WAV を受け入れます。data payload 全体が物理サイズ内にあれば、後続 LIST chunk の実体が宣言より短い場合、RIFF outer size が物理サイズと 8 bytes 異なる場合、最後の data pad byte が欠けている場合も音声を受け入れます。回帰テストは streaming、短い trailing LIST、8 bytes 大きい outer size の各 WAV で import 成功を確認します。

RF64 WAV / FLAC では、デコード位置が宣言 frame 数に達する前に miniaudio が終端を返した場合、基礎ファイルの位置が物理終端にあるときに限り `AudioImportError.unexpectedEOF` とし、物理終端より前なら `MA_INVALID_DATA` によるデコード失敗とします。発生した read error は decoder の再 read でも保持されます。回帰テストでは、途中の FLAC subframe header の破損を物理 EOF より前のデコード失敗として確認します。CRC だけが壊れた FLAC では decoder が frame を skip して物理 EOF まで進むことがあり、CRC error 全般を個別のデコード失敗として検出するわけではありません。`AudioImportError.unexpectedEOF` の日本語メッセージは `音声ファイルが宣言されたフレーム数より前に終了しました。` です。

FLAC STREAMINFO の総サンプル数が 0 の場合、timeline model が宣言済み長さを必要とするため、デコーダー作成時に `AudioImportError.missingTotalSampleCount` を返します。日本語メッセージは `FLAC の総サンプル数が記録されていません。` です。借用した CRT descriptor を write-only descriptor に置き換えて `MA_IO_ERROR` を誘発するテストでは、native I/O エラーが clean EOF として扱われず、終端エラーとして保持されることも確認します。

fixture は [generate_windows_audio_fixtures.py](../scripts/generate_windows_audio_fixtures.py) が [FFmpeg 8.0](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.0/Changelog) で生成します。resampler の仕様と miniaudio 0.11.23 の出典は [CMiniaudio README](../app/MacAmbientJev/Sources/CMiniaudio/README.md)、[miniaudio 0.11.23 release](https://github.com/mackron/miniaudio/releases/tag/0.11.23)、[0.11.23 changes](https://raw.githubusercontent.com/mackron/miniaudio/0.11.23/CHANGES.md) を参照してください。Media Foundation の byte-stream API は [WinSDK 26100: MFCreateSourceReaderFromByteStream](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-mfcreatesourcereaderfrombytestream) を参照してください。

Resampler の連続 SRC テストは 8 / 16 / 22.05 / 44.1 / 48 / 96 kHz を使い、WAV と SRC の interior sine error を 0.025 未満、whole-buffer と異なる read partition 間の差を 1e-6 未満で検査します。別の regression test は、48 kHz の同振幅 1 kHz / 11 kHz tone を 16 kHz へ downsample し、11 kHz tone の rejection が 30 dB 以上であることを確認します。

FLAC / MP3 fixture は 48 kHz stereo、375 Hz の音声です。M4A / AAC の marker fixture は 48 kHz stereo で、silence、700 Hz から 3,700 Hz への chirp、silence、375 Hz sine の順に信号を配置します。M4A / AAC は Media Foundation の AAC priming を trim せず、marker の onset と canonical timeline 上の位置を確認します。marker は `abs(sample) > 0.05` で検出します。FLAC / MP3 の compressed interior sine error と M4A / AAC の sine error は 0.06 未満です。

FLAC 形式の仕様は [RFC 9639 (December 2024)](https://www.rfc-editor.org/rfc/rfc9639.html) を参照してください。

## Qwen3-ASR の prompt と token decoder

Linux / Windows の ONNX ASR engine は、PortableRuntime の [Qwen3ASR](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Qwen3ASR) ディレクトリにある prompt 生成と token id から text への復元を使います。どちらも ONNX Runtime を呼ばない純粋な Swift で、モデルの入出力は別の層が扱います。

`Qwen3ASRPrompt(audioTokenCount:)` は、encoder の出力 token 数 N（1以上）から decoder に渡す `input_ids`（Int64）を作ります。N が0以下なら `Qwen3ASRError.invalidAudioTokenCount` で失敗します。言語は日本語に固定し、引数にしません。prompt tail は Mac の speech-swift と同じ `language ja`（IDs `[11528, 11937]`）であり、[公式 qwen-asr 実装](https://raw.githubusercontent.com/QwenLM/Qwen3-ASR/main/qwen_asr/inference/qwen3_asr.py) の `_build_text_prompt` は完全な言語名 `language Japanese` を prefill します。

```text
[151644, 8948, 198, 151645, 198, 151644, 872, 198, 151669]
+ [151676] * N
+ [151670, 151645, 198, 151644, 77091, 198, 11528, 11937, 151704]
```

先頭の9個が `<|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>`、末尾が `<|audio_end|><|im_end|>\n<|im_start|>assistant\nlanguage ja<asr_text>` です。decoder graph の `audio_offset` は `Qwen3ASRPrompt.audioOffset`（9、最初の `<|audio_pad|>` の位置）です。

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

成功時の stdout は取得したモデル directory の絶対パス1行だけです。終了コードは成功が `0`、引数・サイズ・保存先の不正が `2`、Python version、取得、integrity、OS の失敗が `1` です。[`test_fetch_qwen3_asr_model.py`](../scripts/test_fetch_qwen3_asr_model.py) はネットワーク上のモデル重みに依存しない offline self-test で、[`verify_portable.sh`](../scripts/verify_portable.sh) と [`test-windows.ps1`](../scripts/test-windows.ps1) から実行されます。両 runner は [`test_generate_qwen3_asr_token_reference.py`](../scripts/test_generate_qwen3_asr_token_reference.py) の依存 package・model weights 不要な Python self-test も実行します。full model weights は自動取得せず、full model inference は既定では実行しません。

### Qwen3-ASR の embedding と greedy 生成

PortableRuntime の純粋 Swift embedding・生成・text helper は、重みなしの unit test が可能で、下記 ONNX Qwen3-ASR engine からも使われます。`Qwen3ASREmbeddingTable(contentsOf:vocabSize:hiddenSize:)` は `embed_tokens.bin` を FP16 little-endian、row-major として読み、語彙数 `151936` と hidden size を呼び出し側が指定します。ファイルサイズが `vocabSize * hiddenSize * 2` と完全一致することと token ID の範囲を検証し、immutable な `Foundation.Data` を `.alwaysMapped` で memory map し、[`row(_ id: Int64) throws -> [Float]`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Qwen3ASR/Qwen3ASREmbeddingTable.swift) で選択した行だけを Float32 に変換します。ファイル全体を Swift 配列へコピーしません（[Foundation 6.2 の Data 読み込み実装](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BReading.swift)）。

`Qwen3ASRDecoderModel` は associated type Cache と `prefill(promptIDs:audioOffset:)` / `step(tokenID:position:cache:)` を定義します。prefill は位置 `0..<S` を使う契約で、最初の step は `S`、以降は1ずつ増加します。不透明な cache は Swift 配列へ変換せず各 step に渡します。汎用の `Qwen3ASRGreedyDecoder(model:)` の `generate(promptIDs:audioOffset:maxNewTokens:noRepeatNgramSize:)` は生成 ID、終了理由 `.stopToken(id)` / `.tokenCap`、`endedAtTokenCap` を返します。全引数を明示し、token cap は正数、no-repeat n-gram は `nil` または `3` のみです。停止 ID `151645` / `151643` は結果に含め、その後の step は行いません。同点では小さい ID を選び、空または NaN を含む logits はエラーです。3-gram 抑制は prompt ではなく生成済み ID だけを対象にし、抑制対象 ID が logits の範囲外なら明確なエラーにして黙って除外しません。

`transcript(generatedIDs:endedAtTokenCap:)` は marker・stop token 除外・trim 規則を適用し、`endedAtTokenCap == true` の場合に限って、有効な不完全 trailing UTF-8 byte を取り除いてから厳密に decode します。それ以外の不正 UTF-8 はエラーです。`endedAtTokenCap == false` の場合と `decode(_:)` は常に厳密です。Mac は切れた byte を U+FFFD に置換しますが、PortableRuntime は cap 到達時に限り不完全末尾を除きます。[embedding tests](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASREmbeddingTableTests.swift) は合成 FP16、[greedy tests](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRGreedyDecoderTests.swift) は scripted logits を使い、モデル重みは不要です。[token decoder tests](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRTokenDecoderTests.swift) も参照してください。

## Qwen3-ASR ONNX engine と実モデル test

### ONNX Qwen3-ASR engine

[`ONNXQwen3ASREngine`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/ONNXQwen3ASREngine.swift) は PortableRuntime の公開 `ASREngine` actor です。公開 initializer は `init(modelDirectory:size:intraOpThreads:)` で、モデル directory、size、各 ONNX session の intra-op thread 数をすべて明示します（default 引数はありません）。公開 `Qwen3ASRModelSize.small` の raw value は `0.6b`、hidden size は1024、`.large` の raw value は `1.7b`、hidden size は2048です。

[`qwen3_asr_models.json`](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/qwen3_asr_models.json) は Swift engine と [`fetch_qwen3_asr_model.py`](../scripts/fetch_qwen3_asr_model.py) が共有する唯一のモデル情報源です。2サイズそれぞれの Hugging Face repository、pinned commit、hidden size、6ファイル名・正確な byte 数・SHA-256 を定義し、各ファイルには `encoder`、`decoder_init`、`decoder_step`、`decoder_weights`、`embed_tokens`、`tokenizer` のいずれかを必須かつ一意な `role` として割り当てます。Swift engine と fetcher は配列順ではなく `role` でファイルを参照します。`role` の欠落、重複、未対応値、必須 role の不在は不正です。同梱 manifest の不正は Swift engine が package 設定の欠陥として `fatalError` にし、fetcher はネットワーク取得前に ValueError で失敗します。fetcher は同じ resource を読んで取得・hash 検証に使います。`prepare()` は外部 model directory と6つすべての通常ファイルについて readable であることと manifest の正確な byte 数を検証しますが、起動時に SHA-256 は計算しません。モデルファイルや directory の不備は `prepare()` が throw します。

`prepare()` は engine 所有の `ONNXEnvironment`、encoder / decoder_init / decoder_step の3 session、memory-mapped embedding table、tokenizer を用意します。環境は3 session で共有され、3 session はそれぞれ `cpuMemoryArenaEnabled: false` を明示します。raw `ONNXSession` を直接使う呼び出し側のように environment を渡す API ではありません。各 graph は session 作成後、次の session を作る前に、入力・出力の数と名前、float32 / int64 型、shape metadata を検証します。静的次元は完全一致し、動的次元は `-1` として扱います。dynamic batch 軸だけは metadata が `-1` または1であることを許容します。実行時の encoder `audio_features` は `[1, N, H]`、`N > 0`、`H` が選択モデルの hidden size（1024 / 2048）と一致することも検証します。

推論ごとの mel 特徴量は encoder へ渡し、`audio_features` は `ONNXValue` のまま `decoder_init` に渡すため Swift 配列への出力コピーはありません。decoder の KV cache (`present_keys` / `present_values`) も ONNX Runtime 所有の `ONNXValue` として次の step の `past_keys` / `past_values` に渡し、Swift 経由で複製しません。logits は最後の sequence row だけを Swift 配列へ読み出します。各 step で置き換えられた cache は不要になり次第解放され、run の `ONNXValue` は各 transcription 内だけで使われます。sessions、embedding、tokenizer は準備後に共有されますが、音声特徴量や cache は run 間で共有されません。

Actor は同時の `prepare()` 呼び出しで1つの準備 task を共有します。準備失敗は `.failed` 状態となり、後の `prepare()` で再試行できます。`unload()` は進行中 load の generation を取り消し、モデル資産を外して load task の終了を待ちます。並行する unload も同じ準備 task の終了を待ち、unload 中に呼んだ `prepare()` は cancellation error になります。

`transcribe(_:)` はまず16 kHz以外の sample rate を拒否し、次に prepared 状態を確認し、その後に最小音声長を判定します。最小長は `ASRAudioInput.minimumDurationSeconds` の0.02秒（16 kHzで320 samples）で、これ未満の入力は推論せず空 text と `detectedLanguage == nil` を返します。認識言語は日本語固定で、戻り値の `detectedLanguage` は常に `nil` です。生成は最大448 token、停止 token ID `151645` / `151643` で終了し、音声が厳密に15秒を超える場合だけ生成済み token に対する3-gram抑制を有効にします。

provenance は `engine = onnxruntime-qwen3-asr`、`model = <repository>@<commit>`、`version = onnxruntime-1.31.0` です。configuration は次の値です。

| key | value |
| --- | --- |
| `language` | `ja` |
| `minimum_input_seconds` | `0.02` |
| `quantization` | `int4` |
| `mel_variant` | `whisper-slaney-128-nfft400-hop160-reflect-global-log10` |
| `max_new_tokens` | `448` |
| `no_repeat_ngram` | `3 when input_seconds > 15; disabled otherwise` |

### 実モデルを使う opt-in test

[`ONNXQwen3ASRModelTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXQwen3ASRModelTests.swift) の実モデル推論は、`RUN_MODEL_TESTS` が文字列としてちょうど `1` の場合だけ有効です。それ以外の値や未設定では無効です。有効時は `QWEN3_ASR_ONNX_MODEL_DIRECTORY` と `QWEN3_ASR_ONNX_MODEL_SIZE` の両方が必須で、前者は絶対 path の既存 readable directory、後者は厳密に `0.6b` または `1.7b` でなければなりません。有効時に設定が欠落・不正なら skip せず test failure になります。[`Qwen3ASRModelTestConfigurationTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Qwen3ASRModelTestConfigurationTests.swift) はこの設定検証を確認します。以下のように各サイズで別々に実行します（release build は `-c release` を追加）。

```bash
export RUN_MODEL_TESTS=1
export QWEN3_ASR_ONNX_MODEL_DIRECTORY="/absolute/path/to/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4"
export QWEN3_ASR_ONNX_MODEL_SIZE=0.6b
swift test --package-path app/MacAmbientJev --filter ONNXQwen3ASRModelTests

export QWEN3_ASR_ONNX_MODEL_DIRECTORY="/absolute/path/to/models/qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd"
export QWEN3_ASR_ONNX_MODEL_SIZE=1.7b
swift test --package-path app/MacAmbientJev --filter ONNXQwen3ASRModelTests
```

```powershell
$env:RUN_MODEL_TESTS = '1'
$env:QWEN3_ASR_ONNX_MODEL_DIRECTORY = 'D:\Models\qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4'
$env:QWEN3_ASR_ONNX_MODEL_SIZE = '0.6b'
swift test --package-path app/MacAmbientJev --filter ONNXQwen3ASRModelTests

$env:QWEN3_ASR_ONNX_MODEL_DIRECTORY = 'D:\Models\qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd'
$env:QWEN3_ASR_ONNX_MODEL_SIZE = '1.7b'
swift test --package-path app/MacAmbientJev --filter ONNXQwen3ASRModelTests
```

Linux Docker では model directory を read-only で mount できます。次の例は小サイズの固定 commit directory を mount し、container 内で ONNX Runtime SDK を取得して test を実行します。大サイズでは model path と size をそれぞれ `qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd` と `1.7b` に置き換えます。

```bash
docker run --rm \
  -v "$PWD:/repo" \
  -v "$PWD/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:ro" \
  -w /repo swift:6.2-noble bash -lc '
    apt-get update -qq &&
    apt-get install -y -qq python3 curl >/dev/null &&
    python3 scripts/fetch_onnxruntime.py &&
    RUN_MODEL_TESTS=1 \
    QWEN3_ASR_ONNX_MODEL_DIRECTORY=/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4 \
    QWEN3_ASR_ONNX_MODEL_SIZE=0.6b \
    swift test --package-path app/MacAmbientJev --filter ONNXQwen3ASRModelTests
  '
```

### 日本語音声 fixture

実モデル test は [`qwen3_asr_voicevox_short.wav`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox_short.wav) と [`qwen3_asr_voicevox_long.wav`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox_long.wav) を使います。両方とも mono PCM16、16 kHz WAV です。参照文は合成時に渡したコーパス文そのもので、短い音声は `general-001`、長い音声は `long-001`、`statistics-001`、`question-001` をこの順に連結しています。

| fixture | 参照文 | 長さ | samples | bytes | SHA-256 |
| --- | --- | ---: | ---: | ---: | --- |
| short | 今日は音声認識の動作を確認します。 | 3.3066875 秒 | 52,907 | 105,858 | `2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9` |
| long | 通信相手を認証したあと、セッション鍵を共有し、その鍵を使って以降の通信内容を暗号化する流れを考えます。今日の講義ではベイズ推定について説明します。この場合、公開鍵はどこで配布されるのでしょうか。 | 18.464 秒 | 295,424 | 590,892 | `d50f7f2a1fe9665279689e53297772aeb52c43d9068c82ab21b21fa62cac78b2` |

音声は VOICEVOX ENGINE の固定 image voicevox/voicevox_engine@sha256:52bfd61345fe6896a3d0014e0efd1931f6d2f91f501f3c27181e7bce05b47d68（CPU linux/arm64）で生成します。engine `/version` は 0.25.2（[0.25.2 release](https://github.com/VOICEVOX/voicevox_engine/releases/tag/0.25.2)、[README](https://raw.githubusercontent.com/VOICEVOX/voicevox_engine/0.25.2/README.md)）、speaker library version は 0.16.0、speaker UUID は `388f246b-8c41-4ac1-8e2d-5d79f3ff56d9`、話者・style は ずんだもん／ノーマル（style ID `3`）です。クレジットは `VOICEVOX:ずんだもん` です。生成器は engine version、speaker/style と `/audio_query` の値を検証し、不一致なら fallback せず失敗します。query は speed 1、pitch 0、intonation 1、volume 1、pre/post phoneme length 0.1、24 kHz、stereo false です。生成された 24 kHz mono PCM16 を整数演算の線形変換で16 kHzへ変換します。出力 frame 数は ceil、端点は clamp、丸めは ties-to-even で、padding はしません。同じ設定で2回生成した WAV は bit-identical です。

[`qwen3_asr_voicevox.LICENSE.txt`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox.LICENSE.txt) はこの2つの音声に適用される利用条件と生成元を記録します。[VOICEVOX 利用規約](https://voicevox.hiroshiba.jp/term/)、[東北ずん子・ずんだもんプロジェクト音源利用規約](https://zunko.jp/con_ongen_kiyaku.html) および [VOICEVOX 音声モデル・音声ライブラリ利用規約](https://raw.githubusercontent.com/VOICEVOX/voicevox_vvm/main/TERMS.txt) に従い、クレジットを表示した商用・非商用利用が認められる音声を、中立的な test fixture として規約上の制限を保って配布しています。この音声はリポジトリの software license や CC0 で再許諾されるものではありません。再配布時は WAV とともにこの注意書きと規約へのリンクを保持し、`VOICEVOX:ずんだもん` のクレジットと適用条件を受領者にも伝えてください。VOICEVOX software、音声 library、model、画像は同梱・再配布しません。

再生成には Python 3.12 以上、`curl`、Docker が必要です。repository root で固定 image を起動し、最大120回・2秒間隔で `/version` の readiness を確認してから [`generate_qwen3_asr_fixtures.py`](../scripts/generate_qwen3_asr_fixtures.py) を実行します。終了時は trap で固定 container 名を削除します。

```bash
set -eu
docker run -d --platform linux/arm64 \
  -p 127.0.0.1:50021:50021 \
  --name qwen3-fixture-voicevox \
  voicevox/voicevox_engine@sha256:52bfd61345fe6896a3d0014e0efd1931f6d2f91f501f3c27181e7bce05b47d68
trap 'docker rm -f qwen3-fixture-voicevox >/dev/null 2>&1 || true' EXIT
ready=0
for attempt in {1..120}; do
  if curl --fail --silent http://127.0.0.1:50021/version >/dev/null; then
    ready=1
    break
  fi
  if [ "$attempt" -lt 120 ]; then sleep 2; fi
done
test "$ready" -eq 1
python3 -B scripts/generate_qwen3_asr_fixtures.py --base-url http://127.0.0.1:50021
```

生成器はコーパス ID の不足・重複、engine / style の不一致、query の値の不一致、入力 WAV の形式・長さを検証してから両方の出力を公開します。生成器の offline self-test は [`test_generate_qwen3_asr_fixtures.py`](../scripts/test_generate_qwen3_asr_fixtures.py) で実行します。

```bash
python3 -B scripts/test_generate_qwen3_asr_fixtures.py
```

### 実モデル test の音声照合

opt-in test は合成時と同一の各参照文に対して short / long を別々に照合し、CER 計算前には空白と句読点だけを除去します。受け入れ上限は short `<= 0.05`、long `<= 0.15` です。両 fixture で非空の日本語 text、`detectedLanguage == nil`、WAV の正確な sample 数、および2回の認識 text の一致も検証します。long は15秒を超えるため、runtime の no-repeat 3-gram 経路を通ります。空入力と319-sample入力についても、空 text と `detectedLanguage == nil` を確認します。first / repeat RTF は `prepare()` 後の `transcribe()` だけを計測して出力し、準備時間を含めませんが、RTF の test threshold はありません。既存の first / repeat baseline measurements は[測定記録](records/qwen3-asr-token-memory-2026-10-20.md)にあります。

### 独立 token reference と完全一致 test

[`generate_qwen3_asr_token_reference.py`](../scripts/generate_qwen3_asr_token_reference.py) は、実モデルの生成 token ID と復元 text の独立した参照 fixture を作ります。同梱の [`qwen3_asr_token_reference.json`](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_token_reference.json) は0.6b model commit `4fc24a1402e74db89c4d2ef256875e71680128c4` と `ja` で生成した固定 parity fixture です。生成器は `--model-size` に `0.6b` または `1.7b`、`--language-tag` に `ja` または `"Japanese"` を受け取ります。prompt は tokenizer の special token を `token_to_id` で引き、`system`、`user`、`assistant`、改行、`language <tag>` を `add_special_tokens=False` で encode して組み立て、tag ごとの literal ID（`ja` は `[11528, 11937]`、`"Japanese"` は `[11528, 10769]`）と照合します。不一致なら推論前に失敗します。`ja` の prompt は製品の `Qwen3ASRPrompt` と一致し、`"Japanese"` では language token だけが変わります。出力 metadata は model の hidden size（0.6b は1024、1.7b は2048）と `reference.language_tag` を記録します。同梱 fixture にはこの2つの field はありません。

生成器の `--model-directory`、`--output` に加えて `--model-size`、`--audio-manifest`、`--language-tag` はすべて必須です。`--audio-manifest` は絶対 JSON path で、root object の key は厳密に `{schema_version, clips}`、`schema_version` は1です。各 `clips` entry の key も厳密に `{id, file, sample_count, sha256}` です。`id` は重複のない空でない文字列、`file` は manifest と同じ directory に置く symlink でない通常 WAV file の basename（traversal 不可）、`sample_count` は正の整数、`sha256` は小文字16進64文字でなければなりません。各 WAV は mono PCM16・16 kHz で、hash と sample count を検証します。

同梱の short / long WAV を再生成入力に使う場合、Docker 外の `/absolute/path/to/short-long-inputs` に2つの WAV をコピーし、次の manifest を manifest.json として置きます。

```json
{
  "schema_version": 1,
  "clips": [
    {
      "id": "short",
      "file": "qwen3_asr_voicevox_short.wav",
      "sample_count": 52907,
      "sha256": "2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9"
    },
    {
      "id": "long",
      "file": "qwen3_asr_voicevox_long.wav",
      "sample_count": 295424,
      "sha256": "d50f7f2a1fe9665279689e53297772aeb52c43d9068c82ab21b21fa62cac78b2"
    }
  ]
}
```

fixture には model の6ファイルそれぞれの実 byte 数と SHA-256、commit、短・長 WAV の SHA-256、Python と全 installed distribution の version、参照実行の設定を記録します。同梱 fixture の reference metadata は `platform=Linux`、`architecture=aarch64`、`intra_op_threads=2`、`inter_op_threads=1` を示します。この platform / architecture は同梱 fixture の参照実行環境を表し、生成器の全出力に共通する値ではありません。各 clip には `prompt_ids`、`audio_token_count`、`no_repeat_ngram_size`、`ended_at_token_cap`、生成 ID と text が含まれます。生成器は Python 3.12、NumPy 2.2.6、Transformers 4.57.1、tokenizers 0.22.2、ONNX Runtime 1.31.0 を要求します。NumPy と Transformers は log-mel golden と同じ版です。必須 package version、選択 model size に対応する model metadata と6ファイルの byte 数・SHA-256、WAV manifest の形式・sample 数・SHA-256 が合わない場合は、推論や出力 JSON の書き込み前に失敗します。

参照の mel は Transformers の公式 Whisper NumPy 経路 `_np_extract_fbank_features`（`feature_size=128`、16 kHz、`n_fft=400`、`hop_length=160`、`dither=0`）を使い、WAV 全体をそのまま渡します。30秒への padding / truncation はしません。ONNX Runtime の encoder / decoder session は CPUExecutionProvider のみ、intra-op 2、inter-op 1、CPU memory arena 有効で動作します。`audio_offset` は常に9です。prompt は選択した language tag に従い、`ja` だけが製品 prompt literal `language ja` と一致します。`"Japanese"` にすると language token だけが変わります（上記 [prompt と token decoder](#qwen3-asr-の-prompt-と-token-decoder)）。FP16 little-endian の embedding row を選択して Float32 に変換し、greedy 同点は最小 token ID を選びます。stop token `151645` / `151643` は生成 ID 配列に含めてその位置で停止し、最大生成数は448です。15秒を超える音声だけ生成済み ID に対する no-repeat 3-gram を使います。text は tokenizers の decode で special token を除いて復元します。

`exactTokenParity` は固定 fixture の各 clip について、`Qwen3ASRPrompt(audioTokenCount:)` と `prompt_ids`、`audio_token_count`、`no_repeat_ngram_size`、`ended_at_token_cap` を照合し、実モデル実行では生成 ID と text も完全一致で検証します。prompt と decoding の診断は区別され、fixture と実行環境それぞれの platform / architecture / intra-op thread 数をログに出力します（Swift parity は intra-op 2 / inter-op 1）。独立した [metadata test](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXQwen3ASRModelTests.swift) は model なしで fixture の prompt と metadata を検証します。parity は固定 fixture と実際に実行した platform に限り、任意の platform への保証でも mel / logits の bit identity でもありません。この固定 fixture で token ID と text の完全一致を確認した platform は Linux aarch64（Swift 6.2.4 release）と Windows ARM64（Swift 6.2.0 debug）です。両者とも ONNX Runtime 1.31.0、intra-op 2 / inter-op 1 での結果であり、任意の platform への保証ではありません（[Linux parity 記録](records/qwen3-asr-token-memory-2026-10-20.md#parity)、[Windows ARM64 記録](records/qwen3-asr-token-memory-2026-10-20.md#windows-arm64-vm2026-10-20)）。

[ONNXQwen3ASRModelTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXQwen3ASRModelTests.swift) の `exactTokenParity` test は `RUN_MODEL_TESTS` が文字列として `1` で、既存の必須 `QWEN3_ASR_ONNX_MODEL_DIRECTORY` / `QWEN3_ASR_ONNX_MODEL_SIZE` 設定が有効な場合に実行します。reference は0.6bだけなので、size が明示的に `1.7b` の場合は skip します。その他の欠落・不正な model 設定は skip や別 model への fallback ではなく test failure です。test は `@testable` の内部 `transcribeWithTokens` 結果から、同じ推論 run の `generatedIDs` と `text` を取得し、生成 ID の配列全体を許容差なしで比較します。この内部結果はその推論 run の比較にのみ使い、後続の推論 run へ保持しません。不一致時は最初の差の0-based index、expected / actual ID と配列長を出力して失敗します。public API の追加や token の永続保存はありません。

Python 3.12 の virtual environment をコンテナ内の `/tmp` に作り、4 package を固定して fixture を再生成します。model directory は例のとおり読み取り専用 mount とし、出力は worktree 内の指定 fixture だけです。仮想環境はコンテナが削除されるまで残ります。

```bash
docker run --rm \
  -v "$PWD:/src" \
  -v "/absolute/path/to/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:ro" \
  -v "/absolute/path/to/short-long-inputs:/inputs:ro" -w /src swift:6.2-noble bash -lc '
    apt-get update -qq &&
    apt-get install -y -qq python3-venv >/dev/null &&
    export TMPDIR=/tmp &&
    TOKEN_TMP="$(mktemp -d "${TMPDIR:?}/qwen3-token.XXXXXX")" &&
    python3 -m venv "${TOKEN_TMP:?}/venv" &&
    "${TOKEN_TMP:?}/venv/bin/python" -m pip install \
      numpy==2.2.6 transformers==4.57.1 tokenizers==0.22.2 onnxruntime==1.31.0 &&
    "${TOKEN_TMP:?}/venv/bin/python" scripts/generate_qwen3_asr_token_reference.py \
      --model-directory /models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4 \
      --model-size 0.6b \
      --audio-manifest /inputs/manifest.json \
      --language-tag ja \
      --output /src/app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_token_reference.json
  '
```

参照元は [Transformers v4.57.1 Whisper feature extractor](https://raw.githubusercontent.com/huggingface/transformers/v4.57.1/src/transformers/models/whisper/feature_extraction_whisper.py)、[ONNX Runtime v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)、[ONNX Runtime Python API](https://onnxruntime.ai/docs/api/python/api_summary.html)、[tokenizers 0.22.2 API](https://huggingface.co/docs/tokenizers/v0.22.2/api/tokenizer) と [release](https://github.com/huggingface/tokenizers/releases/tag/v0.22.2) です。

### 複数回推論の RSS benchmark

[ONNXQwen3ASRModelTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXQwen3ASRModelTests.swift) の `memoryOverManyCalls` test は `QWEN3_ASR_MEMORY_BENCHMARK=1` と `RUN_MODEL_TESTS=1` の両方でのみ有効です。既存の `QWEN3_ASR_ONNX_MODEL_DIRECTORY` と `QWEN3_ASR_ONNX_MODEL_SIZE` も必須で、欠落・不正なら test は失敗します。engine を一度だけ prepare し、長い WAV に対して public `transcribe` を50回実行します。各結果は蓄積せず、text が毎回一定かを検査します。RSS は `after_prepare`、`after_call_1`、`after_call_10`、`after_call_25`、`after_call_50`、`after_unload` で出力します。

Linux は [`/proc/self/status`](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html) の VmRSS kB 値を1024倍して byte 数にします。Windows は current process に対する WinSDK K32GetProcessMemoryInfo の `PROCESS_MEMORY_COUNTERS.WorkingSetSize` を byte 数として読みます（[Microsoft API reference](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo)）。値が欠落・不正、または Windows API 呼び出しに失敗した場合は例外にします。各呼び出しの RTF と50回合計の RTF を表示します。合計時間は prepare と unload を含まず、RTF の test threshold はありません。

製品では Qwen3-ASR の encoder / decoder_init / decoder_step の3 session は `cpuMemoryArenaEnabled: false`、Silero は `true` を固定使用し、runtime selector はありません。Qwen の選択理由は arena disabled で warm RSS が低かった測定結果です（[2026-10-20 JST の記録](records/qwen3-asr-token-memory-2026-10-20.md)）。一般の `ONNXSession` は呼び出し側が必須の bool を指定し、default はありません。

Windows では既存の model directory / size 環境変数を設定した状態で、release 用 ONNX Runtime DLL を配置してから実行します。以下は repository root から実行します。

```powershell
$ErrorActionPreference = 'Stop'
$env:RUN_MODEL_TESTS = '1'
$env:QWEN3_ASR_MEMORY_BENCHMARK = '1'
$runtimeRoot = python scripts/fetch_onnxruntime.py
if ($LASTEXITCODE -ne 0) { throw 'ONNX Runtime fetch failed' }
swift build --package-path app/MacAmbientJev -c release
if ($LASTEXITCODE -ne 0) { throw 'Release build failed' }
$releaseBin = swift build --package-path app/MacAmbientJev -c release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve release binary path' }
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'lib/onnxruntime.dll') `
  -Destination (Join-Path $releaseBin 'onnxruntime.dll') -Force
swift test --package-path app/MacAmbientJev -c release --filter ONNXQwen3ASRModelTests/memoryOverManyCalls
if ($LASTEXITCODE -ne 0) { throw 'RSS benchmark failed' }
```

Linux Docker では model directory を読み取り専用で mount します。`/absolute/path/to/models` は手元で用意した絶対 path の例であり、既定 path ではありません。

```bash
docker run --rm \
  -v "$PWD:/repo" \
  -v "/absolute/path/to/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4:ro" \
  -w /repo swift:6.2-noble bash -lc '
    apt-get update -qq &&
    apt-get install -y -qq python3 curl >/dev/null &&
    python3 scripts/fetch_onnxruntime.py &&
    RUN_MODEL_TESTS=1 \
    QWEN3_ASR_MEMORY_BENCHMARK=1 \
    QWEN3_ASR_ONNX_MODEL_DIRECTORY=/models/qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4 \
    QWEN3_ASR_ONNX_MODEL_SIZE=0.6b \
    swift test --package-path app/MacAmbientJev -c release \
      --filter ONNXQwen3ASRModelTests/memoryOverManyCalls
  '
```

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

各段階の失敗で非 0 終了します。runner は ONNX Runtime SDK / Silero model / Qwen3-ASR tokenizer fetch の stdout を UTF-8 として受け取り、終了コードと単一行出力を確認します。ONNX Runtime root は絶対 path の既存 directory として検証します。Silero path は fetcher が絶対 path と通常 file を検証し、runner は再検証しません。Silero path を test 専用 `MAC_AMBIENT_JEV_SILERO_MODEL` に設定し、ONNX Runtime SDK root の lib/onnxruntime.dll を Swift の実行 bin directory へコピーします。Silero fetcher、Qwen3-ASR tokenizer fetcher、pinned download helper、Silero reference generator、Qwen3-ASR token reference generator の各 self-test も実行します。token reference generator の self-test は依存 package や model weights を必要としません。Qwen3-ASR tokenizer の path は test 専用 `MAC_AMBIENT_JEV_QWEN3_TOKENIZER` に設定します。full model weights は自動取得せず、full model inference は既定では実行しません。手動で同じ build / test を行う場合は、次のように取得し、build 後に Swift の実行 bin directory へ DLL を配置してから `swift test` を実行します。

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
python -B scripts/test_generate_qwen3_asr_token_reference.py
if ($LASTEXITCODE -ne 0) { throw 'Qwen3-ASR token reference generator self-test failed' }
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

Windows の `swift build` は Core、Pipeline、CWindowsSession、CMiniaudio、CWindowsAudio、WindowsSupport、`CONNXRuntime`、MacAmbientJevONNX、PortableRuntime と既存評価 CLI 3 本、file transcription CLI 1 本を build します。`swift test` は Core、Pipeline、WindowsSupport、ONNX、PortableRuntime、TranscribeFile の各 test target を filter 指定なしで実行します。WindowsSupport の音声 fixture と ONNX fixture（Silero speech / reference fixture を含む）も各 test target に含まれます。これは [`test-windows.ps1`](../scripts/test-windows.ps1) と [portable CI](../.github/workflows/portable-core.yml) の実行内容です。ONNX Runtime の Windows DLL はテスト実行 bin directory に配置し、Silero model を test 用に取得します。macOS 専用 framework や Mac 用モデルは取得しません。
評価 CLI の参照文・artifact の形式と file CLI の evaluation artifact / model test は [linux.md](linux.md) を参照してください。
参照文のファイル指定は相対パスと Windows の絶対パスを扱います。

[portable-core.yml](../.github/workflows/portable-core.yml) は、共通 Core / Pipeline、Windows 音声関連ソースとテスト、ONNX source / tests / fixture、file transcription CLI の source / tests、fixture 生成スクリプト、Silero fetch / fixture script の変更を含む main への push とレビュー可能な pull request で、Linux と Windows の build/test を実行します。
Linux は CMiniaudio、Core、Pipeline、`CONNXRuntime`、MacAmbientJevONNX、PortableRuntime と既存評価 CLI 3 本、file transcription CLI 1 本を build し、Core、Pipeline、ONNX、PortableRuntime、TranscribeFile の tests を実行します。workflow は ONNX Runtime SDK、Silero model、Qwen3-ASR tokenizer をそれぞれ fetch し、検証した path を `MAC_AMBIENT_JEV_SILERO_MODEL` と `MAC_AMBIENT_JEV_QWEN3_TOKENIZER` として `GITHUB_ENV` に書き込みます。`test_portable_core.py`、ONNX Runtime / Silero / Qwen3-ASR tokenizer fetcher、pinned download helper、Silero reference generator の各 self-test、`check_portable_core.py`、`test_doc_references.py`、`check_doc_references.py` は check step で実行し、`swift build` と `swift test` はそれぞれ別 step で実行します。Linux workflow は `verify_portable.sh` を実行しません。ローカルの [verify_portable.sh](../scripts/verify_portable.sh) は別の実行手順で、ONNX Runtime SDK、Silero model、Qwen3-ASR tokenizer を fetch し、path を環境変数に設定したうえで Silero fetcher、Qwen3-ASR tokenizer fetcher、pinned download helper、Silero と Qwen3-ASR token reference generator の依存 package・model weights 不要な self-test、portable checker、SwiftPM manifest check、build、test を実行します。full model inference は既定では実行しません。
Windows は Core、Pipeline、CWindowsSession、CMiniaudio、CWindowsAudio、WindowsSupport、`CONNXRuntime`、MacAmbientJevONNX、PortableRuntime と既存評価 CLI 3 本、file transcription CLI 1 本を build し、Core、Pipeline、WindowsSupport、ONNX、PortableRuntime、TranscribeFile の tests を実行します。Windows CI は [test-windows.ps1](../scripts/test-windows.ps1) が ONNX Runtime SDK、Silero model、Qwen3-ASR tokenizer の fetch、各 check、ONNX Runtime / Silero / Qwen3-ASR tokenizer fetcher、pinned download helper、Silero reference generator と Qwen3-ASR token reference generator の各 self-test、Package の全適用 target の `swift build`、DLL 配置、全適用 test target の `swift test` を行います。
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
CWindowsSession が開く handle は継承不可です（CreateFileW に SECURITY_ATTRIBUTES を渡さず、NtCreateFile に OBJ_INHERIT を付けません）。
子プロセスが一時ファイルの handle を持ち続けて公開の改名を妨げることはありません。

Windows で実行するテストは、fixture の書き込みに Foundation の `Data.write(to:options: .atomic)` を使いません。
Swift 6.2 の Foundation は `.atomic` の一時ファイルを継承可能な CRT handle（`_wsopen_s`、FILE_SHARE_DELETE なし）で開き、閉じた直後に MoveFileExW で改名します（[Data+Writing.swift](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift)）。
同じテストプロセスで `Process.run()` が並行すると、CreateProcessW の `bInheritHandles` が TRUE のため子プロセスがその handle を継承し（[Process.swift](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.2-RELEASE/Sources/Foundation/Process.swift)）、改名が ERROR_SHARING_VIOLATION（32）になり、NSCocoaErrorDomain Code=513 で失敗します。
`.atomic` を付けない `Data.write(to:)` は継承不可の CreateFileW handle を使うため、この競合は起きません。

イベントログの追記と durable read は LockFileEx で全範囲を排他ロックし、
handle を閉じるまで保持します。復旧の途中で破損した末尾を読むことを防ぎ、
複数 writer が同じイベント番号を発行しません。

セッション名と PCM chunk 名には Windows と POSIX に共通の名前規則を適用します。
詳細は [storage.md](storage.md) を参照してください。

PCM chunk 一覧は大文字に変換した名前でも一意である必要があります。
大小文字を区別しないファイルシステムで同じ音声を二重に数える索引を拒否します。
