# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Lafnaps

<#
    deploy.ps1 — install kbdralt on a machine.

    Installs the driver, writes the rule table and, on request, removes a now-redundant
    Scancode Map entry.

    IMPORTANT: the INF sets the Keyboard class UpperFilters WHOLESALE
    ("kbdralt","kbdclass"), because the filter must sit before kbdclass. That means any
    third-party keyboard filters would be overwritten. This script checks for them and
    refuses to continue without -Force.

    Requires administrator rights. The package must already be built and signed —
    package-and-sign.ps1 for a test-signed lab package, or the package returned from
    Microsoft attestation for production.
#>
[CmdletBinding()]
param(
    [string]$PackageDir = (Join-Path $PSScriptRoot 'x64\Release\package'),

    # The rule set to install. Edit it here so it travels with the script instead of
    # being configured by hand on every machine.
    [string[]]$Rules = @(
        'E0:38 = chord : 38,2A',   # right Alt -> LAlt+LShift chord (switch input language)
        '3A    = remap : 29'       # CapsLock  -> `
    ),

    # Remove the Scancode Map value after installing the driver. Without this switch the
    # script only warns: an old map does not interfere (the driver runs before it), but
    # keeping the same setting in two places is asking for confusion later.
    [switch]$RemoveScancodeMap,

    [switch]$Force,
    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Stop'

$KEYBOARD_CLASS = '{4D36E96B-E325-11CE-BFC1-08002BE10318}'
$classKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$KEYBOARD_CLASS"
$kbdLayoutKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
      ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "administrator rights are required"
}

$inf = Join-Path $PackageDir 'kbdralt.inf'
if (-not (Test-Path $inf)) { throw "$inf not found — build and sign the package first" }

# --- 1. signature ----------------------------------------------------------
$sig = Get-AuthenticodeSignature (Join-Path $PackageDir 'kbdralt.cat')
"catalog signature: $($sig.Status)  ($($sig.SignerCertificate.Subject))"
if ($sig.Status -ne 'Valid' -and -not $Force) {
    throw "the catalog does not pass signature validation. For a lab machine, import the .cer into Root and TrustedPublisher first"
}

# --- 2. FOREIGN FILTERS — the important check ------------------------------
$current = @((Get-ItemProperty $classKey -ErrorAction SilentlyContinue).UpperFilters)
"current UpperFilters: " + $(if ($current) { $current -join ', ' } else { '<empty>' })

$foreign = $current | Where-Object { $_ -and $_ -notin @('kbdclass', 'kbdralt') }
if ($foreign) {
    Write-Warning "FOREIGN FILTERS DETECTED: $($foreign -join ', ')"
    Write-Warning "The INF will overwrite them. Add them to [kbdralt.AddReg] by hand, keeping the order,"
    Write-Warning "or re-run with -Force if you are willing to lose them."
    if (-not $Force) { throw "installation stopped to preserve foreign filters" }
}

$lower = (Get-ItemProperty $classKey -ErrorAction SilentlyContinue).LowerFilters
if ($lower) { Write-Warning "LowerFilters present: $($lower -join ', ') — we do not touch them, but be aware" }

# --- 3. which keyboards are around -----------------------------------------
"keyboard devices (the filter attaches to all of them):"
Get-PnpDevice -Class Keyboard | ForEach-Object { "  [$($_.Status)] $($_.FriendlyName)  $($_.InstanceId)" }

# --- 4. Scancode Map: what is there now ------------------------------------
# THE DRIVER RUNS BEFORE THE SCANCODE MAP. The map is applied by kbdclass, which sits
# ABOVE us, so we see the original scan code and substitute first. There is no conflict
# and no double substitution: after the driver is installed, map entries for the same
# keys simply stop firing, because the code they look for never reaches them.
$existingMap = (Get-ItemProperty $kbdLayoutKey -ErrorAction SilentlyContinue).'Scancode Map'
if ($existingMap) {
    Write-Warning "Scancode Map has entries ($($existingMap.Length) bytes)."
    Write-Warning "They do not interfere with the driver (it runs first), but the setting ends up in two places."
    Write-Warning "Re-run with -RemoveScancodeMap to drop the map after installing."
}

"rules to be applied:"
$Rules | ForEach-Object { "  $_" }

if ($WhatIfOnly) { "--- check only, nothing installed ---"; return }

# --- 5. install ------------------------------------------------------------
"=== pnputil /add-driver /install ==="
pnputil /add-driver $inf /install
if ($LASTEXITCODE -ne 0) { throw "pnputil returned $LASTEXITCODE" }

"new UpperFilters: " + (((Get-ItemProperty $classKey).UpperFilters) -join ', ')

# --- 6. rule table ---------------------------------------------------------
$setRules = Join-Path $PSScriptRoot 'Set-KbdRAltRules.ps1'
if (-not (Test-Path $setRules)) { $setRules = Join-Path $PackageDir 'Set-KbdRAltRules.ps1' }
if (Test-Path $setRules) {
    "=== writing the rule table ==="
    & $setRules -Rule $Rules
} else {
    Write-Warning "Set-KbdRAltRules.ps1 not found — rules were NOT written."
    Write-Warning "The driver will run on its built-in right Alt -> Alt+Shift rule,"
    Write-Warning "and anything else will stay wherever it was configured before."
}

# --- 7. Scancode Map: remove if asked --------------------------------------
if ($RemoveScancodeMap -and $existingMap) {
    $backup = Join-Path $env:ProgramData ("kbdralt-scancodemap-backup-{0}.reg.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    ($existingMap | ForEach-Object { $_.ToString('x2') }) -join ' ' | Set-Content $backup
    "previous Scancode Map value saved to $backup"
    Remove-ItemProperty $kbdLayoutKey -Name 'Scancode Map'
    "Scancode Map removed (takes effect after reboot)"
}

"service: " + (Get-Service kbdralt -ErrorAction SilentlyContinue).Status

@"

Installed. A REBOOT IS REQUIRED: the driver reads the rule table in DriverEntry, and
pnputil /restart-device will not re-read it.

AFTER REBOOT, verify the stack is kbdclass -> kbdralt -> <port driver>:
  Get-PnpDevice -Class Keyboard -Status OK | ForEach-Object {
      (Get-PnpDeviceProperty -InstanceId `$_.InstanceId -KeyName DEVPKEY_Device_Stack).Data -join ' -> ' }

If kbdralt appears BEFORE kbdclass in that output (i.e. above it), the UpperFilters
order is wrong: the driver will load and report Running, but stay completely inert.

ROLLBACK:
  pnputil /delete-driver <oemNN.inf> /uninstall /force
  restore UpperFilters to its original value (usually just kbdclass)
  restore the Scancode Map from the saved file if needed
"@
