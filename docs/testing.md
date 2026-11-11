# 検証と計測

検証記述は build / test target と実行した test の範囲を示し、製品 process の受入を意味しません。Windows の現行 target、保存規則、対象外機能は [windows.md](windows.md)、capture の境界は [capture.md](capture.md) を参照してください。macOS app bundle の plist 生成を確認する Bash テストは Windows では実行しません。

自動検証、実モデルによるファイル処理、計測結果の意味を分けて扱う。実マイク・システム音声の capture や画面の確認は fake 入力やファイル処理だけでは検証できない。Linux の artifact・corpus・CI 実推論は [linux.md](linux.md)、処理経路は [final.md](final.md)、保存と公開結果は [storage.md](storage.md) を参照する。

以下のコマンドはリポジトリルートから実行する。実データのファイル名、セッション ID、保存先を示す環境変数には、自分の実在するデータを設定する。個人録音は Git に入れず、ローカル録音用の領域に置く。配置の案内は `test-data/recordings/README.md` にある。

## C# portable libraries の検証

[`.NET 10` portable solution](../app/Windows/MacAmbientJev.Portable.slnx) の restore と test はリポジトリルートから実行します。

```bash
dotnet restore app/Windows/MacAmbientJev.Portable.slnx --locked-mode
dotnet test app/Windows/MacAmbientJev.Portable.slnx -c Release --no-restore
```

Protocol は共有102-record corpus の typed decode / reencode と codec / framing validation を検証します。EngineClient は in-memory fake child を使う process-client tests、Presentation は fake engine による store / view-model / paging / guard tests と portable assembly check を行います（詳細は [Windows の C# portable libraries](windows.md#c-portable-libraries)）。Swift、model、音声 hardware は必要ありません。

CI の `dotnet-portable` job は `ubuntu-24.04`、`macos-15`、`windows-2025` matrix で実行し、`dotnet --info` を記録します。CI の test / report command は次のとおりです。

```bash
dotnet test app/Windows/MacAmbientJev.Portable.slnx -c Release --no-restore --minimum-expected-tests 2 --results-directory .build/dotnet-test-results --report-xunit-trx
```

job は TRX を `always()` で upload します。期待最小数は2件であり、0件（または2件未満）の実行は失敗します。これは Microsoft.Testing.Platform の report option で、VSTest の `--logger` は使いません。

## Windows WinUI shell の検証

WinUI shell は Windows 専用の XAML / CLI build target で、portable C# libraries / tests とは別に検証します。Windows PowerShell 5.1（`powershell`）、.NET SDK `10.0.402`、Windows SDK `10.0.26100.0` が必要です（[WinAppSDK 2.5.1 の unpackaged app 要件](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/unpackage-winui-app)）。repository root から次を実行します。`C:\builds` は事前に存在し、各 destination は未作成である必要があります。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-windows-shell.ps1 -Version 0.0.0-dev -Architecture x64 -Destination C:\builds\windows-shell-x64
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-windows-shell.ps1 -Version 0.0.0-dev -Architecture ARM64 -Destination C:\builds\windows-shell-arm64
```

[`build-windows-shell.ps1`](../scripts/build-windows-shell.ps1) は architecture ごとの RID（`win-x64` / `win-arm64`）で locked restore を行い、Release publish 後に出力 `MacAmbientJev.exe` の PE machine が指定 architecture と一致することと、publish output 直下に app の PRI `MacAmbientJev.pri` があることを検証します（csproj が `EnableMsixTooling=true` を設定するため PRI が publish されます）。必須の `-Version` は `^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})(-[0-9A-Za-z][0-9A-Za-z.-]*)?$` で検証し、各 numeric part が65535以下であることを確認してから assembly version の元になる MSBuild **Version** に渡します。git が必要で、`git rev-parse HEAD` の失敗時は停止し、informational version を `<version>+<full commit hash>` に設定します。symbol は publish せず、output に `.pdb` があれば失敗します。起動には対象 architecture に合う .NET Desktop Runtime `10.0.x`（patch `10.0.13` 以降）が必要です。portable C# tests と異なり、これは WinUI shell の build / publish 検証であり、アプリの起動や画面表示を自動検証しません。

portable-core workflow の `windows-shell` job は `windows-2025` x64 host で x64 と ARM64（ARM64 は cross-build）を publish し、`windows-shell-x64` / `windows-shell-arm64` artifact を upload します。この job は WinUI app も Swift engine も起動しません。

手動起動確認は repository 外の対応する published directory から行います（以下は x64 の例です）。5秒以上待って `MacAmbientJev` process の window title を取得した後、起動した process を停止します。

```powershell
Set-Location C:\builds\windows-shell-x64
$process = Start-Process -FilePath .\MacAmbientJev.exe -PassThru
Start-Sleep -Seconds 5
Get-Process -Name MacAmbientJev | Select-Object Id, MainWindowTitle
Stop-Process -Id $process.Id
```

engine を含めた配布構成は [combined app staging](windows.md#winui-shell) で用意します。対話型 desktop では、起動中・最小化中のそれぞれで `MacAmbientJev.exe` をもう一度開き、既存 window が表示され前面に戻ること、shell / engine process とログファイルが増えないこと、main instance のログに `redirected activation: existing window activated` が1件増えることを確認します。初回ログの `version:` は指定 version と `git rev-parse HEAD` の full hash を `+` で結んだ値であること、配布 output / zip に `.pdb` がないことも確認します。

WinUI は VM の SSH session 0 から起動できません。build / PE checks は GUI の動作を証明しません。GUI の起動・表示、file / folder picker、Explorer reveal、DPI は lead が interactive VM console で手動確認する必要があり、これらを確認済みとは主張しません。

device-loss は interactive VM console で次の GUI checklist を手動確認します。GUI は build / portable tests では検証されず、以下の実施を主張するものではありません。

- 実デバイスを切断し、status text「録音デバイスの復帰を待っています」が表示されることを確認する。30秒以内に同じデバイスを戻した場合は同一 session に戻り、`device_lost` toast / dialog が出ないことを確認する。
- 30秒以内に戻さない場合、録音の保存と finalization が進み、engine reason をそのまま含む toast と、engine message および「ここまでの録音は保存されています。」を含む dialog が各1回だけ表示されることを確認する。更新を繰り返しても再表示されないことを確認する。
- 「デバイスを選んで新しく録音」は現在の source の device list を更新して pending 解消後に selector へ focus し、自動で録音を開始しないこと、「閉じる」は dismiss のみであることを確認する。
- Settings を開いたまま device loss を起こし、toast は直ちに表示され、dialog は Settings を閉じた後に1つだけ表示されることを確認する。
- notification registration / show failure を起こし、window 内に WindowFailure が見え、device-loss dialog は表示され、通常の commands が使用できることを確認する。
- dialog 表示中に MainWindow を閉じ、安全に dialog を閉じて通知を unregister することを確認する。fatal capture failure / exit code 7 は通常の failure として扱われ、device-loss dialog にならないことも確認する。

実 microphone、loopback（system audio）、long recordings は fake acceptance の対象外で、手動の real-hardware verification が必要です。

## 現行 EngineProtocol / EngineHost の検証範囲

`MacAmbientJevEngineProtocol` と `MacAmbientJevEngineHost` は portable な library target で、macOS・Linux・Windows の build / test 対象です。[MacAmbientJevEngineProtocolTests](../app/MacAmbientJev/Tests/MacAmbientJevEngineProtocolTests/) は NDJSON v1 の wire corpus の byte 一致 round trip、corpus coverage gate、table 形式の negative decoding（unknown member、missing key、absent / null、wrong type、unknown enum / tag、数値境界、non-canonical ID）、lexical validation、round trip から読めない semantic invariants を検証します。[MacAmbientJevEngineHostTests](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/) は scripted byte source / sink と fake handlers を使い、framing、queue/backpressure、request admission、dispatcher、settings store / lock を検証します。[EngineApplicationFailureDeliveryTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationFailureDeliveryTests.swift) は recovery maintenance の shutdown interruption を `cancelled` / `warning` / `restart`、stage `maintenance` とし、実エラーを `filesystem` / `error` / `inspect_session`、同じく stage `maintenance` とすることを検証します。[EngineApplicationTranscriptTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationTranscriptTests.swift) は重複 identity による `.processingFailure` を同じ未変更状態で一度だけ報告し、別の失敗 row も報告すること、修復・再導入後の再報告、oversized row の複数 identity の失敗と修復、追跡上限（`failureLimit` の16件）を超えた失敗行は前の行の修復後に報告されることを検証します。`mixedProjectionAndEncodingFailuresRetainSkippedMarkers` は projection と encoding の失敗が混在しても source order で追跡し、無関係な行の更新や stage の skip で未検証 marker が消えず、修復・削除後も committed rows / revision が成功 update まで変わらないことを確認します。[EngineTranscriptProjectionTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineTranscriptProjectionTests.swift) は重複 ID の集約と修復後の再投影、および commit 前の dirty row を次の update に保持することを検証します。これらは portable な protocol / host unit tests で、実 engine process を起動しません。

```bash
swift test --package-path app/MacAmbientJev --filter 'MacAmbientJevEngineProtocolTests|MacAmbientJevEngineHostTests'
```

この focused command は macOS での手動確認用です。`EngineTransportPipeTests.swift` は POSIX pipe integration test で `#if !os(Windows)` により Windows では除外されます。Windows で fake source / sink tests が通ることを POSIX pipe integration の実行と取り違えません。

### Blocking I/O と cooperative pool の回帰検証

macOS で cooperative pool の strict 検査を有効にして EngineHost と Pipeline の compaction regression を実行し、[Apple が説明する cooperative executor の forward progress](https://developer.apple.com/videos/play/wwdc2021/10254/) に関わる回帰を確認します。

```bash
LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --package-path app/MacAmbientJev --filter 'MacAmbientJevEngineHostTests|SessionProcessingAudioTests'
```

[`SessionProcessingAudioTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingAudioTests.swift) の `compactRecordingUsesDedicatedBlockingIOExecutor` は、同期 compaction I/O callback 内で UnsafeCurrentTask.unownedTaskExecutor を観測し、`BlockingIOExecutor.shared.asUnownedTaskExecutor()` と一致することを検証します（shared executor は assertion まで生存します）。この決定的な placement assertion は、plain Task.detached が default pool に戻る regression を、無関係な work が wall-clock budget 内に schedule されることを要求せずに検出します。heartbeat、gate、deadline は使いません。親 task の cancellation forwarding は既存の cancellation / boundary cases で別に検証します。

Windows の few-core run では、必須 asset setup を保つため同じ PowerShell process で affinity を設定してから既存 runner を実行します。Windows の process affinity は子 process に継承されます（[Microsoft process affinity inheritance](https://learn.microsoft.com/en-us/windows/win32/procthread/inheritance)）。

```powershell
[Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity = [IntPtr]3
./scripts/test-windows.ps1
```

`swift test --parallel --num-workers 2` だけでは processor affinity は保証されません。

本番 `MacAmbientJevEngine` executable product は Windows 専用です。別の test-only executable product `MacAmbientJevEngineHarness` は macOS・Linux・Windows 向けで、CLI の `--root`、`--fixture`、`--sample-rate`、`--channels`、`--inference`、`--threads` はすべて必須です。`--inference` は `deterministic` または `portable`、`--threads` は `1...min(4, logicalCPUCount)` です。`portable` は Linux / Windows だけで利用でき、PortableRuntime を build しない macOS では明示的なエラーになります。Linux の harness は canonical 16 kHz identity のみを受け付け、SRC はありません。fake capture と推論選択は test-only で、本番 engine に追加の flag や hardware capture 経路はありません。portable-core workflow は Windows を job id `windows` の単一 architecture matrix として定義し、`Windows (${{ matrix.architecture }})` の二つの runtime entry で同じ Windows test runner を実行します。各 entry は package build に加えて本番 `--product MacAmbientJevEngine` も明示して build します。build と portable unit tests だけでは engine process acceptance を確立しません。

| OS / 手順 | 現行 build / test 範囲 |
| --- | --- |
| macOS | `MacAmbientJevEngineProtocol` / `MacAmbientJevEngineHost` の portable tests と deterministic harness acceptance を実行できます。portable inference acceptance はありません。通常の macOS 検証は後述の AGENTS 指定コマンドを変更せず実行します。 |
| Linux | [`verify_portable.sh`](../scripts/verify_portable.sh) の既定実行は fetch / check の後、manifest dump と unfiltered build を実行し、`run_swift_tests.py` で test を実行します。EngineProtocol / EngineHost と PortableRuntime 等を含みますが、`MacAmbientJevWindowsSupport` と本番 `MacAmbientJevEngine` product は Linux target ではありません。Linux CI fast job も fetch/check 後に package build と runner 経由の test を行い、Python process acceptance は実行しません。実モデルを使う `linux-model-e2e` は後述の full-model acceptance 手順です。 |
| Windows x64 / ARM64 | portable-core workflow の job id `windows` が `Windows (${{ matrix.architecture }})` として定義され、matrix entry は `x64` / `windows-2022` と `ARM64` / `windows-11-arm` です。両 runtime entry は同じ [`scripts/test-windows.ps1`](../scripts/test-windows.ps1) を実行します。unfiltered package build で test-only `MacAmbientJevEngineHarness` を含む products を build し、本番 `MacAmbientJevEngine` product も明示 build します。runner は ONNX Runtime DLL と必要な pinned test assets / 環境変数を用意し、native injected C tests の後に、unique event path を渡して `run_swift_tests.py` から unfiltered Swift tests を1回実行します。その後、`MAC_AMBIENT_JEV_NETWORK_TESTS=1` で WinHTTP の network tests（実 Hugging Face からの取得、Range 再開、遅い consumer）だけを単独で実行します。全 test の並列実行中は CPU が足りず CDN が接続を切るためです。続いて engine acceptance driver と FLAC validator の self-tests、deterministic fake-capture engine process acceptance を順に実行し、workflow が `windows-engine-x64` / `windows-engine-arm64` payload artifact を success 時だけ stage / upload します。実モデルの追加 acceptance は `-FullModel` でだけ実行します。`timeout-minutes: 45` は testing と release build / staging / cache / artifact の overhead を含む workflow job 全体に適用されます。 |

portable workflow の draft PR jobs は skip され、macOS CI も draft PR jobs を skip します。portable の `workflow_dispatch` は既定で Windows Swift の x64 / ARM64 2 entries、`dotnet-portable` の3 OS entries、および `windows-shell` job を実行します。`run_linux=true` の場合だけ Linux Swift の `linux` と `linux-model-e2e` の2 jobs も追加します（Mac workflow_dispatch の対象を規定する説明ではありません）。Windows Swift job は Windows PowerShell 5.1（`powershell`）で実行し、`pwsh` は使いません。同じ branch / PR の古い run は既存 concurrency により取り消します。Windows tests には symlink 作成権限が必要で、Developer Mode または適切な privilege を使います。

ARM64 の `windows-11-arm` は VS2026 runner 上で、既定 MSVC 14.51 STL に必要な Clang 20 に対し Swift 6.2 同梱 Clang 19 を使うため、Visual Studio 2022 の MSVC v143 14.44 ARM64 / ARM64EC component <code>Microsoft.VisualStudio.Component.VC.14.44.17.14.ARM64</code> を VS2026 installation に追加し、SHA-pinned `gha-setup-vsdevenv@452f99effa381b81c025ccfbdccaca509bff1b29` が `arch: arm64` / `host_arch: arm64` / `toolset_version: '14.44'` を Swift setup より前に選択します。Swift 6.2 は変更せず、x64 の `windows-2022` は image 既定 toolset を保ちます。Swift setup 後の guard は既存 <code>VCToolsInstallDir</code> が `VC/Tools/MSVC/14.44.*` directory で、<code>VCToolsVersion</code> と一致することを要求し、drift で job を停止します。手順と installer の再起動要求時の扱いは [Windows build and verification](windows.md#ビルドと検証) と [portable-core workflow](../.github/workflows/portable-core.yml) を参照してください。

Windows matrix の x64 / ARM64 runtime entry は同じ wrapper で unfiltered Swift test を実行し、各実行に新しい event path を作ります。

```powershell
$eventPath = Join-Path (Get-Location) ".build/test-events/windows-$([guid]::NewGuid().ToString()).jsonl"
python -B scripts/run_swift_tests.py --package-path app/MacAmbientJev --event-stream-output-path $eventPath
```

各 Windows matrix entry の runner は `swift build --build-tests` の後に `swift test --skip-build` を1回実行し、終了後に event を報告します。runner は test process に対する suite budget timer を持ちません。EngineProtocol / EngineHost / WindowsSupport / PortableRuntime / Core / Pipeline / ONNX 等を含む Windows test set 全体が両 entry で対象です。runner は先に `swift build --show-bin-path` で `$binDir` を解決し、unfiltered package build が生成した `MacAmbientJevEngineHarness.exe` を acceptance driver に渡します。ONNX Runtime DLL の配置後に、staged native engine と Swift deterministic harness を使う C# process-client gate（次節）を実行し、native injected C tests、wrapper 経由の Swift tests を順に実行し、その後 driver と FLAC validator の Python self-tests、deterministic fake-capture process acceptance を実行します。Python acceptance driver は build を行いません。workflow はこれらの test の後に release payload も staging しますが、staging script 自身は engine を起動しません。

### Windows C# process client tests

[`MacAmbientJev.Engine.Tests.csproj`](../app/Windows/tests/MacAmbientJev.Engine.Tests/MacAmbientJev.Engine.Tests.csproj) は [`MacAmbientJev.Portable.slnx`](../app/Windows/MacAmbientJev.Portable.slnx) に含まれません。そのため macOS の portable solution tests は engine 環境変数を必要としません。Windows runner は unfiltered Swift build 済み harness と staged native engine を使い、ONNX Runtime DLL 配置後に project 全体を `--minimum-expected-tests 4` で実行します。x64 / ARM64 の両 matrix entry が対象です。[EngineSmokeTests.cs](../app/Windows/tests/MacAmbientJev.Engine.Tests/EngineSmokeTests.cs) は native engine、[EngineHarnessTests.cs](../app/Windows/tests/MacAmbientJev.Engine.Tests/EngineHarnessTests.cs) は deterministic harness を対象にします。両 path は絶対 path が必須で、unset / relative path は失敗し、skip しません。

```powershell
dotnet restore app/Windows/tests/MacAmbientJev.Engine.Tests/MacAmbientJev.Engine.Tests.csproj --locked-mode
dotnet test app/Windows/tests/MacAmbientJev.Engine.Tests/MacAmbientJev.Engine.Tests.csproj -c Release --no-restore --minimum-expected-tests 4 `
  --environment "MAC_AMBIENT_JEV_TEST_ENGINE_PATH=C:\absolute\path\to\MacAmbientJevEngine.exe" `
  --environment "MAC_AMBIENT_JEV_TEST_HARNESS_PATH=C:\absolute\path\to\MacAmbientJevEngineHarness.exe"
```

EngineHarnessTests.cs は実際の ProcessEngineChild と EngineProcessClient を通し、test-only harness に `--root`、`--fixture`、`--sample-rate 16000`、`--channels 1`、`--inference deterministic`、`--threads 1` の6 CLI arguments を明示して起動します。自身で headerless little-endian Float32 mono の33,000 sample fixture を作り、schema version 1、microphone / default device、ASR small、CPU、threads 1、low heat / decisions / automatic export false、export destination null の10 settings をすべて明示します。主シナリオは hello / setup / prepare / start / watch / stop / final publication を経て `transcript.read` limit 1 の一行の text が「エンジンの受け入れテストです。」であること、2回の export が同じ bytes を出し、`transcript.txt` の1行が `[00:00] エンジンの受け入れテストです。` で、末尾に LF があること、shutdown exit 0 を検証します。EOF 後の durable stop は child exit 0 と client Failed state を確認し、kill 後は non-zero exit と client Failed state を確認して、どちらも test が起動する別 process で recovery します。個々の operation wait は30秒、recovery / publication polling は180秒、poll interval は250msです。production の auto-restart や API 変更を加えるものではありません。

EngineHarnessTests の3 tests は実 process transport と storage を deterministic test harness で検証しますが、WASAPI / audio hardware、実モデルや認識品質は検証しません。出荷 Windows engine の startup は、この gate に含まれる別の production smoke test が検証します。既存 Python acceptance checks は変更せず、Linux CI / `verify_portable.sh` にもこの gate は配線していません。

[`test_engine_acceptance.py`](../scripts/test_engine_acceptance.py) と [`test_engine_acceptance_flac.py`](../scripts/test_engine_acceptance_flac.py) は no-build self-tests です。build 済み test-only harness がある場合、[`engine_acceptance.py`](../scripts/engine_acceptance.py) は subcommand を明示して実行します。Windows runner は `$binDir` から `.exe` の完全 path を渡します。

<pre><code>python -B scripts/engine_acceptance.py deterministic &#45;&#45;executable "C:\absolute\path\to\MacAmbientJevEngineHarness.exe"</code></pre>

macOS / Linux では build 済み harness の path を指定します。self-tests と driver は `python3` で起動します。

```bash
python3 -B scripts/test_engine_acceptance.py
python3 -B scripts/test_engine_acceptance_flac.py
```

<pre><code>python3 -B scripts/engine_acceptance.py deterministic &#45;&#45;executable /absolute/path/to/MacAmbientJevEngineHarness</code></pre>

Linux CI fast job の package command は次のとおりです（先行する fetch / check step の後に実行します）。`swift test` は直接呼ばず、runner に未使用の event output path を渡します。

```bash
swift build --package-path app/MacAmbientJev
python3 -B scripts/run_swift_tests.py \
  --package-path app/MacAmbientJev \
  --event-stream-output-path "$GITHUB_WORKSPACE/.build/test-events/linux.jsonl"
```

Linux fast job は fresh checkout の `.build/test-events/linux.jsonl` を使います。`verify_portable.sh` の各 test invocation は UUID を含む別名を同じ `.build/test-events/` directory に作ります。CI artifact upload は job failure 時も実行されます。

Linux / Windows の PortableRuntime tests が使う pinned asset path は runner が fetch して既存の必須環境変数に設定します。WindowsSupport の fake capture tests と native injected C tests は実 audio hardware を使わず、実機 WASAPI の動作を保証しません。通常の deterministic fake-capture acceptance は test-only の pipe I/O 実装と deterministic inference を使います。`-FullModel` は実モデルを使った host acceptance を含みますが、WASAPI / audio hardware は使いません。full-model mode の詳細と transport の適用範囲は [偽キャプチャ engine テストハーネス](windows.md#偽キャプチャ-engine-テストハーネス) を参照してください。

fake-capture process acceptance は stdin / stdout に test-only の [`HarnessPipeIO.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineHarness/HarnessPipeIO.swift) を使い、実 `EngineTransport` / `EngineController` / `EngineApplication` を実行しますが、出荷する [`WindowsPipeIO.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngine/WindowsPipeIO.swift) と [`EngineProcess.swift`](../app/MacAmbientJev/Sources/MacAmbientJevEngine/EngineProcess.swift) の `EngineProcess.run()` 起動 wiring（標準ハンドルの設定・redirect、本番起動時の組み立て）は、full-model を含めどの OS で acceptance を実行しても対象外です。Windows VM でこの harness acceptance を実行しても範囲は変わらず、本番 executable を別途 build するだけでも補われません。fixture signal の検証条件は [偽キャプチャ engine テストハーネス](windows.md#偽キャプチャ-engine-テストハーネス) を参照してください。

本番 `EngineProcess` 起動経路は Windows の [`EngineProcessTests.swift`](../app/MacAmbientJev/Tests/MacAmbientJevEngineTests/EngineProcessTests.swift) が別途検証します。lock conflict と unknown argument の process tests は非 0 exit、空 stdout、必須 stderr diagnostic を確認し、failure message に raw DWORD hex exit code と stdout / stderr の両方を含めます。deterministic exit tests は unknown argument と locked-root operation error の前に best-effort `EngineLog` queue を閉じても必要な stderr diagnostic が出ることを確認し、locked-root case では報告後に root lock を再取得できることも検証します。release executable の relocation / startup smoke はこれらの process tests や harness acceptance とは別で、詳細は [Windows release engine staging と起動確認](windows.md#windows-release-engine-の-staging-と起動確認) に従います。

### Windows native capture-safety injected C test

Windows matrix の両 runtime entry はすべての実行で（`-FullModel` を含む）native C test を Swift tests と別に compile / run します。compiler は解決した `swift.exe` と同じ toolchain directory の `clang.exe`、出力先は `swift build --show-bin-path` で解決した debug `binDir` です。実際の compile command は次の形です。

```text
<clang.exe> app/MacAmbientJev/Tests/CMiniaudioInjected/WindowsCaptureSafetyInjectedTests.c -o <binDir>/WindowsCaptureSafetyInjectedTests.exe -lole32
```

runner は生成 exe の存在を検証してから起動し、compile / run の非 0 exit code は失敗です。test source は production [C implementation](../app/MacAmbientJev/Sources/CMiniaudio/WindowsCaptureSafety.c) を include し、Win32 / COM 呼び出しを local substitutions で差し替えます。SetEvent 解放失敗時に join しないこと、成功時の power cleanup、active probe の再利用と invalidation、GetState failure による invalidation、session-enumerator error の伝播を検証します。音声 hardware は使いません。

### macOS から Windows VM で検証

通常負荷の Windows 11 ARM64 VM test は、リポジトリルートから共有 lock を使う subshell 内で実行します。`winvm test .` が作業ツリーを同期して Windows test runner [`scripts/test-windows.ps1`](../scripts/test-windows.ps1) を実行します。VM は 6.8 GB のため、test run は同時に1つだけにします。Bash の exit trap は runner の終了 code を保ったまま共有 lock を解放します。この test-only harness の acceptance は release payload の起動確認ではなく、別の relocation smoke は [Windows release engine staging と起動確認](windows.md#windows-release-engine-の-staging-と起動確認) に記載します。

```bash
( lock=/private/tmp/winvm-p4.lock; until mkdir "$lock" 2>/dev/null; do sleep 30; done; trap 'rmdir "$lock"' EXIT; winvm test .; rc=$?; exit "$rc" )
```

CPU 負荷を加えた few-core run は、同じ共有 lock subshell で次の inline command を実行します。`winvm run` が作業ツリーを同期して Windows test runner を実行し、PowerShell 5.1 の [`Start-Process`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process?view=powershell-5.1) で論理 processor 数分の CPU 負荷 process を起動します。runner 終了後、この invocation が作成した process object だけを [`Stop-Process`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/stop-process?view=powershell-5.1) で停止します。process 作成が途中で失敗しても、`finally` が既に作成した分を停止し、他の process は対象にしません。native busy process の cleanup failure は抑制せず、非 0 で表面化します。Bash の exit trap は runner の終了 code を保ったまま共有 lock を解放します。

```bash
( lock=/private/tmp/winvm-p4.lock; until mkdir "$lock" 2>/dev/null; do sleep 30; done; trap 'rmdir "$lock"' EXIT; winvm run . -- '$busy=@();try{for($i=0;$i -lt [Environment]::ProcessorCount;$i++){ $process=Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -Command `"while (1) { }`"" -PassThru -ErrorAction Stop; if($null -eq $process){throw "Could not start CPU saturation process"}; $busy += $process }; & .\scripts\test-windows.ps1; if($LASTEXITCODE -ne 0){throw "Windows test runner failed with exit code $LASTEXITCODE"}}finally{foreach($p in $busy){ if(-not $p.HasExited){ Stop-Process -InputObject $p -Force -ErrorAction Stop; $p.WaitForExit() } }}'; rc=$?; exit "$rc" )
```

### Linux Docker で portable 検証

Linux で portable 検証をローカル実行する場合は、次のコマンドを使います。bind mount 上で SwiftPM が macOS `Package.resolved` を削除・変更する場合があるため、使い捨て checkout / worktree で実行します。

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2-noble bash -lc 'apt-get update && apt-get install -y python3 flac && bash scripts/verify_portable.sh'
```

[`verify_portable.sh`](../scripts/verify_portable.sh) は pinned assets を fetch し、portable checker の self-test と import check を行い、SwiftPM manifest を dump してから unfiltered `swift build` と `run_swift_tests.py` を実行します。test は Core / Pipeline / EngineProtocol / EngineHost / PortableRuntime / ONNX 等を含みますが、Linux には WindowsSupport と `MacAmbientJevEngine` product はありません。Linux CI fast job は同じ検証内容の一部を fetch/check step 後に直接 package build と wrapper 経由の test で実行し、この shell script 自体は呼びません。`linux-model-e2e` は既存の separate job です。

[`check_portable_core.py`](../scripts/check_portable_core.py) の default roots には Core / Pipeline に加えて EngineProtocol / EngineHost、ONNX、PortableRuntime が含まれます。portable root から Windows-only `MacAmbientJevEngine` の import を拒否し、WindowsSupport 自体は portable scan roots に含めず、`MacAmbientJevWindowsSupport` import には `#if os(Windows)` を要求します。portable-core workflow の path filter は engine source / test / executable target、native injected test、runner、[`stage-windows-engine.ps1`](../scripts/stage-windows-engine.ps1) と docs の変更を対象にし、Windows matrix job を起動します。macOS CI には path filter がありません。

## 共通 Core / Pipeline テストの現状

[MacAmbientJevPipelineTests](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/) は Windows・Linux で実行する portable な状態・調整ロジックのテストです。[RecordingLifecycleTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingLifecycleTests.swift) は録音・import の lifecycle、[SessionProcessingQueueTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingQueueTests.swift) は FIFO・重複再処理の抑止・thermal hold/resume を検証します。queue の保存整理 state と app 上の完了・失敗表示および整理中の export 制御は、macOS 専用の [LaunchMaintenanceStatusTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LaunchMaintenanceStatusTests.swift) と [ExportDuringMaintenanceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/ExportDuringMaintenanceTests.swift) が検証します。LaunchMaintenanceStatusTests は整理完了時に整理中表示だけを解除して並行更新を保つこと、実エラーの partial failure、shutdown interruption だけなら processing state を partial failure にせず次回起動での再実行を示す処理状態と復元された文字起こしヘッダー、実エラーと interruption の混在時に実エラーを維持することも確認します。[SavedSessionOperationsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SavedSessionOperationsTests.swift) は保存済みセッションの選択と export 状態、[LiveTranscriptionStateTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveTranscriptionStateTests.swift) は FIFO batch・最新 checkpoint・failure・cleanup、[ThermalMonitoringTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/ThermalMonitoringTests.swift) は Windows の `WindowsNoThermalMonitoring` が熱状態を読み取らず、`isCritical == false` と `liveASRDecision == .processNow` を返すことを確認します。[ASRTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ASRTests.swift) は `ASRRunCancellation` の LocalizedError message が Error 型消去後にも `localizedDescription` に届き、cancellation metrics が保持されることを検証します。

[SessionProcessingCoordinatorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingCoordinatorTests.swift) は critical 時の hold / resume と FIFO、pause 時の claim 維持と completion 後の release、recovery filtering を検証します。[LiveTranscriptionCoordinatorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveTranscriptionCoordinatorTests.swift) は fake engines と注入 sleep を使い、thermal wait 中の FIFO、registration await failure と failure / cleanup 後の idle・backlog 状態、cleanup 時に進行中 batch を cancel せず完了させること、遅れて返る failure を公開しないこと、古い drain が置換後の同一 session state を上書きしないこと、VAD progress が ASR 区間登録より先に通知される順序を検証します。[ThermalLineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ThermalLineTests.swift) は Foundation の 4 state（`nominal`、`fair`、`serious`、`critical`）で完全な JSONL 行を直列化することを確認します。ここで挙げた Core / Pipeline tests は portable で、ThermalLineTests は Mac 専用 CLI test です。

```bash
swift test --package-path app/MacAmbientJev --filter MacAmbientJevPipelineTests
```

Swift Testing の `timeLimit` は、指定された個々のテストの hang / cancellation guard です。全テストに `timeLimit` があるわけではありません。許可値は [`check_test_time_limits.py`](../scripts/check_test_time_limits.py) の `HANG_GUARD_MINUTES` が管理します。checker は `app/MacAmbientJev/Tests` 以下の Swift ファイルを再帰的に走査し、`#if` の分岐に関係なく呼び出しを検査して、違反を `path:line` で報告します。self-test は走査規則と `path:line` diagnostics を検証します。検査は Mac の `verify_v1_tests.sh`（およびそれを呼ぶ `verify_v1.sh`）、Windows runner、portable 検証 script と Linux / Windows CI で実行します。Swift Testing の test 経過時間は cooperative scheduling の待ち時間を含む wall clock で、CPU time ではありません。hang guard は性能予算ではなく、引き上げても性能は改善しません。Swift test process は runner 内で独自の時間制限なしに終了を待ちます。CI の job timeout は別の外側の制限であり、[`ci.yml`](../.github/workflows/ci.yml) の両 Mac job は `timeout-minutes: 40` です。

### Swift テストの時間予算とイベント報告

[`run_swift_tests.py`](../scripts/run_swift_tests.py) は `--package-path` と `--event-stream-output-path` を必須とし、`--skip-build` と `--filter` を任意で受け取ります。

通常は `swift build --build-tests` を実行し、成功後に `swift test --skip-build` と event stream 出力を実行します。`--skip-build` を指定した runner invocation では build を省略します。build が失敗した場合は test を起動しません。

```text
swift test --package-path ABS --skip-build --event-stream-output-path ABS --event-stream-version 0
```

runner は Swift test process の終了を待ち、suite budget を理由に process を終了しません。有効な event stream であれば、test 完了後に event reporter が invocation envelope と function test の上位20件を出力し、unfiltered run の envelope が budget を超えた場合は非 0 で終了します。event stream の検証失敗も非 0 です。元の test process が正の非 0 exit code を返した場合は、reporter が失敗してもその test exit code が優先されます。KeyboardInterrupt と `SIGTERM` は test process tree の cleanup / reap を行い、event stream の報告も試みます。

`--filter` を明示した invocation は subset run として扱われ、suite budget は適用しません。event timings の出力と event stream の検証は続き、欠落・malformed・incomplete な stream や未完了の test event は失敗です。

[`verify_portable.sh`](../scripts/verify_portable.sh) の `run_model_suite` と [`test-windows.ps1`](../scripts/test-windows.ps1) の `Invoke-ModelSuite` は、名前を指定した model suite を filtered invocation として実行します。
それぞれ runner に `--filter` を渡します。

[`report_test_events.py`](../scripts/report_test_events.py) は Swift Testing event stream ABI version 0 の `instant.absolute` を使います。invocation envelope は有効な逐次 SwiftPM product run segment の最初の `runStarted` から最後の `runEnded` までで、product 間の gap も含みます。完了した function test の上位20件を、開始・終了 offset と elapsed time で示します。これらの時間も scheduling wait を含む wall clock で、CPU time ではありません。ABI v0 には使える parameterized case identity がないため、parameterized function は case ごとでなく aggregate envelope として報告します。event stream の欠落・malformed・incomplete、または未完了の test event は非 0 の結果です。不完全な stream では観測済み lower bound を示し、観測できない時間は補いません。

全 suite の完了 envelope に対する回帰検出は hang protection と別の判定です。予算値は reporter の [`SUITE_BUDGET_SECONDS`](../scripts/report_test_events.py) が管理します。headroom の評価には hosted CI での測定が必要です。関連する観測結果は [CI test-time measurement record](records/2026-10-25-ci-test-time.md) と [Windows tagger load measurement record](records/2026-10-25-windows-tagger-load.md) を参照してください。

現在の blocking-I/O 回帰検証では、[RecordingAudioCompactorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingAudioCompactorTests.swift) の `fullFLACValidationStopsAtTheStoredEnd` と `aRecordingRoundTripsExactlyCommittedFrames` が既存の test cases と assertions を保ち、録音後の同期 FLAC 処理を bounded `withTaskExecutorPreference` scope で実行します。決定的 executor-identity assertion は処理の配置を検証します。これらの placement checks は全 storage I/O が cooperative pool から除かれたことを主張しません。

ローカルでは invocation ごとに新しい event filename を使い、repository root の `.build/test-events/` に出力します。runner は終了後に reporter を実行します。standalone reporter は通常 run では `EVENT_PATH`、subset stream では `EVENT_PATH --filtered` を指定します。reporter は stream から filtering を推測しません。

```bash
EVENT_PATH="$PWD/.build/test-events/local-$(python3 -c 'import uuid; print(uuid.uuid4())').jsonl"
python3 -B scripts/run_swift_tests.py \
  --package-path app/MacAmbientJev \
  --event-stream-output-path "$EVENT_PATH"
python3 -B scripts/report_test_events.py "$EVENT_PATH"

FILTERED_EVENT_PATH="$PWD/.build/test-events/filtered-$(python3 -c 'import uuid; print(uuid.uuid4())').jsonl"
python3 -B scripts/run_swift_tests.py \
  --package-path app/MacAmbientJev \
  --event-stream-output-path "$FILTERED_EVENT_PATH" \
  --filter 'MacAmbientJevPipelineTests'
python3 -B scripts/report_test_events.py "$FILTERED_EVENT_PATH" --filtered
```

CI の Mac・Linux・Windows test runs は `.build/test-events/` の JSONL artifacts を `always()` upload step で、test failure 時も含めて保存します。Windows の x64 / ARM64 matrix entry は `test-events-windows-x64` / `test-events-windows-arm64` の別 artifact 名を使います。runner は出力先が既に存在すると失敗するため、同じ path を stale event stream に再利用しません。

EngineHost / Engine では、同期に使う仕組みを該当 helper ごとに分けています。FakeEngineHandlers は handler call・held call・hello completion の lifecycle 通知に [ChangeSignal.swift](../app/MacAmbientJev/Tests/MacAmbientJevTestSupport/ChangeSignal.swift) を使い、scripted sink と pipe reader の各 chunk も状態変更を signal します。Windows native stdout capture の [WindowsDiagnosticCaptureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevEngineTests/WindowsDiagnosticCaptureTests.swift) は、native stdout producer-completion latch、capture-close / writer-close latch、egress reader completion、および captured-chunk signals を使います。これらの latch / signal wait は ChangeSignal.wait を通じて test cancellation-aware で、条件を再確認してから復帰します。[EngineApplicationTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationTests.swift) の OfflineFinalizationGate.waitUntilEntered も cancellation-aware gate です。[EngineApplicationFailureDeliveryTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevEngineHostTests/EngineApplicationFailureDeliveryTests.swift) は onBackgroundEventStateChange lifecycle notification callback と ChangeSignal で状態遷移を待ち、MainActor の Task.yield polling を使いません。これらの wait では suite `timeLimit` が hang guard です。この記述は全 EngineHost / Engine tests が event-driven であるという意味ではありません。EngineTransportOutputTests は reliable sender が queue 満杯で suspend したことを明示的な signal で待ち、注入した logical clock で deadline を検証します。progress のケースでは clock を100msずつ進めて deadline の再設定を確認し、no-progress のケースは400ms で期限切れにします。coalescing / backpressure cases は writer 開始前に queue を埋め、テストの進み具合を write deadline に混ぜません。WindowsPipeByteSinkTests は成功・失敗・test cancellation の各経路で sink を close し、writer と reader を join します。pipe reader 自身が read handle を所有し、終了時に閉じます。

Windows job の x64 / ARM64 matrix runtime entry は同じ [`scripts/test-windows.ps1`](../scripts/test-windows.ps1) を実行します。`run_swift_tests.py` が unfiltered Swift test を1回実行し、Windows で適用される Pipeline を含む全 test target を各 entry で一度ずつ検証します。これらは portable な調整・状態ロジックの検証です。WindowsSupport の capture unit tests と native injected C test は別に実行しますが、実 audio hardware を使う検証ではありません。

[CaptureSafetyTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/CaptureSafetyTests.swift) は startup/stall/silence、disk threshold と error rules、oversized mono buffer を検証します。[TimestampedMonoSinkTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/TimestampedMonoSinkTests.swift) は raw-meter の 100ms windows、channels 間の clipping、gaps/reset、metering 前後で audio が変わらないことを検証します。AudioCaptureEngine/CoreMedia/IOKit との実 integration は macOS 専用 AppTests（[AudioCaptureEngineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/AudioCaptureEngineTests.swift)、[CaptureSafetyTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/CaptureSafetyTests.swift)）で扱います。

## macOS の基本検証

```bash
python3 -B scripts/check_portable_core.py
python3 scripts/check_doc_references.py
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev
bash scripts/verify_v1.sh
```

`verify_v1.sh` は `RUN_MODEL_TESTS` と `ASR_SMOKE_AUDIO` を引き継ぎ、`scripts/verify_v1_tests.sh`、続けて `scripts/verify_v1_app.sh` の順に実行する。`RUN_MODEL_TESTS=1` の場合は、Swift コマンドを始める前に `ASR_SMOKE_AUDIO` が読み取り可能な絶対パスであることを検査する。`scripts/verify_v1_tests.sh` は次の1〜6を行い、`scripts/verify_v1_app.sh` は7を行う。

1. `scripts/check_doc_references.py` で参照検査を実行する。`scripts/test_japanese_numeral_exclusions.py` で漢数字表示の除外句一覧の生成規則と、コミット済みの生成物が `labels.tsv` と一致することを検査する。イベント・処理 metadata の schema version 3 と、未対応・欠損・型不正の version の拒否も検証する。Python の `regex` package が必要。
2. SwiftPM の依存を解決し、`swift build --build-tests` で package とテストをまとめて build する。
3. `scripts/fetch_mac_vad_model.py` が [mac_models.json](../app/MacAmbientJev/Sources/MacAmbientJevRuntime/Resources/mac_models.json) に固定した VAD のファイルを取得し（SHA-256 と byte 数を照合し、取得済みなら再取得しない）、`.build/mac-test-models/<commit>` を表示する。その後、事前に build したテストを再利用し、UUID の event path を `.build/test-events/` に作ってから `env -u RUN_MODEL_TESTS MAC_AMBIENT_JEV_TEST_APP_SUPPORT=<表示された directory> python3 -B scripts/run_swift_tests.py --package-path "$PACKAGE" --skip-build --event-stream-output-path "$EVENT_PATH"` を実行する。runner は test process の完了後に event を報告します。この実行では [VADParityFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/VADParityFixtureTests.swift) の FluidAudio 一致検査（`committedFixtureMatchesFluidAudio`）が、固定した VAD の FluidAudio 出力とコミット済み fixture の一致（確率差 0.05 以下、区間は完全一致）を検査する。`MAC_AMBIENT_JEV_TEST_APP_SUPPORT` を渡した実行ではこの検査はモデルがなければ失敗する（skip しない）。ASR model は渡さないため、通常の検証では実 ASR 推論の test は動かない。
4. `MacAmbientJevProcessRecording` を build し、`scripts/verify_cli_inputs.py` で不正入力、ローカル2段階（segmentation / asr）の成功0件を公開した named folder の inspect、イベント・処理 metadata の未対応・欠損・型不正 version の拒否、resume 出力先の containment と保存ファイルの不変性を確認する。
5. `MacAmbientJevEvaluateSession` を build する。
6. モデル検証を指定した場合は Swift test 一覧に ASRIntegrationTests があることと Runtime test bundle の存在を確認し、その bundle を `xcrun xctest` で実行する。実モデルを使うテストは、アプリのモデル directory にピン留めしたASR・VADの2モデルが取得済みで検証に通ることが前提で、ダウンロードはしない（取得して読み込むまでの確認は後述の RealModelFetchIntegrationTests）。
7. `scripts/build_app.sh` は `python3 -B scripts/fetch_clause_tagger.py --format coreml` で固定された Hugging Face の公開 repository から Core ML model files を取得し、manifest が指定する各ファイルの byte 数と SHA-256 を検証して app bundle に同梱する。同梱物は ClauseTagger.mlpackage、tokenizer.json、LICENSE.md です。MLX の Metal shader library は Swift Build backend で生成するため、その backend で build し、Apple Silicon 専用の arm64 のみを対象にする。続けてアプリアイコンの CFBundleIconFile 指定と `.icns` の読み込み、最小・最大解像度の収録、MLX Metal shader library、同梱した発話文判定モデルの package・tokenizer・license、Runtime の resource bundle（SwiftPM の accessor は app の resource directory から探す）にあるピン留めモデルの manifest がソースと同一であること、codesign の検証、利用者が選んだファイルへの read/write と app-scope bookmark の2つの entitlement を確認する。

アプリの build は行うが GUI を起動しない。通常の検証は実 ASR モデルを実行せず、認識精度やライブ録音の合格根拠にはならない。`.github/workflows/ci.yml` は draft PR を除き、`macos-26` 上で `verify-v1-tests` と `verify-v1-app` を並列に実行する。両 job は Python 3.13 を用意する。前者は `regex` package を install し、`scripts/test_fetch_clause_tagger.py`、`scripts/test_export_clause_tagger_onnx.py`、`scripts/test_build_app.py`、`scripts/test_fetch_mac_vad_model.py` を実行してから、固定した VAD モデルの `.build/mac-test-models`（key は `mac_models.json` の hash。main への push だけが保存する）を restore して `bash scripts/verify_v1_tests.sh` を実行する。後者は `bash scripts/verify_v1_app.sh` を実行する。両 job は `app/MacAmbientJev` package の `.build/checkouts`、`.build/repositories`、`.build/artifacts`、`.build/workspace-state.json` のみを同じ `swiftpm-sources` key で restore / save する。key inputs は runner OS / architecture、Swift と Xcode の version output の SHA-256 fingerprint、`Package.resolved` と `Package.swift` の hash で、restore prefix はありません。cache paths に build products は含まれないため、debug test bundle、debug product、release product は cache しません。test job は debug test bundle と debug `MacAmbientJev` product を build し、app job は `swiftbuild` backend の arm64 release `MacAmbientJev` product を build します。

cache hit は dependency resolution、build、test、app build を省略しない。`verify-v1-app` job だけが MLX の Metal shader library を build するため `xcodebuild -downloadComponent MetalToolchain` を実行し、実行ごとに「MacAmbientJev Local Signing」という自己署名コード署名証明書を一時 keychain に作って署名に使う。アプリ job は Python 3.13 を使い、`scripts/fetch_clause_tagger.py --format coreml` で公開 Hugging Face repository から認証なしでモデルを取得する。取得時には manifest に pin された各ファイルの byte 数と SHA-256 を検証する。

### Windows CI の temp directory と cache

Windows runner は `RUNNER_TEMP` が空でない絶対 path であり、既存 directory であることを検証してから、`TEMP`、`TMP`、`TMPDIR` のすべてにその完全な値を設定します。設定後に開始する Python / Swift の子 process はこの環境を継承し、新しい Python process ごとに `tempfile` の temp-directory 判定を行います。Foundation 6.2 の Windows *FileManager.temporaryDirectory* は *String.temporaryDirectoryPath* に進み、Windows では *GetTempPathW* を呼びます。corelibs Foundation の *NSTemporaryDirectory()* も *FileManager.default.temporaryDirectory* を返します（[Foundation corelibs implementation](https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/swift-6.2-RELEASE/Sources/Foundation/NSPathUtilities.swift)、[swift-foundation implementation](https://raw.githubusercontent.com/swiftlang/swift-foundation/swift-6.2-RELEASE/Sources/FoundationEssentials/String/String+Path.swift)）。Windows は *GetTempPathW* で `TMP` を `TEMP` より優先し（[Microsoft documentation](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw)）、Python 3.12 `tempfile` は `TMPDIR`、`TEMP`、`TMP` の順に検索します（[Python documentation](https://docs.python.org/3.12/library/tempfile.html)）。

Windows job の x64 matrix entry（`windows-2022`）では `RUNNER_TEMP` は通常 D: 上、user temp は通常 C: 上ですが、drive letter は固定せず workflow が検証した `RUNNER_TEMP` だけを使います。temp file I/O が D: に移ることで fsync / flush に利点がある可能性は仮説であり、GitHub Actions 上で測定するまでは性能改善と断定しません。両 Windows matrix entry は SwiftPM の `app/MacAmbientJev/.build` を workspace drive に残し、モデル directory の `.build` 配下の配置も変更しません。Windows CI は workspace 上の SwiftPM package / executable builds と test run をそのまま実行します。

Windows job の x64 / ARM64 matrix entries と Linux `linux-model-e2e` は同じ4つの model directory（`.build/qwen3-asr-models`、`.build/qwen3-asr-tokenizer`、`.build/silero-vad`、`.build/clause-tagger-onnx`）と同じ cache key inputs を使います。model cache key には runner OS / architecture と次の `hashFiles` inputs が含まれます。

- `app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/qwen3_asr_models.json`
- `app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/clause_tagger_model.json`
- `scripts/fetch_qwen3_asr_model.py`
- `scripts/fetch_qwen3_asr_tokenizer.py`
- `scripts/fetch_silero_vad.py`
- `scripts/fetch_clause_tagger.py`
- `scripts/pinned_download.py`

各 fetcher は cache hit のファイルも SHA-256 で検証し、破損は error として失敗し、別の取得経路へ切り替えません。

Windows job の各 matrix entry は SwiftPM package の `.build` 全体を cache します。key は runner OS / architecture、Swift toolchain version fingerprint、`Package.resolved` と `Package.swift` の hash を含み、restore prefix は同じ OS / architecture / toolchain に限定されます。この full build cache は Windows matrix entries のみで使い、Mac CI は前述の SwiftPM dependency state だけを cache します。cache hit でも dependency resolution、build、test を省略しません。

`.github/workflows/ci.yml` と [portable-core.yml](../.github/workflows/portable-core.yml) は、PR と `workflow_dispatch` を含む各対象 run で cache を restore します。明示的な v4 cache save step の定義は合計5つ（`ci.yml` に2つ、portable workflow に3つ）で、Windows の2定義は一つの matrix job の各 entry で実行されます。したがって実行時の save invocation は合計7回です（Mac 2、Linux model E2E 1、Windows model cache 2、Windows SwiftPM `.build` cache 2）。各明示 save は既存の検証・build・test command 完了後に限り、`main` への push かつ restore miss の場合だけ保存します。対象は Mac の SwiftPM source 4 path（2 job で共有）、Linux E2E と Windows matrix entries の4 model directory cache、Windows matrix entries の SwiftPM `.build` cache です。cache hit でも dependency resolution、build、test、app build を省略せず、model fetcher は hit したファイルも SHA-256 検証します。main のみで保存することで PR ごとの同内容の cache copy を増やさず、main の entry を quota 内に保ちます。PR ref の entry はその PR からのみ読めますが、main の entry は PR からも利用できます（[actions/cache v4 scope](https://raw.githubusercontent.com/actions/cache/v4/README.md#cache-scopes)、[restore / save action](https://raw.githubusercontent.com/actions/cache/v4/README.md)、[actions/cache v4 release notes (4.3.0)](https://raw.githubusercontent.com/actions/cache/v4/RELEASES.md)）。

例外として、Windows matrix の各 entry は Swift toolchain installer として pinned [compnerd/gha-setup-swift](https://raw.githubusercontent.com/compnerd/gha-setup-swift/775d3f4111c5be58a0f62f2efdd353bb8fac15c7/action.yml) を使い、その action 内部の v6 cache restore / save も行います。公開 input は restore と save を一括で制御する `cache` boolean のみで save だけを main 限定にできないため、`cache: true` を維持し、PR ref 上でも cache miss 時に保存される場合があります。この installer 内部 cache は5つの明示的定義・7つの実行とは別です。従って main-only は5定義（7 invocation）の明示 save に適用され、全 cache に対する例外のない規則ではありません。

[PR cache cleanup workflow](../.github/workflows/pr-cache-cleanup.yml) は PR close 時に `refs/pull/<number>/merge` に一致する cache を全ページ取得して削除します。該当なしは成功、API / 削除エラーは失敗として表面化します。fork PR の `pull_request` token は read-only の場合があり、その場合は削除に失敗します。`pull_request_target` は使いません。cleanup workflow の追加だけでは既存の PR cache は削除されず、削除は close event 後に実行されます（[GitHub cache management](https://raw.githubusercontent.com/github/docs/main/content/actions/how-tos/manage-workflow-runs/manage-caches.md)、[`gh cache delete`](https://cli.github.com/manual/gh_cache_delete)）。

この repository の GitHub Actions cache quota は10 GB、retention は未アクセス7日で、branch / workflow / job をまたいで共有されます。上限を超えると least-recently-used cache が eviction されます（[GitHub cache policy](https://raw.githubusercontent.com/github/docs/main/content/actions/how-tos/manage-workflow-runs/manage-caches.md)）。複数世代の keys、PR cache、toolchain installer の PR cache も quota を消費するため cache hit は保証されず、quota を無制限として扱いません。

### Swift の一時 path

Production Swift code に hard-coded な temporary root はなく、temporary I/O は *FileManager.temporaryDirectory* を使います。Tests には parser / codec / AppPaths の URL fixtures として `/tmp` literals があります。[TranscribeFileTests.makePayload](../app/MacAmbientJev/Tests/MacAmbientJevTranscribeFileTests/TranscribeFileTests.swift) の `/tmp` root も payload 構築用の inert URL だけで、disk I/O は行いません。

ライブ判定の regression は注入した判定 coordinator factory を使います。

[MicInputVolumeTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCaptureTests/MicInputVolumeTests.swift) は fake HAL のバックグラウンド通知と手動発火する確認期限を使い、要求した 50 ms と書込み失敗理由・effective/unresolved を実時間待機なしで検証します。本番の main queue `asyncAfter` による期限設定は変更しません。

`scripts/check_doc_references.py` は `README.md`、`AGENTS.md`、docs 配下の Markdown（records を除く）のリポジトリパス、script、既知 CLI の flag、Swift 型の参照を検査する。

### 発話文判定の契約

```bash
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev --filter 'DecisionTests|DecisionContractTests|DecisionEnrichmentCoordinatorTests|ClauseAssemblyTests|MaterializerTests|LiveContentPriorityGatingTests|LiveDecisionRecordingTests|FinalTranscriptPipelineTests|nativeTakeoverFinishesWithoutWaitingForLiveDecisionsAndReusesOnlyFrozenDurableAnswers'
```

[DecisionContractTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/DecisionContractTests.swift) は共有判定型の JSON 形、境界の厳密な `> 0.5`、確率の有限 0..1 検証、優先度判定の和（tagger と同じ `1e-5`）・confidence の完全一致と同率の扱い、不正な優先度判定を保存済み優先度の保留にすることを検証します。[DecisionTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/DecisionTests.swift) は回答の不足・余分でリクエスト全体が失敗し、失敗理由が保留の message になることを検証します。

計数・consumerの回帰検証は purpose 別の実 request 計数と合計、成功した判定だけの入力 token、session + 境界区間／優先度節の保留 identity、失敗した batch ごとの保留、cancel の attempt-only、判定成功後の保存失敗、低 confidence 判定・metadata 保持を対象にします。モデルの品質を合成結果で証明したとは扱いません。

実行 smoke は一時 harness で実 SessionWriter／NativeSessionProcessor／reader／metadata／export を通します。複数の保存 raw 区間から跨ぎ節と行内別節を作り、混在した優先度判定、finishInput、各 run の保存済み F・B除去範囲をそれぞれの原文に適用し、削除後の本文を区切りなしで連結した UTF-8 bytes が完全一致する場合の priority のみの carry（live の F・B除去範囲は final にコピーしない）、判定失敗の保留、設定と同じ再試行経路、metadata 再読込、txt 実出力、purpose 別 usage を観測します。判定無効（`ContentPriorityAccess.disabled`）では判定呼出し0・無分割通常表示・ローカル公開を確認し、ASR raw と `display_text` が一致します。この経路では F・B除去範囲を評価せず、F・B除去を行いません。保存済み F・B除去範囲の表示・export は共通 Swift の範囲検証で別に確認します。harness は検証後に除去します。この smoke はモデルの精度・GUI・録音権限を検証しません。

### ローカル発話文モデルの parity

発話文判定テストでは、通常の `swift test` で実 Core ML モデルを使うテストだけが skip され、model-free tests は通常の suite で実行対象です（他の suite や benchmark の gate は別途適用されます）。実モデル parity は macOS 15 以降で CPU only・float32 を使います。リポジトリルートから実行します。

```bash
CLAUSE_TAGGER="$(python3 scripts/fetch_clause_tagger.py --format coreml)"
RUN_CLAUSE_TAGGER_TESTS=1 CLAUSE_TAGGER_MODEL_DIRECTORY="$CLAUSE_TAGGER" swift test --package-path app/MacAmbientJev --filter 'LocalClauseTaggerTests|DecisionProviderFactoryTests|ClauseTaggerParityFixtureTests|ClauseTagger'
```

上の fetch command は検証済み Core ML model directory の絶対パスを返します。`scripts/build_app.sh` の後は、app bundle の Contents/Resources/clause-tagger の絶対パスを `CLAUSE_TAGGER_MODEL_DIRECTORY` に指定して同梱モデルを検証できます。gated run では `RUN_CLAUSE_TAGGER_TESTS=1` と明示的な `CLAUSE_TAGGER_MODEL_DIRECTORY` が必要です。環境変数の未設定・空値、相対パス、存在しないパス、ディレクトリでないパスはエラーになります。`MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY=1` を `RUN_CLAUSE_TAGGER_TESTS=1` なしで指定する場合もエラーです。暗黙のパス、モデルの自動取得、fallback はありません。学習済み model package は Git に含めず、pinned tokenizer は app release に同梱します。test-only の hash-pinned tokenizer JSON は Git に含めます。

このモデルは [Hugging Face repository](https://huggingface.co/Pokojaka/modernbert-ja-30m-utterance-tagger) の commit [`5c0213592cf8d59fc0b665183ab7536ddde05d1f`](https://huggingface.co/Pokojaka/modernbert-ja-30m-utterance-tagger/tree/5c0213592cf8d59fc0b665183ab7536ddde05d1f) に pin されています。model ID は Pokojaka/modernbert-ja-30m-utterance-tagger、state revision は `90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9` です。app code は MIT license、名大会話コーパスで学習した model は CC BY-NC-ND 4.0 です。共有 manifest が両形式の各取得ファイルを byte 数と SHA-256 で pin します。

Core ML 形式（`--format coreml`）の pinned files:

| Hugging Face path | bytes | SHA-256 |
| --- | ---: | --- |
| coreml/tokenizer.json | 6,724,873 | `0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062` |
| coreml/ClauseTagger.mlpackage/Manifest.json | 617 | `52c8e4a83a0b4b1f533cc1606e198fbaba9b235898c7dde6eda2c301c79b3182` |
| coreml/ClauseTagger.mlpackage/Data/com.apple.CoreML/model.mlmodel | 134,272 | `200affa73898c875c5aac52401fadf601779af28a50662edac9c47b084edbb45` |
| coreml/ClauseTagger.mlpackage/Data/com.apple.CoreML/weights/weight.bin | 146,847,424 | `e21ddf63a223e859be6b1051e326362c12fabd4cdc8c8f4cb0c18a7e657d220d` |
| coreml/ClauseTagger.mlpackage/executorch_debug_handle_mapping.json | 147,654 | `6e741f4ba9d007e49b98aa31f8db7164763660f04df3e6d92b015913f0451f44` |
| LICENSE.md | 2,185 | `08b0eeee7efa0c43bcdefa95e64f0cf0e8f869eed4d01f3c5bcc2d99f112fb77` |

ONNX 形式（`--format onnx`）の pinned files:

| Hugging Face path | bytes | SHA-256 |
| --- | ---: | --- |
| onnx/ClauseTagger.onnx | 146,889,562 | `1131898abd272f8bfb6e30828384e875971486cf9ba4f42f464f40b2f1119782` |
| onnx/tokenizer.json | 6,724,873 | `0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062` |
| onnx/export.json | 253,707 | `c62d12cba67447ba64c45d9e5471c65f69f0efebe9c2901852ec3ce8587c3a4a` |
| onnx/LICENSE.txt | 1,292 | `2e97bfc46df586a08bb5942dc2af608d1aced6023735f65797d0ced0ba7fd77a` |
| LICENSE.md | 2,185 | `08b0eeee7efa0c43bcdefa95e64f0cf0e8f869eed4d01f3c5bcc2d99f112fb77` |

fixture は production dependency を持たない all-platform の test-only SwiftPM target `MacAmbientJevClauseTaggerFixtures` に置き、reader と resources を共有します。[reader](../app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/ClauseTaggerFixtures.swift) は元 fixture を JSONDecoder で読みます。leading U+FEFF を含む値は JSONSerialization の NSString bridge が decode 時に除くため、parity support は JSONDecoder で raw scalar を保持します。

[ClauseTaggerFixtures.json](../app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerFixtures.json) は13件の元入力、厳密な token ID、boundary・span・priority の参照確率を持ち、SHA-256 は `41650293a866faba413cabaf568807243dc4684f4fca1f9660a0d26ec0860726` です。実モデル capture より先に、model ID Pokojaka/modernbert-ja-30m-utterance-tagger・state revision `90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9`・tokenizer SHA と、元13件すべての literal input ID、candidate/junction index、三 head の形と確率を照合します。期待 token ID を Swift の誤った tokenization に合わせて変更してはいけません。`training_status` が `trained` 以外の package はアプリ判定に使用できません。

[ClauseTaggerTokenizerFixtures.json](../app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerTokenizerFixtures.json) は47 cases・106 pieces を持ち、pinned tokenizer SHA-256 `0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062` を固定します。元13件に加え、BOM、composed/decomposed Unicode、OOV、emoji modifiers、whitespace、全18 added token、2つの埋め込み synthetic tokenizer config と SHA-256 による8件の exact Float32 tie cases を含みます。fixture の `tokenizer_backend` は capture provenance で、runtime dependency ではありません。現行の `MacAmbientJevCore` の [ClauseTaggerTokenizer.swift](../app/MacAmbientJev/Sources/MacAmbientJevCore/ClauseTaggerTokenizer.swift) は Foundation-only の scalar trie と Float32 Unigram lattice 実装で、`swift-transformers` を runtime import しません。swift-transformers 1.3.4 release は tokenizer algorithm の provenance です（[1.3.4 release](https://github.com/huggingface/swift-transformers/releases/tag/1.3.4)）。

[ClauseTaggerTokenizerTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerTokenizerTests.swift) は CoreTests の全 platform で無条件に実行される model-free tests です。5 tests が現在の47 cases・106 pieces・8 ties、77個の不正・未対応 configuration mutation、誤 hash・読取・parse error、byte-distinct Unicode、Float32 加算順序（比較前に Float32 へ加算）、byte fallback witness、および BOM・空白・unknown-run の raw UTF-16 範囲 regression を検証します。この回帰テストはサポート対象の埋め込み synthetic tokenizer prefix（byte ID 固定）を使います。test-only resource [ClauseTaggerTokenizer.json](../app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerTokenizer.json) は pinned tokenizer と byte-identical（6,724,873 bytes、SHA-256 `0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062`）です。期待 token ID・範囲と request の golden fixtures は変更せずに照合します。既知 scalar を含む lattice で隣接する unknown pieces の再構成失敗が `.unrepresentableText` となることも検証し、通常の OOV は byte fallback で表現します。この Core tokenizer tests にモデル weights、download、環境変数は不要です。この JSON は test resource 専用で、app fallback には使いません。

```bash
swift test --package-path app/MacAmbientJev --filter ClauseTaggerTokenizer
```

[ClauseTaggerRequestFixtures.json](../app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerRequestFixtures.json) は同じモデル identity の Core ML・CPU only・float32 による request parity を保存します。6 boundary cases・10 raw model calls と、3 targets / 3 calls の priority batch を含みます。multi-window、short/long continuation、候補なしの終端 `まあ。`、filler、backchannel を扱います。filler の必須 projection は入力 `まあ、あの、今日は損失関数の話をします。` から出力 `今日は損失関数の話をします。` です。backchannel は元コーパスの F/B owned-span argmax witness を確認します。priority batch では192-token truncation も確認します。各 request の source、candidates、`next`、全 window の input IDs・ownership・UTF-16 ranges、junction/span indices、raw 3 heads、実際の `LocalClauseTagger` response と projected text を記録します。raw model snapshots は同じ既存 encoder/model sequence の決定的 replay であり、production trace hook ではありません。fixture を書く前に replay と public response を照合します。

保存済み request の replay と実モデル capture は別の検証です。[ClauseTaggerDecisionLogicFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerDecisionLogicFixtureTests.swift) は CoreTests の3件で、同じ target の [ClauseTaggerRequestReplaySupport.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerRequestReplaySupport.swift) を使い、不変の request fixture 6 boundary cases・10 calls と、priority batch 3 targets・3 calls の計13 raw calls を、Core の pinned tokenizer と同期 decision logic で再生します。fake throwing closure は各 `inputID` の内容・順序・呼び出し数を照合し、想定外の呼び出しを throw します。すべての呼び出しがちょうど一度消費され、欠落・余分・未消費がないことと、fake throwing closure が記録済み snapshot の3 heads の raw 出力を返すことを確認します。唯一の request encoder を使って事前符号化した ownership・ranges・windows・junctions・candidates は完全一致で比較し、最終結果の keys・labels・counts・tokens・ranges・projected text の UTF-8 bytes も完全一致で比較します。probabilities と confidence は絶対誤差 `1e-3` 以下、raw head の shape・値と確率和（`1e-5` 以内）も検証します。filler の結果は `今日は損失関数の話をします。` と完全一致します。

```bash
swift test --package-path app/MacAmbientJev --filter 'DecisionProviderFactoryTests|ClauseTaggerDecisionLogic|ClauseTaggerEncodingTests|ClauseTaggerSpanProjectionTests'
```

[ClauseTaggerDecisionLogicTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerDecisionLogicTests.swift) の10件は不正 batch・keys・probabilities・malformed heads、primary tie と confidence、error propagation、および entry・windows 間・continuation 前・final return での cancellation と priority 処理を model-free で検証します。これらと上記 fixture replay、DecisionProviderFactoryTests の計20件は CoreTests で model・download・環境変数・OS gate を使わず、通常の `swift test` で実行対象です。

[ClauseTaggerParityFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/ClauseTaggerParityFixtureTests.swift) は [ClauseTaggerParityFixtureSupport.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/ClauseTaggerParityFixtureSupport.swift) を使い、環境変数で gate された実モデル parity で shape と値を比較します。object key sets、array counts、IDs、ranges、candidate/label/token totals、projected text などは完全一致し、文字列は UTF-8 bytes で比較して Unicode の byte-distinct 表記を区別します。確率と confidence は各値の絶対誤差 `1e-3` 以下、head の shape は `boundary_probs` `[1,L,2]`、`span_probs` `[1,L,4]`、`priority_probs` `[1,2]`、各確率 row の和は `1e-5` 以内です。

変換 artifact の Python 受け入れ基準では、Python reference と Core ML MLProgram を dynamic `input_ids` int32 `[1,L]` で比較し、通常入力と randomized inputs の各整数長 `L=2...192` のすべてで `boundary_probs`、`span_probs`、`priority_probs` 各 head の最大絶対誤差を `1e-3` 以下とします。mask support は長さ `2, 64, 65, 66, 128, 192` で確認します。これは Python conversion acceptance sweep の基準であり、Swift の選定 corpus が全191長を網羅するという意味ではありません。tokenizer config は Metaspace の `prepend_scheme=never` と `split=false`、正確な UTF-8 byte fallback を要求し、この契約に違反する config は拒否します。

fixture の生成と check は次のとおりです。placeholder は上記と同じ要件の絶対 model directory に置き換えます。`MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY` が未設定または `1` 以外なら committed golden と比較するだけで、書き換えません。生成時だけ `MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY=1` を指定します。

```bash
MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY=1 RUN_CLAUSE_TAGGER_TESTS=1 CLAUSE_TAGGER_MODEL_DIRECTORY=/absolute/path/to/exported-model swift test --package-path app/MacAmbientJev --filter ClauseTaggerParityFixtureTests
RUN_CLAUSE_TAGGER_TESTS=1 CLAUSE_TAGGER_MODEL_DIRECTORY=/absolute/path/to/exported-model swift test --package-path app/MacAmbientJev --filter ClauseTaggerParityFixtureTests
```

Linux / Windows の `ONNXClauseTagger`（[ONNXClauseTaggerTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXClauseTaggerTests.swift)）は実モデルの parity テストを持ち、通常の portable CI で必ず実行します。`RUN_MODEL_TESTS` のような opt-in はありません。必須の環境変数 `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` に `python3 scripts/fetch_clause_tagger.py --format onnx` が出力する絶対ディレクトリを設定します（`scripts/verify_portable.sh`、`scripts/test-windows.ps1`、`.github/workflows/portable-core.yml` が設定します）。未設定・空・相対パス・存在しないディレクトリはテストの失敗で、skip しません。

suite は serialized で、実行全体で共有する runtime fixture は二つです。raw の `ONNXClauseTaggerModel` fixture は入力契約と original fixture の3 heads を検証し、actor `ONNXClauseTagger` fixture は request parity と cancellation を検証します。

- `ClauseTaggerFixtures.json` の13件は literal な `input_ids` をそのまま推論し、`boundary_probs`、`span_probs`、`priority_probs` の head ごとに最大絶対誤差を `1e-3` 以下とします。head ごとの最大値は fixture ごとと全体でログに出ます。
- `ClauseTaggerRequestFixtures.json` の境界 6 case と優先度 batch は `ONNXClauseTagger` の public API へ実 request を渡し、response を Core ML 由来の保存値と比較します。key、candidate、label、token 数、除去範囲、投影後の文字列は完全一致、確率と confidence は `1e-3` 以下です。`まあ、あの、今日は損失関数の話をします。` は `今日は損失関数の話をします。` になります。
- model への不正入力（空、1 token、193 token、CLS・SEP 欠落、負・語彙外の ID）、最短2 token と最長192 token の推論、取り消し済み request、非正の thread 数（ロード前に失敗）、相対・存在しない directory のテストを含みます。thread 数と directory のテストは model を使いません。
- `factoryInvokesTheProviderLoaderOnceAndReturnsItsIdentity` は共有済みの実 `ONNXClauseTagger` provider を factory に渡し、factory ごとの LoadCounter で loader 呼出しを数えます。最初の identity 取得前は0、取得後・coordinator の反復取得後・identity の再取得後は1のままです。これは provider loader の呼出し回数であり、tagger の constructor 回数ではありません。既存の共有 provider を使うため3つ目の session は初期化しません。

```bash
CLAUSE_TAGGER="$(python3 scripts/fetch_clause_tagger.py --format onnx)"
MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY="$CLAUSE_TAGGER" swift test --package-path app/MacAmbientJev --filter 'ONNXClauseTagger|ClauseTaggerAssets'
```

fetcher と app bundling の self-test は次のとおりです。

```bash
python3 -B scripts/test_fetch_clause_tagger.py
python3 -B scripts/test_build_app.py
```

[`test_fetch_clause_tagger.py`](../scripts/test_fetch_clause_tagger.py) は標準ライブラリだけを使い、network に接続せず synthetic data で両形式の manifest、各 pinned file の path・byte count・SHA-256（LICENSE.md を含む）、正確な tree、network なしの有効 cache 再利用を検査します。破損・不足・余分・symlink を含む cache の fail-fast、取得・hash・byte count failure 時の no-retry と staging cleanup も確認します。[`test_build_app.py`](../scripts/test_build_app.py) は Python 標準ライブラリの5件の isolated bundling tests で、fake repository と stub command を使い、Core ML fetch contract、成功時の model・tokenizer・LICENSE.md 同梱、fetch failure / 不正結果時に app 公開前で停止することを検査します。

Core ML の入力は dynamic `input_ids` int32 `[1,L]`（`2...192`）、出力は `boundary_probs` `[1,L,2]`、`span_probs` `[1,L,4]`、`priority_probs` `[1,2]` です。Core ML 変換器は scratch の外部ツールで、このリポジトリに変換 script はありません。export artifact は base model、trained weights、明示した output directory を使って生成し、この入出力契約を満たす必要があります。ポータブル ONNX の書き出しは次節の repository script で行います。変換実験の Python package version は PyTorch `2.14.1`、transformers `5.19`、coremltools `9.0` で、converter は unsupported PyTorch version warning を出します。Core ML Tools [9.0 release notes](https://github.com/apple/coremltools/releases/tag/9.0) には Torch `2.7` のサポートが記載されています。新しい Torch で変換が成功したことを公式サポートの根拠とは扱わず、artifact ごとに実際の installed version と warning を記録してください。

[DecisionProviderFactoryTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/DecisionProviderFactoryTests.swift) は全 platform の CoreTests にある model-free 7件で、fake providers を使い、環境変数・filesystem・モデルなしで実行します。成功・失敗時の single-flight と同時要求での identity/coordinator 共有、同じ failure と load の CancellationError の cache、完全な identity/provenance、identity の lookup/確認だけでは判定 request も usage も発生しないこと、synthetic token accounting、provider cancellation が attempt-only で cache を再利用することを検証します。実 token usage や実モデル推論を測るテストではありません。これらは単体テストであり、GUI 操作、マイク／システム音声の権限、画面表示の確認にはなりません。

### 合成イベントによる回帰検証とライブ滞留計測

```bash
swift test --package-path app/MacAmbientJev --filter 'catalogRejectsUnreadableEventLog|validatedEmptyVADCompletesWithoutSpeechInference|recordingPreservesCaptureAndReleaseFailures|coolingDrainsLiveBacklogWithLatestCheckpointAndStopReleasesState'
LIVE_ASR_REGISTRATION_MEASUREMENT=1 swift test --package-path app/MacAmbientJev --filter measureLiveRegistrationCost
LIVE_ASR_BACKLOG_MEASUREMENT=1 swift test --package-path app/MacAmbientJev --filter measureLatestCheckpointRetentionDuringThermalStall
swift test --package-path app/MacAmbientJev --filter 'liveASR|liveRows|stoppingRecordingCancels'
swift test --package-path app/MacAmbientJev --filter 'appRecordingShowsLiveRowsWhileDecisionsWait|appRecordingShowsDecisionFactoryFailureReason|liveRowsShowAtOnce|nativeTakeover'
CLAUSE_INCREMENTAL_BENCHMARK=1 swift test --package-path app/MacAmbientJev --filter liveClauseIncrementalBenchmark
```

registration と backlog の計測 test は、それぞれ `LIVE_ASR_REGISTRATION_MEASUREMENT`、`LIVE_ASR_BACKLOG_MEASUREMENT` が厳密に `1` の場合だけ有効です。環境変数が未設定または `1` 以外なら Swift Testing の `.enabled(if:)` が test を無効にします。portable CI は Swift 6.2 を使います。条件付き test の仕様は [Swift Testing の有効化と無効化](https://docs.swift.org/latest/documentation/testing/enablinganddisabling/)を参照してください。`materializerHandlesTenThousandSegmentLog` は 10,000 件の count と最終本文だけを確認します。

correctness test は読み取れないイベントログ、検証済み VAD の空結果、録音障害と停止時の資源解放障害、冷却後のライブ認識再開の境界を合成イベントで検証する。計測 test は 5 秒ごとに一発話とした 10 分・1 時間・4 時間相当の合成イベントを使い、再登録の中央値時間と critical 時に保持する ASR バッチ・区間参照・checkpoint・chunk 一覧の項目数を出力する。計測 test の成功は性能合格を意味しない。時間はモデル推論を含まず、保持数は RSS ではない。実キャプチャ、GUI 起動、権限要求は行わない。

`measureLiveRegistrationCost` は debug 構成で、登録 setup を計測から除外し、各 120・720・2880 件の pending 履歴に対して同じ ID を 100 回再登録する標本を 7 個取り、一呼出しあたりの中央値を µs で出力します。登録 progress はセッション内の materialized 行と ID 数を使い、pending 履歴全体を再構築しません。判定目安は 4 時間相当の中央値 ≤ 50 µs かつ 10 分相当の ≤ 3 倍です。時間の単体テスト assertion は置きません。比率が timer noise で外れた場合は全 7 標本を報告し、同じ標本数で逐次に一度再計測します。認識済み行の更新 projection、モデル推論、アプリのキュー保持量はこの計測の対象外です。測定結果は [live registration 計測記録](records/2026-10-04-live-registration.md) を参照してください。

`measureLatestCheckpointRetentionDuringThermalStall` は portable な `LiveTranscriptionCoordinator` を直接動かし、fake executor、注入 sleep、critical 熱状態を使って、5 秒ごとに一発話とした 10 分・1 時間・4 時間相当を計測します。120・720・2880 発話で checkpoint の保持数はセッションあたり 1 件、保持 chunk 項目数は最新 checkpoint の 120・720・2880 件だけです。区間参照は全件保持します。AppState、filesystem、model は使わず、計測 harness は時間の assertion を置きません。`coolingDrainsLiveBacklogWithLatestCheckpointAndStopReleasesState` は実 `AppState.startRecording` / `stopRecording`、注入 VAD polling、合成の保存済み PCM、injected ASR を使い、critical 中の認識停止と最新 checkpoint の保持、冷却後の全区間を一度だけ順次認識すること、録音停止後のキュー・checkpoint 解放を確認します。portable な `criticalLiveDrainWaitsWithoutDequeueThenResumesFIFOUsingLatestCheckpoint` は、後から更新された最新 checkpoint が FIFO の各 batch に使われることを検証します。実モデル、マイク、GUI は使いません。

[LiveASRThermalQueueTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LiveASRThermalQueueTests.swift) は共有 [LivePollTestSupport.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LivePollTestSupport.swift) の手動進行する VAD poll gate と thermal-recheck gate を分け、thermal gate の停止を待ってから ASR 未実行・熱停止 status を確認し、冷却後は recheck を進めて drain 完了を待ちます。`ThermalMonitoring` は `@MainActor observeChanges` を必須とし、購読寿命を表す token を返します。`AppState` は初期化時に購読し、本番 composition の [MacAmbientJevApp.swift](../app/MacAmbientJev/Sources/MacAmbientJev/MacAmbientJevApp.swift) だけが `MacThermalMonitor` を渡します。`MacThermalMonitor` は token の寿命に合わせて host observer を設置・解除し、[TestThermalMonitor.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/TestThermalMonitor.swift) は合成変更を駆動します。熱状態の読み取りと再開判断は同じ注入 monitor を使います。`coolingResumesThermallyHeldFinalization` は直接 resume せず fair を通知し、coordinator の完了を待って durable な completed metadata を確認します。portable な [LiveTranscriptionCoordinatorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveTranscriptionCoordinatorTests.swift) の `criticalHeatSuspendsLiveRecognitionUntilCooled` も注入 sleep gate と drain 完了で同期します。

ライブ ASR regression は認識後の新規 pending 登録・重複 ID、ASR 完了・空本文・失敗の ordered snapshot、同一 run の保存済み節更新と active run 切替、登録・完了・失敗・終了イベントの保存障害、並行登録・終了を検証します。取得済み行配列は後の認識や節更新で変わりません。判定待機中も全行が即時表示されること、時間順、無効・初期化失敗・失敗した batch ごとの保留、空区間のテキスト列終端、ASR gap 後の未解決先頭を注入 provider で検証します。`LiveASRSession` の writer は必須の `SessionEventAppending` であり、並行登録 test は本番 `SessionWriter` を包む fake writer で最初の `segment.created` append を gate し、append 開始を待って二つ目を登録し、最初を解放して worker の完了を待ち、本番 test hook なしで durable event が一件であることを確認します。

[LiveClauseIncrementalTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveClauseIncrementalTests.swift) は通常の全履歴 materializer と増分更新の行・projection・保存 JSON を照合し、長い跨ぎ節、空区間、ASR gap、不正 batch の rollback、取得済み snapshot の不変性を検証します。[LiveClauseIncrementalBenchmark.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveClauseIncrementalBenchmark.swift) は一時音声と注入 ASR で実 `LiveASRSession.applyClauseEvents` を動かし、40・400・2500 区間で境界・節閉鎖・優先度を反映する時間を、テスト専用の全履歴再構築 actor と比較します。各規模で warmup 1 回と標本 20 回を使い、結果の同一性は計測区間外で照合します。通常 test では計測を無効とし、時間閾値を correctness の合否にしません。[測定記録](records/2026-10-09-clause-incremental.md) を参照してください。

[PriorityBatchPersistenceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/PriorityBatchPersistenceTests.swift) と [LiveContentPriorityGatingTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveContentPriorityGatingTests.swift) は注入 provider と一時イベントログで、81 節の確定・優先度再試行・ライブを検証します。失敗した batch をそれぞれ 40/40/1 件の保留として保存すること、境界判定の失敗がその区間だけを保留にして優先度判定を続けること、coordinator 取得中・判定待ち中の取り消しを扱います。LiveContentPriorityGatingTests の fixture は request・row・status の条件を continuation 通知で待ち、worker の終了後に `SessionWriter.readDurableLog(eventsURL:)` でwriter と同じ排他ロック下の durable snapshot を一度だけ読み、各 assertion と reader の再読込で同じ bytes を使います（取消しの基準 snapshot は fake provider の gate で worker を保持した状態で読みます）。ここで `timeLimit` を付けた tests の上限は hang guard のみで、意味上の条件や実行時間予算ではありません。各テストは worker の終了後に一時 root を削除します。[NativeSessionProcessorLiveTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/NativeSessionProcessorLiveTests.swift) の finalization takeover fixture は provider gate、transcript update 通知、保持した live worker の終了を待って late response を確認するため、経過時間に依存しません。意味上の coordinator tests も明示 gate を持つ fake effects と注入 sleep で同期し、性能予算を置きません。suite budget は test process 完了後の回帰判定であり、hang protection ではありません。個々の test の `timeLimit` と GitHub Actions の job-level timeout が hang / job 停止を扱い、job timeout は build や asset fetch も含む job 全体に適用されます。Linux fast、Windows、Linux model E2E job には workflow で job-level timeout が指定されています。`.github/workflows/ci.yml` の Mac jobs に明示的な `timeout-minutes` はありません。実モデルは使いません。

`appRecordingShowsLiveRowsWhileDecisionsWait` は実 `AppState.startRecording`、checkpoint の VAD polling、区間登録、ライブ ASR drain、判定 queue、画面用 projection を通します。capture・VAD・ASR・判定 provider は合成入力に置き換え、応答を止めている間も通常行が表示され、保存済み判定だけが反映されることを確認します。`appRecordingShowsDecisionFactoryFailureReason` は分類器生成時の合成エラーを使い、理由が状態表示に残り、通常行を表示して録音と ASR を継続することを確認します。実モデル、マイク、GUI は使いません。

ライブ ASR drain の完了は、独立して動く判定キューの完了を保証しません。AppState はライブ処理の sleep を必須引数で受け取り、本番は Task.sleep、[LiveDecisionRecordingTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/LiveDecisionRecordingTests.swift) と [MicInputStatusTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/MicInputStatusTests.swift) は手動で進める poll gate を渡します。ライブ判定の regression は起動時の保存整理 task を await し、VAD poll を一回進めて区間登録を確認した後、fake tagger の request 通知と画面用 rows・エラー状態の publisher 通知を待ちます。保存済み LOW 判定の反映も rows の通知で確認します。

`NativeSessionProcessor` → `FinalTranscriptPipeline` の pacing sleep も必須注入です。本番 composition は Task.sleep を渡し、[FluidFinalTranscriptIntegrationTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/FluidFinalTranscriptIntegrationTests.swift) の `finalTranscriptPipelineForwardsPacingAndPauseToASR` は fake sleep recorder で正確な `.seconds(2)` と pause 判定の順序を確認します。sleep closure は実時間待機せず記録するため、この pacing test は時間経過に依存しません。

[MicInputStatusTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/MicInputStatusTests.swift) の fake VAD は指定した batch 数の到達を continuation で通知します。各 poll の次の sleep gate まで待つことで、AppState が音声レベルを取り込んだ後に状態を検証します。入力音量の書込みは fake volume の通知、poll 中の VAD 障害は状態表示の通知を待ち、開始時の VAD 障害は `startRecording` の完了で確認します。これらの待機は中断時に条件名を含むエラーを投げ、`timeLimit` は hang guard としてのみ使います。実時間の待機間隔や期限は同期条件にしません。

[IdleReleaseTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/IdleReleaseTests.swift) は startup maintenance、processing coordinator の drain、model preparation/release task の完了を待ってから検証します。[RecordingFailureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppTests/RecordingFailureTests.swift) は failure-stop task を await し、同じ session の重複 failure が完了前後で stop と finalization を二重実行しないことを確認します。両テストの `timeLimit` は hang guard のみで、経過時間は同期条件ではありません。

保存済みセッション catalog は active ASR run のイベントログ・payload を読み取り専用で検証し、欠損・不正・不完全な末尾を持つログを破損として表示する。合成 catalog regression は malformed / missing / directory の各ケースで非 exportable 状態、再処理可否、manifest と metadata の不変性を確認する。

Linux 音声正規化は入力と出力が同一ファイル（シンボリックリンク解決後を含む）なら、出力先を変更する前に拒否し、原音声を保持する。`tools/linux-audio/tests/test_audio.py` は実 ffmpeg を使う同一パス・symlink の境界と、正常変換・変換失敗時の出力処理を検証する。

`validatedEmptyVADCompletesWithoutSpeechInference` は1秒の合成無音を2回確定し、検証済み VAD の空結果で完了して ASR 準備を呼ばないことを確認する。読み取れる空 transcript、segmentation / asr の2段階 provenance と各 stage の成功0件、`complete` metadata、終端の無発話表示、復旧対象外の分類を検証する。VAD 自体の失敗と発話ありの ASR 失敗は別の tests で `failed` となり、公開済み run を保持する。これは orchestration の検証であり、実 FluidAudio モデルの無音成功・クラッシュを測った結果ではない。

[CanonicalAudioIngressTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/CanonicalAudioIngressTests.swift) は device-rate の合成 tone を irregular / 512-frame block に分けて実 drain とディスクへ通す。48 kHz・44.1 kHz の累積 duration、block 境界の single-stream reference との sample 差、997 / 3101 Hz の波形誤差、16 kHz identity、4-channel import 平均、fractional-ratio の gap・overlap・overflow・stop tail、部分 append failure 後の retry と並行 finish / snapshot を検証する。fixture を保存前に preconvert しない。EOS 後の全体長は正確な長さの floor か ceil で、gap は公開範囲へ切り詰める。

`captureStartReservesStoredPCMNotDeviceRate` は injected tap の実 capture start を 48 kHz・44.1 kHz・16 kHz で実行し、601,600,000 bytes の受理と 601,599,999 bytes の拒否を確認する。hardware・permission prompt は使わない。[CanonicalEngineInputTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/CanonicalEngineInputTests.swift) は `NativeQwen3ASREngine` が model load 前に非 canonical sample rate を拒否することを検証する。`finalizationEnginesReceiveCanonicalAudioForRecordedAndImportedSessions` は48 kHz の録音を irregular block で実 drain に通した session と44.1 kHz stereo の import を実 `NativeSessionProcessor` で確定し、injected VAD が16 kHz・mono・float32LEを、injected ASR が sample rate 16 kHz・16,000 samples を受け取ること、および import original の bytes が不変であることを検証する。

### 保存音声のテスト

[SessionAudioStorageFormatTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/SessionAudioStorageFormatTests.swift) は `storage.json` の 4 つの形を bytes で固定する（[保存形式](storage.md)の例はこの出力）。[RecordingAudioCompactorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingAudioCompactorTests.swift) は 16-bit FLAC への変換を、4,096 フレーム前後を含む長さ、クリップ・端点・非有限値、破損・欠落・余剰フレームの FLAC、全 `Boundary` での中断と再実行の収束で確認します。さらに `maintenanceCancellationBeforeFirstCandidateReportsEveryCandidateAsUncompleted` と `maintenanceCancellationDuringCandidateReportsCurrentAndRemainingButNotCompleted` は、最初の item より前・処理中の shutdown cancellation で現在と残りを `.interruptedByShutdown` にし、成功済み item を結果から除くことを検証します。`aRealMaintenanceErrorIsPreservedWhenCancellationAlsoOccurs` は実エラーを `.failed` として残し、後続未実行 item を `.interruptedByShutdown` にすることを確認します。[SessionProcessingCoordinatorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionProcessingCoordinatorTests.swift) は両 issue のセッションを保存整理成功まで推論復旧に含めないことを検証します。[LaunchMaintenanceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/LaunchMaintenanceTests.swift) は起動時の保存整理が全セッションを収束させ、失敗したセッションをフォルダー名付きで返すことを確認する。[SessionStorageFinalizationTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/SessionStorageFinalizationTests.swift) は全結果での一時音声の削除、変換・削除の失敗報告、一時停止中の削除失敗、FLAC からの再処理（再符号化なし）、整理後の古い音声ソースを使わないことを、音声から結果を導く注入エンジンで確認する。[SessionExportTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionExportTests.swift) は portable な PipelineTests で、全 OS で FLAC の無変換コピー、読み込み音声の原本コピー、PCM 状態の拒否、破損 FLAC での失敗と既存書き出しの保持、置き換えの失敗時の復元と復元失敗・作業用フォルダー削除失敗・置き換え前フォルダー削除失敗の報告、中断された置き換えの回復、書き出しが内部音声を変更しないことを確認する。マイク・システム音声の権限や GUI の起動時整理の表示は、これらでは確認できない。

共通 Core の codec tests は [RecordingFLACEncoderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/RecordingFLACEncoderTests.swift)、[FLACTimelineReaderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACTimelineReaderTests.swift)、[FLACFrameDecoderTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACFrameDecoderTests.swift)、[FLACMD5Tests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACMD5Tests.swift)、[FLACBitstreamTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FLACBitstreamTests.swift) にあります。reader の round-trip は noise・silence・clipped alternating signal・sine の 4 種と 1、4,095、4,096、4,097、12,305 frame の 5 長さを組み合わせた 20 ケースで、任意範囲読み取り（block 境界をまたぐ範囲を含む）も比較します。CRC、metadata・frame の切り詰め、長さ・MD5 の不一致、末尾 bytes を拒否し、handcrafted frame で FIXED 次数 0〜4、LPC、Rice2、escape coding、wasted bits を検証します。埋め込みの 16-sample frame は FIXED 次数 2・partition order 3 とし、先頭 partition の残差数が 0 となる境界も検証します。MD5 は RFC 1321 の既知 vector と signed 16-bit little-endian sample を使った vector で確認します。

`flac` CLI は codec tests の参照 oracle です。ローカル環境（VM を含む）では任意で、テストは `PATH` 上の実行可能ファイルだけを検索します。実行可能ファイルが見つからない場合は Swift Testing の `.enabled(if:)` gate により該当する interop tests を無効にします（[無効化可能なテスト](https://docs.swift.org/latest/documentation/testing/enablinganddisabling/)）。portable CI では `flac` を必須にします。Linux fast job は Ubuntu noble の distro package を install し、Windows job の x64 / ARM64 matrix entry は同じ公式 [FLAC 1.5.0 Win64 archive](https://github.com/xiph/flac/releases/download/1.5.0/flac-1.5.0-win.zip) を SHA-256 `53f1500f0d6e7c61379d7fee50d4a9f7f504c650009506d9ba015530d76c0dde` で検証して展開します。ARM64 entry は Windows 11 の x64 emulation をこの test oracle のためだけに使います（[Microsoft: x64 emulation on Windows on Arm](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation)）。Linux fast と両 Windows matrix entry は `flac --version` を確認し、実行可能ファイルがない場合または version check が失敗した場合は job が失敗します。FLAC CLI はテスト専用で release payload には含まれません。参照エンコーダーを使う reader テストは、`-0` による FIXED、`-8` による LPC、全 sample が 8 の倍数となる wasted-bits 入力、`--lax -b 65535 -l 32` で符号化した入力の 65,535 sample 境界をまたぐ範囲読み取りの4ケースを検証します。参照 CLI の仕様は [flac 1.5.0 manual](https://raw.githubusercontent.com/xiph/flac/1.5.0/man/flac.md) を参照してください。[RecordingAudioCompactorTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/RecordingAudioCompactorTests.swift) は portable な PipelineTests で、全 OS で compactor を検証します。一方、session reader・symlink 境界の integration tests（[SessionAudioReadersTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionAudioReadersTests.swift)、[SessionAudioSymlinkTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionAudioSymlinkTests.swift)）は macOS 専用の AppleSupportTests で、Core codec を通して検証します。

[SessionFileAccessTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/SessionFileAccessTests.swift) と [SessionAudioSymlinkTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevAppleSupportTests/SessionAudioSymlinkTests.swift) は一時ディレクトリだけを使い、イベント writer の初回 open と初期化後の置換、manifest・metadata の読込みと書込み、audio 親ディレクトリ、chunk・original・FLAC・partial の symlink を拒否することを検証します。セッション外の sentinel の bytes・ディレクトリ内容を比較し、descriptor を開いた後の URL 置換が元のファイルの読み書きを保つことと、通常セッションの成功経路も検証します。catalog・復旧はリンクされたセッションをエラーとして返します。選択 root の symlink 拒否は [AppPathsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/AppPathsTests.swift) が対象です。

AppState の合成テストに注入する `temporaryDefaults()` はインスタンス内の辞書だけを使う UserDefaults test double です。実 UserDefaults の標準 domain・suite domain を読み書きせず、音声デバイス・実ネットワークも使いません。

### セッション保存容量の合成計測

```bash
python3 scripts/measure_session_storage.py --sessions-root /private/tmp/mac-ambient-jev-storage-measure --seconds 600
```

`--sessions-root` と `--seconds`（正の整数。既定値なし）は必須。明示した scratch root に実行ごとの新規ディレクトリを作り、録音・import の保存、共通確定処理、書き出しを順次実行する。root は GUI の sandbox 内と CLI の非 sandbox の実データ・cache 領域、およびその祖先・子孫を指定できない。マイク、システム音声、GUI、実モデル、権限要求を使わない。Swift test はこの計測一つだけを実行し、通常の suite では無効にする。

fixture は seed 固定の `--seconds` 秒・48 kHz stereo float32 CAF の再現可能な低域 noise。録音は device-rate channel 平均を 512-frame block で ring / 実 capture drain の converter に渡し、16 kHz mono PCM を保存する。import は byte-for-byte original のコピーから同じ canonical timeline を毎回構築する。注入 VAD は16 kHz mono を検証して最初の1秒を一発話として返し、注入 ASR はその16 kHz・1秒の入力を検証する。音声全体の保存・import timeline 構築・export は実装を実行する。これは保存容量の計測であり、音声認識精度・実 hardware capture・人声の圧縮率の根拠ではない。

`disk-usage.json` は録音終了時の session 全体、確定後の session 全体、import の処理タイムライン構築直後、各 export フォルダーの bytes を報告する。bytes は metadata を含む通常ファイルの論理長の合計で、filesystem の割当容量ではない。import の計測時点は original と処理タイムラインを含む。600 秒を一時間へ換算するときは 6 倍する。fixture・session・export・レポートは調査用に保持し、削除は利用者が行う。

### 実 ASR モデルの smoke

Apple Silicon / macOS で、明示的な WAV ファイルを指定する。

```bash
RUN_MODEL_TESTS=1 ASR_SMOKE_AUDIO="$AUDIO_WAV_ABSOLUTE" \
  bash scripts/verify_v1.sh
```

`ASR_SMOKE_AUDIO` は絶対パスの読み取り可能なファイルが必須。Runtime の ASRIntegrationTests はさらに 16 kHz、mono、0 秒超〜60 秒以下を要求する。日本語音声を使う。モデルをロードして認識し、trim 後の本文が非空で日本語文字を含むことを確認するが、参照文との一致率は測らない。ASRIntegrationTests と MacModelLoadingIntegrationTests は `RUN_MODEL_TESTS=1` のときだけ動き、アプリが使うモデル directory（`~/Library/Application Support/mac-ambient-jev/models`）にピン留めした ASR・VAD の2モデルが取得済みで検証に通ることが前提です。VADParityFixtureTests の FluidAudio 一致検査は `RUN_MODEL_TESTS=1` または `MAC_AMBIENT_JEV_TEST_APP_SUPPORT` があるときに動きます。エンジンはダウンロードしないため、未取得なら型付きエラーで失敗します。別の場所のモデルを使うときは、絶対パスの Application Support 相当 directory を `MAC_AMBIENT_JEV_TEST_APP_SUPPORT` に指定します（その下の mac-ambient-jev の models フォルダーを読みます）。テスト用 directory には manifest のファイルだけを hard link かコピーで置けば足ります。[VADParityFixtureTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/VADParityFixtureTests.swift) の FluidAudio 一致検査だけは `RUN_MODEL_TESTS=1` がなくても `MAC_AMBIENT_JEV_TEST_APP_SUPPORT` があれば動き、CI はこれで固定した VAD モデルを渡します。

実際のダウンロードは [RealModelFetchIntegrationTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/RealModelFetchIntegrationTests.swift) が確かめます。`URLSessionModelTransport` でASR・VADの2モデルを約2.5 GBダウンロードし、`ModelPreparer` で照合と読み込みを行い、短いクリップで ASR と VAD を実行して経過時間とスループットを表示します。`RUN_MODEL_TESTS=1` と、絶対パスの `MAC_AMBIENT_JEV_TEST_APP_SUPPORT` があるときだけ動きます（`verify_v1_tests.sh` は `RUN_MODEL_TESTS` を外すので動きません）。アプリ自身の directory には取得しません。実行途中で止めて同じ directory で再実行すると、取得済みのファイルと `.partial` を使って Range で再開します。表示するスループットは、その実行でダウンロードした byte 数だけで計算します。

```bash
RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_TEST_APP_SUPPORT=/absolute/folder \
  swift test --package-path app/MacAmbientJev --filter RealModelFetchIntegrationTests
```

`verify_v1.sh` は integration test の検出と Runtime test bundle の存在も確認し、指定時だけその bundle を xctest で実行する。`RUN_MODEL_TESTS=1` だけで fixture を指定しない手順は使えない。

## 共通 Swift の検証

[FileSHA256Tests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/FileSHA256Tests.swift) は既知 digest と padding 境界、chunk size を変えた file / Data の一致、1 MiB 超の file を検証します。timing assertion はありません。

### F・B除去範囲と表示 projection

[ClauseTaggerSpanProjectionTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/ClauseTaggerSpanProjectionTests.swift) は `span_probs` の4列を O=0、F=1、D=2、B=3 と解釈し、各 token の argmax と同率時に最小 index を選ぶことを検証する。O/F、F/D、O/B、D/B の tie と4 label 全ての tie を含み、token 範囲と生成される F・B除去範囲は原文の end-exclusive UTF-16 offset で表す。UTF-8 byte fallback の複数 token が一つの Unicode scalar を表す場合、それぞれがその scalar 全体の UTF-16 範囲を指し、UTF-8 byte offset にはしない（BOM は `[0,1)`、emoji の byte token は各々 `[1,3)`）。token 範囲を順に適用し、重なる位置は後の token の label で上書きする。純粋な B と隣接する F+B は除去し、連続する除去文字は一つの範囲にまとめる。kana・decomposed character・emoji を構成する scalar が F/B 混在でも Character 全体を除去し、O/D が含まれる Character はどちらの scalar 順でも全体を残す。テストは surrogate pair、decomposed scalar、token overlap、無効な shape・確率範囲・range も扱う。

[TranscriptTextProjectionTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevCoreTests/TranscriptTextProjectionTests.swift) は明示された F・B除去範囲だけを削除し、接続した句読点も削除する一方、無関係な空白・改行、開き括弧・引用符を保ち、本文を削除位置をまたいで連結し、retainedRuns/displayRanges は写像用の別々の run として保持することを確認する。入力範囲は重なり・隣接・未整列を許さず、句読点拡張後の除去範囲だけを結合する。F・B除去範囲が空なら `まあ、あの、今日は損失関数の話をします。` のようなフィラーらしい文字列も変えない。UTF-16 範囲が surrogate pair／Unicode Character の途中を割る場合や、範囲が空・重複・隣接・未整列・範囲外の場合は拒否する。

`materializerAppliesFillerRemovalOnlyAfterSavedAssessment` は ASR 原文 `えー、資料を配ります。` が assessment 前と boundary pending（request failed）時にはそのまま表示され、保存済み assessment の F 範囲 `[0,2)` を適用した後だけ表示本文が `資料を配ります。` となることを検証する。保存後も `text` と ASR event は原文のまま。tagger 初期化失敗も raw 表示と pending を保ち request は0件（`failedTaggerLoadKeepsLiveRowsUnsplitAndPendingWithoutRequests`）。[LiveClauseIncrementalTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/LiveClauseIncrementalTests.swift) は保存済み F・B除去範囲の到着で対象行の projection cache が更新され、古い raw projection が残らないこと、増分結果が全履歴 materializer・row projection・JSON と一致することを照合する。不正な event batch は assembly・clause・priority の状態と公開 row を部分変更せず transaction rollback し、その後の正しい batch でだけ更新する。

`boundaryAssessmentRequiresAndCarriesFillerRanges` は assessment JSON の必須 `filler_ranges` 欠落を decode error にし、encode/decode と run carry で範囲が保持されること、F・B除去範囲が異なれば decision は同一でないことを検証する。event reader／coordinator は原文外の範囲を拒否する。`savedTranscriptLoaderKeepsRawFillerTextForPresentationAndExport` は保存済み ASR event を `SavedTranscriptLoader` で読み、assessment 保存前後も原文と event bytes が変わらず、保存済み F 範囲の後だけ表示 projection と実際の `transcript.txt` が `今日は公開鍵暗号を説明します。` になることを確認する。GUI の選択コピーとアクセシビリティ読み上げは別途、画面上で検証する。

節優先度の回帰検証は注入 `DecisionProvider` で決定的に行い、モデル品質の正解とは分ける。厳密な `> 0.5` と LOW 採用 `≥ 0.90`（直前の Double を含む）、候補の raw UTF-16 座標、候補なし・無句読点・連続句読点と末尾除外、跨ぎ節と終端、再利用対象を除いた後の40/41節の batch 境界を対象とする。候補が空の終端境界も boundary request として送信・計数し、input token を持つ。boundary と priority の request 数は独立して数え、この境界テスト単独の priority request は0件だが、全処理では非空の閉じた節を通常どおり priority request で分類する。最初の回答が有効でも後続の回答欠落・余分・不正な優先度判定で全batchを拒否し、一requestの失敗として数える。確定処理では、各 run の保存済み F・B除去範囲をそれぞれの原文に適用して得た部分を区切りなしで連結し、その UTF-8 bytes が完全一致する場合に限り durable な priority 判定を再利用する。比較では trim・句読点・Unicode byte差を同一視せず、未公開 retry の回答も使わない。carry するのは priority 判定だけであり、live の F・B除去範囲を final にコピーしない。schema・参照・coverage の破損、保留再試行と公開 snapshot、request 単位の token 計数、takeover 時の保存済み LOW の除去と判定待ち行の本文表示を確認する。LOW＋続き待ちは閉じた LOW 部分だけを除き、待機本文を保持する。画面 projection・txt・`display_text` は混在 PRIMARY/LOW（LOW を除いた本文）、全 LOW（行なし）、待機・保留・再試行待ち（本文を表示）、F・B除去後に本文が空になる実 slice で本文と行集合を確認する。文言・内部配線・コピーした設定値を固定するテストは根拠にしない。

実ファイルの受入smokeは一時harnessで `NativeSessionProcessor` → `SessionWriter` → metadata・readerの再読込 → `SavedSessionCatalog` → `SessionExporter` を通す。注入ASRの `えー、週末の設計を確認します。そうですね。` からPRIMARY/LOW混在を作り、rawの保持、LOWを除いた表示本文と実txt出力、全LOW行の非表示を確認する。注入した判定失敗ではpriority保留の本文を表示し、priorityだけのtargeted retryで公開boundaryを維持・非対象pendingをcarryする。boundaryの失敗では無分割行を保持し、boundary retryで両runとpendingを一括公開する。判定結果の前の再読込では直前の公開snapshotのままであることを確認する。2つのlive区間から1つのfinal区間への再利用は、各 run 自身の保存済み F・B除去範囲を適用した本文を区切りなしで連結し、UTF-8 bytes が完全一致する場合に priority だけを carry し、live の F・B除去範囲を final にコピーしないことを確認する。event appendとmetadata公開をそれぞれ実ファイルで失敗させ、ローカルのdurable本文・本文表示・3段公開を保持し、未公開の任意段を採用しないことを確認する。注入値はモデル精度の証拠ではない。harnessと一時セッションは受入後に削除する。

ASR gap の smoke は実ファイルに非空本文・ASR 欠落・成功した空 ASR・後続本文を保存し、`DecisionEnrichmentCoordinator` → metadata 公開 → reader/materializer の再読込を通す。前半本文を未解決のまま残し、空 ASR より後の本文だけを一回の優先度判定で分類し、保存 snapshot と再読込が一致することを確認する。空 ASR の後に新たな gap がある場合に先頭を推測しないことは回帰テストで扱う。

ライブ状態表示の実ファイル smoke は、注入 ASR で2区間を保存し、判定 coordinator の生成で初期化エラーを投げる。`LiveASRSession` と `LiveContentPrioritySession` の実装を通して、ASR 原文と通常表示を維持し、両区間の durable 保留理由と最後の状態表示に同じ失敗原因が残り、境界・優先度の判定呼出しが0であることを確認する。App の状態への反映は回帰テストで扱い、実 GUI の検証とは分ける。

### 録音しない受入と実画面での確認

授業など録音できない環境では、マイク・システム音声を開始せず、システム音量や出力装置にも触れない。既存ファイルのCLI処理とディスクだけの注入 smoke を行う。CLI の隔離 root で `--keep-session` の実処理を完了した後、JSON の `text` と参照先 ASR event の raw、`display_text`、`source`、`clause_state`、空 slice を照合する。判定を指定しない CLI run には segmentation / asr の2 active run があり、判定 request と decision run はなく、`text` と `display_text` は raw と一致する。終端行を含め F・B除去範囲の評価・除去は行わない。inspect → resume の再書き出しで event bytes と metadata が変わらないことも確認する。CLI の出力を F・B除去の証拠にはしない。

bundleは `scripts/run_app.sh` でbuildして起動する。プロセスの生存だけでは画面の合格にしない。GUI操作の権限がない場合は、設定・表示・exportボタンの確認を未観察として報告する。録音可能な時の手動受入では次を確認する。

- 「モデルを確認」で同梱モデルの ID と revision が表示されること、録音元・書き出し先、マイク／システム音声の実権限。
- 14秒超の実ASR原文をイベントで確認し、第一行の「発話文の続き待ち」、後続行の可視性、跨ぎpartsと確率を照合。
- PRIMARY＋LOWでLOW本文が消えること、全LOW行が消えること、LOW＋待機／保留の本文表示、選択copy/paste・accessibilityがLOWを除いた表示本文と一致すること、時刻ボタンのpopoverには clause-state の詳細だけが表示されること。
- 録音停止後のASR drain・finishInputとfinal takeover、late結果不採用、実live/final本文が完全一致する場合だけのcarryと判定削減。
- priority障害で保存済みboundaryを維持し、ローカル公開が続くこと。
- 設定の保留再試行ボタン、二種targetの判定、atomic metadata切替、診断のrequest・token・pending内訳。
- 保存済み録音の再選択とGUI「書き出す」の実txt再読込、`[mm:ss] text` 形式の行と改行処理、F・B除去後に本文が残る全行とLOWの保持、イベントraw不変。GUI exportにJSONは含まれない。

`MacAmbientJevEvaluateSession` と `MacAmbientJevEvaluateASR` は明示された artifact file を評価し、保存済み session を検索・作成しません。capture、file-processing、live-latency の CLI は明示的な root を要求し、保護された app data/cache root とその祖先・子孫、symlink alias を拒否します。

```bash
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateSession
swift build --package-path app/MacAmbientJev --product MacAmbientJevEvaluateASR
bash scripts/verify_portable.sh
```

`verify_portable.sh` は `scripts/check_portable_core.py` の default portable roots と test import check を使い、SwiftPM manifest を評価してから unfiltered build / test を実行します。検査対象 roots と禁止 import / platform guard の正本は [checker](../scripts/check_portable_core.py) です。これは import 境界の検査であり、Linux 上で macOS runtime が実行できることを意味しません。

## ファイル入力 CLI

`MacAmbientJevProcessRecording` は全 OS のファイル入力 CLI です。マイクや GUI を使わず、音声を import して VAD segmentation と ASR を行い、`--with-decisions` を指定した場合だけ clause-boundary / content-priority 判定も実行します。session の inspect / resume にも対応し、判定は既定で無効です。判定 provider は macOS で Core ML、Linux / Windows で ONNX を使います。

以下は **Mac の実行例**です。macOS は `--threads` を受け付けないため指定しません。Portable の正確な Linux / Windows コマンドと model 設定は [Linux の ProcessRecording 使用方法](linux.md#セッション全体のファイル処理-cli) と [Windows の ProcessRecording 使用方法](windows.md#セッション全体のファイル処理-cli) を参照してください。

```bash
# macOS: --threads は指定しない
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --sessions-root "$SESSIONS_ROOT" "$AUDIO_FILE" "$SEGMENTS_OUTPUT"
```

出力先を省略すると音声と同じディレクトリに `segments.json` を作ります。入力と出力が symlink 解決後に同一となる場合は拒否します。`--keep-session` を指定しない import の一時 session は成功・失敗のいずれでも処理後に削除し、調査・復旧のため保持する場合にだけ指定します。

```bash
# macOS: --threads は指定しない
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --sessions-root "$SESSIONS_ROOT" --keep-session --low-heat "$AUDIO_FILE" "$SEGMENTS_OUTPUT"
```

Portable の import / resume は `--threads N` が必須です（export-only resume を含む）。`N` は `1...min(4, logicalCPUCount)` で、ASR と tagger の ONNX session は N、VAD は常に1 thread です。Mac は `--threads` を拒否します。`--low-heat` は Portable では ASR 区間間の pacing のみを行い、thermal monitor / start gate / pause はありません。Mac では推論が必要な import / resume の開始時に nominal / fair を要求し、critical 時は処理を pause します。resource を作る Mac run の `--low-heat` は pacing に加えて MLX cache 上限を抑えます。measurement option と thermal / memory sampling は Mac 専用です。これらは短い fixture の成功から長時間のメモリ条件やライブ遅延を推定するものではありません。

`--with-decisions` の実行時に Mac は `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY` に実在する絶対 directory を要求し、その直下の ClauseTagger.mlpackage と tokenizer.json を Core ML provider が使います。Portable の処理資源解決には `MAC_AMBIENT_JEV_SILERO_MODEL`（既存 absolute file）、`QWEN3_ASR_ONNX_MODEL_DIRECTORY`（既存 absolute directory）、`QWEN3_ASR_ONNX_MODEL_SIZE`（`0.6b` または `1.7b`）が必要です。`--with-decisions` を指定する場合だけ、4つ目の `MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY`（既存 absolute directory）も必要です。設定に既定値や暗黙 download はありません。inspect と推論不要の export-only resume は model environment を読みません。decision-only retry は ASR / VAD 推論を再実行しませんが、Portable の処理資源解決時には基本3項目も必要です。

### inspect と resume

```bash
# macOS: --threads は指定しない
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --inspect-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT"

# macOS: --threads は指定しない
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --resume-session "$SESSION_ID" --sessions-root "$SESSIONS_ROOT" \
  --low-heat "$SEGMENTS_OUTPUT"
```

inspect は read-only で、session action と保存整理 `maintenance`（`compactRecording`、`removeTransients`、`null`）を JSON で返します。`--with-decisions` と `--threads` を含む処理 option、位置引数は受け付けません。action は `finalize`、未公開の判定 run がある場合の `recoverDecisionRun`、判定の保留だけがある場合の `retryContentPriority`、`none`、音声が復旧できない場合の `unrecoverable` です。ID は UUID、root は必須です。manifest の完全 ID から実 folder を特定し、不在・複数一致・名前の検証不整合は明示エラーになります。

resume は最初に output containment / session lookup の safety 検査と read-only inspection を行います。初回 inspection の action が推論を必要とする場合に限り、model configuration / resources を解決し、`--with-decisions` が有効なら decision provider preflight も session maintenance より前に行います。その後に必要な保存整理（FLAC 変換または一時音声削除）を行い、再走査した action で finalize または decision retry を dispatch します。`--with-decisions` なしの decision-only recovery は新たな判定を行わず公開済み local transcript を export します。要求された mode をすでに満たす session は model / environment を必要とせず、推論 event を追加しません（Portable の CLI 引数として `--threads` はなお必須です）。finalize は保存済み音声から全段階を再実行し、pending ASR だけを再投入する経路ではありません。

認識テキストがある `--with-decisions` export は、clause-boundary と content-priority の両 run が公開済みで、boundary / priority retry target および `pendingDecisionTargets` が空の場合に限り成功します。判定 request が失敗した場合は既存 session の公開済み local transcript と保留状態を維持し、export を作らず CLI は非0で終了します。import の決定 preflight が session 作成前に失敗した場合は local transcript を約束しません。処理開始後に失敗した一時 import session は `--keep-session` がなければ削除対象のままです。認識テキストがない場合は判定 run なしで空の `[]` を export できます。

成功 export は全 session から materialize した `MaterializedTranscriptSegment` 配列を pretty-printed / sorted-key JSON として出力し、segment schema を変えたり TranscribeFile / CER artifact の envelope に包んだりしません。失敗・pause は completed として扱いません。実モデルでの VAD 成功や実 end-to-end 処理を fake service tests で保証するものではありません。

### CLI の portable service tests

[SessionFileProcessingServiceTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/SessionFileProcessingServiceTests.swift) の9つの fake-service test functions は、注入 engine / provider と一時 session を使い、実モデルや実 CLI end-to-end を実行せず service の処理・export・cleanup を検証します。

- `importKeepsCanonicalSessionAndPublishesTranscriptWithoutStdoutDependency` は import original、segmentation / asr の2 run、materialized transcript と export の一致を確認します。
- `inspectReportsDecisionRetryWithExactJSONAndDoesNotTouchEventsOrCreateResources` は read-only inspection、exact JSON、event 不変、resource factory 未呼出しを確認します。
- `resumeOfDisabledOrSatisfiedTranscriptExportsWithoutResources` は判定無効または要求済み判定が完了済みの場合に resources を作らず、event を追加せず同じ配列を export することを確認します。
- `interruptedImportedFinalizationResumesFromRunningMetadata` は中断した finalization を再走査後に全量再実行し、complete metadata と export を確認します。
- `decisionOnlyResumeRetriesPublishedTargetsAndRecoversUnpublishedRuns` は公開済み retry target と未公開 decision run の双方を復旧し、ASR / VAD を再実行しないことを確認します。
- `failedDecisionRequestRejectsDecisionExportButKeepsPublishedLocalTranscript` は strict decision export failure、保持された local transcript / pending target、出力なしを確認します。
- `failedImportCleansTemporarySessionOnlyWhenNotRetained` は失敗時に `keepSession` がない一時 session を削除し、指定時は保持することを確認します。
- `invalidAliasesAndMissingAudioAreRejectedBeforeResourceCreation` は同一 path、missing audio、session 内 resume output を resources 作成前に拒否します。
- `noSpeechWithDecisionsExportsEmptyArrayWithoutDecisionRuns` は無発話の空配列 export と decision run 不要を確認します。

[ProcessRecordingArgumentsTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ProcessRecordingArgumentsTests.swift) は同じ CLI test target から `.macOS` / `.portable` policy を指定して parser を検査する9 test functions です。

- `macOSAcceptsCompleteMeasurementOptionsForImportAndResume` と `macOSRejectsThreads` は Mac の計測 option 全指定と `--threads` 拒否を確認します。
- `portableImportAndResumeRequireBoundedPositiveThreads` と `portableRejectsMeasurementOptionsWithoutFilesystemSideEffects` は import / resume の必須 thread 範囲と、measurement option の副作用前拒否を確認します。
- `inspectAcceptsWithoutProcessingOptionsAndRejectsDisallowedOptions` は両 policy で inspect の decision / thread / pacing / measurement / position option を拒否します。
- `decisionsAndImportFlagsArePreservedOnBothPlatforms` は両 policy で `--with-decisions`、`--keep-session`、`--low-heat` と resume の option parsing を確認します。
- `duplicateFlagsOptionsAndUnknownFlagsAreRejected`、`missingInvalidAndEmptyValuesAndPositionalsAreRejected`、`malformedOptionsCannotBeHealedByRemovingFlags` は重複・未知 option、値と位置引数の不備、flag 除去で malformed option が通らないことを検査します。

parser policy の simulation は portable runtime / CLI composition を macOS 上で compile したことを示すものではありません。

[ProcessRecordingSafetyTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ProcessRecordingSafetyTests.swift) の measurement destination / sampling failure cases と [ThermalLineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevProcessRecordingTests/ThermalLineTests.swift) は macOS 専用です。これらは RunMonitor の出力 alias、安全な書込み失敗、thermal JSONL を扱います。portable parser / fake service tests は測定済み run、実 model の end-to-end、または CI の実行内容変更を意味しません。

### 不正入力の smoke

`scripts/verify_cli_inputs.py` は build 済み CLI のパスを一つ受け取り、重複 flag、未知 option、inspect/resume の余分な位置引数、計測引数の欠落等の 10 ケースを実行します。不正入力の非 0 終了に加えて、出力・計測ファイル・セッションが作成されないことを確認します。さらに実 named folder で inspect の正常・不在・完全 UUID の重複・同じ先頭 8 桁の別 ID・名前/日時/suffix/stem の不整合を検証し、実セッション内（symlink・大文字小文字の違いを含む）への resume 出力を拒否して原ファイルが変わらないことを確認します。これは実モデルの正常推論とは別の safety smoke です。

## ポータブル full-model の受入

Linux / Windows の `MacAmbientJevProcessRecording` は、実モデルで音声ファイルから最終 transcript までを通す受入 driver [`process_recording_acceptance.py`](../tools/linux-audio/process_recording_acceptance.py) で検査します。入力は公開 fixture `qwen3_asr_voicevox_long.wav`（18.464 秒）だけで、参照文と WAV の SHA-256・sample 数は [windows.md](windows.md#日本語音声-fixture) の表から読みます。fixture が表と一致しなければ失敗します。

driver は release の CLI と `MacAmbientJevEvaluateASR` の絶対 path、fixture を引数で受け取り（既定値なし）、次を実行します。

1. 一時 sessions root へ `--keep-session --with-decisions --threads 2` で import する。
2. 全モデル環境変数を除いた環境で `--inspect-session` を実行する。
3. 完了済みセッションを `--resume-session --with-decisions --threads 2` で再開し、出力を import と比較する。

必須の環境変数は `MAC_AMBIENT_JEV_SILERO_MODEL`（ファイル）、`QWEN3_ASR_ONNX_MODEL_DIRECTORY`、`QWEN3_ASR_ONNX_MODEL_SIZE`（`0.6b` か `1.7b`）、`MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY`（decision model directory）です。未設定・空・相対 path・不正な path は失敗し、skip しません。各コマンドには timeout があり、import と resume は 300 秒です。

検査内容は次のとおりです。

- 全コマンドの終了コードが 0 で、import の stdout に `session_id:` 行がちょうど 1 つある。
- 出力 JSON は 2 件以上の segment を時系列・重なりなし・音声長以内で持ち、各 `text` は日本語を含む。`clause_state` は `classified` で、clause slice は priority を持ち再試行待ちがない。
- `text` を時刻順に連結した raw 文を `MacAmbientJevEvaluateASR` で参照文と比較し、単一 CER の `cer.rate` が 0.15 以下。
- セッション folder に `session.json`、末尾まで完結した `events.jsonl`、`processing_metadata.json`、`storage.json`（imported original と import 時のフレーム数）があり、`audio/original.*` が入力と byte 単位で同一である。audio directory 以下に `.caf` がなく、`recording.flac` と `.recording.flac.partial` もない。
- `active_runs` の segmentation・asr・clause_boundary・content_priority があり、それぞれ `processing.run.started` / `processing.run.completed`（成功、失敗数 0）が1組ずつある。segmentation provenance の engine は `onnxruntime-silero-vad`、ASR provenance の engine は `onnxruntime-qwen3-asr` で、ASR model は [qwen3_asr_models.json](../app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/qwen3_asr_models.json) の `repository@commit`、`intra_op_threads` は2です。decision run の engine は ONNX で、Core ML を名乗りません。境界・優先度の判定 event が active run にあり、保留中の判定対象がありません。
- 出力 segment と active ASR run の認識済み `asr.completed` event が segment ID と本文で一致する。
- inspect は `action` が `none`、`maintenance` が `null` で、resume は `events.jsonl` を変えず、出力が import と同一である。

driver 自身のテストは実モデルを使わず、偽の CLI と evaluator が作る session で、誤った transcript、欠けた stage / file、残った CAF、Core ML を名乗る decision engine、import と異なる resume 出力が失敗することを確認します。POSIX のみで実行します。

```bash
cd tools/linux-audio
uv run --python 3.12 --with pytest python -m pytest -q tests/test_process_recording_acceptance.py
```

### full-model モード

`bash scripts/verify_portable.sh --full-model` は Linux の opt-in 実行です。指定しない通常の Linux 検証は portable package build / test と self-tests で終わり、Python の ProcessRecording acceptance driver や engine process acceptance は実行しません。full-model は次を順に行います。

1. ONNX Runtime、Silero、Qwen3-ASR tokenizer、clause tagger、Qwen3-ASR 0.6B（int4、`.build/qwen3-asr-models`）を fetch し、PortableRuntime の実モデル検証に必要な環境変数を設定する。
2. `RUN_MODEL_TESTS=1` で3つの数値 suite（[SileroVADParityTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/SileroVADParityTests.swift)、Qwen3-ASR model / token-reference tests、[ONNXClauseTaggerTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/ONNXClauseTaggerTests.swift)）を1つずつ実行する。実行・skip した test 名を出力し、suite で test が1件も実行されなければ失敗とする。
3. `MacAmbientJevProcessRecording`、`MacAmbientJevEvaluateASR`、`MacAmbientJevEngineHarness` を release で build し、既存の `tools/linux-audio/process_recording_acceptance.py` を実行する。
4. 続けて `scripts/engine_acceptance.py full-model` を `--threads 2` で実行し、実モデルを使う canonical 16 kHz mono の fake-capture host scenario と ProcessRecording baseline / resume の一致を検証する。full-model acceptance の契約は [偽キャプチャ engine テストハーネス](windows.md#偽キャプチャ-engine-テストハーネス) を参照する。

fixture 入力の Qwen3-ASR は 0.6B で、full-model acceptance はこの固定 profile による処理経路を比較します。1.7B の CER は別の記録で扱います。

Windows の `./scripts/test-windows.ps1 -FullModel` は通常の build / test、driver self-tests、deterministic fake-capture acceptance の後に pinned model fetch と同じ3つの数値 suite を実行します。release の ProcessRecording / EvaluateASR / EngineHarness を build して ONNX Runtime DLL を配置し、既存 ProcessRecording acceptance driver の後に新しい `full-model` engine acceptance を実行します。Linux と異なり、Windows は canonical 16 kHz mono に加えて、fixture の各 PCM16 sample を3回繰り返して両 channel に置いた 48 kHz stereo scenario を実行します。Windows full-model run は手動 opt-in であり、通常の Windows CI は deterministic acceptance のみで、実モデル acceptance を主張しません。

### CI の `linux-model-e2e`

[portable-core.yml](../.github/workflows/portable-core.yml) の `linux-model-e2e` は `linux` と同じ trigger と draft の扱いで動く必須 job です（`swift:6.2-noble`、timeout 45 分）。まず ProcessRecording acceptance driver の self-test を実行し、続けて `verify_portable.sh --full-model` を実行します。この job は数値 suite と ProcessRecording acceptance に加え、EngineHost の fake-capture から実 PortableRuntime inference / decisions を通る canonical 16 kHz scenario を行います。モデル directory（`.build/qwen3-asr-models`、`.build/qwen3-asr-tokenizer`、`.build/silero-vad`、`.build/clause-tagger-onnx`）は OS・arch と各 manifest、fetcher、`pinned_download.py` の hash を key に GitHub Actions の cache action へ保存します。broad な restore key はありません。cache が hit しても fetcher が全ファイルの SHA-256 を再検証し、破損した cache は別モデルで代替せず失敗します。ONNX Runtime は毎回取得します。

## セッションの CER

`MacAmbientJevEvaluateSession` は portable で、二つの位置引数だけを受け取る。

```bash
swift run --package-path app/MacAmbientJev MacAmbientJevEvaluateSession \
  "$SESSION_MANIFEST" "$SEGMENTS_JSON"
```

結果は標準出力の JSON。manifest の形式は次のとおり。

```json
{
  "id": "japanese-speech",
  "audio": "audio.wav",
  "reference": { "text": "今日は音声認識の動作を確認します。" }
}
```

`reference` は `text` または `file` のどちらか一つ。file は UTF-8 で、相対パスなら manifest のディレクトリから解決する。inline/file とも EvaluateASR と同じ平坦な `(F x)` / `(D x)` mark を使い、無印が必須、mark 内が任意。括弧の不正や未知 tag は1始まりの Swift 文字位置付きで失敗する。audio は必須だが、この CLI は音声を読み込んだり認識したりしない。

入力する `segments.json` の各要素から `start_ms` と `text` を読む。保存順に本文を改行で連結して CER を求める。参照文は mark を parse 後に必須片・任意片ごとに正規化し、hypothesis は既存 normalizer の適用だけで変更する。分母は正規化後の必須参照文字数とする。レポートは `id` と `asr_evaluation` を持ち、その key は `cer` object と `normalizer_version` の2つだけ。CER object の項目定義は [Linux の CER 定義](linux.md#asr-実行と-cer)を参照する。

Linux runner の ASR artifact は `MacAmbientJevEvaluateASR` で評価します。参照・artifact の二位置引数と任意の末尾 `--output` を受け取ります。詳細は [linux.md](linux.md) を参照してください。

## macOS のファイル処理長時間計測

この長時間計測は macOS 専用です。`scripts/measure_v1_run.sh` は Mac release CLI の MLX memory / thermal sampling と `/usr/bin/time -l` を使い、音声 import または保存済み session の resume を一回計測します。Portable CLI は measurement options を拒否し、thermal / memory sampling を持ちません。事前に Mac release product を build し、必要空き容量は 4 GiB 以上です。

計測後は root 直下の manifest の完全 UUID を正規化して検索し、ちょうど一つの実フォルダーを解決します。ID 不在・複数一致・一致したフォルダーの名前/日時/suffix/source stem の不整合は明示エラーです。stem の Swift Character 境界での切り詰めを検査するため、実行する `python3` に `regex` package が必要です（`python3 -m pip install regex`）。日時は `created_at` から再計算しません。events、metadata、checkpoint、original は同じ解決済みフォルダーから読み、original が複数なら失敗します。import がセッション作成前に失敗して stdout に ID がない場合は、セッションの欠測理由を残します。ID がある場合は lookup の失敗を欠測扱いにしません。


```bash
# macOS measurement build; the CLI has no --threads option on Mac
swift build --package-path app/MacAmbientJev -c release \
  --product MacAmbientJevProcessRecording

# macOS only: uses Mac thermal / MLX metrics and /usr/bin/time -l
bash scripts/measure_v1_run.sh \
  --id lecture-ja \
  --audio "$AUDIO_FILE" \
  --sessions-root "$SESSIONS_ROOT" \
  --keep-session --low-heat \
  --output "$SEGMENTS_OUTPUT"
```

import と resume の両方で `--sessions-root` が必須です。import は `--audio` と `--keep-session` を指定し、resume は `--resume-session` を指定して `--audio` を省略します。

```bash
bash scripts/measure_v1_run.sh \
  --id lecture-ja \
  --resume-session "$SESSION_ID" \
  --sessions-root "$SESSIONS_ROOT" \
  --low-heat --output "$SEGMENTS_OUTPUT"
```

共通の必須引数は `--id` と `--output`。id は英数字・ハイフン・underscore のみ。run ID は id と UTC 時刻から作り、segments 出力先の親に run 用のディレクトリを作る。

保存物は `run.json`、`engine-metrics.json`、`thermal.jsonl`、`memory.jsonl`、stdout.log、stderr.log、source-snapshot.tar.gz、成功時の `segments.json`。入力・イベント・source snapshot・依存解決ファイル・差分の hash、実行コマンド、環境、終了コードを記録する。計測値はこの起動の範囲であり、過去の run の ASR 時間を引き継がない。

- `run.json` の対象キーは `recording_id`。`status` は `completed` / `failed` / `paused`。
- `asr_rtf` は ASR 呼び出し時間 ÷ 処理済み音声秒数。モデルロード、pacing 待機、処理全体の wall time を混ぜない。
- 欠落・破損した engine metrics、thermal/memory sample、run ID 不一致は失敗。欠測を 0 として補完しない。
- 読み取るイベントと processing metadata は `schema_version: 3` が必須。版が異なるか欠落している場合は計測を失敗とする。
- `memory.jsonl` は run ID、UTC 時刻、phase、`footprint_bytes`、MLX の active/cache/peak/cache-limit bytes。footprint 取得失敗は null と `footprint_error` の理由を持つ。sample 書き込み失敗も CLI の失敗になる。
- `thermal.jsonl` は run ID、UTC 時刻、state。サンプルは開始・終了・約 5 秒ごと、および phase 変更時に取る。critical は確定処理を一時停止する。
- マイクの dropout、発話文判定の件数（`decision_success_count` など）、クラッシュ復旧の音声喪失窓は、このオフライン計測では測れず null と理由を記録する。

メモリ判定は ASR phase の有効な phys_footprint サンプルを使う。最初と最後の重ならない各 5 分窓で 48 件以上、全体で少なくとも 96 件・600 秒の範囲が必要。最後の中央値 − 最初の中央値が 512 MiB 以下、かつ `/usr/bin/time -l` の peak memory footprint が 12 GiB 以下で正常終了なら `VERIFIED`。サンプル不足、peak 欠測、途中失敗等は `INCONCLUSIVE`、条件を評価できて閾値超過なら `FAILED`。max RSS と peak footprint は別に記録する。短時間 run の INCONCLUSIVE は精度や処理成功の判定とは別で、ライブ録音全体のメモリ合格を意味しない。

### macOS CLI に直接計測引数を渡す場合

Mac の import / resume には `--run-id`、`--metrics-output`、`--thermal-output`、`--memory-output` を四つすべて指定します。run ID は空でなく `/` を含まないもの。三つの計測出力先は互いに異なり、既存ファイルがないことが必要です。Portable CLI はこれらを filesystem side effect より前に拒否します。通常は上の Mac 専用 script を使います。

## 原速 replay のライブ遅延計測

```bash
bash scripts/measure_live_latency.sh "$AUDIO_FILE"
bash scripts/measure_live_latency.sh --sample-rate 48000 --channels 1 "$AUDIO_FILE"
```

`MacAmbientJevMeasureLiveLatency` は既存音声を原速で投入し、VAD 区間終了から最初の非空な RAW ASR 更新までを計測する。発話文判定は無効で、最初の `displayText` は未評価の ASR 原文。空白・改行だけの本文は除外するが、認識されたフィラーだけの非空 raw 行も最初の更新として数える。CLI は tagger を実行せず F・B除去範囲を適用しないため、これは F・B除去後の更新時間ではない。report に記録する本文も raw で、空白・句読点の変更や正規化を行わない。次区間待ちと境界・優先度判定の時間は測らない。投入は遅延計測と同じ時計の起点からの絶対予定で行い、各 0.5 秒の塊はその末尾の音声時刻まで待ってから durable append する。変換や append の処理時間は後続の塊へ累積しない。report の `replay_max_feed_lag_seconds` は、各 append の完了時刻から、それまでに投入した replay input の音声秒数を引いた値の最大値である。この値が大きい場合は投入が原速に追いついておらず、遅延値に投入の遅れが含まれる。replay の入力形式は既定でファイル形式、明示指定時はその device 相当形式に変換する。sample rate は 1000〜768000 Hz、channels は 1〜32。durable append 前に同じ ingress converter を通し、保存と VAD / ASR は常に 16 kHz mono。report の `source_*`、`replay_input_*` と `processing_*` は別形式を表し、frame 座標は保存 timeline を参照する。`--match-default-input` は既定入力 format を読むだけで capture を開始しないが、sample rate/channels の明示指定とは併用できない。

Qwen と VAD のキャッシュ済みモデルが必要。閉じた VAD 区間、または最長 14 秒分割が表示単位であり、長い発話は初表示まで待つ。測るのは非空更新までで、実画面描画、マイク入力の実時間、全発話の精度を保証する指標ではない。

### 保存整理のテスト

Runtime の [SessionStorageFinalizationTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevRuntimeTests/SessionStorageFinalizationTests.swift) は録音・import の finalization で success / no-speech / VAD failure / ASR failure / pause を検証します。成功した録音は FLAC 化して processing timeline を除去し、失敗・pause の録音は PCM と timeline を保持します。import は処理 timeline を除去します。開始失敗を含む一時 partial の cleanup、削除・compaction failure、再処理時の transcript / FLAC 保持も確認します。[FinalTranscriptPipelineTests.swift](../app/MacAmbientJev/Tests/MacAmbientJevPipelineTests/FinalTranscriptPipelineTests.swift) は VAD / ASR / pacing / compaction 中の cancellation が finalization を durable な pause にし、再開で完了することを検証します。AppleSupport の起動時整理テストは、全 session の整理が収束し、失敗した session を folder 名付きで返し、録音中の session に触れないことを確認します。App test は起動時整理中に `recordingPCM` の export を書き出し先に触れる前に止めます。

## ポータブル ONNX の書き出しと受入

[export_clause_tagger_onnx.py](../scripts/export_clause_tagger_onnx.py) の純粋な helper（引数・入力 path・出力先の検証、入出力契約、入力 ID、fixture document、license 文、state revision）は [test_export_clause_tagger_onnx.py](../scripts/test_export_clause_tagger_onnx.py) が torch なしで検証します。このテストは portable-core workflow の Linux と Windows で実行します。

```bash
python3 -B scripts/test_export_clause_tagger_onnx.py
```

実際の書き出しと受入は、モデルと checkpoint が必要なためリポジトリのルートで手動実行します。重い処理なので、他の重い job と同時に動かさないでください。出力先は存在しない新規ディレクトリで、親ディレクトリは先に作ります。`<models>` は modernbert-ja-30m と multi-30m-bc2 を置いたディレクトリの絶対パスに置き換えます。

```bash
mkdir -p .build/clause-tagger-onnx-export
uv run --project tools/clause-tagger-export python scripts/export_clause_tagger_onnx.py \
  --base-dir <models>/modernbert-ja-30m \
  --checkpoint <models>/multi-30m-bc2/multitagger.pt \
  --tokenizer <models>/modernbert-ja-30m/tokenizer.json \
  --fixture app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerFixtures.json \
  --output-dir .build/clause-tagger-onnx-export/clause-tagger-onnx
```

`--tokenizer` には SHA-256 `0a94ac9a...` の tokenizer.json を指定します。multi-30m-bc2 ディレクトリの tokenizer.json は再保存された別 bytes なので使えません。受入検査の内容は [判定](decision-engine.md) の「ポータブル ONNX の書き出し」に従い、失敗した検査と測定値を標準エラーに出して非 0 で終了します。成功時は stdout の最後の行に ClauseTagger.onnx の SHA-256・サイズと head ごとの最大誤差を JSON で出し、全長の誤差は export.json の `parity` に残ります。

## Linux Python の単体テストと suite

uv を使う場合は `tools/linux-audio` を作業ディレクトリにして実行する。

```bash
cd tools/linux-audio
uv run --python 3.12 --with pytest python -m pytest -q tests
```

suite はリポジトリルートで実行する。

```bash
bash scripts/verify_linux_audio.sh --smoke
```

Python unit test は artifact、baseline、CSJ parser、VOICEVOX CLI、ProcessRecording acceptance driver、suite runner を検証します。suite は portable Swift と依存の有無も確認します。full mode の入力と実モデル実行は [linux.md](linux.md) を参照してください。依存欠落や未実行を PASS と解釈しません。
