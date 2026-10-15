// Copyright (c) 2026 DOTS
// Surgical file editing and filename search for the native agent loop (parity with
// macOS WorkspaceTools+Editing.swift).
//
// write_file replaces a whole file, which forces the model to reproduce every byte it
// does not intend to change - and a file it never read is refused for exactly that
// reason. edit_file is the other half: it names the text to replace, so the untouched
// 90 % of the file is never in the transcript. It is still guarded by the same read
// ledger, because an edit applied to bytes the model has not seen is the same loss in a
// smaller wrapper.

using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

public static class NativeFileEdit
{
    public const string EditName = "edit_file";
    public const string GlobName = "glob";

    /// Directory walks stop here rather than reporting a partial list as if it were
    /// complete.
    internal const int GlobResultCap = 200;
    internal const int GlobScanLimit = 20_000;
    internal const int MaxEditsPerCall = 50;
    private const int AmbiguousLineSample = 5;
    private static readonly TimeSpan RegexTimeout = TimeSpan.FromSeconds(2);

    public static NativeToolDefinition EditDefinition { get; } = new(
        EditName,
        "Replace exact text inside an existing file, without rewriting the rest of it. "
        + "Prefer this over write_file for any edit to a file you have already read. Each "
        + "old_text must match the file byte for byte and appear exactly once unless "
        + "replace_all is set; a match that is not unique is refused rather than guessed "
        + "at, so widen it with surrounding lines. Creating a new file still needs write_file.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["path"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Relative path to the existing file.",
                },
                ["edits"] = new JsonObject
                {
                    ["type"] = "array",
                    ["description"] = "Replacements applied in order, all or none.",
                    ["items"] = new JsonObject
                    {
                        ["type"] = "object",
                        ["properties"] = new JsonObject
                        {
                            ["old_text"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["description"] = "Exact text to replace, copied from read_file.",
                            },
                            ["new_text"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["description"] = "Replacement text. Empty deletes the match.",
                            },
                            ["replace_all"] = new JsonObject
                            {
                                ["type"] = "boolean",
                                ["description"] = "Replace every occurrence instead of requiring one unique match.",
                            },
                        },
                        ["required"] = new JsonArray("old_text", "new_text"),
                        ["additionalProperties"] = false,
                    },
                },
            },
            ["required"] = new JsonArray("path", "edits"),
            ["additionalProperties"] = false,
        });

    public static NativeToolDefinition GlobDefinition { get; } = new(
        GlobName,
        "Find files by name pattern inside the workspace and get back paths newest-first. "
        + "Supports * and ? within one path segment, ** across segments, and {a,b} groups "
        + "\u2014 so \"**/*.swift\", \"Sources/**/*Test*.swift\", \"config.{json,yml}\". A pattern with no "
        + "slash matches filenames at any depth. Use grep_files instead when the content, not "
        + "the name, is what you are looking for.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["pattern"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Glob pattern, relative to the searched directory.",
                },
                ["path"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Relative directory to search. Defaults to the workspace root.",
                },
            },
            ["required"] = new JsonArray("pattern"),
            ["additionalProperties"] = false,
        });

    // Declaration order is initialization order for static members, so the pair is built
    // after the two definitions it holds.
    public static IReadOnlyList<NativeToolDefinition> Definitions { get; } = [EditDefinition, GlobDefinition];

    public static bool IsFileEditTool(string name) => name == EditName || name == GlobName;

    public sealed record EditOperation(string? OldText, string? NewText, bool ReplaceAll);

    public static string Execute(NativeToolCall call, string workspace)
    {
        JsonObject input;
        try
        {
            // A body that is not an object is as unusable as one that will not parse.
            input = JsonNode.Parse(call.Arguments) as JsonObject
                ?? throw new JsonException("The arguments are not an object.");
        }
        catch (Exception) { return "Tool error: invalid JSON arguments."; }
        try
        {
            return call.Name switch
            {
                EditName => Edit(Text(input["path"]), Operations(input["edits"]), workspace),
                GlobName => Glob(Text(input["pattern"]), Text(input["path"]) ?? ".", workspace),
                _ => $"Tool error: unknown file tool {call.Name}.",
            };
        }
        catch (Exception ex) { return $"Tool error: {ex.Message}"; }
    }

    private static string? Text(JsonNode? node)
    {
        if (node is null) return null;
        try { return node.GetValue<string>(); } catch { return null; }
    }

    private static bool Flag(JsonNode? node)
    {
        if (node is null) return false;
        try { return node.GetValue<bool>(); } catch { }
        try { return bool.TryParse(node.GetValue<string>(), out var parsed) && parsed; } catch { return false; }
    }

    /// A missing or malformed `edits` is the model's mistake, so it is answered the way
    /// the reference answers it rather than dropped on the floor.
    private static List<EditOperation> Operations(JsonNode? node)
    {
        if (node is not JsonArray array) throw new InvalidOperationException(
            "edits must be an array of {old_text, new_text} objects.");
        var operations = new List<EditOperation>();
        foreach (var item in array)
        {
            if (item is not JsonObject entry)
                throw new InvalidOperationException("edits must be an array of {old_text, new_text} objects.");
            operations.Add(new EditOperation(Text(entry["old_text"]), Text(entry["new_text"]), Flag(entry["replace_all"])));
        }
        return operations;
    }

    // MARK: - edit_file

    public static string Edit(string? path, IReadOnlyList<EditOperation> edits, string workspace)
    {
        if (edits.Count == 0) return "Tool error: edits is empty; at least one replacement is required.";
        if (edits.Count > MaxEditsPerCall)
            return $"Tool error: too many edits in one call (max {MaxEditsPerCall}). Split them into separate calls.";
        if (string.IsNullOrWhiteSpace(path)) return "A file path is required.";

        string file;
        try { file = NativeWorkspaceTools.Resolve(path, workspace); }
        catch (Exception ex) { return $"Tool error: {ex.Message}"; }
        byte[] current;
        try { current = File.ReadAllBytes(file); }
        catch (Exception)
        {
            return $"Tool error: {path} does not exist. write_file creates a new file; edit_file only changes an existing one.";
        }
        string text;
        try { text = new UTF8Encoding(false, true).GetString(current); }
        catch (DecoderFallbackException) { return $"Tool error: {path} is not valid UTF-8 text."; }
        // An edit assumes the model has seen the bytes it is matching against. Unlike
        // write_file it does not need the whole file: the lines it replaces must lie
        // inside pages read from this exact version.
        var totalLines = text.Split('\n').Length;
        var (state, covered) = ReadLedger.Coverage(file, current, totalLines);
        switch (state)
        {
            case ReadState.Unread:
                return $"Tool error: {path} has not been read in this conversation. Read it before editing.";
            case ReadState.Stale:
                return $"Tool error: {path} changed since it was read. Read it again before editing.";
        }
        var partial = !(covered.Count == 1 && covered[0].Start == 1 && covered[0].End > totalLines);

        var updated = text;
        var summary = new List<string>();
        for (var index = 0; index < edits.Count; index++)
        {
            var operation = edits[index];
            var oldText = operation.OldText;
            var newText = operation.NewText;
            if (oldText is null || newText is null)
                return $"Tool error: edit {index + 1} needs both old_text and new_text. Nothing was written.";
            if (oldText.Length == 0)
                return $"Tool error: edit {index + 1} has an empty old_text, which would match everywhere. Nothing was written.";
            var replaceAll = operation.ReplaceAll;
            var found = Occurrences(oldText, updated);
            if (found.Count == 0)
                return "Tool error: edit " + (index + 1) + " matched nothing in " + path
                    + ". Nothing was written \u2014 check the exact text and whitespace with read_file.";
            if (found.Count > 1 && !replaceAll)
            {
                var lines = found.Take(AmbiguousLineSample).Select(position => LineNumber(updated, position)).ToArray();
                return "Tool error: edit " + (index + 1) + " matched " + found.Count + " places in " + path
                    + " (around line" + (lines.Length == 1 ? "" : "s") + " " + string.Join(", ", lines) + "). "
                    + "Nothing was written. Widen old_text with surrounding lines, or set replace_all.";
            }
            if (partial)
            {
                var touched = (replaceAll ? found : found.Take(1))
                    .Select(position => (Start: LineNumber(updated, position), End: LineNumber(updated, position + oldText.Length - 1)))
                    .ToList();
                var unread = touched.FirstOrDefault(span => !covered.Any(range => range.Start <= span.Start && span.End < range.End));
                if (unread != default)
                    return $"Tool error: edit {index + 1} changes lines {unread.Start}-{unread.End} of {path}, which were not read in this conversation. "
                        + "Read them with read_file offset/limit first. Nothing was written.";
                var delta = newText.Count(c => c == '\n') - oldText.Count(c => c == '\n');
                foreach (var span in touched.OrderByDescending(span => span.Start))
                    covered = ShiftRanges(covered, span.End, delta);
            }
            if (replaceAll)
            {
                updated = updated.Replace(oldText, newText, StringComparison.Ordinal);
                summary.Add($"replaced {found.Count} occurrence{(found.Count == 1 ? "" : "s")}");
            }
            else
            {
                var position = found[0];
                updated = updated.Remove(position, oldText.Length).Insert(position, newText);
                summary.Add("replaced 1 occurrence");
            }
        }

        byte[] data;
        try
        {
            data = Encoding.UTF8.GetBytes(updated);
            WriteAtomically(file, data);
        }
        catch (Exception ex) { return $"Tool error: could not write {path}: {ex.Message}"; }
        if (partial)
        {
            // Carry what was read over to the new version, shifted past each edit, so
            // the next edit in the same section needs no reread.
            var newTotal = updated.Split('\n').Length;
            foreach (var range in covered.Where(range => range.End > range.Start))
                ReadLedger.RecordLines(file, data, range.Start, Math.Min(range.End, newTotal + 1), newTotal);
        }
        else ReadLedger.Record(file, data);
        return $"Edited {RelativePath(WorkspaceRoot(workspace), file)} ({string.Join("; ", summary)}).";
    }

    /// The workspace as the resolver sees it: reported paths have to be relative to the
    /// same canonical root the file itself was resolved against, or a workspace reached
    /// through a symlink answers with a path climbing out of it.
    private static string WorkspaceRoot(string workspace) => NativeWorkspaceTools.Resolve(".", workspace);

    /// Same temporary-then-move shape as write_file: a half-written file is worse than no
    /// edit at all, and every rejection above happens before anything touches the disk.
    private static void WriteAtomically(string file, byte[] data)
    {
        var temporary = file + "." + Guid.NewGuid().ToString("N") + ".part";
        try
        {
            File.WriteAllBytes(temporary, data);
            File.Move(temporary, file, overwrite: true);
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
        }
    }

    /// Overlapping matches are counted left to right, the same way the subsequent
    /// replacement consumes them - so a count of two never describes one rewrite.
    internal static List<int> Occurrences(string needle, string haystack)
    {
        var positions = new List<int>();
        var cursor = 0;
        while (true)
        {
            var found = haystack.IndexOf(needle, cursor, StringComparison.Ordinal);
            if (found < 0) break;
            positions.Add(found);
            cursor = found + needle.Length;
        }
        return positions;
    }

    /// Moves read ranges after an edit that ended on <paramref name="editEnd"/> and
    /// changed the line count by <paramref name="delta"/>: later ranges shift, the
    /// range holding the edit stretches or shrinks, earlier ones stay.
    internal static List<(int Start, int End)> ShiftRanges(List<(int Start, int End)> ranges, int editEnd, int delta) =>
        ranges.Select(range => range.Start > editEnd
                ? (range.Start + delta, range.End + delta)
                : range.End > editEnd ? (range.Start, range.End + delta) : range)
            .ToList();

    internal static int LineNumber(string text, int position)
    {
        var lines = 1;
        for (var index = 0; index < position && index < text.Length; index++)
            if (text[index] == '\n') lines++;
        return lines;
    }

    // MARK: - glob

    public static string Glob(string? pattern, string path, string workspace)
    {
        var trimmed = (pattern ?? "").Trim();
        if (trimmed.Length == 0) return "Tool error: pattern is required.";
        if (trimmed.StartsWith('/') || trimmed.StartsWith('\\')
            || Path.IsPathRooted(trimmed) || trimmed.Contains("..", StringComparison.Ordinal))
            return "Tool error: pattern must stay inside the workspace.";
        var expression = GlobRegex(trimmed);
        if (expression is null)
            return "Tool error: the pattern could not be compiled \u2014 check for an unclosed { or [.";

        var baseDirectory = string.Empty;
        try { baseDirectory = NativeWorkspaceTools.Resolve(path, workspace); }
        catch (Exception ex) { return $"Tool error: {ex.Message}"; }
        if (!Directory.Exists(baseDirectory)) return $"Tool error: {path} is not a directory.";

        var matches = GlobMatches(expression, trimmed.Contains('/', StringComparison.Ordinal), baseDirectory);
        if (matches.Count == 0) return $"glob {trimmed}: no files found.";
        var scope = RelativePath(WorkspaceRoot(workspace), baseDirectory);
        var header = matches.Count > GlobResultCap
            ? $"glob {trimmed} under {scope}: {GlobResultCap} newest of {matches.Count} matches \u2014 narrow the pattern"
            : $"glob {trimmed} under {scope}: {matches.Count} file{(matches.Count == 1 ? "" : "s")}";
        var lines = new List<string> { header };
        lines.AddRange(matches.Take(GlobResultCap).Select(item => item.Relative));
        return string.Join('\n', lines);
    }

    /// Newest first: when an agent is looking for "the file I just made", the
    /// modification time carries more signal than alphabetical order.
    internal static List<(string Relative, DateTime Modified)> GlobMatches(
        Regex expression,
        bool patternHasSlash,
        string baseDirectory)
    {
        var found = new List<(string Relative, DateTime Modified)>();
        var scanned = 0;
        var pending = new Stack<string>();
        pending.Push(baseDirectory);
        while (pending.Count > 0)
        {
            var directory = pending.Pop();
            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFileSystemEntries(directory); }
            catch { continue; }
            var limitReached = false;
            foreach (var entry in entries)
            {
                var name = Path.GetFileName(entry);
                // An ignored or symlinked directory is never descended into: skipping
                // descendants is what the reference does, and a stack walk simply refuses
                // to queue them.
                if (NativeWorkspaceTools.IgnoredScanDirectories.Contains(name)
                    || NativeWorkspaceTools.IsSymlink(entry)) continue;
                if (Directory.Exists(entry))
                {
                    pending.Push(entry);
                    continue;
                }
                if (!File.Exists(entry)) continue;
                if (++scanned > GlobScanLimit) { limitReached = true; break; }
                var relative = RelativePath(baseDirectory, entry);
                var separator = relative.LastIndexOf('/');
                var lastComponent = separator < 0 ? relative : relative[(separator + 1)..];
                if (IsMatch(expression, relative, patternHasSlash, lastComponent))
                    found.Add((relative, LastWrite(entry)));
            }
            if (limitReached) break;
        }
        found.Sort((left, right) => left.Modified == right.Modified
            ? StringComparer.Ordinal.Compare(left.Relative, right.Relative)
            : right.Modified.CompareTo(left.Modified));
        return found;
    }

    private static bool IsMatch(Regex expression, string relative, bool patternHasSlash, string lastComponent)
    {
        try
        {
            if (expression.IsMatch(relative)) return true;
            // "**/*.swift" already crosses separators; a bare "*.swift" should still reach
            // nested files, which is what an agent means when it types one.
            return !patternHasSlash && lastComponent.Length > 0 && expression.IsMatch(lastComponent);
        }
        catch (RegexMatchTimeoutException) { return false; }
    }

    private static DateTime LastWrite(string path)
    {
        try { return File.GetLastWriteTime(path); }
        catch (Exception) { return DateTime.MinValue; }
    }

    /// Compiles a glob into an anchored regular expression, or null when it cannot be
    /// compiled at all. `**` alone spans path separators, `**/` also matches zero
    /// directories, and a brace group becomes a non-capturing alternation.
    internal static Regex? GlobRegex(string pattern)
    {
        if (GlobPattern(pattern) is not { } source) return null;
        try { return new Regex(source, RegexOptions.None, RegexTimeout); }
        catch (ArgumentException) { return null; }
    }

    public static string? GlobPattern(string pattern)
    {
        var output = new StringBuilder();
        var braceDepth = 0;
        var index = 0;
        while (index < pattern.Length)
        {
            var character = pattern[index];
            var next = index + 1;
            switch (character)
            {
                case '*':
                    if (next < pattern.Length && pattern[next] == '*')
                    {
                        var after = next + 1;
                        if (after < pattern.Length && pattern[after] == '/')
                        {
                            // `**/` may stand for zero directories as well as many, so
                            // "src/**/*.ts" has to keep matching "src/a.ts".
                            output.Append("(?:[^/]*/)*");
                            index = after + 1;
                            continue;
                        }
                        output.Append(".*");
                        index = after;
                        continue;
                    }
                    output.Append("[^/]*");
                    index = next;
                    break;
                case '?':
                    output.Append("[^/]");
                    index = next;
                    break;
                case '{':
                    braceDepth++;
                    output.Append("(?:");
                    index = next;
                    break;
                case '}':
                    if (braceDepth == 0) return null;
                    braceDepth--;
                    output.Append(')');
                    index = next;
                    break;
                case ',':
                    output.Append(braceDepth > 0 ? "|" : ",");
                    index = next;
                    break;
                case '[':
                    // Copy the class verbatim; an unterminated one is a broken pattern.
                    var close = pattern.IndexOf(']', next);
                    if (close < 0 || close == next) return null;
                    output.Append('[').Append(pattern, next, close - next).Append(']');
                    index = close + 1;
                    break;
                default:
                    output.Append(RegexEscaped(character));
                    index = next;
                    break;
            }
        }
        if (braceDepth != 0) return null;
        return "^" + output + "$";
    }

    /// Only the metacharacters that can actually reach here are escaped: the switch above
    /// has already consumed `*`, `?`, `{`, `}`, `,` and `[`.
    private static string RegexEscaped(char character) =>
        ".+^$()|\\][".IndexOf(character) >= 0 ? "\\" + character : character.ToString();

    /// Reported paths are workspace-relative and always with forward slashes, so the same
    /// pattern text matches on every platform.
    internal static string RelativePath(string root, string path)
    {
        var relative = Path.GetRelativePath(Path.GetFullPath(root), path);
        return relative.Replace(Path.DirectorySeparatorChar, '/')
            .Replace(Path.AltDirectorySeparatorChar, '/');
    }
}
