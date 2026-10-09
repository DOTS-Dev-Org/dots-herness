// Copyright (c) 2026 DOTS
// P-256 signed workspace access log shared with the macOS WorkspaceMemory store.

using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace DotsHarnessCore;

public enum MemoryRole { Owner, Approver, Contributor, Observer }

public static class MemoryRoleRules
{
    public static int Rank(this MemoryRole role) => role switch
    {
        MemoryRole.Owner => 3,
        MemoryRole.Approver => 2,
        MemoryRole.Contributor => 1,
        _ => 0,
    };

    public static string Value(this MemoryRole role) => role.ToString().ToLowerInvariant();
    public static bool TryParse(string? value, out MemoryRole role) =>
        Enum.TryParse(value, true, out role);
}

public sealed record WorkspaceMember(
    string PersonId, string DeviceId, string DisplayName, string Role, int Score, bool Revoked);

public sealed record WorkspaceDecision(string EventId, string Summary, JsonObject Payload);

public sealed record WorkspaceAccessSnapshot(
    string PersonId,
    string DeviceId,
    string PublicKey,
    MemoryRole? Role,
    int Score,
    int Revision,
    bool MemoryReady,
    IReadOnlyList<WorkspaceMember> Members,
    IReadOnlyList<WorkspaceDecision> PendingDecisions);

public sealed class WorkspaceAccessStore
{
    private sealed class StoredIdentity
    {
        [JsonPropertyName("personID")] public string PersonId { get; set; } = "";
        [JsonPropertyName("displayName")] public string DisplayName { get; set; } = "";
        [JsonPropertyName("privateKey")] public string PrivateKey { get; set; } = "";
        [JsonPropertyName("publicKey")] public string PublicKey { get; set; } = "";
        [JsonPropertyName("deviceID")] public string DeviceId { get; set; } = "";
        [JsonPropertyName("keyID")] public string KeyId { get; set; } = "";
    }

    private static readonly JsonSerializerOptions CompactJson = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        WriteIndented = false,
    };
    private readonly string _workspace;
    private readonly string _userRoot;
    private readonly string _memoryRoot;
    private readonly string _manifestPath;
    private readonly string _identityPath;
    private readonly object _gate = new();
    private JsonObject? _manifest;
    private JsonObject _state = EmptyState();
    private List<JsonObject> _events = [];
    private StoredIdentity? _identity;
    private ECDsa? _privateKey;
    private IReadOnlyList<JsonObject> _pendingDecisions = [];

    public WorkspaceAccessStore(string workspace, string userRoot)
    {
        _workspace = Path.GetFullPath(workspace);
        _userRoot = Path.GetFullPath(userRoot);
        _memoryRoot = Path.Combine(_workspace, ".mem");
        _manifestPath = Path.Combine(_memoryRoot, "manifest.json");
        _identityPath = Path.Combine(_userRoot, "memory-identity.json");
    }

    public WorkspaceAccessSnapshot Snapshot()
    {
        lock (_gate)
        {
            EnsureIdentity();
            Load();
            var current = CurrentMember();
            MemoryRole? role = MemoryRoleRules.TryParse(String(current?["role"]), out var parsed) ? parsed : null;
            return new WorkspaceAccessSnapshot(
                _identity!.PersonId,
                _identity.DeviceId,
                _identity.PublicKey,
                role,
                Integer(current?["score"]),
                Integer(_state["revision"]),
                _manifest is not null,
                ReadMembers(),
                ReadPendingDecisions());
        }
    }

    public void Initialize(string? displayName = null)
    {
        lock (_gate)
        {
            EnsureIdentity();
            Load();
            if (_manifest is not null) return;
            Directory.CreateDirectory(_memoryRoot);
            foreach (var folder in new[] { "events", "tasks", "decisions", "conversations" })
                Directory.CreateDirectory(Path.Combine(_memoryRoot, folder));
            var projectId = Guid.NewGuid().ToString().ToUpperInvariant();
            _manifest = new JsonObject
            {
                ["schemaVersion"] = 1,
                ["projectId"] = projectId,
                ["createdAt"] = DateTimeOffset.UtcNow.ToString("O"),
                ["rootAuthority"] = new JsonObject
                {
                    ["personId"] = _identity!.PersonId,
                    ["deviceId"] = _identity.DeviceId,
                    ["publicKey"] = _identity.PublicKey,
                    ["keyId"] = _identity.KeyId,
                    ["algorithm"] = "P-256-SHA256",
                },
                ["revision"] = 0,
            };
            _state = EmptyState();
            _events = [];
            WriteJson(_manifestPath, _manifest);
            WriteEvent("workspace.initialized", "project", new JsonObject
            {
                ["projectId"] = projectId,
                ["personId"] = _identity.PersonId,
                ["deviceId"] = _identity.DeviceId,
                ["displayName"] = Sanitize(displayName ?? _identity.DisplayName, 80),
                ["role"] = "owner",
                ["score"] = 100,
                ["publicKey"] = _identity.PublicKey,
            });
        }
    }

    public string CreateInvite(string displayName, MemoryRole role, int score, string publicKey)
    {
        lock (_gate)
        {
            PrepareWrite();
            RequireRole(MemoryRole.Owner);
            if (!IsValidPublicKey(publicKey)) throw new InvalidOperationException("The device public key is not a valid P-256 key.");
            var personId = Guid.NewGuid().ToString().ToUpperInvariant();
            var payload = new JsonObject
            {
                ["schemaVersion"] = 1,
                ["projectId"] = ProjectId(),
                ["personId"] = personId,
                ["displayName"] = Sanitize(displayName, 80),
                ["role"] = role.Value(),
                ["score"] = Math.Clamp(score, 0, 100),
                ["publicKey"] = publicKey,
                ["invitedBy"] = _identity!.PersonId,
                ["createdAt"] = DateTimeOffset.UtcNow.ToString("O"),
            };
            var eventId = WriteEvent("member.invited", "device", payload);
            payload["eventId"] = eventId;
            payload["actor"] = Actor();
            var signed = SignObject(payload);
            return Convert.ToBase64String(CanonicalBytes(signed));
        }
    }

    public void AcceptInvite(string token)
    {
        lock (_gate)
        {
            EnsureIdentity();
            Load();
            var invitation = ParseToken(token);
            if (invitation["projectId"]?.GetValue<string>() != ProjectId()
                || invitation["publicKey"]?.GetValue<string>() != _identity!.PublicKey)
                throw new InvalidOperationException("This invitation is for a different project or device.");
            var rootKey = ImportPublicKey(String(_manifest?["rootAuthority"]?["publicKey"]));
            if (!VerifyObject(invitation, rootKey)) throw new InvalidOperationException("The invitation signature is invalid.");
            var role = String(invitation["role"]);
            if (!MemoryRoleRules.TryParse(role, out _)) throw new InvalidOperationException("The invitation role is invalid.");
            WriteEvent("member.accepted", "device", new JsonObject
            {
                ["personId"] = String(invitation["personId"]),
                ["deviceId"] = _identity.DeviceId,
                ["displayName"] = String(invitation["displayName"]),
                ["role"] = role,
                ["score"] = Integer(invitation["score"]),
                ["publicKey"] = _identity.PublicKey,
            });
        }
    }

    public void Revoke(string deviceId)
    {
        lock (_gate)
        {
            PrepareWrite();
            RequireRole(MemoryRole.Owner);
            if (deviceId == _identity!.DeviceId) throw new InvalidOperationException("The current device cannot revoke itself.");
            WriteEvent("member.revoked", "device", new JsonObject { ["deviceId"] = deviceId });
        }
    }

    public void ResolveDecision(string eventId, bool accept)
    {
        lock (_gate)
        {
            PrepareWrite();
            RequireRole(MemoryRole.Approver);
            var proposal = _pendingDecisions.FirstOrDefault(item => String(item["eventId"]) == eventId);
            if (proposal is null) return;
            var payload = CloneObject(proposal["payload"] as JsonObject ?? new JsonObject());
            if (accept)
            {
                var supersedes = proposal["supersedes"]?.DeepClone() as JsonArray ?? new JsonArray();
                WriteEvent("decision.accepted", "project", payload, supersedes);
            }
            else WriteEvent("decision.rejected", "project", new JsonObject { ["proposalEventId"] = eventId });
        }
    }

    public bool SetProjectDefault(string key, string value)
    {
        lock (_gate)
        {
            PrepareWrite();
            RequireRole(MemoryRole.Approver);
            var limit = WorkspaceFacts.KnowledgeKeys.Contains(key) ? WorkspaceFacts.MaxKnowledgeLength : WorkspaceFacts.MaxTextLength;
            var cleanedKey = Sanitize(key, WorkspaceFacts.MaxKeyLength).ToLowerInvariant();
            var cleanedValue = Sanitize(value, limit);
            if (cleanedKey.Length == 0 || cleanedValue.Length == 0
                || WorkspaceFacts.IsSecret(new WorkspaceFact("project", cleanedKey, cleanedValue))) return false;
            WriteEvent("project.default.set", "project", new JsonObject { ["key"] = cleanedKey, ["value"] = cleanedValue });
            return WorkspaceFacts.SetProject(_workspace, cleanedKey, cleanedValue);
        }
    }

    public bool ForgetProjectDefault(string key)
    {
        lock (_gate)
        {
            PrepareWrite();
            RequireRole(MemoryRole.Approver);
            var cleanedKey = Sanitize(key, WorkspaceFacts.MaxKeyLength).ToLowerInvariant();
            if (cleanedKey.Length == 0) return false;
            WriteEvent("project.default.set", "project", new JsonObject { ["key"] = cleanedKey });
            return WorkspaceFacts.ForgetProject(_workspace, cleanedKey);
        }
    }

    public bool CanEditProjectDefaults()
    {
        lock (_gate)
        {
            EnsureIdentity();
            Load();
            return _manifest is null || CurrentRole() is { } role && role.Rank() >= MemoryRole.Approver.Rank();
        }
    }

    private void PrepareWrite()
    {
        EnsureIdentity();
        Load();
        if (_manifest is null) throw new InvalidOperationException("Initialize workspace memory before changing access.");
    }

    private string WriteEvent(string type, string scope, JsonObject payload, JsonArray? supersedes = null)
    {
        if (_manifest is null || _identity is null || _privateKey is null) throw new InvalidOperationException("Workspace memory is unavailable.");
        if (!CanWrite(type)) throw new InvalidOperationException("The current workspace role cannot perform this action.");
        var eventId = Guid.NewGuid().ToString().ToUpperInvariant();
        var lamport = Integer(_state["revision"]) + 1;
        var parent = _events.LastOrDefault();
        var parents = parent is null ? new JsonArray() : new JsonArray(JsonValue.Create(String(parent["eventId"])));
        var unsigned = new JsonObject
        {
            ["schemaVersion"] = 1,
            ["eventId"] = eventId,
            ["type"] = type,
            ["scope"] = scope,
            ["projectId"] = ProjectId(),
            ["actor"] = Actor(),
            ["lamport"] = lamport,
            ["createdAt"] = DateTimeOffset.UtcNow.ToString("O"),
            ["parents"] = parents,
            ["supersedes"] = supersedes?.DeepClone() ?? new JsonArray(),
            ["payload"] = payload.DeepClone(),
        };
        var signed = SignObject(unsigned);
        var path = Path.Combine(_memoryRoot, "events", eventId + ".json");
        WriteJson(path, signed);
        _events.Add(CloneObject(signed));
        Apply(signed);
        _state["revision"] = lamport;
        _manifest["revision"] = lamport;
        WriteJson(_manifestPath, _manifest);
        WriteJson(Path.Combine(_memoryRoot, "state.json"), _state);
        return eventId;
    }

    private void Load()
    {
        _manifest = ReadObject(_manifestPath);
        _state = EmptyState();
        _events = [];
        _pendingDecisions = [];
        if (_manifest is null || Integer(_manifest["schemaVersion"]) != 1 || ProjectId().Length == 0) return;
        var eventsDirectory = Path.Combine(_memoryRoot, "events");
        if (!Directory.Exists(eventsDirectory)) return;
        var valid = new HashSet<string>(StringComparer.Ordinal);
        foreach (var path in Directory.GetFiles(eventsDirectory, "*.json")
                     .Select(ReadObject).Where(item => item is not null).Cast<JsonObject>()
                     .OrderBy(item => Integer(item["lamport"]))
                     .ThenBy(item => String(item["eventId"]), StringComparer.Ordinal))
        {
            if (!VerifyEvent(path)) continue;
            var parents = path["parents"] as JsonArray ?? new JsonArray();
            if (parents.Any(parent => !valid.Contains(String(parent)))) continue;
            _events.Add(path);
            var eventId = String(path["eventId"]);
            if (eventId.Length > 0) valid.Add(eventId);
            Apply(path);
        }
        if (_events.Count > 0)
        {
            var revision = Integer(_events[^1]["lamport"]);
            _state["revision"] = revision;
            _manifest["revision"] = revision;
            WriteJson(_manifestPath, _manifest);
            WriteJson(Path.Combine(_memoryRoot, "state.json"), _state);
        }
    }

    private bool VerifyEvent(JsonObject item)
    {
        if (Integer(item["schemaVersion"]) != 1 || String(item["projectId"]) != ProjectId()) return false;
        var actor = item["actor"] as JsonObject;
        if (actor is null) return false;
        var publicKeyString = String(actor["publicKey"]);
        var deviceId = String(actor["deviceId"]);
        byte[] publicRaw;
        try { publicRaw = Convert.FromBase64String(publicKeyString); }
        catch (FormatException) { return false; }
        if (Hex(SHA256.HashData(publicRaw)) != deviceId) return false;
        var root = _manifest?["rootAuthority"] as JsonObject;
        var isRoot = deviceId == String(root?["deviceId"]);
        if (isRoot && publicKeyString != String(root?["publicKey"])) return false;
        if (!isRoot)
        {
            if (String(item["type"]) == "member.accepted")
            {
                var payload = item["payload"] as JsonObject;
                if (String(payload?["publicKey"]) != publicKeyString || String(payload?["deviceId"]) != deviceId) return false;
                var invitationExists = _events.Any(existing => String(existing["type"]) == "member.invited"
                    && String((existing["payload"] as JsonObject)?["publicKey"]) == publicKeyString
                    && String((existing["payload"] as JsonObject)?["personId"]) == String(payload?["personId"]));
                if (!invitationExists) return false;
            }
            else if (Member(deviceId) is not { Revoked: false }) return false;
        }
        try { return VerifyObject(item, ImportPublicKey(publicKeyString)); }
        catch (CryptographicException) { return false; }
    }

    private void Apply(JsonObject item)
    {
        var type = String(item["type"]);
        var payload = item["payload"] as JsonObject ?? new JsonObject();
        switch (type)
        {
            case "workspace.initialized":
            case "member.accepted":
                UpsertMember(payload);
                break;
            case "member.revoked":
                UpdateMember(String(payload["deviceId"]), "revoked", JsonValue.Create(true));
                break;
            case "member.updated":
                foreach (var propertyName in new[] { "role", "score", "displayName" })
                    if (payload[propertyName] is { } value) UpdateMember(String(payload["deviceId"]), propertyName, value.DeepClone());
                break;
            case "project.default.set":
                if (String(payload["key"]) is { Length: > 0 } key)
                {
                    var facts = _state["projectDefaults"] as JsonObject ?? new JsonObject();
                    facts[key] = payload["value"]?.DeepClone();
                    _state["projectDefaults"] = facts;
                }
                break;
            case "decision.proposed":
                var proposals = _state["pendingProposals"] as JsonArray ?? new JsonArray();
                proposals.Add(item.DeepClone());
                _state["pendingProposals"] = proposals;
                break;
            case "decision.accepted":
                var accepted = _state["acceptedDecisions"] as JsonArray ?? new JsonArray();
                var superseded = (item["supersedes"] as JsonArray ?? new JsonArray()).Select(String).ToHashSet(StringComparer.Ordinal);
                var retained = accepted.Where(existing => !superseded.Contains(String(existing?["eventId"]))).Select(existing => existing?.DeepClone()).ToArray();
                retained = retained.Append(item.DeepClone()).ToArray();
                _state["acceptedDecisions"] = new JsonArray(retained);
                RemoveProposal(String(payload["eventId"]));
                break;
            case "decision.rejected":
                RemoveProposal(String(payload["proposalEventId"]));
                break;
        }
    }

    private void RemoveProposal(string? proposalId)
    {
        if (proposalId is null) return;
        var proposals = _state["pendingProposals"] as JsonArray ?? new JsonArray();
        var retained = proposals.Where(item => String((item?["payload"] as JsonObject)?["eventId"]) != proposalId).ToArray();
        _state["pendingProposals"] = new JsonArray(retained.Select(item => item?.DeepClone()).ToArray());
    }

    private IReadOnlyList<WorkspaceMember> ReadMembers() =>
        (_state["members"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(item => new WorkspaceMember(
            String(item["personId"]), String(item["deviceId"]), String(item["displayName"]), String(item["role"]),
            Integer(item["score"]), Bool(item["revoked"]))).ToList();

    private IReadOnlyList<WorkspaceDecision> ReadPendingDecisions() =>
        (_state["pendingProposals"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(item =>
        {
            var payload = item["payload"] as JsonObject ?? new JsonObject();
            return new WorkspaceDecision(String(item["eventId"]), String(payload["summary"]), CloneObject(payload));
        }).ToList();

    private WorkspaceMember? Member(string deviceId) => ReadMembers().FirstOrDefault(member => member.DeviceId == deviceId);
    private JsonObject? CurrentMember() => _state["members"] is JsonArray members
        ? members.OfType<JsonObject>().FirstOrDefault(member => String(member["deviceId"]) == _identity?.DeviceId)
        : null;
    private MemoryRole? CurrentRole() => MemoryRoleRules.TryParse(String(CurrentMember()?["role"]), out var role) ? role : null;

    private bool CanWrite(string type)
    {
        if (type is "workspace.initialized" or "member.accepted") return true;
        var role = CurrentRole();
        if (role is null || Bool(CurrentMember()?["revoked"])) return false;
        var required = type switch
        {
            "member.invited" or "member.revoked" or "member.updated" => MemoryRole.Owner,
            "project.default.set" or "decision.accepted" or "decision.rejected" => MemoryRole.Approver,
            "preference.set" => MemoryRole.Observer,
            _ => MemoryRole.Contributor,
        };
        return role.Value.Rank() >= required.Rank();
    }

    private void RequireRole(MemoryRole role)
    {
        if (CurrentRole() is not { } actual || Bool(CurrentMember()?["revoked"]) || actual.Rank() < role.Rank())
            throw new InvalidOperationException("The current workspace role cannot perform this action.");
    }

    private void UpsertMember(JsonObject payload)
    {
        var list = _state["members"] as JsonArray ?? new JsonArray();
        var deviceId = String(payload["deviceId"]);
        var members = list.OfType<JsonObject>().Where(item => String(item["deviceId"]) != deviceId)
            .Select(item => (JsonNode?)item.DeepClone()).ToList();
        members.Add(payload.DeepClone());
        _state["members"] = new JsonArray(members.ToArray());
    }

    private void UpdateMember(string? deviceId, string key, JsonNode? value)
    {
        if (deviceId is null || _state["members"] is not JsonArray list) return;
        foreach (var member in list.OfType<JsonObject>().Where(item => String(item["deviceId"]) == deviceId))
            member[key] = value?.DeepClone();
    }

    private JsonObject Actor() => new()
    {
        ["personId"] = _identity!.PersonId,
        ["deviceId"] = _identity.DeviceId,
        ["keyId"] = _identity.KeyId,
        ["publicKey"] = _identity.PublicKey,
    };

    private JsonObject SignObject(JsonObject unsigned)
    {
        var signature = _privateKey!.SignData(CanonicalBytes(unsigned), HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        var signed = CloneObject(unsigned);
        signed["signature"] = new JsonObject { ["algorithm"] = "P-256-SHA256", ["value"] = Convert.ToBase64String(signature) };
        return signed;
    }

    private static bool VerifyObject(JsonObject signed, ECDsa publicKey)
    {
        var signature = String((signed["signature"] as JsonObject)?["value"]);
        byte[] signatureBytes;
        try { signatureBytes = Convert.FromBase64String(signature); }
        catch (FormatException) { return false; }
        var unsigned = CloneObject(signed);
        unsigned.Remove("signature");
        return publicKey.VerifyData(CanonicalBytes(unsigned), signatureBytes, HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    }

    private static byte[] CanonicalBytes(JsonNode node) => JsonSerializer.SerializeToUtf8Bytes(Sort(node), CompactJson);

    private static JsonNode? Sort(JsonNode? node)
    {
        if (node is JsonObject obj)
        {
            var sorted = new JsonObject();
            foreach (var item in obj.OrderBy(pair => pair.Key, StringComparer.Ordinal)) sorted[item.Key] = Sort(item.Value);
            return sorted;
        }
        if (node is JsonArray array) return new JsonArray(array.Select(Sort).ToArray());
        return node?.DeepClone();
    }

    private void EnsureIdentity()
    {
        if (_identity is not null && _privateKey is not null) return;
        Directory.CreateDirectory(_userRoot);
        var existing = ReadObject(_identityPath);
        if (existing is not null)
        {
            var stored = existing.Deserialize<StoredIdentity>(new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (stored is not null && TryLoadPrivateKey(stored, out var existingKey))
            {
                _identity = stored;
                _privateKey = existingKey;
                return;
            }
        }
        using var generated = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var parameters = generated.ExportParameters(true);
        var privateBytes = parameters.D!;
        var publicBytes = new byte[65];
        publicBytes[0] = 0x04;
        parameters.Q.X!.CopyTo(publicBytes, 1);
        parameters.Q.Y!.CopyTo(publicBytes, 33);
        var deviceId = Hex(SHA256.HashData(publicBytes));
        _identity = new StoredIdentity
        {
            PersonId = Guid.NewGuid().ToString().ToUpperInvariant(),
            DisplayName = Environment.UserName.Length == 0 ? "User" : Environment.UserName,
            PrivateKey = Convert.ToBase64String(privateBytes),
            PublicKey = Convert.ToBase64String(publicBytes),
            DeviceId = deviceId,
            KeyId = "device-" + deviceId[..16],
        };
        _privateKey = ECDsa.Create(parameters);
        WriteJson(_identityPath, JsonSerializer.SerializeToNode(_identity, CompactJson)!.AsObject());
        RestrictIdentityFile();
    }

    private static bool TryLoadPrivateKey(StoredIdentity stored, out ECDsa key)
    {
        key = ECDsa.Create();
        try
        {
            var privateBytes = Convert.FromBase64String(stored.PrivateKey);
            var publicBytes = Convert.FromBase64String(stored.PublicKey);
            if (privateBytes.Length != 32 || publicBytes.Length != 65 || publicBytes[0] != 0x04) return false;
            key.ImportParameters(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                D = privateBytes,
                Q = new ECPoint { X = publicBytes[1..33], Y = publicBytes[33..65] },
            });
            return true;
        }
        catch (Exception error) when (error is FormatException or CryptographicException or ArgumentException)
        {
            key.Dispose();
            key = ECDsa.Create();
            return false;
        }
    }

    private static ECDsa ImportPublicKey(string? base64)
    {
        var bytes = Convert.FromBase64String(base64 ?? "");
        if (bytes.Length != 65 || bytes[0] != 0x04) throw new CryptographicException("Invalid P-256 public key.");
        var key = ECDsa.Create();
        key.ImportParameters(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = bytes[1..33], Y = bytes[33..65] },
        });
        return key;
    }

    private static bool IsValidPublicKey(string value)
    {
        try { using var _ = ImportPublicKey(value); return true; }
        catch (Exception error) when (error is FormatException or CryptographicException or ArgumentException) { return false; }
    }

    private static JsonObject ParseToken(string token)
    {
        try
        {
            return JsonNode.Parse(Convert.FromBase64String(token))?.AsObject() ?? throw new InvalidOperationException();
        }
        catch (Exception error) when (error is FormatException or JsonException or InvalidOperationException)
        {
            throw new InvalidOperationException("The invitation token is malformed.");
        }
    }

    private string ProjectId() => String(_manifest?["projectId"]);
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

    private static JsonObject CloneObject(JsonObject value) => (JsonObject)value.DeepClone();
    private static string String(JsonNode? value) => value is JsonValue item && item.TryGetValue<string>(out var text) ? text : "";
    private static int Integer(JsonNode? value) => value is JsonValue item && item.TryGetValue<int>(out var number) ? number : 0;
    private static bool Bool(JsonNode? value) => value is JsonValue item && item.TryGetValue<bool>(out var boolean) && boolean;
    private static string Hex(byte[] data) => Convert.ToHexString(data).ToLowerInvariant();
    private static string Sanitize(string value, int limit)
    {
        var cleaned = string.Join(" ", (value ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return cleaned.Length <= limit ? cleaned : cleaned[..limit];
    }

    private static void WriteJson(string path, JsonObject value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var sorted = Sort(value)!;
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temp, JsonSerializer.SerializeToUtf8Bytes(sorted, new JsonSerializerOptions(CompactJson) { WriteIndented = true }));
            File.Move(temp, path, overwrite: true);
        }
        finally { try { if (File.Exists(temp)) File.Delete(temp); } catch (IOException) { } }
    }

    private static JsonObject? ReadObject(string path)
    {
        try { return File.Exists(path) ? JsonNode.Parse(File.ReadAllBytes(path))?.AsObject() : null; }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException) { return null; }
    }

    private void RestrictIdentityFile()
    {
        if (OperatingSystem.IsWindows()) return; // The support directory inherits the user's private home permissions.
        try { File.SetUnixFileMode(_identityPath, UnixFileMode.UserRead | UnixFileMode.UserWrite); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or PlatformNotSupportedException) { }
    }
}
