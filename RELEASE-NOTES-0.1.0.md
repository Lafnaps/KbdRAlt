First public build of kbdralt — a Windows keyboard filter driver that remaps keys in
kernel mode, and a configurator for its rule table.

## ⚠ This release contains no installable driver

`kbdralt.sys` is shipped **unsigned**. `pnputil` will refuse the package because there is
no catalog, and it will not load on a normally configured x64 Windows machine. Test
signing does not change this: it relaxes *who* may sign a kernel driver, not *whether* it
is signed.

To run it you must sign it yourself with a certificate you generate — the archive ships
`package-and-sign.ps1`, which does that — on a machine with test signing on, Secure Boot
off and Memory Integrity off. Full procedure in
[INSTALL.md](https://github.com/Lafnaps/KbdRAlt/blob/v0.1.0/INSTALL.md).

No certificate is published with this release, and none ever will be. Shipping a signed
catalog plus the project's certificate would mean every machine that followed the
instructions trusts anything signed with a private key kept on someone else's computer,
for that certificate's whole lifetime, with no revocation. Your key stays yours.

An attestation-signed build, which needs none of this, requires an EV code-signing
certificate that has not been purchased yet.

## ⚠ This is kernel-mode code

A bug in a keyboard filter does not crash an application — it leaves the machine with no
working keyboard. **Use a virtual machine with a snapshot.**

The filter attaches to the *keyboard class*, so plugging in a second keyboard does not
help if something goes wrong. Read
[RECOVERY.md](https://github.com/Lafnaps/KbdRAlt/blob/v0.1.0/RECOVERY.md) **before**
installing — the working escape routes are On-Screen Keyboard, one-shot boot with driver
signature enforcement disabled, and WinRE.

Two more things worth knowing before you start:

- **Disabling Secure Boot triggers a BitLocker recovery prompt on the next boot.** Save
  your key first: `manage-bde -protectors -get C:`.
- Installing sets the keyboard class `UpperFilters` **wholesale**, which would overwrite
  any other keyboard filter driver. `deploy.ps1` refuses to install if it finds one.

## Downloads

| Asset | Size | Needs |
|---|---|---|
| `kbdralt-driver-0.1.0-x64-unsigned.zip` | ~50 KB | Windows SDK/WDK 10.0.26100 to sign it; test signing to load it |
| `kbdralt-config-0.1.0-win-x64.zip` | ~90 KB | [.NET 8 Desktop Runtime (x64)](https://dotnet.microsoft.com/download/dotnet/8.0) |
| `kbdralt-config-0.1.0-win-x64-self-contained.zip` | ~35 MB | nothing |

`.NET 9 or 10 alone will not run the small build` — the framework-dependent asset needs
the 8.x desktop runtime specifically. If you would rather not install it, take the
self-contained one.

Verify what you downloaded against `SHA256SUMS.txt`:

```powershell
Get-FileHash .\kbdralt-driver-0.1.0-x64-unsigned.zip -Algorithm SHA256
```

Nothing here is code-signed, so expect SmartScreen's *"Windows protected your PC"* on
first launch of the configurator, and a yellow *unknown publisher* prompt when it asks for
administrator rights to save. Both are expected; the checksums above are the check worth
doing instead. If Smart App Control is enabled, these binaries will not run at all — do
not turn it off for this, it cannot be turned back on without reinstalling Windows.

## Installing, in short

Unblock the zip before extracting (Properties → Unblock), then, from the extracted folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\package-and-sign.ps1
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -WhatIfOnly
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```

Reboot — rules are read in `DriverEntry`, so `pnputil /restart-device` is not enough — then
confirm the filter is in the right place:

```powershell
Get-PnpDevice -Class Keyboard -Status OK | ForEach-Object {
    (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_Stack).Data -join ' -> '
}
```

Expected: `\Driver\kbdclass -> \Driver\kbdralt -> ...`. If `kbdralt` appears *before*
`kbdclass`, the order is wrong and the driver will load, report `Running`, and do nothing.

The default rule set is only right Alt → `LAlt+LShift`, matching the driver's built-in
fallback, so a default install takes no key away from you. Everything else is opt-in.

## What it does, and what it does not

Two rule modes: `chord` swallows a key and its auto-repeat and emits a whole sequence once
on release; `remap` is a plain key-for-key substitution. Up to 64 rules, up to 8 output
keys each.

Because it works in the kernel it also applies on the secure desktop and the logon screen,
where AutoHotkey, PowerToys and hook-based remappers cannot reach.

Not implemented, by design: tap-hold, layers, macros, per-application profiles.
Per-application rules are impossible in a driver at all — the kernel does not know which
window has focus. There is no per-device binding yet either: rules apply to every keyboard.

## Known limitations

- **x64 only.** No ARM64 or x86 build.
- **Tested on Windows 11 Enterprise 25H2 (build 26200) only**, in a Hyper-V VM. Hot-plugging
  a USB keyboard is the one item in the test matrix that a Gen-2 VM cannot reproduce, so it
  is untested.
- Changing rules requires a reboot.
- An attestation signature, when it exists, will not be accepted on Windows Server —
  client editions only.

## Source and licence

AGPL-3.0-or-later. Tag `v0.1.0` in this repository is the complete corresponding source
for these binaries, including the scripts that build them; each archive carries `LICENSE`
and a `SOURCE.txt` naming the exact commit. `New-Release.ps1` reproduces these artifacts
from that commit — it builds from a clean clone of this repository rather than from a
working tree, so the published source really is what the binaries were made from.

This release and everything from commit `83c5b19` onward is AGPL-3.0-or-later only. The
dual non-commercial/commercial licence visible in the first public commit `ae049e2` is
superseded.

The driver's IOCTL plumbing follows the `kbfiltr` sample from
[microsoft/Windows-driver-samples](https://github.com/microsoft/Windows-driver-samples)
— Copyright (c) Microsoft Corporation, MIT License.
