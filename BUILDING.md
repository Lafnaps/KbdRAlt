# Building kbdralt

## Requirements

- Visual Studio 2022 **Build Tools** (the full IDE is not needed) with the C++ workload
  and the Spectre-mitigated libraries
- Windows SDK 10.0.26100
- Windows Driver Kit 10.0.26100
- the driver platform toolset — see the gotcha below, this one is easy to miss

```
msbuild kbdralt.vcxproj /p:Configuration=Release /p:Platform=x64 /t:Rebuild
```

With static analysis:

```
msbuild kbdralt.vcxproj /p:Configuration=Release /p:Platform=x64 /t:Rebuild /p:RunCodeAnalysis=true
```

Output: `x64\Release\kbdralt.sys` plus a stamped `kbdralt.inf`. No elevation required —
the build host only compiles; signing happens elsewhere.

## Toolchain gotchas

These cost real time to find, so they are written down.

**1. The WDK component for Build Tools has a different ID than for full VS.**
Installing the WDK MSI is not enough — modern WDK releases no longer ship the Visual
Studio extension with the MSI. For Build Tools the component is:

```
Component.Microsoft.Windows.DriverKit.BuildTools
```

The `.BuildTools` suffix is mandatory; `Component.Microsoft.Windows.DriverKit` exists only
in the full Visual Studio product graph and silently fails with *"Cannot find package … in
product graph"*. Component IDs can be listed from
`C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances\<id>\catalog.json`.

Also note `setup.exe modify` does **not** support a `--wait` flag; passing it fails with
exit code 87.

**2. Use the 64-bit MSBuild.** The x86 `MSBuild.exe` fails with
`Unable to load DLL 'x86\InfVerif.dll'` — WDK 26100 ships `infverif` only for x64/arm64.

**3. `SignMode=Off` in the project file.** By default MSBuild tries to auto-generate a
test certificate and fails with `CryptographicException: Access is denied` unless elevated.
Signing is a separate, deliberate step here.

**4. `EnableInf2cat=false` and `SkipPackageVerification=true`.** The catalog is built during
packaging, not during compilation. INF verification is run explicitly against the packaged
INF with the standalone tool, because the in-build task depends on the missing x86 DLL above:

```
"C:\Program Files (x86)\Windows Kits\10\Tools\10.0.26100.0\x64\infverif.exe" /h kbdralt.inf
```

**5. `C4152` under `/WX`.** `CONNECT_DATA.ClassService` is declared `PVOID`, so assigning
or calling a function pointer through it needs an explicit cast via `PVOID`. The original
Microsoft `kbfiltr` sample has the same construct.

## INF verification modes

| Mode | Meaning | Result here |
|---|---|---|
| `/h` | WHQL signature requirements | passes — this is the bar for attestation |
| `/u` | Universal driver | passes |
| `/w` | Windows Driver | **fails: ERROR 1321**, and that is expected |

`/w` forbids registry writes outside `HKR`, but a keyboard *class* filter must write
`UpperFilters` under the class key in `HKLM` — that is inherent to what it does. The
Windows Driver model targets Store-delivered drivers and is not required for attestation.
Do not try to "fix" this.

## Validating the driver

Static analysis should be clean. Beyond that, run Driver Verifier in a VM:

```
verifier /standard /driver kbdralt.sys
# reboot, then exercise the keyboard
verifier /query      # pool: peak allocations should equal current — no leaks
verifier /reset      # disable, reboot
```
