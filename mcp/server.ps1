# gputrace-mcp: a zero-dependency MCP server (stdio, PowerShell) exposing headless GPU Trace
# analysis. Windows + Nsight Graphics is the target audience, so PowerShell is the only runtime
# requirement - no Node, no Python, no package installs.
#
# Tools (all wrap the PowerShell CLI in this repo's root - the CLI is the engine, this server is
# the LLM-facing interface):
#   gputrace_capture      - capture traces per variant (needs NVIDIA counter access; on GeForce
#                           without the Control Panel "allow all users" toggle it relaunches
#                           elevated via UAC, which requires a human at the machine)
#   gputrace_report       - validated JSON report for one capture directory
#   gputrace_compare      - validated side-by-side comparison of 2+ capture directories
#   gputrace_list_metrics - every metric instance in a capture (incl. same-name duplicates)
#   gputrace_raw_metric   - raw per-frame rows for metrics matching a pattern (auditability)
#
# Accuracy contract (embedded in every report/compare response):
#   - captures that failed validation are refused, never returned as data
#   - every value carries an evidence class (sampled | count | rate | peak-normalised | time)
#   - aggregation semantics are stated: GUI displays are time-weighted over the whole trace,
#     export medians are over captured frames - expect 2-3% differences between the two
#
# Naming rule learned the hard way: never name a parameter or variable $input - it collides
# with PowerShell's automatic pipeline-input variable ($toolInput everywhere below). The same
# case-insensitivity once shadowed $TOOLS with a local $tools and emptied the tool list.
#
# Transport: newline-delimited JSON-RPC 2.0 on stdin/stdout (MCP stdio).

$ErrorActionPreference = 'Stop'
$SERVER_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$TOOLS_DIR = if ($env:GPUTRACE_TOOLS_DIR) { $env:GPUTRACE_TOOLS_DIR } else { Split-Path -Parent $SERVER_ROOT }
$CAPTURE_SCRIPT = Join-Path $TOOLS_DIR 'gputrace-capture.ps1'
$REPORT_SCRIPT = Join-Path $TOOLS_DIR 'gputrace-report.ps1'
$CAPTURE_TIMEOUT_MS = 20 * 60 * 1000
$REPORT_TIMEOUT_MS = 5 * 60 * 1000

$AGGREGATION_NOTE =
  'Aggregation semantics: the Nsight GUI displays time-weighted values over the whole trace ' +
  '(including idle frames), while export medians are over captured frames only - expect 2-3% ' +
  'differences between the two on identical captures. Evidence classes: sampled = warp-state ' +
  '(PC) sampler quantities, same source as the GUI Top Stall table; peak-normalised = counter ' +
  'ratios against an assumed peak; count = deterministic event totals; rate = per-cycle ' +
  'averages; time = durations with bounded jitter.'

function Invoke-Cli {
    param([string]$Script, [string[]]$CliArgs, [int]$TimeoutMs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    # A plain space-join is safe here: the CLI paths and args contain no spaces, and quoting
    # through ProcessStartInfo.Arguments has its own escaping rules that do not apply.
    $psi.Arguments = ((@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $CliArgs) | ForEach-Object { $_ }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutMs)) {
        try { $proc.Kill() } catch { }
        return @{ Code = -1; Stdout = ''; Stderr = 'CLI timed out' }
    }
    return @{ Code = $proc.ExitCode; Stdout = $outTask.Result; Stderr = $errTask.Result }
}

function ConvertFrom-JsonLoose {
    param([string]$Text)
    $m = [regex]::Match($Text, '[\[{]')
    if (-not $m.Success) { return $null }
    $candidate = $Text.Substring($m.Index)
    try { return $candidate | ConvertFrom-Json } catch { }
    for ($end = $candidate.Length; $end -gt 2; $end--) {
        $last = $candidate[$end - 1]
        if ($last -eq '}' -or $last -eq ']') {
            try { return $candidate.Substring(0, $end) | ConvertFrom-Json } catch { }
        }
    }
    return $null
}

function Get-ValidationBlocks {
    param($Payload)
    $failed = @()
    if ($null -eq $Payload -or $null -eq $Payload.traces) { return $null }
    foreach ($trace in $Payload.traces) {
        if ($null -eq $trace.validation) { continue }
        foreach ($check in $trace.validation) {
            if ($check.Status -eq 'FAIL') { $failed += @{ check = $check.Check; detail = $check.Detail } }
        }
    }
    if ($failed.Count -gt 0) { return $failed }
    return $null
}

function Invoke-ToolCapture {
    param([hashtable]$toolInput)
    if (-not (Test-Path -LiteralPath $CAPTURE_SCRIPT)) {
        return @{ error = "capture script missing: $CAPTURE_SCRIPT" }
    }
    $cliArgs = @()
    if ($toolInput.profile) { $cliArgs += @('-Profile', $toolInput.profile) }
    if ($toolInput.exe) { $cliArgs += @('-Exe', $toolInput.exe) }
    if ($toolInput.appArgs) { $cliArgs += @('-AppArgs', $toolInput.appArgs) }
    if ($toolInput.outDir) { $cliArgs += @('-OutDir', $toolInput.outDir) }
    if ($toolInput.workDir) { $cliArgs += @('-WorkDir', $toolInput.workDir) }
    if ($toolInput.ngfxPath) { $cliArgs += @('-NgfxPath', $toolInput.ngfxPath) }
    $saf = 300; if ($toolInput.startAfterFrames) { $saf = $toolInput.startAfterFrames }
    $fr = 8; if ($toolInput.frames) { $fr = $toolInput.frames }
    $as = 20; if ($toolInput.appSeconds) { $as = $toolInput.appSeconds }
    $cliArgs += @('-StartAfterFrames', [string]$saf)
    $cliArgs += @('-Frames', [string]$fr)
    $cliArgs += @('-AppSeconds', [string]$as)
    # Sampling on by default: this is the tool's reason to exist. Opt out explicitly.
    if ($toolInput.shaderProfiler -eq $false) { $cliArgs += '-MultiPassMetrics' } else { $cliArgs += '-ShaderProfiler' }

    $run = Invoke-Cli -Script $CAPTURE_SCRIPT -CliArgs $cliArgs -TimeoutMs $CAPTURE_TIMEOUT_MS
    $elevated = $run.Stdout -match 'relaunching with a UAC prompt'
    $failures = @()
    foreach ($m in [regex]::Matches($run.Stdout, '(\S+): FAILED - (.+)')) {
        $failures += @{ target = $m.Groups[1].Value; reason = $m.Groups[2].Value }
    }
    $exported = @()
    foreach ($m in [regex]::Matches($run.Stdout, '(\S+) -> (\S+)')) {
        $base = Join-Path $m.Groups[2].Value 'BASE\REPRO_INFO.xls'
        if (Test-Path -LiteralPath $base) { $exported += @{ target = $m.Groups[1].Value; dir = $m.Groups[2].Value } }
    }
    $notes = @()
    if ($elevated) {
        $notes += 'The capture relaunches elevated via UAC - a human must approve the prompt on the machine.'
        $notes += 'To remove the prompt permanently: NVIDIA Control Panel > Developer > Manage GPU Performance Counters > allow access to all users.'
    } else {
        $notes += 'Capture ran without elevation (counters accessible to all users).'
    }
    $tail = ($run.Stdout -split "`r?`n") | Select-Object -Last 25
    return @{
        exitCode = $run.Code
        elevatedViaUac = $elevated
        succeeded = ($run.Code -eq 0 -and $failures.Count -eq 0 -and $exported.Count -gt 0)
        exported = $exported
        failures = $failures
        notes = $notes
        stdoutTail = ($tail -join "`n")
    }
}

function Invoke-ToolReport {
    param([hashtable]$toolInput)
    $dir = [string]$toolInput.dir
    if (-not $dir) { return @{ error = 'dir is required (path to a capture directory containing BASE\)' } }
    $run = Invoke-Cli -Script $REPORT_SCRIPT -CliArgs @('-Dir', $dir, '-Validate', '-Json') -TimeoutMs $REPORT_TIMEOUT_MS
    $payload = ConvertFrom-JsonLoose $run.Stdout
    if ($null -eq $payload -or $null -eq $payload.traces) {
        return @{ error = 'could not parse report output'; stdoutTail = $run.Stdout.Substring([Math]::Max(0, $run.Stdout.Length - 2000)) }
    }
    $blocked = Get-ValidationBlocks $payload
    if ($null -ne $blocked) {
        return @{ error = 'validation FAILED - do not cite these numbers'; validationFailures = $blocked;
                  hint = 'Re-capture or inspect with gputrace_raw_metric; raw data is not returned when validation fails.' }
    }
    $notes = @()
    foreach ($n in $payload.notes) { $notes += $n }
    return @{ traces = $payload.traces; notes = $notes; aggregationSemantics = $AGGREGATION_NOTE }
}

function Invoke-ToolCompare {
    param([hashtable]$toolInput)
    $dirs = $toolInput.dirs
    if (-not $dirs -or @($dirs).Count -lt 2) { return @{ error = 'dirs must list at least two capture directories' } }
    $joined = (@($dirs) -join ',')
    $run = Invoke-Cli -Script $REPORT_SCRIPT -CliArgs @('-Compare', $joined, '-Validate', '-Json') -TimeoutMs $REPORT_TIMEOUT_MS
    $payload = ConvertFrom-JsonLoose $run.Stdout
    if ($null -eq $payload -or $null -eq $payload.traces) {
        return @{ error = 'could not parse compare output'; stdoutTail = $run.Stdout.Substring([Math]::Max(0, $run.Stdout.Length - 2000)) }
    }
    $blocked = Get-ValidationBlocks $payload
    if ($null -ne $blocked) { return @{ error = 'validation FAILED - do not cite these numbers'; validationFailures = $blocked } }
    $notes = @()
    foreach ($n in $payload.notes) { $notes += $n }
    return @{ traces = $payload.traces; notes = $notes; aggregationSemantics = $AGGREGATION_NOTE }
}

function Invoke-ToolListMetrics {
    param([hashtable]$toolInput)
    $dir = [string]$toolInput.dir
    if (-not $dir) { return @{ error = 'dir is required' } }
    $run = Invoke-Cli -Script $REPORT_SCRIPT -CliArgs @('-Dir', $dir, '-List', '-Json') -TimeoutMs $REPORT_TIMEOUT_MS
    $payload = ConvertFrom-JsonLoose $run.Stdout
    if ($null -eq $payload) { return @{ error = 'could not parse list output'; stdoutTail = $run.Stdout.Substring([Math]::Max(0, $run.Stdout.Length - 2000)) } }
    return $payload
}

function Invoke-ToolRawMetric {
    param([hashtable]$toolInput)
    $dir = [string]$toolInput.dir
    $pattern = [string]$toolInput.pattern
    if (-not $dir -or -not $pattern) { return @{ error = 'dir and pattern are required' } }
    $run = Invoke-Cli -Script $REPORT_SCRIPT -CliArgs @('-Dir', $dir, '-Metric', $pattern, '-Json') -TimeoutMs $REPORT_TIMEOUT_MS
    $payload = ConvertFrom-JsonLoose $run.Stdout
    if ($null -eq $payload) { return @{ error = 'could not parse raw metric output'; stdoutTail = $run.Stdout.Substring([Math]::Max(0, $run.Stdout.Length - 2000)) } }
    return @{ metrics = $payload;
              note = 'Raw per-frame values as stored in the export. Same-name instances appear as Name, Name#2, ... - compare instances before citing.' }
}

$TOOLS = @(
    @{ name = 'gputrace_capture'
       description = ('Capture GPU Trace(s) of a target application headlessly via the Nsight Graphics CLI, ' +
                      'with warp-state sampling ON (the data behind the GUI Top Stall table) and auto-export ' +
                      'of all metrics. One trace per variant/arm. Requires NVIDIA counter access; on GeForce ' +
                      'without the Control Panel "allow all users" toggle it relaunches elevated (UAC prompt - ' +
                      'needs a human). Returns per-target status and exported directories.')
       inputSchema = @{
           type = 'object'
           properties = @{
               profile = @{ type = 'string'; description = 'Required. Profile name (resolved under profiles\) or a path to a profile JSON. Defines exe, workDir, app args and the variants to trace.' }
               exe = @{ type = 'string'; description = 'Overrides the profile executable path.' }
               appArgs = @{ type = 'string'; description = 'Overrides the base application arguments.' }
               outDir = @{ type = 'string'; description = 'Output directory root, relative to the profile workDir (default gputrace).' }
               workDir = @{ type = 'string'; description = 'Overrides the profile workDir: the directory the application is launched in.' }
               ngfxPath = @{ type = 'string'; description = 'ngfx.exe or its directory. Only needed when the automatic Nsight Graphics search misses (unusual install path, several versions).' }
               startAfterFrames = @{ type = 'number'; description = 'Frames to skip before capturing (default 300).' }
               frames = @{ type = 'number'; description = 'Frames to capture (default 8).' }
               appSeconds = @{ type = 'number'; description = 'Seconds substituted into the profile appTimeoutArgs template. Only bounds the run if the profile declares that template - nothing here watches the application process.' }
               shaderProfiler = @{ type = 'boolean'; description = 'Warp-state sampling on (default true). Set false for plain multi-pass counters.' }
           }
       }
       handler = 'Invoke-ToolCapture' }
    @{ name = 'gputrace_report'
       description = ('Validated JSON report for one capture directory: frame/event timing, focus metrics with ' +
                      'evidence classes, counter stall breakdown (16 reasons), warp-state sampled stall breakdown ' +
                      '(20 reasons, when the capture ran with sampling), provenance. Captures that fail validation ' +
                      'are refused. Quote numbers only with their evidence class.')
       inputSchema = @{ type = 'object'; properties = @{ dir = @{ type = 'string'; description = 'Capture directory (contains BASE\ exports).' } }; required = @('dir') }
       handler = 'Invoke-ToolReport' }
    @{ name = 'gputrace_compare'
       description = ('Validated side-by-side comparison of 2+ capture directories: sampled + counter stall ' +
                      'tables, per-pass timing, focus metrics, provenance. Compare captures of the SAME work, ' +
                      'never different workloads.')
       inputSchema = @{ type = 'object'; properties = @{ dirs = @{ type = 'array'; items = @{ type = 'string' }; description = '2+ capture directories.' } }; required = @('dirs') }
       handler = 'Invoke-ToolCompare' }
    @{ name = 'gputrace_list_metrics'
       description = ('List every metric instance stored in a capture, including same-name duplicate instances ' +
                      '(Name, Name#2, ...) which can differ by 2x between rollup levels. Use before citing a ' +
                      'metric to pick the right instance.')
       inputSchema = @{ type = 'object'; properties = @{ dir = @{ type = 'string' } }; required = @('dir') }
       handler = 'Invoke-ToolListMetrics' }
    @{ name = 'gputrace_raw_metric'
       description = 'Raw per-frame values for metrics matching a regex - the unaggregated source rows. Use to audit any aggregated claim.'
       inputSchema = @{ type = 'object'; properties = @{ dir = @{ type = 'string' }; pattern = @{ type = 'string'; description = 'Regex on metric name, e.g. "PCSampler.*stalled"' } }; required = @('dir', 'pattern') }
       handler = 'Invoke-ToolRawMetric' }
)

$PROTOCOL_VERSION = '2024-11-05'
$script:INITIALIZED = $false

function Send-Reply {
    param([long]$Id, $Result)
    $msg = @{ jsonrpc = '2.0'; id = $Id; result = $Result }
    [Console]::Out.WriteLine(($msg | ConvertTo-Json -Depth 30 -Compress))
}
function Send-Error {
    param([long]$Id, [int]$Code, [string]$Message)
    $msg = @{ jsonrpc = '2.0'; id = $Id; error = @{ code = $Code; message = $Message } }
    [Console]::Out.WriteLine(($msg | ConvertTo-Json -Depth 30 -Compress))
}

function Invoke-Dispatch {
    param([string]$Method, $Params)
    switch ($Method) {
        'initialize' {
            $script:INITIALIZED = $true
            $requested = '2024-11-05'
            if ($Params -and $Params.protocolVersion) { $requested = [string]$Params.protocolVersion }
            return @{ protocolVersion = $requested
                      capabilities = @{ tools = @{} }
                      serverInfo = @{ name = 'gputrace-mcp'; version = '0.1.0' } }
        }
        'tools/list' {
            $toolDefs = @()
            foreach ($t in $TOOLS) {
                $toolDefs += @{ name = $t.name; description = $t.description; inputSchema = $t.inputSchema }
            }
            return @{ tools = $toolDefs }
        }
        'tools/call' {
            $name = [string]$Params.name
            $tool = $TOOLS | Where-Object { $_.name -eq $name } | Select-Object -First 1
            if ($null -eq $tool) { throw "unknown tool: $name" }
            $toolInput = @{}
            if ($Params.arguments) {
                foreach ($prop in $Params.arguments.PSObject.Properties) { $toolInput[$prop.Name] = $prop.Value }
            }
            $content = & $tool.handler $toolInput
            $text = $content | ConvertTo-Json -Depth 30 -Compress
            $isError = ($null -ne $content -and $content.error)
            return @{ content = @(@{ type = 'text'; text = $text }); isError = [bool]$isError }
        }
        'ping' { return @{} }
        default { throw "method not found: $Method" }
    }
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if (-not $line.Trim()) { continue }
    $msg = $null
    try { $msg = $line | ConvertFrom-Json } catch { continue }
    if ($null -eq $msg -or $msg.jsonrpc -ne '2.0' -or $null -eq $msg.id) { continue }
    try {
        $result = Invoke-Dispatch -Method $msg.method -Params $msg.params
        Send-Reply -Id ([long]$msg.id) -Result $result
    } catch {
        Send-Error -Id ([long]$msg.id) -Code -32603 -Message $_.Exception.Message
    }
}
