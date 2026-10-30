[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Executable,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SmallModelDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$LargeModelDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Fixture,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResultsDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-AbsoluteWindowsPath([string]$Path, [string]$Name) {
    if ($Path -match '["\r\n%]') {
        throw "$Name contains a quote, newline, or CMD percent-expansion character: $Path"
    }
    if ($Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))') {
        throw "$Name must be an absolute Windows path: $Path"
    }
    try {
        return [System.IO.Path]::GetFullPath($Path)
    } catch {
        throw "$Name is not a valid absolute Windows path: $Path. $($_.Exception.Message)"
    }
}

function Write-NewJsonFile([string]$Path, [object]$Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 12
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($json + [Environment]::NewLine)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
}

function Invoke-MeasurementProcess([string]$Name, [string[]]$Arguments, [string]$LogPath) {
    Write-Host "START $Name"
    $exitCode = -1
    try {
        if (Test-Path -LiteralPath $LogPath) { throw "Log path already exists: $LogPath" }
        foreach ($argument in $Arguments) {
            if ($argument -match '["\r\n%]') { throw "CLI argument cannot be quoted safely for CMD: $argument" }
        }
        $commandParts = New-Object 'System.Collections.Generic.List[string]'
        [void]$commandParts.Add(('"' + $script:ExecutablePath + '"'))
        foreach ($argument in $Arguments) { [void]$commandParts.Add(('"' + $argument + '"')) }
        $command = ($commandParts.ToArray() -join ' ') + ' > "' + $LogPath + '" 2>&1'
        $cmdArgument = '"' + $command + '"'
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:CmdExecutable
        $startInfo.Arguments = '/d /s /v:off /c ' + $cmdArgument
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) { throw "Could not start cmd.exe for $Name" }
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        } finally {
            $process.Dispose()
        }
        if ($exitCode -ne 0) {
            if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
                $logText = Get-Content -LiteralPath $LogPath -Raw -Encoding UTF8 -ErrorAction Stop
                if (-not [string]::IsNullOrEmpty($logText)) { Write-Host $logText }
            } else {
                Write-Host "Native log was not created: $LogPath"
            }
            throw "$Name failed with native exit code $exitCode"
        }
    } finally {
        Write-Host "DONE $Name (exit code $exitCode)"
    }
}

function Read-Measurement([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Name did not create its JSON output: $Path" }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "$Name produced invalid JSON at $Path. $($_.Exception.Message)"
    }
}

function Assert-SameTranscription([object]$Reference, [object]$Candidate, [string]$Name) {
    $referenceBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Reference.first_transcription.text)
    $candidateBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Candidate.first_transcription.text)
    if ($referenceBytes.Length -ne $candidateBytes.Length) { throw "$Name text UTF-8 byte length differs from trial 1 current" }
    for ($index = 0; $index -lt $referenceBytes.Length; $index++) {
        if ($referenceBytes[$index] -ne $candidateBytes[$index]) { throw "$Name text UTF-8 bytes differ from trial 1 current" }
    }
    $referenceIDs = @($Reference.first_transcription.generated_ids)
    $candidateIDs = @($Candidate.first_transcription.generated_ids)
    if ($referenceIDs.Count -ne $candidateIDs.Count) { throw "$Name generated token count differs from trial 1 current" }
    for ($index = 0; $index -lt $referenceIDs.Count; $index++) {
        if ([long]$referenceIDs[$index] -ne [long]$candidateIDs[$index]) { throw "$Name generated token IDs differ from trial 1 current" }
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This measurement runner must run on Windows.' }
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw "This measurement runner requires Windows PowerShell 5.1; found $($PSVersionTable.PSVersion)." }
$script:ExecutablePath = Resolve-AbsoluteWindowsPath $Executable 'Executable'
$smallModelPath = Resolve-AbsoluteWindowsPath $SmallModelDirectory 'SmallModelDirectory'
$largeModelPath = Resolve-AbsoluteWindowsPath $LargeModelDirectory 'LargeModelDirectory'
$fixturePath = Resolve-AbsoluteWindowsPath $Fixture 'Fixture'
$resultsPath = Resolve-AbsoluteWindowsPath $ResultsDirectory 'ResultsDirectory'
if (-not (Test-Path -LiteralPath $script:ExecutablePath -PathType Leaf)) { throw "Executable does not exist: $script:ExecutablePath" }
if (-not (Test-Path -LiteralPath $smallModelPath -PathType Container)) { throw "Small model source directory does not exist: $smallModelPath" }
if (-not (Test-Path -LiteralPath $largeModelPath -PathType Container)) { throw "Large model source directory does not exist: $largeModelPath" }
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) { throw "Fixture does not exist: $fixturePath" }
if (Test-Path -LiteralPath $resultsPath) { throw "ResultsDirectory must not already exist: $resultsPath" }
$resultsParent = [System.IO.Path]::GetDirectoryName($resultsPath)
if ([string]::IsNullOrEmpty($resultsParent) -or -not (Test-Path -LiteralPath $resultsParent -PathType Container)) {
    throw "ResultsDirectory parent must already exist: $resultsParent"
}

$derivedRoot = 'C:\Models'
if (-not (Test-Path -LiteralPath $derivedRoot -PathType Container)) { throw "Required derived-model parent does not exist: $derivedRoot" }
$experiments = @(
    [PSCustomObject]@{ Size = '0.6b'; Model = $smallModelPath; Derived = 'C:\Models\prepack-0.6b' },
    [PSCustomObject]@{ Size = '1.7b'; Model = $largeModelPath; Derived = 'C:\Models\prepack-1.7b' }
)
foreach ($experiment in $experiments) {
    if (Test-Path -LiteralPath $experiment.Derived) { throw "Derived destination must not already exist: $($experiment.Derived)" }
}

$script:CmdExecutable = Join-Path -Path $env:SystemRoot -ChildPath 'System32\cmd.exe'
if (-not (Test-Path -LiteralPath $script:CmdExecutable -PathType Leaf)) { throw "cmd.exe is missing: $script:CmdExecutable" }
$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
$disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
if ($processors.Count -eq 0 -or $null -eq $disk -or $null -eq $disk.FreeSpace) { throw 'Could not capture required CPU or C: disk environment data.' }
$cpuNames = @($processors | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
$logicalProcessors = [int](($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
if ([string]::IsNullOrWhiteSpace([string]$os.BuildNumber) -or $cpuNames.Count -eq 0 -or $logicalProcessors -le 0 -or [UInt64]$os.TotalVisibleMemorySize -eq 0 -or [string]::IsNullOrWhiteSpace([string]$env:PROCESSOR_ARCHITECTURE)) {
    throw 'Required OS build, CPU, memory, or architecture environment data is missing.'
}
$environment = [ordered]@{
    os_build = [string]$os.BuildNumber
    cpu_name = ($cpuNames -join '; ')
    logical_processor_count = $logicalProcessors
    visible_memory_bytes = [UInt64]$os.TotalVisibleMemorySize * 1024
    architecture = [string]$env:PROCESSOR_ARCHITECTURE
    os_is_64_bit = [Environment]::Is64BitOperatingSystem
    powershell_version = [string]$PSVersionTable.PSVersion
    free_c_bytes_before = [UInt64]$disk.FreeSpace
    noise_vm_note = 'Windows VM; ambient noise is not measured by this runner.'
    x64_experiment_status = 'pending'
}

if (Test-Path -LiteralPath $resultsPath) { throw "ResultsDirectory appeared before creation: $resultsPath" }
New-Item -ItemType Directory -Path ([WildcardPattern]::Escape($resultsPath)) -ErrorAction Stop | Out-Null
Write-NewJsonFile (Join-Path $resultsPath 'environment.json') $environment
$trialOrders = @(
    'current,external-mapped,saved-prepacked',
    'external-mapped,saved-prepacked,current',
    'saved-prepacked,current,external-mapped'
)
$measurementRecords = New-Object 'System.Collections.Generic.List[object]'
$parityBySize = [ordered]@{}

foreach ($experiment in $experiments) {
    $derivedPath = [string]$experiment.Derived
    $saveStarted = $false
    try {
        if (Test-Path -LiteralPath $derivedPath) { throw "Derived destination appeared before save: $derivedPath" }
        $saveOutput = Join-Path $resultsPath "$($experiment.Size)-save.json"
        $saveLog = Join-Path $resultsPath "$($experiment.Size)-save.log"
        $saveArguments = @(
            'measure-prepack', '--fixture', $fixturePath,
            '--asr-model-directory', [string]$experiment.Model,
            '--asr-model-size', [string]$experiment.Size,
            '--threads', '3', '--prepack', 'saved-prepacked', '--action', 'save',
            '--calls', '50', '--output', $saveOutput,
            '--prepack-directory', $derivedPath
        )
        $saveStarted = $true
        Invoke-MeasurementProcess "$($experiment.Size) save" $saveArguments $saveLog
        if (-not (Test-Path -LiteralPath $derivedPath -PathType Container)) { throw "Save did not create its derived directory: $derivedPath" }
        if (-not (Test-Path -LiteralPath $saveOutput -PathType Leaf)) { throw "Save did not create its result JSON: $saveOutput" }

        for ($trial = 1; $trial -le 3; $trial++) {
            foreach ($mode in $trialOrders[$trial - 1].Split(',')) {
                $outputPath = Join-Path $resultsPath "$($experiment.Size)-$mode-$trial.json"
                $logPath = Join-Path $resultsPath "$($experiment.Size)-$mode-$trial.log"
                $arguments = @(
                    'measure-prepack', '--fixture', $fixturePath,
                    '--asr-model-directory', [string]$experiment.Model,
                    '--asr-model-size', [string]$experiment.Size,
                    '--threads', '3', '--prepack', $mode, '--action', 'measure',
                    '--calls', '50', '--output', $outputPath
                )
                if ($mode -eq 'saved-prepacked') { $arguments += @('--prepack-directory', $derivedPath) }
                Invoke-MeasurementProcess "$($experiment.Size) $mode trial $trial" $arguments $logPath
                $data = Read-Measurement $outputPath "$($experiment.Size) $mode trial $trial"
                $measurementRecords.Add([PSCustomObject]@{ Size = [string]$experiment.Size; Mode = $mode; Trial = $trial; Data = $data })
                $afterPrepare = ConvertTo-Json -InputObject $data.memory.after_prepare -Compress -Depth 8
                $afterWarm = ConvertTo-Json -InputObject $data.memory.after_all_warm_calls -Compress -Depth 8
                Write-Host ('RESULT {0}-{1}-{2}: cold_process_load_seconds={3} first_transcription.rtf={4} warm.mean_rtf={5} warm.p95_seconds={6} memory.after_prepare={7} memory.after_all_warm_calls={8}' -f `
                    $experiment.Size, $mode, $trial, $data.cold_process_load_seconds, $data.first_transcription.rtf, `
                    $data.warm.mean_rtf, $data.warm.p95_seconds, $afterPrepare, $afterWarm)
            }
        }

        $sizeRecords = @($measurementRecords | Where-Object { $_.Size -eq $experiment.Size })
        if ($sizeRecords.Count -ne 9) { throw "$($experiment.Size) produced $($sizeRecords.Count) measurements; expected exactly 9." }
        $referenceRecord = @($sizeRecords | Where-Object { $_.Mode -eq 'current' -and $_.Trial -eq 1 })
        if ($referenceRecord.Count -ne 1) { throw "Could not identify $($experiment.Size) trial 1 current as parity reference." }
        foreach ($record in $sizeRecords) {
            Assert-SameTranscription $referenceRecord[0].Data $record.Data "$($experiment.Size) $($record.Mode) trial $($record.Trial)"
        }
        $parityBySize[[string]$experiment.Size] = [ordered]@{
            text = [string]$referenceRecord[0].Data.first_transcription.text
            generated_ids = @($referenceRecord[0].Data.first_transcription.generated_ids)
            parity = $true
            calls = [ordered]@{
                warm_per_process = 50
                first_per_process = 1
                measurement_processes = 9
                total_transcriptions = 459
            }
        }
        Write-Host "PARITY $($experiment.Size): exact UTF-8 text and generated_ids match all 9 measurement processes."
    } finally {
        if ($saveStarted -and (Test-Path -LiteralPath $derivedPath)) {
            if (-not (Test-Path -LiteralPath $derivedPath -PathType Container)) { throw "Refusing cleanup: derived destination is not a directory: $derivedPath" }
            $resolvedDerived = (Resolve-Path -LiteralPath $derivedPath -ErrorAction Stop).Path
            if (-not [string]::Equals($resolvedDerived, $derivedPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing cleanup: resolved derived path '$resolvedDerived' is not the expected target '$derivedPath'."
            }
            Remove-Item -LiteralPath $derivedPath -Recurse -Force -ErrorAction Stop
        }
    }
}

Write-NewJsonFile (Join-Path $resultsPath 'parity.json') $parityBySize
Write-Host "Results written to $resultsPath"
