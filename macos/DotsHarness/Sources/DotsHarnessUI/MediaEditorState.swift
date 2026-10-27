// Copyright (c) 2026 DOTS
// Editing state for one media project: selection, viewport, history and AI runs.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore

/// What a press on the board does. Each case is one entry in the dock's tool menus.
enum MediaTool: String {
    case move, hand, scale, frame, section, slice
    case rectangle, line, arrow, ellipse, polygon, star
    case pen, pencil, marker, text, textPath, comment

    var systemImage: String {
        switch self {
        case .move: return "cursorarrow"
        case .hand: return "hand.raised"
        case .scale: return "arrow.up.left.and.arrow.down.right"
        case .frame: return "number"
        case .section: return "rectangle.dashed"
        case .slice: return "scissors"
        case .rectangle: return "square"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .ellipse: return "circle"
        case .polygon: return "triangle"
        case .star: return "star"
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .textPath: return "textformat.abc.dottedunderline"
        case .comment: return "bubble.left"
        }
    }

    var title: String {
        switch self {
        case .frame: return AppCopy.text("studio.addCanvas")
        case .text: return AppCopy.text("studio.layer.text")
        case .rectangle, .ellipse, .polygon, .star, .line, .arrow: return AppCopy.text("studio.shape.\(rawValue)")
        default: return AppCopy.text("studio.tool.\(rawValue)")
        }
    }

    /// The key that picks the tool while the board has focus; uppercase means with Shift.
    var key: Character? {
        switch self {
        case .move: return "v"
        case .hand: return "h"
        case .scale: return "k"
        case .frame: return "f"
        case .section: return "S"
        case .slice: return "s"
        case .rectangle: return "r"
        case .line: return "l"
        case .arrow: return "L"
        case .ellipse: return "o"
        case .pen: return "p"
        case .pencil: return "P"
        case .marker: return nil
        case .text: return "t"
        case .comment: return "c"
        case .polygon, .star, .textPath: return nil
        }
    }

    var keyLabel: String {
        guard let key else { return "" }
        return key.isUppercase ? "⇧\(key)" : String(key).uppercased()
    }

    static let all: [MediaTool] = [
        .move, .hand, .scale, .frame, .section, .slice, .rectangle, .line, .arrow, .ellipse, .polygon, .star,
        .pen, .pencil, .marker, .text, .textPath, .comment,
    ]
}

private extension MediaLayer {
    /// The layer resized as a whole: type, strokes, corners and shadow keep their proportions.
    func scaled(by factor: Double, movingOrigin: Bool) -> MediaLayer {
        var copy = self
        copy.width *= factor
        copy.height *= factor
        copy.fontSize *= factor
        copy.strokeWidth *= factor
        copy.cornerRadius *= factor
        copy.shadow *= factor
        if movingOrigin {
            copy.x *= factor
            copy.y *= factor
        }
        return copy
    }
}

@MainActor
final class MediaEditorState: ObservableObject {
    enum AIKind: String, CaseIterable, Identifiable {
        case design, next, image, video

        var id: String { rawValue }
        var title: String { AppCopy.text("studio.ai.kind.\(rawValue)") }
        var systemImage: String {
            switch self {
            case .design: return "square.3.layers.3d"
            case .next: return "rectangle.stack.badge.plus"
            case .image: return "photo"
            case .video: return "film"
            }
        }
    }

    @Published var project: MediaProject
    @Published var canvasID: String?
    @Published var layerID: String?
    @Published var tool: MediaTool = .move
    @Published var zoom: CGFloat = 0.5
    /// Screen position of the board's origin, relative to the viewport centre.
    @Published var pan: CGSize = .zero
    @Published var aiBusy = false
    @Published var aiStatus = ""
    @Published var aiError: String?
    /// Something worth knowing that did not stop the run, such as images left as placeholders.
    @Published var aiNote: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Read by the scroll monitor; not published so moving the pointer redraws nothing.
    var viewport: CGSize = .zero
    var hover: CGPoint?

    let store: MediaStudioStore
    private var undoStack: [[MediaCanvas]] = []
    private var redoStack: [[MediaCanvas]] = []
    private var monitor: Any?
    private var aiTask: Task<Void, Never>?
    private var hasFitted = false

    static let zoomRange: ClosedRange<CGFloat> = 0.05...8
    static let historyLimit = 25

    init(project: MediaProject, store: MediaStudioStore) {
        self.project = project
        self.store = store
        self.canvasID = project.canvases.first?.id
        // An empty board opens on the canvas tool, with the ready-made sizes beside it.
        if project.canvases.isEmpty { tool = .frame }
    }

    var canvas: MediaCanvas? { project.canvases.first { $0.id == canvasID } }
    var layer: MediaLayer? { canvas?.layers.first { $0.id == layerID } }

    func assetURL(_ name: String) -> URL {
        store.assetURL(projectID: project.id, name: name)
    }

    // MARK: History

    /// Call before a change the user should be able to undo.
    func checkpoint() {
        undoStack.append(project.canvases)
        // Snapshots share storage with the live project until something changes, so a step costs
        // only the canvas that was edited; the cap keeps a long session from growing without end.
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshHistoryFlags()
    }

    func commit() {
        store.save(project)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project.canvases)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project.canvases)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        restore(next)
    }

    private func restore(_ canvases: [MediaCanvas]) {
        project.canvases = canvases
        if canvas == nil { canvasID = canvases.first?.id }
        if layer == nil { layerID = nil }
        refreshHistoryFlags()
        commit()
    }

    private func refreshHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Edits

    func updateCanvas(_ id: String, _ change: (inout MediaCanvas) -> Void) {
        guard let index = project.canvases.firstIndex(where: { $0.id == id }) else { return }
        change(&project.canvases[index])
        // A typed-in zero would divide by zero wherever the canvas is scaled to fit.
        project.canvases[index].width = max(1, project.canvases[index].width)
        project.canvases[index].height = max(1, project.canvases[index].height)
    }

    func updateLayer(_ id: String, in canvasID: String, _ change: (inout MediaLayer) -> Void) {
        updateCanvas(canvasID) { canvas in
            guard let index = canvas.layers.firstIndex(where: { $0.id == id }) else { return }
            change(&canvas.layers[index])
            canvas.layers[index].width = max(1, canvas.layers[index].width)
            canvas.layers[index].height = max(1, canvas.layers[index].height)
        }
    }

    func select(canvas id: String, layer: String? = nil) {
        canvasID = id
        layerID = layer
    }

    /// Selects by either kind of id, as the layers panel reports them.
    func select(id: String?) {
        guard let id else { return }
        if project.canvases.contains(where: { $0.id == id }) {
            select(canvas: id)
        } else if let owner = project.canvases.first(where: { $0.layers.contains { $0.id == id } }) {
            select(canvas: owner.id, layer: id)
        }
    }

    /// New canvases line up to the right of the existing ones.
    func addCanvas(_ canvas: MediaCanvas) {
        checkpoint()
        var canvas = canvas
        canvas.x = (project.canvases.map { $0.x + $0.width }.max() ?? -120) + 120
        canvas.y = project.canvases.first?.y ?? 0
        project.canvases.append(canvas)
        select(canvas: canvas.id)
        commit()
        fit()
    }

    func duplicateSelectedCanvas() {
        guard var copy = canvas else { return }
        copy.id = UUID().uuidString
        copy.parentID = nil
        copy.name = AppCopy.format("studio.copyOf", copy.name)
        copy.layers = copy.layers.map { layer in
            var layer = layer
            layer.id = UUID().uuidString
            return layer
        }
        addCanvas(copy)
    }

    func addLayer(_ layer: MediaLayer) {
        guard let id = canvasID ?? project.canvases.first?.id else { return }
        checkpoint()
        updateCanvas(id) { $0.layers.append(layer) }
        select(canvas: id, layer: layer.id)
        commit()
    }

    /// Board coordinates of a point in the viewport, and back.
    func boardPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - viewport.width / 2 - pan.width) / zoom,
            y: (point.y - viewport.height / 2 - pan.height) / zoom
        )
    }

    func screenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: viewport.width / 2 + pan.width + point.x * zoom,
            y: viewport.height / 2 + pan.height + point.y * zoom
        )
    }

    /// The canvas a new layer drawn at `point` belongs to: the front one under it, else the selected one.
    private func target(at point: CGPoint) -> MediaCanvas? {
        hit(at: point) ?? canvas
    }

    /// The innermost canvas under a board point; a canvas wins over the section it sits in.
    func hit(at point: CGPoint) -> MediaCanvas? {
        let under = orderedCanvases.filter { Self.rect(of: $0).contains(point) }
        return under.last { $0.section != true } ?? under.last
    }

    // MARK: Nesting

    static func rect(of canvas: MediaCanvas) -> CGRect {
        CGRect(x: canvas.x, y: canvas.y, width: canvas.width, height: canvas.height)
    }

    /// Every canvas inside `id`, parents before their children.
    func descendants(of id: String) -> [MediaCanvas] {
        project.canvases.filter { $0.parentID == id }.flatMap { [$0] + descendants(of: $0.id) }
    }

    /// Drawing order for the board: each canvas after the one that holds it, sections under their neighbours.
    var orderedCanvases: [MediaCanvas] {
        let roots = project.canvases.filter { $0.parentID == nil }
        return (roots.filter { $0.section == true } + roots.filter { $0.section != true })
            .flatMap { [$0] + descendants(of: $0.id) }
    }

    /// After a canvas is moved or drawn: it belongs to the smallest canvas that wholly contains it, if any.
    func reparentCanvas(_ id: String) {
        guard let moved = project.canvases.first(where: { $0.id == id }) else { return }
        let inside = Set(descendants(of: id).map(\.id))
        let holder = project.canvases
            .filter { $0.id != id && !inside.contains($0.id) && Self.rect(of: $0).contains(Self.rect(of: moved)) }
            .min { $0.width * $0.height < $1.width * $1.height }
        updateCanvas(id) { $0.parentID = holder?.id }
    }

    /// After a layer is dragged: if its centre now lies over another canvas, it moves into that canvas.
    func rehomeLayer(_ id: String, from canvasID: String) {
        guard let source = project.canvases.first(where: { $0.id == canvasID }),
              let layer = source.layers.first(where: { $0.id == id }),
              let destination = hit(at: CGPoint(
                  x: source.x + layer.x + layer.width / 2, y: source.y + layer.y + layer.height / 2
              )), destination.id != source.id else { return }
        var moved = layer
        moved.x += source.x - destination.x
        moved.y += source.y - destination.y
        updateCanvas(source.id) { $0.layers.removeAll { $0.id == id } }
        updateCanvas(destination.id) { $0.layers.append(moved) }
        select(canvas: destination.id, layer: id)
    }

    // MARK: Clipboard

    private struct Clip: Codable {
        var projectID: String
        var layers: [MediaLayer] = []
        var canvases: [MediaCanvas] = []
    }

    static let clipType = NSPasteboard.PasteboardType("public.json")
    /// Kept beside the system pasteboard so a copy survives anything that fails to carry the data across.
    private static var lastClip: Data?

    /// The selected layer, or the selected canvas with everything nested in it, as pasteboard data.
    @discardableResult
    func copySelection() -> Data? {
        var clip = Clip(projectID: project.id)
        if let layer {
            clip.layers = [layer]
        } else if let canvas {
            clip.canvases = [canvas] + descendants(of: canvas.id)
        } else {
            return nil
        }
        guard let data = try? JSONEncoder().encode(clip) else { return nil }
        Self.lastClip = data
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: Self.clipType)
        return data
    }

    func cutSelection() {
        guard copySelection() != nil else { return }
        deleteSelection()
    }

    /// Pastes layers or canvases copied here, else images and files from the system pasteboard.
    /// `point` is a board position to paste at; nil pastes just off the original.
    func paste(at point: CGPoint? = nil) {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: Self.clipType), paste(clip: data, at: point) { return }
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            addFiles(files, at: point)
        } else if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            addImageData(png, at: point)
        } else if let data = Self.lastClip {
            _ = paste(clip: data, at: point)
        }
    }

    private func paste(clip data: Data, at point: CGPoint?) -> Bool {
        guard let clip = try? JSONDecoder().decode(Clip.self, from: data),
              !clip.layers.isEmpty || !clip.canvases.isEmpty else { return false }
        /// A layer copied from another project brings its file along.
        func adopted(_ layer: MediaLayer) -> MediaLayer {
            var copy = layer
            copy.id = UUID().uuidString
            if clip.projectID != project.id, let name = layer.assetName {
                copy.assetName = try? store.importAsset(
                    from: store.assetURL(projectID: clip.projectID, name: name), into: project.id
                )
            }
            return copy
        }

        if !clip.canvases.isEmpty {
            let ids = Dictionary(uniqueKeysWithValues: clip.canvases.map { ($0.id, UUID().uuidString) })
            let root = clip.canvases[0]
            let dx = (point.map { Double($0.x) } ?? (project.canvases.map { $0.x + $0.width }.max() ?? -120) + 120) - root.x
            let dy = (point.map { Double($0.y) } ?? root.y) - root.y
            checkpoint()
            for canvas in clip.canvases {
                var copy = canvas
                copy.id = ids[canvas.id] ?? UUID().uuidString
                copy.parentID = canvas.parentID.flatMap { ids[$0] }
                copy.x += dx
                copy.y += dy
                copy.layers = canvas.layers.map(adopted)
                project.canvases.append(copy)
            }
            if let rootID = ids[root.id] {
                reparentCanvas(rootID)
                select(canvas: rootID)
            }
            commit()
            return true
        }

        guard let destination = point.flatMap(hit(at:)) ?? canvas else { return false }
        canvasID = destination.id
        for layer in clip.layers {
            var copy = adopted(layer)
            if let point {
                copy.x = (point.x - destination.x - copy.width / 2).rounded()
                copy.y = (point.y - destination.y - copy.height / 2).rounded()
            } else {
                copy.x += 24
                copy.y += 24
            }
            addLayer(copy)
        }
        return true
    }

    /// Image and video files dropped or pasted at a board position.
    func addFiles(_ urls: [URL], at point: CGPoint?) {
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true else { continue }
            addMedia(at: url, fill: 0.5, center: point)
        }
    }

    /// Picture data with no file behind it, such as an image dragged out of a browser.
    func addImageData(_ data: Data, at point: CGPoint?) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil else { return }
        addMedia(at: url, fill: 0.5, name: AppCopy.text("studio.ai.kind.image"), center: point)
        try? FileManager.default.removeItem(at: url)
    }

    func deleteSelection() {
        if layer != nil { deleteSelectedLayer() } else { deleteSelectedCanvas() }
    }

    /// Scale tool: `start` is the layer or canvas as it was when the drag began.
    func scale(_ start: MediaLayer, in canvasID: String, by factor: Double) {
        updateLayer(start.id, in: canvasID) { $0 = start.scaled(by: factor, movingOrigin: false) }
    }

    func scale(_ start: MediaCanvas, by factor: Double) {
        updateCanvas(start.id) {
            $0.width = (start.width * factor).rounded()
            $0.height = (start.height * factor).rounded()
            $0.layers = start.layers.map { $0.scaled(by: factor, movingOrigin: true) }
        }
    }

    /// Finishes a drag of a box-drawing tool. Both points are in board coordinates;
    /// a plain click gives the tool's default size.
    func place(_ tool: MediaTool, from start: CGPoint, to end: CGPoint) {
        let clicked = hypot(end.x - start.x, end.y - start.y) * zoom < 4
        var rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        if clicked { rect = CGRect(x: start.x, y: start.y, width: 100, height: 100) }
        defer { self.tool = .move }

        switch tool {
        case .frame, .section:
            checkpoint()
            var canvas = MediaCanvas(
                name: "\(tool.title) \(project.canvases.count + 1)",
                x: rect.minX.rounded(), y: rect.minY.rounded(),
                width: max(1, rect.width.rounded()), height: max(1, rect.height.rounded())
            )
            if tool == .section {
                canvas.section = true
                canvas.backgroundHex = "#E4E4E7"
            }
            project.canvases.append(canvas)
            // Drawn inside a canvas it becomes that canvas's child; drawn around canvases it takes them in.
            let bounds = Self.rect(of: canvas)
            for other in project.canvases
            where other.id != canvas.id && other.parentID == nil && bounds.contains(Self.rect(of: other)) {
                updateCanvas(other.id) { $0.parentID = canvas.id }
            }
            reparentCanvas(canvas.id)
            select(canvas: canvas.id)
            commit()
        case .line, .arrow:
            addPath([start, clicked ? CGPoint(x: start.x + 100, y: start.y) : end], name: tool.title, arrow: tool == .arrow)
        case .slice:
            // A slice is an export of one region of the canvas it was drawn on.
            guard !clicked, let canvas = target(at: start) else { return }
            let region = rect.offsetBy(dx: -canvas.x, dy: -canvas.y)
                .intersection(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            guard region.width >= 1, region.height >= 1 else { return }
            MediaExport.save(
                MediaExport.data(of: canvas, region: region, format: .png, scale: 1, assetURL: assetURL),
                name: "\(canvas.name) \(tool.title)", format: .png
            )
        case .comment:
            guard let canvas = target(at: start) else { return }
            canvasID = canvas.id
            addLayer(MediaLayer(
                name: tool.title, kind: .icon,
                x: (start.x - canvas.x).rounded(), y: (start.y - canvas.y - 36).rounded(), width: 36, height: 36,
                colorHex: "#0D99FF", shadow: 4, symbol: "bubble.left.fill", comment: true
            ))
        case .rectangle, .ellipse, .polygon, .star, .text, .textPath:
            guard let canvas = target(at: start) else { return }
            canvasID = canvas.id
            var layer = MediaLayer(
                name: tool.title,
                kind: .shape,
                x: (rect.minX - canvas.x).rounded(),
                y: (rect.minY - canvas.y).rounded(),
                width: rect.width.rounded(),
                height: rect.height.rounded(),
                colorHex: "#D9D9D9",
                shape: MediaLayer.Shape(rawValue: tool.rawValue) ?? .rectangle
            )
            if tool == .text || tool == .textPath {
                layer.kind = .text
                layer.arc = tool == .textPath ? 120 : 0
                layer.text = AppCopy.text("studio.sample.text")
                layer.colorHex = "#111111"
                layer.alignment = .leading
                layer.fontSize = max(12, (canvas.height * 0.04).rounded())
                if clicked {
                    layer.width = (layer.fontSize * 8).rounded()
                    layer.height = (layer.fontSize * (tool == .textPath ? 3 : 1.5)).rounded()
                }
            }
            addLayer(layer)
        case .move, .hand, .scale, .pen, .pencil, .marker:
            break
        }
    }

    /// Adds a stroked path through `points` (board coordinates): a line, an arrow, or a pen or pencil stroke.
    func addPath(_ points: [CGPoint], name: String, arrow: Bool = false, colorHex: String = "#111111", strokeWidth: Double = 4, opacity: Double = 1) {
        guard points.count >= 2, let canvas = target(at: points[0]) else { return }
        canvasID = canvas.id
        let minX = points.map(\.x).min() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let width = max((points.map(\.x).max() ?? 0) - minX, 1)
        let height = max((points.map(\.y).max() ?? 0) - minY, 1)
        let normalized: [Double] = points.flatMap { point -> [Double] in
            [Double((point.x - minX) / width), Double((point.y - minY) / height)]
        }
        let x = Double(minX - canvas.x)
        let y = Double(minY - canvas.y)
        addLayer(MediaLayer(
            name: name,
            kind: .path,
            x: x,
            y: y,
            width: Double(width),
            height: Double(height),
            opacity: opacity,
            colorHex: colorHex,
            strokeWidth: strokeWidth,
            points: normalized,
            arrow: arrow
        ))
    }

    func addIcon() {
        guard let canvas else { return }
        let side = (min(canvas.width, canvas.height) * 0.15).rounded()
        addLayer(MediaLayer(
            name: AppCopy.text("studio.layer.icon"),
            kind: .icon,
            x: ((canvas.width - side) / 2).rounded(),
            y: ((canvas.height - side) / 2).rounded(),
            width: side,
            height: side,
            colorHex: "#4F6BED"
        ))
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls { self?.addMedia(at: url, fill: 0.8) }
            }
        }
    }

    /// Copies `url` into the project and places it centred, scaled to `fill` of the canvas.
    /// `center` is a board position; the canvas under it takes the layer.
    func addMedia(at url: URL, fill: Double, name: String? = nil, prompt: String? = nil, center: CGPoint? = nil) {
        if let center, let under = hit(at: center) { canvasID = under.id }
        // Dropped on an empty board, the file gets a canvas to sit on.
        if canvas == nil { addCanvas(MediaCanvas(name: "Desktop", width: 1440, height: 1024)) }
        guard let canvas, let asset = try? store.importAsset(from: url, into: project.id) else { return }
        let isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
        let stored = assetURL(asset)
        let natural = (isVideo ? VideoPosterCache.poster(for: stored) : NSImage(contentsOf: stored))?.size
            ?? NSSize(width: 16, height: 9)
        let scale = min(canvas.width * fill / max(natural.width, 1), canvas.height * fill / max(natural.height, 1))
        let width = (natural.width * scale).rounded()
        let height = (natural.height * scale).rounded()
        addLayer(MediaLayer(
            name: name ?? url.deletingPathExtension().lastPathComponent,
            kind: isVideo ? .video : .image,
            x: ((center.map { $0.x - canvas.x } ?? canvas.width / 2) - width / 2).rounded(),
            y: ((center.map { $0.y - canvas.y } ?? canvas.height / 2) - height / 2).rounded(),
            width: width,
            height: height,
            assetName: asset,
            prompt: prompt
        ))
    }

    func deleteSelectedLayer() {
        guard let canvasID, let layerID else { return }
        checkpoint()
        updateCanvas(canvasID) { $0.layers.removeAll { $0.id == layerID } }
        self.layerID = nil
        commit()
    }

    func duplicateSelectedLayer() {
        guard var copy = layer else { return }
        copy.id = UUID().uuidString
        copy.x += 24
        copy.y += 24
        addLayer(copy)
    }

    /// Deletes the selected canvas and everything nested in it.
    func deleteSelectedCanvas() {
        guard let canvasID else { return }
        let doomed = Set([canvasID] + descendants(of: canvasID).map(\.id))
        checkpoint()
        project.canvases.removeAll { doomed.contains($0.id) }
        self.canvasID = project.canvases.first?.id
        layerID = nil
        commit()
    }

    func nudge(dx: Double, dy: Double) {
        guard let canvasID, let layerID else { return }
        updateLayer(layerID, in: canvasID) {
            $0.x += dx
            $0.y += dy
        }
        commit()
    }

    func unlockAllLayers() {
        checkpoint()
        for index in project.canvases.indices {
            for layer in project.canvases[index].layers.indices { project.canvases[index].layers[layer].locked = false }
        }
        commit()
    }

    func toggle(_ keyPath: WritableKeyPath<MediaLayer, Bool>, layer id: String, in canvasID: String) {
        checkpoint()
        updateLayer(id, in: canvasID) { $0[keyPath: keyPath].toggle() }
        commit()
    }

    /// Moves the selected layer all the way to the front or the back of its canvas.
    func reorderSelectedLayer(toFront: Bool) {
        guard let canvasID, let layer else { return }
        checkpoint()
        updateCanvas(canvasID) { canvas in
            canvas.layers.removeAll { $0.id == layer.id }
            canvas.layers.insert(layer, at: toFront ? canvas.layers.count : 0)
        }
        commit()
    }

    /// Lines the selected layer up with an edge or the middle of its canvas; `nil` leaves that axis alone.
    func alignSelectedLayer(horizontal: Double? = nil, vertical: Double? = nil) {
        guard let canvas, let layerID else { return }
        checkpoint()
        updateLayer(layerID, in: canvas.id) {
            if let horizontal { $0.x = ((canvas.width - $0.width) * horizontal).rounded() }
            if let vertical { $0.y = ((canvas.height - $0.height) * vertical).rounded() }
        }
        commit()
    }

    /// `offsets` index the layer list as shown: front layer first.
    func moveLayers(in canvasID: String, from offsets: IndexSet, to destination: Int) {
        checkpoint()
        updateCanvas(canvasID) { canvas in
            var shown = Array(canvas.layers.reversed())
            shown.move(fromOffsets: offsets, toOffset: destination)
            canvas.layers = shown.reversed()
        }
        commit()
    }

    // MARK: Viewport

    func screenOrigin(of canvas: MediaCanvas) -> CGPoint {
        CGPoint(
            x: viewport.width / 2 + pan.width + canvas.x * zoom,
            y: viewport.height / 2 + pan.height + canvas.y * zoom
        )
    }

    /// Frames every canvas, leaving room below for the prompt bar.
    func fit() {
        guard viewport.width > 0, viewport.height > 0, let first = project.canvases.first else { return }
        var bounds = CGRect(x: first.x, y: first.y, width: first.width, height: first.height)
        for canvas in project.canvases.dropFirst() {
            bounds = bounds.union(CGRect(x: canvas.x, y: canvas.y, width: canvas.width, height: canvas.height))
        }
        let scale = min((viewport.width - 120) / bounds.width, (viewport.height - 260) / bounds.height, 1)
        zoom = min(max(scale, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        pan = CGSize(width: -bounds.midX * zoom, height: -bounds.midY * zoom - 50)
    }

    func fitOnce() {
        guard !hasFitted, viewport.width > 0 else { return }
        hasFitted = true
        fit()
    }

    /// Zooms keeping `point` (viewport coordinates) still; the viewport centre when nil.
    func zoom(by factor: CGFloat, around point: CGPoint? = nil) {
        let target = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard target != zoom else { return }
        let anchor = CGSize(
            width: (point?.x ?? viewport.width / 2) - viewport.width / 2,
            height: (point?.y ?? viewport.height / 2) - viewport.height / 2
        )
        let ratio = target / zoom
        pan = CGSize(
            width: anchor.width - (anchor.width - pan.width) * ratio,
            height: anchor.height - (anchor.height - pan.height) * ratio
        )
        zoom = target
    }

    /// Two-finger scroll pans, pinch or Command-scroll zooms, like other canvas editors.
    func startScrollMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, let hover = self.hover else { return event }
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            if event.type == .magnify {
                self.zoom(by: 1 + event.magnification, around: hover)
            } else if event.modifierFlags.contains(.command) {
                self.zoom(by: exp(event.scrollingDeltaY * step * 0.01), around: hover)
            } else {
                self.pan.width += event.scrollingDeltaX * step
                self.pan.height += event.scrollingDeltaY * step
            }
            return nil
        }
    }

    func stopScrollMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hover = nil
    }

    // MARK: AI

    func runAI(prompt: String, kind: AIKind, model: AppModel) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Next screen" can run on its own: the previous screen is the brief.
        guard !aiBusy, !prompt.isEmpty || kind == .next else { return }
        // On an empty board the request gets a desktop-sized canvas to land on.
        if canvas == nil { addCanvas(MediaCanvas(name: "Desktop", width: 1440, height: 1024)) }
        guard let target = canvas else { return }
        // There is nothing to follow on from an empty canvas, so it is designed in place.
        let kind: AIKind = kind == .next && target.layers.isEmpty ? .design : kind
        guard !prompt.isEmpty || kind == .next else { return }
        startAI { try await $0.performAI(prompt: prompt, kind: kind, target: target, model: model) }
    }

    /// Fills, or refills, one image layer from the description stored on it.
    func generateImage(for layer: MediaLayer, in canvasID: String, model: AppModel) {
        guard !aiBusy, let prompt = layer.prompt, !prompt.isEmpty else { return }
        startAI { state in
            state.aiStatus = AppCopy.text("studio.ai.drawing")
            let media = try await MediaStudioAI.generate(
                kind: .image, prompt: prompt, router: model.router, settings: state.store.settings, paths: model.paths
            )
            try Task.checkCancellation()
            let asset = try state.store.importAsset(from: media.url, into: state.project.id)
            state.checkpoint()
            state.updateLayer(layer.id, in: canvasID) { $0.assetName = asset }
        }
    }

    private func startAI(_ work: @escaping @MainActor (MediaEditorState) async throws -> Void) {
        aiBusy = true
        aiError = nil
        aiNote = nil
        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch {
                if !Task.isCancelled { self.aiError = Self.message(for: error) }
            }
            self.aiBusy = false
            self.aiStatus = ""
            self.commit()
        }
    }

    func stopAI() {
        aiTask?.cancel()
    }

    private func performAI(prompt: String, kind: AIKind, target: MediaCanvas, model: AppModel) async throws {
        let settings = store.settings
        switch kind {
        case .design, .next:
            aiStatus = AppCopy.text("studio.ai.planning")
            var imagesAvailable = await MediaStudioAI.canGenerateImages(router: model.router, settings: settings)
            // A next screen is planned against an empty canvas the size of the one it follows,
            // and only joins the board once the model has answered.
            var target = target
            var reference: MediaCanvas?
            if kind == .next {
                reference = target
                target = MediaCanvas(
                    name: AppCopy.format("studio.screenNumber", project.canvases.count + 1),
                    width: target.width, height: target.height, backgroundHex: target.backgroundHex
                )
            }
            let plan = try await MediaStudioAI.plan(
                prompt: prompt.isEmpty ? MediaStudioAI.nextScreenRequest : prompt,
                canvas: target,
                selectedLayerID: layerID,
                reference: reference,
                imagesAvailable: imagesAvailable,
                router: model.router,
                settings: settings
            )
            try Task.checkCancellation()
            if kind == .next {
                if let name = plan.name { target.name = name }
                addCanvas(target)
            } else {
                checkpoint()
            }
            updateCanvas(target.id) { canvas in
                if let background = plan.backgroundHex { canvas.backgroundHex = background }
                canvas.layers.removeAll { plan.removals.contains($0.id) }
                for update in plan.updates {
                    if let index = canvas.layers.firstIndex(where: { $0.id == update.id }) { canvas.layers[index] = update }
                }
            }
            if layer == nil { layerID = nil }
            // One layer at a time, so the build-up is visible and can be stopped midway.
            for (index, step) in plan.steps.enumerated() {
                try Task.checkCancellation()
                aiStatus = AppCopy.format("studio.ai.layerProgress", index + 1, plan.steps.count, step.layer.name)
                updateCanvas(target.id) { $0.layers.append(step.layer) }
                select(canvas: target.id, layer: step.layer.id)
                guard let imagePrompt = step.imagePrompt, imagesAvailable else {
                    if step.imagePrompt != nil { aiNote = AppCopy.text("studio.ai.noImages") }
                    try await Task.sleep(for: .milliseconds(120))
                    continue
                }
                do {
                    let media = try await MediaStudioAI.generate(
                        kind: .image, prompt: imagePrompt, router: model.router, settings: settings, paths: model.paths
                    )
                    let asset = try store.importAsset(from: media.url, into: project.id)
                    updateLayer(step.layer.id, in: target.id) { $0.assetName = asset }
                } catch {
                    try Task.checkCancellation()
                    // The design carries on without pictures: the layer keeps its tint and its
                    // description, and can be generated from the inspector once a generator works.
                    imagesAvailable = false
                    aiError = Self.message(for: error)
                    aiNote = AppCopy.text("studio.ai.noImages")
                }
            }
            if !plan.steps.isEmpty { select(canvas: target.id) }
        case .image, .video:
            aiStatus = AppCopy.text(kind == .video ? "studio.ai.renderingVideo" : "studio.ai.drawing")
            let media = try await MediaStudioAI.generate(
                kind: kind == .video ? .video : .image,
                prompt: prompt,
                router: model.router,
                settings: settings,
                paths: model.paths
            )
            try Task.checkCancellation()
            canvasID = target.id
            addMedia(at: media.url, fill: 1, name: String(prompt.prefix(40)), prompt: kind == .image ? prompt : nil)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? NativeAgentError)?.message ?? error.localizedDescription
    }
}
