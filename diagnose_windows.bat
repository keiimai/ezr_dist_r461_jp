@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "EZR_DIAGNOSTIC_SELF=%~f0"
set "EZR_DIAGNOSTIC_OPTIONS=%*"
powershell.exe -NoLogo -NoProfile -Command "$s=[IO.File]::ReadAllText($env:EZR_DIAGNOSTIC_SELF);$marker='#'+'<EZR_DIAGNOSTIC_POWERSHELL>';& ([scriptblock]::Create($s.Substring($s.IndexOf($marker)+$marker.Length)))"
set "EZR_DIAGNOSTIC_EXIT=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %EZR_DIAGNOSTIC_EXIT%
#<EZR_DIAGNOSTIC_POWERSHELL>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$toolVersion = '1.3.3'
$rulesVersion = '2026-11-02'
$selfPath = $env:EZR_DIAGNOSTIC_SELF
$projectRoot = [IO.Path]::GetDirectoryName($selfPath)
$language = 'en'
$messagesFile = Join-Path $projectRoot 'launcher\start_messages.txt'
if ([IO.File]::Exists($messagesFile)) { foreach ($line in [IO.File]::ReadAllLines($messagesFile, [Text.Encoding]::UTF8)) { if ($line -cmatch '^language=(ja|en)$') { $language = $Matches[1]; break } } }
$extendedRequested = $false
$networkRequested = $false
$shareRequested = $false
$imageOverride = $null
$incidentName = $null
foreach ($option in @($env:EZR_DIAGNOSTIC_OPTIONS -split '\s+' | Where-Object { $_ })) {
    if ($option -eq '--extended') { $extendedRequested = $true }
    elseif ($option -eq '--network') { $networkRequested = $true }
    elseif ($option -eq '--share-test') { $shareRequested = $true }
    elseif ($option -eq '--no-pause') { }
    elseif ($option -match '^--image=([A-Za-z0-9][A-Za-z0-9_.:/@-]*)$') { $imageOverride = $Matches[1] }
    elseif ($option -cmatch '^--incident=(runtime_[A-Za-z0-9_.-]+\.jsonl)$') { $incidentName = $Matches[1] }
    elseif ($option -eq '--help') {
        Write-Host 'diagnose_windows.bat [--extended] [--network] [--share-test] [--image=existing-tag] [--no-pause]'
        Write-Host '--incident=runtime_<ID>.jsonl: summarize recorded conditions only; no live probes.'
        Write-Host '--extended: include Windows feature inventory; probe budget 90 seconds (default 30).'
        Write-Host 'Default: local information only; no Docker start, download, build or settings change.'
        Write-Host '--network: HTTPS checks to Docker Registry and Posit (no package download).'
        Write-Host '--share-test: two-way file check using an existing local image.'
        Write-Host 'Exit: 0 prerequisites met; 2 preparation needed; 3 review needed; 1 record could not be saved.'
        exit 0
    }
    else { Write-Error "Unknown option: $option"; exit 1 }
}
$runId = [Guid]::NewGuid().ToString()
$timer = [Diagnostics.Stopwatch]::StartNew()
$probeBudgetSeconds = if ($extendedRequested) { 90 } else { 30 }
$report = [ordered]@{
    schema_version = '1.0'; tool_version = $toolVersion; rules_version = $rulesVersion; run_id = $runId
    started_at = [DateTime]::UtcNow.ToString('o'); platform = 'Windows'; probes = @(); checks = @()
    scope = [ordered]@{ ezr_analysis = 'not_run'; vendor_support_lifecycle = 'not_evaluated'; configuration_changes = $false; network_requested = $networkRequested; share_test_requested = $shareRequested; extended_requested = $extendedRequested }
    criteria = [ordered]@{ host_memory_minimum_bytes = 8000000000; memory_rule_scope = 'Docker prerequisite, not an EZR analysis memory guarantee'; references = @('https://docs.docker.com/desktop/setup/install/windows-install/', 'https://learn.microsoft.com/en-us/windows/wsl/wsl-config') }
}

function Protect-Text([string]$Value) {
    foreach ($prefix in @($projectRoot, $env:USERPROFILE) | Sort-Object Length -Descending) {
        if ($prefix) { $Value = $Value.Replace($prefix, '<LOCAL_PATH>') }
    }
    $Value = $Value -replace '(?i)(https?://)[^\s/@]+@', '$1<REDACTED>@'
    $Value = $Value -replace '(?i)((?:proxy-)?authorization\s*[=:]\s*)[^\r\n]*', '$1<REDACTED>'
    $Value = $Value -replace '(?i)((?:password|token|secret|authorization)\s*[=:]\s*)[^\s,;]+', '$1<REDACTED>'
    if ($Value.Length -gt 1600) { $Value = $Value.Substring(0, 1600) }
    return $Value.Trim()
}
function Add-Check([string]$Id, [string]$Status, [string]$Reason) {
    $report.checks += [ordered]@{ id = $Id; status = $Status; reason = $Reason }
}
function Convert-NativeArgument([string]$Value) {
    if ($Value -notmatch '[\s"]' -and $Value.Length) { return $Value }
    $quoted = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $quoted = [regex]::Replace($quoted, '(\\+)$', '$1$1')
    return '"' + $quoted + '"'
}
function Convert-WslOutput([byte[]]$Bytes) {
    if (-not $Bytes.Length) { return '' }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }
    if ($Bytes.Length % 2 -eq 0 -and $Bytes -contains 0) {
        return [Text.Encoding]::Unicode.GetString($Bytes)
    }
    return [Text.Encoding]::UTF8.GetString($Bytes)
}
function Invoke-Probe([string]$Id, [string]$Executable, [string[]]$Arguments = @(), [int]$Seconds = 15, [switch]$Cleanup) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $outBytes = $null; $errBytes = $null
    $wslOutput = $Id -in @('wsl_version', 'wsl_distributions')
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.Arguments = (($Arguments | ForEach-Object { Convert-NativeArgument $_ }) -join ' ')
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $process.StartInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $status = 'unavailable'; $exitCode = $null; $stdout = ''; $stderr = ''; $started = $false
    $remaining = [Math]::Max(0, [int]($probeBudgetSeconds * 1000 - $timer.Elapsed.TotalMilliseconds))
    if (-not $Cleanup -and $remaining -le 0) {
        $process.Dispose()
        $report.probes += [ordered]@{ id = $Id; status = 'budget_exhausted'; exit_code = $null; elapsed_seconds = 0; error = '' }
        return [ordered]@{ status = 'budget_exhausted'; exit_code = $null; stdout = ''; stderr = ''; started = $false }
    }
    try {
        [void]$process.Start(); $started = $true
        if ($wslOutput) {
            $outBytes = New-Object IO.MemoryStream
            $errBytes = New-Object IO.MemoryStream
            $outTask = $process.StandardOutput.BaseStream.CopyToAsync($outBytes)
            $errTask = $process.StandardError.BaseStream.CopyToAsync($errBytes)
        } else {
            $outTask = $process.StandardOutput.ReadToEndAsync()
            $errTask = $process.StandardError.ReadToEndAsync()
        }
        $waitMs = [Math]::Max(0, [int]($Seconds * 1000 - $watch.Elapsed.TotalMilliseconds))
        $budgetLimited = $false
        if (-not $Cleanup) {
            $remaining = [Math]::Max(0, [int]($probeBudgetSeconds * 1000 - $timer.Elapsed.TotalMilliseconds))
            $budgetLimited = $remaining -le $waitMs
            $waitMs = [Math]::Min($waitMs, $remaining)
        }
        if ($process.WaitForExit($waitMs)) {
            $exitCode = $process.ExitCode
            $status = if ($exitCode -eq 0) { 'ok' } else { 'failed' }
        }
        else {
            $status = if ($budgetLimited) { 'budget_exhausted' } else { 'timed_out' }
            $process.Kill(); [void]$process.WaitForExit(200)
        }
        if ($outTask.Wait(100)) {
            $stdout = if ($wslOutput) { Convert-WslOutput ($outBytes.ToArray()) } else { $outTask.Result -replace "`0", '' }
        }
        if ($errTask.Wait(100)) {
            $stderr = if ($wslOutput) { Convert-WslOutput ($errBytes.ToArray()) } else { $errTask.Result -replace "`0", '' }
        }
    }
    catch { $stderr = $_.Exception.Message }
    finally {
        $process.Dispose()
        if ($outBytes) { $outBytes.Dispose() }
        if ($errBytes) { $errBytes.Dispose() }
    }
    if ($status -eq 'failed' -and $stderr -match '(?i)permission denied|operation not permitted|access is denied|アクセスが拒否') { $status = 'permission_denied' }
    $result = [ordered]@{ status = $status; exit_code = $exitCode; stdout = $stdout; stderr = (Protect-Text $stderr); started = $started }
    $report.probes += [ordered]@{ id = $Id; status = $status; exit_code = $exitCode; elapsed_seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 3); error = $result.stderr }
    return $result
}
function Read-ProbeJson([string]$Id, [string]$Executable, [string[]]$Arguments, [int]$Seconds = 20) {
    $result = Invoke-Probe $Id $Executable $Arguments $Seconds
    $result.value = $null
    try { if ($result.stdout.Trim()) { $result.value = $result.stdout | ConvertFrom-Json } } catch { }
    return $result
}
function Read-HostQuery([string]$Id, [string]$Code) {
    $Code = "`$ProgressPreference='SilentlyContinue';" + '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false);' + $Code
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    return Read-ProbeJson $Id (Join-Path $PSHOME 'powershell.exe') @('-NoLogo', '-NoProfile', '-EncodedCommand', $encoded) 40
}
function Get-FileDigest([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { return $null }
}



function Get-RoutineResult($Item) {
    $success = @{}; $failures = @(); $lastExit = $null; $lastStop = $null; $readyAt = -1
    $startup = @('docker_cli', 'project_files', 'docker_ready', 'build', 'bootstrap_build', 'package_relock', 'package_check', 'container_start', 'rstudio_ready')
    $index = 0
    foreach ($row in @($Item.events)) {
        $hasCode = $null -ne $row.exit_code -and [string]$row.exit_code -match '^-?\d{1,10}$'
        if ($row.event -eq 'launcher_exit' -and $hasCode) { $lastExit = $row }
        if ($row.event -eq 'end' -and $row.phase -eq 'container_stop_remove' -and $hasCode) { $lastStop = $row }
        if ($row.event -eq 'end' -and $hasCode -and [long]$row.exit_code -eq 0) {
            if ($row.phase) { $success[[string]$row.phase] = $index }
            if ($row.phase -eq 'rstudio_ready') { $readyAt = $index }
        }
        if ($row.event -in @('end', 'timeout') -and $hasCode -and [long]$row.exit_code -ne 0 -and $row.phase -in ($startup + @('container_stop_remove'))) {
            $failures += @{ phase = [string]$row.phase; index = $index }
        }
        $index++
    }
    $recovered = 0; $unresolved = 0
    foreach ($failure in $failures) {
        if (($success.ContainsKey($failure.phase) -and $success[$failure.phase] -gt $failure.index) -or ($failure.phase -in $startup -and $readyAt -gt $failure.index)) { $recovered++ }
        else { $unresolved++ }
    }
    $status = if ($Item.status -ne 'observed') { 'record_incomplete' }
        elseif ($lastStop -and [long]$lastStop.exit_code -ne 0) { 'stop_failed' }
        elseif ($lastExit -and [long]$lastExit.exit_code -ne 0) { 'launcher_failed' }
        elseif ($unresolved -gt 0) { 'command_failed' }
        elseif (-not $lastExit) { 'exit_not_observed' }
        elseif ($recovered -gt 0) { 'recovered' }
        else { 'completed' }
    return [ordered]@{
        status = $status; launcher_exit_observed = [bool]$lastExit; launcher_exit_code = $lastExit.exit_code
        rstudio_ready_observed = ($readyAt -ge 0); stop_remove_exit_code = $lastStop.exit_code
        recovered_failure_count = $recovered; unresolved_failure_count = $unresolved
        ezr_analysis = 'not_evaluated'
    }
}
function Write-RoutineResult($Item) {
    $messages = if ($language -eq 'ja') { @{
        completed = '起動ファイルの正常終了を記録しました。'
        recovered = '途中の失敗から回復し、起動ファイルの正常終了を記録しました。'
        stop_failed = '停止・削除コマンドが失敗しました。コンテナの停止を確認してください。'
        launcher_failed = '起動ファイルが失敗して終了しました。'
        command_failed = 'コマンドの失敗を記録しています。その後の回復は未確認です。'
        exit_not_observed = '起動ファイルの終了記録がありません。実行中か中断かは判定できません。'
        record_incomplete = '記録が不完全なため、終了状態を確定できません。'
    } } else { @{
        completed = 'Launcher completed successfully.'
        recovered = 'Recovered from an earlier command failure; launcher completed successfully.'
        stop_failed = 'Stop/remove command failed. Check whether the container has stopped.'
        launcher_failed = 'Launcher exited with a failure.'
        command_failed = 'A command failed; subsequent recovery was not observed.'
        exit_not_observed = 'No launcher exit recorded; it may still be running or may have been interrupted.'
        record_incomplete = 'Incomplete record; completion cannot be established.'
    } }
    $status = if ($Item.result) { $Item.result.status } else { 'record_incomplete' }
    Write-Host ($Item.path + ': ' + $messages[$status])
    if ($Item.result.recovered_failure_count -gt 0 -and $status -ne 'recovered') {
        Write-Host $(if ($language -eq 'ja') { '途中のコマンド失敗からの回復も記録されています。' } else { 'Recovery from an earlier command failure was also observed.' })
    }
}

function Read-RoutineRecords([string]$OnlyName = '') {
    $items = @()
    $folder = Join-Path $projectRoot 'outputs'
    if ([IO.Directory]::Exists($folder)) {
        $files = if ($OnlyName) { Get-Item -LiteralPath (Join-Path $folder $OnlyName) -ErrorAction SilentlyContinue } else { Get-ChildItem -LiteralPath $folder -Filter 'runtime_*.jsonl' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3 }
        $files = @($files | Where-Object { -not $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
        foreach ($file in $files) {
            $item = [ordered]@{ path = 'outputs/' + $file.Name; bytes = $file.Length }
            if ($file.Length -gt 65536) { $item.status = 'over_size_limit'; $items += $item; continue }
            $rows = @(); $invalid = $false
            try {
                $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    $buffer = New-Object byte[] 65537
                    $count = 0
                    while ($count -lt $buffer.Length) {
                        $n = $stream.Read($buffer, $count, $buffer.Length - $count)
                        if ($n -eq 0) { break }
                        $count += $n
                    }
                }
                finally { $stream.Dispose() }
                $item.bytes = $count
                if ($count -gt 65536) { $item.status = 'over_size_limit'; $items += $item; continue }
                $hasher = [Security.Cryptography.SHA256]::Create()
                try { $item.sha256 = [BitConverter]::ToString($hasher.ComputeHash($buffer, 0, $count)).Replace('-', '').ToLowerInvariant() }
                finally { $hasher.Dispose() }
                $lines = [Text.Encoding]::UTF8.GetString($buffer, 0, $count).TrimStart([char]0xFEFF) -split '\r?\n'
            }
            catch { $item.status = 'unavailable'; $items += $item; continue }
            foreach ($line in $lines) {
                if (-not $line.Trim()) { continue }
                try {
                    $row = $line | ConvertFrom-Json
                    if ($null -eq $row -or $row -is [array] -or $row -is [string] -or $row -is [ValueType]) { throw 'Invalid row' }
                    $selected = [ordered]@{}
                    foreach ($key in @('rule', 'observed_seconds', 'threshold_seconds', 'schema_version', 'record_kind', 'run_id', 'started_at', 'platform', 'elapsed_clock', 'elapsed_resolution_seconds', 'ezr_analysis', 'event', 'phase', 'elapsed_seconds', 'local_clock', 'exit_code', 'built_image_id', 'target', 'image_tag', 'built_at')) {
                        if ($row.PSObject.Properties.Name -contains $key) {
                            $v = $row.$key
                            if ($null -eq $v -or ($v -isnot [array] -and $v -isnot [pscustomobject] -and [string]$v -cmatch '^[A-Za-z0-9_.:/,-]{0,160}$')) { $selected[$key] = $v }
                        }
                    }
                    $rows += $selected
                }
                catch { $invalid = $true }
            }
            $valid = $rows.Count -gt 0 -and $rows[0].record_kind -eq 'ezr_launcher'
            $item.status = if (-not $valid) { 'invalid_header' } elseif ($invalid) { 'partial_record' } else { 'observed' }
            $item.launcher_completion = if (@($rows | Where-Object { $_.event -eq 'launcher_exit' }).Count) { 'observed' } else { 'not_observed' }
            $item.events = $rows
            $item.result = Get-RoutineResult $item
            $items += $item
        }
    }
    return [ordered]@{ maximum_files = 3; maximum_bytes_per_file = 65536; entries = $items; note = 'Launcher and command results only; container exit and EZR analysis completion are not inferred.' }
}


if ($incidentName) {
    try {
        $source = (Read-RoutineRecords $incidentName).entries | Select-Object -First 1
        if (-not $source -or $source.status -notin @('observed', 'partial_record')) { throw 'Routine record unavailable or invalid.' }
        $phases = @('launcher', 'docker_cli', 'project_files', 'docker_ready', 'build', 'bootstrap_build', 'package_relock', 'package_check', 'container_start', 'rstudio_ready', 'container_stop_remove')
        $rules = @('command_failed', 'timeout', 'slow_phase', 'launcher_failed')
        $conditions = @($source.events | Where-Object { $_.event -eq 'condition' -and $_.rule -in $rules -and $_.phase -in $phases })
        if (-not $conditions.Count) { throw 'No supported condition was recorded.' }
        $identity = $source.events | Where-Object { $_.event -eq 'build_identity' -and $_.built_image_id -cmatch '^sha256:[0-9a-f]{64}$' } | Select-Object -First 1
        $closed = @($source.events | Where-Object { $_.event -eq 'launcher_exit' }).Count -gt 0
        $lastExit = $source.events | Where-Object { $_.event -eq 'launcher_exit' } | Select-Object -Last 1
        $lastStop = $source.events | Where-Object { $_.event -eq 'end' -and $_.phase -eq 'container_stop_remove' } | Select-Object -Last 1
        $ready = @($source.events | Where-Object { $_.event -eq 'end' -and $_.phase -eq 'rstudio_ready' -and $null -ne $_.exit_code -and $_.exit_code -eq 0 }).Count -gt 0
        $summary = [ordered]@{
            schema_version = '1.0'; record_kind = 'ezr_conditional'; tool_version = '1.3.3'; rules_version = '2026-11-02'
            captured_at = [DateTime]::UtcNow.ToString('o'); platform = 'Windows'; conditions = $conditions; result = $source.result
            source_snapshot = [ordered]@{ path = $source.path; bytes = $source.bytes; sha256 = $source.sha256; status = $source.status; launcher_exit_observed = $closed; launcher_exit_code = $lastExit.exit_code; rstudio_ready_observed = $ready; stop_remove_exit_code = $lastStop.exit_code }
            built_identity = $identity; files = @()
            scope = [ordered]@{ ezr_analysis = 'not_evaluated'; docker_queries = $false; network = $false; raw_logs = $false }
            collection_budget_seconds = 0.5; clock_note = 'Phase durations use local time of day, assuming less than 24 hours per phase and no system clock adjustment.'
        }
        $hashTimer = [Diagnostics.Stopwatch]::StartNew()
        foreach ($name in @('start_windows.bat', 'diagnose_windows.bat', 'launcher/windows_gui.ps1', 'launcher/start_messages.txt', 'R/project_ezr.R', 'Dockerfile', 'docker-compose.yml', 'renv.lock', 'TEMPLATE_VERSION.txt')) {
            $path = Join-Path $projectRoot $name
            $entry = [ordered]@{ path = $name; status = 'not_present' }
            if ($hashTimer.Elapsed.TotalSeconds -gt 0.5) { $entry.status = 'budget_exhausted' }
            elseif ([IO.File]::Exists($path)) {
                $info = Get-Item -LiteralPath $path
                if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) { $entry.status = 'symlink_skipped' }
                elseif ($info.Length -gt 1048576) { $entry.status = 'over_size_limit' }
                else { $entry.sha256 = Get-FileDigest $path; $entry.status = if ($entry.sha256) { 'hashed' } else { 'unavailable' } }
            }
            $summary.files += $entry
        }
        $summary.collection_elapsed_seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        $bytes = [Text.Encoding]::UTF8.GetBytes(($summary | ConvertTo-Json -Depth 16) + "`n")
        if ($bytes.Length -gt 65536) { throw 'Conditional summary exceeded size limit.' }
        $leaf = ($incidentName -replace '^runtime_', 'incident_') -replace '\.jsonl$', '.json'
        $output = Join-Path (Join-Path $projectRoot 'outputs') $leaf
        if (Test-Path -LiteralPath $output) {
            $info = Get-Item -LiteralPath $output
            if ($info.PSIsContainer -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Conditional output is a link or directory.' }
        }
        $temp = $output + '.' + $runId + '.tmp'
        try { [IO.File]::WriteAllBytes($temp, $bytes); Move-Item -LiteralPath $temp -Destination $output -Force }
        finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
        Write-RoutineResult $source
        Write-Host $(if ($language -eq 'ja') { 'EZR: 問題があったときの記録を outputs/' + $leaf + ' に残しました。' } else { 'EZR conditional record: outputs/' + $leaf })
        exit 0
    }
    catch { Write-Host ($(if ($language -eq 'ja') { 'EZR: 問題があったときの記録をまとめられなかった理由: ' } else { 'EZR conditional record unavailable: ' }) + (Protect-Text $_.Exception.Message)); exit 1 }
}

try {
    $report.tool_sha256 = Get-FileDigest $selfPath
    $report.routine_records = Read-RoutineRecords
    $hostData = Read-HostQuery 'host_information' @'
$ErrorActionPreference='Stop'
$o=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 8
$c=Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 8
$p=@(Get-CimInstance Win32_Processor -OperationTimeoutSec 8)
$first=$p[0]
$arch=switch([int]$first.Architecture){9{'amd64'}12{'arm64'}0{'x86'}default{'unknown'}}
[ordered]@{os_caption=$o.Caption;os_version=$o.Version;os_build=$o.BuildNumber;os_product_type=$o.ProductType;os_architecture=$o.OSArchitecture;native_architecture=$arch;cpu_model=$first.Name;physical_cores=($p|Measure-Object NumberOfCores -Sum).Sum;logical_cpus=$c.NumberOfLogicalProcessors;memory_total_bytes=$c.TotalPhysicalMemory;memory_available_bytes=([long]$o.FreePhysicalMemory*1024);cpu_load_percent=$first.LoadPercentage;hypervisor_present=$c.HypervisorPresent;virtualization_firmware_reported=$first.VirtualizationFirmwareEnabled;slat_reported=$first.SecondLevelAddressTranslationExtensions;process_architecture=$env:PROCESSOR_ARCHITECTURE;process_wow64_architecture=$env:PROCESSOR_ARCHITEW6432}|ConvertTo-Json -Compress
'@
    $report.host = $hostData.value
    if (-not $report.host) { Add-Check 'host_information' 'unknown' 'Host information was unavailable or timed out.' }
    else {
        $arch = $report.host.native_architecture
        Add-Check 'cpu_architecture' $(if ($arch -in @('amd64', 'arm64')) { 'pass' } elseif ($arch -eq 'unknown') { 'unknown' } else { 'fail' }) "Native CPU: $arch"
        Add-Check 'host_memory' $(if ($report.host.memory_total_bytes -ge $report.criteria.host_memory_minimum_bytes) { 'pass' } else { 'fail' }) 'Docker prerequisite only; EZR requirements depend on the analysis.'
        if ($report.host.os_product_type -in @(2, 3)) { Add-Check 'windows_build' 'fail' 'Windows Server is not a Docker Desktop target.' }
        elseif ([int]$report.host.os_build -lt 19045) { Add-Check 'windows_build' 'fail' 'Below the documented Windows build floor.' }
        elseif ([int]$report.host.os_build -lt 22000) { Add-Check 'windows_build' 'warning' 'Windows 10 servicing eligibility requires separate verification.' }
        elseif ([int]$report.host.os_build -lt 22631) { Add-Check 'windows_build' 'fail' 'Below the documented Windows 11 build floor.' }
    }
    $report.storage = [ordered]@{ location_hint = $(if ($projectRoot -match '(?i)OneDrive|Dropbox|iCloud|CloudStorage') { 'cloud_sync_possible' } elseif ($projectRoot.StartsWith('\\')) { 'network' } else { 'local' }); folder_writable = $null }
    $driveRoot = [IO.Path]::GetPathRoot($projectRoot)
    try {
        $drive = New-Object IO.DriveInfo($driveRoot)
        $report.storage.filesystem = $drive.DriveFormat
        $report.storage.free_bytes = $drive.AvailableFreeSpace
        $report.storage.drive_type = $drive.DriveType.ToString()
    }
    catch { $report.storage.observation_error = Protect-Text $_.Exception.Message }
    if ($report.storage.location_hint -ne 'local') { Add-Check 'project_location' 'warning' 'Record storage conditions when comparing performance.' }
    $report.package = [ordered]@{ files = @(); template_version = @() }
    foreach ($name in @('start_windows.bat', 'diagnose_windows.bat', 'launcher/windows_gui.ps1', 'launcher/start_messages.txt', 'R/project_ezr.R', 'Dockerfile', 'docker-compose.yml', 'renv.lock', 'TEMPLATE_VERSION.txt')) {
        $file = Join-Path $projectRoot $name
        $report.package.files += [ordered]@{ path = $name; sha256 = (Get-FileDigest $file); present = [IO.File]::Exists($file) }
    }
    $stamp = Join-Path $projectRoot 'TEMPLATE_VERSION.txt'
    if ([IO.File]::Exists($stamp)) { $report.package.template_version = @([IO.File]::ReadAllLines($stamp) | Where-Object { $_ -match '^(template|launcher) [A-Za-z0-9_.-]+ [0-9a-f]{40,64}$' }) }
    $report.package.git_commit = $null
    if ([IO.Directory]::Exists((Join-Path $projectRoot '.git')) -or [IO.File]::Exists((Join-Path $projectRoot '.git'))) {
        $gitCommand = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gitCommand) {
            $commit = Invoke-Probe 'package_git_commit' $gitCommand.Source @('-C', $projectRoot, 'rev-parse', 'HEAD') 5
            if ($commit.status -eq 'ok' -and $commit.stdout.Trim() -match '^[0-9a-f]{40,64}$') { $report.package.git_commit = $commit.stdout.Trim() }
        }
    }
    $base = (Split-Path -Leaf $projectRoot).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if (-not $base) { $base = 'r' }
    $pathHash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($projectRoot))
    $projectName = '{0}-{1:D6}' -f $base, ([BitConverter]::ToUInt32($pathHash, 0) % 1000000)
    $image = if ($imageOverride) { $imageOverride } else { $projectName + ':dev' }
    $report.package.expected_image = $image
    $report.package.launcher_target = if ($report.host -and $report.host.native_architecture -in @('amd64', 'arm64')) { 'linux/' + $report.host.native_architecture } else { $null }

    $wsl = Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $report.wsl = [ordered]@{ wsl_exe_present = [bool]$wsl; installed = $(if ($wsl) { $null } else { $false }); version = $null; status = 'not_checked'; configured_limits = [ordered]@{}; docker_distribution_reported = $null; version_2_reported = $null; wsl2_observation = 'unknown' }
    if ($wsl) {
        $wv = Invoke-Probe 'wsl_version' $wsl.Source @('--version') 15
        $versions = @([regex]::Matches($wv.stdout, '\d+\.\d+\.\d+(?:\.\d+)?') | ForEach-Object { $_.Value })
        $report.wsl.status = $wv.status
        if ($wv.status -eq 'ok' -and $versions.Count) { $report.wsl.version = $versions[0]; if ($versions.Count -gt 1) { $report.wsl.kernel_version = $versions[1] } }
        $wl = Invoke-Probe 'wsl_distributions' $wsl.Source @('--list', '--verbose') 15
        $report.wsl.list_status = $wl.status
        if ($wv.status -eq 'ok' -or $wl.status -eq 'ok') { $report.wsl.installed = $true }
        if ($wl.status -eq 'ok' -and $wl.stdout.Trim()) {
            $report.wsl.docker_distribution_reported = [bool]($wl.stdout -match '(?m)^\s*\*?\s*docker-desktop[ \t]+')
            $report.wsl.version_2_reported = [bool]($wl.stdout -match '(?m)[ \t]2[ \t]*\r?$')
            $report.wsl.wsl2_observation = if ($report.wsl.version_2_reported) { 'distribution_reported' } else { 'no_distribution_reported' }
        }
    }
    $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
    if ([IO.File]::Exists($wslConfig)) {
        try {
            $section = ''
            foreach ($line in [IO.File]::ReadAllLines($wslConfig)) {
                if ($line -match '^\s*\[([^]]+)\]') { $section = $Matches[1] }
                elseif ($section -eq 'wsl2' -and $line -match '^\s*(memory|processors|swap)\s*=\s*([0-9]+(?:KB|MB|GB)?)\s*(?:[#;].*)?$') { $report.wsl.configured_limits[$Matches[1].ToLowerInvariant()] = $Matches[2] }
            }
        }
        catch { $report.wsl.config_read_status = 'unavailable' }
    }
    $report.wsl.windows_features = $null
    $report.wsl.feature_query_status = 'not_requested'

    $dockerCommand = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $docker = if ($dockerCommand) { $dockerCommand.Source } else { $null }
    if (-not $docker) {
        foreach ($candidate in @((Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe'), (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'))) {
            if ([IO.File]::Exists($candidate)) { $docker = $candidate; break }
        }
    }
    $report.docker = [ordered]@{ cli_found = [bool]$docker; cli_on_path = [bool]$dockerCommand; initial_engine_state = 'not_checked'; image = @{ status = 'not_checked' }; container = @{ status = 'not_checked' } }
    $report.docker.desktop_version = $null
    foreach ($app in @((Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\DockerDesktop.exe'), (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'))) {
        if ([IO.File]::Exists($app)) {
            try { $report.docker.desktop_version = [Diagnostics.FileVersionInfo]::GetVersionInfo($app).ProductVersion } catch { }
            break
        }
    }
    $engineReady = $false
    if (-not $docker) { Add-Check 'docker_cli' 'fail' 'Docker CLI not found. Install Docker Desktop or check its CLI location.' }
    else {
        if (-not $dockerCommand) { Add-Check 'launcher_cli_path' 'warning' 'Docker CLI was located outside PATH; verify that the existing launcher can find it.' }
        $cv = Invoke-Probe 'docker_cli' $docker @('--version')
        $report.docker.cli_version = if ($cv.status -eq 'ok') { $cv.stdout.Trim() } else { $null }
        $endpoint = $null
        if ($env:DOCKER_HOST -and -not $env:DOCKER_CONTEXT) { $endpoint = $env:DOCKER_HOST }
        else {
            $context = Invoke-Probe 'docker_context' $docker @('context', 'show')
            if ($context.status -eq 'ok') {
                $ep = Invoke-Probe 'docker_endpoint' $docker @('context', 'inspect', $context.stdout.Trim(), '--format', '{{(index .Endpoints "docker").Host}}')
                if ($ep.status -eq 'ok') { $endpoint = $ep.stdout.Trim() }
            }
        }
        $local = [bool]($endpoint -and ($endpoint.StartsWith('npipe://') -or $endpoint.StartsWith('unix://')))
        $report.docker.endpoint_kind = if ($endpoint) { ($endpoint -split ':')[0] } else { 'unknown' }
        $report.docker.local_endpoint = $local
        if (-not $local) { $report.docker.initial_engine_state = 'not_contacted'; Add-Check 'docker_endpoint' 'unknown' 'Remote or unresolved Docker endpoint was not contacted.' }
        else {
            $format = '{"server_version":{{json .ServerVersion}},"os_type":{{json .OSType}},"architecture":{{json .Architecture}},"logical_cpus":{{.NCPU}},"memory_total_bytes":{{.MemTotal}},"kernel_version":{{json .KernelVersion}},"storage_driver":{{json .Driver}},"running_containers":{{.ContainersRunning}}}'
            $info = Read-ProbeJson 'docker_engine' $docker @('info', '--format', $format)
            $v = $info.value
            $engineReady = [bool]($info.status -eq 'ok' -and $v -and $v.server_version -and $v.kernel_version -and $v.os_type -eq 'linux' -and $v.architecture -in @('aarch64', 'arm64', 'x86_64', 'amd64') -and $v.logical_cpus -gt 0 -and $v.memory_total_bytes -gt 0)
            $report.docker.engine = $v
            $report.docker.initial_engine_state = if ($engineReady) { 'responding' } elseif ($info.status -eq 'timed_out') { 'timed_out' } else { 'unavailable_or_invalid' }
            Add-Check 'docker_engine' $(if ($engineReady) { 'pass' } elseif ($info.status -in @('timed_out', 'budget_exhausted', 'permission_denied', 'unavailable')) { 'unknown' } else { 'fail' }) $(if ($engineReady) { 'Actual local Linux Engine fields returned.' } else { 'No valid Linux Engine response; exit code alone does not establish readiness.' })
            if ($engineReady) {
                $compose = Invoke-Probe 'docker_compose' $docker @('compose', 'version', '--short')
                $report.docker.compose_version = if ($compose.status -eq 'ok') { $compose.stdout.Trim() } else { $null }
                Add-Check 'docker_compose' $(if ($report.docker.compose_version) { 'pass' } elseif ($compose.status -eq 'budget_exhausted') { 'unknown' } else { 'fail' }) 'Docker Compose must be available to the existing launcher.'
                $im = Read-ProbeJson 'docker_image' $docker @('image', 'inspect', $image, '--format', '{"id":{{json .Id}},"os":{{json .Os}},"architecture":{{json .Architecture}},"repo_digests":{{json .RepoDigests}}}')
                $validImage = $im.status -eq 'ok' -and $im.value -and $im.value.id -match '^sha256:[0-9a-f]{64}$' -and $im.value.os -eq 'linux' -and $im.value.architecture -in @('arm64', 'amd64')
                $report.docker.image = [ordered]@{ status = $(if ($validImage) { 'present' } elseif ($im.status -in @('ok', 'timed_out', 'budget_exhausted')) { 'unknown' } else { 'not_available' }); details = $im.value }
                if ($im.value -and $report.host -and $im.value.architecture -ne $report.host.native_architecture) { Add-Check 'image_architecture' 'warning' 'Image and native CPU differ; emulation may be required.' }
                $ci = Read-ProbeJson 'docker_container' $docker @('container', 'inspect', ($projectName + '_dev'), '--format', '{"state":{{json .State.Status}},"oom_killed":{{.State.OOMKilled}},"image_id":{{json .Image}},"memory_limit_bytes":{{.HostConfig.Memory}},"swap_limit_bytes":{{.HostConfig.MemorySwap}},"nano_cpus":{{.HostConfig.NanoCpus}},"cpu_quota":{{.HostConfig.CpuQuota}},"cpu_period":{{.HostConfig.CpuPeriod}},"cpuset":{{json .HostConfig.CpusetCpus}}}')
                $report.docker.container = [ordered]@{ status = $(if ($ci.status -eq 'ok' -and $ci.value) { 'present' } elseif ($ci.status -in @('timed_out', 'budget_exhausted')) { 'unknown' } else { 'not_available' }); details = $ci.value }
            }
        }
    }
    $settingsPath = Join-Path $env:APPDATA 'Docker\settings-store.json'
    $report.docker.configured_limits = [ordered]@{ status = 'unavailable' }
    if ([IO.File]::Exists($settingsPath)) {
        try {
            $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
            $selected = [ordered]@{}
            foreach ($key in @('cpus', 'memoryMiB', 'swapMiB', 'diskSizeMiB', 'virtualMachineManager', 'wslEngineEnabled')) {
                if ($settings.PSObject.Properties.Name -contains $key) {
                    $setting = $settings.$key
                    if ($setting -and $setting.PSObject.Properties.Name -contains 'value') { $setting = $setting.value }
                    if ($setting -is [bool] -or ($null -ne $setting -and [string]$setting -match '^[A-Za-z0-9_.-]{1,64}$')) { $selected[$key] = $setting }
                }
            }
            $report.docker.configured_limits = [ordered]@{ status = 'observed'; values = $selected; note = 'Configured values may differ from the running Engine.' }
        }
        catch { }
    }
    $dataFolder = Join-Path $env:LOCALAPPDATA 'Docker\wsl'
    $report.docker.host_storage = [ordered]@{ status = 'unavailable'; scope = 'Docker data parent on the Windows host; Linux filesystem free space is not measured' }
    if ([IO.Directory]::Exists($dataFolder)) {
        try {
            $dataDrive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($dataFolder))
            $report.docker.host_storage.status = 'observed_default_parent'
            $report.docker.host_storage.filesystem = $dataDrive.DriveFormat
            $report.docker.host_storage.free_bytes = $dataDrive.AvailableFreeSpace
        }
        catch { }
    }

    if ($extendedRequested) {
    $features = Read-HostQuery 'windows_virtualization_features' @'
Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform' OR Name='Microsoft-Windows-Subsystem-Linux'" -OperationTimeoutSec 8 | Select-Object Name,InstallState | ConvertTo-Json -Compress
'@
    $report.wsl.windows_features = $features.value
    $report.wsl.feature_query_status = $features.status
    }

    $report.network = [ordered]@{ status = 'not_run'; proxy_configured = [bool]($env:HTTPS_PROXY -or $env:HTTP_PROXY); checks = @() }
    if ($networkRequested) {
        $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $report.network.status = if ($curl) { 'performed' } else { 'unavailable' }
        if (-not $curl) { Add-Check 'network_reachability' 'unknown' 'The requested HTTPS check could not run because curl.exe is unavailable.' }
        if ($curl) {
            foreach ($url in @('https://registry-1.docker.io/v2/', 'https://packagemanager.posit.co/cran/')) {
                $n = Invoke-Probe ('https_' + $report.network.checks.Count) $curl.Source @('--head', '--silent', '--show-error', '--connect-timeout', '5', '--max-time', '10', '--output', 'NUL', '--write-out', '%{http_code}', $url) 12
                $httpStatus = 0; [void][int]::TryParse($n.stdout.Trim(), [ref]$httpStatus)
                $ok = $n.status -eq 'ok' -and $httpStatus -ge 100 -and $httpStatus -lt 600
                $report.network.checks += [ordered]@{ service = $(if ($url.Contains('docker.io')) { 'docker_registry' } else { 'posit_package_manager' }); status = $(if ($ok) { 'responded' } else { $n.status }); http_status = $httpStatus; note = 'An HTTP response, including 401, proves HTTPS reachability only; package access and authentication are not validated.' }
                if (-not $ok) { Add-Check 'network_reachability' 'warning' 'A requested HTTPS check failed.' }
            }
        }
    }
    $report.share_test = [ordered]@{ status = 'not_run' }
    if ($shareRequested) {
        if (-not $engineReady -or $report.docker.image.status -ne 'present') {
            $report.share_test.reason = 'A responsive local Engine and an existing image are required; nothing is downloaded.'
            Add-Check 'two_way_share' 'unknown' 'The requested sharing test was not run; a local Engine and existing image are required.'
        }
        else {
            $probe = Join-Path $projectRoot ('outputs\.ezr-diagnostic-' + $runId)
            $container = 'ezr-diagnostic-' + $runId
            $marker = 'ezr-diagnostic:' + $runId
            if ([IO.Directory]::Exists($probe)) { throw 'Diagnostic probe path already exists.' }
            [void][IO.Directory]::CreateDirectory($probe)
            [IO.File]::WriteAllText((Join-Path $probe 'host.txt'), $marker + "`n", (New-Object Text.UTF8Encoding($false)))
            $mountPath = $probe.Replace('"', '""')
            $test = Invoke-Probe 'two_way_share' $docker @('run', '--rm', '--pull=never', '--name', $container, '--label', ('org.ezr.diagnostic.run=' + $runId), '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--entrypoint', '/bin/sh', '--env', ('EZR_DIAG_PROBE=' + $marker), '--mount', ('type=bind,"source=' + $mountPath + '",target=/diag'), $report.docker.image.details.id, '-c', 'test "$(cat /diag/host.txt)" = "$EZR_DIAG_PROBE" && printf "%s\n" "$EZR_DIAG_PROBE" > /diag/container.txt') 30
            $back = Join-Path $probe 'container.txt'
            $passed = $test.status -eq 'ok' -and [IO.File]::Exists($back) -and [IO.File]::ReadAllText($back).Trim() -eq $marker
            $cleaned = $true
            if ($test.started -and $test.status -in @('timed_out', 'budget_exhausted')) {
                $owner = Invoke-Probe 'probe_owner' $docker @('container', 'inspect', $container, '--format', '{{index .Config.Labels "org.ezr.diagnostic.run"}}') 10 -Cleanup
                $cleaned = $owner.status -eq 'ok' -and $owner.stdout.Trim() -eq $runId
                if ($cleaned) { $cleanup = Invoke-Probe 'probe_cleanup' $docker @('container', 'rm', '--force', $container) 10 -Cleanup; $cleaned = $cleanup.status -eq 'ok' }
            }
            if ($cleaned) {
                foreach ($name in @('host.txt', 'container.txt')) { $file = Join-Path $probe $name; if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
                [IO.Directory]::Delete($probe)
            }
            $report.share_test = [ordered]@{ status = $(if ($passed) { 'passed' } else { 'failed' }); cleanup_completed = $cleaned; synthetic_data_only = $true }
            if (-not $cleaned) { $report.share_test.cleanup_container = $container }
            Add-Check 'two_way_share' $(if ($passed -and $cleaned) { 'pass' } else { 'fail' }) 'Only newly generated diagnostic files and the uniquely labelled probe container are used.'
        }
    }
}
catch { Add-Check 'diagnostic_internal' 'unknown' (Protect-Text $_.Exception.Message) }

$budgetExhausted = $report.probes.status -contains 'budget_exhausted'
if ($budgetExhausted) { Add-Check 'diagnostic_budget' 'unknown' 'Probe budget exhausted; acquired observations were retained and remaining probes were skipped.' }
$report.probe_budget = [ordered]@{ seconds = $probeBudgetSeconds; exhausted = $budgetExhausted; mode = $(if ($extendedRequested) { 'extended' } else { 'basic' }); scope = 'Child probes after PowerShell payload start. Shell/PowerShell startup, local file I/O, JSON save and bounded sharing cleanup are outside this limit.' }
$report.finished_at = [DateTime]::UtcNow.ToString('o')
$report.elapsed_seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
$failed = @($report.checks | Where-Object { $_.status -eq 'fail' }).Count -gt 0
$review = @($report.checks | Where-Object { $_.status -in @('unknown', 'warning') }).Count -gt 0
$report.overall = if ($failed) { 'preparation_needed' } elseif ($review) { 'review_needed' } else { 'prerequisites_met' }
$outputDirectory = Join-Path $projectRoot 'outputs'
$output = Join-Path $outputDirectory ('environment_check_' + [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff') + '_' + $runId.Substring(0, 8) + '.json')
$saved = $false
try {
    [void][IO.Directory]::CreateDirectory($outputDirectory)
    $report.storage.folder_writable = $true
    [IO.File]::WriteAllText($output, ($report | ConvertTo-Json -Depth 16) + "`n", (New-Object Text.UTF8Encoding($false)))
    $saved = $true
}
catch { Write-Host ('JSON save failed: ' + (Protect-Text $_.Exception.Message)) }
$overallMessages = if ($language -eq 'ja') { @{ prerequisites_met = '確認した起動条件を満たしています。'; preparation_needed = '起動前の準備が必要です。'; review_needed = '未確認または注意が必要な項目があります。' } } else { @{ prerequisites_met = 'Checked prerequisites are met.'; preparation_needed = 'Preparation is needed before launch.'; review_needed = 'Some items need review or remain unverified.' } }
Write-Host ($overallMessages[$report.overall])
foreach ($item in @($report.routine_records.entries)) { Write-RoutineResult $item }
foreach ($item in $report.checks) { Write-Host ('[' + $item.status + '] ' + $item.id + ': ' + $item.reason) }
if ($budgetExhausted) { Write-Host $(if ($language -eq 'ja') { '診断の待ち時間に達しました。取得済みの結果を保存し、残りは未確認としました。' } else { 'Probe budget reached. Acquired results were saved; remaining items are unverified.' }) }
$wslObservation = 'unknown'
if ($report.wsl) { $wslObservation = $report.wsl.wsl2_observation }
$wslObservationText = if ($language -eq 'ja') {
    @{ unknown = '未確認'; distribution_reported = '登録あり'; no_distribution_reported = '登録なし' }
} else {
    @{ unknown = 'unknown'; distribution_reported = 'reported'; no_distribution_reported = 'not reported' }
}
$wslObservationLabel = if ($language -eq 'ja') { 'WSL 2 ディストリビューションの登録状況' } else { 'WSL 2 distribution registration' }
Write-Host ($wslObservationLabel + ': ' + $wslObservationText[$wslObservation])
Write-Host 'EZR analysis: NOT TESTED / EZR解析は未検証'
if ($saved) { Write-Host ('JSON: ' + $output) }
if (-not $saved) { exit 1 }
if ($failed) { exit 2 }
if ($review) { exit 3 }
exit 0
