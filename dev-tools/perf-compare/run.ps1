param(
    [string]$Label = $env:COMPUTERNAME,
    [string]$Heap = '2g',
    [int]$Docs = 10000,
    [int]$SearchRuns = 100,
    [int]$Port = 19200,
    [switch]$SkipBuild,
    [switch]$SkipRuntime
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Measure-Step {
    param(
        [scriptblock]$Action
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    & $Action
    $stopwatch.Stop()
    [int64]$stopwatch.ElapsedMilliseconds
}

function Get-ArchivePath {
    param(
        [string]$RepoRoot
    )

    $archiveDir = Join-Path $RepoRoot 'distribution\archives\windows-zip\build\distributions'
    if (-not (Test-Path $archiveDir)) {
        throw "Distribution directory not found: $archiveDir"
    }

    $archive = Get-ChildItem -Path $archiveDir -Filter 'elasticsearch-*.zip' |
        Sort-Object LastWriteTimeUtc |
        Select-Object -Last 1

    if (-not $archive) {
        throw 'Could not locate a Windows distribution archive. Run localDistro first.'
    }

    $archive.FullName
}

function Wait-ForHttp {
    param(
        [string]$Uri,
        [int]$TimeoutSeconds
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 0; $attempt -lt $TimeoutSeconds; $attempt++) {
        try {
            Invoke-RestMethod -Method Get -Uri $Uri | Out-Null
            $stopwatch.Stop()
            return [int64]$stopwatch.ElapsedMilliseconds
        } catch {
            Start-Sleep -Seconds 1
        }
    }

    throw "Timed out waiting for $Uri"
}

function Write-BulkFile {
    param(
        [string]$Path,
        [int]$DocCount
    )

    $builder = [System.Text.StringBuilder]::new()
    for ($i = 1; $i -le $DocCount; $i++) {
        [void]$builder.AppendLine('{"index":{"_index":"bench"}}')
        [void]$builder.AppendLine("{""id"":$i,""name"":""doc-$i"",""group"":""g$($i % 10)"",""text"":""quick brown fox jumps over the lazy dog""}")
    }
    [System.IO.File]::WriteAllText($Path, $builder.ToString(), [System.Text.Encoding]::UTF8)
}

function Invoke-CurlQuiet {
    param(
        [string[]]$Arguments
    )

    & curl.exe @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe failed with exit code $LASTEXITCODE"
    }
}

function Invoke-Gradle {
    param(
        [string[]]$Arguments,
        [string]$Description
    )

    & .\gradlew.bat @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Format-Nullable {
    param(
        $Value
    )

    if ($null -eq $Value -or $Value -eq '') {
        'skipped'
    } else {
        "$Value"
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$resultsDir = Join-Path $scriptDir 'results'
$workDir = Join-Path $scriptDir 'work'

New-Item -Path $resultsDir -ItemType Directory -Force | Out-Null
New-Item -Path $workDir -ItemType Directory -Force | Out-Null

Set-Location $repoRoot

if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    throw 'java is not available on PATH.'
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw 'curl.exe is required for the runtime benchmark.'
}

$safeLabel = ($Label -replace '[^A-Za-z0-9_.-]', '-')
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$runId = "$safeLabel-$timestamp"
$runRoot = Join-Path $workDir $runId
$resultJson = Join-Path $resultsDir "$runId.json"
$resultMd = Join-Path $resultsDir "$runId.md"

New-Item -Path $runRoot -ItemType Directory -Force | Out-Null

$gitCommit = (& git rev-parse --short HEAD).Trim()
$gitBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
$javaVersion = ((& java -version 2>&1) | Out-String).Trim() -replace '\s+', ' '
$osVersion = [System.Environment]::OSVersion.VersionString
$osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$cpuModel = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name).Trim()

$warmupMs = $null
$buildMs = $null
$startupMs = $null
$bulkMs = $null
$searchMs = $null
$archivePath = $null
$process = $null
$serverPid = $null

try {
    if (-not $SkipBuild) {
        Write-Host 'Warming Gradle with --no-daemon help...'
        $warmupMs = Measure-Step { Invoke-Gradle -Arguments @('--no-daemon', 'help') -Description 'Gradle warmup' }

        Write-Host 'Running timed clean localDistro...'
        $buildMs = Measure-Step { Invoke-Gradle -Arguments @('--no-daemon', 'clean', 'localDistro') -Description 'Gradle localDistro build' }
    }

    if (-not $SkipRuntime) {
        $archivePath = Get-ArchivePath -RepoRoot $repoRoot
        $installDir = Join-Path $runRoot 'install'
        $bulkFile = Join-Path $runRoot 'bench.ndjson'
        $pidFile = Join-Path $runRoot 'elasticsearch.pid'
        $stdoutLog = Join-Path $runRoot 'es-stdout.log'
        $stderrLog = Join-Path $runRoot 'es-stderr.log'

        New-Item -Path $installDir -ItemType Directory -Force | Out-Null
        Write-Host "Extracting $archivePath..."
        Expand-Archive -Path $archivePath -DestinationPath $installDir -Force

        $esHome = Get-ChildItem -Path $installDir -Directory | Select-Object -First 1
        if (-not $esHome) {
            throw 'Could not locate extracted Elasticsearch home.'
        }

        $env:ES_JAVA_OPTS = "-Xms$Heap -Xmx$Heap"
        $startArgs = @(
            '-p', $pidFile,
            '-E', 'xpack.security.enabled=false',
            '-E', 'discovery.type=single-node',
            '-E', 'network.host=127.0.0.1',
            '-E', "http.port=$Port",
            '-E', "path.data=$(Join-Path $runRoot 'data')",
            '-E', "path.logs=$(Join-Path $runRoot 'logs')"
        )

        Write-Host 'Starting Elasticsearch from distribution...'
        $process = Start-Process -FilePath (Join-Path $esHome.FullName 'bin\elasticsearch.bat') `
            -ArgumentList $startArgs `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog `
            -PassThru `
            -WindowStyle Hidden

        $startupMs = Wait-ForHttp -Uri "http://127.0.0.1:$Port" -TimeoutSeconds 180

        if (Test-Path $pidFile) {
            $serverPid = [int](Get-Content $pidFile | Select-Object -First 1)
        } else {
            $serverPid = $process.Id
        }

        Write-Host 'Preparing deterministic benchmark data...'
        Write-BulkFile -Path $bulkFile -DocCount $Docs

        Invoke-CurlQuiet -Arguments @('-sS', '-o', 'NUL', '-X', 'DELETE', "http://127.0.0.1:$Port/bench")
        Invoke-CurlQuiet -Arguments @(
            '-fsS',
            '-H', 'Content-Type: application/json',
            '-X', 'PUT',
            "http://127.0.0.1:$Port/bench",
            '-d', '{"settings":{"number_of_shards":1,"number_of_replicas":0}}'
        )

        Write-Host 'Running bulk benchmark...'
        $bulkMs = Measure-Step {
            Invoke-CurlQuiet -Arguments @(
                '-fsS',
                '-H', 'Content-Type: application/x-ndjson',
                '-X', 'POST',
                "http://127.0.0.1:$Port/_bulk?refresh=true",
                '--data-binary', "@$bulkFile"
            )
        }

        $query = '{"query":{"match":{"text":"quick brown fox"}}}'
        Invoke-CurlQuiet -Arguments @(
            '-fsS',
            '-H', 'Content-Type: application/json',
            '-X', 'POST',
            "http://127.0.0.1:$Port/bench/_search",
            '-d', $query
        )

        Write-Host 'Running search benchmark...'
        $searchMs = Measure-Step {
            for ($i = 0; $i -lt $SearchRuns; $i++) {
                Invoke-CurlQuiet -Arguments @(
                    '-fsS',
                    '-H', 'Content-Type: application/json',
                    '-X', 'POST',
                    "http://127.0.0.1:$Port/bench/_search",
                    '-d', $query
                )
            }
        }
    }
} finally {
    if ($serverPid) {
        Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
    } elseif ($process) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}

$resultObject = [ordered]@{
    run_id = $runId
    label = $Label
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    git_commit = $gitCommit
    git_branch = $gitBranch
    java_version = $javaVersion
    os_name = 'Windows'
    os_version = $osVersion
    os_arch = $osArch
    cpu_model = $cpuModel
    heap = $Heap
    docs = $Docs
    search_runs = $SearchRuns
    build = [ordered]@{
        warmup_help_ms = $warmupMs
        clean_local_distro_ms = $buildMs
    }
    runtime = [ordered]@{
        archive_path = $archivePath
        http_port = $Port
        startup_ms = $startupMs
        bulk_ms = $bulkMs
        search_ms = $searchMs
    }
}

$resultObject | ConvertTo-Json -Depth 5 | Set-Content -Path $resultJson -Encoding utf8

$markdown = @"
# Elasticsearch perf run: $runId

- Label: $Label
- Timestamp (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
- Git branch: $gitBranch
- Git commit: $gitCommit
- Java: $javaVersion
- OS: Windows $osVersion ($osArch)
- CPU: $cpuModel
- Heap: $Heap
- Docs: $Docs
- Search runs: $SearchRuns

## Build

- Warmup ./gradlew --no-daemon help: $(Format-Nullable $warmupMs) ms
- Timed ./gradlew --no-daemon clean localDistro: $(Format-Nullable $buildMs) ms

## Runtime

- Distribution archive: $(Format-Nullable $archivePath)
- Startup to HTTP ready: $(Format-Nullable $startupMs) ms
- Bulk indexing: $(Format-Nullable $bulkMs) ms
- Search loop: $(Format-Nullable $searchMs) ms
"@

Set-Content -Path $resultMd -Value $markdown -Encoding utf8

Write-Host "Wrote:"
Write-Host "  $resultJson"
Write-Host "  $resultMd"
