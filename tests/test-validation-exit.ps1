# Regression: a failing validation check must reach the caller through the
# process exit code, in BOTH output modes.
#
# The `-Json` branch used to print the payload and `exit 0` before the
# validation block ran, so an automated caller saw success on a trace that the
# human-readable path called FAIL. The fixtures are one-metric traces whose
# only decisive check is `warp-width` (32 threads/instruction passes, 16 fails).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-validation-exit.ps1
#
# Exits 0 when every case matches its expected code, 1 otherwise.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$report = Join-Path (Join-Path $root 'cli') 'gputrace-report.ps1'
if (-not (Test-Path -LiteralPath $report)) { throw "no gputrace-report.ps1 at $report" }

$cases = @(
    @{ Name = 'warp-ok';  Expected = 0 }
    @{ Name = 'warp-bad'; Expected = 1 }
)
$modes = @(
    @{ Label = 'text'; Extra = @() }
    @{ Label = 'json'; Extra = @('-Json') }
)

$failures = 0
foreach ($case in $cases) {
    $dir = Join-Path $PSScriptRoot (Join-Path 'fixtures' $case.Name)
    foreach ($mode in $modes) {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $report,
                       '-Validate', '-Dir', $dir) + $mode.Extra
        & powershell.exe @arguments *> $null
        $code = $LASTEXITCODE
        $ok = ($code -eq $case.Expected)
        if (-not $ok) { $failures++ }
        '{0,-9} {1,-5} expected {2}  got {3}  {4}' -f `
            $case.Name, $mode.Label, $case.Expected, $code, $(if ($ok) { 'ok' } else { 'FAIL' })
    }
}

if ($failures -gt 0) {
    Write-Host ''
    Write-Host "$failures case(s) FAILED"
    exit 1
}
Write-Host ''
Write-Host 'all exit-code cases passed'
exit 0
