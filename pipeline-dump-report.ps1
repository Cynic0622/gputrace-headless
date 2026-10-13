# Summarizes a pipeline dump produced by running the application with its own pipeline-dump switch on.
#
# The engine writes one row per driver statistic reported through
# VK_KHR_pipeline_executable_properties. This script pivots the ones that matter for shader work
# into a single line per pipeline stage, and can diff two dumps:
#
#     .\pipeline-dump-report.ps1                                  # summarize ./pipeline-dump
#     .\pipeline-dump-report.ps1 -Dir some\other\dump             # summarize elsewhere
#     .\pipeline-dump-report.ps1 -Baseline pipeline-dump-before   # add a delta column
#
# Columns:
#   Registers  driver "Register Count" - what Nsight shows as Live Registers
#   Binary     driver "Binary Size" - static instruction footprint, a stand-in for instruction count
#   Stack      driver "Stack Size" - non-zero means the shader spills
#
# Only pipelines created while dumping was enabled appear, so an application that builds its
# variants up front (rather than lazily on first use) lists all of them from a single run.

param(
    [string]$Dir = 'pipeline-dump',
    [string]$Baseline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Dump {
    param([string]$Path)

    $csv = Join-Path $Path 'pipelines.csv'
    if (-not (Test-Path -LiteralPath $csv)) {
        throw "no pipelines.csv under '$Path' - run the application with its pipeline-dump switch on first"
    }
    return Import-Csv -LiteralPath $csv
}

function Get-Summary {
    param($Rows)

    $summary = @{}
    foreach ($group in ($Rows | Group-Object pipeline, stage)) {
        $statistics = @{}
        foreach ($row in $group.Group) {
            # The driver reports numbers as strings (they arrive through a tagged union); keep them
            # as strings so a missing statistic stays distinguishable from a zero.
            $statistics[$row.statistic] = $row.value
        }

        $first = $group.Group[0]
        $summary["$($first.pipeline)|$($first.stage)"] = [pscustomobject]@{
            Pipeline  = $first.pipeline
            Stage     = $first.stage
            Registers = $statistics['Register Count']
            Binary    = $statistics['Binary Size']
            Stack     = $statistics['Stack Size']
        }
    }
    return $summary
}

$current = Get-Summary (Read-Dump $Dir)
$baseline = $null
if ($Baseline) {
    $baseline = Get-Summary (Read-Dump $Baseline)
}

$rows = foreach ($key in ($current.Keys | Sort-Object)) {
    $entry = $current[$key]

    $delta = ''
    if ($baseline -and $baseline.ContainsKey($key)) {
        $before = $baseline[$key]
        $parts = @()
        foreach ($field in @('Registers', 'Binary', 'Stack')) {
            $old = $before.$field
            $new = $entry.$field
            if ($old -ne $new -and $null -ne $old -and $null -ne $new) {
                $parts += "$field $old->$new"
            }
        }
        $delta = $parts -join ', '
    }
    elseif ($baseline) {
        $delta = 'not in baseline'
    }

    [pscustomobject]@{
        Pipeline  = $entry.Pipeline
        Stage     = $entry.Stage
        Registers = $entry.Registers
        Binary    = $entry.Binary
        Stack     = $entry.Stack
        Delta     = $delta
    }
}

$rows | Format-Table -AutoSize
