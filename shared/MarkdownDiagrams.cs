// Copyright (c) 2026 DOTS
// Parses the colored ```diagram, ```flow and ```chart fences the HerNess prompt
// teaches. Windows and Linux draw them; macOS and mobile keep their own copy of
// the same rules (ConversationDiagram.swift, MarkdownDiagrams.swift/.kt).

using System.Globalization;

namespace DotsHarnessCore;

/// <summary>A trailing `[tone: label]` or `[group]` tag.</summary>
public sealed record DiagramTag(string? Tone, string Label)
{
    // Apple system colors, so every client paints a status the same way.
    private static readonly Dictionary<string, (byte R, byte G, byte B)> StatusColors = new(StringComparer.OrdinalIgnoreCase)
    {
        ["ok"] = (52, 199, 89), ["done"] = (52, 199, 89),
        ["warn"] = (255, 149, 0), ["warning"] = (255, 149, 0),
        ["error"] = (255, 59, 48), ["fail"] = (255, 59, 48),
        ["info"] = (0, 122, 255),
        ["pending"] = (142, 142, 147),
    };
    private static readonly (byte R, byte G, byte B)[] Palette =
        [(48, 176, 199), (88, 86, 214), (255, 149, 0), (255, 45, 85), (0, 122, 255), (162, 132, 94)];
    public static readonly (byte R, byte G, byte B) Neutral = (142, 142, 147);

    public (byte R, byte G, byte B) Color => Tone is { } tone && StatusColors.TryGetValue(tone, out var c) ? c : Neutral;

    public static bool IsStatus(string name) => StatusColors.ContainsKey(name);
    public static (byte R, byte G, byte B) StatusColor(string name) => StatusColors[name];
    public static (byte R, byte G, byte B) PaletteColor(int slot) => Palette[slot % Palette.Length];

    /// <summary>`"Title: note [ok: Doğru]"` → `("Title: note", tag)`.</summary>
    public static (string Body, DiagramTag? Tag) Split(string line)
    {
        var trimmed = line.Trim();
        var open = trimmed.LastIndexOf('[');
        if (!trimmed.EndsWith(']') || open < 0) return (trimmed, null);
        var inner = trimmed[(open + 1)..^1];
        var body = trimmed[..open].Trim();
        var colon = inner.IndexOf(':');
        var first = (colon < 0 ? inner : inner[..colon]).Trim();
        if (first.Length == 0) return (body, null);
        if (colon >= 0) return (body, new DiagramTag(first, inner[(colon + 1)..].Trim()));
        return (body, new DiagramTag(IsStatus(first) ? first : null, first));
    }

    /// <summary>`"title: note"` → `("title", "note")`.</summary>
    public static (string Title, string Note) TitleNote(string body)
    {
        var colon = body.IndexOf(':');
        return colon < 0 ? (body.Trim(), "") : (body[..colon].Trim(), body[(colon + 1)..].Trim());
    }
}

public sealed record FlowStep(int Number, string Title, string Note, DiagramTag? Badge, bool IsLast);
public sealed record ChartBar(string Label, string Text, double Fraction);
public sealed record DiagramNode(string Title, string Note, string? Group);
public sealed record DiagramLayer(string? Caption, IReadOnlyList<DiagramNode> Nodes);

/// <summary>```diagram: one line per layer; `a: b [g] | c: d [g]`, `> caption`, `legend: g = text | …`.</summary>
public sealed class DiagramSpec
{
    public List<DiagramLayer> Layers { get; } = [];
    public List<(string Group, string Text)> Legend { get; } = [];

    public DiagramSpec(string source)
    {
        string? caption = null;
        foreach (var raw in source.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith('>'))
            {
                caption = line[1..].Trim();
            }
            else if (line.StartsWith("legend:", StringComparison.OrdinalIgnoreCase))
            {
                foreach (var item in line[7..].Split('|'))
                {
                    var eq = item.IndexOf('=');
                    if (eq > 0) Legend.Add((item[..eq].Trim(), item[(eq + 1)..].Trim()));
                }
            }
            else
            {
                var nodes = line.Split('|').Select(cell =>
                {
                    var (body, tag) = DiagramTag.Split(cell);
                    var (title, note) = DiagramTag.TitleNote(body);
                    return new DiagramNode(title, note, tag?.Label);
                }).ToList();
                Layers.Add(new DiagramLayer(caption, nodes));
                caption = null;
            }
        }
    }

    /// <summary>Status names keep their fixed color; other groups take palette slots by first use.</summary>
    public (byte R, byte G, byte B) Color(string? group)
    {
        if (string.IsNullOrEmpty(group)) return DiagramTag.Neutral;
        if (DiagramTag.IsStatus(group)) return DiagramTag.StatusColor(group);
        var seen = Layers.SelectMany(l => l.Nodes).Select(n => n.Group).Concat(Legend.Select(l => l.Group))
            .OfType<string>().Where(g => !DiagramTag.IsStatus(g)).Distinct().ToList();
        return DiagramTag.PaletteColor(Math.Max(0, seen.IndexOf(group)));
    }
}

public static class MarkdownDiagrams
{
    public static IReadOnlyList<FlowStep> Flow(string source)
    {
        var lines = source.Split('\n').Where(l => l.Trim().Length > 0).ToList();
        return lines.Select((line, i) =>
        {
            var (body, badge) = DiagramTag.Split(line);
            var (title, note) = DiagramTag.TitleNote(body);
            return new FlowStep(i + 1, title, note, badge, i == lines.Count - 1);
        }).ToList();
    }

    /// <summary>`label: number` rows scaled to the block's peak; other lines are skipped.</summary>
    public static IReadOnlyList<ChartBar> Chart(string source)
    {
        var rows = new List<(string Label, string Text, double Value)>();
        foreach (var raw in source.Split('\n'))
        {
            var colon = raw.LastIndexOf(':');
            if (colon < 0) continue;
            var text = raw[(colon + 1)..].Trim();
            var number = new string(text.TakeWhile(c => char.IsDigit(c) || c is '.' or '-').ToArray());
            if (double.TryParse(number, NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
                rows.Add((raw[..colon].Trim(), text, value));
        }
        var peak = rows.Count == 0 ? 0 : rows.Max(r => Math.Abs(r.Value));
        return rows.Select(r => new ChartBar(r.Label, r.Text, peak > 0 ? Math.Abs(r.Value) / peak : 0)).ToList();
    }
}
