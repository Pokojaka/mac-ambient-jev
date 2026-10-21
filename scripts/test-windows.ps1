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

Invoke-Step 'portable Core/Pipeline checker self-test' { python -B scripts/test_portable_core.py }
Invoke-Step 'portable Core/Pipeline import check' { python -B scripts/check_portable_core.py }
Invoke-Step 'doc reference checker self-test' { python scripts/test_doc_references.py }
Invoke-Step 'doc reference check' { python scripts/check_doc_references.py }
Invoke-Step 'ONNX Runtime fetcher self-test' { python -B scripts/test_fetch_onnxruntime.py }
Invoke-Step 'Silero VAD fetcher self-test' { python -B scripts/test_fetch_silero_vad.py }
Invoke-Step 'Community-1 diarization fetcher self-test' { python -B scripts/test_fetch_community1_diarization.py }
Invoke-Step 'diarization run comparison self-test' { python -B scripts/test_compare_diarization_runs.py }
Invoke-Step 'canonical CAF converter self-test' { python -B scripts/test_prepare_canonical_caf.py }
Invoke-Step 'Qwen3-ASR tokenizer fetcher self-test' { python -B scripts/test_fetch_qwen3_asr_tokenizer.py }
Invoke-Step 'Qwen3-ASR model fetcher self-test' { python -B scripts/test_fetch_qwen3_asr_model.py }
Invoke-Step 'pinned download self-test' { python -B scripts/test_pinned_download.py }
Invoke-Step 'Silero reference generator self-test' { python -B scripts/test_generate_silero_reference.py }
Invoke-Step 'Qwen3-ASR token reference generator self-test' { python -B scripts/test_generate_qwen3_asr_token_reference.py }
Invoke-Step 'Swift build portable Core/Pipeline/ONNX targets' { swift build --package-path app/MacAmbientJev }

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

Invoke-Step 'Swift test portable Core/Pipeline/ONNX targets' { swift test --package-path app/MacAmbientJev }
