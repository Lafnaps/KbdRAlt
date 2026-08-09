# kbdralt — a Windows keyboard filter driver that remaps keys in kernel mode

A small KMDF upper-filter driver for the `kbdclass` stack. It rewrites keystrokes
according to a rule table before any application — or Windows itself — sees them.

Two rule modes:

| Mode | Behaviour | Example |
|---|---|---|
| `chord` | the key is swallowed on press and on auto-repeat; on **release** the whole output sequence is emitted at once (all makes in order, then all breaks in reverse) | Right Alt → `LAlt+LShift`, i.e. the standard Windows *switch input language* hotkey |
| `remap` | plain key-for-key substitution | CapsLock → `` ` `` |

## Why this exists

User-mode remappers (AutoHotkey, kanata/kmonad in LLHOOK mode, PowerToys) cannot work
on the secure desktop, on the logon screen, or before the user session exists. They also
die with their process.

The closest thing to a general-purpose keyboard filter for Windows has been
[Interception](https://github.com/oblitum/Interception), and it has been unmaintained for
years. Its users report devices that stop responding after reconnection, and machines where
it will not load under Memory Integrity. Everything built on top of it inherits that.

kanata's README has carried an open invitation since 2022: *"If you know anything about
writing a keyboard driver for Windows, starting an open-source alternative to the
Interception driver would be lovely."*

**This is not that**, and the difference matters. kanata and the other downstream tools
consume Interception's *user-mode API*; kbdralt deliberately exposes none. It is a
self-contained rule table applied in the kernel, so nothing can be scripted on top of it —
you configure it and it runs. What it does have in common with the wish is that it is a
working KMDF keyboard filter under a free licence, which is the part that did not exist.

## Status

Working and tested, but **unsigned** — see *Downloads* and *Signing* below. Prebuilt
binaries are published under [Releases](https://github.com/Lafnaps/KbdRAlt/releases); the
driver in them cannot be loaded without signing it yourself.

Verified on Windows 11 Enterprise 25H2 (build 26200), x64, in a Hyper-V VM:

- basic translation, both rule modes;
- auto-repeat: holding the key produces exactly one chord, and nothing is left held down
  between press and release;
- sleep/resume, device stack rebuild, RDP connect/disconnect/reconnect;
- static analysis (`/analyze`) clean;
- **Driver Verifier** (standard flags + WDF), ~300 input events: no bugchecks, exactly
  one non-paged pool allocation, peak equals current — no leaks.

Not implemented, by design: tap-hold, layers, macros, per-application profiles.
Per-application rules are impossible in a driver at all — the kernel does not know
which window is focused.

## ⚠ This is kernel-mode code

A bug in a keyboard filter does not crash an application — it leaves the machine
without a keyboard, or bugchecks it on boot. **Test in a virtual machine with
snapshots first.**

The filter attaches to the keyboard *class*, so a second keyboard is not a way out.
Read [RECOVERY.md](RECOVERY.md) before installing: On-Screen Keyboard, a one-shot boot
with driver signature enforcement disabled, and WinRE are the routes that work.

## How it works

The driver hooks `IOCTL_INTERNAL_KEYBOARD_CONNECT`, replaces `kbdclass`'s
`ClassService` callback with its own, and rewrites `KEYBOARD_INPUT_DATA` packets
before passing them up.

**Filter order is critical and easy to get wrong.** In the `UpperFilters` value of the
Keyboard class, drivers are listed bottom-up: the first entry sits closest to the port
driver. This driver must be **below** `kbdclass`, because `IOCTL_INTERNAL_KEYBOARD_CONNECT`
travels *downward* from `kbdclass`. So the value must be:

```
UpperFilters = kbdralt, kbdclass
```

If you append instead (`kbdclass, kbdralt`), the driver loads fine, the service reports
`Running`, and it does absolutely nothing — the connect IOCTL never reaches it. Verify
the real stack instead of trusting the service state:

```powershell
Get-PnpDevice -Class Keyboard -Status OK | ForEach-Object {
    (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_Stack).Data -join ' -> '
}
# expected:  \Driver\kbdclass -> \Driver\kbdralt -> <port driver> -> <bus>
```

Note that the INF sets `UpperFilters` **wholesale**, which overwrites any third-party
keyboard class filters. `deploy.ps1` checks for those and refuses to install without
`-Force`.

### AltGr

On many keyboards the right Alt key is AltGr, and user-mode hooks see a synthetic
`LCtrl` alongside it. That is a virtual-key level artifact produced above this driver
(scan code `0x21D`, which never appears in Raw Input; a real Ctrl is `0x1D`). Since the
driver replaces the scan code before `VK_RMENU` is ever produced, the synthetic Ctrl
never appears. No special handling is needed — and suppressing Ctrl here would break
`Ctrl+C`.

### Scancode Map

This driver runs **before** the registry `Scancode Map` (which `kbdclass` applies, and
`kbdclass` sits above us). A rule here wins; a `Scancode Map` entry for the same key
simply stops firing.

## Configuration

Rules live in `HKLM\SYSTEM\CurrentControlSet\Services\kbdralt\Parameters\Rules` as a
binary blob. Parsing text in kernel mode is a well-known source of bugs, so the driver
reads a fixed-layout structure and `Set-KbdRAltRules.ps1` produces it from readable input:

```powershell
.\Set-KbdRAltRules.ps1 -Rule @(
    'E0:38 = chord : 38,2A',   # Right Alt -> LAlt+LShift
    '3A    = remap : 29'       # CapsLock  -> `
)
```

Keys are set-1 scan codes in hex, optionally prefixed with `E0:` for extended keys.

There is also a **GUI configurator** — see [gui/](gui/) — which writes the same value.
It shows driver health (including whether the filter is in the correct position relative
to `kbdclass`), decodes the stored table into readable key names, captures keys by
pressing them, and validates with the same rules the driver applies. Its output is
verified byte-identical to the script's.

The blob is validated strictly: version, count, sizes, scan-code ranges, mode/output
agreement, and duplicate inputs. It is accepted **whole or not at all** — a partially
applied rule set is worse than none. If the value is missing or invalid, the driver falls
back to a built-in `Right Alt → LAlt+LShift` rule, so it never degrades into doing nothing
unpredictable.

**Rules are read in `DriverEntry`, so a reboot is required after changing them.**
`pnputil /restart-device` is not enough — the device restarts but the driver stays loaded.

## Downloads

Binaries are published under
[Releases](https://github.com/Lafnaps/KbdRAlt/releases): the driver payload, and the
configurator in a small build that needs the .NET 8 Desktop Runtime and a self-contained
one that needs nothing. Checksums are in `SHA256SUMS.txt`; nothing is code-signed, so
SmartScreen will object.

**The published driver is unsigned and cannot be loaded as it stands.** Signing it is your
step, and it requires the WDK. Step-by-step: [INSTALL.md](INSTALL.md).

## Building

See [BUILDING.md](BUILDING.md). Short version:

```
msbuild kbdralt.vcxproj /p:Configuration=Release /p:Platform=x64 /t:Rebuild
```

`KbdRAltVersion` is the single source of the version number: it feeds both the
`VERSIONINFO` resource in `kbdralt.rc` and the INF's `DriverVer`. A release build pins the
date too, so the INF is reproducible from the tag:

```
msbuild kbdralt.vcxproj /p:Configuration=Release /p:Platform=x64 /t:Rebuild ^
        /p:KbdRAltVersion=0.1.0.0 /p:KbdRAltDriverVerDate=08/09/2026
```

## Signing

Binary releases contain an **unsigned reference build**; the driver is signed by whoever
runs it. Loading it requires either:

- **test signing** — a certificate *you* generate, `bcdedit /set {current} testsigning on`,
  Secure Boot off and Memory Integrity off. Fine for a VM; `package-and-sign.ps1`
  automates the whole flow, minting the certificate in your own store.
- **attestation signing** by Microsoft — requires an EV code-signing certificate and a
  Partner Center account. `New-SubmissionPackage.ps1` builds the CAB for submission
  (clean unsigned `.sys`; Microsoft produces the catalog). Note that an attestation
  signature is **not accepted on Windows Server** — client editions only.

No certificate is distributed with the releases, and none will be. A published signing
certificate that users are told to trust as a root authority vouches for anything signed
with its private key, on every machine that imports it, for the certificate's whole life.

## Scripts

| Script | Purpose |
|---|---|
| `Set-KbdRAltRules.ps1` | write the rule table to the registry |
| `package-and-sign.ps1` | sign the payload with a locally generated certificate, for a test-signing machine |
| `New-SubmissionPackage.ps1` | build the CAB for attestation submission |
| `deploy.ps1` | install: checks code-integrity settings and foreign filters, applies rules, handles `Scancode Map` |
| `uninstall.ps1` | remove the package and repair the keyboard class `UpperFilters` |
| `New-Release.ps1` | build the downloadable release artifacts from a clean clone of the published repository |
| `altgr-probe.ps1` | diagnostic: logs Raw Input vs `WH_KEYBOARD_LL` side by side |

All scripts are saved as UTF-8 **with** a byte-order mark. Windows PowerShell 5.1 reads a
BOM-less file as ANSI, and one em dash in a comment is then enough to stop it parsing.

### Which build am I running?

The driver binary is not in `System32\drivers` — a primitive driver package stays in the
Driver Store. Follow the service's `ImagePath`:

```powershell
$ip = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdralt').ImagePath
(Get-Item ($ip -replace '^\\SystemRoot\\', "$env:SystemRoot\")).VersionInfo |
    Format-List FileVersion, CompanyName
```

Include that, and the configurator's own version, in any bug report.

`deploy.ps1 -WhatIfOnly` runs every check and installs nothing — the right first
invocation on any machine. `-PackageDir` overrides where it looks for the signed package;
by default it tries the build output, then a `package\` folder beside the script, then the
script's own folder, so an unpacked release archive works without arguments.

## Third-party

The IOCTL plumbing follows the `kbfiltr` sample from
[microsoft/Windows-driver-samples](https://github.com/microsoft/Windows-driver-samples) —
Copyright (c) Microsoft Corporation, MIT License.

## Licence

**GNU AGPL v3** — see [LICENSE](LICENSE).

Use it, read it, modify it, ship it. The one obligation: if you distribute this
software or a derivative, or make it available to others over a network, the complete
corresponding source must be available under the same licence. Keeping your changes
private while shipping them to users is not permitted.

This is an OSI-approved open source licence. There is no separate commercial track and
no non-commercial restriction: everyone gets the same terms.
