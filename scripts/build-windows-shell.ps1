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

function Resolve-FullyQualifiedWindowsPath([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Name must be a nonempty absolute Windows path."
    }
    if ($Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))') {
        throw "$Name must be a fully qualified Windows path, not drive-relative or root-relative: $Path"
    }
    try {
        return [System.IO.Path]::GetFullPath($Path)
    } catch {
        throw "$Name is not a valid fully qualified Windows path: $Path. $($_.Exception.Message)"
    }
}

function Invoke-NativeCapture([string]$Name, [string]$Executable, [string[]]$ArgumentList, [Parameter(Mandatory = $true)][bool]$DisplayOutput) {
    Write-Host "==> $Name"
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 can promote native stderr to a terminating error under Stop.
        $ErrorActionPreference = 'Continue'
        $outputLines = @(& $Executable @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($DisplayOutput -or $exitCode -ne 0) {
        foreach ($line in $outputLines) {
            Write-Host $line
        }
    }
    if ($exitCode -ne 0) {
        throw "$Name failed with exit code $exitCode"
    }
    return [PSCustomObject]@{ Lines = [string[]]$outputLines }
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
Push-Location -LiteralPath $repositoryRoot
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This script must run on Windows.'
    }

    $destinationPath = Resolve-FullyQualifiedWindowsPath -Path $Destination -Name 'Destination'
    if (Test-Path -LiteralPath $destinationPath) {
        throw "Destination already exists; refusing to modify or overwrite it: $destinationPath"
    }
    $destinationParent = [System.IO.Path]::GetDirectoryName($destinationPath)
    if ([string]::IsNullOrEmpty($destinationParent) -or -not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        throw "Destination parent directory must already exist: $destinationParent"
    }

    $architectureDetailsByName = @{
        x64 = @{
            Platform = 'x64'
            RuntimeIdentifier = 'win-x64'
            PeMachine = 0x8664
        }
        ARM64 = @{
            Platform = 'ARM64'
            RuntimeIdentifier = 'win-arm64'
            PeMachine = 0xaa64
        }
    }
    $architectureDetails = $architectureDetailsByName[$Architecture]
    $platform = [string]$architectureDetails.Platform
    $runtimeIdentifier = [string]$architectureDetails.RuntimeIdentifier

    try {
        $dotnetCommand = Get-Command -Name 'dotnet' -CommandType Application -ErrorAction Stop
    } catch {
        throw "Required .NET SDK CLI 'dotnet' was not found on PATH: $($_.Exception.Message)"
    }
    $dotnetExecutable = [string]$dotnetCommand.Source
    if ([string]::IsNullOrWhiteSpace($dotnetExecutable) -or -not (Test-Path -LiteralPath $dotnetExecutable -PathType Leaf)) {
        throw "Resolved dotnet application does not exist: $dotnetExecutable"
    }

    $sdkVersionResult = Invoke-NativeCapture -Name 'Read .NET SDK version' -Executable $dotnetExecutable -ArgumentList @('--version') -DisplayOutput $true
    if ($sdkVersionResult.Lines.Count -ne 1) {
        throw "dotnet --version returned $($sdkVersionResult.Lines.Count) lines; expected exactly one."
    }
    $sdkVersion = ([string]$sdkVersionResult.Lines[0]).Trim()
    if ($sdkVersion -cne '10.0.402') {
        throw "The .NET SDK version must be exactly 10.0.402; found '$sdkVersion'."
    }
    Write-Host "Verified .NET SDK version: $sdkVersion"

    $projectDirectory = [System.IO.Path]::GetFullPath((Join-Path -Path $repositoryRoot -ChildPath 'app/Windows/src/MacAmbientJev.WinUI'))
    $projectPath = [System.IO.Path]::GetFullPath((Join-Path -Path $projectDirectory -ChildPath 'MacAmbientJev.WinUI.csproj'))
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
        throw "WinUI project file is missing: $projectPath"
    }

    $projectPathProperties = @(
        "-p:Platform=$platform",
        "-p:WindowsShellRuntimeIdentifier=$runtimeIdentifier"
    )

    $restoreArguments = @(
        'restore',
        $projectPath,
        '--locked-mode'
    ) + $projectPathProperties
    Invoke-NativeCapture -Name "Restore WinUI shell for $platform ($runtimeIdentifier)" -Executable $dotnetExecutable -ArgumentList $restoreArguments -DisplayOutput $true | Out-Null

    if (Test-Path -LiteralPath $destinationPath) {
        throw "Destination appeared before publish; refusing to modify or overwrite it: $destinationPath"
    }
    $publishArguments = @(
        'publish',
        $projectPath,
        '-c', 'Release',
        '--no-restore',
        '--output', $destinationPath
    ) + $projectPathProperties
    Invoke-NativeCapture -Name "Publish WinUI shell for $platform ($runtimeIdentifier)" -Executable $dotnetExecutable -ArgumentList $publishArguments -DisplayOutput $true | Out-Null

    $executablePath = Join-Path -Path $destinationPath -ChildPath 'MacAmbientJev.exe'
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        throw "Published WinUI executable is missing: $executablePath"
    }
    $peBytes = [System.IO.File]::ReadAllBytes($executablePath)
    if ($peBytes.Length -lt 64) {
        throw "Invalid or truncated PE file (DOS header is incomplete): $executablePath"
    }
    if ($peBytes[0] -ne 0x4d -or $peBytes[1] -ne 0x5a) {
        throw "Invalid PE file (missing MZ signature): $executablePath"
    }
    $peOffset = [System.BitConverter]::ToInt32($peBytes, 0x3c)
    if ($peOffset -lt 0 -or $peOffset -gt ($peBytes.Length - 6)) {
        throw "Invalid or truncated PE file (e_lfanew is outside the file): $executablePath"
    }
    if ([System.BitConverter]::ToUInt32($peBytes, $peOffset) -ne 0x00004550) {
        throw "Invalid PE file (missing PE signature): $executablePath"
    }
    $machine = [System.BitConverter]::ToUInt16($peBytes, $peOffset + 4)
    if ($machine -ne $architectureDetails.PeMachine) {
        throw ('Published PE machine mismatch (found 0x{0:x4}, expected 0x{1:x4}): {2}' -f $machine, $architectureDetails.PeMachine, $executablePath)
    }

    Write-Host ('Verified Windows shell architecture: {0} (PE machine 0x{1:x4})' -f $platform, $machine)
    Write-Host "Windows $platform shell published and verified: $destinationPath"
    Write-Output $destinationPath
} finally {
    Pop-Location
}
