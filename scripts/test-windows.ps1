param([switch]$FullModel)

$ErrorActionPreference = 'Stop'
$env:PYTHONIOENCODING = 'utf-8'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Invoke-Step([string]$Name, [scriptblock]$Command) {
    Write-Host "==> $Name"
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}

Write-Host '==> fetch ONNX Runtime'
$runtimeRootLines = @(& python scripts/fetch_onnxruntime.py)
$runtimeRootExitCode = $LASTEXITCODE
if ($runtimeRootExitCode -ne 0) { throw "ONNX Runtime fetch failed with exit code $runtimeRootExitCode" }
if ($runtimeRootLines.Count -ne 1) { throw "ONNX Runtime fetch returned $($runtimeRootLines.Count) paths; expected exactly one" }
$runtimeRoot = ([string]$runtimeRootLines[0]).Trim()
if ([string]::IsNullOrWhiteSpace($runtimeRoot)) { throw 'ONNX Runtime fetch returned an empty path' }
$runtimeRoot = [System.IO.Path]::GetFullPath($runtimeRoot)
if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) { throw "ONNX Runtime root directory does not exist: $runtimeRoot" }

Write-Host '==> fetch Silero VAD model'
$sileroModelPathLines = @(& python scripts/fetch_silero_vad.py)
$sileroModelPathExitCode = $LASTEXITCODE
if ($sileroModelPathExitCode -ne 0) { throw "Silero VAD model fetch failed with exit code $sileroModelPathExitCode" }
if ($sileroModelPathLines.Count -ne 1) { throw "Silero VAD model fetch returned $($sileroModelPathLines.Count) paths; expected exactly one" }
$env:MAC_AMBIENT_JEV_SILERO_MODEL = [string]$sileroModelPathLines[0]

Write-Host '==> fetch Qwen3-ASR tokenizer'
$qwen3TokenizerPathLines = @(& python scripts/fetch_qwen3_asr_tokenizer.py)
$qwen3TokenizerExitCode = $LASTEXITCODE
if ($qwen3TokenizerExitCode -ne 0) { throw "Qwen3-ASR tokenizer fetch failed with exit code $qwen3TokenizerExitCode" }
if ($qwen3TokenizerPathLines.Count -ne 1) { throw "Qwen3-ASR tokenizer fetch returned $($qwen3TokenizerPathLines.Count) paths; expected exactly one" }
$env:MAC_AMBIENT_JEV_QWEN3_TOKENIZER = [string]$qwen3TokenizerPathLines[0]

Write-Host '==> fetch clause tagger model'
$clauseTaggerPathLines = @(& python scripts/fetch_clause_tagger.py)
$clauseTaggerExitCode = $LASTEXITCODE
if ($clauseTaggerExitCode -ne 0) { throw "Clause tagger model fetch failed with exit code $clauseTaggerExitCode" }
if ($clauseTaggerPathLines.Count -ne 1) { throw "Clause tagger model fetch returned $($clauseTaggerPathLines.Count) paths; expected exactly one" }
$env:MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY = [string]$clauseTaggerPathLines[0]

Invoke-Step 'portable Core/Pipeline checker self-test' { python -B scripts/test_portable_core.py }
Invoke-Step 'portable Core/Pipeline import check' { python -B scripts/check_portable_core.py }
Invoke-Step 'doc reference checker self-test' { python scripts/test_doc_references.py }
Invoke-Step 'doc reference check' { python scripts/check_doc_references.py }
Invoke-Step 'ONNX Runtime fetcher self-test' { python -B scripts/test_fetch_onnxruntime.py }
Invoke-Step 'Silero VAD fetcher self-test' { python -B scripts/test_fetch_silero_vad.py }
Invoke-Step 'Community-1 diarization fetcher self-test' { python -B scripts/test_fetch_community1_diarization.py }
Invoke-Step 'clause tagger fetcher self-test' { python -B scripts/test_fetch_clause_tagger.py }
Invoke-Step 'diarization run comparison self-test' { python -B scripts/test_compare_diarization_runs.py }
Invoke-Step 'canonical CAF converter self-test' { python -B scripts/test_prepare_canonical_caf.py }
Invoke-Step 'Qwen3-ASR tokenizer fetcher self-test' { python -B scripts/test_fetch_qwen3_asr_tokenizer.py }
Invoke-Step 'Qwen3-ASR model fetcher self-test' { python -B scripts/test_fetch_qwen3_asr_model.py }
Invoke-Step 'pinned download self-test' { python -B scripts/test_pinned_download.py }
Invoke-Step 'Silero reference generator self-test' { python -B scripts/test_generate_silero_reference.py }
Invoke-Step 'Qwen3-ASR token reference generator self-test' { python -B scripts/test_generate_qwen3_asr_token_reference.py }
Invoke-Step 'Swift build EngineProtocol/EngineHost/WindowsSupport/PortableRuntime/Core/Pipeline/ONNX targets' { swift build --package-path app/MacAmbientJev }
Invoke-Step 'Swift build Windows MacAmbientJevEngine executable' { swift build --package-path app/MacAmbientJev --product MacAmbientJevEngine }

Write-Host '==> resolve Swift debug bin path'
$binPathLines = @(& swift build --package-path app/MacAmbientJev --show-bin-path)
$binPathExitCode = $LASTEXITCODE
if ($binPathExitCode -ne 0) { throw "Swift debug bin path lookup failed with exit code $binPathExitCode" }
if ($binPathLines.Count -ne 1) { throw "Swift debug bin path lookup returned $($binPathLines.Count) paths; expected exactly one" }
$binDir = ([string]$binPathLines[0]).Trim()
if ([string]::IsNullOrWhiteSpace($binDir)) { throw 'Swift debug bin path lookup returned an empty path' }
if (-not (Test-Path -LiteralPath $binDir -PathType Container)) { throw "Swift debug bin directory does not exist: $binDir" }
$binDir = [System.IO.Path]::GetFullPath($binDir)

Write-Host '==> locate ONNX Runtime DLL for Swift target'
$runtimeDll = [System.IO.Path]::Combine($runtimeRoot, 'lib', 'onnxruntime.dll')
if (-not (Test-Path -LiteralPath $runtimeDll -PathType Leaf)) { throw "ONNX Runtime DLL is missing: $runtimeDll" }
$destinationDll = Join-Path $binDir 'onnxruntime.dll'
Copy-Item -LiteralPath $runtimeDll -Destination $destinationDll -Force -ErrorAction Stop
if (-not (Test-Path -LiteralPath $destinationDll -PathType Leaf)) { throw "ONNX Runtime DLL was not copied to the Swift debug bin directory: $destinationDll" }

$swiftExecutable = (Get-Command swift -CommandType Application -ErrorAction Stop).Source
$swiftToolchainDirectory = Split-Path -Parent $swiftExecutable
$clangPath = Join-Path $swiftToolchainDirectory 'clang.exe'
if (-not (Test-Path -LiteralPath $clangPath -PathType Leaf)) { throw "Swift toolchain clang.exe is missing at the expected path: $clangPath" }
$injectedTestSource = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) 'app/MacAmbientJev/Tests/CMiniaudioInjected/WindowsCaptureSafetyInjectedTests.c'))
$injectedTestExecutable = Join-Path $binDir 'WindowsCaptureSafetyInjectedTests.exe'
Invoke-Step 'Compile Windows capture safety injected C tests' { & $clangPath $injectedTestSource -o $injectedTestExecutable -lole32 }
if (-not (Test-Path -LiteralPath $injectedTestExecutable -PathType Leaf)) { throw "Windows capture safety injected test executable was not produced: $injectedTestExecutable" }
Invoke-Step 'Run Windows capture safety injected C tests' { & $injectedTestExecutable }

Invoke-Step 'Swift test EngineProtocol/EngineHost/WindowsSupport/PortableRuntime/Core/Pipeline/ONNX targets' { swift test --package-path app/MacAmbientJev }

Invoke-Step 'engine acceptance driver self-test' { python -B scripts/test_engine_acceptance.py }
Invoke-Step 'engine acceptance FLAC validator self-test' { python -B scripts/test_engine_acceptance_flac.py }
Invoke-Step 'deterministic engine acceptance' { python -B scripts/engine_acceptance.py deterministic --executable (Join-Path $binDir 'MacAmbientJevEngineHarness.exe') }

if ($FullModel) {
    function Get-SinglePath([string]$Name, [object[]]$Lines) {
        if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
        if ($Lines.Count -ne 1) { throw "$Name returned $($Lines.Count) paths; expected exactly one" }
        $path = ([string]$Lines[0]).Trim()
        if ([string]::IsNullOrWhiteSpace($path)) { throw "$Name returned an empty path" }
        return $path
    }

    # Runs one gated numerical suite with RUN_MODEL_TESTS=1, prints the executed and skipped test
    # names, and fails when the suite executed no test. Windows PowerShell 5.1 turns native stderr
    # into terminating errors under 'Stop', so the preference is relaxed around the native call.
    function Invoke-ModelSuite([string]$Name, [string]$Filter) {
        Write-Host "==> model suite: $Name (filter: $Filter)"
        $env:RUN_MODEL_TESTS = '1'
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $lines = @(& swift test --package-path app/MacAmbientJev --filter $Filter 2>&1 | ForEach-Object { "$_" })
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
            Remove-Item Env:RUN_MODEL_TESTS
        }
        $lines | ForEach-Object { Write-Host $_ }
        if ($exitCode -ne 0) { throw "model suite $Name failed with exit code $exitCode" }
        $executed = @($lines | Where-Object { $_ -match 'Test .* passed after' -and $_ -notmatch 'Test run' })
        if ($executed.Count -eq 0) { throw "model suite $Name executed no test" }
        Write-Host "executed tests in $Name ($($executed.Count)):"
        $executed | ForEach-Object { Write-Host $_ }
        $skipped = @($lines | Where-Object { $_ -match 'Test .* skipped' })
        Write-Host "skipped tests in ${Name}:"
        if ($skipped.Count -eq 0) { Write-Host '(none)' } else { $skipped | ForEach-Object { Write-Host $_ } }
    }

    $modelsDirectory = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) '.build\qwen3-asr-models'))
    New-Item -ItemType Directory -Force -Path $modelsDirectory | Out-Null
    Write-Host '==> fetch Qwen3-ASR 0.6B model'
    $qwen3Lines = @(& python scripts/fetch_qwen3_asr_model.py 0.6b $modelsDirectory)
    $env:QWEN3_ASR_ONNX_MODEL_DIRECTORY = Get-SinglePath 'Qwen3-ASR model fetch' $qwen3Lines
    $env:QWEN3_ASR_ONNX_MODEL_SIZE = '0.6b'

    Write-Host '==> fetch Community-1 diarization model'
    $diarizationLines = @(& python scripts/fetch_community1_diarization.py)
    $env:MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY = Get-SinglePath 'Community-1 diarization fetch' $diarizationLines

    Invoke-ModelSuite 'Silero VAD' 'SileroVADParityTests'
    Invoke-ModelSuite 'Qwen3-ASR' 'ONNXQwen3ASRModelTests|Qwen3ASRTokenReferenceTests'
    Invoke-ModelSuite 'Community-1 diarization' 'Community1ONNXStageTests|Community1ONNXEndToEndTests'
    Invoke-ModelSuite 'clause tagger' 'ONNXClauseTaggerTests'

    Invoke-Step 'Swift build release ProcessRecording' { swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevProcessRecording }
    Invoke-Step 'Swift build release EvaluateASR' { swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevEvaluateASR }
    Invoke-Step 'Swift build release EngineHarness' { swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevEngineHarness }
    $releaseBinLines = @(& swift build --package-path app/MacAmbientJev -c release --show-bin-path)
    $releaseBinDir = [System.IO.Path]::GetFullPath((Get-SinglePath 'Swift release bin path lookup' $releaseBinLines))
    if (-not (Test-Path -LiteralPath $releaseBinDir -PathType Container)) { throw "Swift release bin directory does not exist: $releaseBinDir" }
    $releaseDll = Join-Path $releaseBinDir 'onnxruntime.dll'
    Copy-Item -LiteralPath $runtimeDll -Destination $releaseDll -Force -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $releaseDll -PathType Leaf)) { throw "ONNX Runtime DLL was not copied beside the release CLI: $releaseDll" }

    $fixture = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) 'app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox_long.wav'))
    Invoke-Step 'process recording acceptance driver' {
        python tools/linux-audio/process_recording_acceptance.py `
            --executable (Join-Path $releaseBinDir 'MacAmbientJevProcessRecording.exe') `
            --evaluator (Join-Path $releaseBinDir 'MacAmbientJevEvaluateASR.exe') `
            --fixture $fixture
    }
    Invoke-Step 'full-model engine acceptance' {
        python -B scripts/engine_acceptance.py full-model `
            --executable (Join-Path $releaseBinDir 'MacAmbientJevEngineHarness.exe') `
            --process-recording (Join-Path $releaseBinDir 'MacAmbientJevProcessRecording.exe') `
            --fixture $fixture `
            --threads 2
    }
    Write-Host 'Windows full-model verification passed'
}
