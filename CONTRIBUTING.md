# Contributing

## Where things go

- **A reproducible defect** → [an issue](https://github.com/Lafnaps/KbdRAlt/issues/new/choose).
  The form asks for two things up front; please do not skip them. The device stack output
  distinguishes "the driver is not working" from "the driver is not attached", which look
  identical from outside, and the version has to come from the service's `ImagePath` because
  the binary is not in `System32\drivers`.
- **A question** → [Discussions → Q&A](https://github.com/Lafnaps/KbdRAlt/discussions/categories/q-a).
- **An opinion about the design** → [Discussions → Ideas](https://github.com/Lafnaps/KbdRAlt/discussions/categories/ideas).
- **A dead keyboard** → [RECOVERY.md](RECOVERY.md), before anything else.

## What would actually help right now

This is pre-signature. The driver is unsigned, cannot be loaded without a WDK and a machine
in test signing mode, and an attestation-signed build needs an EV certificate that has not
been bought. So the most valuable feedback is not a bug report — it is:

1. **Is the shape right?** kbdralt is a rule table applied in the kernel with no user-mode
   API at all. Nothing can be scripted on top of it. That is deliberate, but it is also the
   decision most likely to be wrong.
2. **Would you use it once it is attestation-signed, or is something missing that would stop
   you?** The certificate is the expensive irreversible step and I would rather learn this
   before paying for it than after.
3. **Review of the driver itself.** It is about 600 lines of C across `kbdralt.c` and
   `rules.c`, plus an INF that sets the keyboard class `UpperFilters` wholesale. Kernel code
   that gets keyboards wrong leaves people unable to type their password, so I would rather
   be told bluntly.

## Out of scope, and not by accident

Tap-hold, layers, macros and per-application profiles are not planned. Per-application rules
are impossible in a driver at all — the kernel does not know which window has focus. If you
want those, you want a user-mode remapper, and this is not trying to replace one.

Nothing here exposes a user-mode API, so it cannot back kanata, AutoHotInterception, or
anything else built on Interception's API surface.

## If you send code

- **Scripts must be UTF-8 with a byte-order mark.** Windows PowerShell 5.1 reads a BOM-less
  file as ANSI, and a single em dash in a comment is then enough to stop it parsing. This
  project has been caught by it three times; `New-Release.ps1` now refuses to build if any
  `.ps1` lacks a BOM or fails to parse under a real `powershell.exe` 5.1.
- Everything published is in English — documentation, code comments, script output.
- Driver changes need a Driver Verifier run with standard flags plus WDF before they are
  worth reviewing. `BUILDING.md` covers the toolchain; the test matrix is in the README.
- By contributing you agree your changes ship under AGPL-3.0-or-later, like the rest.

## A warning about the one trap that wastes the most time

In the keyboard class `UpperFilters` value, drivers are listed bottom-up: the first entry
sits closest to the port driver. `kbdralt` must come **before** `kbdclass`. Append it instead
and the driver loads, the service reports `Running`, and it does absolutely nothing, because
`IOCTL_INTERNAL_KEYBOARD_CONNECT` travels downward from `kbdclass` and never reaches it.

Service state proves nothing here. Check the stack.
