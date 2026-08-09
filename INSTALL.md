# Installing kbdralt from a release archive

**Read this first: the release contains no installable driver.** `kbdralt.sys` is shipped
unsigned. It will not load on a normally configured x64 Windows machine, and `pnputil`
will refuse the package outright because there is no catalog. To run it you have to sign
it yourself, with a certificate you generate, on a machine configured to accept that.

That is not an oversight. The alternative — publishing a signed catalog together with the
project's own certificate and telling you to import it into your Trusted Root store —
would make every machine that followed the instructions trust *anything* signed with a
private key kept on someone else's computer, for the life of that certificate, with no
revocation. Signing it yourself keeps that key yours.

A production build signed by Microsoft attestation needs no test signing and none of the
steps below. It is not available yet; see *Signing* in [README.md](README.md).

**Do this on a virtual machine with a snapshot, or on a computer you are willing to
reinstall.** A keyboard filter that misbehaves does not crash an application — it leaves
the machine with no working keyboard. Read [RECOVERY.md](RECOVERY.md) *before* you start,
not after.

---

## 0. Unblock the download

Windows marks files that came from the internet, and PowerShell refuses to run marked
scripts under the default execution policy. Right-click the downloaded `.zip` →
**Properties** → tick **Unblock** → OK, *then* extract. If you already extracted it:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

The scripts are not code-signed, so run them explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -WhatIfOnly
```

## 1. Preconditions

Three separate gates have to be open before Windows will load a self-signed kernel driver.
`deploy.ps1` checks all three and refuses to install if any is shut — installing anyway
would rewrite your keyboard configuration and leave you with a driver that never loads.

| Gate | How to open it |
|---|---|
| Test signing | `bcdedit /set {current} testsigning on`, then reboot |
| Secure Boot | Disable in firmware. **See the warning below.** |
| Memory Integrity (HVCI) | Windows Security → Device security → Core isolation → off, then reboot |

> **Disabling Secure Boot will trigger a BitLocker recovery prompt on the next boot.**
> Before you touch firmware settings, save your recovery key:
> ```powershell
> manage-bde -protectors -get C:
> ```
> Without that 48-digit key you will not get back into the machine.

Test mode is machine-wide, not per-driver. It puts a watermark on the desktop and it
breaks kernel anti-cheat systems (Vanguard, EAC, BattlEye).

Signing needs the Windows SDK/WDK 10.0.26100, for `signtool`, `Inf2Cat` and `infverif`.
**It does not have to be the same machine you install on** — sign on your workstation,
copy the resulting `package\` folder to the test machine, install there. That is the
normal arrangement: the machine you are willing to run an unsigned kernel driver on is
rarely the machine you keep a toolchain on.

If you are installing the WDK anyway, building from source is barely more work; see
[BUILDING.md](BUILDING.md).

## 2. Sign the payload

From the extracted folder, in a normal (non-elevated) PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\package-and-sign.ps1
```

This generates a code-signing certificate in your own `CurrentUser\My` store if you do not
already have one, embeds a signature in `kbdralt.sys`, builds the catalog, signs that too,
and writes everything to a `package\` subfolder along with `kbdralt-test.cer`.

On the **test machine only**, import that `.cer` into both `Root` and `TrustedPublisher`.
On a throwaway VM this is fine. On a machine you care about it is not: see the top of this
file for why.

## 3. Dry run

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -WhatIfOnly
```

Elevated. This performs every check and installs nothing. It reports the code-integrity
gates, the current `UpperFilters`, any third-party keyboard filters that the install would
overwrite, every keyboard device the filter will attach to, and the rules it would write.

If it reports foreign filters, stop. The INF sets `UpperFilters` wholesale and would
remove them.

## 4. Install

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```

The default rule set is only right Alt → `LAlt+LShift`, which is what the driver falls
back to on its own, so a default install takes no key away from you. Anything else is
opt-in:

```powershell
.\deploy.ps1 -Rules 'E0:38 = chord : 38,2A', '3A = remap : 29'
```

Keys are set-1 scan codes in hex, `E0:` prefix for extended keys. `3A = remap : 29` maps
CapsLock to the key left of `1`.

`deploy.ps1` saves your previous `UpperFilters` to
`%ProgramData%\kbdralt-upperfilters-backup-<timestamp>.txt` before changing anything.
Recovery needs that file — do not delete it.

## 5. Reboot, then verify

A reboot is required: the driver reads its rule table in `DriverEntry`, and
`pnputil /restart-device` does not re-read it.

```powershell
Get-PnpDevice -Class Keyboard -Status OK | ForEach-Object {
    (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_Stack).Data -join ' -> '
}
```

Expected: `\Driver\kbdclass -> \Driver\kbdralt -> <port driver> -> <bus>`.

If `kbdralt` appears *before* `kbdclass`, the filter order is wrong: the driver loads, the
service reports `Running`, and it does nothing at all. Service state proves nothing here —
check the stack.

## 6. Changing rules later

Either script or GUI; both write the same registry value, and both need a reboot to take
effect.

```powershell
.\Set-KbdRAltRules.ps1 -Rule 'E0:38 = chord : 38,2A'
```

The configurator is a separate download. It also shows driver health, including the filter
ordering above. It runs unelevated and asks for administrator rights only when saving.

## 7. Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -WhatIfOnly
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

It finds the `oemNN.inf` the package was renamed to in the driver store, removes it, and
then checks the class `UpperFilters` and repairs it from the backup file if `kbdralt` is
still listed — removing a driver package does not reliably undo the class-level registry
value the INF wrote, and a filter entry pointing at a driver that is no longer installed is
not a state to leave a keyboard stack in. Add `-Purge` to drop the service key and the
stored rules as well. Reboot afterwards.

By hand, if you would rather:

```powershell
pnputil /enum-drivers          # find the oemNN.inf whose Original Name is kbdralt.inf
pnputil /delete-driver oemNN.inf /uninstall /force
```

then check `UpperFilters` under
`HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E96B-E325-11CE-BFC1-08002BE10318}`.

Turn test signing back off when you are done:

```powershell
bcdedit /set {current} testsigning off
```

---

If the keyboard stops working at any point: **[RECOVERY.md](RECOVERY.md)**.
