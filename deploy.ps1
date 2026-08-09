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
    # Left empty on purpose: the default is resolved below, because it differs between a
    # source tree and an unpacked release archive.
    [string]$PackageDir,

    # The rule set to install.
    #
    # The default is deliberately just the right-Alt rule, which is what the driver falls
    # back to on its own — so a default install changes nothing a user did not ask for.
    # Anything that takes a key AWAY, such as remapping CapsLock, has to be requested:
    #
    #   .\deploy.ps1 -Rules 'E0:38 = chord : 38,2A', '3A = remap : 29'
    [string[]]$Rules = @(
        'E0:38 = chord : 38,2A'    # right Alt -> LAlt+LShift chord (switch input language)
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

# --- 0. find the package ---------------------------------------------------
# Candidates in order: the source-tree build output, the package folder produced by
# package-and-sign.ps1 next to an unpacked release, and finally the script's own folder.
if (-not $PackageDir) {
    $candidates = @(
        (Join-Path $PSScriptRoot 'x64\Release\package')
        (Join-Path $PSScriptRoot 'package')
        $PSScriptRoot
    )
    $PackageDir = $candidates | Where-Object { Test-Path (Join-Path $_ 'kbdralt.inf') } | Select-Object -First 1
    if (-not $PackageDir) {
        throw ("no signed package found. Looked in:`n  " + ($candidates -join "`n  ") +
               "`nRun package-and-sign.ps1 first, or pass -PackageDir.")
    }
    "package: $PackageDir"
}

$inf = Join-Path $PackageDir 'kbdralt.inf'
if (-not (Test-Path $inf)) { throw "$inf not found — build and sign the package first" }

# --- 1. signature ----------------------------------------------------------
# A release archive ships the driver UNSIGNED on purpose, so there is no catalog until
# the user signs it themselves. Saying that outright beats an exception from
# Get-AuthenticodeSignature about a file that was never supposed to be there yet.
$cat = Join-Path $PackageDir 'kbdralt.cat'
if (-not (Test-Path $cat)) {
    throw ("no kbdralt.cat in $PackageDir — the package is unsigned and Windows will refuse to load it.`n" +
           "Sign it first with package-and-sign.ps1 (self-signed, for a test-signing lab machine),`n" +
           "or use a package returned from Microsoft attestation.")
}
$sig = Get-AuthenticodeSignature $cat
"catalog signature: $($sig.Status)  ($($sig.SignerCertificate.Subject))"
if ($sig.Status -ne 'Valid' -and -not $Force) {
    throw ("the catalog does not pass signature validation. On a throwaway test VM, import " +
           "the .cer YOU generated into Root and TrustedPublisher first — never do this on a " +
           "machine you care about, because that certificate then vouches for any code signed " +
           "with its key.")
}

# --- 1a. CAN THIS MACHINE ACTUALLY LOAD IT? --------------------------------
# The catalog validating only means Windows trusts the signer for user-mode purposes.
# Kernel code integrity is a separate gate, and a self-signed driver clears it only in
# test-signing mode with Secure Boot off and HVCI off. Installing without checking is the
# worst outcome available: pnputil succeeds, UpperFilters is rewritten, and the failure
# surfaces on the next boot as a keyboard that does not work.
#
# A Microsoft-signed catalog (attestation or WHQL) needs none of this, so that case skips
# the whole block.
$microsoftSigned = $false
if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate) {
    try {
        $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
        [void]$chain.Build($sig.SignerCertificate)
        $rootSubject = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Subject
        $microsoftSigned = $rootSubject -match 'Microsoft'
    } catch { $microsoftSigned = $false }
}

if ($microsoftSigned) {
    "catalog chains to a Microsoft root — no test-signing configuration needed"
} else {
    $problems = @()

    $testsigning = (bcdedit /enum '{current}') | Select-String -Pattern '^\s*testsigning\s+Yes' -Quiet
    if (-not $testsigning) {
        $problems += "test signing is OFF. Enable it:  bcdedit /set {current} testsigning on   (then reboot)"
    }

    # Confirm-SecureBootUEFI throws rather than returning False on legacy BIOS and Gen-1
    # VMs, where the concept does not exist — that is a pass, not a failure.
    try {
        if (Confirm-SecureBootUEFI) {
            $problems += "Secure Boot is ON. Test signing has no effect until it is disabled in firmware."
        }
    } catch { }

    # SecurityServicesRunning contains 2 when HVCI / Memory Integrity is active. HVCI
    # rejects test-signed drivers even in test-signing mode, and it is on by default on a
    # large part of the Windows 11 install base.
    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
                              -ClassName Win32_DeviceGuard -ErrorAction Stop
        if ($dg.SecurityServicesRunning -contains 2) {
            $problems += "Memory Integrity (HVCI) is ON. Turn it off in Windows Security -> Device security -> Core isolation, then reboot."
        }
    } catch { }

    if ($problems) {
        Write-Warning "This machine cannot load a self-signed kernel driver as configured:"
        $problems | ForEach-Object { Write-Warning "  * $_" }
        Write-Warning "Installing anyway would rewrite the keyboard UpperFilters and leave you"
        Write-Warning "with a driver that never loads. See RECOVERY.md before using -Force."
        if (-not $Force) { throw "installation stopped: the driver could not load on this machine" }
    } else {
        "code integrity: test signing on, Secure Boot off, HVCI off — a self-signed driver can load"
    }
}

# --- 2. FOREIGN FILTERS — the important check ------------------------------
$current = @((Get-ItemProperty $classKey -ErrorAction SilentlyContinue).UpperFilters)
"current UpperFilters: " + $(if ($current) { $current -join ', ' } else { '<empty>' })

# Persist it. This is the one value recovery actually needs, and the INF is about to
# overwrite it wholesale — printing it to a console window that will be closed is not a
# backup. The Scancode Map already gets this treatment further down; UpperFilters is the
# more important of the two.
$filterBackup = Join-Path $env:ProgramData ("kbdralt-upperfilters-backup-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$(if ($current) { $current -join "`n" } else { '' }) | Set-Content -LiteralPath $filterBackup -Encoding ASCII
"previous UpperFilters saved to $filterBackup"

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
    # A real .reg file, not a hex dump: restoring has to be a double-click under stress,
    # not a PowerShell one-liner reconstructed from memory.
    $backup = Join-Path $env:ProgramData ("kbdralt-scancodemap-backup-{0}.reg" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $hex = ($existingMap | ForEach-Object { $_.ToString('x2') }) -join ','
    @"
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Keyboard Layout]
"Scancode Map"=hex:$hex
"@ | Set-Content -LiteralPath $backup -Encoding ASCII
    "previous Scancode Map saved to $backup (double-click to restore, then reboot)"
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
  .\uninstall.ps1
or by hand:
  pnputil /enum-drivers                       # find the oemNN.inf whose Original Name is kbdralt.inf
  pnputil /delete-driver <oemNN.inf> /uninstall /force
  restore UpperFilters from $filterBackup
  restore the Scancode Map from the .reg file above if you removed it

IF THE KEYBOARD IS DEAD AFTER THE REBOOT: read RECOVERY.md. A second keyboard will not
help — this is a class filter and it attaches to every keyboard in the machine.
"@
