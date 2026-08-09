// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Lafnaps

using System.Windows;

namespace KbdRAlt.Config;

public partial class CaptureWindow : Window
{
    private readonly KeyCapture _capture = new();
    private readonly HashSet<(ushort, bool)> _knownOutputs;

    public KeyRef? Result_Key { get; private set; }

    /// <param name="knownOutputs">
    /// Outputs of rules already in the table. If the captured key is one of them, the
    /// user is almost certainly seeing the effect of an existing rule rather than the
    /// physical key, because the hook sits above the driver.
    /// </param>
    public CaptureWindow(IEnumerable<(ushort, bool)>? knownOutputs = null)
    {
        InitializeComponent();
        // null means "do not show the already-remapped warning at all" — used when
        // capturing an OUTPUT key, where that advice would be wrong.
        _knownOutputs = knownOutputs is null ? new() : new HashSet<(ushort, bool)>(knownOutputs);

        _capture.Captured += OnCaptured;
        _capture.Cancelled += () => { if (IsLoaded) Cancel_Click(this, new RoutedEventArgs()); };

        Loaded += (_, _) =>
        {
            if (!_capture.Start())
            {
                Result.Text = "could not install the keyboard hook";
                Result.Foreground = System.Windows.Media.Brushes.Firebrick;
            }
        };
        Closed += (_, _) => _capture.Dispose();
    }

    private void OnCaptured(KeyRef key, bool injected)
    {
        Result_Key = key;
        Result.Text = key.Display;
        OkButton.IsEnabled = true;
        RemapWarning.Visibility  = _knownOutputs.Contains((key.Scan, key.Extended))
            ? Visibility.Visible : Visibility.Collapsed;
        InjectedWarning.Visibility = injected ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        // Stop the hook before closing so the click that dismisses the dialog is not
        // swallowed by our own capture.
        _capture.Stop();
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        _capture.Stop();
        Result_Key = null;
        DialogResult = false;
    }
}
