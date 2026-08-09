/*++
  kbdralt — implementation. See kbdralt.h.
--*/

#include "kbdralt.h"

#ifdef ALLOC_PRAGMA
#pragma alloc_text (INIT, DriverEntry)
#pragma alloc_text (PAGE, KbdRAltEvtDeviceAdd)
#endif

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
{
    WDF_DRIVER_CONFIG config;
    NTSTATUS status;

    WDFDRIVER driver;
    WDF_OBJECT_ATTRIBUTES attr;

    WDF_DRIVER_CONFIG_INIT(&config, KbdRAltEvtDeviceAdd);

    WDF_OBJECT_ATTRIBUTES_INIT(&attr);
    attr.EvtCleanupCallback = KbdRAltEvtDriverCleanup;

    status = WdfDriverCreate(DriverObject,
                             RegistryPath,
                             &attr,
                             &config,
                             &driver);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    // The rule table is read once, before any device exists, so there are no
    // concurrent readers yet. If the registry value is missing or invalid, the
    // built-in right Alt -> Alt+Shift rule is substituted inside.
    KbdRAltLoadRules(driver);

    return STATUS_SUCCESS;
}

NTSTATUS
KbdRAltEvtDeviceAdd(
    _In_ WDFDRIVER Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
    )
{
    WDF_OBJECT_ATTRIBUTES deviceAttributes;
    NTSTATUS status;
    WDFDEVICE hDevice;
    WDF_IO_QUEUE_CONFIG ioQueueConfig;
    PDEVICE_EXTENSION devExt;

    UNREFERENCED_PARAMETER(Driver);
    PAGED_CODE();

    //
    // We are a filter in the kbdclass stack.
    //
    WdfFdoInitSetFilter(DeviceInit);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&deviceAttributes, DEVICE_EXTENSION);

    status = WdfDeviceCreate(&DeviceInit, &deviceAttributes, &hDevice);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    devExt = DeviceGetContext(hDevice);
    devExt->WdfDevice = hDevice;

    //
    // A queue only for IOCTL_INTERNAL_KEYBOARD_CONNECT (and other internal device
    // controls): on CONNECT we substitute the class driver's ServiceCallback.
    //
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&ioQueueConfig, WdfIoQueueDispatchParallel);
    ioQueueConfig.EvtIoInternalDeviceControl = KbdRAltEvtIoInternalDeviceControl;

    status = WdfIoQueueCreate(hDevice,
                              &ioQueueConfig,
                              WDF_NO_OBJECT_ATTRIBUTES,
                              WDF_NO_HANDLE);
    return status;
}

VOID
KbdRAltEvtIoInternalDeviceControl(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength,
    _In_ ULONG IoControlCode
    )
{
    PDEVICE_EXTENSION devExt;
    PCONNECT_DATA connectData = NULL;
    NTSTATUS status = STATUS_SUCCESS;
    size_t length;
    WDFDEVICE hDevice;
    BOOLEAN forwardRequest = FALSE;
    WDF_REQUEST_SEND_OPTIONS options;
    WDFIOTARGET target;

    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    hDevice = WdfIoQueueGetDevice(Queue);
    devExt = DeviceGetContext(hDevice);

    switch (IoControlCode) {

    //
    // The class driver (kbdclass) is attaching our stack as an input source.
    // Intercept its CONNECT_DATA: keep its ClassDeviceObject and ServiceCallback,
    // and substitute our own callback.
    //
    case IOCTL_INTERNAL_KEYBOARD_CONNECT:

        if (devExt->UpperConnectData.ClassService != NULL) {
            status = STATUS_SHARING_VIOLATION;
            break;
        }

        status = WdfRequestRetrieveInputBuffer(Request,
                                               sizeof(CONNECT_DATA),
                                               &connectData,
                                               &length);
        if (!NT_SUCCESS(status)) {
            break;
        }

        devExt->UpperConnectData = *connectData;

        connectData->ClassDeviceObject = WdfDeviceWdmGetDeviceObject(hDevice);
        // ClassService is declared PVOID, so assigning a function pointer directly
        // trips C4152. Cast explicitly through PVOID.
        connectData->ClassService = (PVOID)(ULONG_PTR)KbdRAltServiceCallback;

        forwardRequest = TRUE;
        break;

    //
    // DISCONNECT. The kbfiltr sample returns STATUS_NOT_IMPLEMENTED here and clears
    // nothing, which is a trap: a DISCONNECT followed by a CONNECT makes our CONNECT
    // handler see a non-empty ClassService and answer STATUS_SHARING_VIOLATION. The
    // class driver then fails to attach and the keyboard stays dead until reboot.
    //
    // Clear the state and pass the request down. Racing with in-flight input is safe:
    // ServiceCallback checks ClassService for NULL and simply swallows the packet
    // instead of dereferencing garbage.
    //
    case IOCTL_INTERNAL_KEYBOARD_DISCONNECT:
        RtlZeroMemory(&devExt->UpperConnectData, sizeof(devExt->UpperConnectData));
        RtlZeroMemory(devExt->Held, sizeof(devExt->Held));
        forwardRequest = TRUE;
        break;

    default:
        forwardRequest = TRUE;
        break;
    }

    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(Request, status);
        return;
    }

    if (forwardRequest) {
        WDF_REQUEST_SEND_OPTIONS_INIT(&options, WDF_REQUEST_SEND_OPTION_SEND_AND_FORGET);
        target = WdfDeviceGetIoTarget(hDevice);

        if (!WdfRequestSend(Request, target, &options)) {
            status = WdfRequestGetStatus(Request);
            WdfRequestComplete(Request, status);
        }
        return;
    }

    WdfRequestComplete(Request, status);
}

//
// Helper: fill one KEYBOARD_INPUT_DATA from a template, but with a new scan code,
// extended flag and make/break bit.
//
static VOID
MakeKey(
    _Out_ PKEYBOARD_INPUT_DATA dst,
    _In_ PKEYBOARD_INPUT_DATA templ,
    _In_ USHORT scanCode,
    _In_ BOOLEAN extended,
    _In_ BOOLEAN keyUp
    )
{
    *dst = *templ;
    dst->MakeCode = scanCode;
    // Rebuild the flags from scratch: never carry KEY_E1 over, set KEY_E0 only when
    // the rule says so, and set the break bit according to keyUp.
    dst->Flags = (USHORT)((keyUp ? KEY_BREAK : KEY_MAKE) | (extended ? KEY_E0 : 0));
}

//
// Find the rule for an input event. NULL means there is no rule and the key should
// pass through untouched.
//
static const KBDRALT_RULE *
FindRule(
    _In_ PKBDRALT_RULETABLE table,
    _In_ PKEYBOARD_INPUT_DATA p,
    _Out_ PULONG index
    )
{
    ULONG i;
    USHORT ext = (USHORT)(((p->Flags & KEY_E0) != 0) ? 1 : 0);

    *index = 0;

    if (table == NULL) {
        return NULL;
    }
    for (i = 0; i < table->Count; i++) {
        if (table->Rule[i].InScan == p->MakeCode &&
            table->Rule[i].InExtended == ext) {
            *index = i;
            return &table->Rule[i];
        }
    }
    return NULL;
}

//
// Hand the accumulated events up to kbdclass and reset the counter.
// The cast goes through PVOID because ClassService is declared PVOID and a direct
// cast trips C4152.
//
static VOID
FlushUp(
    _In_ PDEVICE_EXTENSION devExt,
    _In_reads_(*count) PKEYBOARD_INPUT_DATA buf,
    _Inout_ PULONG count
    )
{
    ULONG consumedByUpper = 0;
    PSERVICE_CALLBACK_ROUTINE upperCallback;

    if (*count == 0) {
        return;
    }

    upperCallback =
        (PSERVICE_CALLBACK_ROUTINE)(PVOID)devExt->UpperConnectData.ClassService;

    (*upperCallback)(devExt->UpperConnectData.ClassDeviceObject,
                     buf,
                     buf + *count,
                     &consumedByUpper);
    *count = 0;
}

//
// ServiceCallback — the interception point. Driven by the rule table (g_Rules).
//
// Chord mode (this is how right Alt -> Alt+Shift works):
//   * the make and every auto-repeat are swallowed silently;
//   * on break the ENTIRE sequence is emitted at once: all makes in order, then all
//     breaks in reverse.
// Auto-repeat stops being a problem by construction: however many makes arrive, the
// chord fires exactly once, on release. And nothing stays held down in the system
// between press and release. The trade-off is deliberate: the key stops working as a
// modifier, because it is given over entirely to the chord.
//
// Remap mode is a plain substitution: make -> make, break -> break.
//
// On AltGr — measured on real hardware with altgr-probe.ps1 (Raw Input against
// WH_KEYBOARD_LL, 923 events):
//
//   * a real Ctrl from the keyboard -> sc=0x1D, visible in BOTH Raw Input and the hook;
//   * the AltGr Ctrl                -> sc=0x21D, visible ONLY in the hook; that scan
//                                      code never appears in Raw Input at all.
//
// So there is no separate hardware LCtrl: the keyboard sends a single E0 38 scan code
// and the Ctrl is born higher up, when the scan code is mapped to a virtual key. We
// replace E0 38 before VK_RMENU is ever produced, so the AltGr synthesis never happens
// and there is nothing to suppress. No AltGr-specific code is needed here — and adding
// it would be wrong: swallowing a real Ctrl (sc=0x1D) would break Ctrl+C.
//
#define KBDRALT_MAX_OUT 32

VOID
KbdRAltServiceCallback(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PKEYBOARD_INPUT_DATA InputDataStart,
    _In_ PKEYBOARD_INPUT_DATA InputDataEnd,
    _Inout_ PULONG InputDataConsumed
    )
{
    PDEVICE_EXTENSION devExt;
    WDFDEVICE hDevice;
    KEYBOARD_INPUT_DATA out[KBDRALT_MAX_OUT];
    ULONG outCount = 0;
    PKEYBOARD_INPUT_DATA p;
    PKBDRALT_RULETABLE table;

    hDevice = WdfWdmDeviceGetWdfDeviceHandle(DeviceObject);
    devExt = DeviceGetContext(hDevice);

    //
    // Guard: if CONNECT never completed there is nobody to call upward. Bail out
    // quietly and mark the input consumed, rather than dereferencing NULL.
    //
    if (devExt->UpperConnectData.ClassService == NULL) {
        *InputDataConsumed = (ULONG)(InputDataEnd - InputDataStart);
        return;
    }

    // Read the pointer ONCE for the whole buffer: the table is immutable and updates
    // swap the pointer wholesale, so processing a single buffer always sees one
    // consistent rule set.
    table = g_Rules;

    for (p = InputDataStart; p < InputDataEnd; p++) {

        ULONG ruleIdx = 0;
        const KBDRALT_RULE *rule = FindRule(table, p, &ruleIdx);
        BOOLEAN keyUp;
        ULONG i;

        if (rule == NULL) {
            if (outCount + 1 > KBDRALT_MAX_OUT) {
                FlushUp(devExt, out, &outCount);
            }
            out[outCount++] = *p;
            continue;
        }

        keyUp = (BOOLEAN)((p->Flags & KEY_BREAK) != 0);

        if (rule->Mode == KbdRAltModeRemap) {
            if (outCount + 1 > KBDRALT_MAX_OUT) {
                FlushUp(devExt, out, &outCount);
            }
            MakeKey(&out[outCount++], p,
                    rule->Out[0].Scan,
                    (BOOLEAN)(rule->Out[0].Extended != 0),
                    keyUp);
            continue;
        }

        // --- KbdRAltModeChord ---

        if (!keyUp) {
            devExt->Held[ruleIdx] = TRUE;   // make or auto-repeat — swallow it
            continue;
        }

        if (!devExt->Held[ruleIdx]) {
            continue;                        // a break with no make of ours
        }
        devExt->Held[ruleIdx] = FALSE;

        // The whole sequence at once: makes in order, breaks in reverse.
        if (outCount + rule->OutCount * 2 > KBDRALT_MAX_OUT) {
            FlushUp(devExt, out, &outCount);
        }
        for (i = 0; i < rule->OutCount; i++) {
            MakeKey(&out[outCount++], p, rule->Out[i].Scan,
                    (BOOLEAN)(rule->Out[i].Extended != 0), FALSE);
        }
        for (i = rule->OutCount; i > 0; i--) {
            MakeKey(&out[outCount++], p, rule->Out[i - 1].Scan,
                    (BOOLEAN)(rule->Out[i - 1].Extended != 0), TRUE);
        }
    }

    FlushUp(devExt, out, &outCount);

    *InputDataConsumed = (ULONG)(InputDataEnd - InputDataStart);
}
