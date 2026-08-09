<#
    altgr-probe.ps1 — find out WHERE the Ctrl that accompanies right Alt comes from.

    Listens to two independent sources and writes both to one log:
      RAW  — Raw Input (WM_INPUT): device events, BEFORE win32k maps scan codes to
             virtual keys;
      HOOK — WH_KEYBOARD_LL: the same event AFTER that processing, where the synthetic
             AltGr Ctrl becomes visible.

    Reading the result:
      * LCtrl (sc=0x1D) in BOTH RAW and HOOK -> it comes from the hardware or the port
        driver, and a filter driver has to deal with it;
      * LCtrl only in HOOK                   -> win32k synthesises it from VK_RMENU, so
        at driver level it does not exist and there is nothing to suppress.

    Installs nothing, changes nothing, needs no administrator rights.
    While running it logs the scan codes of EVERY key pressed — do not type anything
    sensitive during the probe.

    Implemented on plain Win32: its own hidden window and message loop. WinForms is
    deliberately avoided — Add-Type on it fails under PowerShell 7 (CS0012,
    System.ComponentModel.Primitives).
#>
param(
    [string]$LogPath = "$env:TEMP\altgr-probe.log",
    [int]$Seconds = 30
)

$cs = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class AltGrProbe
{
    delegate IntPtr WndProcDel(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    delegate IntPtr HookProcDel(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX {
        public uint cbSize, style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }

    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUTDEVICE { public ushort UsagePage, Usage; public uint Flags; public IntPtr Target; }

    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUTHEADER { public uint Type, Size; public IntPtr Device, wParam; }

    [StructLayout(LayoutKind.Sequential)]
    struct RAWKEYBOARD { public ushort MakeCode, Flags, Reserved, VKey; public uint Message, ExtraInformation; }

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extra; }

    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern ushort RegisterClassExW(ref WNDCLASSEX c);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool PeekMessageW(out MSG m, IntPtr h, uint a, uint b, uint r);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll", SetLastError=true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint n, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint hsize);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SetWindowsHookExW(int id, HookProcDel fn, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string n);

    const uint WM_INPUT = 0x00FF;
    const uint RID_INPUT = 0x10000003;
    const uint RIDEV_INPUTSINK = 0x00000100;
    const int  WH_KEYBOARD_LL = 13;

    static StreamWriter _log;
    static WndProcDel  _wndProc;   // keep the delegates alive, or the GC collects them
    static HookProcDel _hookProc;
    static IntPtr _hook;

    static void Log(string s) { _log.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff") + "  " + s); }

    static string Name(uint vk) {
        switch (vk) {
            case 0xA2: return " (LCtrl)";
            case 0xA3: return " (RCtrl)";
            case 0xA4: return " (LAlt)";
            case 0xA5: return " (RAlt)";
            case 0xA0: return " (LShift)";
            case 0xA1: return " (RShift)";
            case 0x11: return " (Ctrl)";
            case 0x12: return " (Alt)";
            case 0x10: return " (Shift)";
            default:   return "";
        }
    }

    static IntPtr WindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam) {
        if (msg == WM_INPUT) HandleRaw(lParam);
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    static void HandleRaw(IntPtr hRawInput) {
        uint size = 0;
        uint hdrSize = (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER));
        GetRawInputData(hRawInput, RID_INPUT, IntPtr.Zero, ref size, hdrSize);
        if (size == 0) return;
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            if (GetRawInputData(hRawInput, RID_INPUT, buf, ref size, hdrSize) != size) return;
            RAWINPUTHEADER hdr = (RAWINPUTHEADER)Marshal.PtrToStructure(buf, typeof(RAWINPUTHEADER));
            if (hdr.Type != 1) return;   // RIM_TYPEKEYBOARD
            IntPtr kp = (IntPtr)(buf.ToInt64() + hdrSize);
            RAWKEYBOARD kb = (RAWKEYBOARD)Marshal.PtrToStructure(kp, typeof(RAWKEYBOARD));
            bool up = (kb.Flags & 0x01) != 0;
            bool e0 = (kb.Flags & 0x02) != 0;
            Log(string.Format("RAW   vk=0x{0:X2}{1,-9} sc=0x{2:X2} {3}{4}",
                kb.VKey, Name(kb.VKey), kb.MakeCode, up ? "UP  " : "DOWN", e0 ? "  E0" : ""));
        } finally { Marshal.FreeHGlobal(buf); }
    }

    static IntPtr HookCallback(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0) {
            KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            bool up  = (k.flags & 0x80) != 0;
            bool ext = (k.flags & 0x01) != 0;
            bool inj = (k.flags & 0x10) != 0;
            Log(string.Format("HOOK  vk=0x{0:X2}{1,-9} sc=0x{2:X2} {3}{4}{5}",
                k.vkCode, Name(k.vkCode), k.scanCode, up ? "UP  " : "DOWN",
                ext ? "  E0" : "", inj ? "  INJECTED" : ""));
        }
        return CallNextHookEx(_hook, code, wParam, lParam);
    }

    public static void Run(string logPath, int seconds) {
        _log = new StreamWriter(logPath, false);
        _log.AutoFlush = true;
        IntPtr hwnd = IntPtr.Zero;
        try {
            IntPtr hInst = GetModuleHandleW(null);
            _wndProc = WindowProc;

            WNDCLASSEX wc = new WNDCLASSEX();
            wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
            wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc);
            wc.hInstance = hInst;
            wc.lpszClassName = "KbdRAltProbeWnd";
            if (RegisterClassExW(ref wc) == 0)
                Log("!! RegisterClassEx: " + Marshal.GetLastWin32Error());

            hwnd = CreateWindowExW(0, "KbdRAltProbeWnd", "probe", 0, 0, 0, 0, 0,
                                   IntPtr.Zero, IntPtr.Zero, hInst, IntPtr.Zero);
            if (hwnd == IntPtr.Zero) { Log("!! CreateWindowEx: " + Marshal.GetLastWin32Error()); return; }

            RAWINPUTDEVICE[] rid = new RAWINPUTDEVICE[1];
            rid[0].UsagePage = 0x01;            // Generic Desktop
            rid[0].Usage     = 0x06;            // Keyboard
            rid[0].Flags     = RIDEV_INPUTSINK; // receive even without focus
            rid[0].Target    = hwnd;
            if (!RegisterRawInputDevices(rid, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE))))
                Log("!! RegisterRawInputDevices: " + Marshal.GetLastWin32Error());
            else Log("raw input: subscribed");

            _hookProc = HookCallback;
            _hook = SetWindowsHookExW(WH_KEYBOARD_LL, _hookProc, hInst, 0);
            if (_hook == IntPtr.Zero) Log("!! SetWindowsHookEx: " + Marshal.GetLastWin32Error());
            else Log("ll hook: installed");

            Log("=== PRESS RIGHT ALT (" + seconds + "s) ===");

            DateTime end = DateTime.Now.AddSeconds(seconds);
            MSG msg;
            while (DateTime.Now < end) {
                while (PeekMessageW(out msg, IntPtr.Zero, 0, 0, 1)) {
                    TranslateMessage(ref msg);
                    DispatchMessageW(ref msg);
                }
                Thread.Sleep(5);
            }
            Log("=== done ===");
        } finally {
            if (_hook != IntPtr.Zero) UnhookWindowsHookEx(_hook);
            if (hwnd != IntPtr.Zero) DestroyWindow(hwnd);
            _log.Flush();
            _log.Close();
        }
    }
}
'@

Add-Type -TypeDefinition $cs -Language CSharp

if (Test-Path $LogPath) { Remove-Item -LiteralPath $LogPath -Force }

Write-Host "Probing for $Seconds seconds. PRESS RIGHT ALT a few times — short taps and held presses."
Write-Host "Log: $LogPath"

[AltGrProbe]::Run($LogPath, $Seconds)

Write-Host "--- done, log contents ---"
Get-Content $LogPath
