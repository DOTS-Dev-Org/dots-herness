// Copyright (c) 2026 DOTS
// Library: one index of everything the app generated or the user filed in it —
// images, videos, speech, music and documents. Mirrors MediaLibrary.swift on macOS.

using System.Text.Json;

namespace DotsHarnessCore;

public sealed class MediaLibraryItem
{
    public static readonly string[] Kinds = ["image", "video", "audio", "music", "document"];

    public string Id { get; set; } = Guid.NewGuid().ToString();
    /// <summary>image, video, audio, music or document.</summary>
    public string Kind { get; set; } = "document";
    /// <summary>The prompt that made it, or the name of the file it was added from. May be empty.</summary>
    public string Title { get; set; } = "";
    public string Path { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    /// <summary>Library organization metadata; absent in older index files and treated as empty.</summary>
    public bool Favorite { get; set; }
    public string Folder { get; set; } = "";
    public List<string> Tags { get; set; } = [];
    /// <summary>Text recognized on-device. It is never populated by sending the file to a provider.</summary>
    public string OcrText { get; set; } = "";

    public string DisplayTitle => Title.Length > 0 ? Title : LocalizationService.Current.Get($"library.kind.{Kind}");

    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase) { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".tif", ".tiff", ".svg" };
    private static readonly HashSet<string> VideoExtensions = new(StringComparer.OrdinalIgnoreCase) { ".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi" };
    private static readonly HashSet<string> AudioExtensions = new(StringComparer.OrdinalIgnoreCase) { ".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".opus" };

    /// <summary>What a file the user adds is filed as. Anything that is not media is a document.</summary>
    public static string KindOfFile(string file)
    {
        var extension = System.IO.Path.GetExtension(file);
        return ImageExtensions.Contains(extension) ? "image"
            : VideoExtensions.Contains(extension) ? "video"
            : AudioExtensions.Contains(extension) ? "audio"
            : "document";
    }
}

/// <summary>The index on disk. Callable from any thread, so generation can file its output.</summary>
public static class MediaLibrary
{
    private static readonly object Gate = new();
    private static readonly JsonSerializerOptions Options = MediaStudioJson.Options;

    /// <summary>Raised after the index changed, on whichever thread changed it.</summary>
    public static event Action? Changed;

    public static string KindOf(NativeMediaKind kind) => kind switch
    {
        NativeMediaKind.Video => "video",
        NativeMediaKind.Audio => "audio",
        NativeMediaKind.Music => "music",
        _ => "image",
    };

    private static string Directory(string root) => System.IO.Path.Combine(root, "library");
    private static string Index(string root) => System.IO.Path.Combine(Directory(root), "index.json");
    /// <summary>Copies of files the user added. Generated media stays where generation wrote it.</summary>
    private static string Files(string root) => System.IO.Path.Combine(Directory(root), "files");

    /// <summary>Newest first.</summary>
    public static List<MediaLibraryItem> Items(string root)
    {
        lock (Gate) return Read(root);
    }

    /// <summary>Files <paramref name="file"/> under <paramref name="kind"/>. A path already in the library keeps its entry.</summary>
    public static MediaLibraryItem Record(string file, string kind, string? prompt, string root) => Mutate(root, items =>
    {
        if (items.FirstOrDefault(item => item.Path == file) is { } existing) return existing;
        var line = (prompt ?? "").Split('\n', 2)[0].Trim();
        var item = new MediaLibraryItem { Kind = kind, Title = line.Length > 80 ? line[..80] : line, Path = file };
        items.Insert(0, item);
        return item;
    });

    /// <summary>Copies a file into the library so the entry never depends on where it came from.</summary>
    public static MediaLibraryItem ImportFile(string source, string root)
    {
        var folder = Files(root);
        System.IO.Directory.CreateDirectory(folder);
        var extension = System.IO.Path.GetExtension(source).ToLowerInvariant();
        var copy = System.IO.Path.Combine(folder, Guid.NewGuid().ToString().ToUpperInvariant() + (extension.Length == 0 ? ".bin" : extension));
        File.Copy(source, copy);
        return Record(copy, MediaLibraryItem.KindOfFile(source), System.IO.Path.GetFileName(source), root);
    }

    /// <summary>Drops the entry. Only the library's own copy is deleted from disk.</summary>
    public static void Remove(string id, string root) => Mutate(root, items =>
    {
        var index = items.FindIndex(item => item.Id == id);
        if (index < 0) return 0;
        var item = items[index];
        items.RemoveAt(index);
        if (item.Path.StartsWith(Files(root) + System.IO.Path.DirectorySeparatorChar, StringComparison.Ordinal))
        {
            try { File.Delete(item.Path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        return 0;
    });

    public static void Update(string id, string root, Action<MediaLibraryItem> change) => Mutate(root, items =>
    {
        if (items.FirstOrDefault(item => item.Id == id) is { } item) change(item);
        return 0;
    });

    /// <summary>Copies selected library files to a user-chosen folder, resolving duplicate names safely.</summary>
    public static int Export(IEnumerable<string> ids, string destination, string root)
    {
        var selected = ids.ToHashSet(StringComparer.Ordinal);
        var items = Items(root).Where(item => selected.Contains(item.Id) && File.Exists(item.Path)).ToList();
        System.IO.Directory.CreateDirectory(destination);
        foreach (var item in items)
        {
            var baseName = System.IO.Path.GetFileNameWithoutExtension(item.Path);
            var extension = System.IO.Path.GetExtension(item.Path);
            var target = System.IO.Path.Combine(destination, baseName + extension);
            for (var suffix = 2; File.Exists(target); suffix++) target = System.IO.Path.Combine(destination, $"{baseName} ({suffix}){extension}");
            File.Copy(item.Path, target);
        }
        return items.Count;
    }

    // ponytail: one JSON file rewritten per change; move to SQLite when a library reaches tens of thousands of items.
    private static T Mutate<T>(string root, Func<List<MediaLibraryItem>, T> change)
    {
        T result;
        bool changed;
        lock (Gate)
        {
            var items = Read(root);
            var before = JsonSerializer.Serialize(items, Options);
            result = change(items);
            var after = JsonSerializer.Serialize(items, Options);
            changed = before != after;
            if (changed)
            {
                System.IO.Directory.CreateDirectory(Directory(root));
                File.WriteAllText(Index(root) + ".tmp", after);
                File.Move(Index(root) + ".tmp", Index(root), overwrite: true);
            }
        }
        if (changed) Changed?.Invoke();
        return result;
    }

    private static List<MediaLibraryItem> Read(string root)
    {
        try
        {
            return File.Exists(Index(root))
                ? JsonSerializer.Deserialize<List<MediaLibraryItem>>(File.ReadAllText(Index(root)), Options) ?? []
                : [];
        }
        catch (JsonException) { return []; }
        catch (IOException) { return []; }
    }
}
