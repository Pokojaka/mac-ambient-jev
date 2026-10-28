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

    $nativeArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Process')
    if ($Architecture -ieq 'x64' -and $nativeArchitecture -cne 'AMD64') {
        throw "Architecture x64 requires a native Windows AMD64 process (PROCESSOR_ARCHITECTURE must be AMD64; found '$nativeArchitecture')."
    }
    if ($Architecture -ieq 'ARM64' -and $nativeArchitecture -cne 'ARM64') {
        throw "Architecture ARM64 requires a native Windows ARM64 process (PROCESSOR_ARCHITECTURE must be ARM64; found '$nativeArchitecture')."
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
            TargetArch = 'x86_64'
            Triple = 'x86_64-unknown-windows-msvc'
            PeMachine = 0x8664
            OnnxArchitecture = 'x64'
            OnnxSha256 = '3958d8a44984160692c1b4ffd0de3cb48f8c39f9d34bb31e433db06e30b82195'
        }
        ARM64 = @{
            TargetArch = 'aarch64'
            Triple = 'aarch64-unknown-windows-msvc'
            PeMachine = 0xaa64
            OnnxArchitecture = 'arm64'
            OnnxSha256 = 'ef6206fa8d6975878d93a97035d280240ce5764c126a7430e5427e18923316d5'
        }
    }
    $architectureDetails = $architectureDetailsByName[$Architecture]

    $swiftCommand = Get-Command -Name 'swift' -CommandType Application -ErrorAction Stop
    $swiftExecutable = $swiftCommand.Source
    if (-not (Test-Path -LiteralPath $swiftExecutable -PathType Leaf)) {
        throw "Resolved Swift executable does not exist: $swiftExecutable"
    }
    $swiftToolchainDirectory = Split-Path -Parent $swiftExecutable
    $llvmReadobj = Join-Path -Path $swiftToolchainDirectory -ChildPath 'llvm-readobj.exe'
    if (-not (Test-Path -LiteralPath $llvmReadobj -PathType Leaf)) {
        throw "llvm-readobj.exe is missing beside swift.exe: $llvmReadobj"
    }

    $targetInfoResult = Invoke-NativeCapture -Name 'Swift target information' -Executable $swiftExecutable -ArgumentList @('-print-target-info') -DisplayOutput $true
    if ($targetInfoResult.Lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]::Join([Environment]::NewLine, $targetInfoResult.Lines))) {
        throw 'swift -print-target-info returned empty JSON.'
    }
    try {
        $targetInfo = [string]::Join([Environment]::NewLine, $targetInfoResult.Lines) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "swift -print-target-info did not return valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $targetInfo.PSObject.Properties['compilerVersion']) {
        throw 'Swift target information is missing compilerVersion.'
    }
    $compilerVersion = [string]$targetInfo.compilerVersion
    if ($compilerVersion -cne 'Swift version 6.2 (swift-6.2-RELEASE)') {
        throw "Swift compiler version must be exactly the Swift 6.2 release; found '$compilerVersion'."
    }
    if ($null -eq $targetInfo.PSObject.Properties['target'] -or $null -eq $targetInfo.target) {
        throw 'Swift target information is missing target.'
    }
    if ($null -eq $targetInfo.target.PSObject.Properties['arch'] -or $null -eq $targetInfo.target.PSObject.Properties['triple']) {
        throw 'Swift target information is missing target.arch or target.triple.'
    }
    if ([string]$targetInfo.target.arch -cne $architectureDetails.TargetArch) {
        throw "Swift target architecture mismatch: expected $($architectureDetails.TargetArch), found '$($targetInfo.target.arch)'."
    }
    if ([string]$targetInfo.target.triple -cne $architectureDetails.Triple) {
        throw "Swift target triple mismatch: expected $($architectureDetails.Triple), found '$($targetInfo.target.triple)'."
    }
    if ($null -eq $targetInfo.PSObject.Properties['paths'] -or $null -eq $targetInfo.paths) {
        throw 'Swift target information is missing paths.'
    }
    if ($null -eq $targetInfo.paths.PSObject.Properties['runtimeLibraryPaths']) {
        throw 'Swift target information is missing paths.runtimeLibraryPaths.'
    }
    $configuredRuntimePaths = @($targetInfo.paths.runtimeLibraryPaths)
    if ($configuredRuntimePaths.Count -eq 0) {
        throw 'Swift target information has no configured runtimeLibraryPaths.'
    }

    $swiftRuntimeDirectories = @()
    foreach ($configuredPath in $configuredRuntimePaths) {
        $runtimeCandidate = Resolve-FullyQualifiedWindowsPath -Path ([string]$configuredPath) -Name 'Swift runtimeLibraryPaths entry'
        if ((Test-Path -LiteralPath $runtimeCandidate -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path -Path $runtimeCandidate -ChildPath 'swiftCore.dll') -PathType Leaf)) {
            $swiftRuntimeDirectories += $runtimeCandidate
        }
    }
    if ($swiftRuntimeDirectories.Count -ne 1) {
        throw "Swift runtimeLibraryPaths must identify exactly one directory containing swiftCore.dll; found $($swiftRuntimeDirectories.Count)."
    }
    $swiftRuntimeDirectory = $swiftRuntimeDirectories[0]
    if (-not (Test-Path -LiteralPath $swiftRuntimeDirectory -PathType Container)) {
        throw "Swift runtime directory does not exist: $swiftRuntimeDirectory"
    }
    Write-Host "Swift target: $($targetInfo.target.triple) ($($targetInfo.target.arch)); compiler: $compilerVersion"
    Write-Host "Swift runtime directory: $swiftRuntimeDirectory"

    $onnxCache = Join-Path -Path $repositoryRoot -ChildPath ".build\onnxruntime\1.31.0"
    $expectedOnnxRoot = Join-Path -Path $onnxCache -ChildPath "onnxruntime-win-$($architectureDetails.OnnxArchitecture)-1.31.0"
    $fetchResult = Invoke-NativeCapture -Name 'Fetch pinned ONNX Runtime 1.31.0' -Executable 'python' -ArgumentList @('scripts/fetch_onnxruntime.py') -DisplayOutput $true
    if ($fetchResult.Lines.Count -ne 1) {
        throw "ONNX Runtime fetch returned $($fetchResult.Lines.Count) paths; expected exactly one."
    }
    $fetchedOnnxRootText = ([string]$fetchResult.Lines[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($fetchedOnnxRootText)) {
        throw 'ONNX Runtime fetch returned an empty path.'
    }
    $fetchedOnnxRoot = Resolve-FullyQualifiedWindowsPath -Path $fetchedOnnxRootText -Name 'ONNX Runtime fetch result'
    if (-not (Test-Path -LiteralPath $fetchedOnnxRoot -PathType Container)) {
        throw "ONNX Runtime fetch directory does not exist: $fetchedOnnxRoot"
    }
    $expectedOnnxRoot = [System.IO.Path]::GetFullPath($expectedOnnxRoot)
    if (-not ([System.StringComparer]::OrdinalIgnoreCase).Equals($fetchedOnnxRoot, $expectedOnnxRoot)) {
        throw "ONNX Runtime fetch returned an unexpected directory. Expected '$expectedOnnxRoot', found '$fetchedOnnxRoot'."
    }

    $buildResult = Invoke-NativeCapture -Name 'Build release MacAmbientJevEngine' -Executable $swiftExecutable -ArgumentList @(
        'build', '--package-path', 'app/MacAmbientJev', '-c', 'release', '--product', 'MacAmbientJevEngine'
    ) -DisplayOutput $true
    $releaseBinResult = Invoke-NativeCapture -Name 'Resolve Swift release bin directory' -Executable $swiftExecutable -ArgumentList @(
        'build', '--package-path', 'app/MacAmbientJev', '-c', 'release', '--show-bin-path'
    ) -DisplayOutput $true
    if ($releaseBinResult.Lines.Count -ne 1) {
        throw "Swift release bin path lookup returned $($releaseBinResult.Lines.Count) paths; expected exactly one."
    }
    $releaseBinText = ([string]$releaseBinResult.Lines[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($releaseBinText)) {
        throw 'Swift release bin path lookup returned an empty path.'
    }
    $releaseBinDirectory = Resolve-FullyQualifiedWindowsPath -Path $releaseBinText -Name 'Swift release bin directory'
    if (-not (Test-Path -LiteralPath $releaseBinDirectory -PathType Container)) {
        throw "Swift release bin directory does not exist: $releaseBinDirectory"
    }

    $runtimeDllNames = @(
        'BlocksRuntime.dll',
        'dispatch.dll',
        'Foundation.dll',
        'FoundationEssentials.dll',
        'FoundationInternationalization.dll',
        '_FoundationICU.dll',
        'swiftCore.dll',
        'swiftCRT.dll',
        'swiftDispatch.dll',
        'swiftWinSDK.dll',
        'swift_Concurrency.dll',
        'swift_RegexParser.dll',
        'swift_StringProcessing.dll',
        'msvcp140.dll',
        'msvcp140_1.dll',
        'vcruntime140.dll'
    )
    if ($Architecture -ieq 'x64') {
        $runtimeDllNames += 'vcruntime140_1.dll'
    }

    $engineSource = Join-Path -Path $releaseBinDirectory -ChildPath 'MacAmbientJevEngine.exe'
    if (-not (Test-Path -LiteralPath $engineSource -PathType Leaf)) {
        throw "Release engine executable is missing: $engineSource"
    }
    foreach ($dllName in $runtimeDllNames) {
        $runtimeSource = Join-Path -Path $swiftRuntimeDirectory -ChildPath $dllName
        if (-not (Test-Path -LiteralPath $runtimeSource -PathType Leaf)) {
            throw "Required Swift/MSVC runtime DLL is missing from the configured Swift runtime directory: $runtimeSource"
        }
    }

    $resourcePaths = @(
        'MacAmbientJev_MacAmbientJevPortableRuntime.resources/Resources/clause_tagger_model.json',
        'MacAmbientJev_MacAmbientJevPortableRuntime.resources/Resources/qwen3_asr_models.json',
        'MacAmbientJev_MacAmbientJevDiarization.resources/Resources/community1_diarization_models.json'
    )
    foreach ($resourcePath in $resourcePaths) {
        $resourceSource = Join-Path -Path $releaseBinDirectory -ChildPath $resourcePath
        if (-not (Test-Path -LiteralPath $resourceSource -PathType Leaf)) {
            throw "Required SwiftPM resource manifest is missing from the release bin directory: $resourceSource"
        }
    }

    $onnxArchiveName = "onnxruntime-win-$($architectureDetails.OnnxArchitecture)-1.31.0.zip"
    $onnxArchive = Join-Path -Path $onnxCache -ChildPath $onnxArchiveName
    if (-not (Test-Path -LiteralPath $onnxArchive -PathType Leaf)) {
        throw "Pinned ONNX Runtime archive is missing; refusing to use another DLL source: $onnxArchive"
    }
    $actualOnnxSha256 = (Get-FileHash -LiteralPath $onnxArchive -Algorithm SHA256).Hash
    if ($actualOnnxSha256 -ine $architectureDetails.OnnxSha256) {
        throw "ONNX Runtime archive SHA256 mismatch. Expected $($architectureDetails.OnnxSha256), got ${actualOnnxSha256}: $onnxArchive"
    }
    Write-Host "Verified ONNX Runtime archive SHA256: $actualOnnxSha256"

    if (Test-Path -LiteralPath $destinationPath) {
        throw "Destination appeared before staging; refusing to modify or overwrite it: $destinationPath"
    }
    [System.IO.Directory]::CreateDirectory($destinationPath) | Out-Null
    Write-Host "Created engine stage directory: $destinationPath"

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archiveHandle = [System.IO.Compression.ZipFile]::OpenRead($onnxArchive)
    try {
        $onnxEntryName = "onnxruntime-win-$($architectureDetails.OnnxArchitecture)-1.31.0/lib/onnxruntime.dll"
        $onnxEntry = $archiveHandle.GetEntry($onnxEntryName)
        if ($null -eq $onnxEntry) {
            throw "Pinned ONNX Runtime archive is missing the required entry: $onnxEntryName"
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($onnxEntry, (Join-Path -Path $destinationPath -ChildPath 'onnxruntime.dll'))
    } finally {
        $archiveHandle.Dispose()
    }

    Copy-Item -LiteralPath $engineSource -Destination (Join-Path -Path $destinationPath -ChildPath 'MacAmbientJevEngine.exe') -ErrorAction Stop
    foreach ($dllName in $runtimeDllNames) {
        $runtimeSource = Join-Path -Path $swiftRuntimeDirectory -ChildPath $dllName
        Copy-Item -LiteralPath $runtimeSource -Destination (Join-Path -Path $destinationPath -ChildPath $dllName) -ErrorAction Stop
    }
    foreach ($resourcePath in $resourcePaths) {
        $resourceSource = Join-Path -Path $releaseBinDirectory -ChildPath $resourcePath
        $resourceDestination = Join-Path -Path $destinationPath -ChildPath $resourcePath
        $resourceParent = Split-Path -Parent $resourceDestination
        [System.IO.Directory]::CreateDirectory($resourceParent) | Out-Null
        Copy-Item -LiteralPath $resourceSource -Destination $resourceDestination -ErrorAction Stop
    }

    $peFileNames = @('MacAmbientJevEngine.exe') + $runtimeDllNames + @('onnxruntime.dll')
    foreach ($peFileName in $peFileNames) {
        $pePath = Join-Path -Path $destinationPath -ChildPath $peFileName
        if (-not (Test-Path -LiteralPath $pePath -PathType Leaf)) {
            throw "Staged PE file is missing: $pePath"
        }
        $peBytes = [System.IO.File]::ReadAllBytes($pePath)
        if ($peBytes.Length -lt 64) {
            throw "Invalid or truncated PE file (DOS header is incomplete): $pePath"
        }
        if ($peBytes[0] -ne 0x4d -or $peBytes[1] -ne 0x5a) {
            throw "Invalid PE file (missing MZ signature): $pePath"
        }
        $peOffset = [System.BitConverter]::ToInt32($peBytes, 0x3c)
        if ($peOffset -lt 0 -or $peOffset -gt ($peBytes.Length - 6)) {
            throw "Invalid or truncated PE file (e_lfanew is outside the file): $pePath"
        }
        if ([System.BitConverter]::ToUInt32($peBytes, $peOffset) -ne 0x00004550) {
            throw "Invalid PE file (missing PE signature): $pePath"
        }
        $machine = [System.BitConverter]::ToUInt16($peBytes, $peOffset + 4)
        if ($machine -ne $architectureDetails.PeMachine) {
            throw ('Staged PE machine mismatch (found 0x{0:x4}, expected 0x{1:x4}): {2}' -f $machine, $architectureDetails.PeMachine, $pePath)
        }
        Write-Host ('Verified {0}: PE machine 0x{1:x4}' -f $peFileName, $machine)
    }

    $stagedDllLookup = @{}
    foreach ($dllName in (@($runtimeDllNames) + @('onnxruntime.dll'))) {
        $stagedDllLookup[$dllName.ToLowerInvariant()] = $true
    }
    $windowsDllAllowlist = @(
        'advapi32.dll', 'bcrypt.dll', 'dbghelp.dll', 'dxgi.dll', 'iphlpapi.dll', 'kernel32.dll',
        'mfplat.dll', 'mfreadwrite.dll', 'ole32.dll', 'oleaut32.dll', 'secur32.dll', 'setupapi.dll',
        'shell32.dll', 'shlwapi.dll', 'user32.dll', 'userenv.dll', 'winmm.dll', 'ws2_32.dll',
        'ntdll.dll', 'crypt32.dll', 'normaliz.dll'
    )
    $windowsDllLookup = @{}
    foreach ($dllName in $windowsDllAllowlist) {
        $windowsDllLookup[$dllName] = $true
    }
    foreach ($peFileName in $peFileNames) {
        $pePath = Join-Path -Path $destinationPath -ChildPath $peFileName
        $importsResult = Invoke-NativeCapture -Name "Inspect imports for $peFileName" -Executable $llvmReadobj -ArgumentList @('--coff-imports', $pePath) -DisplayOutput $false
        $importedDllNames = @()
        foreach ($line in $importsResult.Lines) {
            if ($line -match '^\s+Name: (\S+\.dll)\s*$') {
                $importedDllNames += $matches[1]
            }
        }
        if ($importedDllNames.Count -eq 0) {
            throw "No DLL imports were reported for staged PE file: $peFileName"
        }
        foreach ($importedDllName in $importedDllNames) {
            $normalizedImport = $importedDllName.ToLowerInvariant()
            $isApiSet = $normalizedImport -match '^(api-ms-win-|ext-ms-win-).+\.dll$'
            if (-not $stagedDllLookup.ContainsKey($normalizedImport) -and
                -not $windowsDllLookup.ContainsKey($normalizedImport) -and
                -not $isApiSet) {
                throw "Staged PE file '$peFileName' imports missing dependency '$importedDllName'."
            }
        }
        Write-Host "Validated imports for $peFileName ($($importedDllNames.Count) DLLs)."
    }

    $expectedInventory = @('MacAmbientJevEngine.exe') + $runtimeDllNames + @('onnxruntime.dll') + $resourcePaths
    $stageRootPrefix = $destinationPath.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
    $actualInventory = @(
        Get-ChildItem -LiteralPath $destinationPath -File -Recurse | ForEach-Object {
            $_.FullName.Substring($stageRootPrefix.Length).Replace('\', '/')
        }
    )
    $expectedInventorySorted = @($expectedInventory | Sort-Object -CaseSensitive)
    $actualInventorySorted = @($actualInventory | Sort-Object -CaseSensitive)
    $inventoryDifferences = @(Compare-Object -ReferenceObject $expectedInventorySorted -DifferenceObject $actualInventorySorted -CaseSensitive)
    if ($inventoryDifferences.Count -ne 0) {
        $differenceText = [string]::Join([Environment]::NewLine, [string[]]@($inventoryDifferences | ForEach-Object { "{0}: {1}" -f $_.SideIndicator, $_.InputObject }))
        throw "Staged file inventory does not match the explicit payload inventory:`n$differenceText"
    }

    Write-Host "Windows $Architecture engine payload staged and verified: $destinationPath"
    Write-Output $destinationPath
} finally {
    Pop-Location
}
