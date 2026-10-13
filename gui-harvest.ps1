# GUI harvest primitives: drive Nsight Graphics to expose what only the GUI renders, and capture
# it as PNGs for the agent to read. Three actions, one per invocation, so each step can be chosen
# from what the previous screenshot actually showed.
#
#     .\gui-harvest.ps1 -Action shot  -Out gui\step1.png
#     .\gui-harvest.ps1 -Action open  -TraceFile gputrace\arm0\Sandbox_*.ngfx-gputrace
#     .\gui-harvest.ps1 -Action keys  -Keys '^o'        # then -Action shot to look
#     .\gui-harvest.ps1 -Action close                 # close only instances we spawned
param(
    [string]$Action = 'shot',
    [string]$Out = 'gui\shot.png',
    [string]$TraceFile = '',
    [string]$Keys = '',
    [int]$WaitSeconds = 8,
    [int]$X = 0,
    [int]$Y = 0,
    [int]$DeltaX = 0,
    [int]$DeltaY = 0,
    # Nsight Graphics' ngfx-ui.exe, or the directory holding it - ngfx.exe's own folder works,
    # since the two ship side by side. Only needed when the automatic search misses.
    [string]$NgfxPath = '',
    # Base for a relative -Out. Defaults to the current directory, since the traces and the
    # screenshots live wherever the capture ran, not next to this script.
    [string]$WorkDir = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ngfx-ui.exe ships beside ngfx.exe, so one discovery covers both - see gputrace-common.ps1.
. (Join-Path $PSScriptRoot 'gputrace-common.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$sig = @'
using System;
using System.Runtime.InteropServices;
public static class Win32Focus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, IntPtr dwExtraInfo);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int w, int h, bool repaint);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }
    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
}
'@
Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue

$uiExe = Find-NgfxUi -Explicit $NgfxPath
$stateFile = Join-Path $env:TEMP 'gputrace-gui-harvest-state.txt'

function Get-OurUiProcesses {
    # Instances this harvest launched (recorded in the state file), never the user's own.
    $pids = @()
    if (Test-Path $stateFile) { $pids = @(Get-Content $stateFile | ForEach-Object { [int]$_ }) }
    @(Get-Process -Name 'ngfx-ui' -ErrorAction SilentlyContinue | Where-Object { $pids -contains $_.Id })
}

function Wait-MainWindow {
    param([System.Diagnostics.Process]$Process, [int]$Seconds = 30)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Focus-Ui {
    param($Process)
    [void][Win32Focus]::ShowWindow($Process.MainWindowHandle, 9)   # SW_RESTORE
    [void][Win32Focus]::SetForegroundWindow($Process.MainWindowHandle)
    Start-Sleep -Milliseconds 600
}

switch ($Action) {
    'shot' {
        $outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $WorkDir $Out }
        New-Item -ItemType Directory -Force -Path (Split-Path $outPath -Parent) | Out-Null
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
        $g.Dispose()
        $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Host "saved $outPath ($($bounds.Width)x$($bounds.Height))"
    }
    'keys' {
        $ours = Get-OurUiProcesses
        $target = $null
        foreach ($p in $ours) {
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $target = $p; break }
        }
        if (-not $target) {
            # Fall back to any ngfx-ui window: the user's instance still shows GUI data, and keys
            # sent there only navigate - nothing destructive. Say so in the output.
            $target = Get-Process -Name 'ngfx-ui' -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
            if ($target) { Write-Host "warning: no harvest-owned UI; using foreign instance PID $($target.Id)" }
        }
        if (-not $target) { throw 'no ngfx-ui window to receive keys' }
        Focus-Ui $target
        [System.Windows.Forms.SendKeys]::SendWait($Keys)
        Write-Host ("sent '{0}' to PID {1}" -f $Keys, $target.Id)
    }
    'open' {
        if (-not (Test-Path -LiteralPath $TraceFile)) { throw "trace not found: $TraceFile" }
        $full = (Get-Item -LiteralPath $TraceFile).FullName

        $ours = Get-OurUiProcesses
        $target = $ours | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        if (-not $target) {
            Write-Host 'launching ngfx-ui...'
            # A private shared-instance key stops Qt from forwarding the open to an existing UI
            # instance and exiting - which killed the first harvest run when the user's own UI
            # was up. Our own process is also the only one that reliably accepted keys/clicks.
            $p = Start-Process -FilePath $uiExe -ArgumentList '--no-splash', '--shared-instance-key', 'gputrace-gui-harvest' -PassThru
            $pids = @()
            if (Test-Path $stateFile) { $pids = @(Get-Content $stateFile) }
            $pids += $p.Id
            Set-Content -LiteralPath $stateFile -Value $pids
            if (-not (Wait-MainWindow -Process $p -Seconds 60)) { throw 'ngfx-ui never showed a window' }
            Start-Sleep -Seconds 4
            $target = $p
        }
        Focus-Ui $target

        # Ctrl+O, type the full path, Enter. The path contains no SendKeys metacharacters.
        [System.Windows.Forms.SendKeys]::SendWait('^o')
        Start-Sleep -Seconds 2
        [System.Windows.Forms.SendKeys]::SendWait($full)
        Start-Sleep -Milliseconds 400
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Write-Host ("open sent for {0}; waiting {1}s for load" -f $full, $WaitSeconds)
        Start-Sleep -Seconds $WaitSeconds
        Write-Host ("window title: '{0}'" -f $target.MainWindowTitle)
    }
    'click' {
        # Move the cursor to (X,Y) and click. On 2026-10-11 this desktop briefly pinned the cursor
        # (security software denied SetCursorPos); that was transient - the move is verified and
        # retried, and a failed move is reported instead of clicking blind.
        $ok = $false
        for ($try = 0; $try -lt 4; $try++) {
            [void][Win32Focus]::SetCursorPos($X, $Y)
            Start-Sleep -Milliseconds 200
            $at = [System.Windows.Forms.Cursor]::Position
            if ($at.X -eq $X -and $at.Y -eq $Y) { $ok = $true; break }
            Write-Host ("cursor drifted to {0},{1}; retrying" -f $at.X, $at.Y)
        }
        if (-not $ok) { throw "cursor could not be placed at $X,$Y - input is being pinned" }
        $down = New-Object Win32Focus+INPUT
        $down.type = 0
        $down.U.mi.dx = 0; $down.U.mi.dy = 0
        $down.U.mi.mouseData = 0; $down.U.mi.dwFlags = 0x0002
        $down.U.mi.time = 0; $down.U.mi.dwExtraInfo = [IntPtr]::Zero
        $up = New-Object Win32Focus+INPUT
        $up.type = 0
        $up.U.mi.dx = 0; $up.U.mi.dy = 0
        $up.U.mi.mouseData = 0; $up.U.mi.dwFlags = 0x0004
        $up.U.mi.time = 0; $up.U.mi.dwExtraInfo = [IntPtr]::Zero
        $batch = @($down, $up)
        $n = [Win32Focus]::SendInput(2, $batch, [System.Runtime.InteropServices.Marshal]::SizeOf([type][Win32Focus+INPUT]))
        Start-Sleep -Milliseconds 400
        Write-Host ("clicked at {0},{1} (injected {2}/2)" -f $X, $Y, $n)
    }
    'dblclick' {
        # A real double-click: both clicks inside one injection burst, 120ms apart. Two separate
        # invocations are seconds apart and the app sees two single clicks.
        $ok = $false
        for ($try = 0; $try -lt 4; $try++) {
            [void][Win32Focus]::SetCursorPos($X, $Y)
            Start-Sleep -Milliseconds 200
            $at = [System.Windows.Forms.Cursor]::Position
            if ($at.X -eq $X -and $at.Y -eq $Y) { $ok = $true; break }
            Write-Host ("cursor drifted to {0},{1}; retrying" -f $at.X, $at.Y)
        }
        if (-not $ok) { throw "cursor could not be placed at $X,$Y - input is being pinned" }
        # Two down/up pairs with a 120ms gap: inside the system double-click time, but not so fast
        # that the app sees one mangled click (a zero-gap burst only selected the row).
        $pairs = @()
        foreach ($gap in @(0, 1)) {
            $down = New-Object Win32Focus+INPUT
            $down.type = 0; $down.U.mi.dwFlags = 0x0002
            $up = New-Object Win32Focus+INPUT
            $up.type = 0; $up.U.mi.dwFlags = 0x0004
            $pairs += ,@($down, $up)
        }
        $null = [Win32Focus]::SendInput(2, $pairs[0], [System.Runtime.InteropServices.Marshal]::SizeOf([type][Win32Focus+INPUT]))
        Start-Sleep -Milliseconds 120
        $n = [Win32Focus]::SendInput(2, $pairs[1], [System.Runtime.InteropServices.Marshal]::SizeOf([type][Win32Focus+INPUT]))
        Start-Sleep -Milliseconds 500
        Write-Host ("double-clicked at {0},{1} (injected last {2}/2)" -f $X, $Y, $n)
    }
    'movewin' {
        # Shift the Nsight window by (DeltaX, DeltaY) so the desired widget lands under the pinned
        # cursor. Un-maximize first if needed (a maximized window cannot move).
        $ui = Get-Process -Name 'ngfx-ui' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        if (-not $ui) { throw 'no ngfx-ui window' }
        $hwnd = $ui.MainWindowHandle
        $style = [Win32Focus]::GetWindowLong($hwnd, -16)   # GWL_STYLE
        if ($style -band 0x01000000) {                      # WS_MAXIMIZE
            Write-Host 'window is maximized; restoring first'
            [void][Win32Focus]::PostMessage($hwnd, 0x0112, [IntPtr]0xF120, [IntPtr]::Zero)  # SC_RESTORE
            Start-Sleep -Seconds 2
        }
        $rect = New-Object Win32Focus+RECT
        [void][Win32Focus]::GetWindowRect($hwnd, [ref]$rect)
        $newX = $rect.Left + $DeltaX
        $newY = $rect.Top + $DeltaY
        [void][Win32Focus]::MoveWindow($hwnd, $newX, $newY, $rect.Right - $rect.Left, $rect.Bottom - $rect.Top, $true)
        Start-Sleep -Milliseconds 800
        $rect2 = New-Object Win32Focus+RECT
        [void][Win32Focus]::GetWindowRect($hwnd, [ref]$rect2)
        Write-Host ("window moved: ({0},{1}) -> ({2},{3})" -f $rect.Left, $rect.Top, $rect2.Left, $rect2.Top)
    }
    'close' {
        $ours = Get-OurUiProcesses
        foreach ($p in $ours) {
            Write-Host ("closing harvest-owned instance PID {0}" -f $p.Id)
            $null = $p.CloseMainWindow()
        }
        Start-Sleep -Seconds 3
        Remove-Item -LiteralPath $stateFile -ErrorAction SilentlyContinue
        Write-Host 'done'
    }
    default { throw "unknown action '$Action'" }
}
