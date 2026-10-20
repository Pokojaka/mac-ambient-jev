$ErrorActionPreference = 'Stop'

function Invoke-Step([string]$Name, [scriptblock]$Command) {
    Write-Host "==> $Name"
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}

Invoke-Step 'portable Core/Pipeline checker self-test' { python -B scripts/test_portable_core.py }
Invoke-Step 'portable Core/Pipeline import check' { python -B scripts/check_portable_core.py }
Invoke-Step 'doc reference checker self-test' { python scripts/test_doc_references.py }
Invoke-Step 'doc reference check' { python scripts/check_doc_references.py }
Invoke-Step 'swift build Core, Pipeline and WindowsSupport' { swift build --package-path app/MacAmbientJev }
Invoke-Step 'swift test Core, Pipeline and WindowsSupport' { swift test --package-path app/MacAmbientJev }
