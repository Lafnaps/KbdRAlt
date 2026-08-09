// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Lafnaps

using System.Collections.ObjectModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace KbdRAlt.Config;

public partial class MainWindow : Window
{
    private readonly ObservableCollection<Rule> _rules = new();
    private bool _dirty;
    private bool _suppressEditorEvents;

    /// <summary>
    /// Outputs of the rules actually stored in the registry — i.e. the ones that can be
    /// affecting key capture right now. Deliberately NOT the edit buffer: rules the user
    /// has only just typed in are not installed and cannot be remapping anything yet.
    /// </summary>
    private HashSet<(ushort, bool)> _storedOutputs = new();

    public MainWindow()
    {
        InitializeComponent();
        RuleList.ItemsSource = _rules;
        RefreshStatus();
        LoadFromRegistry(quiet: true);
    }

    private bool Dirty
    {
        get => _dirty;
        set { _dirty = value; DirtyMark.Visibility = value ? Visibility.Visible : Visibility.Collapsed; }
    }

    private Rule? Selected => RuleList.SelectedItem as Rule;

    /// <summary>Snapshot what is now on disk, for the capture warning's basis.</summary>
    private void RememberAsStored()
        => _storedOutputs = new HashSet<(ushort, bool)>(
               _rules.SelectMany(r => r.Output).Select(o => (o.Scan, o.Extended)));

    // ------------------------------------------------------------- status

    private void RefreshStatus()
    {
        var s = SystemState.Query();
        var lines = new List<string>();
        var problems = new List<string>();

        lines.Add(s.ServiceInstalled
            ? $"Service: {s.ServiceState}"
            : "Service: not installed");

        lines.Add($"UpperFilters: {(string.IsNullOrEmpty(s.UpperFilters) ? "(empty)" : s.UpperFilters)}");

        if (!s.ServiceInstalled)
            problems.Add("The driver is not installed. You can still prepare a rule table here, "
                       + "but nothing will use it until the driver is installed with deploy.ps1.");
        else if (!s.FilterRegistered)
            problems.Add("The driver service exists but kbdralt is not in the keyboard class "
                       + "UpperFilters, so it is not attached to any keyboard.");
        else if (!s.FilterOrderCorrect)
            problems.Add("kbdralt is listed AFTER kbdclass in UpperFilters. In that position the "
                       + "driver loads and reports Running but never receives the connect request, "
                       + "so it does nothing. The correct order is kbdralt, then kbdclass.");

        if (s.ScancodeMapPresent)
            problems.Add("A Scancode Map is present in the registry. The driver runs before it, so "
                       + "rules here win, but having the same setting in two places is confusing. "
                       + "deploy.ps1 -RemoveScancodeMap clears it.");

        StatusText.Text = string.Join("    ·    ", lines);

        if (problems.Count > 0)
        {
            StatusHint.Text = string.Join("\n\n", problems);
            StatusHint.Visibility = Visibility.Visible;
            StatusBox.Background = new SolidColorBrush(Color.FromRgb(0xFF, 0xF4, 0xCE));
            StatusBox.BorderBrush = new SolidColorBrush(Color.FromRgb(0xE8, 0xC3, 0x6A));
        }
        else
        {
            StatusHint.Visibility = Visibility.Collapsed;
            StatusBox.Background = new SolidColorBrush(Color.FromRgb(0xF7, 0xF7, 0xF7));
            StatusBox.BorderBrush = new SolidColorBrush(Color.FromRgb(0xDD, 0xDD, 0xDD));
        }
    }

    // ------------------------------------------------------- load and save

    private void LoadFromRegistry(bool quiet)
    {
        var blob = SystemState.ReadBlob();
        _rules.Clear();

        if (blob is null)
        {
            if (!quiet)
                MessageBox.Show(this,
                    "No rule table is stored. The driver is using its built-in rule "
                    + "(Right Alt → Alt+Shift).",
                    "kbdralt", MessageBoxButton.OK, MessageBoxImage.Information);
            Dirty = false;
            return;
        }

        var parsed = BlobSerializer.TryParse(blob, out var problem);
        if (parsed is null)
        {
            MessageBox.Show(this,
                "The stored rule table is not one the driver will accept, so the driver is "
                + "ignoring it and running its built-in rule (Right Alt → Alt+Shift) instead."
                + $"\n\n{problem}\n\n"
                + "Build a new table here and save it to replace the stored one.",
                "kbdralt", MessageBoxButton.OK, MessageBoxImage.Warning);
            Dirty = false;
            return;
        }

        foreach (var r in parsed) _rules.Add(r);
        RememberAsStored();
        Dirty = false;
        if (_rules.Count > 0) RuleList.SelectedIndex = 0;

        // Belt and braces: TryParse now mirrors the driver's checks, but the validator is
        // the authority on what Save would accept. If the two ever drift apart, say so
        // rather than presenting a table the driver is quietly discarding as the live one.
        var errors = RuleValidator.Validate(_rules);
        if (errors.Count > 0)
        {
            MessageBox.Show(this,
                "The stored table has problems that make the driver reject it wholesale, so "
                + "the driver is running its built-in rule instead:\n\n • "
                + string.Join("\n • ", errors)
                + "\n\nFix them here and save to replace the stored table.",
                "kbdralt", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        CommitEditor();

        var errors = RuleValidator.Validate(_rules);
        if (errors.Count > 0)
        {
            MessageBox.Show(this,
                "These problems would make the driver reject the whole table:\n\n • "
                + string.Join("\n • ", errors),
                "kbdralt", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        byte[] blob;
        try { blob = BlobSerializer.Serialize(_rules); }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "kbdralt", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        if (!TryWrite(blob)) return;

        Dirty = false;
        RefreshStatus();
        MessageBox.Show(this,
            $"Saved {_rules.Count} rule(s), {blob.Length} bytes.\n\n"
            + "A REBOOT is required. The driver reads the table once, in DriverEntry — "
            + "restarting the device is not enough.",
            "kbdralt", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this,
                "Remove the stored rule table?\n\nThe driver will fall back to its built-in "
                + "rule: Right Alt → Alt+Shift. A reboot is required.",
                "kbdralt", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;

        if (!TryWrite(null)) return;

        _rules.Clear();
        Dirty = false;
        RefreshStatus();
    }

    /// <summary>Writes directly when elevated, otherwise via an elevated relaunch.</summary>
    private bool TryWrite(byte[]? blob)
    {
        try
        {
            if (SystemState.IsElevated())
            {
                if (blob is null) SystemState.DeleteBlob(); else SystemState.WriteBlob(blob);
                return true;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "kbdralt", MessageBoxButton.OK, MessageBoxImage.Error);
            return false;
        }

        if (!SystemState.RelaunchElevatedAndApply(blob, out var error))
        {
            MessageBox.Show(this,
                error ?? "The change was not applied.",
                "kbdralt", MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }
        return true;
    }

    private void Reload_Click(object sender, RoutedEventArgs e)
    {
        if (Dirty && MessageBox.Show(this,
                "Discard unsaved changes and reload from the registry?",
                "kbdralt", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;

        RefreshStatus();
        LoadFromRegistry(quiet: false);
    }

    private void Defaults_Click(object sender, RoutedEventArgs e)
    {
        if (Dirty && MessageBox.Show(this,
                "Replace the current list with the default rules?",
                "kbdralt", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;

        _rules.Clear();

        var chord = new Rule { Input = new KeyRef(0x38, true), Mode = RuleMode.Chord };
        chord.Output.Add(new KeyRef(0x38, false));   // LAlt
        chord.Output.Add(new KeyRef(0x2A, false));   // LShift
        _rules.Add(chord);

        var remap = new Rule { Input = new KeyRef(0x3A, false), Mode = RuleMode.Remap };
        remap.Output.Add(new KeyRef(0x29, false));   // key left of 1
        _rules.Add(remap);

        Dirty = true;
        RuleList.SelectedIndex = 0;
    }

    // -------------------------------------------------------------- rules

    private void AddRule_Click(object sender, RoutedEventArgs e)
    {
        CommitEditor();

        // Ask for the key FIRST. Adding a placeholder rule and then opening the dialog
        // would leave an unusable "00 → chord : (empty)" row behind if the user cancels,
        // along with a dirty marker for a change they explicitly declined.
        var key = CaptureKey(isInputKey: true);
        if (key is null) return;

        var r = new Rule { Input = key, Mode = RuleMode.Chord };
        _rules.Add(r);
        Dirty = true;
        RuleList.SelectedItem = r;
    }

    private void RemoveRule_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } r) return;
        _rules.Remove(r);
        Dirty = true;
    }

    private void RuleList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Commit edits from the rule we are leaving, not the one we arrived at.
        if (e.RemovedItems.Count > 0 && e.RemovedItems[0] is Rule prev) CommitEditor(prev);
        BindEditor(Selected);
    }

    private void BindEditor(Rule? r)
    {
        _suppressEditorEvents = true;
        try
        {
            Editor.IsEnabled = r is not null;
            if (r is null)
            {
                InputBox.Text = "";
                InputName.Text = "";
                OutputList.ItemsSource = null;
                return;
            }

            ClearInputError();
            InputBox.Text = r.Input.Code;
            InputName.Text = ScanCodes.NameOf(r.Input.Scan, r.Input.Extended) ?? "unnamed key";
            ModeBox.SelectedIndex = (int)r.Mode;
            UpdateModeHint(r.Mode);
            OutputList.ItemsSource = r.Output;
        }
        finally { _suppressEditorEvents = false; }
    }

    private void UpdateModeHint(RuleMode mode)
        => ModeHint.Text = mode == RuleMode.Chord
            ? "The press and any auto-repeat are swallowed; the whole sequence is emitted once, on release."
            : "One key replaces another, press for press. Exactly one output key.";

    private void CommitEditor(Rule? target = null)
    {
        target ??= Selected;
        if (target is null || _suppressEditorEvents) return;
        ApplyInputText(target);
    }

    private void ApplyInputText(Rule r)
    {
        var parsed = ParseCode(InputBox.Text);
        if (parsed is null) return;
        if (r.Input.Scan != parsed.Scan || r.Input.Extended != parsed.Extended)
        {
            r.Input = parsed;
            r.RaiseSummary();
            Dirty = true;
        }
    }

    private void InputBox_LostFocus(object sender, RoutedEventArgs e)
    {
        if (_suppressEditorEvents || Selected is not { } r) return;

        var parsed = ParseCode(InputBox.Text);
        if (parsed is null)
        {
            // Report inline, never with a MessageBox.
            //
            // A modal dialog opened from LostFocus is entered during the mouse-DOWN of
            // whatever button the user clicked, so it eats the matching mouse-up: the
            // click never reaches Save, and the button can stay visually latched. The
            // user sees no confirmation and no error about what they actually clicked.
            ShowInputError($"“{InputBox.Text}” is not a scan code. Use hex, "
                           + "optionally with an E0: prefix — for example 3A or E0:38.");
            return;
        }

        ClearInputError();
        ApplyInputText(r);
        BindEditor(r);
    }

    private void ShowInputError(string message)
    {
        InputName.Text = message;
        InputName.Foreground = Brushes.Firebrick;
        InputBox.BorderBrush = Brushes.Firebrick;
        InputBox.BorderThickness = new Thickness(1.6);
    }

    private void ClearInputError()
    {
        InputName.Foreground = new SolidColorBrush(Color.FromRgb(0x66, 0x66, 0x66));
        InputBox.ClearValue(BorderBrushProperty);
        InputBox.ClearValue(Control.BorderThicknessProperty);
    }

    private void ModeBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressEditorEvents || Selected is not { } r) return;
        var mode = (RuleMode)Math.Max(0, ModeBox.SelectedIndex);
        if (r.Mode == mode) return;
        r.Mode = mode;
        UpdateModeHint(mode);
        Dirty = true;
    }

    // ------------------------------------------------------------ outputs

    private void AddOutput_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } r) return;
        if (r.Output.Count >= Limits.MaxOutPerRule)
        {
            MessageBox.Show(this, $"A rule can emit at most {Limits.MaxOutPerRule} keys.",
                "kbdralt", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        var key = CaptureKey(isInputKey: false);
        if (key is null) return;
        r.Output.Add(key);
        r.RaiseSummary();
        Dirty = true;
    }

    private void RemoveOutput_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } r || OutputList.SelectedItem is not KeyRef k) return;
        r.Output.Remove(k);
        r.RaiseSummary();
        Dirty = true;
    }

    private void MoveOutputUp_Click(object sender, RoutedEventArgs e) => MoveOutput(-1);
    private void MoveOutputDown_Click(object sender, RoutedEventArgs e) => MoveOutput(+1);

    private void MoveOutput(int delta)
    {
        if (Selected is not { } r || OutputList.SelectedItem is not KeyRef k) return;
        int i = r.Output.IndexOf(k), j = i + delta;
        if (i < 0 || j < 0 || j >= r.Output.Count) return;
        r.Output.Move(i, j);
        OutputList.SelectedIndex = j;
        r.RaiseSummary();
        Dirty = true;
    }

    // ------------------------------------------------------------ capture

    private void CaptureInput_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } r) return;
        var key = CaptureKey(isInputKey: true);
        if (key is null) return;
        r.Input = key;
        r.RaiseSummary();
        Dirty = true;
        BindEditor(r);
    }

    /// <summary>
    /// Shows the capture dialog. Returns null if the user cancelled.
    /// </summary>
    /// <param name="isInputKey">
    /// True when choosing a rule's INPUT. The "this key is already remapped" warning only
    /// makes sense there. When picking an OUTPUT the user is deliberately naming a key to
    /// emit, and telling them to "edit the existing rule instead" would be wrong advice.
    /// </param>
    private KeyRef? CaptureKey(bool isInputKey)
    {
        // Only rules actually stored in the registry can be remapping the keyboard right
        // now, so only those form a basis for the warning. Using the edit buffer would
        // accuse unsaved rules of interfering when they are not installed at all.
        var basis = isInputKey ? _storedOutputs : null;

        var dlg = new CaptureWindow(basis) { Owner = this };
        return dlg.ShowDialog() == true ? dlg.Result_Key : null;
    }

    // ------------------------------------------------------------- helpers

    /// <summary>Parses "3A" or "E0:38". Returns null when the text is not a valid code.</summary>
    private static KeyRef? ParseCode(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var t = text.Trim();
        bool ext = false;

        if (t.StartsWith("E0:", StringComparison.OrdinalIgnoreCase))
        {
            ext = true;
            t = t[3..].Trim();
        }

        if (!ushort.TryParse(t, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var scan))
            return null;
        if (scan == 0 || scan > 0xFF) return null;

        return new KeyRef(scan, ext);
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (Dirty &&
            MessageBox.Show(this, "There are unsaved changes. Close anyway?",
                "kbdralt", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
        {
            e.Cancel = true;
        }
        base.OnClosing(e);
    }
}
