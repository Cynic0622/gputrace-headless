# GUI harvest: drive Nsight Graphics to expose what only the GUI renders. Two halves - screenshot
# primitives that capture PNGs for the agent to read, and UI Automation actions that drive named
# controls and pull the per-instruction attribution out as CSV. One action per invocation, so each
# step can be chosen from what the previous screenshot actually showed.
#
#     .\cli\gui-harvest.ps1 -Action shot  -Out gui\step1.png
#     .\cli\gui-harvest.ps1 -Action open  -TraceFile gputrace\arm0\Sandbox_*.ngfx-gputrace
#     .\cli\gui-harvest.ps1 -Action keys  -Keys '^o'        # then -Action shot to look
#     .\cli\gui-harvest.ps1 -Action close                 # close only instances we spawned
#
# The screenshot/keystroke actions above are coordinate-blind: they work only if the previous
# screenshot showed you where to aim. For anything that has to hit a *named* control - tabs,
# buttons, context-menu entries, dialog fields - use the UI Automation actions instead. They
# locate elements by name, so they survive the window moving, DPI changes and layout drift:
#
#     .\cli\gui-harvest.ps1 -Action selftest                      # is UI Automation usable here?
#     .\cli\gui-harvest.ps1 -Action find   -Name 'Shader'  -Out gui\find.txt
#     .\cli\gui-harvest.ps1 -Action invoke -Name 'Export to CSV...' -IdMatch 'Shader Source'
#     .\cli\gui-harvest.ps1 -Action export -ViewName 'Shader Source' -OutCsv gui\source.csv
#
# `export` is the point of the UIA half: Nsight renders per-instruction attribution only in its
# own views, and the CSV exporter behind those views (NV::UI::CSVExporter::ExportToFile) has no
# CLI front end. Driving the GUI is the one supported route to that data, and the only reason
# this script exists - gputrace-sampling.ps1 reaches the same samples from inside the container.
#
# What the UI actually looks like (measured on 2026.1.0, a trace loaded). Nsight is Qt, so every
# AutomationId is the full object path, which is what makes -IdMatch the precise way to aim:
#
#   view tabs    name 'Instruction Mix' / 'Shader Source' / ..., id ...FlatTabButton_<View>,
#                ControlType CheckBox. Invoke() TOGGLES a CheckBox, so use TogglePattern and check
#                the state first - Select-UiTab does that. Note the top document well and the
#                bottom dock are separate FlatTabWidgets, so two tabs can read "on" at once.
#   view bodies  id ...FlatTabPanel_<View>, a subtree per view.
#   Shader Source  has a direct button 'Export to CSV...' under ShaderProfiler::UI::SourceDetails.
#                This is the view that matters: its CSV is per source line, with Samples, the top
#                three stall types, Avg. Warp Latency, Instruction Mix, Dependency-Attributed
#                Samples and Live Registers - the GUI-only attribution.
#   Instruction Mix  no export button. It is three horizontally-scrolled QTreeViews with no
#                working context menu (verified: a right-click on them opens nothing). Its numbers
#                are already carried by the Shader Source CSV's 'Instruction Mix' column.
#   'Export to CSV' is ambiguous - the command bar has a *log* export with the same caption, and
#                clicking it opens an 'Export log messages' dialog. Anything under
#                commandBar/ExportLogsCommand must be skipped.
#   save dialog  a native Win32 common dialog, class '#32770', titled 'Save CSV file' - NOT the
#                'CSV Export' string that exists in the binaries. Its controls:
#                  filename   class Edit, AutomationId 1001, inside FileNameControlHost
#                  Save       ClassName Button, AutomationId 1, but ControlType Pane
#                Neither control supports ANY UIA pattern, and SendKeys is unusable (the IME eats
#                every backslash, so a path lands as 'C:Users...out.csv'). The filename goes in via
#                WM_SETTEXT and the Save button is clicked by geometry. Because a click on a
#                visible-but-not-foreground window is swallowed by activation, the dialog is given
#                the focus with AttachThreadInput first.
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
    # --- UI Automation actions ---
    # Element name to match for -Action invoke. Exact match first, then a case-insensitive
    # substring match, so 'Export' finds 'Export...'.
    [string]$Name = '',
    # Optional ControlType filter for -Action invoke, e.g. MenuItem, Button, TabItem.
    [string]$ControlType = '',
    # Optional AutomationId substring filter. Nsight's AutomationIds are full Qt object paths, so
    # this is how the right 'Export to CSV' button is picked when two share a name.
    [string]$IdMatch = '',
    # For -Action export: the view to activate before exporting, e.g. 'Instruction Mix'.
    [string]$ViewName = '',
    # For -Action export: where the CSV should land. Defaults next to -Out.
    [string]$OutCsv = '',
    [int]$MaxDepth = 10,
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
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    // Added 2026-10-14: enumerate this process's visible top-level windows, so Get-UiRoot can
    // pick the window that actually holds the populated UI instead of the stale MainWindowHandle.
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    public const uint WM_SETTEXT = 0x000C;
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    // SWP_NOACTIVATE|SWP_NOMOVE|SWP_NOSIZE|SWP_SHOWWINDOW - reorder the z-order without
    // disturbing the window's geometry or the user's focus.
    const uint SWP_FLAGS = 0x0002 | 0x0001 | 0x0004 | 0x0040;
    static readonly IntPtr HWND_TOP = IntPtr.Zero;
    static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    // Windows refuses SetForegroundWindow from a background process (the foreground lock), so a
    // script cannot reliably raise Nsight the normal way. Lifting it to the top of the z-order
    // works anyway: measured 2026-10-13, the click landed on the right control even though
    // GetForegroundWindow still reported another process. Always pair with DropToTop().
    public static void RaiseToTop(IntPtr hWnd) { SetWindowPos(hWnd, HWND_TOP, 0, 0, 0, 0, SWP_FLAGS); }
    public static void DropToTop(IntPtr hWnd) { SetWindowPos(hWnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_FLAGS); }

    // Which process owns the window under a screen point? Guards coordinate clicks: without it a
    // click silently goes to whatever window happens to be on top, which is how an earlier run
    // "clicked the export button" and actually hit an Explorer window.
    public static uint PidAtPoint(int x, int y) {
        POINT p; p.x = x; p.y = y;
        uint pid; GetWindowThreadProcessId(GetAncestor(WindowFromPoint(p), 2 /* GA_ROOT */), out pid);
        return pid;
    }

    // Actually give a window the keyboard focus. SetWindowPos alone only reorders the z-order, and
    // a click on a window that is visible-but-not-foreground is swallowed by activation - Windows
    // sends WM_MOUSEACTIVATE and the button never sees the press. That is exactly why an identical
    // click saved the file once and did nothing the next time (measured 2026-10-13). Attaching to
    // the foreground thread is the documented way around the foreground lock.
    public static bool ForceForeground(IntPtr hWnd) {
        if (GetForegroundWindow() == hWnd) { return true; }
        uint unused;
        uint target = GetWindowThreadProcessId(hWnd, out unused);
        uint mine = GetCurrentThreadId();
        bool attached = false;
        if (target != 0 && target != mine) { attached = AttachThreadInput(mine, target, true); }
        bool ok = SetForegroundWindow(hWnd);
        if (attached) { AttachThreadInput(mine, target, false); }
        return ok || GetForegroundWindow() == hWnd;
    }

    // Set the text of a Win32/DirectUI edit. The modern file dialog is DirectUI, so its filename
    // field answers neither to UIA's ValuePattern nor to a real keystroke stream: SendKeys drops
    // every backslash because the Chinese IME eats the character, turning
    // 'C:\Users\...\out.csv' into 'C:Users...out.csv'. WM_SETTEXT is not routed through the
    // keyboard at all, so it is immune to both.
    public static void SetControlText(IntPtr hWnd, string text) {
        SendMessageW(hWnd, WM_SETTEXT, IntPtr.Zero, text);
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }
    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }

    // Build the INPUT records here, not in PowerShell. PowerShell cannot write a *nested* struct
    // field - "$inp.U.mi.dwFlags = x" mutates a copy and the field still reads back 0 - which had
    // silently turned every click this script sent into a no-op (dwFlags stayed 0, so SendInput
    // got a button-less mouse record). Verified on 2026-10-13: nested write read back 0.
    public static uint SendMouseBatch(uint[] flags) {
        INPUT[] arr = new INPUT[flags.Length];
        for (int i = 0; i < flags.Length; i++) {
            arr[i].type = 0;                        // INPUT_MOUSE
            arr[i].U.mi.dwFlags = flags[i];
        }
        return SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue

# --- UI Automation -------------------------------------------------------------------------
# Nsight's export path is a context-menu entry on an item view (the binary carries
# NV::UI::ContextMenuDecorator::OverrideExportRole / SetExportRole), and there is no export
# keyboard shortcut anywhere in the install. Coordinates would therefore have to be re-derived
# every time the window moves, so everything below locates elements by name instead.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$TS_CHILDREN = [System.Windows.Automation.TreeScope]::Children
$TS_DESC = [System.Windows.Automation.TreeScope]::Descendants

function Get-UiRoot {
    param([System.Diagnostics.Process]$Process)
    # Process.MainWindowHandle is a cached, often-stale value for Qt apps: for a long-lived
    # ngfx-ui it can point at a hidden splash/top-level window while the real, fully-populated
    # UI lives on another visible window of the same process (measured 2026-10-14: handle
    # 0x1e3062 held 168 elements, 0x30d4a held 16497). Enumerate this process's own visible
    # top-level windows and keep the one whose UIA subtree is largest.
    $best = $null
    $bestCount = -1
    foreach ($h in (Get-VisibleTopLevelWindows -ProcessId $Process.Id)) {
        try { $el = [System.Windows.Automation.AutomationElement]::FromHandle($h) }
        catch { continue }
        if ($null -eq $el) { continue }
        $count = 0
        try { $count = $el.FindAll($TS_DESC, [System.Windows.Automation.Condition]::TrueCondition).Count }
        catch { $count = 0 }
        if ($count -gt $bestCount) { $bestCount = $count; $best = $el }
    }
    if ($null -ne $best) { return $best }
    if ($Process.MainWindowHandle -eq [IntPtr]::Zero) { return $null }
    try { return [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle) }
    catch { return $null }
}

function Get-VisibleTopLevelWindows {
    param([int]$ProcessId)
    $list = New-Object System.Collections.ArrayList
$cb = [Win32Focus+EnumWindowsProc] {
    param($h, $l)
    $wpid = [uint32]0
    [Win32Focus]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
    if ($wpid -eq [uint32]$ProcessId -and [Win32Focus]::IsWindowVisible($h)) { [void]$list.Add([IntPtr]$h) }
    return $true
}
[Win32Focus]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
return @($list)
}

function Get-UiProp {
    # Every AutomationElement property read can throw if the element died between discovery and
    # use - which happens constantly in a menu that opens and closes. Always go through here.
    param($Element, [string]$Prop, $Default = '')
    try {
        $v = $Element.Current.$Prop
        if ($null -eq $v) { return $Default }
        return $v
    } catch { return $Default }
}

function Get-UiTypeName {
    param($Element)
    $pn = Get-UiProp $Element 'ControlType' $null
    if ($null -eq $pn) { return '' }
    try { return ($pn.ProgrammaticName -replace '^ControlType\.', '') } catch { return '' }
}

function Get-UiChildren {
    param($Element)
    try {
        $c = $Element.FindAll($TS_CHILDREN, [System.Windows.Automation.Condition]::TrueCondition)
        $out = @()
        foreach ($e in $c) { $out += $e }
        return $out
    } catch { return @() }
}

function Get-UiTreeLines {
    # Breadth-first with a depth cap: the Nsight tree is thousands of nodes deep in the data
    # grids, and the useful controls (menus, toolbars, buttons, tabs) are all near the top.
    param($Root, [int]$MaxDepth = 10)
    $lines = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Root, 0))
    $seen = 0
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $el = $item[0]
        $depth = [int]$item[1]
        $name = Get-UiProp $el 'Name'
        $type = Get-UiTypeName $el
        $auto = Get-UiProp $el 'AutomationId'
        $cls = Get-UiProp $el 'ClassName'
        $off = Get-UiProp $el 'IsOffscreen' $false
        $en = Get-UiProp $el 'IsEnabled' $true
        $flag = ''
        if ($off) { $flag += ' [offscreen]' }
        if (-not $en) { $flag += ' [disabled]' }
        $lines.Add(("{0}{1}  name='{2}'  id='{3}'  class='{4}'{5}" -f
            ('  ' * $depth), $type, $name, $auto, $cls, $flag))
        $seen++
        if ($depth -lt $MaxDepth) {
            foreach ($c in Get-UiChildren $el) { $queue.Enqueue(@($c, $depth + 1)) }
        }
    }
    Write-Host "walked $seen elements"
    return $lines
}

function Find-UiElement {
    # Exact name match wins over substring, so 'Export' prefers a control literally named
    # 'Export' over 'Export All'. Pass an empty -Name to match on ControlType alone, which is
    # how the filename field of a dialog gets located (its name is the current path, not a label).
    #
    # Nsight is a Qt app, so every AutomationId is the full object path - e.g.
    #   QApplication...FlatTabPanel_Shader Source.NV::ShaderProfiler::UI::SourceDetails...QPushButton
    # -IdMatch filters on a substring of that path, which is the only way to tell apart the two
    # buttons both named 'Export to CSV': one is the command bar's log export, the other is the
    # shader profiler's source export.
    param($Root, [string]$Name, [string]$ControlType = '', [int]$MaxDepth = 12, [string]$IdMatch = '',
        [string]$ClassName = '', [string]$IdExact = '')
    if (-not $Name -and -not $ControlType -and -not $IdMatch -and -not $ClassName -and -not $IdExact) { return $null }
    $exact = $null
    $partial = $null
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $el = $item[0]
        $depth = [int]$item[1]
        $n = [string](Get-UiProp $el 'Name')
        $t = Get-UiTypeName $el
        $typeOk = $true
        if ($ControlType) { $typeOk = ($t -eq $ControlType) }
        $idOk = $true
        if ($IdMatch) {
            $aid = [string](Get-UiProp $el 'AutomationId')
            $idOk = $aid.Contains($IdMatch)
        }
        if ($idOk -and $IdExact) { $idOk = ([string](Get-UiProp $el 'AutomationId') -eq $IdExact) }
        if ($idOk -and $ClassName) { $idOk = ([string](Get-UiProp $el 'ClassName') -eq $ClassName) }
        if ($typeOk -and $idOk) {
            if (-not $Name) { return $el }                       # type/id/class-only: first match wins
            if ($n) {
                if ($n -eq $Name) { $exact = $el; break }
                if (-not $partial -and $n.ToLower().Contains($Name.ToLower())) { $partial = $el }
            }
        }
        if ($depth -lt $MaxDepth) {
            foreach ($c in Get-UiChildren $el) { $queue.Enqueue(@($c, $depth + 1)) }
        }
    }
    if ($exact) { return $exact }
    return $partial
}

function Invoke-UiElement {
    # Try every pattern that can "activate" an element, cheapest first. Menu items answer to
    # Invoke; tabs and list rows to SelectionItem; collapsed menus to ExpandCollapse.
    param($Element)
    if (-not $Element) { return $false }
    foreach ($pair in @(
            @([System.Windows.Automation.InvokePattern]::Pattern, 'Invoke'),
            @([System.Windows.Automation.SelectionItemPattern]::Pattern, 'Select'),
            @([System.Windows.Automation.ExpandCollapsePattern]::Pattern, 'Expand'))) {
        try {
            $p = $Element.GetCurrentPattern($pair[0])
            if ($p) {
                if ($pair[1] -eq 'Invoke') { $p.Invoke() }
                elseif ($pair[1] -eq 'Select') { $p.Select() }
                else { $p.Expand() }
                Write-Host ("  invoked via {0}" -f $pair[1])
                return $true
            }
        } catch { }
    }
    Write-Host '  no activatable pattern on that element'
    return $false
}

function Set-UiText {
    param($Element, [string]$Text)
    if (-not $Element) { return $false }
    try {
        $p = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($p) { $p.SetValue($Text); return $true }
    } catch { }
    return $false
}

function Send-MouseFlags {
    # dwFlags constants: 0x0002 LEFT_DOWN, 0x0004 LEFT_UP, 0x0008 RIGHT_DOWN, 0x0010 RIGHT_UP.
    # The records are assembled in C# because PowerShell cannot write a nested struct field - see
    # the comment on Win32Focus.SendMouseBatch.
    param([uint32[]]$Flags)
    return [Win32Focus]::SendMouseBatch($Flags)
}

function Invoke-RightClickAt {
    # Move the cursor, verify it landed, then inject RIGHTDOWN/RIGHTUP. The verification matters:
    # on 2026-10-11 this desktop briefly pinned the cursor and SetCursorPos silently did nothing,
    # which would otherwise mean right-clicking at whatever the pointer happened to be over.
    # -ProcessId additionally checks the window under the point, because a right-click on a window
    # that is only *visible* is spent activating it and no context menu appears.
    param([int]$Px, [int]$Py, [int]$ProcessId = 0)
    $ok = $false
    for ($try = 0; $try -lt 4; $try++) {
        [void][Win32Focus]::SetCursorPos($Px, $Py)
        Start-Sleep -Milliseconds 200
        $at = [System.Windows.Forms.Cursor]::Position
        if ($at.X -eq $Px -and $at.Y -eq $Py) { $ok = $true; break }
        Write-Host ("cursor drifted to {0},{1}; retrying" -f $at.X, $at.Y)
    }
    if (-not $ok) { throw "cursor could not be placed at $Px,$Py - input is being pinned" }
    if ($ProcessId -ne 0) {
        $owner = [Win32Focus]::PidAtPoint($Px, $Py)
        if ($owner -ne $ProcessId) {
            throw "refusing to right-click $Px,$Py - that point belongs to pid $owner, not $ProcessId"
        }
    }
    $n = Send-MouseFlags @(0x0008, 0x0010)
    Start-Sleep -Milliseconds 700
    Write-Host ("right-clicked at {0},{1} (injected {2}/2)" -f $Px, $Py, $n)
}

function Get-UiClickPoint {
    # ClickablePoint is the reliable answer when available; otherwise fall back to the middle of
    # the bounding box, nudged down so we land on a row rather than a header.
    param($Element)
    try {
        $cp = $Element.GetClickablePoint()
        return @([int]$cp.X, [int]$cp.Y)
    } catch {
        try {
            $r = $Element.Current.BoundingRectangle
            return @([int]($r.X + $r.Width / 2), [int]($r.Y + 20))
        } catch { return $null }
    }
}

function Get-UiHandle {
    # The HWND behind an AutomationElement. Needed because a modal dialog must be raised by its
    # own handle - raising the main window does nothing for a dialog that is already on top of it.
    param($Element)
    try {
        $h = [IntPtr]$Element.Current.NativeWindowHandle
        if ($h -eq [IntPtr]::Zero) { return $null }
        return $h
    } catch { return $null }
}

function Raise-UiWindow {
    param($Element)
    $h = Get-UiHandle $Element
    if (-not $h) { return $false }
    [void][Win32Focus]::RaiseToTop($h)
    Start-Sleep -Milliseconds 300
    # Reordering is not enough: without the focus a click only activates the window and the button
    # never sees the press. Force the focus, then re-assert the z-order.
    [void][Win32Focus]::ForceForeground($h)
    Start-Sleep -Milliseconds 400
    [void][Win32Focus]::RaiseToTop($h)
    Start-Sleep -Milliseconds 300
    return $true
}

function Set-UiControlText {
    # WM_SETTEXT straight to the control. See Win32Focus.SetControlText for why neither
    # ValuePattern nor SendKeys can be used on the file dialog's filename field.
    param($Element, [string]$Text)
    $h = Get-UiHandle $Element
    if (-not $h) { return $false }
    try {
        [Win32Focus]::SetControlText($h, $Text)
        Start-Sleep -Milliseconds 400
        return $true
    } catch { return $false }
}

function Drop-UiWindow {
    param($Element)
    $h = Get-UiHandle $Element
    if ($h) { [void][Win32Focus]::DropToTop($h) }
}

function Invoke-UiClickElement {
    # Click an element for real, by geometry. Required for the Win32 common dialog's buttons: they
    # report ClassName 'Button' but expose NO UIA pattern at all - GetCurrentPattern throws
    # 'unsupported pattern' for Invoke and LegacyIAccessible alike (measured 2026-10-13 on the
    # 'Save CSV file' dialog). Invoke-UiElement cannot help there, so fall back to the mouse.
    param($Element, [int]$ProcessId = 0)
    if (-not $Element) { return $false }
    $pt = Get-UiClickPoint $Element
    if (-not $pt) { return $false }
    [void](Raise-UiWindow $Element)
    Invoke-UiClickAt -Px $pt[0] -Py $pt[1] -ProcessId $ProcessId | Out-Null
    return $true
}

function Get-UiTarget {
    # Prefer an instance this script launched; fall back to any ngfx-ui window and say so.
    $ours = @(Get-OurUiProcesses | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    if ($ours.Count -gt 0) { return $ours[0] }
    $any = Get-Process -Name 'ngfx-ui' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
    if ($any) {
        Write-Host "warning: no harvest-owned UI; using foreign instance PID $($any.Id)"
        return $any
    }
    return $null
}

function Select-UiTab {
    # View tabs are Qt CheckBoxes. Invoke() on a CheckBox *toggles* it, so calling it on the tab
    # that is already active would deselect the view - measured 2026.1.0: the tab answered to
    # TogglePattern with ToggleState=On while 'Shader Source' was the active view. Ask the state
    # first and only act when it is off; SelectionItem when offered, Toggle otherwise.
    param($Tab)
    if (-not $Tab) { return $false }
    try {
        $sp = $Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        if ($sp) {
            if ($sp.Current.IsSelected) { Write-Host '  tab already selected'; return $true }
            $sp.Select(); Write-Host '  selected via SelectionItem'; return $true
        }
    } catch { }
    try {
        $tp = $Tab.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($tp) {
            if ($tp.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) {
                Write-Host '  tab already on'
                return $true
            }
            $tp.Toggle(); Write-Host '  toggled on'
            return $true
        }
    } catch { }
    return (Invoke-UiElement $Tab)
}

function Get-UiProcessWindows {
    # Top-level windows belonging to a process. Context menus, popups and dialogs are their own
    # top-level windows, so they are NOT under the main window's tree - but scanning the whole
    # desktop instead (every window of every app, to depth 10) turned one export into a seven
    # minute run. Enumerating the desktop's immediate children and filtering by pid is cheap.
    # Deduped by HWND: UIA reports the same Qt main window several times over (a window plus its
    # backing/shadow windows), which otherwise makes callers pick a "different" window that is
    # really the same one.
    param([int]$ProcessId = 0)
    $out = @()
    $seen = @{}
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($w in $desktop.FindAll($TS_CHILDREN, [System.Windows.Automation.Condition]::TrueCondition)) {
        $owner = 0
        try { $owner = $w.Current.ProcessId } catch { continue }
        if ($ProcessId -ne 0 -and $owner -ne $ProcessId) { continue }
        $h = Get-UiHandle $w
        $key = if ($h) { $h.ToString() } else { [Guid]::NewGuid().ToString() }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $out += $w
    }
    return $out
}

function Find-UiPopupItem {
    # Look for an entry in a popup / context menu. Popups are separate top-level windows, but the
    # main window has to be excluded: it contains a button captioned 'Export to CSV' too (the
    # command bar's *log* export), and matching that instead silently opens 'Export log messages'
    # rather than the shader profiler's export. Better to find nothing than the wrong control.
    param([int]$ProcessId, [IntPtr]$MainWindowHandle, [string]$Name, [int]$MaxDepth = 8)
    foreach ($w in (Get-UiProcessWindows -ProcessId $ProcessId)) {
        $h = Get-UiHandle $w
        if ($h -and $MainWindowHandle -ne [IntPtr]::Zero -and $h -eq $MainWindowHandle) { continue }
        $hit = Find-UiElement -Root $w -Name $Name -MaxDepth $MaxDepth
        if ($hit) {
            $aid = [string](Get-UiProp $hit 'AutomationId')
            if ($aid.Contains('commandBar') -or $aid.Contains('ExportLogsCommand')) {
                Write-Host "  ignoring '$Name' - that is the command bar log export"
                continue
            }
            return $hit
        }
    }
    return $null
}

function Get-UiDialog {
    # Dialogs Nsight opens are native Win32 windows, class '#32770'. UIA exposes them BOTH as a
    # desktop child and as a child of the main window, and which one is populated varies with
    # timing - so walk both, restricted to the target process, and return the last one found.
    # Name-based lookup does not work here: the save dialog is titled 'Save CSV file' by Windows,
    # while the 'CSV Export' string in the binaries is only the Qt-side dialog that Nsight builds
    # on top of it. -ProcessId 0 accepts any owner.
    param($Root, [int]$ProcessId = 0, [int]$MaxDepth = 6)
    $starts = @(Get-UiProcessWindows -ProcessId $ProcessId)
    if ($Root) { $starts += $Root }
    $found = @()
    foreach ($start in $starts) {
        if (-not $start) { continue }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($start, 0))
        $n = 0
        while ($queue.Count -gt 0 -and $n -lt 20000) {
            $item = $queue.Dequeue(); $n++
            $el = $item[0]; $depth = [int]$item[1]
            if ([string](Get-UiProp $el 'ClassName') -eq '#32770') { $found += $el; continue }
            if ($depth -lt $MaxDepth) {
                foreach ($c in Get-UiChildren $el) { $queue.Enqueue(@($c, $depth + 1)) }
            }
        }
    }
    if ($found.Count -eq 0) { return $null }
    return $found[$found.Count - 1]
}

function Wait-UiDialog {
    param($Root, [int]$ProcessId = 0, [int]$Seconds = 20)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $d = Get-UiDialog -Root $Root -ProcessId $ProcessId
        if ($d) { return $d }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Invoke-UiClickAt {
    # Left-click a screen point, but only after confirming the point really belongs to $ProcessId.
    # A coordinate click goes to whatever is on top, so without this check a blocked
    # SetForegroundWindow turns "click the export button" into "click an Explorer window".
    param([int]$Px, [int]$Py, [int]$ProcessId = 0)
    [void][Win32Focus]::SetCursorPos($Px, $Py)
    Start-Sleep -Milliseconds 250
    $at = [System.Windows.Forms.Cursor]::Position
    if ($at.X -ne $Px -or $at.Y -ne $Py) {
        throw "cursor could not be placed at $Px,$Py (it is at $($at.X),$($at.Y)) - input is being pinned"
    }
    if ($ProcessId -ne 0) {
        $owner = [Win32Focus]::PidAtPoint($Px, $Py)
        if ($owner -ne $ProcessId) {
            throw "refusing to click $Px,$Py - that point belongs to pid $owner, not $ProcessId"
        }
    }
    $n = Send-MouseFlags @(0x0002, 0x0004)     # LEFT_DOWN, LEFT_UP
    Start-Sleep -Milliseconds 500
    return $n
}

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
    $Process.Refresh()
    $hwnd = $Process.MainWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { return }

    # Minimized windows sit at (-32000,-32000) and SetForegroundWindow does not restore them. A
    # SendKeys to a window in that state goes to whatever is actually in front, which is how an
    # 'open' run reported success while the trace never loaded (measured 2026-10-21).
    [void][Win32Focus]::ShowWindow($hwnd, 9)      # SW_RESTORE
    Start-Sleep -Milliseconds 300

    # The foreground lock refuses a plain SetForegroundWindow from a background process - the
    # script's own ForceForeground attaches to the foreground thread to get around it. Fall back
    # to raising the window in the z-order when even that is refused.
    [void][Win32Focus]::ForceForeground($hwnd)
    if ([Win32Focus]::GetForegroundWindow() -ne $hwnd) { [Win32Focus]::RaiseToTop($hwnd) }
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
        $n = Send-MouseFlags @(0x0002, 0x0004)
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
        $null = Send-MouseFlags @(0x0002, 0x0004)
        Start-Sleep -Milliseconds 120
        $n = Send-MouseFlags @(0x0002, 0x0004)
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
    'dumpui' {
        # Discovery first: the export path is a context-menu entry, and what the menu is called
        # depends on the view. Dump the tree, look at it, then drive with -Action invoke.
        $target = Get-UiTarget
        if (-not $target) { throw 'no ngfx-ui window; run -Action open first' }
        Focus-Ui $target
        $root = Get-UiRoot $target
        if (-not $root) { throw 'could not attach UI Automation to the ngfx-ui window' }
        $lines = Get-UiTreeLines -Root $root -MaxDepth $MaxDepth
        $outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $WorkDir $Out }
        New-Item -ItemType Directory -Force -Path (Split-Path $outPath -Parent) | Out-Null
        [System.IO.File]::WriteAllLines($outPath, $lines,
            (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "wrote $($lines.Count) elements to $outPath"
    }
    'invoke' {
        # Activate a control by name. Search the app window first, then the desktop, because
        # context menus and dialogs are separate top-level windows owned by the same process.
        $target = Get-UiTarget
        if (-not $target) { throw 'no ngfx-ui window; run -Action open first' }
        Focus-Ui $target
        $root = Get-UiRoot $target
        $el = Find-UiElement -Root $root -Name $Name -ControlType $ControlType `
            -MaxDepth $MaxDepth -IdMatch $IdMatch
        if (-not $el) {
            Write-Host "not in the app window; searching the desktop (popups live there)"
            $el = Find-UiElement -Root ([System.Windows.Automation.AutomationElement]::RootElement) `
                -Name $Name -ControlType $ControlType -MaxDepth $MaxDepth -IdMatch $IdMatch
        }
        if (-not $el) { throw "no element matching '$Name'" }
        Write-Host ("found {0} '{1}'" -f (Get-UiTypeName $el), (Get-UiProp $el 'Name'))
        if (-not (Invoke-UiElement $el)) { throw "found '$Name' but could not activate it" }
        Start-Sleep -Milliseconds 800
    }
    'rclick' {
        # Right-click an element found by name (or raw X,Y). Needed because Nsight hangs Export
        # off the item view's context menu - there is no menu-bar entry and no shortcut.
        if ($Name) {
            $target = Get-UiTarget
            if (-not $target) { throw 'no ngfx-ui window; run -Action open first' }
            Focus-Ui $target
            $root = Get-UiRoot $target
            $el = Find-UiElement -Root $root -Name $Name -ControlType $ControlType -MaxDepth $MaxDepth
            if (-not $el) { throw "no element matching '$Name'" }
            $pt = Get-UiClickPoint $el
            if (-not $pt) { throw "could not compute a click point for '$Name'" }
            Write-Host ("target {0} '{1}' at {2},{3}" -f (Get-UiTypeName $el), (Get-UiProp $el 'Name'), $pt[0], $pt[1])
        } else {
            $pt = @($X, $Y)
        }
        Invoke-RightClickAt -Px $pt[0] -Py $pt[1]
    }
    'export' {
        # The composed flow: activate the view, open its context menu, pick Export, then fill in
        # the CSV Export dialog. Every step reports what it matched, so a failure tells you which
        # control to look for with -Action dumpui rather than leaving you guessing.
        if (-not $ViewName) { throw '-ViewName is required (e.g. "Instruction Mix")' }
        $target = Get-UiTarget
        if (-not $target) { throw 'no ngfx-ui window; run -Action open first' }
        Focus-Ui $target
        $root = Get-UiRoot $target
        if (-not $root) { throw 'could not attach UI Automation to the ngfx-ui window' }

        if (-not $OutCsv) { $OutCsv = [System.IO.Path]::ChangeExtension($Out, '.csv') }
        $csvPath = if ([System.IO.Path]::IsPathRooted($OutCsv)) { $OutCsv } else { Join-Path $WorkDir $OutCsv }
        New-Item -ItemType Directory -Force -Path (Split-Path $csvPath -Parent) | Out-Null

        # 1. Activate the view tab. Measured against 2026.1.0: the tab buttons carry
        #    AutomationId ...FlatTabButton_<View> and are exposed as CheckBox, so Invoke() would
        #    toggle the view off when it is already active. Select-UiTab reads the state first.
        $tab = Find-UiElement -Root $root -Name $ViewName -IdMatch 'FlatTabButton_' -MaxDepth $MaxDepth
        if (-not $tab) { $tab = Find-UiElement -Root $root -Name $ViewName -MaxDepth $MaxDepth }
        if (-not $tab) { throw "view tab '$ViewName' not found - run -Action find -Name '$ViewName'" }
        Write-Host ("tab: {0} '{1}'" -f (Get-UiTypeName $tab), (Get-UiProp $tab 'Name'))
        if (-not (Select-UiTab $tab)) { throw "could not activate the '$ViewName' tab" }
        Start-Sleep -Seconds 2

        # 2. Prefer the view's own export button. 'Shader Source' has one in its SourceDetails
        #    panel. Watch out: the command bar's *log* export shares the caption 'Export to CSV',
        #    so anything whose AutomationId mentions commandBar/ExportLogsCommand is excluded.
        $panel = Find-UiElement -Root $root -IdMatch ("FlatTabPanel_" + $ViewName) -MaxDepth $MaxDepth
        if (-not $panel) { Write-Host "warning: no FlatTabPanel_$ViewName found; falling back to the context menu" }
        $btn = $null
        if ($panel) {
            foreach ($label in @('Export to CSV...', 'Export to CSV', 'Export')) {
                $cand = Find-UiElement -Root $panel -Name $label -ControlType 'Button' -MaxDepth 8
                if ($cand) {
                    $cid = [string](Get-UiProp $cand 'AutomationId')
                    if ($cid.Contains('commandBar') -or $cid.Contains('ExportLogsCommand')) {
                        Write-Host "  skipping '$label' (that is the command bar log export)"
                    } else { $btn = $cand; break }
                }
            }
        }

        if ($btn) {
            Write-Host ("export button: '{0}'" -f (Get-UiProp $btn 'Name'))
            # Invoke() returns success on this QPushButton but dispatches nothing - measured
            # 2026-10-13: 'Invoke() returned OK' and no dialog ever appeared, while a real click
            # opened it immediately. So click for real, and keep Invoke() as the fallback.
            $raised = $false
            $cp = Get-UiClickPoint $btn
            if ($cp) {
                [void][Win32Focus]::RaiseToTop($target.MainWindowHandle); $raised = $true
                Start-Sleep -Milliseconds 700
                try {
                    $n = Invoke-UiClickAt -Px $cp[0] -Py $cp[1] -ProcessId $target.Id
                    Write-Host ("  clicked at {0},{1} (injected {2}/2)" -f $cp[0], $cp[1], $n)
                } catch {
                    Write-Host "  real click failed: $($_.Exception.Message)"
                }
            } else {
                Write-Host '  no click point; invoking directly'
            }
            if (-not (Wait-UiDialog -Root $root -ProcessId $target.Id -Seconds 6)) {
                Write-Host '  no dialog after the click; falling back to Invoke()'
                if (-not (Invoke-UiElement $btn)) { throw 'found the export button but could not activate it' }
            }
            if ($raised) { [void][Win32Focus]::DropToTop($target.MainWindowHandle) }
            Start-Sleep -Seconds 1
        } else {
            # 3. No button: the export role lives on the table's context menu. Find the
            #    shallowest grid/table/list/tree inside the view and right-click it.
            Write-Host 'no export button in this view; using the table context menu'
            $grid = $null
            $queue = New-Object System.Collections.Queue
            $queue.Enqueue(@($(if ($panel) { $panel } else { $root }), 0))
            while ($queue.Count -gt 0 -and -not $grid) {
                $it = $queue.Dequeue()
                if (-not $it[0]) { continue }
                $t = Get-UiTypeName $it[0]
                if ($t -in @('DataGrid', 'Table', 'List', 'Tree')) { $grid = $it[0]; break }
                if ([int]$it[1] -lt 6) {
                    foreach ($c in Get-UiChildren $it[0]) { $queue.Enqueue(@($c, [int]$it[1] + 1)) }
                }
            }
            if (-not $grid) { throw "no export button and no data table under '$ViewName'" }
            Write-Host ("grid: {0} '{1}'" -f (Get-UiTypeName $grid), (Get-UiProp $grid 'Name'))

            $gp = Get-UiClickPoint $grid
            if (-not $gp) { throw "could not compute a click point for the grid under '$ViewName'" }
            [void](Raise-UiWindow $root)
            Invoke-RightClickAt -Px $gp[0] -Py $gp[1] -ProcessId $target.Id

            # 4. Pick Export from the popup. The popup is its own top-level window, so look at the
            #    process's windows and skip the main one - see Find-UiPopupItem for why.
            $item = Find-UiPopupItem -ProcessId $target.Id -MainWindowHandle $target.MainWindowHandle -Name 'Export' -MaxDepth $MaxDepth
            if (-not $item) {
                throw ("no Export entry appeared for the table under '$ViewName'. Measured 2026.1.0: " +
                    "the Instruction Mix panel is three horizontally-scrolled QTreeViews with no export " +
                    "button and no working context menu. Its numbers are already carried by the " +
                    "'Shader Source' export - that CSV has an 'Instruction Mix' column per source line - " +
                    "so use -ViewName 'Shader Source'.")
            }
            Write-Host ("menu: {0} '{1}'" -f (Get-UiTypeName $item), (Get-UiProp $item 'Name'))
            # Qt's context-menu entries expose no usable pattern either (a popup item reports as
            # Button with nothing activatable), so click it for real when Invoke does not take.
            if (-not (Invoke-UiElement $item)) {
                Write-Host '  no pattern on the menu item; clicking it'
                if (-not (Invoke-UiClickElement $item -ProcessId $target.Id)) {
                    throw "found the 'Export' menu item but could not activate it"
                }
            }
            [void][Win32Focus]::DropToTop($target.MainWindowHandle)
            Start-Sleep -Seconds 2
        }

        # 5. The save dialog. This is a native Win32 common dialog (class '#32770'), not a Qt
        #    window - its title is whatever Windows supplies ('Save CSV file'), so match on the
        #    class, not on the 'CSV Export' string that only exists inside the binaries.
        $dlg = Wait-UiDialog -Root $root -ProcessId $target.Id -Seconds 20
        if (-not $dlg) {
            Write-Host 'warning: no save dialog appeared; falling back to typing the path'
            [System.Windows.Forms.SendKeys]::SendWait($csvPath)
            Start-Sleep -Milliseconds 400
            [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            Start-Sleep -Seconds 2
        } else {
            Write-Host ("dialog: '{0}' (class {1})" -f (Get-UiProp $dlg 'Name'), (Get-UiProp $dlg 'ClassName'))

            # The filename field is the Edit with AutomationId 1001 inside FileNameControlHost.
            # Searching for "the first enabled Edit" instead picks up the details-view column
            # editor (class UIProperty, id System.ItemNameDisplay), which silently swallows the
            # value - so try the id first and only then fall back.
            $edit = Find-UiElement -Root $dlg -Name '' -IdMatch 'FileNameControlHost' -MaxDepth 4
            if ($edit) { $edit = Find-UiElement -Root $edit -Name '' -ControlType 'Edit' -MaxDepth 3 }
            if (-not $edit) { $edit = Find-UiElement -Root $dlg -Name '' -IdExact '1001' -ClassName 'Edit' -MaxDepth 6 }
            if (-not $edit) {
                $edit = Find-UiElement -Root $dlg -Name '' -ControlType 'Edit' -MaxDepth 5
                if ($edit) { Write-Host 'warning: matched a filename field by control type only' }
            }
            if (-not $edit) { throw 'no filename field in the save dialog' }
            Write-Host ("filename field: id='{0}' class='{1}'" -f (Get-UiProp $edit 'AutomationId'), (Get-UiProp $edit 'ClassName'))
            # This field refuses ValuePattern, and SendKeys is unusable here: the IME eats every
            # backslash, so the path lands as 'C:Users...out.csv' and the dialog then cannot save.
            # WM_SETTEXT goes straight to the control, bypassing the keyboard entirely.
            if (Set-UiText $edit $csvPath) {
                Write-Host "set filename to $csvPath"
            } elseif (Set-UiControlText $edit $csvPath) {
                Write-Host "set filename to $csvPath (WM_SETTEXT)"
            } else {
                Write-Host 'warning: could not set the filename; leaving the dialog default'
            }
            Start-Sleep -Milliseconds 700

            # The Save button: ClassName 'Button', AutomationId 1, but reported as ControlType
            # Pane and supporting no UIA pattern - so it has to be clicked by geometry. Match on
            # class+id, NOT on the caption: 'Save' as a substring also matches the window title
            # 'Save CSV file', which is how an earlier version ended up "invoking" the dialog.
            $save = Find-UiElement -Root $dlg -Name '' -IdExact '1' -ClassName 'Button' -MaxDepth 6
            if (-not $save) {
                Write-Host 'no Save button matched; pressing Enter'
                [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            } else {
                Write-Host ("save: '{0}' ({1}/{2})" -f (Get-UiProp $save 'Name'), (Get-UiTypeName $save), (Get-UiProp $save 'ClassName'))
                # Give the dialog the focus first, or the click is spent activating the window
                # and the button never sees the press.
                [void](Raise-UiWindow $dlg)
                if (-not (Invoke-UiElement $save)) {
                    Write-Host '  no UIA pattern on Save (expected); clicking it'
                    if (-not (Invoke-UiClickElement $save -ProcessId $target.Id)) {
                        Write-Host 'could not click Save; pressing Enter'
                        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
                    }
                }
            }
            Drop-UiWindow $dlg
            Start-Sleep -Seconds 3
        }

        if (Test-Path -LiteralPath $csvPath) {
            $len = (Get-Item -LiteralPath $csvPath).Length
            Write-Host "exported $csvPath ($len bytes)"
        } else {
            Write-Host "warning: $csvPath was not created - check the dialog with -Action dumpui"
        }
    }
    'find' {
        # Search the whole tree for names matching -Name (substring, case-insensitive) and list
        # what matched, with the coordinates needed to click it. Far more useful than a raw dump:
        # a loaded trace puts 16k+ elements in the first three levels alone.
        $target = Get-UiTarget
        if (-not $target) { throw 'no ngfx-ui window; run -Action open first' }
        if (-not $Name) { throw '-Name is required for -Action find' }
        $root = Get-UiRoot $target
        if (-not $root) { throw 'could not attach UI Automation to the ngfx-ui window' }

        $needle = $Name.ToLower()
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("matches for '$Name' in PID $($target.Id) '$($target.MainWindowTitle)'")
        # Every property read is a cross-process COM call, and a loaded trace has 16k+ elements in
        # the first three levels. Breadth-first plus a hard cap keeps this responsive: the controls
        # worth finding (menus, toolbars, tabs) are shallow, so they are always reached first.
        $maxVisit = 50000
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($root, 0))
        $visited = 0
        $hits = 0
        $truncated = $false
        while ($queue.Count -gt 0) {
            $it = $queue.Dequeue()
            $el = $it[0]
            $depth = [int]$it[1]
            $visited++
            if ($visited -gt $maxVisit) { $truncated = $true; break }
            $n = [string](Get-UiProp $el 'Name')
            $aid = [string](Get-UiProp $el 'AutomationId')
            # Match the visible name or the Qt object path: the path is often the more
            # informative of the two (e.g. 'SelfInstructionMixTable' has name '').
            $nameHit = ($n -and $n.ToLower().Contains($needle))
            $idHit = ($aid -and $aid.ToLower().Contains($needle))
            $idOk = $true
            if ($IdMatch) { $idOk = $aid.Contains($IdMatch) }
            if (($nameHit -or $idHit) -and $idOk) {
                $hits++
                $t = Get-UiTypeName $el
                $cls = Get-UiProp $el 'ClassName'
                $off = Get-UiProp $el 'IsOffscreen' $false
                $pt = Get-UiClickPoint $el
                $where = ''
                if ($pt) { $where = " at $($pt[0]),$($pt[1])" }
                $lines.Add(("  d{0,-2} {1,-12} '{2}'  id='{3}' class='{4}'{5}{6}" -f
                    $depth, $t, $n, $aid, $cls, $where, $(if ($off) { ' [offscreen]' } else { '' })))
            }
            if ($depth -lt $MaxDepth) {
                foreach ($c in Get-UiChildren $el) { $queue.Enqueue(@($c, $depth + 1)) }
            }
        }
        $note = "visited $visited elements, $hits matched (depth cap $MaxDepth)"
        if ($truncated) { $note += " - TRUNCATED at $maxVisit, raise -MaxDepth only if needed" }
        $lines.Insert(1, $note)
        $outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $WorkDir $Out }
        New-Item -ItemType Directory -Force -Path (Split-Path $outPath -Parent) | Out-Null
        [System.IO.File]::WriteAllLines($outPath, $lines,
            (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "visited $visited, matched $hits -> $outPath"
    }
    'selftest' {
        # Verify the UIA half of this script actually works on this machine before trusting it.
        # Some hardened/remote desktops block UI Automation outright, and a silent block would
        # otherwise look like "the Export menu item was not found".
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("UI Automation self-test")
        $lines.Add("  assemblies: UIAutomationClient/UIAutomationTypes loaded")

        $desktop = [System.Windows.Automation.AutomationElement]::RootElement
        if (-not $desktop) {
            $lines.Add("  FAIL: no desktop root - UI Automation is unavailable here")
        } else {
            $kids = @(Get-UiChildren $desktop)
            $lines.Add("  desktop root ok, $($kids.Count) top-level windows")
            $named = @($kids | Where-Object { (Get-UiProp $_ 'Name') })
            $lines.Add("  $($named.Count) of them have a title")
            foreach ($k in ($named | Select-Object -First 8)) {
                $lines.Add("    - {0}" -f (Get-UiProp $k 'Name'))
            }
        }

        $ui = Get-Process -Name 'ngfx-ui' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        if ($ui) {
            $lines.Add("")
            $lines.Add("  ngfx-ui PID $($ui.Id): '$($ui.MainWindowTitle)'")
            $root = Get-UiRoot $ui
            if ($root) {
                $n = 0
                $queue = New-Object System.Collections.Queue
                $queue.Enqueue(@($root, 0))
                while ($queue.Count -gt 0) {
                    $it = $queue.Dequeue()
                    $n++
                    if ([int]$it[1] -lt 3) {
                        foreach ($c in Get-UiChildren $it[0]) { $queue.Enqueue(@($c, [int]$it[1] + 1)) }
                    }
                }
                $lines.Add("  attached; $n elements in the first 3 levels")
                $lines.Add("  (run -Action dumpui for the full tree)")
            } else {
                $lines.Add("  FAIL: could not attach to the ngfx-ui window")
            }
        } else {
            $lines.Add("")
            $lines.Add("  no ngfx-ui window running (that is fine; open one to test the attach path)")
        }

        $outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $WorkDir $Out }
        New-Item -ItemType Directory -Force -Path (Split-Path $outPath -Parent) | Out-Null
        [System.IO.File]::WriteAllLines($outPath, $lines,
            (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "self-test written to $outPath"
    }
    default { throw "unknown action '$Action'" }
}
