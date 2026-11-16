# Shared discovery of the Nsight Graphics tools. Dot-source it from a script in this directory:
#
#     . (Join-Path $PSScriptRoot 'gputrace-common.ps1')
#
# Nsight Graphics installs wherever the user chose, under a version-stamped directory name, so
# neither the drive letter nor the path below it is knowable in advance. Resolution order, first
# hit wins:
#
#   1. an explicit path - the calling script's -NgfxPath, or $env:GPUTRACE_NGFX
#   2. ngfx.exe already on PATH
#   3. the usual install roots, then every fixed drive's root
#
# Step 3 recurses, so it is only reached when the two cheap answers both fail.

function Find-NsightTool {
    param(
        [string]$Name,
        [string]$Explicit
    )

    # 1. An explicit path wins outright - the escape hatch when none of the guesses fit. Accept
    #    either the executable itself or the directory holding it, so both -NgfxPath forms work.
    foreach ($candidate in @($Explicit, $env:GPUTRACE_NGFX)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $joined = Join-Path $candidate $Name
            if (Test-Path -LiteralPath $joined -PathType Leaf) { return (Resolve-Path -LiteralPath $joined).Path }
        } elseif (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    # 2. Whatever is already on PATH.
    $onPath = Get-Command $Name -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    # 3. The roots Nsight Graphics is known to install under, then every fixed drive's root -
    #    an install on E:\ is not unusual, and the original hardcoded drive list missed it.
    $roots = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $roots += (Join-Path $base 'NVIDIA Corporation') }
    }
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -eq [System.IO.DriveType]::Fixed) {
            $roots += (Join-Path $drive.Name 'NVIDIA Corporation')
        }
    }

    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter $Name -ErrorAction SilentlyContinue -Depth 6 |
            Select-Object -First 1 -ExpandProperty FullName
        if ($hit) { return $hit }
    }

    throw "$Name not found. Install Nsight Graphics, or pass -NgfxPath (or set `$env:GPUTRACE_NGFX) to where it lives."
}

function Find-Ngfx {
    param([string]$Explicit)
    return Find-NsightTool -Name 'ngfx.exe' -Explicit $Explicit
}

function Find-NgfxUi {
    param([string]$Explicit)
    return Find-NsightTool -Name 'ngfx-ui.exe' -Explicit $Explicit
}
