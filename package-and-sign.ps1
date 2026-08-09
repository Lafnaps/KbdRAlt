# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Lafnaps

<#
    Builds the driver package and signs it with a self-signed TEST certificate, for use
    on a lab machine with test signing enabled.

    For production, Microsoft attestation signs the driver instead — use
    New-SubmissionPackage.ps1, which signs a CAB rather than these files.

    No elevation required: the certificate lives in Cert:\CurrentUser\My.

    Order matters: embed the signature in the .sys first, then build the catalog (it
    hashes the already-signed file), then sign the catalog. Doing it the other way round
    invalidates the catalog.
#>
param(
    # Release, matching BUILDING.md and deploy.ps1. It used to default to Debug, which
    # meant a bare invocation could quietly package a stale Debug binary that happened to
    # be lying around in the build tree.
    [string]$Configuration = 'Release',
    [string]$Platform      = 'x64',

    # Germanium = Windows 11 24H2/25H2 (26xxx). Vibranium and Nickel are included so a
    # catalog built here is also accepted on Windows 10 and Windows 11 21H2-23H2.
    [string]$OsTarget      = '10_VB_X64,10_NI_X64,10_GE_X64',

    [string]$CertSubject   = 'CN=kbdralt test',

    # Without a countersignature the driver stops loading the day the certificate expires.
    # These signatures are local and short-lived, but the cost of timestamping is nil.
    [string]$TimestampUrl  = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'

$root     = $PSScriptRoot

# Where the built payload lives. In a source tree that is x64\Release; in an unpacked
# release archive the .sys and .inf sit next to this script. Supporting both matters:
# a downloaded release is the only way to get the payload without installing the WDK,
# and it is exactly the case where a hardcoded build path fails.
$outDir = Join-Path $root "$Platform\$Configuration"
if (-not (Test-Path (Join-Path $outDir 'kbdralt.sys'))) {
    if (Test-Path (Join-Path $root 'kbdralt.sys')) {
        $outDir = $root
        "payload found next to the script (unpacked release layout)"
    } else {
        throw "kbdralt.sys not found in $outDir or $root — build the driver first, or run this from an unpacked release archive"
    }
}
$pkgDir   = Join-Path $outDir 'package'
$kit      = 'C:\Program Files (x86)\Windows Kits\10'
$signtool = "$kit\bin\10.0.26100.0\x64\signtool.exe"
$inf2cat  = "$kit\bin\10.0.26100.0\x86\Inf2Cat.exe"
$infverif = "$kit\Tools\10.0.26100.0\x64\infverif.exe"

foreach ($t in $signtool, $inf2cat, $infverif) {
    if (-not (Test-Path $t)) { throw "tool not found: $t" }
}

# --- 1. package ------------------------------------------------------------
if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force }
New-Item -ItemType Directory -Path $pkgDir | Out-Null
Copy-Item "$outDir\kbdralt.sys" $pkgDir
Copy-Item "$outDir\kbdralt.inf" $pkgDir
"package: $pkgDir"

# A published .sys is deliberately unsigned; signing it here is the whole point. But if
# the input already carries a signature, appending a second one silently produces a file
# whose first signature is the one Windows checks — say so rather than pretend.
$inSig = Get-AuthenticodeSignature (Join-Path $pkgDir 'kbdralt.sys')
if ($inSig.Status -ne 'NotSigned') {
    Write-Warning "the input .sys is already signed ($($inSig.Status)). Signing again appends a second signature."
}

# --- 2. INF against signature requirements ---------------------------------
& $infverif /h "$pkgDir\kbdralt.inf"
if ($LASTEXITCODE -ne 0) { throw "infverif /h failed (exit $LASTEXITCODE)" }
"infverif /h: OK"

# --- 3. test certificate ---------------------------------------------------
$cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $CertSubject -and $_.NotAfter -gt (Get-Date) } |
        Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $CertSubject `
                -CertStoreLocation Cert:\CurrentUser\My -KeyUsage DigitalSignature `
                -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(5)
    "test certificate created: $($cert.Thumbprint)"
} else {
    "using existing certificate: $($cert.Thumbprint)"
}

# --- 4. embed the signature in .sys (BEFORE the catalog) -------------------
& $signtool sign /fd SHA256 /tr $TimestampUrl /td SHA256 /sha1 $cert.Thumbprint /s My "$pkgDir\kbdralt.sys"
if ($LASTEXITCODE -ne 0) { throw "signtool on .sys returned $LASTEXITCODE" }

# --- 5. catalog ------------------------------------------------------------
& $inf2cat /driver:$pkgDir /os:$OsTarget /verbose
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat returned $LASTEXITCODE" }

# --- 6. sign the catalog ---------------------------------------------------
& $signtool sign /fd SHA256 /tr $TimestampUrl /td SHA256 /sha1 $cert.Thumbprint /s My "$pkgDir\kbdralt.cat"
if ($LASTEXITCODE -ne 0) { throw "signtool on .cat returned $LASTEXITCODE" }

# --- 7. export the certificate for the lab machine -------------------------
$cerPath = Join-Path $pkgDir 'kbdralt-test.cer'
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

# --- 8. everything the package needs on the target machine -----------------
# The package folder is what gets carried to the test machine, and it is usually the ONLY
# thing that gets carried. deploy.ps1 looks for Set-KbdRAltRules.ps1 next to itself, or the
# install silently falls back to the driver's built-in rule. uninstall.ps1 and RECOVERY.md
# matter more than that: needing them is exactly the situation where you cannot go and
# fetch the rest of the archive.
foreach ($s in 'deploy.ps1', 'uninstall.ps1', 'Set-KbdRAltRules.ps1', 'RECOVERY.md', 'INSTALL.md') {
    $src = Join-Path $root $s
    if (Test-Path $src) { Copy-Item $src $pkgDir }
    else { Write-Warning "$s not found next to this script — the package will be missing it" }
}

"=== done ==="
$signedSys = Join-Path $pkgDir 'kbdralt.sys'
"packaged driver : {0}" -f ((Get-Item $signedSys).VersionInfo.FileVersion)
"SHA256          : {0}" -f (Get-FileHash $signedSys -Algorithm SHA256).Hash.ToLower()
"DriverVer       : {0}" -f (Select-String -Path (Join-Path $pkgDir 'kbdralt.inf') -Pattern '^\s*DriverVer\s*=').Line.Trim()
Get-ChildItem $pkgDir | Select-Object Name, Length | Format-Table -AutoSize

# Informational. Verification here WILL fail ("0 files verified"): the certificate is
# self-signed and is not in this machine's trusted roots — nor should it be.
#
# Trust is established only on a THROWAWAY TEST VM, by importing this .cer into Root and
# TrustedPublisher. Understand what that does: a certificate in the machine Root store is
# not scoped to kernel drivers or to this project. Anything signed with its private key
# shows up as a trusted publisher on that machine, for the certificate's whole lifetime,
# with no revocation. Do it on a VM you are willing to throw away, and nowhere else.
#
# signtool exits non-zero here and writes to stderr, which under $ErrorActionPreference =
# 'Stop' turns a SUCCESSFUL run into a red error and a non-zero exit code as the very last
# thing the user sees. Contain it: the failure is expected and informational.
"--- catalog signature (trust is not expected to validate here) ---"
try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $verify = & $signtool verify /pa /v "$pkgDir\kbdralt.cat" 2>&1
} finally { $ErrorActionPreference = $prev }
($verify | Select-String 'Issued to|SHA1 hash|Number of files' | Out-String).Trim()
"(a chain error above is normal — the certificate is trusted only where you import it)"

@"

NEXT STEPS
  1. Copy the package folder to the test machine:
       $pkgDir
  2. On THAT machine only, import kbdralt-test.cer into Root and TrustedPublisher.
     It is a machine-wide trust anchor for anything signed with its key — use a VM you
     are willing to throw away.
  3. Check, without installing:
       powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -WhatIfOnly
  4. Install, then reboot.

Signing and installing do not have to happen on the same machine: this step needs the
Windows SDK/WDK, the install does not.
"@
exit 0
