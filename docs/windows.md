# Windows の共通コア

Windows では Swift 6.2 で共通 Core / Pipeline、WindowsSupport、ONNX、評価 CLI 3 本と Core / Pipeline / WindowsSupport / ONNX のテストをビルド・実行できます（[Swift 6.2 release](https://www.swift.org/blog/swift-6.2-released/)）。Linux では共通 Core / Pipeline、CMiniaudio、ONNX、評価 CLI 3 本と Core / Pipeline / ONNX のテストをビルド・実行します。共通 Core の [`RecordingFLAC`](../app/MacAmbientJev/Sources/MacAmbientJevCore/RecordingFLAC.swift) と [`FLACTimelineReader`](../app/MacAmbientJev/Sources/MacAmbientJevCore/FLACTimelineReader.swift) は、録音用の正規 `recording.flac`（16 kHz mono 16-bit）の streaming encoder / reader API と CRC / MD5 検証を提供し、Windows でも利用できます。共通の [`MacAmbientJevPipeline`](../app/MacAmbientJev/Sources/MacAmbientJevPipeline) と [`MacAmbientJevPipelineTests`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests) は Windows / Linux の build / test 対象です。WindowsSupport は WAV / FLAC / MP3 / M4A / AAC の streaming import と canonical timeline 生成 API を提供しますが、これは Windows の録音・capture や GUI・engine を含む完全な import / finalization pipeline が実装済みであることを意味しません。録音・capture、VAD segmentation / live VAD、ASR、話者分離、発話文判定を統合する Windows processing engine、GUI、インストーラーは実行対象に含まれません。ONNX の SileroVAD はフレーム確率を返す library API であり、これらの処理 pipeline には接続されていません。macOS のアプリは Apple Silicon と macOS 15 以降で動作します。

## ONNX Runtime

Windows / Linux の ONNX 実行には Microsoft ONNX Runtime の固定版 1.31.0 を使います（[公式 v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)、[C API](https://onnxruntime.ai/docs/get-started/with-c.html)、[OrtApi](https://onnxruntime.ai/docs/api/c/struct_ort_api.html)）。[`CONNXRuntime`](../app/MacAmbientJev/Sources/CONNXRuntime/module.modulemap) は取得した ONNX Runtime C header を読み込む `systemLibrary` module です。[`MacAmbientJevONNX`](../app/MacAmbientJev/Sources/MacAmbientJevONNX/ONNXSession.swift) はこの C module だけに直接依存し、[`MacAmbientJevONNXTests`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/ONNXSessionTests.swift) は Windows / Linux のみで定義します。macOS は ONNX target を定義せず、ONNX Runtime SDK を取得しません。

公開 API は `ONNXEnvironment(loggingID:)`、`ONNXSession(environment:modelURL:intraOpThreads:)`、`ONNXTensor`、`ONNXRuntimeError` です。すべての引数が必須です。呼び出し側が `ONNXEnvironment` を1つ生成してプロセススコープで保持し、すべての session に共有します。ORT environment はプロセス全体で使うためのもので、wrapper は global singleton を提供しません。`ONNXEnvironment` は環境作成前に読み込まれた ONNX Runtime の版が固定 1.31.0 と一致することを確認し、一致しない場合は実際の版を含む日本語エラーを返して環境を作成しません（異なるシステム DLL は使用できません）。`ONNXEnvironment` は OrtEnv を所有して解放し、`ONNXSession` は environment を強参照で保持し、自身の native session だけを所有・解放します。モデル URL は明示し、モデルや SDK の path を環境変数・config から読み取る override はありません。`intraOpThreads` は各 session で選ぶ正の Int32 表現可能な Int で、全 session 共通の値ではありません。inter-op thread 数は 1 固定です。`ONNXTensor` は `.float32(shape:values:)` と `.int64(shape:values:)` のみを持ち、値はそれぞれ `[Float]` と `[Int64]` です。shape `[]` は値1個の scalar、0 extent を含む shape は値0個です。負の次元、要素数の不一致、要素数または byte 数の overflow は run 境界で検証します。`run(inputs:outputNames:)` は名前付き複数入力を受け取り、指定した順序の出力テンソルを返します。出力で読み取れる要素型は float32 と int64 だけで、ほかの型は `ONNXRuntimeError` になります。空または NUL を含む入出力名、重複する入力名、空の出力一覧も拒否します。ファイル URL の native filesystem representation を使い、Windows では native UTF-8 path を UTF-16 に変換して ORT に渡します（`URL.path` は使いません）。CPU provider のみを使い telemetry を無効にし、fallback はありません。ORT status は日本語の処理状況と ORT のメッセージを含む `ONNXRuntimeError` として返します。

ONNX のテストは [`affine.onnx`](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/affine.onnx) を用いて、名前付き型付きテンソル推論、run 境界での検証、environment / session の寿命とエラー処理、日本語・絵文字を含むパスを確認します（[テスト](../app/MacAmbientJev/Tests/MacAmbientJevONNXTests/ONNXSessionTests.swift)）。

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

`MacAmbientJevONNX` の `SileroVAD` は、Silero VAD の単一16 kHz mono frame から speech probability を返す stateful API です。公開 API は `SileroVAD(environment:modelURL:intraOpThreads:)`、`SileroVAD.frameSamples`、`speechProbability(frame:)`、`reset()` で、初期化引数はすべて必須です。`frameSamples` は512です。モデル URL を明示し、実行時に環境変数から推論モデルを探しません。`MacAmbientJevONNX` は Foundation と `CONNXRuntime` のみに依存し、プロセス共有の `ONNXEnvironment` は呼び出し側が作成・共有します。インスタンスは状態を持ち、Swift concurrency 上は non-sendable であるため、呼び出し側が呼び出しを直列化します。

固定 ONNX model は upstream v6.2.3 release の commit `5cd7945676eb32225748052e2e6a0580e4686a08` にある [src/silero_vad/data/silero_vad_16k_op15.onnx](https://raw.githubusercontent.com/snakers4/silero-vad/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/data/silero_vad_16k_op15.onnx) です。この opset 15 export は v6.2.1 の Silero VAD model weights を使います。取得した実ファイルの SHA-256 は `7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49` です。upstream の [model.py](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/model.py) は opset 15 用にこのファイルを選びます。この API は16 kHz のみを受け取ります。固定 revision の [LICENSE](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/LICENSE) は MIT License、Copyright (c) 2020-present Silero Team です（[v6.2.3 release](https://github.com/snakers4/silero-vad/releases/tag/v6.2.3)）。

ONNX 推論では `input[1, 576]`、`state[2, 1, 128]`、`sr[] = 16000` を渡し、出力 `output[1, 1]` と `stateN[2, 1, 128]` を検証します。1 frame は `SileroVAD.frameSamples` の512 sample（16 kHz で32 ms）です。新しい frame に64 sample context を連結し、初期 context と recurrent state `[2, 1, 128]` はゼロです。推論に成功した場合に限り `stateN` と新しい frame の末尾64 sample を次 frame 用に保持します。`reset()` は session を保持したまま state と context をともにゼロに戻します。state の初期化・reset は固定 revision の上流 [`reset_states` (L103–107)](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/utils_vad.py#L103-L107)、frame 推論は [`__call__` (L109–144)](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/utils_vad.py#L109-L144) の実装を mirror します。単体 API は frame の padding、chunking、sample-rate conversion を行いません。512 sample 以外または有限でない入力は明示的なエラーとなります。確率出力は float32 `[1, 1]`、有限値かつ `[0, 1]` 内であることを検証し、state 出力は float32 `[2, 1, 128]` で有限であることを検証します（state の値域は制約しません）。検証に成功する前に状態を更新しません。

Mac は FluidAudio 0.15.8 の Core ML artifact `silero-vad-unified-256ms-v6.2.1` を使います（[FluidAudio VAD docs](https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.8/Documentation/VAD/GettingStarted.md)、[release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.8)、[artifact metadata](https://huggingface.co/FluidInference/silero-vad-coreml/commit/b419383c55c110e2c9271fa6ee0ea83d03c70d96)、[model README](https://huggingface.co/FluidInference/silero-vad-coreml/raw/main/README.md)）。segmentation layer は16 kHz の連続 recurrent state で連続する512-sample frameを8個処理し、各 frame probability を noisy-OR `1 − Π(1 − p_i)` で集約した256 msごとの確率に threshold 0.50 を適用します。最後の部分 chunk は最後の sample の反復で埋めます。ONNX の `SileroVAD` は同じ v6.2.1 weights を使う opset 15 export から frame probability を返します。ONNX segmentation layer contract も8 frame/noisy-OR/threshold 0.50/部分 chunk の最後の sample 反復で同じ集約を行います。この contract は `SileroVAD` 単体 API の処理ではありません。Windows の segmentation integration は未実装です。

[`fetch_silero_vad.py`](../scripts/fetch_silero_vad.py) は Python 3.12 以上の標準ライブラリのみを使う引数なし fetcher です（[Python 3.12 release](https://docs.python.org/3.12/whatsnew/3.12.html)）。固定 raw GitHub URL だけから取得し、retry や代替 URL は使わず、ダウンロード後と既存ファイルの再利用時に SHA-256 を検証します。不一致は再ダウンロードせずエラーにします。symlink、リポジトリ外 path、通常ファイルでない cache entry を拒否し、一時ファイルを検証してから `os.replace` で公開します。成功時の stdout は検証済み絶対 path 1行のみで、保存先は `.build/silero-vad/5cd7945676eb32225748052e2e6a0580e4686a08/silero_vad_16k_op15.onnx` です。両 fetcher は [`pinned_download.py`](../scripts/pinned_download.py) を共有し、repository directory の検証と hash 検証付き atomic file download を行います。download staging は Python 3.12 の [`tempfile.mkstemp`](https://docs.python.org/3.12/library/tempfile.html#tempfile.mkstemp) を使います。ONNX Runtime の archive extraction は fetcher 固有です。

モデル path の環境変数 `MAC_AMBIENT_JEV_SILERO_MODEL` は ONNX test harness 専用です。未設定・空・欠損の場合は fetch command を示すエラーになり、test は skip しません。`MacAmbientJevONNXTests` は連続無音 frame の確率が0.1未満、有声 RMS 0.01 以上の frame の70%以上で確率が0.5以上となること、reset 後の bitwise 再現性と speech 後に reset した無音の一致、recurrent state / context の frame 間引継ぎを検証します。不正 frame と非有限値は状態を変えません。固定 revision の上流参照確率も許容差 `1e-4` で照合します。Linux で手動設定する場合は repository root で次を実行します。Bash は fetch 結果を先に変数へ代入してから `export` し、失敗 status を保持します（[Bash simple command expansion](https://www.gnu.org/software/bash/manual/html_node/Simple-Command-Expansion.html)）。

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

## ビルドと検証

Linux / Windows では Core のみの作業を含むすべての `swift build` の前に、リポジトリルートで ONNX Runtime fetch が必要です（Linux: `python3 scripts/fetch_onnxruntime.py`、Windows: `python scripts/fetch_onnxruntime.py`）。Python 3.12 以上を使います。Silero model fetch は build には不要で、`swift test` に必要です。テスト前に `fetch_silero_vad.py` の出力を `MAC_AMBIENT_JEV_SILERO_MODEL` に設定します。

Swift 6.2 の Windows toolchain、対応する Visual Studio の C++ Build Tools と Windows SDK、Python 3.12 以上を用意し、リポジトリルートから実行します。全 check、ONNX Runtime SDK 取得、全適用 target の build、DLL 配置、全 test を行うコマンドは次のとおりです。

```powershell
./scripts/test-windows.ps1
```

各段階の失敗で非 0 終了します。runner は ONNX Runtime SDK / Silero model fetch の stdout を UTF-8 として受け取り、終了コードと単一行出力を確認します。ONNX Runtime root は絶対 path の既存 directory として検証します。Silero path は fetcher が絶対 path と通常 file を検証し、runner は再検証しません。Silero path を test 専用 `MAC_AMBIENT_JEV_SILERO_MODEL` に設定し、ONNX Runtime SDK root の lib/onnxruntime.dll を Swift の実行 bin directory へコピーします。Silero fetcher、pinned download helper、reference generator の self-test も実行します。手動で同じ build / test を行う場合は、次のように取得し、build 後に Swift の実行 bin directory へ DLL を配置してから `swift test` を実行します。

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
python -B scripts/test_fetch_silero_vad.py
if ($LASTEXITCODE -ne 0) { throw 'Silero VAD fetcher self-test failed' }
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

Windows の `swift build` は Core、Pipeline、CWindowsSession、CMiniaudio、CWindowsAudio、WindowsSupport、`CONNXRuntime`、MacAmbientJevONNX と評価 CLI 3 本を build します。`swift test` は Core、Pipeline、WindowsSupport、ONNX の各 test target を filter 指定なしで実行します。WindowsSupport の音声 fixture と ONNX fixture（Silero speech / reference fixture を含む）も各 test target に含まれます。これは [`test-windows.ps1`](../scripts/test-windows.ps1) と [portable CI](../.github/workflows/portable-core.yml) の実行内容です。ONNX Runtime の Windows DLL はテスト実行 bin directory に配置し、Silero model を test 用に取得します。macOS 専用 framework や Mac 用モデルは取得しません。
評価 CLI の参照文・artifact の形式は [testing.md](testing.md) と [linux.md](linux.md) を参照してください。
参照文のファイル指定は相対パスと Windows の絶対パスを扱います。

[portable-core.yml](../.github/workflows/portable-core.yml) は、共通 Core / Pipeline、Windows 音声関連ソースとテスト、ONNX source / tests / fixture、fixture 生成スクリプト、Silero fetch / fixture script の変更を含む main への push とレビュー可能な pull request で、Linux と Windows の build/test を実行します。
Linux は CMiniaudio、Core、Pipeline、`CONNXRuntime`、MacAmbientJevONNX と評価 CLI 3 本を build し、Core、Pipeline、ONNX の tests を実行します。workflow は ONNX Runtime SDK と Silero model をそれぞれ fetch し、検証した model path を `MAC_AMBIENT_JEV_SILERO_MODEL` として `GITHUB_ENV` に書き込みます。`test_portable_core.py`、ONNX Runtime / Silero fetcher、pinned download helper、Silero reference generator の各 self-test、`check_portable_core.py`、`test_doc_references.py`、`check_doc_references.py` は check step で実行し、`swift build` と `swift test` はそれぞれ別 step で実行します。Linux workflow は `verify_portable.sh` を実行しません。ローカルの [verify_portable.sh](../scripts/verify_portable.sh) は別の実行手順で、ONNX Runtime SDK と Silero model を fetch し、model path を環境変数に設定したうえで Silero fetcher、pinned download helper、Silero reference generator の self-test、portable checker、SwiftPM manifest check、build、test を実行します。
Windows は Core、Pipeline、CWindowsSession、CMiniaudio、CWindowsAudio、WindowsSupport、`CONNXRuntime`、MacAmbientJevONNX と評価 CLI 3 本を build し、Core、Pipeline、WindowsSupport、ONNX の tests を実行します。Windows CI は [test-windows.ps1](../scripts/test-windows.ps1) が ONNX Runtime SDK と Silero model の fetch、各 check、ONNX Runtime / Silero fetcher、pinned download helper、Silero reference generator の各 self-test、Package の全適用 target の `swift build`、DLL 配置、全適用 test target の `swift test` を行います。
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
