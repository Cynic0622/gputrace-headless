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
#   * The application has to end on its own - nothing here bounds it. The profile's appTimeoutArgs
#     says how to ask for a lifetime (for example "-timeout {seconds}"); a profile that declares
#     none is traced exactly as written, and the capture then waits as long as the application runs.

param(
    # Required: profile name (resolved under .\profiles) or a path to a profile JSON.
    [string]$Profile = '',
    [int]$StartAfterFrames = 600,
    [int]$Frames = 60,
    [int]$MetricSetId = 1,          # Ada: 0 = Async Compute Triage, 1 = Throughput Metrics, 2 = Top-Level
    [string]$MetricSetName = 'Throughput Metrics',  # used by -ShaderProfiler, which goes through JSON
    [int]$AppSeconds = 25,          # seconds handed to the profile's appTimeoutArgs template
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
    # Keep whatever is already in a variant's trace directory. Without this the directory is moved
    # aside, never deleted: the previous run's .ngfx-gputrace is the only oracle for the GUI, and
    # losing it silently costs a full re-capture (that is how the 2026-10-14 reference was lost).
    [switch]$KeepExisting,
    # Trace only the named profile variants. A shader-profiler capture is minutes per variant and
    # the variants differ only in a shader arm, so re-running all of them to answer one question
    # about a single arm is wasted machine time.
    [string[]]$Variant = @(),
    # Where the target application lives. Normally left to the profile, whose workDir is resolved
    # against the profile file so a profile can point at a checkout next to itself; passing this
    # overrides that, and the current directory is the last resort.
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

# The profile supplies the defaults, and anything passed explicitly wins - which is what the MCP
# server relies on when it forwards a caller's overrides. Before this, the profile overwrote -Exe
# outright and beat -AppSeconds, so both knobs were silently dead on any profile that set them.
$profileWorkDir = Get-ProfileField $profileData 'workDir' ''
$profileExe = Get-ProfileField $profileData 'exe' ''

# A profile still carrying the template's placeholders is named here, before any path API touches
# it: IsPathRooted rejects the angle brackets outright on Windows, so the check has to come first
# or it surfaces as an unrelated "illegal characters in path".
$placeholder = @($profileWorkDir, $profileExe) | Where-Object { $_ -match '<[^>]+>' } | Select-Object -First 1
if ($placeholder) {
    throw "profile '$Profile' still holds a template placeholder ('$placeholder'). Copy profiles\example.json, fill it in, and pass that file to -Profile."
}

if ($Exe -ne '') {
    $appPath = $Exe
} else {
    $appPath = $profileExe
}

# The profile's workDir is resolved against the profile file, not against this script - which no
# longer sits inside the traced repository - so a profile can point at a checkout next to itself.
# Made absolute because the elevated relaunch below forwards it verbatim and because the relative
# exe/outDir below are joined onto it.
if ($WorkDir -eq '') {
    if ($profileWorkDir -eq '') {
        $WorkDir = (Get-Location).Path
    } elseif ([System.IO.Path]::IsPathRooted($profileWorkDir)) {
        $WorkDir = $profileWorkDir
    } else {
        $WorkDir = Join-Path (Split-Path -Parent $profilePath) $profileWorkDir
    }
}

$architecture = Get-ProfileField $profileData 'architecture' 'Ada'
$baseAppArgs = Get-ProfileField $profileData 'appArgs' ''
if ($AppArgs -ne '') { $baseAppArgs = $AppArgs }
# -AppSeconds has a non-empty default, so "was it passed explicitly?" needs PSBoundParameters
# rather than a sentinel value.
if (-not $PSBoundParameters.ContainsKey('AppSeconds') -and $profileData.PSObject.Properties['appSeconds']) {
    $AppSeconds = [int]$profileData.appSeconds
}

$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
if (-not [System.IO.Path]::IsPathRooted($appPath)) { $appPath = Join-Path $WorkDir $appPath }
if (-not (Test-Path -LiteralPath $appPath)) {
    throw "application not found at '$appPath'; build the target first or fix the profile"
}

$outputDir = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $WorkDir $OutDir }

# The trace targets: one per profile variant. Names become directory names, so they are
# sanitized here.
$targets = @()
foreach ($v in @($profileData.variants)) {
    $name = ($v.name -replace '[\\/:*?"<>|]', '_')
    $targets += [pscustomobject]@{
        Name = $name
        Args = ((@($baseAppArgs, $v.args) | Where-Object { $_ }) -join ' ').Trim()
    }
}
if ($targets.Count -eq 0) { throw 'no trace targets (empty variants list in the profile)' }

# Applied after the profile's variants are read so the error for a typo names what was available.
# Split on commas as well as accepting an array: the elevated relaunch passes the whole list as one
# -Variant argument, because Windows PowerShell does not quote ArgumentList entries individually.
if ($Variant.Count -gt 0) {
    $wanted = @($Variant | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $available = @($targets | ForEach-Object { $_.Name })
    $unknown = @($wanted | Where-Object { $_ -notin $available })
    if ($unknown.Count -gt 0) {
        throw "-Variant '$($unknown -join ', ')' is not in the profile; available: $($available -join ' ')"
    }
    $targets = @($targets | Where-Object { $_.Name -in $wanted })
}

# How the application is asked to stop, if it can be asked at all.
#
# This used to be an unconditional "--timeout <n>" appended to every target, which quietly
# required every traced application to accept that exact flag. Nothing here bounds a run by
# itself - there is no watchdog on the application process - so an application that ignored the
# flag ran forever and took the capture with it. The profile now declares the template, and a
# profile that declares none is left untouched.
$appTimeoutArgs = Get-ProfileField $profileData 'appTimeoutArgs' ''
if ($appTimeoutArgs -eq '') {
    Write-Warning ('profile declares no appTimeoutArgs, so the run length is entirely up to the ' +
                   'application. Set it - for example "-timeout {seconds}" - if the application ' +
                   'takes a lifetime flag; the capture waits for the application either way.')
} else {
    foreach ($t in $targets) {
        # The template is a default, not a rule: a target that already spells the flag out itself
        # is left as written.
        $flag = ($appTimeoutArgs -split '\s+')[0]
        if ($flag -and $t.Args -notmatch [regex]::Escape($flag)) {
            $t.Args = "$($t.Args) $($appTimeoutArgs -replace '\{seconds\}', "$AppSeconds")".Trim()
        }
    }
}

# Environment variables the profile wants the target to see, applied to the traced process below.
#
# The usual reason to declare one is to force a diagnostic switch OFF: a switch that changes how
# the driver compiles shaders would otherwise pollute the trace, and the point of a trace is to see
# the code as it normally compiles. Declared by the profile rather than hardcoded here, so this
# tool never has to know any application's private variable names.
$profileEnvPairs = @()
$profileEnv = Get-ProfileField $profileData 'env' $null
if ($null -ne $profileEnv) {
    foreach ($property in $profileEnv.PSObject.Properties) {
        $profileEnvPairs += [pscustomobject]@{ Name = $property.Name; Value = [string]$property.Value }
    }
}

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
    if ($profileEnvPairs.Count -gt 0) {
        Write-Host ("env:     {0}" -f (($profileEnvPairs | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '))
    }
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
    if ($KeepExisting) { $relaunchArgs += '-KeepExisting' }
    if ($Variant.Count -gt 0) { $relaunchArgs += @('-Variant', (Quote-Argument ($Variant -join ','))) }

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

# Applied here rather than earlier on purpose: whichever process actually runs the capture - this
# one, or the elevated relaunch above - sets the variables for its own children. Timing runs must
# not carry the target's pipeline capture flags, which can change how the driver compiles.
foreach ($pair in $profileEnvPairs) {
    Set-Item -Path "Env:$($pair.Name)" -Value $pair.Value
    Write-Host ("env: {0}={1}" -f $pair.Name, $pair.Value)
}

$failed = 0
try {
    Write-Host "Targets to trace: $($targets.Count) [$(($targets | ForEach-Object { $_.Name }) -join ' ')]"
    foreach ($t in $targets) {
        $traceDir = Join-Path $outputDir $t.Name
        try {
            # Moved aside rather than deleted. This directory holds the only copy of the previous
            # capture, and a trace takes minutes to produce; a run that failed before writing a new
            # one must not also destroy the reference it was going to be compared against.
            if (Test-Path -LiteralPath $traceDir) {
                if ($KeepExisting) {
                    Write-Warning "$($t.Name): keeping the existing $traceDir; ngfx may overwrite files in it"
                } else {
                    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $aside = "$traceDir.prev-$stamp"
                    Move-Item -LiteralPath $traceDir -Destination $aside
                    Write-Host "previous capture moved aside: $aside"
                }
            }
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
