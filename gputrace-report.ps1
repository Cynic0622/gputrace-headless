<#
.SYNOPSIS
    Reads and validates Nsight Graphics GPU Trace exports, and compares traces.

.DESCRIPTION
    Drives nothing: gputrace-capture.ps1 produces the traces, this reads them. ngfx's --auto-export
    writes tab-separated files under <trace>/BASE despite the .xls names, and GPUTRACE_FRAME.xls is
    transposed - one row per metric, first cell the name, remaining cells one value per traced frame.
    Also read: D3DPERF_EVENTS.xls (per-pass ms per frame), REPRO_INFO.xls (capture provenance) and,
    with -Regimes, GPUTRACE_REGIMES.xls (per-regime hardware counters).

        .\gputrace-report.ps1 -Dir gputrace\arm1
        .\gputrace-report.ps1 -Compare gputrace\arm0,gputrace\arm1,gputrace\arm2
        .\gputrace-report.ps1 -Validate -Compare gputrace\arm0,gputrace\arm1
        .\gputrace-report.ps1 -Json -Validate -Dir gputrace\arm1     # for an agent to parse
        .\gputrace-report.ps1 -List -Dir gputrace\arm1

.EVIDENCE CONTRACT
    Not every number carries the same weight, and the tool labels each one:

      count            A raw event count. Deterministic: two independent traces of the same work
                       must agree exactly. Safe to quote and to compare across traces.
      invariant        A physical constant that the hardware guarantees (warp width). Its only use
                       is to prove the counters are scaled correctly.
      ratio            A ratio with a known denominator (L1 sectors, frames). Safe to compare.
      rate             A per-cycle average. The numerator is a count, but the denominator is elapsed
                       cycles, so the value moves with the SM clock even when the work is identical -
                       which is exactly what the determinism check caught when these were first
                       mislabelled as counts. Compare rates only between traces taken at the same
                       clock, or lock the clock with ngfx --lock-gpu-clocks.
      peak-normalised  A rate whose denominator is an assumed peak. Internally checkable, but NOT
                       guaranteed to agree with another tool's definition of the same name.

    Validation runs eight checks and refuses to call a trace good when one fails:

      1 warp-width      threads-per-instruction == 32 exactly
      2 pipe-budget     sum(alu, fma, xu) <= total instructions
      3 registers       register-file% / warps_active reconstructs a plausible register count
      4 slot-budget     issue-slot utilisation + sum(issue stalls) <= 100%
      5 peak-bound      the peak implied by the stall sum is >= the architecture's warps per
                        sub-partition. The architecture comes from the capture's own REPRO_INFO
                        (chip name), so this needs no input; it is skipped, never guessed, when
                        the chip is unknown. -Architecture overrides.
      6 determinism     two traces of the same arm executed the same work: every workload count
                        agrees within 0.05%. Counters that measure *when* work happened (GPU
                        cycles, PCIe traffic, front-end queue stalls) are reported separately:
                        they cannot be reproduced across two independent runs of a live app.
      7 event-budget    the per-pass timings (D3DPERF_EVENTS) sum to no more than the frame time
                        (FRAME.xls) - two different tables that must agree
      8 sampling-provenance  REPRO_INFO records whether warp state sampling was enabled; only
                        sampling-enabled traces carry GUI-comparable stall data at all

.LIMITATIONS - read before trusting a stall number
    * Stall reasons exist only with -MultiPassMetrics. The plain metric set has none.
    * Nsight's GUI "Top Stall" table is built from per-PC samples inside the .ngfx-gputrace
      container (WRPV sections, decoded by gputrace-extract.py / pcs-lines.py). The counter-based
      stall numbers here are therefore NOT the same quantity as the GUI's, and must not be
      presented as if they were. Their absolute values differ by large factors; only the direction
      is usable.
    * No single Ada metric set satisfies all eight checks (measured 2026-10-27, driver 610.88):
      set 1 "Throughput Metrics" lacks the thread-per-instruction ratio and the RF-occupancy
      counter; set 2 "Top-Level Triage" has both, but enabling the real-time shader profiler
      replaces the RF-occupancy counter, so `registers` and `sampling-provenance` cannot both PASS
      on one trace. This is Nsight behaviour, not a bug here - see docs/validation-2026-10-27.md.
    * At least one stall metric is pipe-qualified - smsp__warps_issue_stalled_long_scoreboard_pipe_l1tex
      is long-scoreboard on the L1TEX pipe only, not the total - which distorts any share computed
      by dividing by the sum of the reasons.
    * Attaching the profiler costs a roughly uniform ~18%, so ratios survive but absolute times do
      not. Time the application with its own harness instead of reading times from here.
    * Trace one arm per run: a --sweep trace switches arm per frame and cannot be attributed back.
#>

param(
    [string]$Dir = 'gputrace',
    [string]$Compare,
    [string]$Metric,
    [switch]$List,
    [switch]$Validate,
    # Also summarise GPUTRACE_REGIMES.xls: the same hardware metrics split per named regime
    # (benchmark pass vs UI vs present), which is what attributes throughput to the decode pass.
    [switch]$Regimes,
    # Optional: a pipeline-dump CSV (see pipeline-dump-report.ps1), for check 3 to cross-check against.
    [string]$PipelineDump,
    [switch]$Json,
    # The peak-bound check compares against the architecture's real warp limit, so it needs to know
    # which GPU produced the trace. That is normally read from the capture's own REPRO_INFO; this
    # overrides it when the capture carries no provenance or an unrecognised chip. Accepts
    # turing/ampere/ada/hopper/blackwell, or a raw warps-per-sub-partition count.
    [string]$Architecture,
    # Base for the relative -Dir / -Compare / -PipelineDump paths. Defaults to the current
    # directory: this script is a standalone reader, so it resolves paths where it is invoked
    # from rather than relative to itself.
    [string]$WorkDir = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Architectural constants. Four sub-partitions per SM and 65536 registers per SM have held since
# Maxwell, so only the warp count varies between the GPUs this runs on - and the peak-bound check
# below is meaningless without it. PowerShell variable names are case-insensitive, so no local may
# differ only in case from these.
$SubPartitionsPerSm = 4
$RegistersPerSm = 65536

# Warps per sub-partition, keyed by architecture. A wrong entry turns a correct capture into a
# reported failure, so an unrecognised chip resolves to $null and the check is skipped - never
# guessed at.
$ArchitectureWarps = [ordered]@{
    turing    = 8    # 32 warps per SM
    ampere    = 12   # GA10x, 48 warps per SM
    ada       = 12   # 48 warps per SM
    hopper    = 16   # 64 warps per SM
    blackwell = 16   # 64 warps per SM
}

# Resolves warps-per-sub-partition from the chip the capture recorded in REPRO_INFO ("Chip Name":
# AD104, GA102, GH100, GB202, TU117, ...). -Architecture overrides, for a capture that carries no
# REPRO_INFO or a chip the table does not know.
function Get-WarpsPerSubPartition {
    param([string]$Chip, [string]$Architecture)

    if ($Architecture) {
        $key = $Architecture.Trim().ToLowerInvariant()
        if ($ArchitectureWarps.Contains($key)) { return $ArchitectureWarps[$key] }
        $raw = 0
        if ([int]::TryParse($Architecture, [ref]$raw) -and $raw -gt 0) { return $raw }
        throw "-Architecture '$Architecture' is not one of $($ArchitectureWarps.Keys -join '/'), nor a warp count"
    }

    if ([string]::IsNullOrWhiteSpace($Chip)) { return $null }
    $name = $Chip.Trim().ToUpperInvariant()

    # GA100 is the datacentre Ampere part, with 64 warps per SM where the consumer GA10x has 48.
    if ($name.StartsWith('GA100')) { return 16 }

    if ($name.StartsWith('TU')) { return $ArchitectureWarps['turing'] }
    if ($name.StartsWith('GA')) { return $ArchitectureWarps['ampere'] }
    if ($name.StartsWith('AD')) { return $ArchitectureWarps['ada'] }
    if ($name.StartsWith('GH')) { return $ArchitectureWarps['hopper'] }
    if ($name.StartsWith('GB')) { return $ArchitectureWarps['blackwell'] }
    return $null
}

# Issue-stall reasons. Names come from the trace; a missing one is simply not reported.
$stallNames = @(
    'long_scoreboard_pipe_l1tex', 'short_scoreboard', 'lg_throttle', 'mio_throttle_pipe_mio',
    'tex_throttle', 'math_pipe_throttle', 'wait', 'not_selected', 'dispatch_stall',
    'no_instruction', 'drain', 'imc_miss', 'misc', 'barrier', 'membar', 'sleeping'
)

# The same reasons as measured by the warp-state (PC) sampler - the GUI "Top Stall" table's own
# data source, exported when the capture ran with --real-time-shader-profiler. Evidence class
# 'sampled': same measurement the GUI shows, not the counter quantity above.
$sampledStallNames = @(
    'long_scoreboard_pipe_l1tex', 'long_scoreboard_pipe_rtcore', 'short_scoreboard',
    'lg_throttle', 'mio_throttle_pipe_mio', 'mio_throttle_pipe_rtcore',
    'tex_throttle', 'math_pipe_throttle', 'wait', 'selected', 'not_selected',
    'dispatch_stall', 'no_instruction', 'branch_resolving', 'drain', 'imc_miss',
    'misc', 'barrier', 'membar', 'sleeping'
)

# Reasons whose metric is qualified to one hardware pipe, so it measures a subset rather than the
# whole reason. Listed explicitly rather than matched on "_pipe_": math_pipe_throttle is the name of
# a reason (Math Pipe Throttle), not a qualified variant, and a substring match flags it by mistake.
$pipeQualifiedStalls = @('long_scoreboard_pipe_l1tex', 'mio_throttle_pipe_mio')

# Metrics worth reading first, selected by pattern rather than a fixed whitelist: metric names
# shift with the metric set and the capture mode (RTS captures roll several counters up under
# GPUTrace.*), so a hardcoded list silently goes stale. The curated view skips the per-unit
# instances (they duplicate the trace rollups) and the #2/#3 duplicate-name suffixes.
$focusPatterns = @(
    '\.throughput\.avg\.pct_of_peak_sustained_elapsed$',
    'warps_active',
    'warps_issue_stalled',
    'warps_launched',
    'inst_executed',
    'average_warp_latency',
    'hit_rate',
    'registers_allocated',
    'thread_inst_executed_per_inst_executed'
)

function Get-FocusRows {
    param($Series)
    $focus = [ordered]@{}
    foreach ($name in $Series.Keys) {
        if ($name -match '\.Triage') { continue }
        if ($name -match '#\d+$') { continue }
        foreach ($p in $focusPatterns) {
            if ($name -match $p) { $focus[$name] = Get-EvidenceClass $name; break }
        }
    }
    return $focus
}

function Write-Output-Line {
    param([string]$Text = '')
    if (-not $Json) { Write-Host $Text }
}

function Get-TraceLabel {
    param([string]$Path)
    # Two segments, not just the leaf: trace folders are conventionally named arm0/arm1/arm2, so a
    # leaf-only label makes two runs collide on one key - which once silently compared a trace
    # against itself and reported impossible bit-identical numbers.
    $trimmed = $Path.TrimEnd('\', '/')
    $leaf = Split-Path $trimmed -Leaf
    $parent = Split-Path (Split-Path $trimmed -Parent) -Leaf
    if ($parent) { return "$parent/$leaf" }
    return $leaf
}

function Resolve-TraceDir {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $WorkDir $Path
}

function Read-Trace {
    param([string]$TraceDir)

    $frameFile = Join-Path $TraceDir 'BASE\GPUTRACE_FRAME.xls'
    if (-not (Test-Path -LiteralPath $frameFile)) {
        throw "no BASE\GPUTRACE_FRAME.xls under '$TraceDir' - run gputrace-capture.ps1 first"
    }

    $series = @{}
    foreach ($line in (Get-Content -LiteralPath $frameFile)) {
        $fields = $line -split "`t"
        if ($fields.Count -lt 2) { continue }

        $values = @()
        foreach ($field in $fields[1..($fields.Count - 1)]) {
            $parsed = 0.0
            if ([double]::TryParse($field, [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                $values += $parsed
            }
        }
        if ($values.Count -eq 0) { continue }

        # The export carries the same metric name more than once (different rollup levels - e.g.
        # two pcie__throughput rows differing by 2x). Last-wins silently picked the wrong
        # instance for the GUI comparison, so the first keeps the plain name and later ones get
        # a #2/#3 suffix.
        $name = $fields[0]
        if ($series.ContainsKey($name)) {
            $suffix = 2
            while ($series.ContainsKey("$name#$suffix")) { $suffix++ }
            $name = "$name#$suffix"
        }
        $series[$name] = $values
    }

    # Frame times live in FRAME.xls, not the metric table; carry them so check 6 and the report can
    # use the one timing figure the trace records itself.
    $frameTimes = @()
    $frameFileTimes = Join-Path $TraceDir 'BASE\FRAME.xls'
    if (Test-Path -LiteralPath $frameFileTimes) {
        $line = (Get-Content -LiteralPath $frameFileTimes) -split "`t"
        foreach ($field in $line[1..($line.Count - 1)]) {
            $parsed = 0.0
            if ([double]::TryParse($field, [ref]$parsed)) { $frameTimes += $parsed }
        }
    }

    # D3DPERF_EVENTS.xls is the per-pass timing breakdown the metric tables never carry: one row
    # per named event the application declares, one ms column per traced frame.
    $events = [ordered]@{}
    $eventsFile = Join-Path $TraceDir 'BASE\D3DPERF_EVENTS.xls'
    if (Test-Path -LiteralPath $eventsFile) {
        foreach ($line in (Get-Content -LiteralPath $eventsFile)) {
            $fields = $line -split "`t"
            if ($fields.Count -lt 2) { continue }
            $values = @()
            foreach ($field in $fields[1..($fields.Count - 1)]) {
                $parsed = 0.0
                if ([double]::TryParse($field, [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                    $values += $parsed
                }
            }
            if ($values.Count -gt 0) { $events[$fields[0]] = $values }
        }
    }

    # REPRO_INFO.xls is the capture's own provenance record. Kept verbatim: it is what tells a
    # sampling-enabled trace from a plain one, which decides what the stall numbers even are.
    $repro = [ordered]@{}
    $reproFile = Join-Path $TraceDir 'BASE\REPRO_INFO.xls'
    if (Test-Path -LiteralPath $reproFile) {
        foreach ($line in (Get-Content -LiteralPath $reproFile)) {
            $idx = $line.IndexOf("`t")
            if ($idx -lt 1) { continue }
            $repro[$line.Substring(0, $idx)] = $line.Substring($idx + 1)
        }
    }

    return [pscustomobject]@{
        Path = $frameFile; Dir = $TraceDir; Series = $series; FrameTimes = $frameTimes
        Events = $events; Repro = $repro; Regimes = $null
    }
}

# GPUTRACE_REGIMES.xls layout (verified 2026-10-11, Nsight 2026.1): 1 header + (frames x regimes)
# data rows. The header is "flattened_event_name" followed by metric names in blocks of exactly
# <frame count> columns each. Rows cycle through the regime names; for the FIRST regime of the
# cycle row 0 carries the whole per-frame series across the block columns, while every later row
# repeats its single frame value across all columns. So: regime[0] reads column blockStart+f for
# frame f; every other regime reads column blockStart on its own row.
function Read-Regimes {
    param([string]$TraceDir, [double[]]$FrameTimes)

    $file = Join-Path $TraceDir 'BASE\GPUTRACE_REGIMES.xls'
    if (-not (Test-Path -LiteralPath $file)) { return $null }

    $reader = [System.IO.File]::OpenText($file)
    try {
        $header = ($reader.ReadLine()) -split "`t"
        if ($header.Count -lt 3) { return $null }
        $blockWidth = $FrameTimes.Count
        if ($blockWidth -lt 1) { return $null }

        # Metric blocks: columns 1..N, name at the first column of each block.
        $blockNames = @()
        for ($c = 1; $c -lt $header.Count; $c += $blockWidth) { $blockNames += $header[$c] }

        # Only the metrics that attribute behaviour to a regime; the full table is 7000+ columns.
        $wanted = 'throughput\.avg\.pct|warps_active|l1tex__t_sector_hit_rate|dram__bytes'
        $keep = @()
        for ($b = 0; $b -lt $blockNames.Count; $b++) {
            if ($blockNames[$b] -match $wanted) { $keep += $b }
        }

        $rows = @()
        while ($null -ne ($line = $reader.ReadLine())) { $rows += ,@($line -split "`t") }
        if ($rows.Count -lt 3) { return $null }

        # The regime names, in cycle order, from the first three data rows.
        $trio = @($rows[0][0], $rows[1][0], $rows[2][0])

        $regimes = [ordered]@{}
        foreach ($name in $trio) { $regimes[$name] = @{} }
        $skipped = 0
        for ($b = 0; $b -lt $keep.Count; $b++) {
            $name = $blockNames[$keep[$b]]
            $blockStart = 1 + $keep[$b] * $blockWidth
            for ($r = 0; $r -lt $trio.Count; $r++) {
                $values = @()
                for ($f = 0; $f -lt $blockWidth; $f++) {
                    $rowIndex = $f * $trio.Count + $r
                    if ($rowIndex -ge $rows.Count) { break }
                    # First regime: the frame series lives across the block columns. Others: the
                    # single frame value is repeated, so any column works - use the first.
                    $col = if ($r -eq 0) { $blockStart + $f } else { $blockStart }
                    if ($col -ge $rows[$rowIndex].Count) { $skipped++; continue }
                    $parsed = 0.0
                    if ([double]::TryParse($rows[$rowIndex][$col], [System.Globalization.NumberStyles]::Float,
                            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                        $values += $parsed
                    }
                }
                if ($values.Count -gt 0) { $regimes[$trio[$r]][$name] = $values }
            }
        }
        if ($skipped -gt 0) {
            Write-Host ("  note: $skipped regime cells out of range - block layout differs from assumption")
        }
        return $regimes
    } finally {
        $reader.Close()
    }
}

# Median rather than mean: every trace contains a few frames disturbed by process start-up.
function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return [double]::NaN }
    $sorted = @($Values | Sort-Object)
    return $sorted[[int][Math]::Floor($sorted.Count / 2)]
}

# Counters this check set asks for by their canonical Nsight name, mapped to the counter the
# "Throughput Metrics" set actually emits. `sm__inst_executed_realtime` and `smsp__inst_executed`
# are the same rollup: on 2026-10-27, 100 * smsp__inst_executed.avg.per_cycle_elapsed / 4 = 58.05,
# which is exactly smsp__inst_executed.avg.pct_of_peak_sustained_elapsed in the same trace.
$MetricAliases = @{
    'sm__inst_executed_realtime.sum'                   = 'smsp__inst_executed.sum'
    'sm__inst_executed_realtime.avg.per_cycle_elapsed' = 'smsp__inst_executed.avg.per_cycle_elapsed'
}

# Group prefixes such as 'SM_A.TriageSCG.' / 'TPC.TriageSCG.' identify the counter block and are
# not part of the metric identity; which ones are present changes with driver version and metric
# set. 2026-10-27: driver 610.88 emits `tpc__warps_active_shader_ps_realtime.*` bare, while the
# checks were written against the 591.86 form `TPC.TriageSCG.tpc__...`. Resolving by exact name
# only made three checks skip on a capture that had every counter they needed.
function Resolve-MetricName {
    param($Trace, [string]$Name)

    if ($Trace.Series.ContainsKey($Name)) { return $Name }

    $leaf = $Name -replace '^.*?\.TriageSCG\.', ''
    if ($Trace.Series.ContainsKey($leaf)) { return $leaf }
    if ($MetricAliases.ContainsKey($leaf) -and $Trace.Series.ContainsKey($MetricAliases[$leaf])) {
        return $MetricAliases[$leaf]
    }

    # Last resort: a unique "<group>.<leaf>" match. Ambiguity returns $null rather than picking
    # one of two differently-scoped counters, so the caller reports SKIP instead of a wrong PASS.
    $hits = @($Trace.Series.Keys | Where-Object { $_.EndsWith('.' + $leaf) })
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}

function Get-MetricOrNaN {
    param($Trace, [string]$Name)
    $resolved = Resolve-MetricName $Trace $Name
    if ($null -eq $resolved) { return [double]::NaN }
    return Get-Median $Trace.Series[$resolved]
}

# A count that measures elapsed clock/bus activity rather than work performed. Two independent
# runs of a real-time application cannot reproduce these: the capture window lands at a different
# phase of the frame, the GPU clock free-runs, and the host PCIe bus carries unrelated desktop
# traffic. Measured 2026-10-27 across two arm1 traces: instruction/warp/pixel counts agreed to
# 0.004%, while these differed by up to 7%. Counted and reported, not failed.
function Test-TimingDomainCount {
    param([string]$Name)
    return $Name -match '(^|\.)(gr__cycles_|pcie__|PCI\.|FE_)|_cycles_stalled_'
}

# Classifies any metric, so -Metric and -List label what they print.
# Order matters: .sum.per_second is a rate, .sum is a count.
function Get-EvidenceClass {
    param([string]$Name)
    if ($Name -match '^GPUTrace\.PCSampler') { return 'sampled' }
    if ($Name -match 'warps_issue_stalled') { return 'peak-normalised' }
    if ($Name -match '\.sum\.per_second$') { return 'rate' }
    if ($Name -match '\.sum$') { return 'count' }
    if ($Name -match 'avg\.per_cycle_elapsed$') { return 'rate' }
    if ($Name -match 'pct_of_peak_sustained') { return 'peak-normalised' }
    if ($Name -match '\.pct$' -or $Name -match 'hit_rate') { return 'ratio' }
    return 'unclassified'
}

function Add-Check {
    param([System.Collections.ArrayList]$Checks, [string]$Name, [string]$Status, [string]$Detail)
    $null = $Checks.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail })
}

# Reads a pipeline dump so check 3 can cross-check the register count against a completely
# different API (VK_KHR_pipeline_executable_properties) rather than only against itself.
function Read-PipelineRegisters {
    param([string]$Path)
    $table = @{}
    if (-not $Path) { return $table }
    $csv = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $WorkDir $Path }
    if (-not (Test-Path -LiteralPath $csv)) { return $table }
    foreach ($row in (Import-Csv -LiteralPath $csv)) {
        if ($row.statistic -ne 'Register Count') { continue }
        $shader = Split-Path $row.pipeline -Leaf
        $table["$shader/$($row.stage)"] = [int]$row.value
    }
    return $table
}

function Test-Trace {
    param($Trace, $PipelineRegisters, $ReferenceTrace)

    # Which GPU produced this trace decides the architectural peak the stall counters are scaled
    # against. The capture records its own chip, so this normally needs no user input at all.
    $chip = if ($Trace.Repro.Contains('Chip Name')) { $Trace.Repro['Chip Name'] } else { $null }
    $warpsPerSubPartition = Get-WarpsPerSubPartition -Chip $chip -Architecture $Architecture

    $checks = New-Object System.Collections.ArrayList

    # 1. Warp width. The hardware guarantees 32 threads per warp, so this ratio has exactly one
    #    correct value; anything else means the counters are not scaled the way we assume.
    $warpRatio = Get-MetricOrNaN $Trace 'smsp__thread_inst_executed_per_inst_executed.ratio'
    if ([double]::IsNaN($warpRatio)) {
        Add-Check $checks 'warp-width' 'SKIP' 'thread-per-instruction ratio not in this trace'
    } elseif ([Math]::Abs($warpRatio - 32.0) -le 0.01) {
        Add-Check $checks 'warp-width' 'PASS' ("threads per instruction = {0:F4} (expected 32)" -f $warpRatio)
    } else {
        Add-Check $checks 'warp-width' 'FAIL' ("threads per instruction = {0:F4}, expected 32" -f $warpRatio)
    }

    # 2. Per-pipe counts cannot exceed the total. fmaheavy is a subset of fma, so it is not added.
    $total = Get-MetricOrNaN $Trace 'SM_A.TriageSCG.sm__inst_executed_realtime.sum'
    $alu = Get-MetricOrNaN $Trace 'SM_A.TriageSCG.sm__inst_executed_pipe_alu_realtime.sum'
    $xu = Get-MetricOrNaN $Trace 'SM_A.TriageSCG.sm__inst_executed_pipe_xu_realtime.sum'
    $fma = Get-MetricOrNaN $Trace 'SM_C.TriageSCG.smsp__inst_executed_pipe_fma.sum'
    if ([double]::IsNaN($total) -or [double]::IsNaN($alu)) {
        Add-Check $checks 'pipe-budget' 'SKIP' 'per-pipe instruction counts not in this trace'
    } else {
        $sum = $alu + $fma + $xu
        $share = 100.0 * $sum / $total
        if ($sum -le $total) {
            Add-Check $checks 'pipe-budget' 'PASS' ("alu+fma+xu = {0:F1}% of total, remainder {1:F1}%" -f $share, (100.0 - $share))
        } else {
            Add-Check $checks 'pipe-budget' 'FAIL' ("alu+fma+xu = {0:F1}% of total - exceeds 100%" -f $share)
        }
    }

    # 3. Registers. The register-file occupancy, the live warp count and the per-thread register
    #    count are three views of one number: warps * regs * 32 / 65536 = occupancy. Solving for the
    #    register count must land on a plausible allocation, and when a pipeline dump is available it
    #    must match the Register Count the driver reports through a different API entirely.
    $warps = Get-MetricOrNaN $Trace 'TPC.TriageSCG.tpc__warps_active_shader_ps_realtime.avg.per_cycle_elapsed'
    $regPct = Get-MetricOrNaN $Trace 'TPC.TriageSCG.tpc__sm_rf_registers_allocated_shader_3d_realtime.avg.pct_of_peak_sustained_elapsed'
    if ([double]::IsNaN($warps) -or [double]::IsNaN($regPct) -or $warps -le 0) {
        Add-Check $checks 'registers' 'SKIP' 'warps_active / register occupancy not in this trace'
    } else {
        $derived = $regPct * $RegistersPerSm / (100.0 * $warps * 32.0)
        # Registers are allocated in multiples of 8 per thread.
        $nearest = [Math]::Round($derived / 8.0) * 8.0
        $errorPt = [Math]::Abs($derived - $nearest)
        # When a pipeline dump is supplied, the reconstruction must also land on a count the driver
        # actually reports through VK_KHR_pipeline_executable_properties - a different API entirely.
        $known = @($PipelineRegisters.Values | Sort-Object -Unique)
        if ($known.Count -gt 0) {
            # The trace does not say which pipeline it captured, so report the closest count the
            # driver reports rather than every one that happens to be nearby.
            $closest = $known | Sort-Object { [Math]::Abs($_ - $derived) } | Select-Object -First 1
            if ([Math]::Abs($closest - $derived) -gt 8.0) {
                Add-Check $checks 'registers' 'FAIL' ("reconstructed {0:F1} registers/thread; closest driver count is {1} (all: {2})" -f $derived, $closest, ($known -join '/'))
            } else {
                Add-Check $checks 'registers' 'PASS' ("reconstructed {0:F1} registers/thread, driver reports {1}" -f $derived, $closest)
            }
        } elseif ($errorPt -gt 8.0) {
            Add-Check $checks 'registers' 'FAIL' ("reconstructed {0:F1} registers/thread, not within 8 of a multiple of 8" -f $derived)
        } else {
            Add-Check $checks 'registers' 'PASS' ("reconstructed {0:F1} registers/thread (nearest allocation {1:F0}); pass -PipelineDump to cross-check" -f $derived, $nearest)
        }
    }

    # 4. Issue-slot budget. Four schedulers per SM issue at most one instruction per cycle each, so
    #    instructions-per-cycle-per-SM over 4 is the utilisation; what is issuing plus what is stalled
    #    cannot exceed the whole.
    $stallSum = 0.0
    $haveStalls = $false
    foreach ($stall in $stallNames) {
        $value = Get-MetricOrNaN $Trace "smsp__warps_issue_stalled_$stall.avg.pct_of_peak_sustained_elapsed"
        if (-not [double]::IsNaN($value)) { $stallSum += $value; $haveStalls = $true }
    }

    $ipc = Get-MetricOrNaN $Trace 'SM_A.TriageSCG.sm__inst_executed_realtime.avg.per_cycle_elapsed'
    if ([double]::IsNaN($ipc)) {
        Add-Check $checks 'slot-budget' 'SKIP' 'instructions-per-cycle not in this trace'
    } else {
        $util = 100.0 * $ipc / $SubPartitionsPerSm
        if (-not $haveStalls) {
            Add-Check $checks 'slot-budget' 'SKIP' ("issue-slot utilisation {0:F1}%, no stall counters in this trace" -f $util)
        } elseif (($util + $stallSum) -le 100.0) {
            Add-Check $checks 'slot-budget' 'PASS' ("issue {0:F1}% + stalled {1:F1}% = {2:F1}%" -f $util, $stallSum, ($util + $stallSum))
        } else {
            Add-Check $checks 'slot-budget' 'FAIL' ("issue {0:F1}% + stalled {1:F1}% = {2:F1}% - exceeds 100%" -f $util, $stallSum, ($util + $stallSum))
        }
    }

    # 5. Peak bound. Stalled warps cannot outnumber active warps, and stalled warps = sum(pct) * P/100
    #    for whatever peak P the counter uses. So P is bounded above by active/stalled, and that bound
    #    must sit at or above the architectural peak - it lands just above it when the scaling is right.
    if ($null -eq $warpsPerSubPartition) {
        # Skipped rather than assumed: judging the scaling against the wrong architecture's peak
        # reports a false failure on a capture that is perfectly good.
        $which = if ($chip) { $chip } else { 'not recorded' }
        Add-Check $checks 'peak-bound' 'SKIP' ("unknown architecture (chip '{0}'); pass -Architecture to check this" -f $which)
    } elseif (-not [double]::IsNaN($warps) -and $haveStalls -and $stallSum -gt 0) {
        $activePerSubPartition = $warps / $SubPartitionsPerSm
        $impliedPeak = 100.0 * $activePerSubPartition / $stallSum
        if ($impliedPeak -ge $warpsPerSubPartition) {
            Add-Check $checks 'peak-bound' 'PASS' ("implied peak {0:F2} warp/sub-partition >= architectural {1} (chip {2})" -f $impliedPeak, $warpsPerSubPartition, $chip)
        } else {
            Add-Check $checks 'peak-bound' 'FAIL' ("implied peak {0:F2} warp/sub-partition < architectural {1} (chip {2})" -f $impliedPeak, $warpsPerSubPartition, $chip)
        }
    } else {
        Add-Check $checks 'peak-bound' 'SKIP' 'needs both stall counters and warps_active'
    }

    # 6. Determinism. Compared against another trace of the same arm only. Two independent runs of
    #    a live application never reproduce *timing* counters, so the check is on the work that was
    #    executed: every workload count must agree within 0.05 %. That tolerance is ~12x the worst
    #    deviation measured between two good runs (0.004 %) and far below a one-frame change, so it
    #    separates run-to-run jitter from "the two runs executed different work".
    if ($null -ne $ReferenceTrace) {
        $tolerance = 0.0005
        $differences = @()
        $compared = 0
        $timingSkipped = 0
        $maxRel = 0.0
        $worst = ''
        foreach ($name in $Trace.Series.Keys) {
            if ((Get-EvidenceClass $name) -ne 'count') { continue }
            if (-not $ReferenceTrace.Series.ContainsKey($name)) { continue }
            if (Test-TimingDomainCount $name) { $timingSkipped++; continue }

            $a = Get-Median $Trace.Series[$name]
            $b = Get-Median $ReferenceTrace.Series[$name]
            $compared++
            if ($a -eq $b) { continue }

            $scale = [Math]::Max([Math]::Abs($a), [Math]::Abs($b))
            $rel = if ($scale -gt 0) { [Math]::Abs($a - $b) / $scale } else { 1.0 }
            if ($rel -gt $maxRel) { $maxRel = $rel; $worst = $name }
            if ($rel -gt $tolerance) {
                $differences += ("{0}: {1:G6} vs {2:G6} ({3:P2})" -f $name, $a, $b, $rel)
            }
        }
        $where = ''
        if ($worst) { $where = " (worst: $worst)" }
        if ($differences.Count -eq 0) {
            Add-Check $checks 'determinism' 'PASS' (
                "{0} workload counts compared, max deviation {1:P3}{2}; {3} timing-domain counts not comparable across runs" -f
                $compared, $maxRel, $where, $timingSkipped)
        } else {
            Add-Check $checks 'determinism' 'FAIL' ($differences -join '; ')
        }
    } else {
        Add-Check $checks 'determinism' 'SKIP' 'pass two traces of the same arm to check this'
    }

    # 7. Event budget. The per-pass timings in D3DPERF_EVENTS and the frame time in FRAME.xls are
    #    two different tables; their medians must agree, otherwise one of them was misread. Events
    #    may sum to less than the frame (gaps between passes), never meaningfully more.
    $frameTime = Get-Median $Trace.FrameTimes
    if ($Trace.Events.Count -eq 0 -or [double]::IsNaN($frameTime)) {
        Add-Check $checks 'event-budget' 'SKIP' 'no event table or frame times in this trace'
    } else {
        $eventSum = 0.0
        foreach ($name in $Trace.Events.Keys) { $eventSum += Get-Median $Trace.Events[$name] }
        if ($eventSum -le 0) {
            Add-Check $checks 'event-budget' 'SKIP' 'event table carries no non-zero timings'
        } elseif ($eventSum -le 1.25 * $frameTime) {
            Add-Check $checks 'event-budget' 'PASS' ("events sum {0:F3} ms vs frame time {1:F3} ms" -f $eventSum, $frameTime)
        } else {
            Add-Check $checks 'event-budget' 'FAIL' ("events sum {0:F3} ms exceeds frame time {1:F3} ms - the tables disagree" -f $eventSum, $frameTime)
        }
    }

    # 8. Sampling provenance. The GUI "Top Stall" table exists only for captures whose warp state
    #    sampling was enabled; REPRO_INFO records that explicitly, so quote it instead of guessing.
    $sampling = if ($Trace.Repro.Contains('Warp State Sampling Interval')) {
        $Trace.Repro['Warp State Sampling Interval']
    } else {
        $null
    }
    if ($null -eq $sampling) {
        Add-Check $checks 'sampling-provenance' 'SKIP' 'no REPRO_INFO provenance in this trace'
    } elseif ($sampling -match 'Disabled') {
        Add-Check $checks 'sampling-provenance' 'SKIP' ("warp state sampling was OFF for this capture ({0}); GUI-equivalent stall data absent" -f $sampling)
    } else {
        Add-Check $checks 'sampling-provenance' 'PASS' ("warp state sampling was ON: {0}" -f $sampling)
    }

    return $checks
}

# ---------------------------------------------------------------------------
# Load the traces
# ---------------------------------------------------------------------------

if ($Compare) {
    $requested = @($Compare -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { Resolve-TraceDir $_ })
    if ($requested.Count -lt 2) { throw '-Compare needs at least two trace directories' }
} else {
    $requested = @(Resolve-TraceDir $Dir)
}

$pipelineRegisters = Read-PipelineRegisters $PipelineDump

$traces = @{}
$labels = @()
foreach ($path in $requested) {
    $label = Get-TraceLabel $path
    if ($traces.ContainsKey($label)) { throw "two traces map to the label '$label'; rename one folder" }
    $labels += $label
    $traces[$label] = Read-Trace $path
    if ($Regimes) {
        # opt-in: the regimes table is the largest file in the export; parse it only when asked.
        $traces[$label].Regimes = Read-Regimes -TraceDir $path -FrameTimes $traces[$label].FrameTimes
    }
}

# Validate every trace; the first trace of a repeated arm acts as the determinism reference.
$validation = @{}
for ($i = 0; $i -lt $labels.Count; ++$i) {
    $reference = $null
    if ($i -gt 0) {
        $previous = $labels[$i - 1]
        if ((Split-Path $previous -Leaf) -eq (Split-Path $labels[$i] -Leaf)) { $reference = $traces[$previous] }
    }
    $validation[$labels[$i]] = Test-Trace -Trace $traces[$labels[$i]] -PipelineRegisters $pipelineRegisters -ReferenceTrace $reference
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

if ($List) {
    $first = $traces[$labels[0]]
    Write-Output-Line "Metric names in $($traces[$labels[0]].Path) ($($first.Series.Count) total):"
    $first.Series.Keys | Sort-Object | ForEach-Object { Write-Output-Line "  $_" }
    if ($Json) { [pscustomobject]@{ trace = $labels[0]; metrics = @($first.Series.Keys | Sort-Object) } | ConvertTo-Json -Depth 5 }
    exit 0
}

if ($Metric) {
    $first = $traces[$labels[0]]
    $matches = @($first.Series.Keys | Where-Object { $_ -match $Metric } | Sort-Object)
    $rows = @()
    foreach ($name in $matches) {
        $rows += [pscustomobject]@{
            metric = $name
            median = Get-Median $first.Series[$name]
            frames = $first.Series[$name].Count
            evidence = Get-EvidenceClass $name
        }
    }
    if ($Json) { ,$rows | ConvertTo-Json -Depth 5; exit 0 }
    if ($rows.Count -eq 0) { Write-Host "no metric name matches '$Metric'"; exit 0 }
    Write-Host ("{0,-74} {1,14} {2,7} {3}" -f 'Metric', 'Median', 'Frames', 'Evidence')
    Write-Host ('-' * 112)
    foreach ($row in $rows) {
        Write-Host ("{0,-74} {1,14:G6} {2,7} {3}" -f $row.metric, $row.median, $row.frames, $row.evidence)
    }
    exit 0
}

# JSON: one object holding every trace, its notable metrics, its stall breakdown and its checks.
if ($Json) {
    $payload = [ordered]@{
        traces = @()
        notes = @(
            'stalls: pct_of_peak is a counter-based quantity; it is NOT the same measurement as the Nsight GUI Top Stall table.',
            'long_scoreboard_pipe_l1tex is pipe-qualified and therefore a subset, which distorts shares.',
            'events: per-pass timings from D3DPERF_EVENTS.xls, class "time" - bounded jitter, never bit-exact.',
            'sampling-provenance: REPRO_INFO records whether warp state sampling was on; only then does sampling-level stall data exist in this trace.',
            'Evidence classes: count | invariant | ratio | peak-normalised | time.'
        )
    }
    foreach ($label in $labels) {
        $trace = $traces[$label]
        $used = 0.0
        $stalls = [ordered]@{}
        foreach ($stall in $stallNames) {
            $value = Get-MetricOrNaN $trace "smsp__warps_issue_stalled_$stall.avg.pct_of_peak_sustained_elapsed"
            if ([double]::IsNaN($value)) { continue }
            $used += $value
        }
        foreach ($stall in $stallNames) {
            $value = Get-MetricOrNaN $trace "smsp__warps_issue_stalled_$stall.avg.pct_of_peak_sustained_elapsed"
            if ([double]::IsNaN($value)) { continue }
            $shareValue = if ($used -gt 0) { $value / $used } else { 0.0 }
            $stalls[$stall] = [ordered]@{
                pct_of_peak = $value
                share = $shareValue
                qualified = ($pipeQualifiedStalls -contains $stall)
            }
        }

        # Warp-state (PC) sampler stalls: the GUI Top Stall table's own quantities, present when
        # the capture ran with --real-time-shader-profiler. Evidence class 'sampled'.
        $sampledUsed = 0.0
        $sampledStalls = [ordered]@{}
        foreach ($stall in $sampledStallNames) {
            $key = "GPUTrace.PCSampler.tpc__warps_issue_stalled_$stall.avg.pct_of_peak_sustained_elapsed"
            if (-not $trace.Series.ContainsKey($key)) { continue }
            $value = Get-Median $trace.Series[$key]
            $sampledUsed += $value
            $sampledStalls[$stall] = $value
        }

        $metricsOut = [ordered]@{}
        foreach ($name in (Get-FocusRows $trace.Series).Keys) {
            $values = $trace.Series[$name]
            $sorted = @($values | Sort-Object)
            $metricsOut[$name] = [ordered]@{
                median = Get-Median $values
                min = $sorted[0]
                max = $sorted[-1]
                p90 = $sorted[[int][Math]::Min($sorted.Count - 1, [Math]::Ceiling(0.9 * $sorted.Count) - 1)]
                frames = $values.Count
                evidence = Get-EvidenceClass $name
            }
        }

        # Per-pass timing: the breakdown that answers "what does a frame spend time on".
        $eventsOut = @()
        foreach ($name in $trace.Events.Keys) {
            $values = $trace.Events[$name]
            $eventsOut += [ordered]@{
                event = $name
                median_ms = Get-Median $values
                mean_ms = [Math]::Round((($values | Measure-Object -Average).Average), 6)
                max_ms = ($values | Measure-Object -Maximum).Maximum
                frames = $values.Count
                evidence = 'time'
            }
        }

        # Regime breakdown: the same counters attributed to the named pass they ran in.
        $regimesOut = $null
        if ($null -ne $trace.Regimes) {
            $regimesOut = [ordered]@{}
            foreach ($regimeName in $trace.Regimes.Keys) {
                $regime = [ordered]@{}
                foreach ($name in $trace.Regimes[$regimeName].Keys) {
                    $regime[$name] = [ordered]@{
                        median = Get-Median $trace.Regimes[$regimeName][$name]
                        frames = $trace.Regimes[$regimeName][$name].Count
                        evidence = Get-EvidenceClass $name
                    }
                }
                $regimesOut[$regimeName] = $regime
            }
        }

        $payload.traces += [ordered]@{
            label = $label
            frame_time_ms = Get-Median $trace.FrameTimes
            trace_config = $trace.Repro
            metrics = $metricsOut
            events = $eventsOut
            regimes = $regimesOut
            stalls = $stalls
            stalls_sampled = [ordered]@{
                available = ($sampledStalls.Count -gt 0)
                total_pct_of_peak = $sampledUsed
                reasons = $sampledStalls
                evidence = 'sampled'
                note = 'Same measurement the GUI Top Stall table shows; shares computed over the sampled reasons.'
            }
            stall_total_pct_of_peak = $used
            validation = @($validation[$label])
        }
    }
    $jsonFailures = 0
    if ($Validate) {
        foreach ($label in $labels) {
            foreach ($check in $validation[$label]) {
                if ($check.Status -eq 'FAIL') { $jsonFailures++ }
            }
        }
    }
    $payload | ConvertTo-Json -Depth 10
    # -Json must still be machine-readable on failure, but a failing validation has to
    # reach the caller through the exit code as well; otherwise "never mistake a bad
    # trace for a good one" only holds for the human-readable path.
    exit $(if ($jsonFailures -gt 0) { 1 } else { 0 })
}

$reference = $labels[0]

$checkFailures = 0
$validationRan = $false
if ($Validate) {
    $validationRan = $true
    Write-Host 'Validation'
    Write-Host ('=' * 78)
    $failed = 0
    foreach ($label in $labels) {
        Write-Host ''
        Write-Host $label
        foreach ($check in $validation[$label]) {
            $mark = switch ($check.Status) {
                'PASS' { 'ok  ' }
                'FAIL' { 'FAIL' }
                'SKIP' { '--  ' }
                default { '?   ' }
            }
            Write-Host ("  [{0}] {1,-14} {2}" -f $mark, $check.Check, $check.Detail)
            if ($check.Status -eq 'FAIL') { $failed++ }
        }
    }
    Write-Host ''
    Write-Host ('=' * 78)
    if ($failed -eq 0) { Write-Host 'All checks passed (or were skipped for lack of metrics in the trace).' }
    else { Write-Host "$failed check(s) FAILED - do not trust these numbers." }
    $checkFailures = $failed
    if (-not $Compare) { exit $(if ($checkFailures -gt 0) { 1 } else { 0 }) }
}

if ($Compare) {
    Write-Host ''
    Write-Host "Comparing: $($labels -join ', ')"
    Write-Host ''

    Write-Host '--- issue stalls, % of peak sustained elapsed (median over frames) ---'
    Write-Host ("{0,-30} {1}" -f 'Stall', (($labels | ForEach-Object { '{0,14}' -f $_ }) -join ' '))
    Write-Host ('-' * (31 + 15 * $labels.Count))

    $totals = @{}
    foreach ($l in $labels) { $totals[$l] = 0.0 }
    $rows = @()
    foreach ($stall in $stallNames) {
        $key = "smsp__warps_issue_stalled_$stall.avg.pct_of_peak_sustained_elapsed"
        $values = @{}
        foreach ($l in $labels) {
            $values[$l] = Get-MetricOrNaN $traces[$l] $key
            if (-not [double]::IsNaN($values[$l])) { $totals[$l] += $values[$l] }
        }
        $rows += [pscustomobject]@{ Name = $stall; Values = $values; Qualified = ($pipeQualifiedStalls -contains $stall) }
    }

    $haveStalls = ($totals.Values | Where-Object { $_ -gt 0 } | Measure-Object).Count -gt 0
    if (-not $haveStalls) {
        Write-Host 'no smsp__warps_issue_stalled_* metrics in these traces - capture with -MultiPassMetrics'
        Write-Host '(or -WarpStateSampling) for the stall table; see the evidence contract in the header.'
    } else {
        foreach ($row in ($rows | Sort-Object { -$_.Values[$reference] })) {
            $cells = ($labels | ForEach-Object { '{0,14:F2}' -f $row.Values[$_] }) -join ' '
            $flag = if ($row.Qualified) { ' (subset)' } else { '' }
            Write-Host ("{0,-30} {1}{2}" -f $row.Name, $cells, $flag)
        }
        Write-Host ('-' * (31 + 15 * $labels.Count))
        Write-Host ("{0,-30} {1}" -f 'total', (($labels | ForEach-Object { '{0,14:F2}' -f $totals[$_] }) -join ' '))
        Write-Host ''
        Write-Host 'Stalls marked (subset) are pipe-qualified: the metric covers one pipe, not the whole'
        Write-Host 'reason, so dividing by the total above understates every other reason.'
    }

    Write-Host ''
    Write-Host '--- per-pass timing, ms per frame (median over frames, evidence: time) ---'
    Write-Host ("{0,-34} {1}" -f 'Event', (($labels | ForEach-Object { '{0,12}' -f $_ }) -join ' '))
    Write-Host ('-' * (35 + 13 * $labels.Count))
    $eventNames = @()
    foreach ($l in $labels) { foreach ($n in $traces[$l].Events.Keys) { if ($eventNames -notcontains $n) { $eventNames += $n } } }
    foreach ($name in $eventNames) {
        $cells = ($labels | ForEach-Object {
            if ($traces[$_].Events.Contains($name)) { '{0,12:F3}' -f (Get-Median $traces[$_].Events[$name]) }
            else { '{0,12}' -f '-' }
        }) -join ' '
        Write-Host ("{0,-34} {1}" -f $name, $cells)
    }

    Write-Host ''
    Write-Host '--- capture provenance (REPRO_INFO) ---'
    $provenanceKeys = @('Device Name', 'Chip Name', 'Warp State Sampling Interval', 'Metric Set',
                        'Multi-Pass Metrics', 'Real-Time Shader Profiler', 'GPU Clocks',
                        'V-Sync Mode', 'Driver Version')
    foreach ($name in $provenanceKeys) {
        $cells = ($labels | ForEach-Object {
            if ($traces[$_].Repro.Contains($name)) { '{0,12}' -f $traces[$_].Repro[$name] }
            else { '{0,12}' -f '-' }
        }) -join ' '
        Write-Host ("{0,-34} {1}" -f $name, $cells)
    }

    Write-Host ''
    Write-Host '--- other metrics (with evidence class) ---'
    Write-Host ("{0,-74} {1} {2}" -f 'Metric', (($labels | ForEach-Object { '{0,14}' -f $_ }) -join ' '), 'evidence')
    Write-Host ('-' * (75 + 15 * $labels.Count + 16))
    $focusUnion = @()
    foreach ($l in $labels) {
        foreach ($n in (Get-FocusRows $traces[$l].Series).Keys) { if ($focusUnion -notcontains $n) { $focusUnion += $n } }
    }
    foreach ($name in $focusUnion) {
        $cells = @()
        $present = $false
        foreach ($l in $labels) {
            if ($traces[$l].Series.ContainsKey($name)) {
                $cells += '{0,14:G6}' -f (Get-Median $traces[$l].Series[$name])
                $present = $true
            } else {
                $cells += '{0,14}' -f '-'
            }
        }
        if (-not $present) { continue }
        Write-Host ("{0,-74} {1} {2}" -f $name, ($cells -join ' '), (Get-EvidenceClass $name))
    }
    # Non-zero on a failed check even in compare mode, so a script cannot read a broken trace and
    # treat the run as good just because the comparison printed.
    exit $(if ($validationRan -and $checkFailures -gt 0) { 1 } else { 0 })
}

$trace = $traces[$labels[0]]
Write-Host "Trace: $($trace.Path)"
$frameTime = Get-Median $trace.FrameTimes
if (-not [double]::IsNaN($frameTime)) { Write-Host ("GPU frame time (median): {0:F4} ms over {1} frames" -f $frameTime, $trace.FrameTimes.Count) }
if ($trace.Repro.Contains('Warp State Sampling Interval')) {
    Write-Host ("Warp state sampling: {0}" -f $trace.Repro['Warp State Sampling Interval'])
}
Write-Host ''
Write-Host '--- per-pass timing, ms per frame (median over frames, evidence: time) ---'
foreach ($name in $trace.Events.Keys) {
    Write-Host ("{0,-34} {1,12:F3}" -f $name, (Get-Median $trace.Events[$name]))
}
Write-Host ''
Write-Host '--- focus metrics (with evidence class) ---'
Write-Host ("{0,-74} {1,14} {2,7} {3}" -f 'Metric', 'Median', 'Frames', 'Evidence')
Write-Host ('-' * 112)
foreach ($name in (Get-FocusRows $trace.Series).Keys) {
    Write-Host ("{0,-74} {1,14:G6} {2,7} {3}" -f $name, (Get-Median $trace.Series[$name]), $trace.Series[$name].Count, (Get-EvidenceClass $name))
}
