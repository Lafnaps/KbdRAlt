// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Lafnaps

using System.IO;
using System.Windows;

namespace KbdRAlt.Config;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // Elevated worker modes. The main window relaunches us with one of these when a
        // write needs administrator rights, so the GUI itself never has to run elevated.
        // Both modes write and exit without showing any window.
        if (e.Args.Length >= 1 && e.Args[0] == "--apply-rules" && e.Args.Length >= 2)
        {
            Environment.Exit(ApplyRulesAndExit(e.Args[1]));
            return;
        }
        if (e.Args.Length >= 1 && e.Args[0] == "--reset-rules")
        {
            Environment.Exit(ResetRulesAndExit());
            return;
        }

        base.OnStartup(e);
        new MainWindow().Show();
    }

    private static int ApplyRulesAndExit(string path)
    {
        try
        {
            var blob = File.ReadAllBytes(path);

            // Never write something we cannot read back as valid: a corrupt temp file
            // would otherwise become a rule table the driver silently rejects.
            if (BlobSerializer.TryParse(blob, out var problem) is null)
            {
                MessageBox.Show($"The rule data did not validate and was not written.\n\n{problem}",
                    "kbdralt", MessageBoxButton.OK, MessageBoxImage.Error);
                return 2;
            }

            SystemState.WriteBlob(blob);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Could not write the rules.\n\n{ex.Message}",
                "kbdralt", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }
        finally
        {
            try { File.Delete(path); } catch { /* temp file, best effort */ }
        }
    }

    private static int ResetRulesAndExit()
    {
        try { SystemState.DeleteBlob(); return 0; }
        catch (Exception ex)
        {
            MessageBox.Show($"Could not remove the rules.\n\n{ex.Message}",
                "kbdralt", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }
    }
}
