// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Lafnaps

using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace KbdRAlt.Config;

/// <summary>
/// Captures a single physical key press using a low-level keyboard hook.
///
/// WHY A HOOK AND NOT WPF KEY EVENTS: WPF gives virtual keys, already translated
/// through the active layout. The driver works in scan codes. A hook reports the scan
/// code and the extended flag directly, which is exactly what a rule needs, and it also
/// sees keys WPF never delivers — Right Alt, Windows keys and so on.
///
/// IMPORTANT LIMITATION, surfaced in the UI: the hook runs ABOVE the driver in the
/// input stack. If a key is already remapped by an installed rule, capture reports the
/// rule's OUTPUT, not the physical key. Pressing a remapped CapsLock with a
/// CapsLock -> ` rule active yields 0x29, not 0x3A. There is no way around this from
/// user mode; the honest answer is to tell the user, which CaptureWindow does.
/// </summary>
public sealed class KeyCapture : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN     = 0x0100;
    private const int WM_SYSKEYDOWN  = 0x0104;
    private const uint LLKHF_EXTENDED = 0x01;
    private const uint LLKHF_INJECTED = 0x10;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SetWindowsHookExW(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandleW(string? lpModuleName);

    private IntPtr _hook = IntPtr.Zero;
    private readonly HookProc _proc;   // kept alive deliberately: the GC must not collect it

    private const ushort SCAN_ESCAPE = 0x01;

    /// <summary>Raised on the UI thread for each physical key down.</summary>
    public event Action<KeyRef, bool>? Captured;   // key, wasInjected

    /// <summary>Raised on the UI thread when Escape is pressed.</summary>
    public event Action? Cancelled;

    /// <summary>
    /// When true, Escape cancels instead of being captured. The dialog needs a keyboard
    /// way out, because while the hook is installed every keystroke is swallowed
    /// system-wide and the buttons cannot be reached with the keyboard.
    ///
    /// The cost is that Escape cannot be captured as a rule key here; it can still be
    /// entered by hand as scan code 01.
    /// </summary>
    public bool EscapeCancels { get; set; } = true;

    public KeyCapture() => _proc = Callback;

    public bool Start()
    {
        if (_hook != IntPtr.Zero) return true;
        _hook = SetWindowsHookExW(WH_KEYBOARD_LL, _proc, GetModuleHandleW(null), 0);
        return _hook != IntPtr.Zero;
    }

    public void Stop()
    {
        if (_hook == IntPtr.Zero) return;
        UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = (int)wParam;
            if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN)
            {
                var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
                bool extended = (k.flags & LLKHF_EXTENDED) != 0;
                bool injected = (k.flags & LLKHF_INJECTED) != 0;

                // Scan codes are one byte; the hook widens them, and the synthetic AltGr
                // Ctrl arrives as 0x21D. Masking to a byte keeps 0x21D from being stored
                // as an impossible rule the driver would reject.
                ushort scan = (ushort)(k.scanCode & 0xFF);

                if (EscapeCancels && scan == SCAN_ESCAPE && !extended)
                {
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(
                        () => Cancelled?.Invoke());
                    return 1;
                }

                if (scan != 0)
                {
                    var key = new KeyRef(scan, extended);
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(
                        () => Captured?.Invoke(key, injected));

                    // Swallow the key so it does not also reach the application behind the
                    // capture prompt. This is what makes capture usable for keys like Tab
                    // and Space, but it does mean the keyboard is inert everywhere else
                    // while the dialog is open — hence EscapeCancels above, so there is
                    // always a keyboard way out.
                    return 1;
                }
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public void Dispose() => Stop();
}
