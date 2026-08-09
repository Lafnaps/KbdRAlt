// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Lafnaps

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32;

namespace KbdRAlt.Config;

/// <summary>
/// Minimal service state query straight against the Service Control Manager.
///
/// System.ServiceProcess.ServiceController would need a NuGet package. This tool
/// configures a kernel driver and should build offline from a clean checkout, so a few
/// lines of P/Invoke are preferable to a dependency.
/// </summary>
internal static class ServiceQuery
{
    private const uint SC_MANAGER_CONNECT = 0x0001;
    private const uint SERVICE_QUERY_STATUS = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_STATUS
    {
        public uint dwServiceType, dwCurrentState, dwControlsAccepted,
                    dwWin32ExitCode, dwServiceSpecificExitCode,
                    dwCheckPoint, dwWaitHint;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenSCManagerW(string? machine, string? database, uint access);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenServiceW(IntPtr scm, string name, uint access);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool QueryServiceStatus(IntPtr service, out SERVICE_STATUS status);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool CloseServiceHandle(IntPtr handle);

    /// <summary>Returns null when the service does not exist.</summary>
    public static string? StateOf(string serviceName)
    {
        IntPtr scm = OpenSCManagerW(null, null, SC_MANAGER_CONNECT);
        if (scm == IntPtr.Zero) return null;
        try
        {
            IntPtr svc = OpenServiceW(scm, serviceName, SERVICE_QUERY_STATUS);
            if (svc == IntPtr.Zero) return null;
            try
            {
                if (!QueryServiceStatus(svc, out var st)) return null;
                return st.dwCurrentState switch
                {
                    1 => "Stopped",
                    2 => "StartPending",
                    3 => "StopPending",
                    4 => "Running",
                    5 => "ContinuePending",
                    6 => "PausePending",
                    7 => "Paused",
                    _ => $"state {st.dwCurrentState}",
                };
            }
            finally { CloseServiceHandle(svc); }
        }
        finally { CloseServiceHandle(scm); }
    }
}

/// <summary>Reading and writing the driver's rule value, and reporting driver health.</summary>
public static class SystemState
{
    private const string ParametersKey =
        @"SYSTEM\CurrentControlSet\Services\kbdralt\Parameters";
    private const string ValueName = "Rules";
    private const string KeyboardLayoutKey =
        @"SYSTEM\CurrentControlSet\Control\Keyboard Layout";
    private const string KeyboardClassKey =
        @"SYSTEM\CurrentControlSet\Control\Class\{4D36E96B-E325-11CE-BFC1-08002BE10318}";

    public static bool IsElevated()
    {
        using var id = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }

    // ---------------------------------------------------------------- rules

    public static byte[]? ReadBlob()
    {
        using var key = Registry.LocalMachine.OpenSubKey(ParametersKey);
        return key?.GetValue(ValueName) as byte[];
    }

    public static void WriteBlob(byte[] blob)
    {
        using var key = Registry.LocalMachine.CreateSubKey(ParametersKey, writable: true)
            ?? throw new InvalidOperationException("cannot open the driver's Parameters key");
        key.SetValue(ValueName, blob, RegistryValueKind.Binary);
    }

    public static void DeleteBlob()
    {
        using var key = Registry.LocalMachine.OpenSubKey(ParametersKey, writable: true);
        if (key?.GetValue(ValueName) is not null) key.DeleteValue(ValueName);
    }

    // --------------------------------------------------------------- status

    public sealed record Status(
        bool ServiceInstalled,
        string ServiceState,
        bool FilterRegistered,
        bool FilterOrderCorrect,
        string UpperFilters,
        bool ScancodeMapPresent,
        bool RulesPresent);

    public static Status Query()
    {
        string? svcState = ServiceQuery.StateOf("kbdralt");
        bool installed = svcState is not null;
        string state = svcState ?? "not installed";

        string upper = "";
        bool registered = false, orderOk = false;
        using (var cls = Registry.LocalMachine.OpenSubKey(KeyboardClassKey))
        {
            if (cls?.GetValue("UpperFilters") is string[] filters)
            {
                upper = string.Join(", ", filters);
                int us = Array.FindIndex(filters, f => f.Equals("kbdralt", StringComparison.OrdinalIgnoreCase));
                int cl = Array.FindIndex(filters, f => f.Equals("kbdclass", StringComparison.OrdinalIgnoreCase));
                registered = us >= 0;
                // UpperFilters is ordered bottom-up: we must come BEFORE kbdclass, or the
                // connect IOCTL never reaches us and the driver loads but does nothing.
                orderOk = us >= 0 && (cl < 0 || us < cl);
            }
        }

        bool map;
        using (var kl = Registry.LocalMachine.OpenSubKey(KeyboardLayoutKey))
            map = kl?.GetValue("Scancode Map") is byte[];

        return new Status(installed, state, registered, orderOk, upper, map, ReadBlob() is not null);
    }

    // ------------------------------------------------------------ elevation

    /// <summary>
    /// Relaunches this app elevated, handing over a blob to write via a temp file.
    /// Returns false if the user dismissed the UAC prompt.
    /// </summary>
    public static bool RelaunchElevatedAndApply(byte[]? blob, out string? error)
    {
        error = null;
        try
        {
            string arg;
            if (blob is null)
            {
                arg = "--reset-rules";
            }
            else
            {
                var tmp = Path.Combine(Path.GetTempPath(),
                    $"kbdralt-rules-{Guid.NewGuid():N}.bin");
                File.WriteAllBytes(tmp, blob);
                arg = $"--apply-rules \"{tmp}\"";
            }

            var exe = Environment.ProcessPath
                      ?? throw new InvalidOperationException("cannot determine our own path");

            var psi = new ProcessStartInfo(exe, arg) { UseShellExecute = true, Verb = "runas" };
            var p = Process.Start(psi);
            p?.WaitForExit();
            return p is { ExitCode: 0 };
        }
        catch (System.ComponentModel.Win32Exception)
        {
            error = "The elevation prompt was dismissed, so nothing was written.";
            return false;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }
}
