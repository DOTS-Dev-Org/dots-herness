// Copyright (c) 2026 DOTS
// Splits a chat message into prose and fenced ``` blocks. The Linux and Windows
// clients draw each fence unwrapped with a copy button, so box diagrams keep
// their columns and can be copied whole.

using System.Linq;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

/// <summary>Language is the fence tag (`diagram`, `flow`, `chart`), empty for prose and plain fences.
/// A pipe table in prose comes out as IsCode with Language `table`; read it with <see cref="MarkdownSegments.Table"/>.</summary>
public sealed record MarkdownSegment(bool IsCode, string Text, string Language = "");
public enum MarkdownTableAlignment { Left, Center, Right }
public sealed record MarkdownTable(
    IReadOnlyList<string> Header, IReadOnlyList<MarkdownTableAlignment> Alignments, IReadOnlyList<IReadOnlyList<string>> Rows);
public sealed record MarkdownInlineSegment(string Text, Uri? Link);

public static class MarkdownSegments
{
    private static readonly Regex InlineLinkPattern = new(
        @"\[(?<label>[^\]]+)\]\((?<markdownUrl>https?://[^\s)]+)\)|(?<url>https?://[^\s<>]+)",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public static IReadOnlyList<MarkdownSegment> Split(string? text)
    {
        var segments = new List<MarkdownSegment>();
        if (string.IsNullOrEmpty(text)) return segments;

        var prose = new List<string>();
        var code = new List<string>();
        var inCode = false;
        var language = "";
        foreach (var line in text.Replace("\r\n", "\n").Split('\n'))
        {
            if (line.TrimStart().StartsWith("```", StringComparison.Ordinal))
            {
                if (inCode) AddCode(segments, code, language);
                else
                {
                    AddProse(segments, prose);
                    language = line.Trim()[3..].Trim().ToLowerInvariant();
                }
                inCode = !inCode;
                continue;
            }
            (inCode ? code : prose).Add(line);
        }
        if (inCode) AddCode(segments, code, language);
        else AddProse(segments, prose);
        return segments;
    }

    /// <summary>Finds Markdown links and bare HTTP(S) URLs in a prose segment.</summary>
    public static IReadOnlyList<MarkdownInlineSegment> ParseInlineLinks(string? text)
    {
        if (string.IsNullOrEmpty(text)) return [];
        if (!text.Contains("http://", StringComparison.OrdinalIgnoreCase)
            && !text.Contains("https://", StringComparison.OrdinalIgnoreCase))
            return [new MarkdownInlineSegment(text, null)];
        var result = new List<MarkdownInlineSegment>();
        var position = 0;
        foreach (Match match in InlineLinkPattern.Matches(text))
        {
            if (match.Index > position)
                result.Add(new MarkdownInlineSegment(text[position..match.Index], null));

            var isMarkdown = match.Groups["markdownUrl"].Success;
            var rawUrl = isMarkdown ? match.Groups["markdownUrl"].Value : match.Groups["url"].Value;
            var label = isMarkdown ? match.Groups["label"].Value : rawUrl;
            var suffix = string.Empty;
            if (!isMarkdown)
            {
                var trimmedUrl = rawUrl.TrimEnd('.', ',', ';', ':', '!', '?');
                suffix = rawUrl[trimmedUrl.Length..];
                rawUrl = trimmedUrl;
                if (rawUrl.Length == 0)
                {
                    result.Add(new MarkdownInlineSegment(match.Value, null));
                    position = match.Index + match.Length;
                    continue;
                }
            }

            if (Uri.TryCreate(rawUrl, UriKind.Absolute, out var uri)
                && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
                result.Add(new MarkdownInlineSegment(label, uri));
            else
                result.Add(new MarkdownInlineSegment(isMarkdown ? match.Value : rawUrl, null));

            if (suffix.Length > 0) result.Add(new MarkdownInlineSegment(suffix, null));
            position = match.Index + match.Length;
        }
        if (position < text.Length) result.Add(new MarkdownInlineSegment(text[position..], null));
        if (result.Count == 0) result.Add(new MarkdownInlineSegment(text, null));
        return result;
    }

    /// <summary>Parses a `table` segment: header row, `|---|` alignment row, body rows.</summary>
    public static MarkdownTable Table(string text)
    {
        var lines = text.Split('\n');
        var alignments = TableAlignments(lines[1]) ?? [];
        var rows = lines.Skip(2).Select(line => (IReadOnlyList<string>)TableCells(line)).ToList();
        return new MarkdownTable(TableCells(lines[0]), alignments, rows);
    }

    // ponytail: splits on every `|`, so a pipe inside inline code breaks the cell; `\|` escapes it.
    public static IReadOnlyList<string> TableCells(string line)
    {
        var body = line.Trim();
        if (body.StartsWith('|')) body = body[1..];
        if (body.EndsWith('|') && !body.EndsWith("\\|", StringComparison.Ordinal)) body = body[..^1];
        return body.Replace("\\|", "\0").Split('|').Select(cell => cell.Replace("\0", "|").Trim()).ToList();
    }

    private static bool IsTableRow(string line) => line.TrimStart().StartsWith('|');

    private static IReadOnlyList<MarkdownTableAlignment>? TableAlignments(string line)
    {
        if (!IsTableRow(line)) return null;
        var cells = TableCells(line);
        if (!cells.All(cell => cell.Contains('-') && cell.All(c => c is '-' or ':'))) return null;
        return cells.Select(cell => (cell.StartsWith(':'), cell.EndsWith(':')) switch
        {
            (true, true) => MarkdownTableAlignment.Center,
            (false, true) => MarkdownTableAlignment.Right,
            _ => MarkdownTableAlignment.Left,
        }).ToList();
    }

    // Pipe tables leave prose as their own `table` segment; a header still waiting for
    // its `|---|` row stays prose until that row streams in.
    private static void AddProse(List<MarkdownSegment> segments, List<string> lines)
    {
        var start = 0;
        for (var i = 0; i + 1 < lines.Count; i++)
        {
            if (!IsTableRow(lines[i]) || TableAlignments(lines[i + 1]) is null) continue;
            var end = i + 2;
            while (end < lines.Count && IsTableRow(lines[end])) end++;
            AddPlainProse(segments, lines.GetRange(start, i - start));
            segments.Add(new MarkdownSegment(true, string.Join("\n", lines.GetRange(i, end - i).Select(l => l.Trim())), "table"));
            start = end;
            i = end - 1;
        }
        AddPlainProse(segments, lines.GetRange(start, lines.Count - start));
        lines.Clear();
    }

    private static void AddPlainProse(List<MarkdownSegment> segments, List<string> lines)
    {
        var text = string.Join("\n", lines).Trim('\n');
        if (text.Trim().Length > 0) segments.Add(new MarkdownSegment(false, text));
    }

    // An unclosed fence stays code: the reply is still streaming.
    private static void AddCode(List<MarkdownSegment> segments, List<string> lines, string language)
    {
        if (lines.Count > 0) segments.Add(new MarkdownSegment(true, string.Join("\n", lines), language));
        lines.Clear();
    }
}
