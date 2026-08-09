# If your keyboard stops working

Read this before installing, not after. Print it, or open it on your phone — a machine
with no keyboard is a bad place to be looking things up.

## First, the thing that will not help

**Plugging in a different keyboard changes nothing.** kbdralt is a *class* filter: it
attaches to every keyboard device in the machine, including one you plug in afterwards,
including a Bluetooth keyboard, including the virtual keyboard of a BMC or an RDP session.
This is the instinctive first move and it is a dead end.

## The mouse still works. Use it.

### 1. On-Screen Keyboard

At the logon screen: the **accessibility button**, bottom right → **On-Screen Keyboard**.
Inside a session: Win+U, or run `osk.exe`.

OSK synthesises keystrokes above the driver stack, so it works even when the physical
keyboard path is broken. Use it to type your password and then to run the commands below.

### 2. Boot once without driver signature enforcement

If the machine boots but the keyboard is dead because the driver failed code integrity —
or if it loaded and is misbehaving — this gets you a normal session in one reboot:

Hold **Shift** while clicking Restart (or use the power menu on the logon screen with the
mouse) → **Troubleshoot** → **Advanced options** → **Startup Settings** → **Restart** →
choose **7** (*Disable driver signature enforcement*).

This lasts exactly one boot, and it is unavailable while Secure Boot is on. It is not a
fix; it is a working session in which you can uninstall.

### 3. Uninstall

From an elevated PowerShell (start it with the mouse; type with OSK):

```powershell
pnputil /enum-drivers
```

Find the entry whose **Original Name** is `kbdralt.inf` and note its published name
(`oemNN.inf`), then:

```powershell
pnputil /delete-driver oemNN.inf /uninstall /force
```

Then put the keyboard class filters back:

```powershell
$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E96B-E325-11CE-BFC1-08002BE10318}'
(Get-ItemProperty $k).UpperFilters
```

If `kbdralt` is still listed, restore the value `deploy.ps1` saved before it changed
anything — `%ProgramData%\kbdralt-upperfilters-backup-<timestamp>.txt`:

```powershell
Set-ItemProperty $k -Name UpperFilters -Value (Get-Content "$env:ProgramData\kbdralt-upperfilters-backup-<timestamp>.txt")
```

If that file is gone, `kbdclass` alone is the correct value for any machine this driver
would have installed on — `deploy.ps1` refuses to install when any third-party keyboard
filter is present, so there was nothing else to preserve.

Reboot.

## If the machine will not boot far enough for any of that

Use Windows Recovery Environment. Its keyboard works: WinRE runs from its own boot image,
whose registry knows nothing about kbdralt.

Boot to WinRE (interrupt startup twice with the power button, or use installation media) →
**Troubleshoot** → **Advanced options** → **Command Prompt**.

On a BitLocker-encrypted machine you will be asked for the 48-digit recovery key here.
This is the moment the warning in [INSTALL.md](INSTALL.md) was about.

Load the installed system's registry and remove the filter:

```
reg load HKLM\OFF C:\Windows\System32\config\SYSTEM
reg query HKLM\OFF\Select /v Current
```

That prints the active control set as a number — `0x1` means `ControlSet001`. Use it
below; do not assume 001.

```
reg add "HKLM\OFF\ControlSet001\Control\Class\{4D36E96B-E325-11CE-BFC1-08002BE10318}" /v UpperFilters /t REG_MULTI_SZ /d "kbdclass" /f
reg unload HKLM\OFF
```

Reboot. The driver's service can stay — with the filter removed from the class it is never
attached to anything. Clean it up later from a working session.

`C:` in WinRE is not always the Windows volume. Check with `dir C:\Windows` first, and try
`D:` if it is not there.

## Safe Mode

Do not count on it. The Keyboard device class is listed under
`HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal`, which means Safe Mode may well
load this filter along with the rest of the keyboard stack — the option that looks like the
obvious escape hatch may reproduce the exact problem you are escaping. Use On-Screen
Keyboard, option 7, or WinRE, all of which are known to work.

## Prevention, for next time

Snapshot the VM before installing. On real hardware, create a restore point:

```powershell
Checkpoint-Computer -Description "before kbdralt"
```

and verify with `deploy.ps1 -WhatIfOnly` first — it checks everything and installs nothing.
