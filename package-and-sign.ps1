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
    [string]$Configuration = 'Debug',
    [string]$Platform      = 'x64',
    [string]$OsTarget      = '10_GE_X64',           # Germanium = Windows 11 24H2/25H2 (26xxx builds)
    [string]$CertSubject   = 'CN=kbdralt test'
)
$ErrorActionPreference = 'Stop'

$root     = $PSScriptRoot
$outDir   = Join-Path $root "$Platform\$Configuration"
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
& $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /s My "$pkgDir\kbdralt.sys"
if ($LASTEXITCODE -ne 0) { throw "signtool on .sys returned $LASTEXITCODE" }

# --- 5. catalog ------------------------------------------------------------
& $inf2cat /driver:$pkgDir /os:$OsTarget /verbose
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat returned $LASTEXITCODE" }

# --- 6. sign the catalog ---------------------------------------------------
& $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /s My "$pkgDir\kbdralt.cat"
if ($LASTEXITCODE -ne 0) { throw "signtool on .cat returned $LASTEXITCODE" }

# --- 7. export the certificate for the lab machine -------------------------
$cerPath = Join-Path $pkgDir 'kbdralt-test.cer'
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

"=== done ==="
Get-ChildItem $pkgDir | Select-Object Name, Length | Format-Table -AutoSize

# Informational. Verification here WILL fail ("0 files verified"): the certificate is
# self-signed and is not in this machine's trusted roots — nor should it be. Trust is
# established only on the lab machine, by importing the .cer into Root and
# TrustedPublisher.
"--- catalog signature (trust is not expected to validate here) ---"
& $signtool verify /pa /v "$pkgDir\kbdralt.cat" 2>&1 |
    Select-String 'Issued to|SHA1 hash|Number of files' | Out-String
exit 0
