// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Lafnaps

using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace KbdRAlt.Config;

/// <summary>Rule limits. These MUST match kbdralt.h — the driver enforces them too.</summary>
public static class Limits
{
    public const uint BlobVersion   = 1;
    public const int  MaxRules      = 64;
    public const int  MaxOutPerRule = 8;

    /// <summary>Size of one serialised KBDRALT_RULE (pshpack1).</summary>
    public const int RuleSize   = 2 + 2 + 4 + 4 + 4 + MaxOutPerRule * 4;   // 48
    public const int HeaderSize = 4 + 4;                                    // 8
}

public enum RuleMode
{
    /// <summary>Swallow press and auto-repeat; emit the whole sequence on release.</summary>
    Chord = 0,
    /// <summary>Plain key-for-key substitution.</summary>
    Remap = 1,
}

/// <summary>One key: a set-1 scan code plus the E0 (extended) flag.</summary>
public sealed class KeyRef : INotifyPropertyChanged
{
    private ushort _scan;
    private bool _extended;

    public KeyRef() { }
    public KeyRef(ushort scan, bool extended) { _scan = scan; _extended = extended; }

    public ushort Scan
    {
        get => _scan;
        set { if (_scan != value) { _scan = value; Raise(); Raise(nameof(Display)); } }
    }

    public bool Extended
    {
        get => _extended;
        set { if (_extended != value) { _extended = value; Raise(); Raise(nameof(Display)); } }
    }

    /// <summary>"E0:38" style code, as accepted by Set-KbdRAltRules.ps1.</summary>
    public string Code => (Extended ? "E0:" : "") + Scan.ToString("X2");

    /// <summary>"Right Alt (E0:38)" — code plus a human name where we know one.</summary>
    public string Display
    {
        get
        {
            var name = ScanCodes.NameOf(Scan, Extended);
            return name is null ? Code : $"{name} ({Code})";
        }
    }

    public KeyRef Clone() => new(Scan, Extended);

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise([CallerMemberName] string? n = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
}

public sealed class Rule : INotifyPropertyChanged
{
    private KeyRef _input = new();
    private RuleMode _mode = RuleMode.Chord;

    public KeyRef Input
    {
        get => _input;
        set { _input = value; Raise(); Raise(nameof(Summary)); }
    }

    public RuleMode Mode
    {
        get => _mode;
        set { if (_mode != value) { _mode = value; Raise(); Raise(nameof(Summary)); } }
    }

    public ObservableCollection<KeyRef> Output { get; } = new();

    /// <summary>One-line description, in the same shape as the script syntax.</summary>
    public string Summary
        => $"{Input.Display}  →  {Mode.ToString().ToLowerInvariant()} : " +
           (Output.Count == 0 ? "(empty)" : string.Join(" + ", Output.Select(o => o.Display)));

    public void RaiseSummary() => Raise(nameof(Summary));

    public Rule Clone()
    {
        var r = new Rule { Input = Input.Clone(), Mode = Mode };
        foreach (var o in Output) r.Output.Add(o.Clone());
        return r;
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise([CallerMemberName] string? n = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
}

/// <summary>
/// Validation that mirrors KbdRAltRuleIsSane and KbdRAltHasDuplicateInputs in rules.c.
///
/// Keeping this in step with the driver matters: the driver rejects a bad table WHOLE
/// and silently falls back to its built-in rule. If the GUI let a bad table through,
/// the user would see "saved successfully" and then find nothing works — with no clue
/// why. Better to refuse here, where we can say exactly what is wrong.
/// </summary>
public static class RuleValidator
{
    public static List<string> Validate(IReadOnlyList<Rule> rules)
    {
        var errors = new List<string>();

        if (rules.Count == 0)
        {
            errors.Add("The table is empty. Saving an empty table is not possible; " +
                       "use \"Reset to built-in rule\" to remove the table instead.");
            return errors;
        }

        if (rules.Count > Limits.MaxRules)
            errors.Add($"{rules.Count} rules, the driver accepts at most {Limits.MaxRules}.");

        for (int i = 0; i < rules.Count; i++)
        {
            var r = rules[i];
            var where = $"Rule {i + 1} ({r.Input.Code})";

            if (r.Input.Scan == 0 || r.Input.Scan > 0xFF)
                errors.Add($"{where}: the input scan code must be between 01 and FF.");

            if (r.Output.Count == 0)
                errors.Add($"{where}: no output keys.");
            else if (r.Output.Count > Limits.MaxOutPerRule)
                errors.Add($"{where}: {r.Output.Count} output keys, at most {Limits.MaxOutPerRule} allowed.");

            if (r.Mode == RuleMode.Remap && r.Output.Count != 1)
                errors.Add($"{where}: remap mode requires exactly one output key. " +
                           "Use chord mode for a sequence.");

            foreach (var o in r.Output)
                if (o.Scan == 0 || o.Scan > 0xFF)
                    errors.Add($"{where}: an output scan code must be between 01 and FF.");
        }

        var dup = rules
            .GroupBy(r => (r.Input.Scan, r.Input.Extended))
            .Where(g => g.Count() > 1)
            .ToList();

        foreach (var g in dup)
            errors.Add($"Two or more rules for the same key {g.First().Input.Display}. " +
                       "The driver would reject the whole table, so only one rule per key is allowed.");

        return errors;
    }
}
