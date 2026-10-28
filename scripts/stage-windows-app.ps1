[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('x64', 'ARM64')]
    [string]$Architecture,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$previousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    Write-Host "==> Publish Windows shell for $Architecture"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-windows-shell.ps1') -Architecture $Architecture -Destination $Destination
    if ($LASTEXITCODE -ne 0) { throw "Windows shell build failed with exit code $LASTEXITCODE" }

    Write-Host "==> Stage Windows engine for $Architecture"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'stage-windows-engine.ps1') -Architecture $Architecture -Destination (Join-Path $Destination 'engine')
    if ($LASTEXITCODE -ne 0) { throw "Windows engine staging failed with exit code $LASTEXITCODE" }
} finally {
    $ErrorActionPreference = $previousPreference
}

Write-Host "Windows $Architecture application staged successfully: $Destination"
Write-Output $Destination
