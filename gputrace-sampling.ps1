<#
.SYNOPSIS
    Headless per-source-line analysis of a .ngfx-gputrace capture's warp-state (PC) samples.

.DESCRIPTION
    The GUI's Source Positions view is the one thing ngfx's auto-export does not carry. It is
    still in the capture: the trace container holds the raw PC-sample buffers, the shader's
    SPIR-V (with OpLine records) and the driver's cubin (with .debug_line). This script runs
    the decode chain that turns those into a per-source-line sample table with a stall
    breakdown per line - no GUI, no .proto files, no packages:

        capture ─▶ WRPV sections ─▶ LZ4+XOR blobs ─▶ PC-sample buffers
                ─▶ per-PC histogram ─▶ .debug_line join ─▶ SPIR-V OpLine ─▶ (file, line)

    The Python side (gputrace-extract.py, pcs-samples.py, pcs-lines.py) is stdlib-only and
    needs no .proto compilation; this wrapper adds what the scripts deliberately lack - Python
    discovery, an internal-consistency gate, and a machine-readable report.

        .\gputrace-sampling.ps1 -Trace captures\exp\Sandbox_2026_10_17_01_05_04.ngfx-gputrace
        .\gputrace-sampling.ps1 -Trace ... -Json -Top 30        # for an agent to parse
        .\gputrace-sampling.ps1 -Trace ... -Compare gui\pcs_source.csv

.EVIDENCE CONTRACT
    Every number produced here is class `sampled`: it comes from the warp-state sampler, the
    same hardware source the GUI Top Stall table and the Source Positions view display. Two
    honest caveats travel with the data:

      * The raw samples are count-weighted; the GUI's panel values are time-weighted over the
        whole trace. Ranks and shapes compare; absolute percentages do not.
      * Samples whose PC falls outside the recovered shader .text window are dropped, and the
        attribution coverage is reported so the reader knows what fraction that was.

    The gate: when the capture's own auto-export (BASE\GPUTRACE_FRAME.xls, a headless
    artefact) sits beside the trace, the decoded raw-sample stall mix is cross-checked
    against the capture's own aggregate. The aggregate is cycle-weighted and the raw samples
    are count-weighted, so exact equality is not expected - but if the largest per-reason
    deviation exceeds 1.0 percentage points the decode is judged broken and the script exits
    non-zero rather than return data. Skip the run (and the check) with -SkipAggregateCheck.

.PARAMETER Trace
    The .ngfx-gputrace file to decode.

.PARAMETER WorkDir
    Where the decoded buffers, CSVs and manifest are written. Default
    gputrace-sampling\<trace file name> under the current directory. Files are overwritten in
    place; nothing is deleted.

.PARAMETER Top
    How many source lines to report (default 20). The full table is always written to
    <WorkDir>\source_lines.csv.

.PARAMETER Compare
    Optional: a GUI Source Positions export (CSV) to measure agreement against. Shape only,
    unless the export came from this same capture.

.PARAMETER Json
    Emit one JSON object and nothing else.

.PARAMETER Python
    Explicit python 3.x executable. Otherwise: $env:GPUTRACE_PYTHON, then `py -3`, then
    `python` on PATH.

.PARAMETER SkipAggregateCheck
    Skip the global stall histogram and the aggregate cross-check entirely (saves about a
    minute; the per-source-line table is still produced, unvalidated against the aggregate).

.EXAMPLE
    .\gputrace-sampling.ps1 -Trace captures\exp\Sandbox_2026_10_17_01_05_04.ngfx-gputrace -Json
#>
[CmdletBinding()]
param(
    [string]$Trace,
    [string]$WorkDir,
    [int]$Top = 20,
    [string]$Compare,
    [switch]$Json,
    [string]$Python,
    [switch]$SkipAggregateCheck
)

$ErrorActionPreference = 'Stop'
$TOOLS_DIR = $PSScriptRoot

# Exit codes: 0 ok; 1 failure (bad input, no python, decode error, or validation failed).

function Write-Fail {
    param([string]$Message, [hashtable]$Payload)
    if ($Json) {
        if ($Payload) { $Payload.error = $Message }
        else { $Payload = @{ error = $Message } }
        $Payload | ConvertTo-Json -Depth 8 -Compress | Write-Output
    } else {
        Write-Error $Message
    }
    exit 1
}

function Get-PyArgs {
    # Each candidate is an array: exe plus any leading fixed arguments (py.exe needs -3).
    param($Candidate, [string[]]$Rest)
    $fixed = @()
    if ($Candidate.Count -gt 1) { $fixed = $Candidate[1..($Candidate.Count - 1)] }
    return @($fixed) + @($Rest)
}

function Find-Python {
    param([string]$Explicit)
    # Each candidate is an array: exe plus any leading fixed arguments.
    $candidates = @()
    if ($Explicit) { $candidates += ,@($Explicit) }
    if ($env:GPUTRACE_PYTHON) { $candidates += ,@($env:GPUTRACE_PYTHON) }
    foreach ($name in @('py', 'python')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            if ($name -eq 'py') { $candidates += ,@($cmd.Source, '-3') }
            else { $candidates += ,@($cmd.Source) }
        }
    }
    foreach ($cand in $candidates) {
        try {
            # $ErrorActionPreference is Stop here; without the local override, PS 5.1 turns
            # the first redirected stderr line of a native call into a terminating error.
            $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $out = & $cand[0] (Get-PyArgs $cand @('--version')) 2>&1
            $ErrorActionPreference = $prevEap
            if ($LASTEXITCODE -eq 0 -and ("$out") -match 'Python 3\.') { return ,$cand }
        } catch { }
    }
    return $null
}

function Get-PythonExeLabel {
    param($Candidate)
    return ($Candidate -join ' ')
}

function Invoke-Python {
    # Runs python with the given arguments, returning { Code, Text }. Merged stdout+stderr:
    # the decode scripts narrate on stdout and crash on stderr, and both belong in the record.
    param([string[]]$PyArgs)
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $py[0] (Get-PyArgs $py $PyArgs) 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return @{ Code = $code; Text = ($out | ForEach-Object { "$_" }) -join "`n" }
}

if (-not $Trace) {
    Write-Fail 'no trace given: pass -Trace <path to .ngfx-gputrace>' @{ }
}
if (-not (Test-Path -LiteralPath $Trace -PathType Leaf)) {
    Write-Fail "trace not found: $Trace" @{ }
}
$Trace = (Resolve-Path -LiteralPath $Trace).Path
$pcsLines = Join-Path $TOOLS_DIR 'pcs-lines.py'
$pcsSamples = Join-Path $TOOLS_DIR 'pcs-samples.py'
foreach ($dep in @($pcsLines, $pcsSamples, (Join-Path $TOOLS_DIR 'gputrace-extract.py'))) {
    if (-not (Test-Path -LiteralPath $dep)) {
        Write-Fail "required script missing: $dep" @{ }
    }
}
$py = Find-Python -Explicit $Python
if ($null -eq $py) {
    Write-Fail ('no Python 3 found. This analysis decodes the capture container, which the ' +
                'PowerShell-only export engine does not do. Install Python 3 (stdlib only, no ' +
                'packages), or point -Python / $env:GPUTRACE_PYTHON at an existing python.exe.') @{ }
}

if (-not $WorkDir) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($Trace)
    $WorkDir = Join-Path (Join-Path (Get-Location).Path "gputrace-sampling") $stem
}
if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path

$sourceLinesCsv = Join-Path $WorkDir 'source_lines.csv'
$perPcLinesCsv = Join-Path $WorkDir 'source_lines_per_pc.csv'
$reasonsCsv = Join-Path $WorkDir 'stall_reasons.csv'
$perPcStallsCsv = Join-Path $WorkDir 'per_pc_stalls.csv'

# ---- stage 1: decode + per-source-line join ----------------------------------
$linesArgs = @($pcsLines, '--capture', $Trace, '--workdir', $WorkDir,
               '--out', $sourceLinesCsv, '--per-pc', $perPcLinesCsv, '--top', [string]$Top)
if ($Compare) {
    if (-not (Test-Path -LiteralPath $Compare -PathType Leaf)) {
        Write-Fail "compare export not found: $Compare" @{ }
    }
    $linesArgs += @('--verify', (Resolve-Path -LiteralPath $Compare).Path)
}
$linesRun = Invoke-Python $linesArgs
$linesText = $linesRun.Text
if ($linesRun.Code -ne 0) {
    Write-Fail "decode failed (pcs-lines.py exit $($linesRun.Code))" @{ stdoutTail = (($linesText -split "`n") | Select-Object -Last 12) -join "`n" }
}

# ---- stage 2: global stall histogram + aggregate cross-check -----------------
$validation = [ordered]@{
    check = 'aggregate-cross-check'
    meaning = 'decoded raw-sample stall mix vs the capture''s own GPUTrace.PCSampler.* aggregate'
    thresholdPp = 1.0
}
$aggregateXls = Join-Path (Split-Path -Parent $Trace) 'BASE\GPUTRACE_FRAME.xls'
$runSamples = -not $SkipAggregateCheck
$deviation = $null
$worstReason = $null
if ($runSamples) {
    if (Test-Path -LiteralPath $aggregateXls) {
        $samplesArgs = @($pcsSamples, (Join-Path $WorkDir 'pcbuf'),
                         '--csv', $reasonsCsv, '--per-pc', $perPcStallsCsv,
                         '--top', '0', '--verify', $aggregateXls)
        $samplesRun = Invoke-Python $samplesArgs
        $samplesText = $samplesRun.Text
        if ($samplesRun.Code -ne 0) {
            Write-Fail "stall histogram failed (pcs-samples.py exit $($samplesRun.Code))" @{ stdoutTail = (($samplesText -split "`n") | Select-Object -Last 12) -join "`n" }
        }
        $m = [regex]::Match($samplesText, 'largest deviation : ([\d.]+) percentage points\s+\((.+?)\)')
        if ($m.Success) {
            $deviation = [double]$m.Groups[1].Value
            $worstReason = $m.Groups[2].Value
        }
        if ($null -ne $deviation -and $deviation -gt 1.0) {
            $validation.status = 'FAIL'
            $validation.maxDeviationPp = $deviation
            $validation.worstReason = $worstReason
            $validation.aggregateFile = $aggregateXls
            $validation['detail'] = ('the decoded sample mix diverges from the capture''s own ' +
                                     'aggregate beyond the count-weighted-vs-cycle-weighted envelope; ' +
                                     'the decode is treated as broken and the table is withheld')
            Write-Fail "aggregate cross-check FAILED: max deviation $deviation pp ($worstReason)" @{ validation = $validation }
        }
        $validation.status = 'PASS'
    } else {
        $validation.status = 'SKIPPED'
        $validation['detail'] = "no aggregate export next to the trace (looked for $aggregateXls); the table is returned unchecked against the capture's own aggregate"
    }
} else {
    $validation.status = 'SKIPPED'
    $validation['detail'] = '-SkipAggregateCheck: the global stall histogram and the cross-check did not run'
}
if ($null -ne $deviation) {
    $validation.maxDeviationPp = $deviation
    $validation.worstReason = $worstReason
    $validation.aggregateFile = $aggregateXls
}

# ---- stage 3: summarise ------------------------------------------------------
$totals = [ordered]@{ }
$m = [regex]::Match($linesText, '(\d+) buffer\(s\), ([\d,]+) samples, (\d+) distinct PCs')
if ($m.Success) {
    $totals.buffers = [int]$m.Groups[1].Value
    $totals.samples = [long]($m.Groups[2].Value -replace ',', '')
    $totals.distinctPCs = [int]$m.Groups[3].Value
}
$m = [regex]::Match($linesText, 'base\s+: 0x([0-9a-f]+)\s+covers (\d+) PCs, ([\d,]+) samples \(([\d.]+) %\)')
if ($m.Success) {
    $totals.textBase = '0x' + $m.Groups[1].Value
    $totals.windowCoveragePct = [double]$m.Groups[4].Value
}
$m = [regex]::Match($linesText, 'attributed\s+: ([\d,]+) samples \(([\d.]+) % of total\) to (\d+) distinct')
if ($m.Success) {
    $totals.attributedSamples = [long]($m.Groups[1].Value -replace ',', '')
    $totals.attributedPct = [double]$m.Groups[2].Value
    $totals.distinctSourceLines = [int]$m.Groups[3].Value
}

$sourceLines = @()
if (Test-Path -LiteralPath $sourceLinesCsv) {
    $rows = @(@(Import-Csv -LiteralPath $sourceLinesCsv))
    if ($null -eq $totals.distinctSourceLines) { $totals.distinctSourceLines = $rows.Count }
    foreach ($row in ($rows | Select-Object -First $Top)) {
        $sourceLines += [ordered]@{
            file = $row.'Source File'
            line = [int]$row.'Line'
            samples = [long]$row.'Total Samples'
            topStall1 = $row.'Top Stall #1 (Type)'
            topStall1Samples = [long]$row.'Top Stall #1 (Samples)'
            topStall2 = $row.'Top Stall #2 (Type)'
            topStall2Samples = [long]$row.'Top Stall #2 (Samples)'
        }
    }
}

$compareResult = $null
if ($Compare) {
    $compareResult = [ordered]@{ against = (Resolve-Path -LiteralPath $Compare).Path }
    $m = [regex]::Match($linesText, 'GUI lines reported : (\d+)\s+reproduced : (\d+)')
    if ($m.Success) {
        $compareResult.guiLines = [int]$m.Groups[1].Value
        $compareResult.reproduced = [int]$m.Groups[2].Value
    }
    $m = [regex]::Match($linesText, 'identical counts\s+: (\d+) / (\d+) lines')
    if ($m.Success) { $compareResult.identicalCounts = [int]$m.Groups[1].Value }
    $m = [regex]::Match($linesText, 'Spearman rho\s+: ([\d.]+)')
    if ($m.Success) { $compareResult.spearmanRho = [double]$m.Groups[1].Value }
    $m = [regex]::Match($linesText, 'top-20 overlap\s+: (\d+)/(\d+)')
    if ($m.Success) { $compareResult.top20Overlap = [int]$m.Groups[1].Value }
    $m = [regex]::Match($linesText, 'sum \|delta\|\s+: ([\d,]+) samples \(([\d.]+) %')
    if ($m.Success) {
        $compareResult.residualSamples = [long]($m.Groups[1].Value -replace ',', '')
        $compareResult.residualPct = [double]$m.Groups[2].Value
    }
}

$notes = @(
    'Evidence class: sampled - warp-state (PC) samples, the same hardware source as the GUI Top Stall table and Source Positions view.',
    'Raw samples are count-weighted; GUI panel values are time-weighted over the whole trace. Compare ranks and shapes, not absolute percentages.',
    ("Attribution: {0}% of samples landed inside the recovered shader .text window; the rest have no source line and appear in no row." -f $(if ($null -ne $totals.attributedPct) { $totals.attributedPct } else { '?' }))
)

if ($Json) {
    [ordered]@{
        trace = $Trace
        traceBytes = (Get-Item -LiteralPath $Trace).Length
        workDir = $WorkDir
        python = Get-PythonExeLabel $py
        evidenceClass = 'sampled'
        totals = $totals
        validation = $validation
        sourceLines = $sourceLines
        compare = $compareResult
        artifacts = [ordered]@{
            sourceLinesCsv = $sourceLinesCsv
            perPcLinesCsv = $perPcLinesCsv
            stallReasonsCsv = $(if ($runSamples -and (Test-Path -LiteralPath $reasonsCsv)) { $reasonsCsv } else { $null })
            perPcStallsCsv = $(if ($runSamples -and (Test-Path -LiteralPath $perPcStallsCsv)) { $perPcStallsCsv } else { $null })
        }
        notes = $notes
    } | ConvertTo-Json -Depth 8 | Write-Output
    exit 0
}

# Text mode: the decode chain's own narration, then the wrapper's summary.
$linesText | Write-Output
if ($runSamples -and $samplesText) { $samplesText | Write-Output }
Write-Output ''
Write-Output 'per-source-line analysis:'
Write-Output ("  trace            : {0}" -f $Trace)
Write-Output ("  validation       : {0}{1}" -f $validation.status, $(if ($null -ne $deviation) { " (max {0} pp, {1})" -f $deviation, $worstReason } else { '' }))
Write-Output ("  full table       : {0}" -f $sourceLinesCsv)
Write-Output ("  per-PC lines     : {0}" -f $perPcLinesCsv)
if ($runSamples -and (Test-Path -LiteralPath $reasonsCsv)) {
    Write-Output ("  stall reasons    : {0}" -f $reasonsCsv)
    Write-Output ("  per-PC stalls    : {0}" -f $perPcStallsCsv)
}
if ($Compare) {
    Write-Output ("  compare          : {0}" -f $compareResult.against)
}
Write-Output 'JSON output: re-run with -Json.'
exit 0
