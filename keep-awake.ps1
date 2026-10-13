# Keep the desktop session awake until the deadline: micro mouse jiggle + display-required state.
# Purpose: the GUI harvest path needs an unlocked, rendering desktop; an idle lock would kill it.
param([DateTime]$Until = '2026-10-11 08:00')

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Awake {
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
}
'@

$ES_CONTINUOUS = 0x80000000; $ES_SYSTEM_REQUIRED = 0x1; $ES_DISPLAY_REQUIRED = 0x2
[void][Awake]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)

$orig = [System.Windows.Forms.Cursor]::Position
Write-Host ("keep-awake active until {0}; cursor at {1},{2}" -f $Until, $orig.X, $orig.Y)
while ((Get-Date) -lt $Until) {
    Start-Sleep -Seconds 45
    $p = [System.Windows.Forms.Cursor]::Position
    # One-pixel round trip: invisible to a human, enough to reset the idle timer.
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($p.X, ($p.Y + 1) % 1440)
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.Cursor]::Position = $p
    [void][Awake]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)
}
[System.Windows.Forms.Cursor]::Position = $orig
[void][Awake]::SetThreadExecutionState($ES_CONTINUOUS)
Write-Host 'keep-awave finished'
