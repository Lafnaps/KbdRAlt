// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Lafnaps

/*++
  rules.c — loading and validating the rule table from the registry.

  Everything here runs at PASSIVE_LEVEL during driver start. The data comes from
  outside (the registry), so it is validated pedantically: the size, the count and
  the indices in the blob cannot be trusted.
--*/

#include "kbdralt.h"

#ifdef ALLOC_PRAGMA
// Rules are only loaded at startup, at PASSIVE_LEVEL, so there is no reason to keep
// this code resident. Without this line the analyzer reports C28172.
#pragma alloc_text (PAGE, KbdRAltLoadRules)
#endif

PKBDRALT_RULETABLE g_Rules = NULL;

#define KBDRALT_POOL_TAG 'tlRK'   // 'KRlt'

//
// The built-in rule: right Alt (E0 38) -> LAlt+LShift chord.
// Used when the registry holds nothing or the blob fails validation.
//
static VOID
KbdRAltFillDefault(
    _Out_ PKBDRALT_RULETABLE table
    )
{
    RtlZeroMemory(table, sizeof(*table));
    table->Count = 1;
    table->Rule[0].InScan       = SCAN_ALT;
    table->Rule[0].InExtended   = 1;
    table->Rule[0].Mode         = KbdRAltModeChord;
    table->Rule[0].OutCount     = 2;
    table->Rule[0].Out[0].Scan  = SCAN_ALT;    // LAlt
    table->Rule[0].Out[0].Extended = 0;
    table->Rule[0].Out[1].Scan  = SCAN_SHIFT;  // LShift
    table->Rule[0].Out[1].Extended = 0;
}

//
// Validate a single rule. Returns FALSE if the rule must not be executed.
//
static BOOLEAN
KbdRAltRuleIsSane(
    _In_ const KBDRALT_RULE *r
    )
{
    ULONG i;

    if (r->Mode >= KbdRAltModeMax) {
        return FALSE;
    }
    // The reserved field must be zero. That lets a future version give it meaning
    // (per-device scoping, for instance) and be sure old blobs are not misread.
    if (r->Reserved != 0) {
        return FALSE;
    }
    // The extended flag must be exactly 0 or 1: the comparison in FindRule is exact,
    // so a value of 2 would silently make the rule unreachable.
    if (r->InExtended > 1) {
        return FALSE;
    }
    if (r->OutCount == 0 || r->OutCount > KBDRALT_MAX_OUT_PER_RULE) {
        return FALSE;
    }
    // A key-for-key substitution must produce exactly one key, otherwise it is
    // ambiguous what to emit on make and what on break.
    if (r->Mode == KbdRAltModeRemap && r->OutCount != 1) {
        return FALSE;
    }
    // A set-1 scan code is one byte. Zero is not valid on either side.
    if (r->InScan == 0 || r->InScan > 0xFF) {
        return FALSE;
    }
    for (i = 0; i < r->OutCount; i++) {
        if (r->Out[i].Scan == 0 || r->Out[i].Scan > 0xFF) {
            return FALSE;
        }
        if (r->Out[i].Extended > 1) {
            return FALSE;
        }
    }
    return TRUE;
}

//
// Two rules for the same input key is almost certainly a typo in the configuration.
// The first one would win while the author expected the second, and the cause would
// take a long time to find. Reject the whole table instead.
//
static BOOLEAN
KbdRAltHasDuplicateInputs(
    _In_reads_(count) const KBDRALT_RULE *rules,
    _In_ ULONG count
    )
{
    ULONG i, j;

    for (i = 0; i < count; i++) {
        for (j = i + 1; j < count; j++) {
            if (rules[i].InScan == rules[j].InScan &&
                rules[i].InExtended == rules[j].InExtended) {
                return TRUE;
            }
        }
    }
    return FALSE;
}

//
// Read the blob from Parameters\Rules and turn it into a working table.
// On any failure the built-in rule is kept, so the driver is never left idle.
//
_IRQL_requires_max_(PASSIVE_LEVEL)
VOID
KbdRAltLoadRules(
    _In_ WDFDRIVER Driver
    )
{
    NTSTATUS status;
    WDFKEY key = NULL;
    WDFMEMORY mem = NULL;
    PKBDRALT_RULETABLE table;
    DECLARE_CONST_UNICODE_STRING(valueName, L"Rules");

    PAGED_CODE();

    table = (PKBDRALT_RULETABLE)ExAllocatePool2(POOL_FLAG_NON_PAGED,
                                                sizeof(KBDRALT_RULETABLE),
                                                KBDRALT_POOL_TAG);
    if (table == NULL) {
        return;   // g_Rules keeps its previous value; NULL on first start, see below
    }
    KbdRAltFillDefault(table);

    status = WdfDriverOpenParametersRegistryKey(Driver, KEY_READ,
                                                WDF_NO_OBJECT_ATTRIBUTES, &key);
    if (NT_SUCCESS(status)) {

        WDF_OBJECT_ATTRIBUTES memAttr;
        WDF_OBJECT_ATTRIBUTES_INIT(&memAttr);
        memAttr.ParentObject = key;

        status = WdfRegistryQueryMemory(key, &valueName, NonPagedPoolNx,
                                        &memAttr, &mem, NULL);
        if (NT_SUCCESS(status)) {

            size_t          blobSize = 0;
            PKBDRALT_RULES  blob = (PKBDRALT_RULES)WdfMemoryGetBuffer(mem, &blobSize);

            // The header itself must fit inside the blob.
            if (blob != NULL &&
                blobSize >= FIELD_OFFSET(KBDRALT_RULES, Rule) &&
                blob->Version == KBDRALT_RULES_VERSION &&
                blob->Count > 0 &&
                blob->Count <= KBDRALT_MAX_RULES) {

                size_t need = FIELD_OFFSET(KBDRALT_RULES, Rule) +
                              (size_t)blob->Count * sizeof(KBDRALT_RULE);

                if (blobSize >= need) {

                    ULONG   i;
                    ULONG   good = 0;
                    BOOLEAN allSane = TRUE;

                    for (i = 0; i < blob->Count; i++) {
                        if (!KbdRAltRuleIsSane(&blob->Rule[i])) {
                            allSane = FALSE;
                            break;
                        }
                    }
                    if (allSane &&
                        KbdRAltHasDuplicateInputs(blob->Rule, blob->Count)) {
                        allSane = FALSE;
                    }

                    // Accept the table whole or not at all: a partially applied rule
                    // set is the worst outcome, because the user believes it is
                    // configured while only half of it works.
                    if (allSane) {
                        RtlZeroMemory(table, sizeof(*table));
                        for (i = 0; i < blob->Count; i++) {
                            table->Rule[good++] = blob->Rule[i];
                        }
                        table->Count = good;
                    }
                }
            }
        }

        WdfRegistryClose(key);
    }

    {
        PKBDRALT_RULETABLE old =
            (PKBDRALT_RULETABLE)InterlockedExchangePointer((PVOID volatile *)&g_Rules,
                                                           table);
        if (old != NULL) {
            // Nothing can be reading the old table concurrently at driver start:
            // no devices exist yet and ServiceCallback is not connected.
            ExFreePoolWithTag(old, KBDRALT_POOL_TAG);
        }
    }
}

//
// Released when the driver unloads.
//
VOID
KbdRAltEvtDriverCleanup(
    _In_ WDFOBJECT Driver
    )
{
    PKBDRALT_RULETABLE old;

    UNREFERENCED_PARAMETER(Driver);

    old = (PKBDRALT_RULETABLE)InterlockedExchangePointer((PVOID volatile *)&g_Rules, NULL);
    if (old != NULL) {
        ExFreePoolWithTag(old, KBDRALT_POOL_TAG);
    }
}
