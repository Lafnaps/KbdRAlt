# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Lafnaps

<#
    New-Release.ps1 — build the downloadable artifacts for a GitHub release.

    HOW THIS DIFFERS FROM THE OTHER TWO PACKAGE SCRIPTS:
      package-and-sign.ps1      builds a TEST-SIGNED package for a lab machine.
      New-SubmissionPackage.ps1 builds the CAB for Microsoft attestation.
      This one builds WHAT STRANGERS DOWNLOAD.

    IT BUILDS FROM A CLEAN CLONE OF THE PUBLISHED REPOSITORY, NOT FROM THE WORKING TREE.
    That is the whole design, and it is not fussiness:

      * AGPL section 6 wants the binary's corresponding source to be the source people can
        actually get. Building from a working tree can ship a binary whose source exists in
        no commit anywhere.
      * The .NET SDK stamps the git commit into the assembly's ProductVersion and writes a
        SourceLink map from the repository root. Built from the private superproject those
        point at commits and paths that do not exist on GitHub, so every URL 404s.
      * The published tree has kbdralt/ at its ROOT, while the working tree nests it one
        level down. Only a real clone gets the paths right.

    The driver ships UNSIGNED, deliberately. The alternative would be to publish a
    self-signed certificate and tell people to import it into their Trusted Root store,
    which hands anyone holding that private key the ability to sign code their machine
    will trust. A project cannot ask that of its users. Downloaders sign the payload with
    their own certificate (package-and-sign.ps1 generates one locally) or wait for the
    attestation-signed release.

    The script verifies what it built rather than trusting the build: version stamped as
    asked, signature absent, INF acceptable, no local paths embedded. A release is the one
    artefact nobody can quietly rebuild, so every check runs before anything is zipped.

    It does NOT publish, and it deliberately does not create or push a git tag. Pushing a
    tag from the private superproject would upload that repository's whole object graph —
    including the directories the subtree split exists to keep out. The tag is created
    server-side by `gh release create --target <sha>`; the command is printed at the end.

    No elevation required. Needs network access for the clone.
#>
[CmdletBinding()]
param(
    # Marketing version, three components: 0.1.0. The fourth is always 0 — DriverVer needs
    # four, and a hand-maintained build counter would only ever drift.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    # What to build: a commit, branch or tag that EXISTS ON THE PUBLIC REMOTE. Defaults to
    # the tip of the local public-kbdralt split branch, which is verified to be published
    # before anything is built.
    [string]$Ref,

    [string]$RepoUrl = 'https://github.com/Lafnaps/KbdRAlt.git',

    # DriverVer date. Pinned so a rebuild of the same ref reproduces the INF byte for byte.
    # stampinf wants two digits for month and day.
    [ValidatePattern('^\d{2}/\d{2}/\d{4}$')]
    [string]$DriverVerDate = (Get-Date -Format 'MM/dd/yyyy'),

    [string]$OutDir,
    [string]$WorkDir,

    [switch]$SkipCodeAnalysis
)
$ErrorActionPreference = 'Stop'

$version4 = "$Version.0"
if (-not $OutDir)  { $OutDir  = Join-Path $PSScriptRoot "release\v$Version" }
# Not under %TEMP%: MSBuild warns (MSB8029) when the intermediate directory lives there,
# and a warning in a release build is noise nobody should have to learn to ignore.
if (-not $WorkDir) { $WorkDir = Join-Path $env:LOCALAPPDATA "kbdralt-release\v$Version" }

$kit      = 'C:\Program Files (x86)\Windows Kits\10'
$infverif = "$kit\Tools\10.0.26100.0\x64\infverif.exe"
if (-not (Test-Path $infverif)) { throw "tool not found: $infverif" }

$msbuild = Get-ChildItem @(
    'C:\Program Files\Microsoft Visual Studio\2022\*\MSBuild\Current\Bin\MSBuild.exe'
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\*\MSBuild\Current\Bin\MSBuild.exe'
) -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $msbuild) { throw "MSBuild for VS 2022 not found" }

function Step($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "  OK   $text" -ForegroundColor Green }

# --- 0. decide what to build, and prove it is published ---------------------
Step "resolve the source ref"

if (-not $Ref) {
    Push-Location $PSScriptRoot
    try {
        $Ref = (& git rev-parse public-kbdralt 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $Ref) {
            throw "no -Ref given and the local public-kbdralt branch does not exist. Run the subtree split first."
        }
    } finally { Pop-Location }
    "  defaulting to the local public-kbdralt tip: $Ref"
}

# The clone below would happily fetch a branch tip that moves later. Resolve to an
# immutable commit and keep using that everywhere: in the build, in SOURCE.txt, and in the
# gh command. A release must name one commit, not a moving reference.
Step "clone $RepoUrl"
if (Test-Path $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
& git clone --quiet $RepoUrl $WorkDir
if ($LASTEXITCODE -ne 0) { throw "git clone failed" }

& git -C $WorkDir checkout --quiet --detach $Ref
if ($LASTEXITCODE -ne 0) {
    throw ("'$Ref' is not present in $RepoUrl. This is the trap the script exists to catch: " +
           "the commit that builds the artifacts must already be PUBLISHED, or the release " +
           "would ship binaries whose source nobody can obtain. Push first, then release.")
}
$commit = (& git -C $WorkDir rev-parse HEAD).Trim()
Ok "building from published commit $commit"

# The published repo has kbdralt/ at its root.
$src = $WorkDir
foreach ($f in 'kbdralt.vcxproj', 'kbdralt.rc', 'LICENSE', 'gui\KbdRAlt.Config.csproj') {
    if (-not (Test-Path (Join-Path $src $f))) {
        throw ("$f is missing from the published tree at $commit. The version and packaging " +
               "work has not been pushed yet — building now would produce artifacts the " +
               "published source cannot regenerate.")
    }
}

# One number for driver, GUI and tag. The two project files are coupled only by a comment,
# so assert it here rather than discovering the mismatch in a downloaded zip.
$csproj = Get-Content (Join-Path $src 'gui\KbdRAlt.Config.csproj') -Raw
if ($csproj -notmatch '<Version>\s*' + [regex]::Escape($Version) + '\s*</Version>') {
    throw "gui/KbdRAlt.Config.csproj at $commit does not declare <Version>$Version</Version>"
}
$manifest = Get-Content (Join-Path $src 'gui\app.manifest') -Raw
if ($manifest -notmatch [regex]::Escape("version=`"$version4`"")) {
    throw "gui/app.manifest at $commit does not declare version=`"$version4`""
}
Ok "GUI version metadata agrees with $Version"

# --- 1. driver --------------------------------------------------------------
Step "driver: build $version4 (DriverVer date $DriverVerDate)"
$buildArgs = @(
    (Join-Path $src 'kbdralt.vcxproj')
    '/p:Configuration=Release'
    '/p:Platform=x64'
    '/t:Rebuild'
    "/p:KbdRAltVersion=$version4"
    "/p:KbdRAltDriverVerDate=$DriverVerDate"
    '/v:minimal'
    '/nologo'
)
if (-not $SkipCodeAnalysis) { $buildArgs += @('/p:RunCodeAnalysis=true', '/p:EnablePREfast=true') }
& $msbuild @buildArgs
if ($LASTEXITCODE -ne 0) { throw "driver build failed (exit $LASTEXITCODE)" }

$buildDir = Join-Path $src 'x64\Release'
$sys = Join-Path $buildDir 'kbdralt.sys'
$inf = Join-Path $buildDir 'kbdralt.inf'
foreach ($f in $sys, $inf) { if (-not (Test-Path $f)) { throw "$f was not produced" } }

Step "driver: verify what was actually built"

# Unsigned is the contract for a published payload. A stray signature means the build
# picked up SignMode from somewhere.
$sig = Get-AuthenticodeSignature $sys
if ($sig.Status -ne 'NotSigned') {
    throw "kbdralt.sys carries a signature ($($sig.Status)). A published payload must be clean."
}
Ok "kbdralt.sys is unsigned"

$fv = (Get-Item $sys).VersionInfo.FileVersion
if ($fv -ne $version4) {
    throw ("FileVersion in the binary is '$fv', expected '$version4'. The VERSIONINFO " +
           "resource did not receive the version — note that rc.exe accepts a malformed " +
           "VALUE silently and produces a resource that reads back EMPTY.")
}
Ok "FileVersion = $fv"

$driverVerLine = (Select-String -Path $inf -Pattern '^\s*DriverVer\s*=').Line.Trim()
foreach ($expect in $version4, $DriverVerDate) {
    if ($driverVerLine -notmatch [regex]::Escape($expect)) {
        throw "INF says '$driverVerLine', expected it to contain '$expect'"
    }
}
Ok $driverVerLine

# Catches a stale or Debug INF in one line: the Debug INF carries a different ProviderName.
$infText = Get-Content $inf -Raw
if ($infText -notmatch 'ProviderName\s*=\s*"kbdralt"') {
    throw "the staged INF does not carry ProviderName = `"kbdralt`" — wrong or stale INF"
}
Ok 'ProviderName = "kbdralt"'

& $infverif /h $inf | Out-Null
if ($LASTEXITCODE -ne 0) { throw "infverif /h failed (exit $LASTEXITCODE)" }
Ok "infverif /h"

function Assert-NoAbsolutePaths($file, $label) {
    $bytes = [IO.File]::ReadAllBytes($file)
    $ascii = -join ($bytes | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { "`n" } })
    $bad = $ascii -split "`n" | Where-Object { $_ -match '^[A-Za-z]:\\' -and $_ -notmatch '^D:\\a\\_work' }
    if ($bad) { throw "$label embeds absolute paths: $($bad -join ', ')" }
}
# D:\a\_work is Microsoft's own build agent path inside the stock .NET apphost, not ours.
Assert-NoAbsolutePaths $sys 'kbdralt.sys'
Ok "no local paths embedded in kbdralt.sys"

# --- 2. GUI -----------------------------------------------------------------
$gui   = Join-Path $src 'gui\KbdRAlt.Config.csproj'
$guiFd = Join-Path $WorkDir 'out\gui-fd'
$guiSc = Join-Path $WorkDir 'out\gui-sc'

Step "GUI: publish framework-dependent"
& dotnet publish $gui -c Release -r win-x64 --self-contained false -o $guiFd -v quiet --nologo
if ($LASTEXITCODE -ne 0) { throw "GUI publish (framework-dependent) failed" }

Step "GUI: publish self-contained, single file"
# Self-contained pulls .NET runtime packs from NuGet. That does not add a dependency to the
# shipped app or to a normal source build, but this step does need a network or a warm
# package cache.
& dotnet publish $gui -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true -o $guiSc -v quiet --nologo
if ($LASTEXITCODE -ne 0) { throw "GUI publish (self-contained) failed" }

Step "GUI: verify"
$guiDll = Join-Path $guiFd 'KbdRAltConfig.dll'
if (-not (Test-Path $guiDll)) { throw "$guiDll was not produced" }
$guiVer = (Get-Item $guiDll).VersionInfo.FileVersion
if ($guiVer -ne $version4) { throw "GUI FileVersion is '$guiVer', expected '$version4'" }
Ok "GUI FileVersion = $guiVer"

# The SDK appends the commit to ProductVersion. Since we built from a clean clone of the
# public repo, it must be the published commit — that is the check that the whole
# clone-first design exists to make possible.
$guiProduct = (Get-Item $guiDll).VersionInfo.ProductVersion
if ($guiProduct -notmatch [regex]::Escape($commit)) {
    throw "GUI ProductVersion is '$guiProduct' but the build commit is $commit"
}
Ok "GUI ProductVersion = $guiProduct"

$scExe = Join-Path $guiSc 'KbdRAltConfig.exe'
if (-not (Test-Path $scExe)) { throw "$scExe was not produced" }
$scCfg = Join-Path $guiSc 'KbdRAltConfig.runtimeconfig.json'
if (Test-Path $scCfg) {
    # A genuinely self-contained publish has no runtimeconfig beside the exe. If one is
    # there, the "no runtime needed" asset silently needs a runtime — which is exactly the
    # mistake the documented publish command made once already.
    throw "the self-contained output still has a runtimeconfig.json — it is framework-dependent"
}
Ok "self-contained build carries its own runtime ($([math]::Round((Get-Item $scExe).Length/1MB,1)) MB)"

Get-ChildItem $guiFd, $guiSc -Filter '*.pdb' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Warning "removing stray symbol file: $($_.Name)"
    Remove-Item $_.FullName -Force
}
Assert-NoAbsolutePaths $guiDll 'the GUI assembly'
Ok "no local paths embedded in the GUI assembly"

# --- 2a. the scripts must survive Windows PowerShell 5.1 --------------------
# This project has been bitten by it three times. Windows PowerShell 5.1 reads a .ps1
# without a byte-order mark as ANSI, so a single em dash in a comment turns into mojibake
# and the file fails to PARSE — the script never runs at all. It is invisible on this
# machine, because PowerShell 7 reads UTF-8 regardless, and it is guaranteed on a
# downloader's default shell.
Step "scripts: BOM and a real 5.1 parse"
$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
foreach ($s in Get-ChildItem (Join-Path $src '*.ps1')) {
    $b = [IO.File]::ReadAllBytes($s.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
        throw "$($s.Name) has no UTF-8 BOM: Windows PowerShell 5.1 will misread it as ANSI"
    }
    if (Test-Path $ps51) {
        $r = & $ps51 -NoProfile -Command "`$e=`$null;[void][System.Management.Automation.Language.Parser]::ParseFile('$($s.FullName)',[ref]`$null,[ref]`$e);if(`$e.Count){`$e[0].Message}else{'OK'}"
        if ($r -ne 'OK') { throw "$($s.Name) does not parse under Windows PowerShell 5.1: $r" }
    }
}
Ok "all .ps1 carry a BOM and parse under 5.1"

# --- 3. stage ---------------------------------------------------------------
Step "stage"
if (Test-Path $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$stageRoot   = Join-Path $WorkDir 'stage'
$driverStage = Join-Path $stageRoot "kbdralt-driver-$Version-x64-unsigned"
$fdStage     = Join-Path $stageRoot "kbdralt-config-$Version-win-x64"
$scStage     = Join-Path $stageRoot "kbdralt-config-$Version-win-x64-self-contained"
foreach ($d in $driverStage, $fdStage, $scStage) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

# AGPL section 6 wants the licence and a route to the corresponding source to travel WITH
# the object code. A link on a web page the user may never read is thin; the text is 35 KB.
$license = Join-Path $src 'LICENSE'
$sourceNote = @"
kbdralt $Version
Copyright (C) 2026 Lafnaps

This program is free software: you can redistribute it and/or modify it under the terms
of the GNU Affero General Public License as published by the Free Software Foundation,
either version 3 of the License, or (at your option) any later version. See LICENSE.

These binaries were built from, and their complete corresponding source code is:

    https://github.com/Lafnaps/KbdRAlt/tree/v$Version
    commit $commit

publicly available at no charge under the same licence. The build scripts are part of it:
New-Release.ps1 reproduces these artifacts from that commit.
"@

# Driver payload. package-and-sign.ps1 is not optional: an unsigned .sys cannot load on
# x64 under any circumstances, so the archive would be inert without the means to sign it.
# Staged by explicit filename — never by archiving x64\, which also holds .obj, .pdb, logs
# and a stale Debug tree.
Copy-Item $sys, $inf $driverStage
foreach ($f in 'package-and-sign.ps1', 'deploy.ps1', 'uninstall.ps1', 'Set-KbdRAltRules.ps1',
               'INSTALL.md', 'RECOVERY.md', 'README.md') {
    $p = Join-Path $src $f
    if (-not (Test-Path $p)) { throw "$f is missing from the published tree — cannot stage the driver archive" }
    Copy-Item $p $driverStage
}
Copy-Item $license $driverStage
$sourceNote | Set-Content (Join-Path $driverStage 'SOURCE.txt') -Encoding UTF8

Copy-Item (Join-Path $guiFd '*') $fdStage -Recurse
Copy-Item $scExe $scStage
foreach ($d in $fdStage, $scStage) {
    Copy-Item $license $d
    Copy-Item (Join-Path $src 'gui\README.md') $d
    $sourceNote | Set-Content (Join-Path $d 'SOURCE.txt') -Encoding UTF8
}

foreach ($d in $driverStage, $fdStage, $scStage) {
    "  {0}: {1} files" -f (Split-Path $d -Leaf), (Get-ChildItem $d -Recurse -File).Count
}

# --- 4. archives and checksums ---------------------------------------------
Step "archives"
# Archive the FOLDER, not its contents: extracting must produce one directory, not scatter
# a dozen loose files into the user's Downloads.
$zips = @()
foreach ($d in $driverStage, $fdStage, $scStage) {
    $zip = Join-Path $OutDir ((Split-Path $d -Leaf) + '.zip')
    Compress-Archive -Path $d -DestinationPath $zip -CompressionLevel Optimal
    $zips += $zip
    "  {0}  {1:N2} MB" -f (Split-Path $zip -Leaf), ((Get-Item $zip).Length / 1MB)
}

Step "checksums"
$sumFile = Join-Path $OutDir 'SHA256SUMS.txt'
$lines = foreach ($z in $zips) {
    "{0}  {1}" -f (Get-FileHash $z -Algorithm SHA256).Hash.ToLower(), (Split-Path $z -Leaf)
}
# LF and lowercase hex, so the file works with sha256sum -c anywhere.
[IO.File]::WriteAllText($sumFile, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
$lines | ForEach-Object { "  $_" }

# --- 5. what to do next -----------------------------------------------------
Step "done"
$notes = Join-Path $src "RELEASE-NOTES-$Version.md"
if (-not (Test-Path $notes)) { throw "RELEASE-NOTES-$Version.md is missing from the published tree" }

@"
Artifacts in $OutDir
Built from published commit $commit

Verify one on Windows:
  Get-FileHash .\kbdralt-driver-$Version-x64-unsigned.zip -Algorithm SHA256

Publish. The tag is created SERVER-SIDE by --target, on the published lineage.
Do NOT 'git push public v$Version': this working tree is a different repository whose
history contains directories the subtree split deliberately excludes, and pushing a tag
would upload all of them.

  gh release create v$Version --repo Lafnaps/KbdRAlt ``
      --target $commit ``
      --prerelease ``
      --title "v$Version — unsigned, requires test signing" ``
      --notes-file "$notes" ``
      "$OutDir\kbdralt-driver-$Version-x64-unsigned.zip" ``
      "$OutDir\kbdralt-config-$Version-win-x64.zip" ``
      "$OutDir\kbdralt-config-$Version-win-x64-self-contained.zip" ``
      "$sumFile"
"@
