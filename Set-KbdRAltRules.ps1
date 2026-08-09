# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Lafnaps

<#
    Set-KbdRAltRules.ps1 — write the kbdralt rule table to the registry.

    The driver reads a binary blob (parsing text in kernel mode is a source of bugs);
    this script accepts a readable form and produces that blob.

    A rule is written as:
        "<input> = <mode> : <output>[,<output>...]"

    A key is a set-1 scan code in hex, optionally prefixed with E0: for extended keys,
    e.g. 38, E0:38, 3A, 29.

    Modes:
        chord — the press and every auto-repeat are swallowed; on release the whole
                sequence is emitted at once (makes in order, breaks in reverse)
        remap — plain key-for-key substitution, exactly one output

    Examples:
        'E0:38 = chord : 38,2A'   right Alt -> LAlt+LShift chord
        '3A    = remap : 29'      CapsLock  -> `

    IMPORTANT: the driver reads the table ONCE, in DriverEntry. So
    `pnputil /restart-device` will NOT pick up changes — it restarts the device while
    the driver stays loaded with the old table. A REBOOT is required (or unloading the
    driver, which only happens when every keyboard is stopped).

    Requires administrator rights to write.
#>
[CmdletBinding()]
param(
    # A plain string array. ValueFromRemainingArguments is deliberately NOT used:
    # invoked through powershell.exe -File it loses every argument but the first.
    [Parameter(Mandatory)]
    [string[]]$Rule,

    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Stop'

$VERSION            = 1
$MAX_RULES          = 64
$MAX_OUT_PER_RULE   = 8
$MODE = @{ 'chord' = 0; 'remap' = 1 }

if ($Rule.Count -gt $MAX_RULES) { throw "more than $MAX_RULES rules" }

function ConvertTo-Key([string]$text) {
    $t = $text.Trim()
    $ext = 0
    if ($t -match '^(?i)E0\s*:\s*(.+)$') { $ext = 1; $t = $matches[1].Trim() }
    $scan = [Convert]::ToUInt16($t, 16)
    if ($scan -eq 0 -or $scan -gt 0xFF) { throw "scan code out of range 01..FF: '$text'" }
    [pscustomobject]@{ Scan = $scan; Ext = $ext }
}

# @(...) is load-bearing, not decoration. A foreach that yields exactly ONE object returns
# that object, not a one-element array, and in Windows PowerShell 5.1 a PSCustomObject has
# no .Count — it evaluates to $null. The blob below would then declare Count = 0, which the
# driver rejects, so it would discard the whole table and fall back to its built-in rule
# while the script reported success. The size assertion further down catches it, but only
# because this wrapper is the actual fix.
$parsed = @(foreach ($line in $Rule) {
    if ($line -notmatch '^\s*(?<in>[^=]+?)\s*=\s*(?<mode>\w+)\s*:\s*(?<out>.+?)\s*$') {
        throw "cannot parse rule: '$line'"
    }
    $modeName = $matches['mode'].ToLower()
    if (-not $MODE.ContainsKey($modeName)) { throw "unknown mode '$modeName' in '$line'" }

    $inKey  = ConvertTo-Key $matches['in']
    $outKeys = @($matches['out'] -split ',' | ForEach-Object { ConvertTo-Key $_ })

    if ($outKeys.Count -eq 0 -or $outKeys.Count -gt $MAX_OUT_PER_RULE) {
        throw "expected 1..$MAX_OUT_PER_RULE outputs in '$line'"
    }
    if ($modeName -eq 'remap' -and $outKeys.Count -ne 1) {
        throw "remap mode requires exactly one output in '$line'"
    }
    [pscustomobject]@{ In = $inKey; Mode = $MODE[$modeName]; Out = $outKeys; Text = $line.Trim() }
})
if ($parsed.Count -eq 0) { throw "no rules given" }

# Two rules for the same input key is almost certainly a typo. The driver rejects such a
# table wholesale and silently falls back to the built-in rule, so catch it here where we
# can say clearly what is wrong.
$dup = $parsed | Group-Object { "{0}:{1:X2}" -f $_.In.Ext, $_.In.Scan } | Where-Object Count -gt 1
if ($dup) {
    throw ("two rules for the same key: " + (($dup.Group | ForEach-Object { "'$($_.Text)'" }) -join ' and '))
}

"=== rules ==="
foreach ($p in $parsed) {
    $inStr  = ($(if ($p.In.Ext) { 'E0:' } else { '' })) + ('{0:X2}' -f $p.In.Scan)
    $outStr = ($p.Out | ForEach-Object { ($(if ($_.Ext) { 'E0:' } else { '' })) + ('{0:X2}' -f $_.Scan) }) -join ','
    $modeStr = ($MODE.GetEnumerator() | Where-Object Value -eq $p.Mode).Key
    "  {0,-8} {1,-6} -> {2}" -f $inStr, $modeStr, $outStr
}

# --- build the blob --------------------------------------------------------
# The layout mirrors kbdralt.h (pshpack1):
#   KBDRALT_RULES : ULONG Version, ULONG Count, KBDRALT_RULE Rule[]
#   KBDRALT_RULE  : USHORT InScan, USHORT InExtended, ULONG Mode,
#                   ULONG OutCount, ULONG Reserved, KBDRALT_KEY Out[8]
#   KBDRALT_KEY   : USHORT Scan, USHORT Extended
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([uint32]$VERSION)
$bw.Write([uint32]$parsed.Count)
foreach ($p in $parsed) {
    $bw.Write([uint16]$p.In.Scan)
    $bw.Write([uint16]$p.In.Ext)
    $bw.Write([uint32]$p.Mode)
    $bw.Write([uint32]$p.Out.Count)
    $bw.Write([uint32]0)                     # Reserved
    for ($i = 0; $i -lt $MAX_OUT_PER_RULE; $i++) {
        if ($i -lt $p.Out.Count) {
            $bw.Write([uint16]$p.Out[$i].Scan)
            $bw.Write([uint16]$p.Out[$i].Ext)
        } else {
            $bw.Write([uint16]0); $bw.Write([uint16]0)
        }
    }
}
$bw.Flush()
$blob = $ms.ToArray()
$bw.Dispose(); $ms.Dispose()

$expected = 8 + $parsed.Count * (2+2+4+4+4 + $MAX_OUT_PER_RULE*4)
if ($blob.Length -ne $expected) { throw "internal error: blob is $($blob.Length) bytes, expected $expected" }
"blob: $($blob.Length) bytes"

if ($WhatIfOnly) { "--- check only, nothing written to the registry ---"; return }

# Rights are needed only for writing — parsing and dry runs work without them.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
      ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "administrator rights are required to write to the registry"
}

$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdralt\Parameters'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
Set-ItemProperty -Path $key -Name 'Rules' -Value $blob -Type Binary

"written to $key\Rules"
@"

The driver reads the table in DriverEntry, so a REBOOT is required.
pnputil /restart-device is not enough: the device restarts but the driver stays
loaded with the old table.

To reset to the built-in rule (right Alt -> Alt+Shift):
  Remove-ItemProperty -Path '$key' -Name Rules
"@
