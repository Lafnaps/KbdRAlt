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

    WHAT GOES IN THE CAB, and why the answer is not obvious. Microsoft's article contradicts
    itself: its component list calls the .pdb and the .cat required, while the worked example
    in the same article builds a CAB from exactly two files and says so. This script sends
    the INF, the .sys and the .pdb — the symbol file because the stated reason for it is real
    ("required for Microsoft automated crash analysis tools") and it costs nothing — and
    leaves the catalog out unless -IncludeCatalog is given, because the only purpose the
    documentation gives a submitted catalog is company verification, which an unsigned or
    test-signed one cannot serve.

    INFVERIF. /h is the gate, and it is the one InfVerif's own help describes as tracking the
    WHQL signing requirements "current as of this InfVerif version", adding that they "may
    change build-to-build". So the version is recorded in the output, and /h is also run
    against the next ruleset via /rulever vnext as an advisory. /w is run and REPORTED, never
    enforced: a class filter writes UpperFilters under the class key, outside HKR, so driver
    package isolation fails with ERROR(1321) by construction and always will until the INF
    moves to the declarative AddFilter directive.

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

    [string]$TimestampUrl = 'http://timestamp.digicert.com',

    # Include a catalog in the CAB. Microsoft's documentation contradicts itself here: the
    # component list says "Catalog (.cat) files are required and used for company
    # verification only", while the worked example in the same article builds a CAB from
    # exactly two files, the INF and the .sys, and states "there should be two files".
    #
    # The default follows the worked example, because a catalog is only useful for company
    # verification if it is signed with the EV certificate, and this script is designed to
    # run without the token present. Pass -IncludeCatalog when you have the token and want
    # to follow the component list literally; an unsigned or test-signed catalog is never
    # included, because either would defeat the only purpose the documentation gives it.
    [switch]$IncludeCatalog,

    # Skip the preview run against the next InfVerif ruleset. The preview is advisory: it
    # reports what would fail under rules that are not enforced yet.
    [switch]$SkipVNextPreview
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

# The dashboard rejects UNC paths outright — "You must use a mapped drive letter for the CAB
# to be valid" — and limits driver folder names to fewer than 40 characters with no special
# characters. Cheap to check here; expensive to discover after a submission round trip.
if ($root -like '\\*') {
    throw "this script is running from a UNC path ($root). Map a drive letter: the CAB will not be valid otherwise."
}

$srcSys = Join-Path $buildDir 'kbdralt.sys'
$srcInf = Join-Path $buildDir 'kbdralt.inf'
$srcPdb = Join-Path $buildDir 'kbdralt.pdb'
foreach ($f in $srcSys, $srcInf) {
    if (-not (Test-Path $f)) { throw "$f not found — build the $Configuration configuration first" }
}

# --- 1. clean package folder -----------------------------------------------
if (Test-Path $subRoot) { Remove-Item -LiteralPath $subRoot -Recurse -Force }
New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
Copy-Item $srcSys $pkgDir
Copy-Item $srcInf $pkgDir

# The symbol file. Microsoft lists it among the required components: "The .pdb file is
# required for Microsoft automated crash analysis tools." Without it a bugcheck traced back
# to this driver is an address with no name attached to it. It costs half a megabyte in the
# submission and it is not redistributed, so the source paths it carries are not a leak in
# the way they would be in a published binary.
if (Test-Path $srcPdb) {
    Copy-Item $srcPdb $pkgDir
    "symbols included: kbdralt.pdb ({0:N0} bytes)" -f (Get-Item $srcPdb).Length
} else {
    Write-Warning "kbdralt.pdb not found next to the binary. Microsoft's automated crash analysis needs it; submitting without symbols is allowed but makes any future bugcheck report far less useful."
}

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

# --- 2a. the catalog ---------------------------------------------------------
# Whatever ends up here, Microsoft regenerates the catalog and replaces it. What the
# submitted one is for, per the documentation, is company verification — which only works
# if it carries the EV signature. A test-signed catalog identifies nobody and a leftover
# one from package-and-sign.ps1 identifies the wrong thing, so both are removed.
$catInBuild = Join-Path $buildDir 'kbdralt.cat'
$catInPkg   = Join-Path $pkgDir 'kbdralt.cat'
if ($IncludeCatalog) {
    if (-not (Test-Path $catInBuild)) {
        throw "-IncludeCatalog was given but $catInBuild does not exist. Build the catalog with Inf2Cat and sign it with the EV certificate first."
    }
    $catSig = Get-AuthenticodeSignature $catInBuild
    if ($catSig.Status -ne 'Valid') {
        throw ("-IncludeCatalog requires a catalog signed with the EV certificate; this one is " +
               "'$($catSig.Status)'. A catalog is submitted for company verification only, so an " +
               "unsigned or untrusted one is worse than none.")
    }
    Copy-Item $catInBuild $pkgDir
    "catalog included, signed by: $($catSig.SignerCertificate.Subject)"
} elseif (Test-Path $catInPkg) {
    Remove-Item $catInPkg -Force
    "catalog removed from the package (Microsoft regenerates it; pass -IncludeCatalog to submit an EV-signed one)"
}

# --- 3. INF against signature requirements ---------------------------------
# /h is the gate that matters: InfVerif's own help says this mode "uses requirements that
# always align with the requirements to get a WHQL signature, current as of this InfVerif
# version" — and, importantly, "These requirements may change build-to-build". So record
# which version passed it; a rejection months from now is much easier to understand when
# you know what validated the package.
$ivVersion = (Get-Item $infverif).VersionInfo.ProductVersion
"infverif version: $ivVersion"

& $infverif /h (Join-Path $pkgDir 'kbdralt.inf')
if ($LASTEXITCODE -ne 0) { throw "infverif /h failed (exit $LASTEXITCODE)" }
"infverif /h: OK"

# Advisory. /rulever vnext previews rules that are proposed but not enforced yet, which is
# the cheapest possible warning that the next toolkit will reject a package this one accepts.
if (-not $SkipVNextPreview) {
    $vnext = & $infverif /h /rulever vnext (Join-Path $pkgDir 'kbdralt.inf') 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "infverif /h /rulever vnext FAILED — this package passes today's rules but would fail the next ruleset:"
        $vnext | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Warning "  $_" }
    } else {
        "infverif /h /rulever vnext: OK (also passes the next ruleset)"
    }
}

# Driver package isolation, reported and not enforced. A class filter has to write
# UpperFilters under the class key, which is outside HKR, so /w fails with ERROR(1321) by
# construction. That is expected and does not block a WHQL signature — but if it ever starts
# passing, something changed worth knowing about, most likely a move to the declarative
# AddFilter directive.
& $infverif /w (Join-Path $pkgDir 'kbdralt.inf') > $null 2>&1
if ($LASTEXITCODE -eq 0) {
    "infverif /w: PASSES — driver package isolation is now satisfied. Unexpected; check whether the INF changed."
} else {
    "infverif /w: fails as expected (ERROR 1321, UpperFilters is not isolated to HKR) — not a submission blocker"
}

$driverVer = (Select-String -Path (Join-Path $pkgDir 'kbdralt.inf') -Pattern '^\s*DriverVer\s*=' ).Line.Trim()
"in the package: $driverVer"
if ($driverVer -notmatch '\d{2}/\d{2}/\d{4}') {
    throw "DriverVer is not stamped — build through msbuild rather than by hand"
}

# --- 3a. nothing unreferenced may travel in the CAB -------------------------
# Files that the INF does not reference come back from the dashboard unsigned. With a package
# this small that would be silent and easy to miss.
#
# Note what this can and cannot catch. The staging folder is wiped and rebuilt above, so
# stray files left on disk never survive to be seen here. What it guards is the staging list
# itself: add a copy of some helper binary to this script later, forget that the INF has to
# reference it, and the check fires instead of the dashboard quietly returning it unsigned.
$infText   = Get-Content (Join-Path $pkgDir 'kbdralt.inf') -Raw
$allowed   = @('kbdralt.inf', 'kbdralt.pdb', 'kbdralt.cat')   # the INF, symbols, catalog
$unexpected = Get-ChildItem $pkgDir -File | Where-Object {
    $_.Name -notin $allowed -and $infText -notmatch [regex]::Escape($_.Name)
}
if ($unexpected) {
    throw ("these files are in the package but not referenced by the INF, and would be returned " +
           "unsigned: " + (($unexpected.Name) -join ', '))
}
"package contents are all referenced by the INF, or are symbols/catalog"

# --- 4. CAB ----------------------------------------------------------------
$ddf = Join-Path $subRoot 'package.ddf'

# The five threshold settings are not decoration. Left at their defaults, makecab is free to
# split the payload across several folders or cabinets, and a split submission is not a valid
# one. Microsoft's own example sets all of them to zero, meaning "no limit, do not split";
# this package is small enough that it would not split today, which is exactly what would
# make the omission a nasty surprise once the package grows.
$ddfFiles = Get-ChildItem $pkgDir -File | Sort-Object Name |
            ForEach-Object { '"{0}"' -f $_.FullName }

@"
.OPTION EXPLICIT
.Set CabinetFileCountThreshold=0
.Set FolderFileCountThreshold=0
.Set FolderSizeThreshold=0
.Set MaxCabinetSize=0
.Set MaxDiskFileCount=0
.Set MaxDiskSize=0
.Set CompressionType=MSZIP
.Set Cabinet=on
.Set Compress=on
.Set CabinetNameTemplate=kbdralt.cab
; No files at the CAB root: each driver package goes in its own subfolder.
.Set DestinationDir=kbdralt
.Set DiskDirectory1=$subRoot\disk1
$($ddfFiles -join "`r`n")
"@ | Set-Content -Path $ddf -Encoding ASCII

"CAB will contain $($ddfFiles.Count) file(s):"
Get-ChildItem $pkgDir -File | ForEach-Object { "   {0,-16} {1,10:N0} bytes" -f $_.Name, $_.Length }

Push-Location $subRoot
try {
    makecab /f $ddf | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "makecab returned $LASTEXITCODE" }
} finally { Pop-Location }

$cab = Join-Path $subRoot 'disk1\kbdralt.cab'
if (-not (Test-Path $cab)) { throw "the CAB was not produced" }
"CAB: $cab ($([math]::Round((Get-Item $cab).Length/1KB,1)) KB)"

# --- 4a. verify the CAB rather than assume it -------------------------------
# A split submission is invalid, and the thresholds above are what prevent a split. Confirm
# they worked: exactly one disk directory, and every staged file present under the
# subfolder, with nothing at the root.
$extraDisks = Get-ChildItem $subRoot -Directory | Where-Object { $_.Name -match '^disk\d+$' -and $_.Name -ne 'disk1' }
if ($extraDisks) {
    throw "makecab split the package across $($extraDisks.Count + 1) disks ($(($extraDisks.Name) -join ', ')). A split submission is not valid."
}

# Read the names as STORED IN THE CAB. expand.exe prints only base names, so it cannot answer
# the question that matters: Microsoft requires that a submission have no files at the archive
# root, each package in its own subfolder.
#
# Walk the CFFILE table rather than grepping the file for strings. Grepping looks tempting and
# is wrong — compressed data is full of byte pairs that read as "x\y", and the first attempt at
# this check duly reported two dozen imaginary root-level files.
function Get-CabStoredNames([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    if ($b.Length -lt 36 -or [Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'MSCF') {
        throw "$path is not a cabinet file"
    }
    $coffFiles = [BitConverter]::ToUInt32($b, 16)   # offset of the first CFFILE entry
    $cFiles    = [BitConverter]::ToUInt16($b, 28)   # how many there are
    $names = New-Object System.Collections.Generic.List[string]
    $p = [int]$coffFiles
    for ($i = 0; $i -lt $cFiles; $i++) {
        $p += 16                                    # fixed part of CFFILE
        $start = $p
        while ($p -lt $b.Length -and $b[$p] -ne 0) { $p++ }
        $names.Add([Text.Encoding]::ASCII.GetString($b, $start, $p - $start))
        $p++                                        # skip the terminator
    }
    $names
}

$storedNames = Get-CabStoredNames $cab | Sort-Object -Unique

$expectedNames = (Get-ChildItem $pkgDir -File | ForEach-Object { "kbdralt\$($_.Name)" }) | Sort-Object
$missing = $expectedNames | Where-Object { $_ -notin $storedNames }
$rootLevel = $storedNames | Where-Object { $_ -notlike 'kbdralt\*' }

if ($missing)   { throw "these staged files are not in the CAB: $($missing -join ', ')" }
if ($rootLevel) { throw "the CAB stores files outside the kbdralt\ subfolder, which makes the submission invalid: $($rootLevel -join ', ')" }

"CAB verified: $($storedNames.Count) file(s), all under kbdralt\"
$storedNames | ForEach-Object { "   $_" }

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
