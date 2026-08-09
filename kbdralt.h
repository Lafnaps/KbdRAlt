// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Lafnaps

/*++
  kbdralt — KMDF upper-filter driver for the kbdclass stack.

  Rewrites keystrokes according to a rule table before anything above sees them.
  Because the substitution happens below kbdclass, it works everywhere the keyboard
  works: inside RDP sessions, on the secure desktop, and on the logon screen.

  Built on the structure of the Microsoft kbfiltr sample (input/kbfiltr in
  microsoft/Windows-driver-samples).
--*/

#pragma once

#include <ntddk.h>
#include <wdf.h>
#include <kbdmou.h>
#include <ntddkbd.h>

//
// Set-1 scan codes used by the built-in fallback rule.
//
#define SCAN_ALT     0x38   // LAlt; right Alt has the same code but carries KEY_E0
#define SCAN_SHIFT   0x2A   // LShift

// ---------------------------------------------------------------------------
// Rule table
//
// The on-disk format is binary on purpose: parsing text in kernel mode is a classic
// source of bugs. Set-KbdRAltRules.ps1 accepts a readable syntax and produces this
// blob.
//
// Registry: HKLM\SYSTEM\CurrentControlSet\Services\kbdralt\Parameters
//           value "Rules", REG_BINARY = KBDRALT_RULES
//
// The blob is read once, at driver start. If the value is missing or fails
// validation, the built-in rule (right Alt -> Alt+Shift) is used instead, so the
// driver never degrades into doing something unpredictable.
// ---------------------------------------------------------------------------

#define KBDRALT_RULES_VERSION      1
#define KBDRALT_MAX_RULES          64
#define KBDRALT_MAX_OUT_PER_RULE   8

typedef enum _KBDRALT_MODE {
    // Press and every auto-repeat are swallowed; on release the entire output
    // sequence is emitted as one chord: all makes in order, then all breaks in
    // reverse. This is how right Alt -> Alt+Shift works.
    KbdRAltModeChord = 0,

    // Plain key-for-key substitution: make -> make, break -> break. The output
    // sequence must consist of exactly one key. This is how CapsLock -> ` works.
    KbdRAltModeRemap = 1,

    KbdRAltModeMax
} KBDRALT_MODE;

#include <pshpack1.h>

typedef struct _KBDRALT_KEY {
    USHORT Scan;        // set-1 scan code
    USHORT Extended;    // 1 = E0 prefix
} KBDRALT_KEY;

typedef struct _KBDRALT_RULE {
    USHORT      InScan;
    USHORT      InExtended;
    ULONG       Mode;       // KBDRALT_MODE
    ULONG       OutCount;
    ULONG       Reserved;   // must be zero; reserved for per-device scoping
    KBDRALT_KEY Out[KBDRALT_MAX_OUT_PER_RULE];
} KBDRALT_RULE;

typedef struct _KBDRALT_RULES {
    ULONG        Version;
    ULONG        Count;
    KBDRALT_RULE Rule[1];   // Count entries in reality
} KBDRALT_RULES, *PKBDRALT_RULES;

#include <poppack.h>

//
// The parsed table as held in kernel memory. Immutable once built: updates replace
// the whole pointer with InterlockedExchangePointer, because ServiceCallback runs at
// DISPATCH_LEVEL and cannot take locks.
//
typedef struct _KBDRALT_RULETABLE {
    ULONG        Count;
    KBDRALT_RULE Rule[KBDRALT_MAX_RULES];
} KBDRALT_RULETABLE, *PKBDRALT_RULETABLE;

extern PKBDRALT_RULETABLE g_Rules;

// ---------------------------------------------------------------------------
// Filter device context
// ---------------------------------------------------------------------------

typedef struct _DEVICE_EXTENSION {
    WDFDEVICE WdfDevice;

    // The upward connection: kbdclass sits above us. We substitute our own
    // ServiceCallback and keep the original so we can call it after translating.
    CONNECT_DATA UpperConnectData;

    // Per chord-mode rule: is its input key currently held? This is what makes
    // auto-repeat a non-issue — the chord is emitted exactly once, on release.
    // The state is per device, not global.
    BOOLEAN Held[KBDRALT_MAX_RULES];

} DEVICE_EXTENSION, *PDEVICE_EXTENSION;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_EXTENSION, DeviceGetContext)

// ---------------------------------------------------------------------------
// Prototypes
// ---------------------------------------------------------------------------

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD KbdRAltEvtDeviceAdd;
EVT_WDF_OBJECT_CONTEXT_CLEANUP KbdRAltEvtDriverCleanup;
EVT_WDF_IO_QUEUE_IO_INTERNAL_DEVICE_CONTROL KbdRAltEvtIoInternalDeviceControl;

VOID
KbdRAltServiceCallback(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PKEYBOARD_INPUT_DATA InputDataStart,
    _In_ PKEYBOARD_INPUT_DATA InputDataEnd,
    _Inout_ PULONG InputDataConsumed
    );

_IRQL_requires_max_(PASSIVE_LEVEL)
VOID
KbdRAltLoadRules(
    _In_ WDFDRIVER Driver
    );
