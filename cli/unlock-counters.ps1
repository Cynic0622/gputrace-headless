# One-time: allow GPU performance counters for non-elevated processes (GeForce).
# Sets HKLM\...\NVTweak\RmProfilingAdminOnly = 0. Needs a single admin approval; after this,
# ngfx/ncu runs no longer need UAC.
# If the key already exists with value 0, exits without prompting.
$value = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak' `
    -Name RmProfilingAdminOnly -ErrorAction SilentlyContinue
if ($null -ne $value -and $value.RmProfilingAdminOnly -eq 0) {
    Write-Host 'RmProfilingAdminOnly is already 0 - no elevation needed.'
    exit 0
}

Write-Host 'Requesting one-time admin approval to set RmProfilingAdminOnly = 0...'
$proc = Start-Process -FilePath 'reg.exe' `
    -ArgumentList 'add', 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak', `
        '/v', 'RmProfilingAdminOnly', '/t', 'REG_DWORD', '/d', '0', '/f' `
    -Verb RunAs -Wait -PassThru
Start-Sleep -Milliseconds 500
$check = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak' `
    -Name RmProfilingAdminOnly -ErrorAction SilentlyContinue
if ($null -ne $check -and $check.RmProfilingAdminOnly -eq 0) {
    Write-Host 'OK: RmProfilingAdminOnly = 0. GPU performance counters no longer need elevation.'
    exit 0
}
Write-Host "FAILED: registry value not set (reg exit $($proc.ExitCode))."
exit 1
