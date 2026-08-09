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

The only general-purpose signed keyboard filter that ever existed —
[Interception](https://github.com/oblitum/Interception) — is effectively dead: its
signature does not satisfy HVCI, and on current Windows 11 it can leave the machine
without a working keyboard. Everything built on top of it inherits that.

As of early 2026 the kanata maintainer explicitly asks the community for an open-source
replacement. This driver is a small, focused answer to that: it does key→key and
key→chord translation in the kernel, and nothing else.

## Status

Working and tested, but **unsigned** — see *Signing* below.

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
snapshots first.** Recovery from a bad install may require Safe Mode.

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

The blob is validated strictly: version, count, sizes, scan-code ranges, mode/output
agreement, and duplicate inputs. It is accepted **whole or not at all** — a partially
applied rule set is worse than none. If the value is missing or invalid, the driver falls
back to a built-in `Right Alt → LAlt+LShift` rule, so it never degrades into doing nothing
unpredictable.

**Rules are read in `DriverEntry`, so a reboot is required after changing them.**
`pnputil /restart-device` is not enough — the device restarts but the driver stays loaded.

## Building

See [BUILDING.md](BUILDING.md). Short version:

```
msbuild kbdralt.vcxproj /p:Configuration=Release /p:Platform=x64 /t:Rebuild
```

## Signing

The driver is shipped as source only. Loading it requires either:

- **test signing** — self-signed certificate, `bcdedit /set testsigning on`, Secure Boot
  off. Fine for a VM; `package-and-sign.ps1` automates the whole flow.
- **attestation signing** by Microsoft — requires an EV code-signing certificate and a
  Partner Center account. `New-SubmissionPackage.ps1` builds the CAB for submission
  (clean unsigned `.sys`; Microsoft produces the catalog). Note that an attestation
  signature is **not accepted on Windows Server** — client editions only.

## Scripts

| Script | Purpose |
|---|---|
| `Set-KbdRAltRules.ps1` | write the rule table to the registry |
| `package-and-sign.ps1` | build a test-signed package for a lab machine |
| `New-SubmissionPackage.ps1` | build the CAB for attestation submission |
| `deploy.ps1` | install: checks foreign filters, applies rules, handles `Scancode Map` |
| `altgr-probe.ps1` | diagnostic: logs Raw Input vs `WH_KEYBOARD_LL` side by side |

## Licence

Free for non-commercial use under **AGPL v3 plus a non-commercial restriction**;
a separate licence is required for commercial use. See [LICENSE](LICENSE).

In short: use it, read it, modify it, learn from it. If you ship it or build a product
on it, publish your source under the same terms. If you are a company using it to make
money, get in touch.

Because of the non-commercial clause this is source-available rather than OSI open
source, and the licence says so plainly rather than pretending otherwise.
