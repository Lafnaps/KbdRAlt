# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Lafnaps

<#
    New-SubmissionPackage.ps1 — build the CAB for attestation submission to Partner Center.

    HOW THIS DIFFERS FROM package-and-sign.ps1:
      package-and-sign.ps1 builds a package FOR A LAB MACHINE: it embeds a test
      certificate signature into the .sys and builds and signs a catalog. That is for
      test signing.

      A submission must contain a CLEAN, UNSIGNED .sys. Microsoft produces and signs the
      catalog. The only thing we sign is the CAB container, and only with an EV
      certificate.

    The script deliberately does NOT sign the CAB by default: signing needs the token,
    which may not be plugged in. Pass -Thumbprint to sign immediately, or copy the
    command from the output.

    No elevation required.
#>
[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [string]$Platform      = 'x64',

    # EV certificate thumbprint. Without it the CAB is built but left unsigned.
    [string]$Thumbprint,

    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'

$root     = $PSScriptRoot
$buildDir = Join-Path $root "$Platform\$Configuration"
$subRoot  = Join-Path $buildDir 'submission'
$pkgDir   = Join-Path $subRoot 'kbdralt'
$kit      = 'C:\Program Files (x86)\Windows Kits\10'
$infverif = "$kit\Tools\10.0.26100.0\x64\infverif.exe"
$signtool = "$kit\bin\10.0.26100.0\x64\signtool.exe"

foreach ($t in $infverif, $signtool) {
    if (-not (Test-Path $t)) { throw "tool not found: $t" }
}

$srcSys = Join-Path $buildDir 'kbdralt.sys'
$srcInf = Join-Path $buildDir 'kbdralt.inf'
foreach ($f in $srcSys, $srcInf) {
    if (-not (Test-Path $f)) { throw "$f not found — build the $Configuration configuration first" }
}

# --- 1. clean package folder -----------------------------------------------
if (Test-Path $subRoot) { Remove-Item -LiteralPath $subRoot -Recurse -Force }
New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
Copy-Item $srcSys $pkgDir
Copy-Item $srcInf $pkgDir

# --- 2. THE KEY CHECK: the .sys must be UNSIGNED ---------------------------
# If a file from package-and-sign.ps1 ends up here it will carry a test signature.
# Such a submission gets rejected at best.
$sysSig = Get-AuthenticodeSignature (Join-Path $pkgDir 'kbdralt.sys')
if ($sysSig.Status -ne 'NotSigned') {
    throw ".sys is already signed ($($sysSig.Status), $($sysSig.SignerCertificate.Subject)). " +
          "A submission needs a clean file. Rebuild the project: " +
          "msbuild kbdralt.vcxproj /p:Configuration=$Configuration /p:Platform=$Platform /t:Rebuild"
}
"check: .sys is unsigned — OK"

# The catalog is not submitted: Microsoft creates it.
if (Test-Path (Join-Path $pkgDir 'kbdralt.cat')) {
    Remove-Item (Join-Path $pkgDir 'kbdralt.cat') -Force
    "test .cat removed from the package"
}

# --- 3. INF against signature requirements ---------------------------------
& $infverif /h (Join-Path $pkgDir 'kbdralt.inf')
if ($LASTEXITCODE -ne 0) { throw "infverif /h failed (exit $LASTEXITCODE)" }
"infverif /h: OK"

$driverVer = (Select-String -Path (Join-Path $pkgDir 'kbdralt.inf') -Pattern '^\s*DriverVer\s*=' ).Line.Trim()
"in the package: $driverVer"
if ($driverVer -notmatch '\d{2}/\d{2}/\d{4}') {
    throw "DriverVer is not stamped — build through msbuild rather than by hand"
}

# --- 4. CAB ----------------------------------------------------------------
$ddf = Join-Path $subRoot 'package.ddf'
@"
.OPTION EXPLICIT
.Set CabinetNameTemplate=kbdralt.cab
.Set DiskDirectory1=$subRoot\disk1
.Set CompressionType=MSZIP
.Set Cabinet=on
.Set Compress=on
.Set MaxDiskSize=0
.Set DestinationDir=kbdralt
"$pkgDir\kbdralt.inf"
"$pkgDir\kbdralt.sys"
"@ | Set-Content -Path $ddf -Encoding ASCII

Push-Location $subRoot
try {
    makecab /f $ddf | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "makecab returned $LASTEXITCODE" }
} finally { Pop-Location }

$cab = Join-Path $subRoot 'disk1\kbdralt.cab'
if (-not (Test-Path $cab)) { throw "the CAB was not produced" }
"CAB: $cab ($([math]::Round((Get-Item $cab).Length/1KB,1)) KB)"

# --- 5. sign the CAB -------------------------------------------------------
if ($Thumbprint) {
    & $signtool sign /fd SHA256 /tr $TimestampUrl /td SHA256 /sha1 $Thumbprint $cab
    if ($LASTEXITCODE -ne 0) { throw "signtool returned $LASTEXITCODE" }
    & $signtool verify /pa /v $cab | Select-String 'Issued to|Number of files'
    "CAB signed."
} else {
    @"

The CAB was built but NOT signed — no -Thumbprint was given.
Plug in the EV token and run:

  & "$signtool" sign /fd SHA256 /tr $TimestampUrl /td SHA256 /sha1 <thumbprint> "$cab"

Find the thumbprint in certmgr.msc, or with
  Get-ChildItem Cert:\CurrentUser\My | Format-List Subject,Thumbprint
The timestamp (/tr) is mandatory: without it the signature dies with the certificate.
"@
}

@"

Package contents:
"@
Get-ChildItem $pkgDir | Select-Object Name, Length | Format-Table -AutoSize

@"
Next steps:
  * tag the commit that goes into the signature, so it stays identifiable later;
  * Partner Center -> Submit new hardware -> upload the CAB;
  * target OS: Windows 11 x64; do NOT enable publishing to Windows Update;
  * test the signed package with Secure Boot and HVCI ENABLED before installing it
    anywhere real — a lab machine running with test signing is a weaker configuration.
"@
