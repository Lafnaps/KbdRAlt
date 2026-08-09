# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Lafnaps

<#
    uninstall.ps1 — remove kbdralt and put the keyboard class back the way it was.

    Two things have to be undone, and only one of them is pnputil's job. Removing the
    driver package does not necessarily clear the class-level UpperFilters value the INF
    wrote, and a stale kbdralt entry there is not harmless: the class filter is referenced
    for every keyboard, and a reference to a driver that is no longer installed is exactly
    the state you do not want a keyboard stack in. So this script checks afterwards and
    repairs the value if pnputil left it behind.

    deploy.ps1 saves the previous UpperFilters to ProgramData before changing it. This
    reads the newest such file. If there is none, it falls back to kbdclass alone, which is
    correct for any machine this driver could have been installed on: deploy.ps1 refuses to
    install when a third-party keyboard filter is present, so there was never anything else
    to preserve.

    Requires administrator rights. A reboot is required afterwards.

    IF THE KEYBOARD IS ALREADY DEAD you cannot type this in — read RECOVERY.md instead,
    which starts with how to get a usable session back.
#>
[CmdletBinding()]
param(
    # Also delete the driver's service key and its stored rule table. Off by default: with
    # the filter unhooked the service is inert, and keeping the rules means reinstalling
    # does not lose the configuration.
    [switch]$Purge,

    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Stop'

$KEYBOARD_CLASS = '{4D36E96B-E325-11CE-BFC1-08002BE10318}'
$classKey  = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$KEYBOARD_CLASS"
$serviceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdralt'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
      ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "administrator rights are required"
}

"current UpperFilters: " + (((Get-ItemProperty $classKey -ErrorAction SilentlyContinue).UpperFilters) -join ', ')

# --- 1. find the published name of our package ------------------------------
# pnputil renames third-party INFs to oemNN.inf in the Driver Store; the original name is
# only visible in the enumeration.
$oem = $null
$enum = pnputil /enum-drivers
for ($i = 0; $i -lt $enum.Count; $i++) {
    if ($enum[$i] -match 'Original Name:\s*kbdralt\.inf') {
        for ($j = $i; $j -ge 0; $j--) {
            if ($enum[$j] -match 'Published Name:\s*(oem\d+\.inf)') { $oem = $Matches[1]; break }
        }
        break
    }
}

if ($oem) { "driver package: $oem" }
else      { Write-Warning "no kbdralt.inf found in the driver store — it may already be removed" }

# --- 2. what the UpperFilters value should become ---------------------------
$backup = Get-ChildItem $env:ProgramData -Filter 'kbdralt-upperfilters-backup-*.txt' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($backup) {
    $restore = @(Get-Content $backup.FullName | Where-Object { $_ -ne '' })
    "restore target: $($restore -join ', ')  (from $($backup.Name))"
} else {
    $restore = @('kbdclass')
    "restore target: kbdclass  (no backup file found; this is the correct value anyway)"
}
if ($restore -contains 'kbdralt') {
    Write-Warning "the backup itself lists kbdralt — ignoring it and restoring kbdclass alone"
    $restore = @('kbdclass')
}

if ($WhatIfOnly) { "--- check only, nothing changed ---"; return }

# --- 3. remove the package --------------------------------------------------
if ($oem) {
    "=== pnputil /delete-driver $oem /uninstall /force ==="
    pnputil /delete-driver $oem /uninstall /force
    if ($LASTEXITCODE -ne 0) { Write-Warning "pnputil returned $LASTEXITCODE — continuing to the registry repair" }
}

# --- 4. repair UpperFilters if pnputil left us in it ------------------------
$after = @((Get-ItemProperty $classKey -ErrorAction SilentlyContinue).UpperFilters)
if ($after -contains 'kbdralt') {
    "UpperFilters still lists kbdralt — restoring"
    Set-ItemProperty $classKey -Name UpperFilters -Value $restore -Type MultiString
} elseif (-not $after) {
    Write-Warning "UpperFilters is now empty; setting it to kbdclass so the keyboard class is intact"
    Set-ItemProperty $classKey -Name UpperFilters -Value $restore -Type MultiString
}
"final UpperFilters: " + (((Get-ItemProperty $classKey).UpperFilters) -join ', ')

# --- 5. optional purge ------------------------------------------------------
if ($Purge -and (Test-Path $serviceKey)) {
    Remove-Item $serviceKey -Recurse -Force
    "service key and stored rules removed"
}

@"

Removed. REBOOT to unload the driver — it stays in memory until then, and the keyboard
stack is not rebuilt without it.

If you turned test signing on for this, turn it back off:
  bcdedit /set {current} testsigning off
and re-enable Secure Boot and Memory Integrity if you disabled them.
"@
