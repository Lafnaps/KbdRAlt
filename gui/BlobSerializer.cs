// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Lafnaps

using System.IO;

namespace KbdRAlt.Config;

/// <summary>
/// Converts between the rule list and the binary blob the driver reads.
///
/// The layout must match kbdralt.h exactly (declared under pshpack1, so no padding):
///
///   KBDRALT_KEY   : USHORT Scan, USHORT Extended                       =  4 bytes
///   KBDRALT_RULE  : USHORT InScan, USHORT InExtended, ULONG Mode,
///                   ULONG OutCount, ULONG Reserved, KBDRALT_KEY Out[8] = 48 bytes
///   KBDRALT_RULES : ULONG Version, ULONG Count, KBDRALT_RULE Rule[]    =  8 + 48*N
///
/// Out[] is always written at full length; entries past OutCount are zero. The driver
/// ignores them, but writing a fixed-size array keeps the layout trivially predictable.
///
/// Everything is little-endian, which is what BinaryWriter/BinaryReader do on the
/// platforms this driver targets.
/// </summary>
public static class BlobSerializer
{
    public static byte[] Serialize(IReadOnlyList<Rule> rules)
    {
        using var ms = new MemoryStream();
        using var bw = new BinaryWriter(ms);

        bw.Write((uint)Limits.BlobVersion);
        bw.Write((uint)rules.Count);

        foreach (var r in rules)
        {
            bw.Write((ushort)r.Input.Scan);
            bw.Write((ushort)(r.Input.Extended ? 1 : 0));
            bw.Write((uint)r.Mode);
            bw.Write((uint)r.Output.Count);
            bw.Write((uint)0);                       // Reserved — the driver requires zero

            for (int i = 0; i < Limits.MaxOutPerRule; i++)
            {
                if (i < r.Output.Count)
                {
                    bw.Write((ushort)r.Output[i].Scan);
                    bw.Write((ushort)(r.Output[i].Extended ? 1 : 0));
                }
                else
                {
                    bw.Write((ushort)0);
                    bw.Write((ushort)0);
                }
            }
        }

        bw.Flush();
        var blob = ms.ToArray();

        var expected = Limits.HeaderSize + rules.Count * Limits.RuleSize;
        if (blob.Length != expected)
            throw new InvalidOperationException(
                $"internal error: blob is {blob.Length} bytes, expected {expected}");

        return blob;
    }

    /// <summary>
    /// Parses a blob back into rules. Returns null with a reason whenever the driver
    /// would reject the blob.
    ///
    /// This must be exactly as strict as KbdRAltRuleIsSane and
    /// KbdRAltHasDuplicateInputs in rules.c, no more and no less. Being more permissive
    /// is the dangerous direction: the driver discards a bad table WHOLE and quietly
    /// falls back to its built-in rule, so a blob we accept but it rejects gets shown to
    /// the user as the live configuration while the machine behaves differently. That is
    /// precisely the confusion this tool exists to prevent.
    /// </summary>
    public static IReadOnlyList<Rule>? TryParse(byte[] blob, out string? problem)
    {
        problem = null;

        if (blob.Length < Limits.HeaderSize)
        {
            problem = $"the value is only {blob.Length} bytes, shorter than the header.";
            return null;
        }

        using var ms = new MemoryStream(blob);
        using var br = new BinaryReader(ms);

        uint version = br.ReadUInt32();
        uint count   = br.ReadUInt32();

        if (version != Limits.BlobVersion)
        {
            problem = $"blob version {version}, this tool understands version {Limits.BlobVersion}.";
            return null;
        }
        if (count == 0 || count > Limits.MaxRules)
        {
            problem = $"rule count {count} is outside 1..{Limits.MaxRules}.";
            return null;
        }

        long need = Limits.HeaderSize + (long)count * Limits.RuleSize;
        if (blob.Length < need)
        {
            problem = $"the value is {blob.Length} bytes but {count} rules need {need}.";
            return null;
        }

        var rules = new List<Rule>((int)count);
        for (int i = 0; i < count; i++)
        {
            ushort inScan = br.ReadUInt16();
            ushort inExt  = br.ReadUInt16();
            uint mode     = br.ReadUInt32();
            uint outCount = br.ReadUInt32();
            uint reserved = br.ReadUInt32();

            if (mode > (uint)RuleMode.Remap)
            {
                problem = $"rule {i + 1} has unknown mode {mode}.";
                return null;
            }
            if (outCount == 0 || outCount > Limits.MaxOutPerRule)
            {
                problem = $"rule {i + 1} has {outCount} outputs, outside 1..{Limits.MaxOutPerRule}.";
                return null;
            }
            if (reserved != 0)
            {
                problem = $"rule {i + 1} has a non-zero reserved field; the driver would reject it.";
                return null;
            }
            // rules.c requires exactly one output in remap mode: otherwise it is undefined
            // what should be emitted on press and what on release.
            if (mode == (uint)RuleMode.Remap && outCount != 1)
            {
                problem = $"rule {i + 1} is a remap with {outCount} outputs; the driver requires exactly one.";
                return null;
            }
            if (inScan == 0 || inScan > 0xFF)
            {
                problem = $"rule {i + 1} has input scan code 0x{inScan:X}, outside 01..FF.";
                return null;
            }
            // The driver compares InExtended exactly, so a value of 2 would not merely be
            // odd — it would make the rule unreachable. rules.c rejects it outright.
            if (inExt > 1)
            {
                problem = $"rule {i + 1} has extended flag {inExt}; the driver only accepts 0 or 1.";
                return null;
            }

            var rule = new Rule
            {
                Input = new KeyRef(inScan, inExt != 0),
                Mode  = (RuleMode)mode,
            };

            for (int k = 0; k < Limits.MaxOutPerRule; k++)
            {
                ushort scan = br.ReadUInt16();
                ushort ext  = br.ReadUInt16();
                if (k >= outCount) continue;

                if (scan == 0 || scan > 0xFF)
                {
                    problem = $"rule {i + 1} has output scan code 0x{scan:X}, outside 01..FF.";
                    return null;
                }
                if (ext > 1)
                {
                    problem = $"rule {i + 1} has an output extended flag of {ext}; only 0 or 1 is accepted.";
                    return null;
                }
                rule.Output.Add(new KeyRef(scan, ext != 0));
            }

            rules.Add(rule);
        }

        // Cross-rule check, mirroring KbdRAltHasDuplicateInputs. This is the worst one to
        // omit: two individually valid-looking rules for the same key make the driver
        // throw away the ENTIRE table, including every other rule in it.
        var dup = rules
            .GroupBy(r => (r.Input.Scan, r.Input.Extended))
            .FirstOrDefault(g => g.Count() > 1);
        if (dup is not null)
        {
            problem = $"two or more rules share the input key {dup.First().Input.Code}; " +
                      "the driver rejects the whole table in that case.";
            return null;
        }

        return rules;
    }
}
