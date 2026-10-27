// Copyright (c) 2026 DOTS
// Music studio: a song as a project — a script, sections with lyrics, artists, and
// tracks that each keep their own audio file so they can be mixed and replaced.
// Mirrors MusicStudio.swift on macOS.

using System.Text.Json;
using System.Text.Json.Nodes;

using PluginRuntime;

namespace DotsHarnessCore;

public sealed class MusicArtist
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    /// <summary>The voice in words ("warm alto, breathy"); sent with every vocal the artist sings.</summary>
    public string Style { get; set; } = "";
}

public sealed class MusicLine
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    /// <summary>Who sings it. Null leaves the line unsung until someone is picked.</summary>
    public string? ArtistID { get; set; }
    public string Text { get; set; } = "";
}

public sealed class MusicSection
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public int Bars { get; set; } = 8;
    public List<MusicLine> Lines { get; set; } = [];
}

/// <summary>One audio file on a track.</summary>
public sealed class MusicClip
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    /// <summary>The section it covers; null spans the whole song.</summary>
    public string? SectionID { get; set; }
    /// <summary>File name inside the project's <c>assets</c> folder.</summary>
    public string AssetName { get; set; } = "";
}

public sealed class MusicTrack
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    /// <summary>What plays on it: "drums", "violin", "vocals".</summary>
    public string Instrument { get; set; } = "";
    /// <summary>How it should play.</summary>
    public string Prompt { get; set; } = "";
    /// <summary>Set on a vocal track: the artist whose lines it sings.</summary>
    public string? ArtistID { get; set; }
    public double Volume { get; set; } = 0.8;
    public bool Muted { get; set; }
    public bool Solo { get; set; }
    // ponytail: generation writes one whole-song clip, as on macOS.
    public List<MusicClip> Clips { get; set; } = [];
}

public sealed class MusicProject : IStudioProject
{
    public const int BeatsPerBar = 4;

    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    /// <summary>The brief the song is written from.</summary>
    public string Script { get; set; } = "";
    public int Bpm { get; set; } = 120;
    public string Key { get; set; } = "C major";
    public List<MusicArtist> Artists { get; set; } = [];
    public List<MusicSection> Sections { get; set; } = [];
    public List<MusicTrack> Tracks { get; set; } = [];
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.Now;

    /// <summary>Length of the song: every track is generated to it, which keeps separate files aligned.</summary>
    public int Seconds => (int)Math.Round(Math.Max(Sections.Sum(s => s.Bars), 1) * BeatsPerBar * 60.0 / Math.Max(Bpm, 1));

    /// <summary>Muted tracks are silent, and one solo silences every track that is not.</summary>
    public double Gain(MusicTrack track) =>
        track.Muted || (Tracks.Any(t => t.Solo) && !track.Solo) ? 0 : Math.Clamp(track.Volume, 0, 1);

    public MusicProject Clone() => MediaStudioJson.Clone(this);
}

public sealed class MusicStudioStore : StudioProjectStore<MusicProject>
{
    public MusicStudioStore(string root) : base(root, "mp3") { }
}

/// <summary>Turns a brief into a song plan, and each track of the plan into audio.</summary>
public static class MusicStudioAI
{
    public const int MaxTracks = 12;

    public static readonly string Instructions =
        "You plan songs for a multitrack music studio. Reply with a single JSON object and nothing else:\n" +
        "{\"name\":\"song title\",\"bpm\":120,\"key\":\"A minor\",\"artists\":[{\"name\":\"\",\"style\":\"how the voice sounds\"}]," +
        "\"sections\":[{\"name\":\"Verse 1\",\"bars\":8,\"lines\":[{\"artist\":\"artist name\",\"text\":\"one sung line\"}]}]," +
        "\"tracks\":[{\"instrument\":\"drums\",\"prompt\":\"how this instrument plays in this song\"}]}\n" +
        "The time signature is 4/4. \"sections\" are in playing order; an instrumental section has no lines. Every " +
        "line names the artist who sings it, spelled as in \"artists\". \"tracks\" lists the instruments only, one per " +
        $"track, at most {MaxTracks}; do not list vocals, each artist gets a vocal track automatically. Each track is " +
        "generated on its own, so its \"prompt\" must describe that instrument's part alone: pattern, feel, register. " +
        "Use as many artists as the request asks for, one when it does not say. Write lyrics and names in the " +
        "language of the request; keep \"instrument\" in English.";

    public static List<NativeMessage> PlanMessages(string brief) => [new("system", Instructions), new("user", brief)];

    private static string Str(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text.Trim() : "";

    private static int? Int(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<double>(out var number) ? (int)number : null;

    /// <summary>Tolerant of prose or code fences around the object; entries the model got wrong are dropped.</summary>
    public static MusicProject? ParsePlan(string text, string brief)
    {
        var start = text.IndexOf('{');
        var end = text.LastIndexOf('}');
        if (start < 0 || end <= start) return null;
        JsonObject? root;
        try { root = JsonNode.Parse(text[start..(end + 1)]) as JsonObject; }
        catch (JsonException) { return null; }
        if (root is null) return null;

        var artists = (root["artists"] as JsonArray ?? []).OfType<JsonObject>()
            .Where(item => Str(item["name"]).Length > 0)
            .Select(item => new MusicArtist { Name = Str(item["name"]), Style = Str(item["style"]) }).ToList();
        string? ArtistId(JsonNode? name) =>
            (artists.FirstOrDefault(a => string.Equals(a.Name, Str(name), StringComparison.OrdinalIgnoreCase)) ?? artists.FirstOrDefault())?.Id;
        var sections = (root["sections"] as JsonArray ?? []).OfType<JsonObject>()
            .Where(item => Str(item["name"]).Length > 0)
            .Select(item => new MusicSection
            {
                Name = Str(item["name"]),
                Bars = Math.Clamp(Int(item["bars"]) ?? 8, 1, 64),
                Lines = (item["lines"] as JsonArray ?? []).OfType<JsonObject>()
                    .Where(line => Str(line["text"]).Length > 0)
                    .Select(line => new MusicLine { ArtistID = ArtistId(line["artist"]), Text = Str(line["text"]) }).ToList(),
            }).ToList();
        var tracks = (root["tracks"] as JsonArray ?? []).OfType<JsonObject>().Take(MaxTracks)
            .Where(item => Str(item["instrument"]).Length > 0)
            .Select(item => new MusicTrack { Instrument = Str(item["instrument"]), Prompt = Str(item["prompt"]) }).ToList();
        if (sections.Count == 0 || tracks.Count == 0) return null;
        var singing = sections.SelectMany(s => s.Lines).Select(l => l.ArtistID).OfType<string>().ToHashSet();
        tracks.AddRange(artists.Where(a => singing.Contains(a.Id)).Select(a => new MusicTrack { Instrument = "vocals", ArtistID = a.Id }));

        var name = Str(root["name"]);
        var key = Str(root["key"]);
        return new MusicProject
        {
            Name = name.Length == 0 ? LocalizationService.Current.Get("studio.untitled") : name.Length > 60 ? name[..60] : name,
            Script = brief,
            Bpm = Math.Clamp(Int(root["bpm"]) ?? 120, 40, 240),
            Key = key.Length == 0 ? "C major" : key,
            Artists = artists,
            Sections = sections,
            Tracks = tracks,
        };
    }

    public static async Task<MusicProject> PlanAsync(string brief, RouterController router, MediaStudioSettings settings, CancellationToken ct = default)
    {
        var model = MediaStudioAI.UsableModel(router, settings.PlannerModelID);
        var response = await router.CompleteAsync(PlanMessages(brief), [], model.Length == 0 ? null : model, ct);
        return ParsePlan(response.Message.Content, brief)
            ?? throw new InvalidOperationException(LocalizationService.Current.Get("studio.music.noPlan"));
    }

    /// <summary>Model ids a server offers at <c>{base}/models</c>; empty when it has no such listing.</summary>
    public static async Task<List<string>> ModelsAsync(string baseUrl, string? apiKey)
    {
        if (!Uri.TryCreate(baseUrl.Trim().TrimEnd('/') + "/models", UriKind.Absolute, out var url) || url.Scheme is not ("http" or "https")) return [];
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            if (!string.IsNullOrWhiteSpace(apiKey)) request.Headers.Authorization = new("Bearer", apiKey);
            using var response = await http.SendAsync(request);
            var root = JsonNode.Parse(await response.Content.ReadAsStringAsync());
            return (root?["data"] as JsonArray ?? []).Select(item => Str(item?["id"])).Where(id => id.Length > 0).ToList();
        }
        catch (Exception) { return []; }
    }

    /// <summary>The lines a vocal track sings, in song order, under their section names.</summary>
    public static string? Lyrics(MusicTrack track, MusicProject project)
    {
        if (track.ArtistID is not { } artistId) return null;
        var parts = project.Sections.Select(section =>
        {
            var lines = section.Lines.Where(l => l.ArtistID == artistId && l.Text.Length > 0).Select(l => l.Text).ToList();
            return lines.Count == 0 ? null : $"[{section.Name}]\n" + string.Join("\n", lines);
        }).OfType<string>().ToList();
        return parts.Count == 0 ? null : string.Join("\n\n", parts);
    }

    /// <summary>Asks for one track alone, pinned to the song's tempo and key so it sits with the others.</summary>
    public static string StemPrompt(MusicTrack track, MusicProject project)
    {
        var parts = new List<string>();
        if (project.Artists.FirstOrDefault(a => a.Id == track.ArtistID) is { } artist)
        {
            parts.Add("Isolated lead vocals only, a cappella, no instruments, no backing track.");
            if (artist.Style.Length > 0) parts.Add($"Voice: {artist.Style}.");
        }
        else
        {
            parts.Add($"Isolated {track.Instrument} stem only, solo {track.Instrument}, no other instruments, no vocals.");
        }
        if (track.Prompt.Length > 0) parts.Add(track.Prompt);
        parts.Add($"{project.Bpm} BPM, {project.Key}, 4/4 time.");
        var script = project.Script.Trim();
        if (script.Length > 0) parts.Add($"Song: {(script.Length > 300 ? script[..300] : script)}");
        if (Lyrics(track, project) is { } lyrics) parts.Add($"Lyrics:\n{lyrics}");
        return string.Join(" ", parts);
    }

    /// <summary>Generates the track's audio and files it in the project. The caller puts the clip on the track.</summary>
    public static async Task<MusicClip> RenderAsync(MusicTrack track, MusicProject project, RouterController router,
        MediaStudioSettings settings, SupportPaths paths, IProviderSecretStore secrets, MusicStudioStore store, CancellationToken ct = default)
    {
        var media = await MediaStudioAI.GenerateAsync(NativeMediaKind.Music, StemPrompt(track, project), router, settings, paths, secrets,
            project.Seconds, new MusicStemRequest(track.Instrument, project.Bpm, project.Key, Lyrics(track, project)), ct);
        return new MusicClip { AssetName = store.ImportAsset(media.FilePath, project.Id) };
    }
}
