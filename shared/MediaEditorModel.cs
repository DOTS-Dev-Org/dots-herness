// Copyright (c) 2026 DOTS
// Editing state for one media project: selection, viewport, history and AI runs.
// The platform-neutral half of macOS MediaEditorState.swift; the Windows and Linux
// editors draw it and feed it pointer input. Points are board coordinates unless named "screen".

using System.Text.Json;
using PluginRuntime;

namespace DotsHarnessCore;

public readonly record struct BoardPoint(double X, double Y);

public readonly record struct BoardRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public bool Contains(BoardPoint p) => p.X >= X && p.X <= Right && p.Y >= Y && p.Y <= Bottom;
    public bool Contains(BoardRect r) => r.X >= X && r.Y >= Y && r.Right <= Right && r.Bottom <= Bottom;
    public static BoardRect Of(MediaCanvas c) => new(c.X, c.Y, c.Width, c.Height);
}

/// <summary>What a press on the board does.</summary>
public static class MediaTools
{
    public static readonly string[] All =
    [
        "move", "hand", "scale", "frame", "section", "slice", "rectangle", "line", "arrow", "ellipse", "polygon", "star",
        "pen", "pencil", "text", "textPath", "comment",
    ];

    public static string Title(string tool) => tool switch
    {
        "frame" => LocalizationService.Current.Get("studio.addCanvas"),
        "text" => LocalizationService.Current.Get("studio.layer.text"),
        "rectangle" or "ellipse" or "polygon" or "star" or "line" or "arrow" => LocalizationService.Current.Get($"studio.shape.{tool}"),
        _ => LocalizationService.Current.Get($"studio.tool.{tool}"),
    };

    /// <summary>Key that picks the tool; uppercase means with Shift.</summary>
    public static char? Key(string tool) => tool switch
    {
        "move" => 'v', "hand" => 'h', "scale" => 'k', "frame" => 'f', "section" => 'S', "slice" => 's',
        "rectangle" => 'r', "line" => 'l', "arrow" => 'L', "ellipse" => 'o', "pen" => 'p', "pencil" => 'P',
        "text" => 't', "comment" => 'c', _ => null,
    };

    public static string Glyph(string tool) => tool switch
    {
        "move" => "➤", "hand" => "✋", "scale" => "⤡", "frame" => "#", "section" => "⬚", "slice" => "✂",
        "rectangle" => "□", "line" => "╱", "arrow" => "↗", "ellipse" => "○", "polygon" => "△", "star" => "☆",
        "pen" => "✒", "pencil" => "✏", "text" => "T", "textPath" => "Ŧ", "comment" => "💬", _ => "•",
    };
}

public sealed class MediaEditorModel
{
    public const double MinZoom = 0.05, MaxZoom = 8;
    public const int HistoryLimit = 25;

    private readonly List<string> _undo = [];
    private readonly List<string> _redo = [];
    private CancellationTokenSource? _ai;
    private static string? _lastClip;

    public MediaEditorModel(MediaProject project, MediaStudioStore store)
    {
        Project = project;
        Store = store;
        CanvasId = project.Canvases.FirstOrDefault()?.Id;
        // An empty board opens on the canvas tool, with the ready-made sizes beside it.
        if (project.Canvases.Count == 0) Tool = "frame";
    }

    public MediaProject Project { get; private set; }
    public MediaStudioStore Store { get; }
    public string? CanvasId { get; set; }
    public string? LayerId { get; set; }
    public string Tool { get; set; } = "move";
    public double Zoom { get; set; } = 0.5;
    /// <summary>Screen position of the board's origin, relative to the viewport centre.</summary>
    public double PanX { get; set; }
    public double PanY { get; set; }
    public double ViewportWidth { get; set; }
    public double ViewportHeight { get; set; }
    public bool AiBusy { get; private set; }
    public string AiStatus { get; private set; } = "";
    public string? AiError { get; set; }
    public string? AiNote { get; set; }
    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;
    /// <summary>Raised after anything the editor shows changed. Always on the caller's thread.</summary>
    public event Action? Changed;
    /// <summary>Asks the UI for an image or video file's natural size; null when unknown.</summary>
    public Func<string, (double Width, double Height)?>? NaturalSize { get; set; }

    public void Notify() => Changed?.Invoke();

    public MediaCanvas? Canvas => Project.Canvases.FirstOrDefault(c => c.Id == CanvasId);
    public MediaLayer? Layer => Canvas?.Layers.FirstOrDefault(l => l.Id == LayerId);
    public string AssetPath(string name) => Store.AssetPath(Project.Id, name);

    // History

    private string Snapshot() => JsonSerializer.Serialize(Project.Canvases, MediaStudioJson.Options);

    /// <summary>Call before a change the user should be able to undo.</summary>
    public void Checkpoint()
    {
        _undo.Add(Snapshot());
        if (_undo.Count > HistoryLimit) _undo.RemoveAt(0);
        _redo.Clear();
    }

    public void Commit()
    {
        Store.Save(Project);
        Notify();
    }

    public void Undo()
    {
        if (_undo.Count == 0) return;
        _redo.Add(Snapshot());
        Restore(Pop(_undo));
    }

    public void Redo()
    {
        if (_redo.Count == 0) return;
        _undo.Add(Snapshot());
        Restore(Pop(_redo));
    }

    private static string Pop(List<string> stack)
    {
        var last = stack[^1];
        stack.RemoveAt(stack.Count - 1);
        return last;
    }

    private void Restore(string snapshot)
    {
        Project.Canvases = JsonSerializer.Deserialize<List<MediaCanvas>>(snapshot, MediaStudioJson.Options) ?? [];
        if (Canvas is null) CanvasId = Project.Canvases.FirstOrDefault()?.Id;
        if (Layer is null) LayerId = null;
        Commit();
    }

    // Edits

    public MediaCanvas? FindCanvas(string? id) => Project.Canvases.FirstOrDefault(c => c.Id == id);

    public void UpdateCanvas(string id, Action<MediaCanvas> change)
    {
        if (FindCanvas(id) is not { } canvas) return;
        change(canvas);
        // A typed-in zero would divide by zero wherever the canvas is scaled to fit.
        canvas.Width = Math.Max(1, canvas.Width);
        canvas.Height = Math.Max(1, canvas.Height);
    }

    public void UpdateLayer(string id, string canvasId, Action<MediaLayer> change) => UpdateCanvas(canvasId, canvas =>
    {
        if (canvas.Layers.FirstOrDefault(l => l.Id == id) is not { } layer) return;
        change(layer);
        layer.Width = Math.Max(1, layer.Width);
        layer.Height = Math.Max(1, layer.Height);
    });

    public void Select(string canvasId, string? layerId = null)
    {
        CanvasId = canvasId;
        LayerId = layerId;
        Notify();
    }

    /// <summary>Selects by either kind of id, as the layers panel reports them.</summary>
    public void SelectAny(string? id)
    {
        if (id is null) return;
        if (FindCanvas(id) is not null) Select(id);
        else if (Project.Canvases.FirstOrDefault(c => c.Layers.Any(l => l.Id == id)) is { } owner) Select(owner.Id, id);
    }

    /// <summary>New canvases line up to the right of the existing ones.</summary>
    public void AddCanvas(MediaCanvas canvas)
    {
        Checkpoint();
        canvas.X = (Project.Canvases.Count == 0 ? -120 : Project.Canvases.Max(c => c.X + c.Width)) + 120;
        canvas.Y = Project.Canvases.FirstOrDefault()?.Y ?? 0;
        Project.Canvases.Add(canvas);
        CanvasId = canvas.Id;
        LayerId = null;
        Fit();
        Commit();
    }

    public void DuplicateSelectedCanvas()
    {
        if (Canvas?.Clone() is not { } copy) return;
        copy.Id = Guid.NewGuid().ToString();
        copy.ParentID = null;
        copy.Name = LocalizationService.Current.Get("studio.copyOf", copy.Name);
        foreach (var layer in copy.Layers) layer.Id = Guid.NewGuid().ToString();
        AddCanvas(copy);
    }

    public void AddLayer(MediaLayer layer)
    {
        if ((CanvasId ?? Project.Canvases.FirstOrDefault()?.Id) is not { } id) return;
        Checkpoint();
        UpdateCanvas(id, c => c.Layers.Add(layer));
        CanvasId = id;
        LayerId = layer.Id;
        Commit();
    }

    public BoardPoint BoardPointAt(double screenX, double screenY) =>
        new((screenX - ViewportWidth / 2 - PanX) / Zoom, (screenY - ViewportHeight / 2 - PanY) / Zoom);

    public (double X, double Y) ScreenPoint(double x, double y) =>
        (ViewportWidth / 2 + PanX + x * Zoom, ViewportHeight / 2 + PanY + y * Zoom);

    private MediaCanvas? Target(BoardPoint point) => Hit(point) ?? Canvas;

    /// <summary>The innermost canvas under a board point; a canvas wins over the section it sits in.</summary>
    public MediaCanvas? Hit(BoardPoint point)
    {
        var under = OrderedCanvases.Where(c => BoardRect.Of(c).Contains(point)).ToList();
        return under.LastOrDefault(c => c.Section != true) ?? under.LastOrDefault();
    }

    // Nesting

    /// <summary>Every canvas inside <paramref name="id"/>, parents before their children.</summary>
    public List<MediaCanvas> Descendants(string id) =>
        Project.Canvases.Where(c => c.ParentID == id).SelectMany(c => new[] { c }.Concat(Descendants(c.Id))).ToList();

    /// <summary>Drawing order: each canvas after the one that holds it, sections under their neighbours.</summary>
    public List<MediaCanvas> OrderedCanvases
    {
        get
        {
            var roots = Project.Canvases.Where(c => c.ParentID is null).ToList();
            return roots.Where(c => c.Section == true).Concat(roots.Where(c => c.Section != true))
                .SelectMany(c => new[] { c }.Concat(Descendants(c.Id))).ToList();
        }
    }

    /// <summary>A moved or drawn canvas belongs to the smallest canvas that wholly contains it, if any.</summary>
    public void ReparentCanvas(string id)
    {
        if (FindCanvas(id) is not { } moved) return;
        var inside = Descendants(id).Select(c => c.Id).ToHashSet();
        var holder = Project.Canvases
            .Where(c => c.Id != id && !inside.Contains(c.Id) && BoardRect.Of(c).Contains(BoardRect.Of(moved)))
            .MinBy(c => c.Width * c.Height);
        moved.ParentID = holder?.Id;
    }

    /// <summary>After a layer is dragged: if its centre now lies over another canvas, it moves into that canvas.</summary>
    public void RehomeLayer(string id, string canvasId)
    {
        if (FindCanvas(canvasId) is not { } source || source.Layers.FirstOrDefault(l => l.Id == id) is not { } layer) return;
        if (Hit(new(source.X + layer.X + layer.Width / 2, source.Y + layer.Y + layer.Height / 2)) is not { } destination
            || destination.Id == source.Id) return;
        source.Layers.Remove(layer);
        layer.X += source.X - destination.X;
        layer.Y += source.Y - destination.Y;
        destination.Layers.Add(layer);
        CanvasId = destination.Id;
        LayerId = id;
    }

    // Clipboard

    private sealed class Clip
    {
        public string ProjectID { get; set; } = "";
        public List<MediaLayer> Layers { get; set; } = [];
        public List<MediaCanvas> Canvases { get; set; } = [];
    }

    /// <summary>The selected layer, or the selected canvas with everything nested in it, as clipboard text.</summary>
    public string? CopySelection()
    {
        var clip = new Clip { ProjectID = Project.Id };
        if (Layer is { } layer) clip.Layers = [layer];
        else if (Canvas is { } canvas) clip.Canvases = [canvas, .. Descendants(canvas.Id)];
        else return null;
        return _lastClip = "dotsmedia:" + JsonSerializer.Serialize(clip, MediaStudioJson.Options);
    }

    public string? CutSelection()
    {
        var data = CopySelection();
        if (data is not null) DeleteSelection();
        return data;
    }

    /// <summary>Pastes what <see cref="CopySelection"/> made; null text falls back to the editor's own last copy.</summary>
    public bool Paste(string? text, BoardPoint? point = null)
    {
        text = text is not null && text.StartsWith("dotsmedia:", StringComparison.Ordinal) ? text : _lastClip;
        if (text is null) return false;
        Clip? clip;
        try { clip = JsonSerializer.Deserialize<Clip>(text["dotsmedia:".Length..], MediaStudioJson.Options); }
        catch (JsonException) { return false; }
        if (clip is null || (clip.Layers.Count == 0 && clip.Canvases.Count == 0)) return false;

        // A layer copied from another project brings its file along.
        MediaLayer Adopted(MediaLayer layer)
        {
            var copy = layer.Clone();
            copy.Id = Guid.NewGuid().ToString();
            if (clip.ProjectID != Project.Id && layer.AssetName is { } name)
            {
                try { copy.AssetName = Store.ImportAsset(Store.AssetPath(clip.ProjectID, name), Project.Id); }
                catch (IOException) { copy.AssetName = null; }
            }
            return copy;
        }

        if (clip.Canvases.Count > 0)
        {
            var ids = clip.Canvases.ToDictionary(c => c.Id, _ => Guid.NewGuid().ToString());
            var root = clip.Canvases[0];
            var dx = (point?.X ?? (Project.Canvases.Count == 0 ? -120 : Project.Canvases.Max(c => c.X + c.Width)) + 120) - root.X;
            var dy = (point?.Y ?? root.Y) - root.Y;
            Checkpoint();
            foreach (var canvas in clip.Canvases)
            {
                var copy = canvas.Clone();
                copy.Id = ids[canvas.Id];
                copy.ParentID = canvas.ParentID is { } parent && ids.TryGetValue(parent, out var mapped) ? mapped : null;
                copy.X += dx;
                copy.Y += dy;
                copy.Layers = canvas.Layers.Select(Adopted).ToList();
                Project.Canvases.Add(copy);
            }
            ReparentCanvas(ids[root.Id]);
            CanvasId = ids[root.Id];
            LayerId = null;
            Commit();
            return true;
        }
        var destination = (point is { } at ? Hit(at) : null) ?? Canvas;
        if (destination is null) return false;
        CanvasId = destination.Id;
        foreach (var layer in clip.Layers)
        {
            var copy = Adopted(layer);
            if (point is { } p)
            {
                copy.X = Math.Round(p.X - destination.X - copy.Width / 2);
                copy.Y = Math.Round(p.Y - destination.Y - copy.Height / 2);
            }
            else
            {
                copy.X += 24;
                copy.Y += 24;
            }
            AddLayer(copy);
        }
        return true;
    }

    private static readonly HashSet<string> VideoExtensions = new(StringComparer.OrdinalIgnoreCase) { ".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi" };

    /// <summary>Image and video files dropped or pasted at a board position.</summary>
    public void AddFiles(IEnumerable<string> paths, BoardPoint? point)
    {
        foreach (var path in paths)
        {
            var kind = MediaLibraryItem.KindOfFile(path);
            if (kind is "image" or "video") AddMedia(path, 0.5, center: point);
        }
    }

    public void DeleteSelection()
    {
        if (Layer is not null) DeleteSelectedLayer();
        else DeleteSelectedCanvas();
    }

    private static MediaLayer Scaled(MediaLayer start, double factor, bool movingOrigin)
    {
        var copy = start.Clone();
        copy.Width *= factor;
        copy.Height *= factor;
        copy.FontSize *= factor;
        copy.StrokeWidth *= factor;
        copy.CornerRadius *= factor;
        copy.Shadow *= factor;
        if (movingOrigin)
        {
            copy.X *= factor;
            copy.Y *= factor;
        }
        return copy;
    }

    /// <summary>Scale tool: <paramref name="start"/> is the layer as it was when the drag began.</summary>
    public void Scale(MediaLayer start, string canvasId, double factor)
    {
        if (FindCanvas(canvasId) is not { } canvas) return;
        var index = canvas.Layers.FindIndex(l => l.Id == start.Id);
        if (index >= 0) canvas.Layers[index] = Scaled(start, factor, false);
    }

    public void Scale(MediaCanvas start, double factor) => UpdateCanvas(start.Id, canvas =>
    {
        canvas.Width = Math.Round(start.Width * factor);
        canvas.Height = Math.Round(start.Height * factor);
        canvas.Layers = start.Layers.Select(l => Scaled(l, factor, true)).ToList();
    });

    /// <summary>
    /// Finishes a drag of a box-drawing tool. A plain click gives the tool's default size.
    /// Returns a region to export for the slice tool (canvas, rect in canvas coordinates).
    /// </summary>
    public (MediaCanvas Canvas, BoardRect Region)? Place(string tool, BoardPoint start, BoardPoint end)
    {
        var clicked = Math.Sqrt(Math.Pow(end.X - start.X, 2) + Math.Pow(end.Y - start.Y, 2)) * Zoom < 4;
        var rect = clicked
            ? new BoardRect(start.X, start.Y, 100, 100)
            : new BoardRect(Math.Min(start.X, end.X), Math.Min(start.Y, end.Y), Math.Abs(end.X - start.X), Math.Abs(end.Y - start.Y));
        Tool = "move";
        var title = MediaTools.Title(tool);
        switch (tool)
        {
            case "frame" or "section":
            {
                Checkpoint();
                var canvas = new MediaCanvas
                {
                    Name = $"{title} {Project.Canvases.Count + 1}",
                    X = Math.Round(rect.X), Y = Math.Round(rect.Y),
                    Width = Math.Max(1, Math.Round(rect.Width)), Height = Math.Max(1, Math.Round(rect.Height)),
                };
                if (tool == "section")
                {
                    canvas.Section = true;
                    canvas.BackgroundHex = "#E4E4E7";
                }
                Project.Canvases.Add(canvas);
                // Drawn inside a canvas it becomes that canvas's child; drawn around canvases it takes them in.
                var bounds = BoardRect.Of(canvas);
                foreach (var other in Project.Canvases.Where(o => o.Id != canvas.Id && o.ParentID is null && bounds.Contains(BoardRect.Of(o))))
                    other.ParentID = canvas.Id;
                ReparentCanvas(canvas.Id);
                CanvasId = canvas.Id;
                LayerId = null;
                Commit();
                return null;
            }
            case "line" or "arrow":
                AddPath([start, clicked ? new BoardPoint(start.X + 100, start.Y) : end], title, tool == "arrow");
                return null;
            case "slice":
            {
                // A slice is an export of one region of the canvas it was drawn on.
                if (clicked || Target(start) is not { } canvas) return null;
                var x = Math.Max(rect.X - canvas.X, 0);
                var y = Math.Max(rect.Y - canvas.Y, 0);
                var region = new BoardRect(x, y, Math.Min(rect.Right - canvas.X, canvas.Width) - x, Math.Min(rect.Bottom - canvas.Y, canvas.Height) - y);
                Notify();
                return region.Width >= 1 && region.Height >= 1 ? (canvas, region) : null;
            }
            case "comment":
            {
                if (Target(start) is not { } canvas) return null;
                CanvasId = canvas.Id;
                AddLayer(new MediaLayer
                {
                    Name = title, Kind = "icon", X = Math.Round(start.X - canvas.X), Y = Math.Round(start.Y - canvas.Y - 36),
                    Width = 36, Height = 36, ColorHex = "#0D99FF", Shadow = 4, Symbol = "bubble.left.fill", Comment = true,
                });
                return null;
            }
            case "rectangle" or "ellipse" or "polygon" or "star" or "text" or "textPath":
            {
                if (Target(start) is not { } canvas) return null;
                CanvasId = canvas.Id;
                var layer = new MediaLayer
                {
                    Name = title, Kind = "shape", X = Math.Round(rect.X - canvas.X), Y = Math.Round(rect.Y - canvas.Y),
                    Width = Math.Round(rect.Width), Height = Math.Round(rect.Height), ColorHex = "#D9D9D9",
                    Shape = tool is "ellipse" or "polygon" or "star" ? tool : "rectangle",
                };
                if (tool is "text" or "textPath")
                {
                    layer.Kind = "text";
                    layer.Arc = tool == "textPath" ? 120 : 0;
                    layer.Text = LocalizationService.Current.Get("studio.sample.text");
                    layer.ColorHex = "#111111";
                    layer.Alignment = "leading";
                    layer.FontSize = Math.Max(12, Math.Round(canvas.Height * 0.04));
                    if (clicked)
                    {
                        layer.Width = Math.Round(layer.FontSize * 8);
                        layer.Height = Math.Round(layer.FontSize * (tool == "textPath" ? 3 : 1.5));
                    }
                }
                AddLayer(layer);
                return null;
            }
            default:
                Notify();
                return null;
        }
    }

    /// <summary>Adds a stroked path through <paramref name="points"/>: a line, an arrow, or a pen or pencil stroke.</summary>
    public void AddPath(IReadOnlyList<BoardPoint> points, string name, bool arrow = false)
    {
        if (points.Count < 2 || Target(points[0]) is not { } canvas) return;
        CanvasId = canvas.Id;
        var minX = points.Min(p => p.X);
        var minY = points.Min(p => p.Y);
        var width = Math.Max(points.Max(p => p.X) - minX, 1);
        var height = Math.Max(points.Max(p => p.Y) - minY, 1);
        AddLayer(new MediaLayer
        {
            Name = name, Kind = "path", X = minX - canvas.X, Y = minY - canvas.Y, Width = width, Height = height,
            ColorHex = "#111111", StrokeWidth = 4, Arrow = arrow,
            Points = points.SelectMany(p => new[] { (p.X - minX) / width, (p.Y - minY) / height }).ToList(),
        });
    }

    public void AddIcon()
    {
        if (Canvas is not { } canvas) return;
        var side = Math.Round(Math.Min(canvas.Width, canvas.Height) * 0.15);
        AddLayer(new MediaLayer
        {
            Name = LocalizationService.Current.Get("studio.layer.icon"), Kind = "icon",
            X = Math.Round((canvas.Width - side) / 2), Y = Math.Round((canvas.Height - side) / 2), Width = side, Height = side,
            ColorHex = "#4F6BED",
        });
    }

    /// <summary>Copies the file into the project and places it centred, scaled to <paramref name="fill"/> of the canvas.</summary>
    public void AddMedia(string path, double fill, string? name = null, string? prompt = null, BoardPoint? center = null)
    {
        if (center is { } point && Hit(point) is { } under) CanvasId = under.Id;
        // Dropped on an empty board, the file gets a canvas to sit on.
        if (Canvas is null) AddCanvas(new MediaCanvas { Name = "Desktop", Width = 1440, Height = 1024 });
        if (Canvas is not { } canvas) return;
        string asset;
        try { asset = Store.ImportAsset(path, Project.Id); }
        catch (IOException) { return; }
        var isVideo = VideoExtensions.Contains(Path.GetExtension(path));
        var natural = NaturalSize?.Invoke(AssetPath(asset)) ?? (16, 9);
        var scale = Math.Min(canvas.Width * fill / Math.Max(natural.Width, 1), canvas.Height * fill / Math.Max(natural.Height, 1));
        var width = Math.Round(natural.Width * scale);
        var height = Math.Round(natural.Height * scale);
        AddLayer(new MediaLayer
        {
            Name = name ?? Path.GetFileNameWithoutExtension(path), Kind = isVideo ? "video" : "image",
            X = Math.Round((center is { } c ? c.X - canvas.X : canvas.Width / 2) - width / 2),
            Y = Math.Round((center is { } d ? d.Y - canvas.Y : canvas.Height / 2) - height / 2),
            Width = width, Height = height, AssetName = asset, Prompt = prompt,
        });
    }

    public void DeleteSelectedLayer()
    {
        if (CanvasId is not { } canvasId || LayerId is not { } layerId) return;
        Checkpoint();
        UpdateCanvas(canvasId, c => c.Layers.RemoveAll(l => l.Id == layerId));
        LayerId = null;
        Commit();
    }

    public void DuplicateSelectedLayer()
    {
        if (Layer?.Clone() is not { } copy) return;
        copy.Id = Guid.NewGuid().ToString();
        copy.X += 24;
        copy.Y += 24;
        AddLayer(copy);
    }

    /// <summary>Deletes the selected canvas and everything nested in it.</summary>
    public void DeleteSelectedCanvas()
    {
        if (CanvasId is not { } canvasId) return;
        var doomed = Descendants(canvasId).Select(c => c.Id).Append(canvasId).ToHashSet();
        Checkpoint();
        Project.Canvases.RemoveAll(c => doomed.Contains(c.Id));
        CanvasId = Project.Canvases.FirstOrDefault()?.Id;
        LayerId = null;
        Commit();
    }

    public void Nudge(double dx, double dy)
    {
        if (CanvasId is not { } canvasId || LayerId is not { } layerId) return;
        UpdateLayer(layerId, canvasId, l => { l.X += dx; l.Y += dy; });
        Commit();
    }

    public void UnlockAllLayers()
    {
        Checkpoint();
        foreach (var layer in Project.Canvases.SelectMany(c => c.Layers)) layer.Locked = false;
        Commit();
    }

    public void ToggleHidden(string id, string canvasId) { Checkpoint(); UpdateLayer(id, canvasId, l => l.Hidden = !l.Hidden); Commit(); }
    public void ToggleLocked(string id, string canvasId) { Checkpoint(); UpdateLayer(id, canvasId, l => l.Locked = !l.Locked); Commit(); }

    /// <summary>Moves the selected layer all the way to the front or the back of its canvas.</summary>
    public void ReorderSelectedLayer(bool toFront)
    {
        if (CanvasId is not { } canvasId || Layer is not { } layer) return;
        Checkpoint();
        UpdateCanvas(canvasId, c =>
        {
            c.Layers.Remove(layer);
            c.Layers.Insert(toFront ? c.Layers.Count : 0, layer);
        });
        Commit();
    }

    /// <summary>Lines the selected layer up with an edge or the middle of its canvas; null leaves that axis alone.</summary>
    public void AlignSelectedLayer(double? horizontal = null, double? vertical = null)
    {
        if (Canvas is not { } canvas || LayerId is not { } layerId) return;
        Checkpoint();
        UpdateLayer(layerId, canvas.Id, l =>
        {
            if (horizontal is { } h) l.X = Math.Round((canvas.Width - l.Width) * h);
            if (vertical is { } v) l.Y = Math.Round((canvas.Height - l.Height) * v);
        });
        Commit();
    }

    // Viewport

    /// <summary>Frames every canvas, leaving room below for the prompt bar.</summary>
    public void Fit()
    {
        if (ViewportWidth <= 0 || ViewportHeight <= 0 || Project.Canvases.Count == 0) return;
        var minX = Project.Canvases.Min(c => c.X);
        var minY = Project.Canvases.Min(c => c.Y);
        var maxX = Project.Canvases.Max(c => c.X + c.Width);
        var maxY = Project.Canvases.Max(c => c.Y + c.Height);
        var scale = Math.Min(Math.Min((ViewportWidth - 120) / (maxX - minX), (ViewportHeight - 260) / (maxY - minY)), 1);
        Zoom = Math.Clamp(scale, MinZoom, MaxZoom);
        PanX = -(minX + maxX) / 2 * Zoom;
        PanY = -(minY + maxY) / 2 * Zoom - 50;
        Notify();
    }

    /// <summary>Zooms keeping a viewport point still; the centre when null.</summary>
    public void ZoomBy(double factor, double? screenX = null, double? screenY = null)
    {
        var target = Math.Clamp(Zoom * factor, MinZoom, MaxZoom);
        if (target == Zoom) return;
        var anchorX = (screenX ?? ViewportWidth / 2) - ViewportWidth / 2;
        var anchorY = (screenY ?? ViewportHeight / 2) - ViewportHeight / 2;
        var ratio = target / Zoom;
        PanX = anchorX - (anchorX - PanX) * ratio;
        PanY = anchorY - (anchorY - PanY) * ratio;
        Zoom = target;
        Notify();
    }

    // AI

    public static readonly string[] AiKinds = ["design", "next", "image", "video"];

    public void RunAI(string prompt, string kind, RouterController router, SupportPaths paths, IProviderSecretStore secrets)
    {
        prompt = prompt.Trim();
        // "Next screen" can run on its own: the previous screen is the brief.
        if (AiBusy || (prompt.Length == 0 && kind != "next")) return;
        // On an empty board the request gets a desktop-sized canvas to land on.
        if (Canvas is null) AddCanvas(new MediaCanvas { Name = "Desktop", Width = 1440, Height = 1024 });
        if (Canvas is not { } target) return;
        // There is nothing to follow on from an empty canvas, so it is designed in place.
        if (kind == "next" && target.Layers.Count == 0) kind = "design";
        if (prompt.Length == 0 && kind != "next") return;
        Start(ct => PerformAsync(prompt, kind, target, router, paths, secrets, ct));
    }

    /// <summary>Fills, or refills, one image layer from the description stored on it.</summary>
    public void GenerateImage(MediaLayer layer, string canvasId, RouterController router, SupportPaths paths, IProviderSecretStore secrets)
    {
        if (AiBusy || string.IsNullOrWhiteSpace(layer.Prompt)) return;
        Start(async ct =>
        {
            AiStatus = LocalizationService.Current.Get("studio.ai.drawing");
            Notify();
            var media = await MediaStudioAI.GenerateAsync(NativeMediaKind.Image, layer.Prompt!, router, Store.Settings, paths, secrets, ct: ct);
            ct.ThrowIfCancellationRequested();
            var asset = Store.ImportAsset(media.FilePath, Project.Id);
            Checkpoint();
            UpdateLayer(layer.Id, canvasId, l => l.AssetName = asset);
        });
    }

    private async void Start(Func<CancellationToken, Task> work)
    {
        AiBusy = true;
        AiError = null;
        AiNote = null;
        _ai = new CancellationTokenSource();
        Notify();
        try { await work(_ai.Token); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (!_ai.IsCancellationRequested) AiError = ex.Message; }
        AiBusy = false;
        AiStatus = "";
        Commit();
    }

    public void StopAI() => _ai?.Cancel();

    private async Task PerformAsync(string prompt, string kind, MediaCanvas target, RouterController router, SupportPaths paths,
        IProviderSecretStore secrets, CancellationToken ct)
    {
        var copy = LocalizationService.Current;
        var settings = Store.Settings;
        if (kind is "image" or "video")
        {
            AiStatus = copy.Get(kind == "video" ? "studio.ai.renderingVideo" : "studio.ai.drawing");
            Notify();
            var media = await MediaStudioAI.GenerateAsync(kind == "video" ? NativeMediaKind.Video : NativeMediaKind.Image, prompt,
                router, settings, paths, secrets, ct: ct);
            ct.ThrowIfCancellationRequested();
            CanvasId = target.Id;
            AddMedia(media.FilePath, 1, prompt.Length > 40 ? prompt[..40] : prompt, kind == "image" ? prompt : null);
            return;
        }
        AiStatus = copy.Get("studio.ai.planning");
        Notify();
        var imagesAvailable = MediaStudioAI.CanGenerateImages(router, settings);
        // A next screen is planned against an empty canvas the size of the one it follows.
        MediaCanvas? reference = null;
        if (kind == "next")
        {
            reference = target;
            target = new MediaCanvas
            {
                Name = copy.Get("studio.screenNumber", Project.Canvases.Count + 1),
                Width = target.Width, Height = target.Height, BackgroundHex = target.BackgroundHex,
            };
        }
        var plan = await MediaStudioAI.PlanAsync(prompt.Length == 0 ? MediaStudioAI.NextScreenRequest : prompt, target, LayerId,
            reference, imagesAvailable, router, settings, ct);
        ct.ThrowIfCancellationRequested();
        if (kind == "next")
        {
            if (plan.Name is { } name) target.Name = name;
            AddCanvas(target);
        }
        else Checkpoint();
        UpdateCanvas(target.Id, canvas =>
        {
            if (plan.BackgroundHex is { } background) canvas.BackgroundHex = background;
            canvas.Layers.RemoveAll(l => plan.Removals.Contains(l.Id));
            foreach (var update in plan.Updates)
            {
                var index = canvas.Layers.FindIndex(l => l.Id == update.Id);
                if (index >= 0) canvas.Layers[index] = update;
            }
        });
        if (Layer is null) LayerId = null;
        // One layer at a time, so the build-up is visible and can be stopped midway.
        for (var index = 0; index < plan.Steps.Count; index++)
        {
            ct.ThrowIfCancellationRequested();
            var step = plan.Steps[index];
            AiStatus = copy.Get("studio.ai.layerProgress", index + 1, plan.Steps.Count, step.Layer.Name);
            UpdateCanvas(target.Id, c => c.Layers.Add(step.Layer));
            CanvasId = target.Id;
            LayerId = step.Layer.Id;
            Notify();
            if (step.ImagePrompt is not { } imagePrompt || !imagesAvailable)
            {
                if (step.ImagePrompt is not null) AiNote = copy.Get("studio.ai.noImages");
                await Task.Delay(120, ct);
                continue;
            }
            try
            {
                var media = await MediaStudioAI.GenerateAsync(NativeMediaKind.Image, imagePrompt, router, settings, paths, secrets, ct: ct);
                var asset = Store.ImportAsset(media.FilePath, Project.Id);
                UpdateLayer(step.Layer.Id, target.Id, l => l.AssetName = asset);
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                // The design carries on without pictures; the layer keeps its tint and description.
                imagesAvailable = false;
                AiError = ex.Message;
                AiNote = copy.Get("studio.ai.noImages");
            }
        }
        if (plan.Steps.Count > 0) { CanvasId = target.Id; LayerId = null; }
    }
}
