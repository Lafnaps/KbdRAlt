// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Lafnaps

namespace KbdRAlt.Config;

/// <summary>
/// Names for set-1 scan codes, so the UI can say "Right Alt" instead of "E0:38".
///
/// Deliberately not exhaustive: it covers the keys people actually remap. Anything
/// unknown is shown as a bare hex code, which is still perfectly usable.
///
/// Note these are physical key positions, not characters. Scan code 0x29 is the key
/// left of "1" — backtick on a US layout, ё on a Russian one. The driver works in scan
/// codes, so the UI does too rather than pretending to know the user's layout.
/// </summary>
public static class ScanCodes
{
    private static readonly Dictionary<(ushort, bool), string> Names = new()
    {
        [(0x01, false)] = "Esc",
        [(0x0E, false)] = "Backspace",
        [(0x0F, false)] = "Tab",
        [(0x1C, false)] = "Enter",
        [(0x1D, false)] = "Left Ctrl",
        [(0x1D, true )] = "Right Ctrl",
        [(0x2A, false)] = "Left Shift",
        [(0x36, false)] = "Right Shift",
        [(0x38, false)] = "Left Alt",
        [(0x38, true )] = "Right Alt",
        [(0x39, false)] = "Space",
        [(0x3A, false)] = "CapsLock",
        [(0x29, false)] = "Key left of 1 (` / ё)",
        [(0x0C, false)] = "Minus",
        [(0x0D, false)] = "Equals",
        [(0x1A, false)] = "Left bracket",
        [(0x1B, false)] = "Right bracket",
        [(0x27, false)] = "Semicolon",
        [(0x28, false)] = "Quote",
        [(0x2B, false)] = "Backslash",
        [(0x33, false)] = "Comma",
        [(0x34, false)] = "Period",
        [(0x35, false)] = "Slash",
        [(0x56, false)] = "ISO key (102nd)",
        [(0x5B, true )] = "Left Win",
        [(0x5C, true )] = "Right Win",
        [(0x5D, true )] = "Menu",
        [(0x46, false)] = "ScrollLock",
        [(0x45, false)] = "NumLock",
        [(0x52, true )] = "Insert",
        [(0x53, true )] = "Delete",
        [(0x47, true )] = "Home",
        [(0x4F, true )] = "End",
        [(0x49, true )] = "Page Up",
        [(0x51, true )] = "Page Down",
        [(0x48, true )] = "Up",
        [(0x50, true )] = "Down",
        [(0x4B, true )] = "Left",
        [(0x4D, true )] = "Right",
        [(0x1C, true )] = "Numpad Enter",
        [(0x35, true )] = "Numpad /",
        [(0x37, false)] = "Numpad *",
        [(0x4A, false)] = "Numpad -",
        [(0x4E, false)] = "Numpad +",
    };

    static ScanCodes()
    {
        // Letter and digit rows, by physical position on a US layout.
        const string row1 = "QWERTYUIOP";
        for (int i = 0; i < row1.Length; i++) Names[((ushort)(0x10 + i), false)] = $"{row1[i]} key";
        const string row2 = "ASDFGHJKL";
        for (int i = 0; i < row2.Length; i++) Names[((ushort)(0x1E + i), false)] = $"{row2[i]} key";
        const string row3 = "ZXCVBNM";
        for (int i = 0; i < row3.Length; i++) Names[((ushort)(0x2C + i), false)] = $"{row3[i]} key";
        const string digits = "1234567890";
        for (int i = 0; i < digits.Length; i++) Names[((ushort)(0x02 + i), false)] = $"{digits[i]} key";
        for (int i = 0; i < 10; i++) Names[((ushort)(0x3B + i), false)] = $"F{i + 1}";
        Names[(0x57, false)] = "F11";
        Names[(0x58, false)] = "F12";
    }

    public static string? NameOf(ushort scan, bool extended)
        => Names.TryGetValue((scan, extended), out var n) ? n : null;

    /// <summary>Keys offered in the "add output" picker, in a sensible order.</summary>
    public static IEnumerable<KeyRef> CommonOutputs()
    {
        yield return new KeyRef(0x38, false);  // Left Alt
        yield return new KeyRef(0x2A, false);  // Left Shift
        yield return new KeyRef(0x1D, false);  // Left Ctrl
        yield return new KeyRef(0x5B, true);   // Left Win
        yield return new KeyRef(0x29, false);  // key left of 1
        yield return new KeyRef(0x3A, false);  // CapsLock
        yield return new KeyRef(0x01, false);  // Esc
        yield return new KeyRef(0x0F, false);  // Tab
    }
}
