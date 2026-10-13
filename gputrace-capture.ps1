# Captures GPU Traces of a target application, unattended, and auto-exports all metrics -
# including the warp-state (PC) sampling data behind the Nsight Graphics GUI "Top Stall" table,
# which the plain CLI never collects. Reads a profile (JSON) that describes the target:
# executable, work directory, architecture, base application arguments and the named variants
# to trace (one trace per variant). See profiles\ntc-benchmark.json for a complete example.
#
#     .\gputrace-capture.ps1 -Profile ntc-benchmark              # one trace per profile variant
#     .\gputrace-capture.ps1 -Profile ntc-benchmark -ShaderProfiler -Frames 8
#     .\gputrace-capture.ps1 -DryRun                             # print what would run
#
# Why this may need elevation:
#   NVIDIA only hands GPU performance counters to an elevated process unless counter access is
#   opened to all users (NVIDIA Control Panel > Developer > Manage GPU Performance Counters;
#   on drivers where the legacy registry key still works, that is
#   HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak\RmProfilingAdminOnly = 0).
#   Without access, ngfx launches the application, connects, and then fails with
#
#       TARGET ERROR: GPU Performance Counters unavailable.
#
#   so the script probes first and relaunches itself elevated when needed (one UAC prompt covers
#   all variants). unlock-counters.ps1 requests that one-time approval.
#
# Notes:
#   * The trace is bounded by frames, not by duration: bounding by duration silently disables
#     multi-pass metrics ("Multi-pass metrics are only supported if the trace end condition is
#     frames or if the underlying application is a replayer").
#   * Bounding by frames also lets multi-pass metrics and the real-time shader profiler be
#     requested together, which is what -ShaderProfiler does. Warp-state sampling (the sampled
#     Top Stall data) engages via the real-time-shader-profiler option - see the README for the
#     full mechanism and the two configuration pitfalls (BOM, per-arch key scoping).
#   * The exported .xls files are tab-separated text; read them with .\gputrace-report.ps1.

param(
    # Required: profile name (resolved under .\profiles) or a path to a profile JSON.
    [string]$Profile = '',
    [int]$StartAfterFrames = 600,
    [int]$Frames = 60,
    [int]$MetricSetId = 1,          # Ada: 0 = Async Compute Triage, 1 = Throughput Metrics, 2 = Top-Level
    [string]$MetricSetName = 'Throughput Metrics',  # used by -ShaderProfiler, which goes through JSON
    [int]$AppSeconds = 25,          # how long each application run is allowed to live
    [string]$Exe = '',              # overrides the profile executable
    [string]$AppArgs = '',          # overrides the profile base application arguments
    [string]$OutDir = 'gputrace',
    [string]$LogFile = (Join-Path ([System.IO.Path]::GetTempPath()) 'gputrace-capture.log'),
    [switch]$ShaderProfiler,
    [switch]$MultiPassMetrics,
    # Carries pc-samples-per-pm-interval-per-sm in the per-arch config. 2026-10-11: the earlier
    # failure was a truncated key name (pc-samples-per-pm-interval, no -per-sm suffix - an unknown
    # key is silently ignored). The corrected name matches the option table in WarpVizPlugin.dll;
    # whether it engages sampling is verified by the export gaining sampled data (open in GUI:
    # Shader Pipelines must show non-zero samples, or REPRO_INFO must stop saying Disabled).
    [switch]$WarpStateSampling,
    [switch]$DryRun,
    # Where the target application lives. The profile's own workDir takes precedence (a relative
    # value there is resolved against the profile file, so a profile can point at a checkout next
    # to itself); this parameter is the fallback, and the current directory the last resort.
    [string]$WorkDir = '',
    # Nsight Graphics' ngfx.exe, or the directory holding it. Only needed when the automatic
    # search misses - an install on an unusual path, or several versions side by side.
    [string]$NgfxPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ngfx.exe lives wherever Nsight Graphics was installed - see gputrace-common.ps1 for the search
# order and the -NgfxPath / GPUTRACE_NGFX overrides.
. (Join-Path $PSScriptRoot 'gputrace-common.ps1')

function Test-Elevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# GeForce hands GPU performance counters only to elevated processes unless this key is 0. Set it
# once with tools/unlock-counters.ps1 and every trace runs unattended - no UAC, no relaunch.
# The driver only honours the key after a reload (reboot), so the registry alone is not proof:
# Test-CountersUsable probes with a one-frame capture before trusting it.
function Test-CountersUnlocked {
    $value = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak' `
        -Name RmProfilingAdminOnly -ErrorAction SilentlyContinue
    return ($null -ne $value -and $value.RmProfilingAdminOnly -eq 0)
}

function Test-CountersUsable {
    param([string]$Ngfx, [string]$AppPath, [string]$WorkDir, [string]$ProbeArgs)
    if (Test-Elevated) { return $true }
    if (-not (Test-CountersUnlocked)) { return $false }

    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) 'gputrace-probe'
    if (Test-Path $probeDir) { Remove-Item $probeDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
    $out = & $Ngfx @(
        '--activity', 'GPU Trace Profiler', '--exe', $AppPath, '--dir', $WorkDir,
        '--args', $ProbeArgs,
        '--output-dir', $probeDir, '--architecture', $architecture,
        '--start-after-frames', '50', '--limit-to-frames', '1', '--metric-set-id', '1'
    ) 2>&1
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($text -match 'GPU Performance Counters unavailable') {
        Write-Host 'counters locked despite the registry key - the driver needs the reboot to honour it'
        return $false
    }
    return $true
}

# Per-architecture options travel in a JSON file; there is no plain switch for the shader profiler.
# The file is a top-level array, so it is written by hand instead of through ConvertTo-Json (which
# drops the brackets around a single-element array on Windows PowerShell).
#
# The metric set is named rather than numbered: a "metric-set-id" in this file was ignored on the
# first attempt and the run fell back to set 0 (Async Compute Triage), which quietly changed which
# metrics the export contained.
function Write-ArchConfig {
    param([string]$MetricSetName, [bool]$MultiPass, [bool]$ShaderProfiler, [bool]$WarpStateSampling)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) 'gputrace-arch.json'
    # Hand-built rather than ConvertTo-Json: a single-element array loses its brackets when piped
    # through the formatter on Windows PowerShell. Written without a BOM: ngfx's parser rejects a
    # preamble - and a silently ignored config once made a run fall back to metric set 0.
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('[')
    $lines.Add('  {')
    $lines.Add('    "architecture": "Ada",')
    $lines.Add('    "metric-set-name": "' + $MetricSetName + '",')
    $lines.Add('    "multi-pass-metrics": "' + $MultiPass.ToString().ToLower() + '",')
    # The full option name carries the -per-sm suffix (verified against the option table inside
    # WarpVizPlugin.dll); without the suffix the key is unknown and silently ignored.
    if ($WarpStateSampling) { $lines.Add('    "pc-samples-per-pm-interval-per-sm": 10,') }
    $lines.Add('    "real-time-shader-profiler": "' + $ShaderProfiler.ToString().ToLower() + '"')
    $lines.Add('  }')
    $lines.Add(']')
    [System.IO.File]::WriteAllText($path, ($lines -join "`r`n") + "`r`n",
        (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# ngfx writes its .ngfx-gputrace next to the Nsight documents by default, whatever --output-dir says,
# so report what appeared there rather than only looking in our own folder.
function Show-NewTraces {
    param([datetime]$Since)

    $documents = Join-Path $env:USERPROFILE 'Documents\NVIDIA Nsight Graphics'
    if (-not (Test-Path -LiteralPath $documents)) { return }

    $recent = Get-ChildItem -LiteralPath $documents -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime
    if ($recent) {
        Write-Host ''
        Write-Host "New files under ${documents}:"
        $recent | ForEach-Object { Write-Host ("  {0,14:N0}  {1}" -f $_.Length, $_.Name) }
    }
}

$ngfx = Find-Ngfx -Explicit $NgfxPath

# A profile is required: it describes the capturable target (exe, work dir, architecture, app
# args, variants). Names resolve under .\profiles, or pass an absolute/relative JSON path.
$profilePath = $Profile
if (-not [System.IO.Path]::IsPathRooted($profilePath)) {
    $bundled = Join-Path $PSScriptRoot "profiles\$profilePath"
    if (Test-Path -LiteralPath "$bundled.json") { $profilePath = "$bundled.json" }
}
if (-not (Test-Path -LiteralPath $profilePath)) { throw "profile not found: $Profile (see profiles\)" }
$profileData = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json

# Reads an optional profile field: Set-StrictMode errors on missing PSCustomObject properties.
function Get-ProfileField {
    param($Data, [string]$Name, $Default)
    $prop = $Data.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

$appPath = $Exe
$architecture = 'Ada'
$baseAppArgs = ''

# The profile describes its own target, so its workDir wins over the parameter and a relative
# value there is resolved against the profile file - not against this script, which no longer
# sits inside the traced repository. Made absolute here because the elevated relaunch below
# forwards it verbatim and because the relative exe/outDir below are joined onto it.
$profileWorkDir = Get-ProfileField $profileData 'workDir' ''
if ($profileWorkDir -ne '') {
    if ([System.IO.Path]::IsPathRooted($profileWorkDir)) {
        $WorkDir = $profileWorkDir
    } else {
        $WorkDir = Join-Path (Split-Path -Parent $profilePath) $profileWorkDir
    }
} elseif ($WorkDir -eq '') {
    $WorkDir = (Get-Location).Path
}
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)

$appPath = Get-ProfileField $profileData 'exe' ''
$architecture = Get-ProfileField $profileData 'architecture' 'Ada'
$baseAppArgs = Get-ProfileField $profileData 'appArgs' ''
if ($profileData.PSObject.Properties['appSeconds']) { $AppSeconds = [int]$profileData.appSeconds }
if ($AppArgs -ne '') { $baseAppArgs = $AppArgs }

if (-not [System.IO.Path]::IsPathRooted($appPath)) { $appPath = Join-Path $WorkDir $appPath }
if (-not (Test-Path -LiteralPath $appPath)) {
    throw "application not found at '$appPath'; build the target first or fix the profile"
}

$outputDir = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $WorkDir $OutDir }

# The trace targets: one per profile variant. Names become directory names, so they are
# sanitized here. The app timeout is appended once - every target needs it to bound the run,
# whatever the app (skip when the app args already carry one).
$targets = @()
foreach ($v in @($profileData.variants)) {
    $name = ($v.name -replace '[\\/:*?"<>|]', '_')
    $targets += [pscustomobject]@{
        Name = $name
        Args = ((@($baseAppArgs, $v.args) | Where-Object { $_ }) -join ' ').Trim()
    }
}
foreach ($t in $targets) {
    if ($t.Args -notmatch '--timeout\s') { $t.Args = "$($t.Args) --timeout $AppSeconds".Trim() }
}
if ($targets.Count -eq 0) { throw 'no trace targets (empty variants list in the profile)' }

function Get-NgfxArgs {
    param([string]$Name, [string]$AppArgs, [string]$TraceDir)

    # Not $args: that is an automatic variable, and assigning to it inside a function corrupts it.
    $ngfxCommandArgs = @(
        '--activity', 'GPU Trace Profiler',
        '--exe', $appPath,
        '--dir', $WorkDir,
        '--args', $AppArgs,
        '--output-dir', $TraceDir,
        '--architecture', $architecture,
        '--start-after-frames', "$StartAfterFrames",
        '--limit-to-frames', "$Frames",
        '--auto-export'
    )

    if ($ShaderProfiler -or $WarpStateSampling) {
        # The real-time shader profiler IS the SM hardware sampling profiler - the data behind the
        # GUI's Top Stall / Source Positions views (option help text, WarpVizPlugin.dll). General
        # options (multi-pass, RTS) are ignored inside the per-arch config - only metric-set keys
        # bind there - so they go through CLI flags. Verified 2026-10-11.
        $ngfxCommandArgs += @('--metric-set-id', "$MetricSetId", '--multi-pass-metrics',
            '--real-time-shader-profiler')
    } else {
        $ngfxCommandArgs += @('--metric-set-id', "$MetricSetId")
        if ($MultiPassMetrics) { $ngfxCommandArgs += '--multi-pass-metrics' }
    }
    return $ngfxCommandArgs
}

if ($DryRun) {
    Write-Host "ngfx:    $ngfx"
    Write-Host "working: $WorkDir"
    Write-Host "output:  $outputDir"
    foreach ($t in $targets) {
        Write-Host ''
        Write-Host "$($t.Name) -> $(Join-Path $outputDir $t.Name)"
        $ngfxCommandArgs = Get-NgfxArgs -Name $t.Name -AppArgs $t.Args -TraceDir (Join-Path $outputDir $t.Name)
        for ($i = 0; $i -lt $ngfxCommandArgs.Count; ++$i) { Write-Host ("  [{0,2}] {1}" -f $i, $ngfxCommandArgs[$i]) }
    }
    exit 0
}

if (-not (Test-Elevated) -and -not (Test-CountersUsable -Ngfx $ngfx -AppPath $appPath -WorkDir $WorkDir -ProbeArgs $targets[0].Args)) {
    Write-Host 'GPU performance counters need an elevated process; relaunching with a UAC prompt...'
    Write-Host '(one-time fix: run tools/unlock-counters.ps1, then reboot, to remove this prompt forever)'

    # An elevated process gets its own console, and that console closes with it, so without the
    # transcript a failed run leaves nothing to look at.
    Remove-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
    $startedAt = Get-Date

    # Windows PowerShell joins -ArgumentList with spaces and never quotes, so a value containing
    # a space has to carry its own quotes.
    function Quote-Argument { param([string]$Value) return '"' + $Value + '"' }

    $relaunchArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Argument $PSCommandPath),
        '-Profile', (Quote-Argument $Profile),
        '-StartAfterFrames', $StartAfterFrames, '-Frames', $Frames,
        '-MetricSetId', $MetricSetId, '-MetricSetName', (Quote-Argument $MetricSetName),
        '-AppSeconds', $AppSeconds,
        '-Exe', (Quote-Argument $appPath), '-OutDir', (Quote-Argument $outputDir),
        '-WorkDir', (Quote-Argument $WorkDir), '-LogFile', (Quote-Argument $LogFile)
    )
    if ($AppArgs -ne '') { $relaunchArgs += @('-AppArgs', (Quote-Argument $AppArgs)) }
    # Carried across so the elevated run resolves the same ngfx rather than searching again.
    if ($NgfxPath -ne '') { $relaunchArgs += @('-NgfxPath', (Quote-Argument $NgfxPath)) }
    if ($ShaderProfiler) { $relaunchArgs += '-ShaderProfiler' }
    if ($MultiPassMetrics) { $relaunchArgs += '-MultiPassMetrics' }
    if ($WarpStateSampling) { $relaunchArgs += '-WarpStateSampling' }

    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs -Verb RunAs -PassThru
    $process.WaitForExit()

    if (Test-Path -LiteralPath $LogFile) {
        Write-Host ''
        Write-Host "--- elevated run output ($LogFile) ---"
        Get-Content -LiteralPath $LogFile | Select-Object -Last 40 | ForEach-Object { Write-Host "  $_" }
        Write-Host "  (full transcript: $LogFile)"
    } else {
        Write-Host 'No transcript was produced, so the elevated run never started (UAC declined?).'
    }

    Write-Host ''
    Write-Host ("Elevated run exited with {0}" -f $process.ExitCode)
    Show-NewTraces -Since $startedAt
    exit $process.ExitCode
}

Start-Transcript -Path $LogFile -Force | Out-Null
$startedAt = Get-Date

# Timing runs must not carry the pipeline capture flags, which can change how the driver compiles.
$env:DSH_DUMP_PIPELINES = '0'

$failed = 0
try {
    Write-Host "Targets to trace: $($targets.Count) [$(($targets | ForEach-Object { $_.Name }) -join ' ')]"
    foreach ($t in $targets) {
        $traceDir = Join-Path $outputDir $t.Name
        try {
            if (Test-Path -LiteralPath $traceDir) { Remove-Item -LiteralPath $traceDir -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $traceDir | Out-Null

            Write-Host ''
            Write-Host "=== $($t.Name) -> $traceDir ($Frames frame(s) after $StartAfterFrames) ==="
            $started = Get-Date
            & $ngfx @(Get-NgfxArgs -Name $t.Name -AppArgs $t.Args -TraceDir $traceDir)
            $code = $LASTEXITCODE
            Write-Host ("ngfx exited with {0} after {1:N1}s" -f $code, ((Get-Date) - $started).TotalSeconds)
            if ($code -ne 0) { $failed++ }
        } catch {
            # One target failing must not silently end the sweep; the next target still has a
            # chance, and the reason has to reach the transcript.
            Write-Host "$($t.Name): FAILED - $($_.Exception.Message)"
            $failed++
        }
    }
} finally {
    # The transcript is what the non-elevated parent reads back, so it has to survive a failure.
    Stop-Transcript | Out-Null
}

Write-Host ''
Write-Host "Files under ${outputDir}:"
Get-ChildItem -LiteralPath $outputDir -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object FullName | ForEach-Object {
        Write-Host ("  {0,12:N0}  {1}" -f $_.Length, $_.FullName.Substring($outputDir.Length))
    }

Show-NewTraces -Since $startedAt

exit $(if ($failed -gt 0) { 1 } else { 0 })
