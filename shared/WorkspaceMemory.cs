// Copyright (c) 2026 DOTS
// Private, workspace-scoped memory for the Windows and Linux shells. Port of the macOS
// WorkspaceMemory.swift, and interoperable with it: the same `.mem` folder is read and written by both.
//
// Everything is event-sourced. Each event is a small JSON file in `.mem/events`, signed with the
// device's P-256 key over a canonical (sorted-key) serialization that matches Foundation's
// `JSONSerialization(.sortedKeys)` byte for byte, so an event signed on macOS verifies here and the
// other way round. State (members, decisions, preferences, ...) is a projection rebuilt from verified
// events. Task, decision and conversation notes plus index/map/preferences are generated Markdown
// (an Obsidian-style vault) that the UI browses read-only.
//
// Difference from macOS: the memory snapshot given to the model leaves out the unfinished-work backlog,
// because the C# shells already inject it as its own prompt section (WorkspaceBacklog).

using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PluginRuntime;

namespace DotsHarnessCore;

public enum MemoryRole
{
    Owner,
    Approver,
    Contributor,
    Observer,
}

public static class MemoryRoles
{
    public static int Rank(this MemoryRole role) => role switch
    {
        MemoryRole.Owner => 3,
        MemoryRole.Approver => 2,
        MemoryRole.Contributor => 1,
        _ => 0,
    };

    public static string Wire(this MemoryRole role) => role.ToString().ToLowerInvariant();

    public static string TitleKey(this MemoryRole role) => $"access.role.{role.Wire()}";

    public static MemoryRole? Parse(string? value) =>
        Enum.TryParse<MemoryRole>(value, ignoreCase: true, out var role) ? role : null;
}

public enum ConversationLifecycleState
{
    Archived,
    Restored,
    Deleted,
}

public sealed record WorkspaceAccessStatus(
    string PersonId = "",
    string DeviceId = "",
    MemoryRole? Role = null,
    int Score = 0,
    int MemberCount = 0,
    int PendingDecisionCount = 0,
    int Revision = 0,
    bool MemoryReady = false);

public sealed record MemorySnapshot(string Text, int Revision);

/// <summary>One parsed note in the Obsidian-style `.mem` vault.</summary>
public sealed record MemoryNote(
    string Id,
    string Kind,
    string Title,
    string Path,
    string Body = "",
    IReadOnlyList<string>? Tags = null,
    IReadOnlyList<string>? Links = null,
    IReadOnlyList<string>? Backlinks = null,
    int Revision = 0,
    bool Resolved = true)
{
    public IReadOnlyList<string> TagList => Tags ?? Array.Empty<string>();
    public IReadOnlyList<string> LinkList => Links ?? Array.Empty<string>();
    public IReadOnlyList<string> BacklinkList => Backlinks ?? Array.Empty<string>();
}

public sealed record MemoryVaultEdge(string From, string To);

public sealed record MemoryVault(IReadOnlyList<MemoryNote> Notes, IReadOnlyList<MemoryVaultEdge> Edges)
{
    public MemoryVault() : this(Array.Empty<MemoryNote>(), Array.Empty<MemoryVaultEdge>()) { }
}

public enum WorkspaceMemoryErrorKind
{
    NoWorkspace,
    Unauthorized,
    InvalidManifest,
    InvalidInvitation,
    WrongDevice,
}

public sealed class WorkspaceMemoryException : Exception
{
    public WorkspaceMemoryErrorKind Kind { get; }

    public WorkspaceMemoryException(WorkspaceMemoryErrorKind kind)
        : base(LocalizationService.Current.Get(kind switch
        {
            WorkspaceMemoryErrorKind.NoWorkspace => "workspaceMemory.noWorkspace",
            WorkspaceMemoryErrorKind.Unauthorized => "workspaceMemory.unauthorized",
            WorkspaceMemoryErrorKind.InvalidManifest => "workspaceMemory.invalidManifest",
            WorkspaceMemoryErrorKind.InvalidInvitation => "workspaceMemory.invalidInvitation",
            _ => "workspaceMemory.wrongDevice",
        })) => Kind = kind;
}

/// <summary>
/// Serialization identical to Foundation's <c>JSONSerialization</c> with <c>.sortedKeys</c>: keys sorted,
/// no whitespace, "/" escaped as "\/", non-ASCII left as UTF-8. Signatures are computed over these bytes,
/// so a difference here would make every event fail verification on the other platform.
/// </summary>
public static class CanonicalJson
{
    public static string Serialize(JsonNode? node)
    {
        var builder = new StringBuilder();
        Write(builder, node);
        return builder.ToString();
    }

    public static byte[] Bytes(JsonNode? node) => Encoding.UTF8.GetBytes(Serialize(node));

    private static void Write(StringBuilder builder, JsonNode? node)
    {
        switch (node)
        {
            case null:
                builder.Append("null");
                break;
            case JsonObject obj:
                builder.Append('{');
                var first = true;
                foreach (var pair in obj.OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    if (!first) builder.Append(',');
                    first = false;
                    WriteString(builder, pair.Key);
                    builder.Append(':');
                    Write(builder, pair.Value);
                }
                builder.Append('}');
                break;
            case JsonArray array:
                builder.Append('[');
                for (var i = 0; i < array.Count; i++)
                {
                    if (i > 0) builder.Append(',');
                    Write(builder, array[i]);
                }
                builder.Append(']');
                break;
            default:
                switch (node.GetValueKind())
                {
                    case JsonValueKind.String:
                        WriteString(builder, node.GetValue<string>());
                        break;
                    case JsonValueKind.True:
                        builder.Append("true");
                        break;
                    case JsonValueKind.False:
                        builder.Append("false");
                        break;
                    case JsonValueKind.Null:
                        builder.Append("null");
                        break;
                    default:
                        // Numbers keep their literal text (integers stay integers).
                        builder.Append(node.ToJsonString());
                        break;
                }
                break;
        }
    }

    private static void WriteString(StringBuilder builder, string value)
    {
        builder.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '/': builder.Append("\\/"); break;
                case '\b': builder.Append("\\b"); break;
                case '\f': builder.Append("\\f"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                default:
                    if (c < 0x20) builder.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else builder.Append(c);
                    break;
            }
        }
        builder.Append('"');
    }

    /// <summary>Indented, sorted-key output for the files people may open (manifest.json, state.json, ...).</summary>
    public static string Pretty(JsonNode? node)
    {
        var builder = new StringBuilder();
        WritePretty(builder, node, 0);
        return builder.ToString();
    }

    private static void WritePretty(StringBuilder builder, JsonNode? node, int depth)
    {
        var pad = new string(' ', (depth + 1) * 2);
        var closePad = new string(' ', depth * 2);
        switch (node)
        {
            case JsonObject obj when obj.Count > 0:
                builder.Append("{\n");
                var first = true;
                foreach (var pair in obj.OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    if (!first) builder.Append(",\n");
                    first = false;
                    builder.Append(pad);
                    WriteString(builder, pair.Key);
                    builder.Append(" : ");
                    WritePretty(builder, pair.Value, depth + 1);
                }
                builder.Append('\n').Append(closePad).Append('}');
                break;
            case JsonArray array when array.Count > 0:
                builder.Append("[\n");
                for (var i = 0; i < array.Count; i++)
                {
                    if (i > 0) builder.Append(",\n");
                    builder.Append(pad);
                    WritePretty(builder, array[i], depth + 1);
                }
                builder.Append('\n').Append(closePad).Append(']');
                break;
            default:
                Write(builder, node);
                break;
        }
    }
}

public sealed class WorkspaceMemory
{
    private sealed class StoredIdentity
    {
        public string PersonID { get; set; } = "";
        public string DisplayName { get; set; } = "";
        public string PrivateKey { get; set; } = "";
        public string PublicKey { get; set; } = "";
        public string DeviceID { get; set; } = "";
        public string KeyID { get; set; } = "";
    }

    private sealed class TaskRecord
    {
        public string RunId = "";
        public string PromptSummary = "";
        public string PromptHash = "";
        public string StartedAt = "";
        public string Provider = "";
        public string Model = "";
        public List<JsonObject> ChangedFiles = new();
        public List<string> Tools = new();
    }

    private static readonly JsonSerializerOptions IdentityJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };

    private readonly object _gate = new();
    private readonly SupportPaths _paths;
    private string? _workspace;
    private StoredIdentity? _identity;
    private ECDsa? _key;
    private JsonObject? _manifest;
    private JsonObject _state = EmptyState();
    private List<JsonObject> _events = new();
    private readonly Dictionary<string, TaskRecord> _tasks = new(StringComparer.Ordinal);
    private string _mapText = "";

    public WorkspaceMemory(SupportPaths paths) => _paths = paths;

    public string? MemoryDirectory => _workspace is null ? null : Path.Combine(_workspace, ".mem");
    public string? ProjectId => _manifest?["projectId"]?.GetValue<string>();
    public int Revision => IntOf(_state["revision"]);
    public string? ActorPublicKey => _identity?.PublicKey;
    public (string PersonId, string DeviceId, string DisplayName)? Actor =>
        _identity is null ? null : (_identity.PersonID, _identity.DeviceID, _identity.DisplayName);

    // MARK: Workspace lifecycle

    public void SetWorkspace(string? path)
    {
        lock (_gate)
        {
            _workspace = string.IsNullOrWhiteSpace(path) ? null : Path.GetFullPath(path);
            _identity = null;
            _key?.Dispose();
            _key = null;
            _manifest = null;
            _state = EmptyState();
            _events = new();
            _tasks.Clear();
            _mapText = "";
            if (MemoryDirectory is { } root && Directory.Exists(root)) LoadExisting();
        }
    }

    public void Reload()
    {
        lock (_gate)
        {
            if (MemoryDirectory is not null) LoadExisting();
        }
    }

    /// <summary>
    /// Creates memory only when the first prompt is accepted; selecting a workspace or opening a blank
    /// chat never calls this. Memory is an audit layer: a storage failure must not stop the agent answering.
    /// </summary>
    public void PrepareForPrompt(string prompt, string runId, string provider, string model)
    {
        lock (_gate)
        {
            if (_workspace is null) return;
            try
            {
                EnsureIdentity();
                if (_manifest is null) InitializeWorkspace(); else LoadExisting();
                UpdateMapIfNeeded();
                BeginTask(runId, prompt, provider, model);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or WorkspaceMemoryException or JsonException or CryptographicException) { }
        }
    }

    // MARK: Prompt context

    public MemorySnapshot Snapshot(string prompt)
    {
        lock (_gate)
        {
            if (_manifest is null) return new MemorySnapshot("", 0);
            var decisions = MarkdownList(Items(_state["acceptedDecisions"]), "Decision");
            var proposals = MarkdownList(Items(_state["pendingProposals"]), "Proposal");
            var preferences = PreferencesText();
            var defaults = MarkdownDictionary(Obj(_state["projectDefaults"]));
            var tasks = RelevantTasks(prompt);
            var conversations = ConversationLifecycleText();
            var body = string.Join("\n", new[]
            {
                "Private project context. It is verified by the native host.",
                "Current user instructions are authoritative over this context.",
                $"Revision: {Revision}",
                $"\n## Project map\n{_mapText}",
                $"\n## Accepted project decisions\n{(decisions.Length == 0 ? "None" : decisions)}",
                $"\n## Current actor preferences\n{(preferences.Length == 0 ? "None" : preferences)}",
                $"\n## Project defaults\n{(defaults.Length == 0 ? "None" : defaults)}",
                $"\n## Relevant task history\n{(tasks.Length == 0 ? "None" : tasks)}",
                $"\n## Conversation lifecycle\n{(conversations.Length == 0 ? "None" : conversations)}",
                proposals.Length == 0 ? "" : $"\n## Unauthoritative proposals\n{proposals}",
            }.Where(part => part.Length > 0));
            return new MemorySnapshot(TrimSnapshot(body), Revision);
        }
    }

    // MARK: Access

    public WorkspaceAccessStatus AccessStatus()
    {
        lock (_gate)
        {
            var member = CurrentMember();
            return new WorkspaceAccessStatus(
                _identity?.PersonID ?? "",
                _identity?.DeviceID ?? "",
                MemoryRoles.Parse(StringOf(member?["role"])),
                IntOf(member?["score"]),
                Items(_state["members"]).Count,
                Items(_state["pendingProposals"]).Count,
                Revision,
                _manifest is not null);
        }
    }

    public IReadOnlyList<IReadOnlyDictionary<string, string>> MemberSummaries()
    {
        lock (_gate)
        {
            return Items(_state["members"])
                .Where(m => StringOf(m["personId"]) is not null && StringOf(m["deviceId"]) is not null)
                .Select(m => (IReadOnlyDictionary<string, string>)new Dictionary<string, string>
                {
                    ["personId"] = StringOf(m["personId"])!,
                    ["deviceId"] = StringOf(m["deviceId"])!,
                    ["displayName"] = StringOf(m["displayName"]) ?? "",
                    ["role"] = StringOf(m["role"]) ?? MemoryRole.Observer.Wire(),
                    ["score"] = IntOf(m["score"]).ToString(CultureInfo.InvariantCulture),
                    ["revoked"] = (m["revoked"]?.GetValue<bool>() ?? false) ? "true" : "false",
                }).ToList();
        }
    }

    /// <summary>The pending proposals, as event objects (payload.summary carries the text).</summary>
    public IReadOnlyList<JsonObject> PendingDecisions()
    {
        lock (_gate) return Items(_state["pendingProposals"]).Select(o => (JsonObject)o.DeepClone()).ToList();
    }

    /// <summary>An invitation token for another device; only an owner can issue one.</summary>
    public string CreateInvite(string displayName, string publicKey, MemoryRole role = MemoryRole.Contributor, int score = 50, string? personId = null)
    {
        lock (_gate)
        {
            if (!CanWrite(MemoryRole.Owner) || _identity is null) throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.Unauthorized);
            var payload = new JsonObject
            {
                ["schemaVersion"] = 1,
                ["projectId"] = ProjectId ?? "",
                ["personId"] = personId ?? Guid.NewGuid().ToString().ToUpperInvariant(),
                ["displayName"] = Sanitize(displayName, 80),
                ["role"] = role.Wire(),
                ["score"] = Math.Max(0, Math.Min(100, score)),
                ["publicKey"] = publicKey,
                ["invitedBy"] = _identity.PersonID,
                ["createdAt"] = IsoNow(),
            };
            var eventId = WriteEvent("member.invited", "device", (JsonObject)payload.DeepClone());
            payload["eventId"] = eventId;
            payload["actor"] = ActorObject();
            var signed = Signed(payload);
            return Convert.ToBase64String(CanonicalJson.Bytes(signed));
        }
    }

    public void AcceptInvite(string token)
    {
        lock (_gate)
        {
            EnsureIdentity();
            // The invitation event was written by another device: pick it up first, both so the acceptance can
            // be verified against it and so this event's lamport clock lands after it.
            if (_manifest is not null) LoadExisting();
            JsonObject invitation;
            try
            {
                invitation = JsonNode.Parse(Convert.FromBase64String(token.Trim())) as JsonObject
                    ?? throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.InvalidInvitation);
            }
            catch (Exception e) when (e is FormatException or JsonException)
            {
                throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.InvalidInvitation);
            }
            var publicKey = StringOf(invitation["publicKey"]);
            if (StringOf(invitation["projectId"]) is not { } project || project != ProjectId
                || publicKey is null || publicKey != _identity?.PublicKey)
                throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.InvalidInvitation);
            var signature = StringOf((invitation["signature"] as JsonObject)?["value"]);
            if (signature is null || RootPublicKey() is not { } root || !Verify(signature, WithoutSignature(invitation), root))
                throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.InvalidInvitation);
            WriteEvent("member.accepted", "device", new JsonObject
            {
                ["personId"] = invitation["personId"]?.DeepClone(),
                ["deviceId"] = _identity!.DeviceID,
                ["displayName"] = invitation["displayName"]?.DeepClone(),
                ["role"] = invitation["role"]?.DeepClone(),
                ["score"] = invitation["score"]?.DeepClone(),
                ["publicKey"] = publicKey,
            });
        }
    }

    /// <summary>A lasting actor preference; a later value under the same key supersedes the earlier one.</summary>
    public void SetPreference(string key, string value)
    {
        lock (_gate)
        {
            if (_identity is null) throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.NoWorkspace);
            WriteEvent("preference.set", "person", new JsonObject
            {
                ["personId"] = _identity.PersonID,
                ["key"] = Sanitize(key, 60),
                ["value"] = Sanitize(value, 240),
            });
        }
    }

    /// <summary>A project-wide fact. Writable by an owner or approver, which is what the vault's creator already is.</summary>
    public void SetProjectDefault(string key, string value)
    {
        lock (_gate)
        {
            WriteEvent("project.default.set", "project", new JsonObject
            {
                ["key"] = Sanitize(key, 60),
                ["value"] = Sanitize(value, 240),
            });
        }
    }

    public bool HasProjectBrief
    {
        get { lock (_gate) return Obj(_state["projectDefaults"]).Count > 0; }
    }

    public void ProposeDecision(string summary, JsonObject? details = null)
    {
        lock (_gate)
        {
            if (!CanWrite(MemoryRole.Contributor)) throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.Unauthorized);
            var payload = (JsonObject?)details?.DeepClone() ?? new JsonObject();
            payload["summary"] = Sanitize(summary, 240);
            WriteEvent("decision.proposed", "project", payload);
        }
    }

    public void Revoke(string deviceId)
    {
        lock (_gate)
        {
            if (!CanWrite(MemoryRole.Owner)) throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.Unauthorized);
            WriteEvent("member.revoked", "device", new JsonObject { ["deviceId"] = deviceId });
        }
    }

    public void UpdateMember(string deviceId, MemoryRole role, int score, string? displayName = null)
    {
        lock (_gate)
        {
            if (!CanWrite(MemoryRole.Owner)) throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.Unauthorized);
            var payload = new JsonObject
            {
                ["deviceId"] = deviceId,
                ["role"] = role.Wire(),
                ["score"] = Math.Max(0, Math.Min(100, score)),
            };
            if (displayName is not null) payload["displayName"] = Sanitize(displayName, 80);
            WriteEvent("member.updated", "device", payload);
        }
    }

    public void ResolveDecision(string eventId, bool accept)
    {
        lock (_gate)
        {
            if (!CanWrite(MemoryRole.Approver)) throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.Unauthorized);
            var proposal = Items(_state["pendingProposals"]).FirstOrDefault(p => StringOf(p["eventId"]) == eventId);
            if (proposal is null) return;
            if (accept)
                WriteEvent("decision.accepted", "project", (JsonObject)proposal.DeepClone(),
                    supersedes: StringList(proposal["supersedes"]));
            else
                WriteEvent("decision.rejected", "project", new JsonObject { ["proposalEventId"] = eventId });
        }
    }

    // MARK: Task recording

    public (string Path, string? Hash, int Bytes)? FileHash(string toolName, string arguments, string workspace)
    {
        if (toolName != "write_file" || ParseArguments(arguments) is not { } args
            || StringOf(args["path"]) is not { } rawPath || SafeWorkspacePath(rawPath, workspace) is not { } file) return null;
        try
        {
            var data = File.ReadAllBytes(file);
            return (SafePath(rawPath), Digest(data), data.Length);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (SafePath(rawPath), null, 0);
        }
    }

    public HashSet<string> ChangedGitPaths(string workspace)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            var start = new ProcessStartInfo("git")
            {
                WorkingDirectory = workspace,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (var argument in new[] { "status", "--porcelain", "--untracked-files=all" }) start.ArgumentList.Add(argument);
            using var process = Process.Start(start);
            if (process is null) return result;
            var errors = process.StandardError.ReadToEndAsync();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            _ = errors.GetAwaiter().GetResult();
            if (process.ExitCode != 0) return result;
            foreach (var line in output.Split('\n').Select(l => l.TrimEnd('\r')))
            {
                // "XY path" - two status columns, a space, then the path (which may be quoted).
                if (line.Length > 3) result.Add(SafePath(line[3..].Trim('"')));
            }
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException or InvalidOperationException) { }
        return result;
    }

    public void RecordTool(
        string runId, string toolName, string arguments, string result,
        (string Path, string? Hash, int Bytes)? beforeFile, HashSet<string> beforeGit, string workspace)
    {
        lock (_gate)
        {
            if (!_tasks.TryGetValue(runId, out var task)) return;
            var args = ParseArguments(arguments) ?? new JsonObject();
            var path = StringOf(args["path"]);
            try
            {
                WriteEvent("tool.executed", "task", new JsonObject
                {
                    ["runId"] = runId,
                    ["name"] = toolName,
                    ["path"] = path is null ? null : SafePath(path),
                    ["commandSummary"] = toolName == "run_command" ? Sanitize(StringOf(args["command"]) ?? "", 160) : null,
                    ["resultStatus"] = result.Contains("error", StringComparison.OrdinalIgnoreCase) ? "failed" : "completed",
                    ["resultBytes"] = Encoding.UTF8.GetByteCount(result),
                });
                task.Tools.Add(toolName);

                if (beforeFile is { } before && SafeWorkspacePath(path ?? "", workspace) is { } afterFile)
                {
                    byte[]? after = null;
                    try { after = File.ReadAllBytes(afterFile); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
                    var change = new JsonObject
                    {
                        ["runId"] = runId,
                        ["path"] = before.Path,
                        ["operation"] = "modified",
                        ["beforeHash"] = before.Hash,
                        ["afterHash"] = after is null ? null : Digest(after),
                        ["beforeBytes"] = before.Bytes,
                        ["afterBytes"] = after?.Length ?? 0,
                        ["attribution"] = "write_file",
                    };
                    WriteEvent("file.changed", "task", (JsonObject)change.DeepClone());
                    task.ChangedFiles.Add(change);
                }

                foreach (var changedPath in ChangedGitPaths(workspace).Except(beforeGit).OrderBy(p => p, StringComparer.Ordinal))
                {
                    var change = new JsonObject
                    {
                        ["runId"] = runId,
                        ["path"] = changedPath,
                        ["operation"] = "modified",
                        ["attribution"] = "unattributed-shell-change",
                    };
                    WriteEvent("file.changed", "task", (JsonObject)change.DeepClone());
                    task.ChangedFiles.Add(change);
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or WorkspaceMemoryException) { }
        }
    }

    public void RecordPrompt(string runId, string prompt)
    {
        lock (_gate)
        {
            if (!_tasks.TryGetValue(runId, out var task)) return;
            task.PromptSummary = Sanitize(prompt, 240);
            task.PromptHash = Digest(Encoding.UTF8.GetBytes(prompt));
        }
    }

    public void FinishTask(string runId, bool success, string finalText = "")
    {
        lock (_gate)
        {
            if (!_tasks.Remove(runId, out var task)) return;
            var open = OpenItems(finalText);
            var status = success ? (open.Count == 0 ? "completed" : "unfinished") : "failed";
            CloseBacklog(finalText);
            // A run that read nothing and changed nothing is chat, not work; its note would still be
            // injected into later prompts, so recording it costs every later turn.
            var didWork = task.Tools.Count > 0 || task.ChangedFiles.Count > 0;
            try
            {
                if (didWork || open.Count > 0)
                {
                    WriteEvent($"task.{status}", "task", new JsonObject
                    {
                        ["runId"] = task.RunId,
                        ["status"] = status,
                        ["promptSummary"] = task.PromptSummary,
                        ["promptHash"] = task.PromptHash,
                        ["changedFiles"] = new JsonArray(task.ChangedFiles.Select(c => (JsonNode?)c.DeepClone()).ToArray()),
                        ["toolCount"] = task.Tools.Count,
                        ["semanticStatus"] = "pending",
                    });
                    WriteTaskNote(task, status, finalText, open);
                }
                var language = ExplicitLanguage(task.PromptSummary);
                var decision = ExplicitDecision(task.PromptSummary);
                if (language is not null && _identity is not null)
                {
                    WriteEvent("preference.set", "person", new JsonObject
                    {
                        ["personId"] = _identity.PersonID,
                        ["key"] = "language",
                        ["value"] = language,
                        ["source"] = "explicit-user-instruction",
                    });
                }
                if (decision is not null)
                {
                    WriteEvent("decision.proposed", "project", new JsonObject
                    {
                        ["summary"] = decision,
                        ["source"] = "explicit-user-instruction",
                        ["runId"] = runId,
                    });
                }
                WriteEvent("semantic.completed", "task", new JsonObject
                {
                    ["runId"] = runId,
                    ["status"] = "completed",
                    ["preferenceUpdated"] = language is not null,
                    ["decisionProposed"] = decision is not null,
                });
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or WorkspaceMemoryException) { }
        }
    }

    /// <summary>Chat lifecycle is kept apart from task outcome so archive/delete stays visible without changing a task's result.</summary>
    public void RecordConversationLifecycle(string conversationId, string title, ConversationLifecycleState state)
    {
        lock (_gate)
        {
            if (_manifest is null || conversationId.Length == 0) return;
            TryWrite("conversation." + state.ToString().ToLowerInvariant(), "conversation", new JsonObject
            {
                ["conversationId"] = conversationId,
                ["title"] = Sanitize(title, 120),
            });
        }
    }

    public void RecordConversationRewind(
        string conversationId, string title, string beforeMessageId,
        IReadOnlyList<string> restoredPaths, IReadOnlyList<string> conflictPaths)
    {
        lock (_gate)
        {
            if (_manifest is null || conversationId.Length == 0) return;
            TryWrite("conversation.rewound", "conversation", new JsonObject
            {
                ["conversationId"] = conversationId,
                ["title"] = Sanitize(title, 120),
                ["beforeMessageId"] = beforeMessageId,
                ["restoredPaths"] = new JsonArray(restoredPaths.Select(p => (JsonNode?)p).ToArray()),
                ["conflictPaths"] = new JsonArray(conflictPaths.Select(p => (JsonNode?)p).ToArray()),
            });
        }
    }

    private void TryWrite(string type, string scope, JsonObject payload)
    {
        try { WriteEvent(type, scope, payload); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or WorkspaceMemoryException) { }
    }

    // MARK: Loading, identity, initialization

    private void LoadExisting()
    {
        var root = MemoryDirectory!;
        JsonObject? loaded;
        try { loaded = JsonNode.Parse(File.ReadAllText(Path.Combine(root, "manifest.json"))) as JsonObject; }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return; }
        if (loaded is null || IntOf(loaded["schemaVersion"]) != 1 || loaded["projectId"] is not JsonValue
            || loaded["rootAuthority"] is not JsonObject) return;
        _manifest = loaded;
        try { EnsureIdentity(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException or JsonException) { }
        // macOS writes state.json without a schemaVersion, so the cache is never trusted: always rebuild.
        RebuildProjection();
        try { _mapText = File.ReadAllText(Path.Combine(root, "map.md")); } catch (IOException) { _mapText = ""; }
    }

    private void InitializeWorkspace()
    {
        var root = MemoryDirectory!;
        if (_identity is null) throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.NoWorkspace);
        Directory.CreateDirectory(root);
        foreach (var folder in new[] { "events", "tasks", "decisions", "conversations" })
            Directory.CreateDirectory(Path.Combine(root, folder));
        var projectId = Guid.NewGuid().ToString().ToUpperInvariant();
        _manifest = new JsonObject
        {
            ["schemaVersion"] = 1,
            ["projectId"] = projectId,
            ["workspaceRoot"] = _workspace ?? "",
            ["createdAt"] = IsoNow(),
            ["rootAuthority"] = new JsonObject
            {
                ["personId"] = _identity.PersonID,
                ["deviceId"] = _identity.DeviceID,
                ["publicKey"] = _identity.PublicKey,
                ["keyId"] = _identity.KeyID,
                ["algorithm"] = "P-256-SHA256",
            },
            ["revision"] = 0,
        };
        WriteJson(_manifest, Path.Combine(root, "manifest.json"));
        WriteEvent("workspace.initialized", "project", new JsonObject
        {
            ["projectId"] = projectId,
            ["personId"] = _identity.PersonID,
            ["deviceId"] = _identity.DeviceID,
            ["displayName"] = _identity.DisplayName,
            ["role"] = MemoryRole.Owner.Wire(),
            ["score"] = 100,
            ["publicKey"] = _identity.PublicKey,
        });
    }

    /// <summary>The device identity: one P-256 key pair per installation, kept beside the app data with user-only permissions.</summary>
    private void EnsureIdentity()
    {
        if (_identity is not null && _key is not null) return;
        _paths.Ensure();
        var file = Path.Combine(_paths.Root, "memory-identity.json");
        try
        {
            if (File.Exists(file)
                && JsonSerializer.Deserialize<StoredIdentity>(File.ReadAllText(file), IdentityJson) is { } stored
                && LoadKey(stored) is { } key)
            {
                _identity = stored;
                _key = key;
                return;
            }
        }
        catch (Exception e) when (e is IOException or JsonException or CryptographicException or FormatException) { }

        var created = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var parameters = created.ExportParameters(includePrivateParameters: true);
        var publicRaw = parameters.Q.X!.Concat(parameters.Q.Y!).ToArray();
        var deviceId = Digest(publicRaw);
        var identity = new StoredIdentity
        {
            PersonID = Guid.NewGuid().ToString().ToUpperInvariant(),
            DisplayName = string.IsNullOrEmpty(Environment.UserName) ? "User" : Environment.UserName,
            PrivateKey = Convert.ToBase64String(parameters.D!),
            PublicKey = Convert.ToBase64String(publicRaw),
            DeviceID = deviceId,
            KeyID = "device-" + deviceId[..16],
        };
        Directory.CreateDirectory(_paths.Root);
        File.WriteAllText(file, JsonSerializer.Serialize(identity, IdentityJson));
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        _identity = identity;
        _key = created;
    }

    private static ECDsa? LoadKey(StoredIdentity stored)
    {
        var d = Convert.FromBase64String(stored.PrivateKey);
        var publicRaw = Convert.FromBase64String(stored.PublicKey);
        if (d.Length != 32 || publicRaw.Length != 64) return null;
        return ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            D = d,
            Q = new ECPoint { X = publicRaw[..32], Y = publicRaw[32..] },
        });
    }

    private static ECDsa? PublicKeyFrom(string base64)
    {
        try
        {
            var raw = Convert.FromBase64String(base64);
            if (raw.Length != 64) return null;
            return ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = raw[..32], Y = raw[32..] },
            });
        }
        catch (Exception e) when (e is FormatException or CryptographicException) { return null; }
    }

    // MARK: Project map

    private void UpdateMapIfNeeded()
    {
        if (_workspace is null || MemoryDirectory is not { } root) return;
        var structure = MapStructure(_workspace);
        var fingerprint = Digest(Encoding.UTF8.GetBytes(structure.Fingerprint));
        var indexFile = Path.Combine(root, "index.json");
        try
        {
            if (JsonNode.Parse(File.ReadAllText(indexFile)) is JsonObject index && StringOf(index["fingerprint"]) == fingerprint)
            {
                try { _mapText = File.ReadAllText(Path.Combine(root, "map.md")); } catch (IOException) { }
                return;
            }
        }
        catch (Exception e) when (e is IOException or JsonException) { }

        _mapText = structure.Markdown;
        WriteJson(new JsonObject
        {
            ["schemaVersion"] = 1,
            ["fingerprint"] = fingerprint,
            ["updatedAt"] = IsoNow(),
            ["topLevel"] = new JsonArray(structure.TopLevel.Select(t => (JsonNode?)t).ToArray()),
            ["manifests"] = new JsonArray(structure.Manifests.Select(m => (JsonNode?)m).ToArray()),
        }, indexFile);
        var front = Frontmatter(new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["id"] = "map", ["type"] = "map", ["title"] = "Project map", ["updated"] = IsoNow(),
        }, ["map"], ["index"]);
        File.WriteAllText(Path.Combine(root, "map.md"), front + "\n" + structure.Markdown + "\n\nBack to [[index]]\n");
        var mapRevision = IntOf(_state["lastMapRevision"]) + 1;
        TryWrite("map.updated", "project", new JsonObject { ["revision"] = mapRevision, ["fingerprint"] = fingerprint });
        WriteIndexNote();
    }

    private static readonly HashSet<string> MapIgnored = new(StringComparer.Ordinal)
    {
        ".git", ".mem", "node_modules", "vendor", "build", "dist", ".build", "bin", "obj", "target",
    };

    private static readonly HashSet<string> BinaryExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "app", "bin", "dmg", "exe", "dll", "dylib", "so", "zip", "gz", "7z", "png", "jpg", "jpeg", "gif", "webp", "pdf", "mp3", "mp4", "mov", "wav",
    };

    private static (string Fingerprint, string Markdown, List<string> TopLevel, List<string> Manifests) MapStructure(string workspace)
    {
        var topLevel = new List<string>();
        var manifests = new List<string>();
        var fingerprint = new List<string>();
        IEnumerable<FileSystemInfo> entries;
        try { entries = new DirectoryInfo(workspace).EnumerateFileSystemInfos().OrderBy(e => e.Name, StringComparer.Ordinal).ToList(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { entries = Array.Empty<FileSystemInfo>(); }
        foreach (var entry in entries)
        {
            var name = entry.Name;
            if (name.StartsWith('.') || MapIgnored.Contains(name)) continue; // hidden files are skipped, as on macOS
            var directory = entry is DirectoryInfo;
            var large = entry is FileInfo file && file.Length > 1_000_000;
            if (!directory && (large || BinaryExtensions.Contains(System.IO.Path.GetExtension(name).TrimStart('.'))))
            {
                fingerprint.Add($"{name}:ignored");
                continue;
            }
            topLevel.Add(directory ? name + "/" : name);
            fingerprint.Add($"{name}:{(directory ? "d" : "f")}");
            if (IsManifest(name)) manifests.Add(name);
        }
        manifests.Sort(StringComparer.Ordinal);
        var language = manifests.Contains("Package.swift") ? "Swift" : "Unknown";
        var lines = new List<string> { "# Project Map", "", "## Workspace", "", $"- Root: `{workspace}`", $"- Primary language: {language}", "", "## Top-level", "" };
        lines.AddRange(topLevel.Select(t => $"- `{t}`"));
        lines.AddRange(new[] { "", "## Important files", "" });
        lines.AddRange(manifests.Select(m => $"- `{m}`"));
        lines.AddRange(new[]
        {
            "", "## Guidance", "",
            "- Source files and task history are selected by the native host as needed.",
            "- The private project context is not exposed through workspace file tools.",
        });
        return (string.Join("\n", fingerprint), string.Join("\n", lines), topLevel, manifests);
    }

    private static bool IsManifest(string name) =>
        new[] { "Package.swift", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "pom.xml", "build.gradle", "Makefile", "README.md", "CONTRACT.md" }.Contains(name)
        || name.EndsWith(".csproj", StringComparison.Ordinal) || name.EndsWith(".sln", StringComparison.Ordinal);

    // MARK: Projection

    private void RebuildProjection()
    {
        _state = EmptyState();
        _events = new();
        var root = MemoryDirectory!;
        var eventsDirectory = Path.Combine(root, "events");
        if (!Directory.Exists(eventsDirectory)) return;
        var candidates = new List<JsonObject>();
        foreach (var file in Directory.EnumerateFiles(eventsDirectory, "*.json"))
        {
            try { if (JsonNode.Parse(File.ReadAllText(file)) is JsonObject obj) candidates.Add(obj); }
            catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
        }
        candidates = candidates
            .OrderBy(e => IntOf(e["lamport"]))
            .ThenBy(e => StringOf(e["eventId"]) ?? "", StringComparer.Ordinal)
            .ToList();
        var valid = new HashSet<string>(StringComparer.Ordinal);
        foreach (var candidate in candidates)
        {
            if (!VerifyEvent(candidate)) continue;
            if (!StringList(candidate["parents"]).All(valid.Contains)) continue;
            _events.Add(candidate);
            if (StringOf(candidate["eventId"]) is { } id) valid.Add(id);
            Apply(candidate);
        }
        if (_events.Count > 0 && _events[^1]["lamport"] is JsonNode lamport)
        {
            var revision = IntOf(lamport);
            _state["revision"] = revision;
            if (_manifest is not null)
            {
                _manifest["revision"] = revision;
                TryWriteJson(_manifest, Path.Combine(root, "manifest.json"));
            }
        }
        TryWriteJson(_state, Path.Combine(root, "state.json"));
        WriteDecisionNotes();
        WriteConversationNotes();
        WriteIndexNote();
        WritePreferencesNote();
    }

    private bool VerifyEvent(JsonObject e)
    {
        if (IntOf(e["schemaVersion"]) != 1 || StringOf(e["projectId"]) != ProjectId
            || e["actor"] is not JsonObject actor || StringOf(actor["publicKey"]) is not { } publicKey
            || StringOf((e["signature"] as JsonObject)?["value"]) is not { } signature) return false;
        byte[] keyBytes;
        try { keyBytes = Convert.FromBase64String(publicKey); }
        catch (FormatException) { return false; }
        using var key = PublicKeyFrom(publicKey);
        if (key is null || !Verify(signature, WithoutSignature(e), key)) return false;
        if (StringOf(actor["deviceId"]) is not { } deviceId || Digest(keyBytes) != deviceId) return false;
        if (deviceId == RootDeviceId()) return publicKey == RootPublicKeyString();
        if (StringOf(e["type"]) == "member.accepted")
        {
            if (e["payload"] is not JsonObject payload || StringOf(payload["publicKey"]) != publicKey
                || StringOf(payload["deviceId"]) != deviceId) return false;
            return _events.Any(existing => StringOf(existing["type"]) == "member.invited"
                && StringOf((existing["payload"] as JsonObject)?["publicKey"]) == publicKey
                && StringOf((existing["payload"] as JsonObject)?["personId"]) == StringOf(payload["personId"]));
        }
        return Member(deviceId)?["revoked"]?.GetValue<bool>() != true;
    }

    private void Apply(JsonObject e)
    {
        if (StringOf(e["type"]) is not { } type || e["payload"] is not JsonObject payload) return;
        switch (type)
        {
            case "workspace.initialized":
            case "member.accepted":
                UpsertMember(payload);
                if (type == "member.accepted")
                {
                    var personId = StringOf(payload["personId"]);
                    _state["pendingProposals"] = new JsonArray(Items(_state["pendingProposals"])
                        .Where(p => StringOf((p["payload"] as JsonObject)?["personId"]) == personId ? false : true)
                        .Select(p => (JsonNode?)p.DeepClone()).ToArray());
                }
                break;
            case "member.revoked":
                if (StringOf(payload["deviceId"]) is { } revoked) SetMember(revoked, "revoked", JsonValue.Create(true));
                break;
            case "member.updated":
                if (StringOf(payload["deviceId"]) is { } updated)
                {
                    foreach (var key in new[] { "role", "score", "displayName" })
                        if (payload[key] is { } value) SetMember(updated, key, value.DeepClone());
                }
                break;
            case "preference.set":
                {
                    if (StringOf(payload["personId"]) is not { } personId || StringOf(payload["key"]) is not { } key) return;
                    var all = Obj(_state["activePreferences"]);
                    var preferences = all[personId] as JsonObject ?? new JsonObject();
                    if (preferences[key] is { } old)
                    {
                        var superseded = Items(_state["supersededValues"]).Select(o => (JsonNode?)o.DeepClone()).ToList();
                        superseded.Add(new JsonObject
                        {
                            ["key"] = key, ["value"] = old.DeepClone(), ["personId"] = personId, ["eventId"] = e["eventId"]?.DeepClone(),
                        });
                        _state["supersededValues"] = new JsonArray(superseded.ToArray());
                    }
                    preferences[key] = payload["value"]?.DeepClone();
                    all[personId] = preferences;
                    _state["activePreferences"] = all;
                    break;
                }
            case "project.default.set":
                {
                    var defaults = Obj(_state["projectDefaults"]);
                    if (StringOf(payload["key"]) is { } key) defaults[key] = payload["value"]?.DeepClone();
                    _state["projectDefaults"] = defaults;
                    break;
                }
            case "decision.proposed":
                {
                    var proposals = Items(_state["pendingProposals"]).Select(o => (JsonNode?)o.DeepClone()).ToList();
                    proposals.Add(e.DeepClone());
                    _state["pendingProposals"] = new JsonArray(proposals.ToArray());
                    break;
                }
            case "decision.accepted":
                ApplyAccepted(e, payload);
                break;
            case "decision.rejected":
                _state["pendingProposals"] = new JsonArray(Items(_state["pendingProposals"])
                    .Where(p => StringOf(p["eventId"]) != StringOf(payload["proposalEventId"]))
                    .Select(p => (JsonNode?)p.DeepClone()).ToArray());
                break;
            case "map.updated":
                _state["lastMapRevision"] = payload["revision"] is JsonNode revision ? IntOf(revision) : IntOf(_state["lastMapRevision"]);
                break;
            case "conversation.archived":
            case "conversation.restored":
            case "conversation.deleted":
                {
                    if (StringOf(payload["conversationId"]) is not { } conversationId) return;
                    var conversations = Obj(_state["conversationStates"]);
                    conversations[conversationId] = new JsonObject
                    {
                        ["conversationId"] = conversationId,
                        ["title"] = StringOf(payload["title"]) ?? conversationId,
                        ["state"] = type["conversation.".Length..],
                        ["eventId"] = StringOf(e["eventId"]) ?? "",
                        ["updatedAt"] = StringOf(e["createdAt"]) ?? "",
                        ["revision"] = IntOf(e["lamport"]),
                    };
                    _state["conversationStates"] = conversations;
                    break;
                }
        }
    }

    private void ApplyAccepted(JsonObject e, JsonObject payload)
    {
        var accepted = Items(_state["acceptedDecisions"]).Select(o => (JsonObject)o.DeepClone()).ToList();
        var key = DecisionKey(e);
        var index = accepted.FindIndex(d => DecisionKey(d) == key);
        var supersededValues = Items(_state["supersededValues"]).Select(o => (JsonNode?)o.DeepClone()).ToList();
        if (index >= 0)
        {
            var old = accepted[index];
            if (!EventWins(e, old))
            {
                supersededValues.Add(new JsonObject { ["eventId"] = e["eventId"]?.DeepClone(), ["supersededBy"] = old["eventId"]?.DeepClone(), ["reason"] = "authority" });
                _state["supersededValues"] = new JsonArray(supersededValues.ToArray());
                return;
            }
            accepted[index] = (JsonObject)e.DeepClone();
            supersededValues.Add(new JsonObject { ["eventId"] = old["eventId"]?.DeepClone(), ["supersededBy"] = e["eventId"]?.DeepClone(), ["reason"] = "authority" });
            _state["supersededValues"] = new JsonArray(supersededValues.ToArray());
        }
        else
        {
            accepted.Add((JsonObject)e.DeepClone());
        }
        var superseded = StringList(e["supersedes"]).ToHashSet(StringComparer.Ordinal);
        _state["acceptedDecisions"] = new JsonArray(accepted.Where(d => !superseded.Contains(StringOf(d["eventId"]) ?? "")).Select(d => (JsonNode?)d).ToArray());
        _state["pendingProposals"] = new JsonArray(Items(_state["pendingProposals"])
            .Where(p => StringOf(p["eventId"]) != StringOf(payload["eventId"]))
            .Select(p => (JsonNode?)p.DeepClone()).ToArray());
    }

    /// <returns>The new event's id.</returns>
    private string WriteEvent(string type, string scope, JsonObject payload, IReadOnlyList<string>? supersedes = null)
    {
        if (MemoryDirectory is not { } root || _identity is null || _key is null || ProjectId is not { } projectId)
            throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.NoWorkspace);
        if (!CanWrite(type)) throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.Unauthorized);
        var eventId = Guid.NewGuid().ToString().ToUpperInvariant();
        var lamport = Math.Max(Revision, _events.Select(ev => IntOf(ev["lamport"])).DefaultIfEmpty(0).Max()) + 1;
        var parents = _events.Count > 0 && StringOf(_events[^1]["eventId"]) is { } last ? new[] { last } : System.Array.Empty<string>();
        var obj = new JsonObject
        {
            ["schemaVersion"] = 1,
            ["eventId"] = eventId,
            ["type"] = type,
            ["scope"] = scope,
            ["projectId"] = projectId,
            ["actor"] = ActorObject(),
            ["lamport"] = lamport,
            ["createdAt"] = IsoNow(),
            ["parents"] = new JsonArray(parents.Select(p => (JsonNode?)p).ToArray()),
            ["supersedes"] = new JsonArray((supersedes ?? System.Array.Empty<string>()).Select(s => (JsonNode?)s).ToArray()),
            ["payload"] = payload,
        };
        var signed = Signed(obj);
        Directory.CreateDirectory(Path.Combine(root, "events"));
        WriteJson(signed, Path.Combine(root, "events", eventId + ".json"));
        // The new event has the highest lamport, so applying it in place equals a full rebuild.
        _events.Add(signed);
        Apply(signed);
        _state["revision"] = lamport;
        if (_manifest is not null)
        {
            _manifest["revision"] = lamport;
            TryWriteJson(_manifest, Path.Combine(root, "manifest.json"));
        }
        TryWriteJson(_state, Path.Combine(root, "state.json"));
        WriteDecisionNotes();
        WriteConversationNotes();
        WriteIndexNote();
        WritePreferencesNote();
        return eventId;
    }

    private JsonObject ActorObject() => new()
    {
        ["personId"] = _identity!.PersonID,
        ["deviceId"] = _identity.DeviceID,
        ["keyId"] = _identity.KeyID,
        ["publicKey"] = _identity.PublicKey,
    };

    private JsonObject Signed(JsonObject obj)
    {
        if (_key is null) throw new WorkspaceMemoryException(WorkspaceMemoryErrorKind.Unauthorized);
        var signature = _key.SignData(CanonicalJson.Bytes(obj), HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        var result = (JsonObject)obj.DeepClone();
        result["signature"] = new JsonObject { ["algorithm"] = "P-256-SHA256", ["value"] = Convert.ToBase64String(signature) };
        return result;
    }

    private static bool Verify(string signature, JsonObject obj, ECDsa key)
    {
        try
        {
            return key.VerifyData(CanonicalJson.Bytes(obj), Convert.FromBase64String(signature), HashAlgorithmName.SHA256,
                DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        }
        catch (Exception e) when (e is FormatException or CryptographicException) { return false; }
    }

    private static JsonObject WithoutSignature(JsonObject obj)
    {
        var copy = (JsonObject)obj.DeepClone();
        copy.Remove("signature");
        return copy;
    }

    // MARK: Notes

    private void BeginTask(string runId, string prompt, string provider, string model)
    {
        var task = new TaskRecord
        {
            RunId = runId,
            PromptSummary = Sanitize(prompt, 240),
            PromptHash = Digest(Encoding.UTF8.GetBytes(prompt)),
            StartedAt = IsoNow(),
            Provider = provider,
            Model = model,
        };
        _tasks[runId] = task;
        TryWrite("task.started", "task", new JsonObject
        {
            ["runId"] = task.RunId,
            ["promptSummary"] = task.PromptSummary,
            ["promptHash"] = task.PromptHash,
            ["startedAt"] = task.StartedAt,
            ["provider"] = Sanitize(provider, 80),
            ["model"] = Sanitize(model, 120),
            ["memoryRevision"] = Revision,
        });
    }

    private void WriteTaskNote(TaskRecord task, string status, string finalText, IReadOnlyList<string> openItems)
    {
        if (MemoryDirectory is not { } root) return;
        var changedPaths = task.ChangedFiles.Select(c => StringOf(c["path"])).Where(p => p is not null).Select(p => p!).ToList();
        var fileLinks = changedPaths.Select(p => $"file:{p}").ToList();
        var decisionLinks = Items(_state["acceptedDecisions"])
            .Where(d => DecisionRunId(d) == task.RunId)
            .Select(d => StringOf(d["eventId"]))
            .Where(id => id is not null)
            .Select(id => $"decision-{id}")
            .ToList();
        var links = new[] { "index" }.Concat(decisionLinks).Concat(fileLinks).ToList();
        var front = Frontmatter(new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["id"] = $"task-{task.RunId}",
            ["type"] = "task",
            ["title"] = Quoted(task.PromptSummary, 120),
            ["created"] = task.StartedAt,
            ["completed"] = IsoNow(),
            ["revision"] = Revision.ToString(CultureInfo.InvariantCulture),
            ["actor"] = _identity?.PersonID ?? "unknown",
            ["status"] = status,
        }, ["task", status], links);
        var filesBlock = changedPaths.Count == 0 ? "- None recorded" : string.Join("\n", changedPaths.Select(p => $"- [[file:{p}]] — modified"));
        var decisionsBlock = decisionLinks.Count == 0
            ? "- Decisions remain event-backed and are not edited by the model."
            : string.Join("\n", decisionLinks.Select(l => $"- [[{l}]]"));
        var note = string.Join("\n", new[]
        {
            front,
            $"# Task: {task.RunId}",
            "",
            "Back to [[index]] · [[map]]",
            "",
            $"- Actor: {_identity?.PersonID ?? "unknown"}",
            $"- Device: {_identity?.DeviceID ?? "unknown"}",
            $"- Started: {task.StartedAt}",
            $"- Completed: {IsoNow()}",
            $"- Status: {status}",
            "",
            "## Request summary",
            "",
            task.PromptSummary,
            "",
            "## Changed files",
            "",
            filesBlock,
            "",
            "## Result",
            "",
            Sanitize(finalText, 600),
            "",
            "## Open items",
            "",
            openItems.Count == 0 ? "- None" : string.Join("\n", openItems.Select(i => $"- [ ] {i}")),
            "",
            "## Decisions",
            "",
            decisionsBlock,
        });
        Directory.CreateDirectory(Path.Combine(root, "tasks"));
        File.WriteAllText(Path.Combine(root, "tasks", task.RunId + ".md"), note);
        WriteIndexNote();
        WritePreferencesNote();
    }

    private void WriteDecisionNotes()
    {
        if (MemoryDirectory is not { } root) return;
        Directory.CreateDirectory(Path.Combine(root, "decisions"));
        foreach (var decision in Items(_state["acceptedDecisions"]))
        {
            if (StringOf(decision["eventId"]) is not { } eventId) continue;
            var payload = decision["payload"] as JsonObject ?? new JsonObject();
            var summary = SummaryOf(payload) ?? "Accepted project decision";
            var supersedes = StringList(decision["supersedes"]).Select(s => $"decision-{s}").ToList();
            var runId = DecisionRunId(decision);
            var taskLink = runId is null ? null : $"task-{runId}";
            var links = new[] { "index" }.Concat(supersedes).Concat(taskLink is null ? System.Array.Empty<string>() : new[] { taskLink }).ToList();
            var actor = StringOf((decision["actor"] as JsonObject)?["personId"]) ?? "unknown";
            var front = Frontmatter(new SortedDictionary<string, string>(StringComparer.Ordinal)
            {
                ["id"] = $"decision-{eventId}",
                ["type"] = "decision",
                ["title"] = Quoted(summary, 120),
                ["status"] = "accepted",
                ["revision"] = IntOf(decision["lamport"]).ToString(CultureInfo.InvariantCulture),
                ["actor"] = actor,
            }, ["decision", "accepted"], links);
            var related = supersedes.Count == 0 ? "" : "\n## Supersedes\n\n" + string.Join("\n", supersedes.Select(s => $"- [[{s}]]")) + "\n";
            var origin = taskLink is null ? "" : $"\n## Origin\n\n- [[{taskLink}]]\n";
            var note = string.Join("\n", new[]
            {
                front, $"# Decision: {eventId}", "", "Back to [[index]]", "",
                "- Status: accepted", $"- Actor: {actor}", $"- Revision: {IntOf(decision["lamport"])}", "",
                "## Summary", "", Sanitize(summary, 600), related, origin,
            });
            File.WriteAllText(Path.Combine(root, "decisions", eventId + ".md"), note);
        }
        WriteIndexNote();
    }

    private void WriteConversationNotes()
    {
        if (MemoryDirectory is not { } root) return;
        var directory = Path.Combine(root, "conversations");
        Directory.CreateDirectory(directory);
        var conversations = Obj(_state["conversationStates"]);
        foreach (var conversationId in conversations.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal))
        {
            if (conversations[conversationId] is not JsonObject record) continue;
            var title = Sanitize(StringOf(record["title"]) ?? conversationId, 120);
            var lifecycle = StringOf(record["state"]) ?? "unknown";
            var updated = StringOf(record["updatedAt"]) ?? "";
            var noteId = ConversationNoteId(conversationId);
            var meaning = lifecycle switch
            {
                "archived" => "The chat is hidden from active conversations. Its task result is unchanged.",
                "restored" => "The chat was returned to active conversations. Its task result is unchanged.",
                "deleted" => "The chat was deleted. This memory record is retained as an audit trail.",
                _ => "The chat lifecycle was updated.",
            };
            var front = Frontmatter(new SortedDictionary<string, string>(StringComparer.Ordinal)
            {
                ["id"] = noteId,
                ["type"] = "conversation",
                ["title"] = Quoted(title, 120),
                ["state"] = lifecycle,
                ["updated"] = updated,
                ["revision"] = IntOf(record["revision"]).ToString(CultureInfo.InvariantCulture),
                ["actor"] = _identity?.PersonID ?? "unknown",
            }, ["conversation", lifecycle], ["index"]);
            var note = string.Join("\n", new[]
            {
                front, $"# Conversation: {title}", "", "Back to [[index]]", "",
                $"- Lifecycle: {Capitalized(lifecycle)}", $"- Updated: {updated}",
                $"- Conversation ID: `{Sanitize(conversationId, 120)}`", "",
                "## What this means", "", meaning, "",
                "Task success or failure is recorded separately in the related task note.",
            });
            File.WriteAllText(Path.Combine(directory, noteId + ".md"), note);
        }
    }

    private static string Capitalized(string value) => value.Length == 0 ? value : char.ToUpperInvariant(value[0]) + value[1..].ToLowerInvariant();

    private static string ConversationNoteId(string conversationId) =>
        "conversation-" + Digest(Encoding.UTF8.GetBytes(conversationId))[..16];

    private static string? DecisionRunId(JsonObject e) =>
        e["payload"] is JsonObject payload ? StringOf(payload["runId"]) ?? StringOf(payload["runID"]) : null;

    private void WriteIndexNote()
    {
        if (MemoryDirectory is not { } root) return;
        List<(string Id, string Title, string Created)> Notes(string folder)
        {
            var directory = Path.Combine(root, folder);
            if (!Directory.Exists(directory)) return new();
            var prefix = folder == "tasks" ? "task" : folder == "decisions" ? "decision" : "conversation";
            var list = new List<(string, string, string)>();
            foreach (var file in Directory.EnumerateFiles(directory, "*.md"))
            {
                string text;
                try { text = File.ReadAllText(file); } catch (IOException) { continue; }
                var front = ParseFrontmatter(text);
                var stem = System.IO.Path.GetFileNameWithoutExtension(file);
                var id = front.GetValueOrDefault("id") ?? $"{prefix}-{stem}";
                var title = Unquoted(front.GetValueOrDefault("title") ?? stem);
                var created = front.GetValueOrDefault("created") ?? front.GetValueOrDefault("updated") ?? front.GetValueOrDefault("revision") ?? "";
                list.Add((id, title, created));
            }
            return list.OrderByDescending(n => n.Item3, StringComparer.Ordinal).ToList();
        }
        var taskLines = Notes("tasks").Select(n => $"- [[{n.Id}]] — {n.Title}").ToList();
        var decisionLines = Notes("decisions").Select(n => $"- [[{n.Id}]] — {n.Title}").ToList();
        var conversationLines = Notes("conversations").Select(n => $"- [[{n.Id}]] — {n.Title}").ToList();
        var front = Frontmatter(new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["id"] = "index", ["type"] = "index", ["title"] = "Memory index", ["updated"] = IsoNow(),
            ["revision"] = Revision.ToString(CultureInfo.InvariantCulture),
        }, ["index", "moc"], ["map", "preferences"]);
        var body = string.Join("\n", new[]
        {
            front, "# Memory index", "", $"Revision {Revision} · [[map]] · [[preferences]]", "",
            "## Tasks", "", taskLines.Count == 0 ? "- None yet" : string.Join("\n", taskLines), "",
            "## Decisions", "", decisionLines.Count == 0 ? "- None yet" : string.Join("\n", decisionLines), "",
            "## Conversations", "", conversationLines.Count == 0 ? "- None yet" : string.Join("\n", conversationLines),
        });
        try { File.WriteAllText(Path.Combine(root, "index.md"), body); } catch (IOException) { }
    }

    private void WritePreferencesNote()
    {
        if (MemoryDirectory is not { } root) return;
        var text = PreferencesText();
        var front = Frontmatter(new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["id"] = "preferences", ["type"] = "preference", ["title"] = "Actor preferences",
            ["actor"] = _identity?.PersonID ?? "unknown", ["updated"] = IsoNow(),
        }, ["preference"], ["index"]);
        var body = string.Join("\n", new[] { front, "# Actor preferences", "", "Back to [[index]]", "", text.Length == 0 ? "- None recorded" : text });
        try { File.WriteAllText(Path.Combine(root, "preferences.md"), body); } catch (IOException) { }
    }

    // MARK: Backlog notes

    private static IReadOnlyList<string> OpenItems(string finalText) =>
        finalText.Split('\n')
            .Select(line => line.Trim())
            .Where(line => line.StartsWith("backlog:", StringComparison.OrdinalIgnoreCase))
            .Select(line => Sanitize(line["backlog:".Length..], 200))
            .Where(item => item.Length > 0)
            .ToList();

    private IEnumerable<string> TaskNoteFiles() =>
        MemoryDirectory is { } root && Directory.Exists(Path.Combine(root, "tasks"))
            ? Directory.EnumerateFiles(Path.Combine(root, "tasks"), "*.md")
            : Enumerable.Empty<string>();

    /// <summary><c>BACKLOG-DONE: &lt;run id&gt;</c> in a reply flips that note out of the backlog.</summary>
    private void CloseBacklog(string finalText)
    {
        var text = finalText.ToLowerInvariant();
        if (!text.Contains("backlog-done:", StringComparison.Ordinal)) return;
        foreach (var file in TaskNoteFiles().ToList())
        {
            var runId = System.IO.Path.GetFileNameWithoutExtension(file);
            if (!text.Contains(runId.ToLowerInvariant(), StringComparison.Ordinal)) continue;
            try
            {
                var note = File.ReadAllText(file)
                    .Replace("status: unfinished", "status: completed", StringComparison.Ordinal)
                    .Replace("status: failed", "status: completed", StringComparison.Ordinal)
                    .Replace("- [ ] ", "- [x] ", StringComparison.Ordinal);
                File.WriteAllText(file, note);
            }
            catch (IOException) { }
        }
    }

    private string RelevantTasks(string prompt)
    {
        var files = TaskNoteFiles().ToList();
        if (files.Count == 0) return "";
        var terms = prompt.Split(new[] { '/', ' ', '\n' }, StringSplitOptions.RemoveEmptyEntries).Where(t => t.Length > 2).ToList();
        var matched = new List<string>();
        foreach (var file in files)
        {
            string text;
            try { text = File.ReadAllText(file); } catch (IOException) { continue; }
            if (terms.Any(term => text.Contains(term, StringComparison.OrdinalIgnoreCase))) matched.Add(text);
        }
        if (matched.Count > 0) return string.Join("\n\n", matched.Take(3));
        return string.Join("\n\n", files.OrderByDescending(f => System.IO.Path.GetFileName(f), StringComparer.Ordinal).Take(3)
            .Select(f => { try { return File.ReadAllText(f); } catch (IOException) { return ""; } })
            .Where(t => t.Length > 0));
    }

    private string ConversationLifecycleText()
    {
        var conversations = Obj(_state["conversationStates"]);
        return string.Join("\n", conversations.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal).Select(id =>
        {
            if (conversations[id] is not JsonObject record) return null;
            var title = Sanitize(StringOf(record["title"]) ?? id, 120);
            return $"- `{title}` — {StringOf(record["state"]) ?? "unknown"}";
        }).Where(line => line is not null));
    }

    private string PreferencesText()
    {
        if (_identity is null || Obj(_state["activePreferences"])[_identity.PersonID] is not JsonObject preferences) return "";
        return MarkdownDictionary(preferences);
    }

    private static string MarkdownList(IReadOnlyList<JsonObject> list, string prefix) =>
        string.Join("\n", list.Select(item =>
        {
            var id = StringOf(item["eventId"]) ?? "unknown";
            var payload = item["payload"] as JsonObject ?? item;
            var summary = SummaryOf(payload) ?? StringOf(payload["key"]) ?? id;
            return $"- {prefix} `{id}`: {Sanitize(summary, 240)}";
        }));

    private static string MarkdownDictionary(JsonObject dictionary) =>
        string.Join("\n", dictionary.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal).Select(key =>
            $"- `{key}`: {Sanitize(dictionary[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : dictionary[key]?.ToJsonString() ?? "", 240)}"));

    /// <summary>
    /// An accepted decision carries the whole proposal event as its payload, so the text sits one level down.
    /// macOS then falls back to the event id; showing the real text is safe because it only affects display.
    /// </summary>
    private static string? SummaryOf(JsonObject payload) =>
        StringOf(payload["summary"]) ?? StringOf(payload["value"])
        ?? (payload["payload"] is JsonObject inner ? StringOf(inner["summary"]) ?? StringOf(inner["value"]) : null);

    private static string DecisionKey(JsonObject e)
    {
        var payload = e["payload"] as JsonObject ?? new JsonObject();
        return StringOf(payload["key"]) ?? StringOf(payload["summary"]) ?? StringOf(e["eventId"]) ?? "unknown";
    }

    private bool EventWins(JsonObject candidate, JsonObject current)
    {
        (int Role, int Score, int Lamport, string Id) Authority(JsonObject e)
        {
            var deviceId = StringOf((e["actor"] as JsonObject)?["deviceId"]) ?? "";
            var member = Member(deviceId);
            var role = (MemoryRoles.Parse(StringOf(member?["role"])) ?? MemoryRole.Observer).Rank();
            return (role, IntOf(member?["score"]), IntOf(e["lamport"]), StringOf(e["eventId"]) ?? "");
        }
        var left = Authority(candidate);
        var right = Authority(current);
        if (left.Role != right.Role) return left.Role > right.Role;
        if (left.Score != right.Score) return left.Score > right.Score;
        if (left.Lamport != right.Lamport) return left.Lamport > right.Lamport;
        return string.CompareOrdinal(left.Id, right.Id) > 0;
    }

    private static string TrimSnapshot(string text)
    {
        const int limit = 32_000;
        if (Encoding.UTF8.GetByteCount(text) <= limit) return text;
        return text[..Math.Min(text.Length, limit)] + "\n[older memory trimmed]";
    }

    /// <summary>
    /// Replicates the macOS heuristic, quirks included: the input is diacritic-folded first, so accented
    /// keywords such as "türkçe" never match and only their ASCII spellings do.
    /// </summary>
    private static string? ExplicitLanguage(string text)
    {
        var lower = Fold(text);
        var explicitRequest = new[] { "artık", "bundan sonra", "from now", "i want", "istiyorum", "tercih", "cevap ver", "konuş", "output" }
            .Any(keyword => lower.Contains(keyword, StringComparison.Ordinal));
        if (explicitRequest && (lower.Contains("ingilizce") || lower.Contains("english"))) return "English";
        if (explicitRequest && (lower.Contains("türkçe") || lower.Contains("turkish"))) return "Turkish";
        return null;
    }

    private static string Fold(string text)
    {
        var decomposed = text.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder();
        foreach (var c in decomposed)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) builder.Append(c);
        return builder.ToString().ToLowerInvariant();
    }

    private static string? ExplicitDecision(string text)
    {
        var lower = text.ToLowerInvariant();
        if (!new[] { "karar:", "decision:", "kullanalım", "we will use", "let's use" }.Any(marker => lower.Contains(marker, StringComparison.Ordinal))) return null;
        return Sanitize(text.Replace("\n", " "), 240);
    }

    // MARK: Members

    private JsonObject? CurrentMember() => _identity is null ? null : Member(_identity.DeviceID);

    private JsonObject? Member(string deviceId) =>
        Items(_state["members"]).FirstOrDefault(m => StringOf(m["deviceId"]) == deviceId);

    private void UpsertMember(JsonObject payload)
    {
        if (StringOf(payload["deviceId"]) is not { } deviceId) return;
        var members = Items(_state["members"]).Where(m => StringOf(m["deviceId"]) != deviceId).Select(m => (JsonNode?)m.DeepClone()).ToList();
        members.Add(payload.DeepClone());
        _state["members"] = new JsonArray(members.ToArray());
    }

    private void SetMember(string deviceId, string key, JsonNode? value)
    {
        if (Items(_state["members"]).FirstOrDefault(m => StringOf(m["deviceId"]) == deviceId) is { } member) member[key] = value;
    }

    private bool CanWrite(MemoryRole required)
    {
        if (CurrentMember() is not { } member || member["revoked"]?.GetValue<bool>() == true) return false;
        return MemoryRoles.Parse(StringOf(member["role"])) is { } actual && actual.Rank() >= required.Rank();
    }

    private bool CanWrite(string type) => type switch
    {
        "workspace.initialized" or "member.accepted" => true,
        "member.invited" or "member.revoked" or "member.updated" => CanWrite(MemoryRole.Owner),
        "decision.accepted" or "decision.rejected" or "project.default.set" => CanWrite(MemoryRole.Approver),
        "preference.set" => CanWrite(MemoryRole.Observer),
        _ => CanWrite(MemoryRole.Contributor),
    };

    private string? RootPublicKeyString() => StringOf((_manifest?["rootAuthority"] as JsonObject)?["publicKey"]);
    private string? RootDeviceId() => StringOf((_manifest?["rootAuthority"] as JsonObject)?["deviceId"]);

    private ECDsa? RootPublicKey() => RootPublicKeyString() is { } key ? PublicKeyFrom(key) : null;

    // MARK: Vault (Obsidian-style browser)

    /// <summary>Parses the `.mem` vault into linked notes for the Memory settings view.</summary>
    public MemoryVault Vault()
    {
        lock (_gate)
        {
            if (MemoryDirectory is not { } root || !Directory.Exists(root)) return new MemoryVault();
            var byId = new Dictionary<string, MemoryNote>(StringComparer.Ordinal);
            var order = new List<string>();

            void Ingest(string file, string fallbackKind)
            {
                if (!file.EndsWith(".md", StringComparison.Ordinal)) return;
                string text;
                try { text = File.ReadAllText(file); } catch (IOException) { return; }
                var front = ParseFrontmatter(text);
                var stem = System.IO.Path.GetFileNameWithoutExtension(file);
                var id = front.GetValueOrDefault("id") ?? $"{fallbackKind}-{stem}";
                var note = new MemoryNote(
                    id,
                    front.GetValueOrDefault("type") ?? fallbackKind,
                    Unquoted(front.GetValueOrDefault("title") ?? stem),
                    System.IO.Path.GetRelativePath(root, file).Replace('\\', '/'),
                    StripFrontmatter(text),
                    ParseList(front.GetValueOrDefault("tags")),
                    ExtractWikilinks(text),
                    Revision: int.TryParse(front.GetValueOrDefault("revision"), out var revision) ? revision : 0);
                if (!byId.ContainsKey(id)) order.Add(id);
                byId[id] = note;
            }

            foreach (var name in new[] { "map.md", "index.md", "preferences.md" })
            {
                var file = Path.Combine(root, name);
                if (File.Exists(file)) Ingest(file, "note");
            }
            foreach (var folder in new[] { "tasks", "decisions", "conversations" })
            {
                var directory = Path.Combine(root, folder);
                if (!Directory.Exists(directory)) continue;
                var kind = folder == "tasks" ? "task" : folder == "decisions" ? "decision" : "conversation";
                foreach (var file in Directory.EnumerateFiles(directory).OrderByDescending(f => System.IO.Path.GetFileName(f), StringComparer.Ordinal))
                    Ingest(file, kind);
            }
            // Synthetic nodes for wikilinked workspace files (and dangling links) that have no note.
            foreach (var id in order.ToList())
            {
                foreach (var link in byId[id].LinkList.Where(link => !byId.ContainsKey(link)))
                {
                    var isFile = link.StartsWith("file:", StringComparison.Ordinal);
                    byId[link] = new MemoryNote(link, isFile ? "file" : "missing", isFile ? link[5..] : link, "", Resolved: isFile);
                    order.Add(link);
                }
            }
            var backlinks = new Dictionary<string, List<string>>(StringComparer.Ordinal);
            var edges = new List<MemoryVaultEdge>();
            foreach (var id in order)
            {
                foreach (var link in byId[id].LinkList)
                {
                    if (!backlinks.TryGetValue(link, out var sources)) backlinks[link] = sources = new List<string>();
                    sources.Add(id);
                    edges.Add(new MemoryVaultEdge(id, link));
                }
            }
            foreach (var (target, sources) in backlinks)
                if (byId.TryGetValue(target, out var note))
                    byId[target] = note with { Backlinks = sources.OrderBy(s => s, StringComparer.Ordinal).ToList() };
            return new MemoryVault(order.Select(id => byId[id]).ToList(), edges);
        }
    }

    private static string Frontmatter(SortedDictionary<string, string> fields, IReadOnlyList<string> tags, IReadOnlyList<string> links)
    {
        var lines = new List<string> { "---" };
        lines.AddRange(fields.Select(f => $"{f.Key}: {f.Value}"));
        lines.Add($"tags: [{string.Join(", ", tags)}]");
        lines.Add($"links: [{string.Join(", ", links.Select(l => $"\"{l}\""))}]");
        lines.Add("---");
        return string.Join("\n", lines);
    }

    private static Dictionary<string, string> ParseFrontmatter(string text)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        if (!text.StartsWith("---\n", StringComparison.Ordinal)) return result;
        var rest = text[4..];
        var end = rest.IndexOf("\n---", StringComparison.Ordinal);
        if (end < 0) return result;
        foreach (var line in rest[..end].Split('\n'))
        {
            var colon = line.IndexOf(':');
            if (colon < 0) continue;
            result[line[..colon].Trim()] = line[(colon + 1)..].Trim();
        }
        return result;
    }

    private static string StripFrontmatter(string text)
    {
        if (!text.StartsWith("---\n", StringComparison.Ordinal)) return text;
        var rest = text[4..];
        var end = rest.IndexOf("\n---", StringComparison.Ordinal);
        return end < 0 ? text : rest[(end + 4)..].Trim();
    }

    private static IReadOnlyList<string> ParseList(string? raw)
    {
        if (raw is null || !raw.StartsWith('[') || !raw.EndsWith(']')) return Array.Empty<string>();
        return raw[1..^1].Split(',').Select(p => p.Trim(' ', '"')).Where(p => p.Length > 0).ToList();
    }

    private static IReadOnlyList<string> ExtractWikilinks(string text)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var search = 0;
        while (true)
        {
            var open = text.IndexOf("[[", search, StringComparison.Ordinal);
            if (open < 0) break;
            var close = text.IndexOf("]]", open + 2, StringComparison.Ordinal);
            if (close < 0) break;
            var target = text[(open + 2)..close].Trim();
            if (target.Length > 0 && seen.Add(target)) result.Add(target);
            search = close + 2;
        }
        return result;
    }

    private static string Quoted(string text, int limit) => $"\"{Sanitize(text, limit).Replace("\"", "'")}\"";

    private static string Unquoted(string text) =>
        text.Length >= 2 && text.StartsWith('"') && text.EndsWith('"') ? text[1..^1] : text;

    // MARK: Helpers

    private static readonly Regex[] SecretPatterns =
    {
        new(@"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*[^\s,;]+", RegexOptions.Compiled),
        new(@"(?i)bearer\s+[A-Za-z0-9._\-]+", RegexOptions.Compiled),
        new(@"(?i)authorization\s*:\s*[^\s,;]+", RegexOptions.Compiled),
    };

    public static string Sanitize(string text, int limit)
    {
        var result = Regex.Replace(text, @"\s+", " ");
        foreach (var pattern in SecretPatterns) result = pattern.Replace(result, "[redacted]");
        result = result.Trim();
        return result.Length > limit ? result[..limit] : result;
    }

    internal static string SafePathForTests(string path) => SafePath(path);

    internal static string SafePath(string path)
    {
        var normalized = path.Replace('\\', '/');
        if (normalized.Split('/', StringSplitOptions.RemoveEmptyEntries).Any(part =>
                part == ".env" || part.Contains("secret", StringComparison.OrdinalIgnoreCase) || part.Contains("token", StringComparison.OrdinalIgnoreCase)))
            return "<redacted>";
        return normalized.Length > 300 ? normalized[..300] : normalized;
    }

    private static string? SafeWorkspacePath(string path, string workspace)
    {
        var root = Path.GetFullPath(workspace);
        var full = Path.GetFullPath(Path.Combine(root, path.Length == 0 ? "." : path.Replace('/', Path.DirectorySeparatorChar)));
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var memory = Path.Combine(root, ".mem");
        var insideRoot = string.Equals(full, root, comparison) || full.StartsWith(root + Path.DirectorySeparatorChar, comparison);
        var insideMemory = string.Equals(full, memory, comparison) || full.StartsWith(memory + Path.DirectorySeparatorChar, comparison);
        return insideRoot && !insideMemory ? full : null;
    }

    private static JsonObject? ParseArguments(string arguments)
    {
        try { return JsonNode.Parse(arguments) as JsonObject; }
        catch (JsonException) { return null; }
    }

    private static void WriteJson(JsonNode node, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, CanonicalJson.Pretty(node), new UTF8Encoding(false));
        File.Move(temporary, path, overwrite: true);
    }

    private static void TryWriteJson(JsonNode node, string path)
    {
        try { WriteJson(node, path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Second-resolution UTC, like Foundation's ISO8601DateFormatter.</summary>
    private static string IsoNow() => DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    private static string Digest(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    private static JsonObject EmptyState() => new()
    {
        ["revision"] = 0,
        ["members"] = new JsonArray(),
        ["projectDefaults"] = new JsonObject(),
        ["activePreferences"] = new JsonObject(),
        ["acceptedDecisions"] = new JsonArray(),
        ["pendingProposals"] = new JsonArray(),
        ["supersededValues"] = new JsonArray(),
        ["conversationStates"] = new JsonObject(),
        ["lastMapRevision"] = 0,
    };

    private static string? StringOf(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static int IntOf(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<int>(out var number) ? number : 0;

    private static List<string> StringList(JsonNode? node) =>
        node is JsonArray array ? array.Select(StringOf).Where(s => s is not null).Select(s => s!).ToList() : new();

    private static IReadOnlyList<JsonObject> Items(JsonNode? node) =>
        node is JsonArray array ? array.OfType<JsonObject>().ToList() : new List<JsonObject>();

    private static JsonObject Obj(JsonNode? node) => node as JsonObject ?? new JsonObject();
}
