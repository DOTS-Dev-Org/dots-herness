// Copyright (c) 2026 DOTS
// Media studio: projects made of canvases on one board, each a stack of layers.
// Mirrors MediaStudio.swift and StudioProjectStore.swift on macOS: the same project.json
// layout, the same planner prompt and the same tolerant plan parser.

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

using PluginRuntime;

namespace DotsHarnessCore;

public sealed class MediaLayer
{
    // Kinds, shapes and the rest are kept as the raw strings macOS writes.
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    /// <summary>text, image, shape, video, icon or path.</summary>
    public string Kind { get; set; } = "shape";
    /// <summary>Frame in the owning canvas's coordinates (points, origin top-left).</summary>
    public double X { get; set; }
    public double Y { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }
    public double Opacity { get; set; } = 1;
    public bool Hidden { get; set; }
    public string Text { get; set; } = "";
    public double FontSize { get; set; } = 48;
    /// <summary>regular, medium or bold.</summary>
    public string FontWeight { get; set; } = "bold";
    /// <summary>leading, center or trailing.</summary>
    public string Alignment { get; set; } = "center";
    /// <summary>Text or icon colour, shape fill, or the tint of an image that has no file yet.</summary>
    public string ColorHex { get; set; } = "#111111";
    /// <summary>rectangle, ellipse, polygon or star.</summary>
    public string Shape { get; set; } = "rectangle";
    public double CornerRadius { get; set; }
    /// <summary>File name inside the project's <c>assets</c> folder (image and video layers).</summary>
    public string? AssetName { get; set; }
    public bool Locked { get; set; }
    /// <summary>Degrees, clockwise, around the layer's centre.</summary>
    public double Rotation { get; set; }
    /// <summary>Second colour; when set the fill is a diagonal gradient from <see cref="ColorHex"/>.</summary>
    public string? GradientHex { get; set; }
    public string? StrokeHex { get; set; }
    public double StrokeWidth { get; set; }
    /// <summary>Blur radius of a drop shadow; zero draws none.</summary>
    public double Shadow { get; set; }
    /// <summary>SF Symbols name (icon layers); <see cref="MediaIcons"/> maps it to a glyph.</summary>
    public string Symbol { get; set; } = "star.fill";
    /// <summary>default, rounded, serif or mono.</summary>
    public string FontDesign { get; set; } = "default";
    /// <summary>What an image layer should show, kept so it can be generated or regenerated later.</summary>
    public string? Prompt { get; set; }
    /// <summary>Path layers: x and y pairs, each 0…1 across the layer's frame.</summary>
    public List<double> Points { get; set; } = [];
    /// <summary>Path layers: an arrowhead on the last point.</summary>
    public bool Arrow { get; set; }
    /// <summary>Text layers: degrees of arc the line bends through.</summary>
    public double Arc { get; set; }
    /// <summary>A note pinned to the canvas: shown while editing, left out of previews and exports.</summary>
    public bool Comment { get; set; }
    /// <summary>Normalized, reversible crop of an image source; null keeps older projects uncropped.</summary>
    public double? CropX { get; set; }
    public double? CropY { get; set; }
    public double? CropWidth { get; set; }
    public double? CropHeight { get; set; }

    public MediaLayer Clone() => MediaStudioJson.Clone(this);
}

public sealed class MediaCanvas
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    /// <summary>Position on the project board.</summary>
    public double X { get; set; }
    public double Y { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }
    public string BackgroundHex { get; set; } = "#FFFFFF";
    /// <summary>Back to front.</summary>
    public List<MediaLayer> Layers { get; set; } = [];
    /// <summary>A section sits behind the canvases on the board and carries the ones inside it when moved.</summary>
    public bool? Section { get; set; }
    /// <summary>The canvas this one sits inside; moved, exported and deleted with its parent.</summary>
    public string? ParentID { get; set; }

    public MediaCanvas Clone() => MediaStudioJson.Clone(this);

    /// <summary>The canvas as it travels to and from the community: fresh ids, no local files, no editing notes.</summary>
    public MediaCanvas CommunityCopy()
    {
        var copy = Clone();
        copy.Id = Guid.NewGuid().ToString();
        copy.X = 0;
        copy.Y = 0;
        copy.ParentID = null;
        copy.Layers = copy.Layers.Where(layer => !layer.Comment).ToList();
        foreach (var layer in copy.Layers)
        {
            layer.Id = Guid.NewGuid().ToString();
            layer.AssetName = null;
        }
        return copy;
    }
}

public interface IStudioProject
{
    string Id { get; set; }
    string Name { get; set; }
    DateTimeOffset UpdatedAt { get; set; }
}

public sealed class MediaProject : IStudioProject
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public List<MediaCanvas> Canvases { get; set; } = [];
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.Now;

    public MediaProject Clone() => MediaStudioJson.Clone(this);
}

public static class MediaStudioJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static T Clone<T>(T value) => JsonSerializer.Deserialize<T>(JsonSerializer.Serialize(value, Options), Options)!;
}

public sealed record MediaSizePreset(string Id, double Width, double Height)
{
    public string Title => LocalizationService.Current.Get($"studio.preset.{Id}");

    public static readonly IReadOnlyList<MediaSizePreset> All =
    [
        new("square", 1080, 1080), new("story", 1080, 1920), new("landscape", 1920, 1080),
        new("thumbnail", 1280, 720), new("logo", 512, 512), new("poster", 1240, 1754),
    ];
}

/// <summary>Ready-made canvas sizes, grouped the way a designer looks for them.</summary>
public sealed record MediaFrameGroup(string Id, IReadOnlyList<MediaFrameGroup.Preset> Presets)
{
    public sealed record Preset(string Name, double Width, double Height);

    public string Title => LocalizationService.Current.Get($"studio.frames.{Id}");

    private static MediaFrameGroup Group(string id, params (string, double, double)[] presets) =>
        new(id, presets.Select(p => new Preset(p.Item1, p.Item2, p.Item3)).ToList());

    public static IReadOnlyList<MediaFrameGroup> All =>
    [
        Group("phone", ("iPhone 17", 402, 874), ("iPhone 16 & 17 Pro", 402, 874), ("iPhone 16", 393, 852),
            ("iPhone 16 & 17 Pro Max", 440, 956), ("iPhone 16 Plus", 430, 932), ("iPhone Air", 420, 912),
            ("iPhone 14 & 15 Pro Max", 430, 932), ("iPhone 14 & 15 Pro", 393, 852), ("iPhone 13 & 14", 390, 844),
            ("iPhone 14 Plus", 428, 926), ("Android Compact", 412, 917), ("Android Medium", 700, 840)),
        Group("tablet", ("iPad mini 8.3", 744, 1133), ("iPad Pro 11\"", 834, 1194), ("iPad Pro 12.9\"", 1024, 1366),
            ("Surface Pro 8", 1440, 960)),
        Group("desktop", ("MacBook Air", 1280, 832), ("MacBook Pro 14\"", 1512, 982), ("MacBook Pro 16\"", 1728, 1117),
            ("Desktop", 1440, 1024), ("Full HD", 1920, 1080), ("TV", 1280, 720)),
        Group("presentation", ("Slide 16:9", 1920, 1080), ("Slide 4:3", 1024, 768)),
        Group("watch", ("Apple Watch 46mm", 208, 248), ("Apple Watch 42mm", 187, 223), ("Apple Watch 45mm", 198, 242),
            ("Apple Watch 41mm", 176, 215), ("Apple Watch 44mm", 184, 224), ("Apple Watch 40mm", 162, 197)),
        Group("paper", ("A4", 595, 842), ("A5", 420, 595), ("A6", 297, 420), ("Letter", 612, 792), ("Tabloid", 792, 1224)),
        new("social", MediaSizePreset.All.Select(p => new Preset(p.Title, p.Width, p.Height)).Concat(
        [
            new Preset("X post", 1200, 675), new Preset("X header", 1500, 500),
            new Preset("Facebook post", 1200, 630), new Preset("Facebook cover", 820, 312),
            new Preset("LinkedIn cover", 1584, 396),
        ]).ToList()),
    ];
}

/// <summary>A ready-made canvas decoded from the remotely maintained media template catalog.</summary>
public sealed record MediaTemplate(string Id, string Category, Func<MediaCanvas> Build, string? DisplayTitle = null)
{
    public static readonly string[] Categories = ["social", "uiux", "presentation", "other"];

    public string Title => DisplayTitle ?? LocalizationService.Current.Get($"studio.template.{Id}");

    public MediaCanvas Canvas()
    {
        var canvas = Build();
        canvas.Id = Guid.NewGuid().ToString();
        canvas.Name = Title;
        foreach (var layer in canvas.Layers) layer.Id = Guid.NewGuid().ToString();
        return canvas;
    }

    public static IReadOnlyList<MediaTemplate> All => [];
}

/// <summary>SF Symbols names the planner and macOS use, drawn as text glyphs on Windows and Linux.</summary>
public static class MediaIcons
{
    public static readonly IReadOnlyDictionary<string, string> Glyphs = new Dictionary<string, string>
    {
        ["star.fill"] = "★", ["heart.fill"] = "♥", ["bell.fill"] = "🔔", ["house.fill"] = "⌂", ["cart.fill"] = "🛒",
        ["person.fill"] = "👤", ["magnifyingglass"] = "🔍", ["arrow.right"] = "→", ["checkmark.circle.fill"] = "✔",
        ["play.fill"] = "▶", ["leaf.fill"] = "🍃", ["bolt.fill"] = "⚡", ["camera.fill"] = "📷", ["mappin"] = "📍",
        ["calendar"] = "📅", ["envelope.fill"] = "✉", ["pawprint.fill"] = "🐾", ["sparkles"] = "✨", ["music.note"] = "♪",
        ["phone.fill"] = "☎", ["gearshape.fill"] = "⚙", ["globe"] = "🌐", ["flame.fill"] = "🔥", ["sun.max.fill"] = "☀",
        ["moon.fill"] = "☾", ["cloud.fill"] = "☁", ["lock.fill"] = "🔒", ["gift.fill"] = "🎁", ["trophy.fill"] = "🏆",
    };

    public static string Glyph(string symbol) => Glyphs.TryGetValue(symbol, out var glyph) ? glyph : "★";
}

/// <summary>A music API connected by address: a server on the network or a cloud service.</summary>
public sealed class MusicEndpoint
{
    public const string Standard = "standard";
    public const string ElevenLabs = "elevenlabs";

    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public string BaseURL { get; set; } = DefaultBaseUrl(Standard);
    /// <summary>standard (<c>POST {base}/audio/generations</c>) or elevenlabs.</summary>
    public string Format { get; set; } = Standard;
    public string Model { get; set; } = "";

    public static string DefaultBaseUrl(string format) =>
        format == ElevenLabs ? "https://api.elevenlabs.io/v1" : "http://127.0.0.1:8090/v1";

    /// <summary>ElevenLabs has no call that lists music models; these are the documented ones.</summary>
    public static IReadOnlyList<string> KnownModels(string format) =>
        format == ElevenLabs ? ["music_v1", "music_v2", "music_v2_5"] : [];

    private string CredentialId => "music." + Id;
    /// <summary>Kept in the platform secret store, so settings.json never holds a credential.</summary>
    public string? ApiKey(IProviderSecretStore secrets) => secrets.Read(CredentialId);

    public void SetApiKey(IProviderSecretStore secrets, string? key)
    {
        if (string.IsNullOrWhiteSpace(key)) secrets.Delete(CredentialId);
        else secrets.Write(CredentialId, key.Trim());
    }
}

/// <summary>Where the studio's generated images, videos and music come from.</summary>
public sealed class MediaStudioSettings
{
    public const string Provider = "provider";
    public const string Local = "local";

    /// <summary>Chat model that plans layers. Empty follows the app's selected model.</summary>
    public string PlannerModelID { get; set; } = "";
    public string ImageSource { get; set; } = Provider;
    /// <summary>Empty uses the provider's own default image model.</summary>
    public string ImageModel { get; set; } = "";
    public string VideoSource { get; set; } = Provider;
    public string VideoModel { get; set; } = "";
    public string MusicSource { get; set; } = Provider;
    public string MusicModel { get; set; } = "";
    /// <summary>Music APIs connected by address, and the one in use. Empty follows <see cref="MusicSource"/>.</summary>
    public List<MusicEndpoint> MusicEndpoints { get; set; } = [];
    public string MusicEndpointID { get; set; } = "";
    public string LocalBaseURL { get; set; } = "http://127.0.0.1:8080/v1";

    [JsonIgnore] public MusicEndpoint? MusicEndpoint => MusicEndpoints.FirstOrDefault(e => e.Id == MusicEndpointID);

    public string SourceFor(NativeMediaKind kind) => kind switch
    {
        NativeMediaKind.Video => VideoSource,
        NativeMediaKind.Music => MusicSource,
        _ => ImageSource,
    };

    public string ModelFor(NativeMediaKind kind) => (kind switch
    {
        NativeMediaKind.Video => VideoModel,
        NativeMediaKind.Music => MusicEndpoint?.Model ?? MusicModel,
        _ => ImageModel,
    }).Trim();
}

/// <summary>One folder per project under the root: <c>project.json</c> plus an <c>assets</c> folder.</summary>
public class StudioProjectStore<TProject> where TProject : class, IStudioProject
{
    private readonly string _fallbackAssetExtension;
    protected bool HasLoaded { get; private set; }

    protected StudioProjectStore(string root, string fallbackAssetExtension)
    {
        Root = root;
        _fallbackAssetExtension = fallbackAssetExtension;
    }

    public string Root { get; }
    public List<TProject> Projects { get; private set; } = [];
    /// <summary>The project open in the editor, which takes over the section while it is set.</summary>
    public string? OpenProjectId { get; set; }
    public event Action? Changed;

    protected void RaiseChanged() => Changed?.Invoke();

    /// <summary>Reads every project from disk once; the views call it when the studio first appears.</summary>
    public virtual void LoadIfNeeded()
    {
        if (HasLoaded) return;
        HasLoaded = true;
        if (!System.IO.Directory.Exists(Root)) return;
        Projects = System.IO.Directory.GetDirectories(Root)
            .Select(folder => Read<TProject>(Path.Combine(folder, "project.json")))
            .OfType<TProject>()
            .OrderByDescending(project => project.UpdatedAt)
            .ToList();
    }

    public TProject? Find(string? id) => id is null ? null : Projects.FirstOrDefault(project => project.Id == id);

    public void Save(TProject project)
    {
        project.UpdatedAt = DateTimeOffset.Now;
        Write(project, Path.Combine(Directory(project.Id), "project.json"));
        Projects.RemoveAll(existing => existing.Id == project.Id);
        Projects.Insert(0, project);
        RaiseChanged();
    }

    public void Delete(string id)
    {
        try { System.IO.Directory.Delete(Directory(id), recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        Projects.RemoveAll(project => project.Id == id);
        if (OpenProjectId == id) OpenProjectId = null;
        RaiseChanged();
    }

    public void Rename(string id, string name)
    {
        name = name.Trim();
        if (name.Length == 0 || Find(id) is not { } project) return;
        project.Name = name;
        Save(project);
    }

    public string Directory(string id) => Path.Combine(Root, id);

    public string AssetPath(string projectId, string name) => Path.Combine(Directory(projectId), "assets", name);

    /// <summary>Copies a file into the project so the project never depends on where it came from.</summary>
    public string ImportAsset(string source, string projectId)
    {
        var assets = Path.Combine(Directory(projectId), "assets");
        System.IO.Directory.CreateDirectory(assets);
        var extension = Path.GetExtension(source).TrimStart('.').ToLowerInvariant();
        var name = $"{Guid.NewGuid().ToString().ToUpperInvariant()}.{(extension.Length == 0 ? _fallbackAssetExtension : extension)}";
        File.Copy(source, Path.Combine(assets, name));
        return name;
    }

    protected static T? Read<T>(string path) where T : class
    {
        try { return File.Exists(path) ? JsonSerializer.Deserialize<T>(File.ReadAllText(path), MediaStudioJson.Options) : null; }
        catch (JsonException) { return null; }
        catch (IOException) { return null; }
    }

    protected static void Write<T>(T value, string path)
    {
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(value, MediaStudioJson.Options));
        File.Move(path + ".tmp", path, overwrite: true);
    }

    protected static void CopyDirectory(string source, string target)
    {
        if (!System.IO.Directory.Exists(source)) return;
        foreach (var directory in System.IO.Directory.GetDirectories(source, "*", SearchOption.AllDirectories))
            System.IO.Directory.CreateDirectory(directory.Replace(source, target));
        System.IO.Directory.CreateDirectory(target);
        foreach (var file in System.IO.Directory.GetFiles(source, "*", SearchOption.AllDirectories))
            File.Copy(file, file.Replace(source, target), overwrite: true);
    }
}

public sealed class MediaStudioStore : StudioProjectStore<MediaProject>
{
    private MediaStudioSettings _settings = new();

    public MediaStudioStore(string root) : base(root, "bin") { }

    public MediaStudioSettings Settings
    {
        get => _settings;
        set
        {
            _settings = value;
            Write(value, Path.Combine(Root, "settings.json"));
            RaiseChanged();
        }
    }

    public override void LoadIfNeeded()
    {
        if (HasLoaded) return;
        if (Read<MediaStudioSettings>(Path.Combine(Root, "settings.json")) is { } saved) _settings = saved;
        base.LoadIfNeeded();
    }

    public MediaProject Create(string name, MediaCanvas? canvas = null)
    {
        var project = new MediaProject { Name = name, Canvases = canvas is null ? [] : [canvas] };
        Save(project);
        return project;
    }

    public void Duplicate(string id)
    {
        if (Find(id) is not { } original) return;
        var copy = original.Clone();
        copy.Id = Guid.NewGuid().ToString();
        copy.Name = LocalizationService.Current.Get("studio.copyOf", copy.Name);
        CopyDirectory(Directory(id), Directory(copy.Id));
        Save(copy);
    }
}

/// <summary>Turns a written request into layer edits, and prompts into generated media.</summary>
public static class MediaStudioAI
{
    public sealed record Step(MediaLayer Layer, string? ImagePrompt);

    public sealed record Plan(string? Name, string? BackgroundHex, IReadOnlyList<string> Removals, IReadOnlyList<MediaLayer> Updates, IReadOnlyList<Step> Steps);

    public const int MaxLayers = 60;
    public const string NextScreenRequest = "Design the screen that naturally follows the reference in this flow.";

    public static string Instructions(bool imagesAvailable) =>
        "You design canvases for a graphics editor that works like Figma. Reply with a single JSON object and nothing else:\n" +
        "{\"name\":\"canvas name\",\"background\":\"#RRGGBB\",\"remove\":[\"L2\"],\"update\":[{\"id\":\"L1\",\"color\":\"#RRGGBB\"}]," +
        "\"layers\":[{\"type\":\"shape|text|icon|image\",\"name\":\"short label\",\"x\":0,\"y\":0,\"width\":0,\"height\":0," +
        "\"rotation\":0,\"opacity\":1,\"color\":\"#RRGGBB\",\"color2\":\"#RRGGBB\",\"stroke\":\"#RRGGBB\",\"strokeWidth\":0,\"shadow\":0," +
        "\"shape\":\"rectangle|ellipse|polygon|star\",\"cornerRadius\":0,\"text\":\"\",\"fontSize\":0,\"fontWeight\":\"regular|medium|bold\"," +
        "\"font\":\"default|rounded|serif|mono\",\"align\":\"leading|center|trailing\",\"symbol\":\"\",\"prompt\":\"\"}]}\n" +
        "Every key is optional; leave out what you do not need. \"layers\" are new layers, drawn above the existing " +
        "ones in the order given, back to front. \"update\" changes existing layers by id and takes the same fields; " +
        "give only the fields that change. \"remove\" deletes existing layers. When the request changes the existing " +
        "design, use \"update\" and \"remove\" instead of adding duplicates. \"background\" recolours the canvas.\n" +
        "Coordinates are points from the canvas's top-left corner and every layer must fit inside the canvas. " +
        "\"color\" fills a shape, colours text or an icon, and tints an image that has no picture yet. \"color2\" turns " +
        "that fill into a diagonal gradient. \"shadow\" is a blur radius. For an icon, \"symbol\" is an SF Symbols name " +
        "such as pawprint.fill, heart.fill, star.fill, bell.fill, house.fill, cart.fill, person.fill, magnifyingglass, " +
        "arrow.right, checkmark.circle.fill, play.fill, leaf.fill, bolt.fill, camera.fill, mappin, calendar, envelope.fill.\n" +
        "Work like a designer: background washes and large decorative shapes first, then cards and panels, then " +
        "icons and text. A button is a rounded rectangle with a text layer over it. Give text layers a box wide and " +
        "tall enough for their words at the chosen size. Name each layer the way it should read in a layers panel. " +
        $"Use at most {MaxLayers} layers, keep text short, and write text in the language of the request.\n" +
        (imagesAvailable
            ? "Use image layers only for photos and illustrations; \"prompt\" is a complete description for an image generator."
            : "No image generator is connected: do not add image layers. Draw illustrations from shapes, gradients and icons.");

    /// <summary>Layers are shown to the model as L1…Ln, back to front.</summary>
    public static string Describe(MediaCanvas canvas)
    {
        if (canvas.Layers.Count == 0) return "none";
        return string.Join("\n", canvas.Layers.Select((layer, index) =>
        {
            var item = new SortedDictionary<string, object>(StringComparer.Ordinal)
            {
                ["id"] = $"L{index + 1}", ["type"] = layer.Kind, ["name"] = layer.Name,
                ["x"] = (int)layer.X, ["y"] = (int)layer.Y, ["width"] = (int)layer.Width, ["height"] = (int)layer.Height,
                ["color"] = layer.ColorHex,
            };
            if (layer.Rotation != 0) item["rotation"] = (int)layer.Rotation;
            if (layer.Opacity < 1) item["opacity"] = Math.Round(layer.Opacity * 100) / 100;
            if (layer.GradientHex is { } gradient) item["color2"] = gradient;
            if (layer.StrokeHex is { } stroke && layer.StrokeWidth > 0)
            {
                item["stroke"] = stroke;
                item["strokeWidth"] = (int)layer.StrokeWidth;
            }
            if (layer.Shadow > 0) item["shadow"] = (int)layer.Shadow;
            if (layer.Hidden) item["hidden"] = true;
            switch (layer.Kind)
            {
                case "text":
                    item["text"] = layer.Text;
                    item["fontSize"] = (int)layer.FontSize;
                    item["fontWeight"] = layer.FontWeight;
                    item["font"] = layer.FontDesign;
                    item["align"] = layer.Alignment;
                    break;
                case "shape":
                    item["shape"] = layer.Shape;
                    if (layer.CornerRadius > 0) item["cornerRadius"] = (int)layer.CornerRadius;
                    break;
                case "icon":
                    item["symbol"] = layer.Symbol;
                    break;
                case "image" when layer.Prompt is { } prompt:
                    item["prompt"] = prompt;
                    break;
            }
            return JsonSerializer.Serialize(item);
        }));
    }

    /// <summary><paramref name="reference"/> is the screen a new canvas should follow on from.</summary>
    public static List<NativeMessage> PlanMessages(string prompt, MediaCanvas canvas, string? selectedLayerId = null,
        MediaCanvas? reference = null, bool imagesAvailable = true)
    {
        var state = $"Canvas \"{canvas.Name}\": {(int)canvas.Width}x{(int)canvas.Height} points, background {canvas.BackgroundHex}.\n" +
            $"Layers, back to front:\n{Describe(canvas)}";
        var index = canvas.Layers.FindIndex(layer => layer.Id == selectedLayerId);
        if (index >= 0) state += $"\nSelected layer (what \"this\" means in the request): L{index + 1}";
        if (reference is not null)
        {
            state += $"\n\nReference: the previous screen \"{reference.Name}\", {(int)reference.Width}x{(int)reference.Height}, " +
                $"background {reference.BackgroundHex}. Keep its palette, type, spacing and recurring elements such as " +
                "the logo and navigation, in the same places. Its layer ids cannot be updated; add new layers.\n" +
                Describe(reference);
        }
        state += $"\n\nRequest: {prompt}";
        return [new("system", Instructions(imagesAvailable)), new("user", state)];
    }

    private static double? Number(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<double>(out var number) ? number : null;

    private static string? Str(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static readonly Regex HexPattern = new("^#[0-9A-Fa-f]{6}$", RegexOptions.Compiled);

    private static string? Hex(JsonNode? node) =>
        Str(node)?.Trim() is { } raw && HexPattern.IsMatch(raw) ? raw.ToUpperInvariant() : null;

    private static double Clamp(double value, double min, double max) => Math.Min(Math.Max(value, min), Math.Max(min, max));

    /// <summary>Copies the fields <paramref name="item"/> carries onto the layer, then pulls the result back inside the canvas.</summary>
    private static void Apply(JsonObject item, MediaLayer layer, MediaCanvas canvas)
    {
        if (Str(item["name"]) is { Length: > 0 } name) layer.Name = name.Length > 40 ? name[..40] : name;
        layer.Width = Clamp(Number(item["width"]) ?? layer.Width, 0, canvas.Width);
        layer.Height = Clamp(Number(item["height"]) ?? layer.Height, 0, canvas.Height);
        layer.X = Clamp(Number(item["x"]) ?? layer.X, 0, canvas.Width - layer.Width);
        layer.Y = Clamp(Number(item["y"]) ?? layer.Y, 0, canvas.Height - layer.Height);
        if (Number(item["rotation"]) is { } rotation) layer.Rotation = Math.IEEERemainder(rotation, 360);
        if (Number(item["opacity"]) is { } opacity) layer.Opacity = Clamp(opacity, 0.05, 1);
        if (item["hidden"] is JsonValue hidden && hidden.TryGetValue<bool>(out var isHidden)) layer.Hidden = isHidden;
        if (Hex(item["color"]) is { } color) layer.ColorHex = color;
        if (item.ContainsKey("color2")) layer.GradientHex = Hex(item["color2"]);
        if (item.ContainsKey("stroke")) layer.StrokeHex = Hex(item["stroke"]);
        if (Number(item["strokeWidth"]) is { } strokeWidth) layer.StrokeWidth = Clamp(strokeWidth, 0, 200);
        if (Number(item["shadow"]) is { } shadow) layer.Shadow = Clamp(shadow, 0, 200);
        if (Str(item["text"]) is { } text) layer.Text = text;
        if (Number(item["fontSize"]) is { } fontSize) layer.FontSize = Clamp(fontSize, 6, 600);
        if (Str(item["fontWeight"]) is "regular" or "medium" or "bold") layer.FontWeight = Str(item["fontWeight"])!;
        if (Str(item["font"]) is "default" or "rounded" or "serif" or "mono") layer.FontDesign = Str(item["font"])!;
        if (Str(item["align"]) is "leading" or "center" or "trailing") layer.Alignment = Str(item["align"])!;
        if (Str(item["shape"]) is "rectangle" or "ellipse" or "polygon" or "star") layer.Shape = Str(item["shape"])!;
        if (Str(item["symbol"]) is { Length: > 0 } symbol) layer.Symbol = symbol;
        if (Str(item["prompt"])?.Trim() is { Length: > 0 } prompt) layer.Prompt = prompt;
        layer.CornerRadius = Clamp(Number(item["cornerRadius"]) ?? layer.CornerRadius, 0, Math.Min(layer.Width, layer.Height) / 2);
    }

    /// <summary>Tolerant of prose or code fences around the object; entries the model got wrong are dropped, not fatal.</summary>
    public static Plan? ParsePlan(string text, MediaCanvas canvas)
    {
        var start = text.IndexOf('{');
        var end = text.LastIndexOf('}');
        if (start < 0 || end <= start) return null;
        JsonObject? root;
        try { root = JsonNode.Parse(text[start..(end + 1)]) as JsonObject; }
        catch (JsonException) { return null; }
        if (root is null) return null;

        MediaLayer? Existing(JsonNode? node) =>
            Str(node) is { } id && id.StartsWith('L') && int.TryParse(id[1..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var index)
            && index >= 1 && index <= canvas.Layers.Count ? canvas.Layers[index - 1] : null;

        var removals = (root["remove"] as JsonArray ?? []).Select(Existing).OfType<MediaLayer>().Select(layer => layer.Id).ToList();
        var updates = (root["update"] as JsonArray ?? []).OfType<JsonObject>().Select(item =>
        {
            if (Existing(item["id"]) is not { } existing || removals.Contains(existing.Id)) return null;
            var layer = existing.Clone();
            Apply(item, layer, canvas);
            return layer.Width >= 1 && layer.Height >= 1 ? layer : null;
        }).OfType<MediaLayer>().ToList();
        var steps = (root["layers"] as JsonArray ?? []).OfType<JsonObject>().Take(MaxLayers).Select(item =>
        {
            var kind = Str(item["type"]);
            if (kind is not ("text" or "image" or "shape" or "icon")) return null;
            var layer = new MediaLayer
            {
                Name = char.ToUpperInvariant(kind[0]) + kind[1..], Kind = kind,
                ColorHex = kind is "text" or "icon" ? "#111111" : "#D9D9D9",
            };
            Apply(item, layer, canvas);
            if (layer.Width < 1 || layer.Height < 1) return null;
            if (kind == "text" && layer.Text.Length == 0) return null;
            return new Step(layer, kind == "image" ? layer.Prompt : null);
        }).OfType<Step>().ToList();
        var background = Hex(root["background"]);
        if (steps.Count == 0 && updates.Count == 0 && removals.Count == 0 && background is null) return null;
        var planName = Str(root["name"])?.Trim();
        return new Plan(string.IsNullOrEmpty(planName) ? null : planName.Length > 40 ? planName[..40] : planName,
            background, removals, updates, steps);
    }

    public static bool CanGenerateImages(RouterController router, MediaStudioSettings settings) =>
        settings.ImageSource == MediaStudioSettings.Local ? settings.ModelFor(NativeMediaKind.Image).Length > 0 : router.HasActiveRoute;

    public static string UsableModel(RouterController router, string id) =>
        !string.IsNullOrWhiteSpace(id) && router.Models.Contains(id) ? id : "";

    public static async Task<Plan> PlanAsync(string prompt, MediaCanvas canvas, string? selectedLayerId, MediaCanvas? reference,
        bool imagesAvailable, RouterController router, MediaStudioSettings settings, CancellationToken ct = default)
    {
        var model = UsableModel(router, settings.PlannerModelID);
        var response = await router.CompleteAsync(PlanMessages(prompt, canvas, selectedLayerId, reference, imagesAvailable), [],
            model.Length == 0 ? null : model, ct);
        return ParsePlan(response.Message.Content, canvas)
            ?? throw new InvalidOperationException(LocalizationService.Current.Get("studio.ai.noPlan"));
    }

    /// <summary>Generates media for the studio and files it in the library. Returns the saved file.</summary>
    public static async Task<NativeGeneratedMedia> GenerateAsync(NativeMediaKind kind, string prompt, RouterController router,
        MediaStudioSettings settings, SupportPaths paths, IProviderSecretStore secrets, int? seconds = null,
        MusicStemRequest? stem = null, CancellationToken ct = default)
    {
        var model = settings.ModelFor(kind);
        NativeGeneratedMedia media;
        if (kind == NativeMediaKind.Music && settings.MusicEndpoint is { } endpoint)
        {
            media = await NativeMediaGenerator.GenerateToFileAsync(kind, prompt, endpoint.BaseURL, endpoint.ApiKey(secrets),
                new NativeMediaSpec(model, Format: endpoint.Format), paths.Root, endpoint.Name, seconds, stem, ct);
        }
        else if (settings.SourceFor(kind) == MediaStudioSettings.Local)
        {
            if (model.Length == 0) throw new InvalidOperationException(LocalizationService.Current.Get("media.modelMissing"));
            media = await NativeMediaGenerator.GenerateToFileAsync(kind, prompt, settings.LocalBaseURL, null,
                new NativeMediaSpec(model), paths.Root, "Local", seconds, stem, ct);
        }
        else if (kind == NativeMediaKind.Image)
        {
            var generated = await router.GenerateImageAsync(prompt, ct);
            var path = NativeImageFileStore.Save(generated.Output, paths.Root, prompt);
            media = new NativeGeneratedMedia(kind, path, generated.Output.MimeType, generated.Provider, generated.Model);
        }
        else
        {
            media = await router.GenerateMediaAsync(kind, prompt, paths.Root, ct);
        }
        MediaLibrary.Record(media.FilePath, MediaLibrary.KindOf(kind), prompt, paths.Root);
        return media;
    }
}
