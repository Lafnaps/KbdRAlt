# kbdralt configurator

A small WPF front end for the driver's rule table. It reads and writes exactly the same
binary value the driver reads — `HKLM\SYSTEM\CurrentControlSet\Services\kbdralt\Parameters\Rules`
— so it is interchangeable with `Set-KbdRAltRules.ps1`. The two are verified to produce
byte-identical output.

![no screenshot yet]()

## What it does

- shows driver health: service state, whether `kbdralt` is actually attached to the
  keyboard class, and **whether it is in the right position** relative to `kbdclass`
- lists the rules currently stored, decoded into readable key names
- edits rules: capture a key by pressing it, pick chord or remap, build the output
  sequence and reorder it
- validates before saving, using the same rules the driver applies
- writes the table, elevating only for that one operation
- resets to the driver's built-in rule

## Build and run

```
dotnet build -c Release
bin\Release\net8.0-windows\KbdRAltConfig.exe
```

Requires the .NET 8 desktop runtime. No NuGet packages: the tool builds offline from a
clean checkout, which matters for something that configures a kernel driver.

A self-contained single file, if you would rather not install a runtime:

```
dotnet publish -c Release -r win-x64 --self-contained true ^
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
```

## Two things worth knowing

**Key capture sits above the driver.** The app records keys with a low-level hook, which
runs higher in the input stack than the filter. If a key is already remapped by an active
rule, capture reports the rule's *output*, not the physical key: with `CapsLock → 0x29`
installed, pressing CapsLock captures `29`. The capture dialog detects this case and says
so. To change an existing rule, edit it rather than re-capturing its input.

**Changes need a reboot.** The driver reads the table once, in `DriverEntry`.
`pnputil /restart-device` restarts the device but leaves the driver loaded with the old
table, so it is not enough.

## Elevation

The app runs unelevated and asks for administrator rights only when writing. That is
deliberate: everything else it does is read-only, and demanding admin at launch to enable
one button is how people learn to click through UAC without reading it.

The write is handed to a short-lived elevated instance of the same executable, which
validates the data again before touching the registry and then exits.

## Licence

AGPL v3, same as the driver. See [../LICENSE](../LICENSE).
