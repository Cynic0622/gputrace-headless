# E2E test: spawn mcp/server.ps1, speak MCP stdio JSON-RPC, exercise all five tools.
$ErrorActionPreference = 'Stop'
$serverPath = Join-Path $PSScriptRoot 'server.ps1'

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverPath`""
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)

function Send-Mcp {
    param([long]$Id, [string]$Method, $Params)
    $msg = @{ jsonrpc = '2.0'; id = $Id; method = $Method }
    if ($null -ne $Params) { $msg.params = $Params }
    $proc.StandardInput.WriteLine(($msg | ConvertTo-Json -Depth 12 -Compress))
}

function Read-Mcp {
    param([string]$ExpectMethod, [int]$TimeoutMs = 300000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $lineTask = $proc.StandardOutput.ReadLineAsync()
        while (-not $lineTask.Wait(200)) {
            if ($proc.HasExited) { throw "server exited unexpectedly (code $($proc.ExitCode))" }
            if ([DateTime]::UtcNow -gt $deadline) { throw "timeout waiting for $ExpectMethod" }
        }
        $line = $lineTask.Result
        if (-not $line) { continue }
        $msg = $line | ConvertFrom-Json
        if ($null -ne $msg.id) { return $msg }
        # notifications ignored
    }
    throw "timeout waiting for $ExpectMethod"
}

$id = 0
function Next-Id { $script:id++; return $script:id }

Write-Host '== 1. initialize =='
Send-Mcp -Id (Next-Id) -Method 'initialize' -Params @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'test'; version = '0' } }
$init = Read-Mcp 'initialize'
Write-Host ("protocol: {0}  server: {1}" -f $init.result.protocolVersion, $init.result.serverInfo.name)
$proc.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')

Write-Host '== 2. tools/list =='
Send-Mcp -Id (Next-Id) -Method 'tools/list'
$list = Read-Mcp 'tools/list'
Write-Host ("tools: {0}" -f (($list.result.tools | ForEach-Object { $_.name }) -join ', '))

Write-Host '== 3. gputrace_report (gputrace-rts/arm0, validated) =='
Send-Mcp -Id (Next-Id) -Method 'tools/call' -Params @{ name = 'gputrace_report'; arguments = @{ dir = 'D:\Code\Bear\gputrace-rts\arm0' } }
$rep = Read-Mcp 'tools/call'
$repPayload = $rep.result.content[0].text | ConvertFrom-Json
$t0 = $repPayload.traces[0]
Write-Host ("validated OK; frame_time {0:N3} ms; sampled stall top: {1}" -f $t0.frame_time_ms,
    (($t0.stalls_sampled.reasons.PSObject.Properties | Sort-Object { -[double]$_.Value } | Select-Object -First 2 | ForEach-Object { "$($_.Name)=$([Math]::Round([double]$_.Value,2))" }) -join ', '))

Write-Host '== 4. gputrace_compare (3 arms) =='
Send-Mcp -Id (Next-Id) -Method 'tools/call' -Params @{ name = 'gputrace_compare'; arguments = @{ dirs = @('D:\Code\Bear\gputrace-rts\arm0', 'D:\Code\Bear\gputrace-rts\arm1', 'D:\Code\Bear\gputrace-rts\arm2') } }
$cmp = Read-Mcp 'tools/call'
$cmpPayload = $cmp.result.content[0].text | ConvertFrom-Json
Write-Host ("arms compared: {0}; isError: {1}" -f $cmpPayload.traces.Count, $cmp.result.isError)

Write-Host '== 5. gputrace_list_metrics =='
Send-Mcp -Id (Next-Id) -Method 'tools/call' -Params @{ name = 'gputrace_list_metrics'; arguments = @{ dir = 'D:\Code\Bear\gputrace-rts\arm0' } }
$lm = Read-Mcp 'tools/call'
$lmPayload = $lm.result.content[0].text | ConvertFrom-Json
Write-Host ("metric instances: {0}" -f $lmPayload.metrics.Count)

Write-Host '== 6. gputrace_raw_metric (PCSampler stalls) =='
Send-Mcp -Id (Next-Id) -Method 'tools/call' -Params @{ name = 'gputrace_raw_metric'; arguments = @{ dir = 'D:\Code\Bear\gputrace-rts\arm0'; pattern = 'PCSampler.*stalled' } }
$raw = Read-Mcp 'tools/call'
$rawPayload = $raw.result.content[0].text | ConvertFrom-Json
Write-Host ("raw metrics matched: {0}" -f $rawPayload.metrics.Count)

Write-Host '== 7. gputrace_capture (real, non-elevated, arm0 only) =='
Send-Mcp -Id (Next-Id) -Method 'tools/call' -Params @{ name = 'gputrace_capture'; arguments = @{ profile = 'ntc-benchmark'; outDir = (Join-Path $env:TEMP 'gputrace-mcp-e2e'); startAfterFrames = 300; frames = 8; appSeconds = 15 } }
$cap = Read-Mcp 'tools/call' 600000
$capPayload = $cap.result.content[0].text | ConvertFrom-Json
Write-Host ("succeeded: {0}  elevated: {1}  exported: {2}" -f $capPayload.succeeded, $capPayload.elevatedViaUac,
    (($capPayload.exported | ForEach-Object { $_.target }) -join ','))

if (-not $proc.HasExited) { $proc.Kill() }
Write-Host 'E2E DONE'
