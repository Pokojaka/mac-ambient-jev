# Installs the Windows build toolchain used by scripts/test-windows.ps1.
# Run once from an elevated PowerShell on an ARM64 Windows 11 machine.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell.'
}
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64') {
    throw "This script installs ARM64 toolchains; this machine is $env:PROCESSOR_ARCHITECTURE."
}

$downloads = Join-Path $env:TEMP 'mac-ambient-jev-setup'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null

function Install-Package([string]$Name, [string]$Url, [string[]]$Arguments) {
    $file = Join-Path $downloads ([IO.Path]::GetFileName($Url))
    Write-Host "==> downloading $Name"
    Invoke-WebRequest -Uri $Url -OutFile $file
    Write-Host "==> installing $Name"
    $process = Start-Process -FilePath $file -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) { throw "$Name installer failed with exit code $($process.ExitCode)" }
}

Install-Package 'Visual Studio 2022 Build Tools' 'https://aka.ms/vs/17/release/vs_BuildTools.exe' @(
    '--quiet', '--wait', '--norestart', '--nocache',
    '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
    '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100'
)
Install-Package 'Swift 6.2' 'https://download.swift.org/swift-6.2-release/windows10-arm64/swift-6.2-RELEASE/swift-6.2-RELEASE-windows10-arm64.exe' @(
    '/quiet', '/norestart'
)
Install-Package 'Python 3.12' 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-arm64.exe' @(
    '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0'
)

# The Core tests create symlinks; Developer Mode lets a standard user do that.
$unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
New-Item -Force -Path $unlock | Out-Null
Set-ItemProperty -Path $unlock -Name AllowDevelopmentWithoutDevLicense -Type DWord -Value 1

Write-Host '==> done. Sign out and back in (or restart sshd) so PATH changes reach new sessions.'
