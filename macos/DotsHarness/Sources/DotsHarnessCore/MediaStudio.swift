// Copyright (c) 2026 DOTS
// Media studio: projects made of canvases on one board, each a stack of layers.

import Foundation
import PluginRuntime

public struct MediaLayer: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case text, image, shape, video, icon, path }
    public enum FontDesign: String, Codable, Sendable, CaseIterable { case standard = "default", rounded, serif, mono }
    public enum Shape: String, Codable, Sendable, CaseIterable { case rectangle, ellipse, polygon, star }
    public enum Alignment: String, Codable, Sendable, CaseIterable { case leading, center, trailing }
    public enum Weight: String, Codable, Sendable, CaseIterable { case regular, medium, bold }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Frame in the owning canvas's coordinates (points, origin top-left).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var opacity: Double
    public var hidden: Bool
    public var text: String
    public var fontSize: Double
    public var fontWeight: Weight
    public var alignment: Alignment
    /// Text or icon colour, shape fill, or the tint of an image that has no file yet.
    public var colorHex: String
    public var shape: Shape
    public var cornerRadius: Double
    /// File name inside the project's `assets` folder (image and video layers).
    public var assetName: String?
    public var locked: Bool
    /// Degrees, clockwise, around the layer's centre.
    public var rotation: Double
    /// Second colour; when set the fill is a diagonal gradient from `colorHex`.
    public var gradientHex: String?
    public var strokeHex: String?
    public var strokeWidth: Double
    /// Blur radius of a drop shadow; zero draws none.
    public var shadow: Double
    /// SF Symbols name (icon layers).
    public var symbol: String
    public var fontDesign: FontDesign
    /// What an image layer should show, kept so it can be generated or regenerated later.
    public var prompt: String?
    /// Path layers: x and y pairs, each 0…1 across the layer's frame. Drawn with `colorHex` at `strokeWidth`.
    public var points: [Double]
    /// Path layers: an arrowhead on the last point.
    public var arrow: Bool
    /// Text layers: degrees of arc the line bends through; zero keeps it straight.
    public var arc: Double
    /// A note pinned to the canvas: shown while editing, left out of previews and exports. Its words are in `text`.
    public var comment: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: Kind,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        opacity: Double = 1,
        hidden: Bool = false,
        text: String = "",
        fontSize: Double = 48,
        fontWeight: Weight = .bold,
        alignment: Alignment = .center,
        colorHex: String = "#111111",
        shape: Shape = .rectangle,
        cornerRadius: Double = 0,
        assetName: String? = nil,
        locked: Bool = false,
        rotation: Double = 0,
        gradientHex: String? = nil,
        strokeHex: String? = nil,
        strokeWidth: Double = 0,
        shadow: Double = 0,
        symbol: String = "star.fill",
        fontDesign: FontDesign = .standard,
        prompt: String? = nil,
        points: [Double] = [],
        arrow: Bool = false,
        arc: Double = 0,
        comment: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.opacity = opacity
        self.hidden = hidden
        self.text = text
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.alignment = alignment
        self.colorHex = colorHex
        self.shape = shape
        self.cornerRadius = cornerRadius
        self.assetName = assetName
        self.locked = locked
        self.rotation = rotation
        self.gradientHex = gradientHex
        self.strokeHex = strokeHex
        self.strokeWidth = strokeWidth
        self.shadow = shadow
        self.symbol = symbol
        self.fontDesign = fontDesign
        self.prompt = prompt
        self.points = points
        self.arrow = arrow
        self.arc = arc
        self.comment = comment
    }

    /// Fields added after the first release are optional on disk, so older projects still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 48
        fontWeight = try c.decodeIfPresent(Weight.self, forKey: .fontWeight) ?? .bold
        alignment = try c.decodeIfPresent(Alignment.self, forKey: .alignment) ?? .center
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#111111"
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? .rectangle
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        assetName = try c.decodeIfPresent(String.self, forKey: .assetName)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        gradientHex = try c.decodeIfPresent(String.self, forKey: .gradientHex)
        strokeHex = try c.decodeIfPresent(String.self, forKey: .strokeHex)
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "star.fill"
        fontDesign = try c.decodeIfPresent(FontDesign.self, forKey: .fontDesign) ?? .standard
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        points = try c.decodeIfPresent([Double].self, forKey: .points) ?? []
        arrow = try c.decodeIfPresent(Bool.self, forKey: .arrow) ?? false
        arc = try c.decodeIfPresent(Double.self, forKey: .arc) ?? 0
        comment = try c.decodeIfPresent(Bool.self, forKey: .comment) ?? false
    }
}

public struct MediaCanvas: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// Position on the project board.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var backgroundHex: String
    /// Back to front.
    public var layers: [MediaLayer]
    /// A section sits behind the canvases on the board and carries the ones inside it when moved.
    /// Optional so projects saved before sections existed still open.
    public var section: Bool?
    /// The canvas this one sits inside. A child keeps board coordinates of its own and is moved,
    /// exported and deleted with its parent.
    public var parentID: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        x: Double = 0,
        y: Double = 0,
        width: Double,
        height: Double,
        backgroundHex: String = "#FFFFFF",
        layers: [MediaLayer] = []
    ) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.backgroundHex = backgroundHex
        self.layers = layers
    }
}

public struct MediaProject: StudioProject, Sendable, Equatable {
    public var id: String
    public var name: String
    public var canvases: [MediaCanvas]
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, canvases: [MediaCanvas], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.canvases = canvases
        self.updatedAt = updatedAt
    }
}

public struct MediaSizePreset: Identifiable, Sendable, Equatable {
    public var id: String
    public var width: Double
    public var height: Double
    public var systemImage: String
    public var title: String { AppCopy.text("studio.preset.\(id)") }

    public static let all: [MediaSizePreset] = [
        MediaSizePreset(id: "square", width: 1080, height: 1080, systemImage: "square"),
        MediaSizePreset(id: "story", width: 1080, height: 1920, systemImage: "rectangle.portrait"),
        MediaSizePreset(id: "landscape", width: 1920, height: 1080, systemImage: "rectangle"),
        MediaSizePreset(id: "thumbnail", width: 1280, height: 720, systemImage: "play.rectangle"),
        MediaSizePreset(id: "logo", width: 512, height: 512, systemImage: "seal"),
        MediaSizePreset(id: "poster", width: 1240, height: 1754, systemImage: "doc"),
    ]
}

/// Ready-made canvas sizes, grouped the way a designer looks for them.
public struct MediaFrameGroup: Identifiable, Sendable {
    public struct Preset: Identifiable, Sendable {
        public var name: String
        public var width: Double
        public var height: Double
        public var id: String { name }
    }

    public var id: String
    public var presets: [Preset]
    public var title: String { AppCopy.text("studio.frames.\(id)") }

    private static func group(_ id: String, _ presets: [(String, Double, Double)]) -> MediaFrameGroup {
        MediaFrameGroup(id: id, presets: presets.map { Preset(name: $0.0, width: $0.1, height: $0.2) })
    }

    public static let all: [MediaFrameGroup] = [
        group("phone", [
            ("iPhone 17", 402, 874), ("iPhone 16 & 17 Pro", 402, 874), ("iPhone 16", 393, 852),
            ("iPhone 16 & 17 Pro Max", 440, 956), ("iPhone 16 Plus", 430, 932), ("iPhone Air", 420, 912),
            ("iPhone 14 & 15 Pro Max", 430, 932), ("iPhone 14 & 15 Pro", 393, 852), ("iPhone 13 & 14", 390, 844),
            ("iPhone 14 Plus", 428, 926), ("Android Compact", 412, 917), ("Android Medium", 700, 840),
        ]),
        group("tablet", [
            ("iPad mini 8.3", 744, 1133), ("iPad Pro 11\"", 834, 1194), ("iPad Pro 12.9\"", 1024, 1366),
            ("Surface Pro 8", 1440, 960),
        ]),
        group("desktop", [
            ("MacBook Air", 1280, 832), ("MacBook Pro 14\"", 1512, 982), ("MacBook Pro 16\"", 1728, 1117),
            ("Desktop", 1440, 1024), ("Full HD", 1920, 1080), ("TV", 1280, 720),
        ]),
        group("presentation", [("Slide 16:9", 1920, 1080), ("Slide 4:3", 1024, 768)]),
        group("watch", [
            ("Apple Watch 46mm", 208, 248), ("Apple Watch 42mm", 187, 223), ("Apple Watch 45mm", 198, 242),
            ("Apple Watch 41mm", 176, 215), ("Apple Watch 44mm", 184, 224), ("Apple Watch 40mm", 162, 197),
        ]),
        group("paper", [
            ("A4", 595, 842), ("A5", 420, 595), ("A6", 297, 420), ("Letter", 612, 792), ("Tabloid", 792, 1224),
        ]),
        MediaFrameGroup(
            id: "social",
            presets: MediaSizePreset.all.map { Preset(name: $0.title, width: $0.width, height: $0.height) } + [
                Preset(name: "X post", width: 1200, height: 675), Preset(name: "X header", width: 1500, height: 500),
                Preset(name: "Facebook post", width: 1200, height: 630), Preset(name: "Facebook cover", width: 820, height: 312),
                Preset(name: "LinkedIn cover", width: 1584, height: 396),
            ]
        ),
    ]
}

/// A ready-made canvas. Built from text and shapes only, so it needs no bundled assets.
public struct MediaTemplate: Identifiable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case social, uiux, presentation, other
        public var title: String { AppCopy.text("studio.category.\(rawValue)") }
    }

    public var id: String
    public var category: Category = .social
    public var title: String { AppCopy.text("studio.template.\(id)") }
    let build: @Sendable () -> MediaCanvas

    public func canvas() -> MediaCanvas {
        var canvas = build()
        canvas.id = UUID().uuidString
        canvas.name = title
        canvas.layers = canvas.layers.map { layer in
            var copy = layer
            copy.id = UUID().uuidString
            return copy
        }
        return canvas
    }

    public static let all: [MediaTemplate] = [
        MediaTemplate(id: "announcement") {
            MediaCanvas(name: "", width: 1080, height: 1080, backgroundHex: "#14213D", layers: [
                MediaLayer(name: "Band", kind: .shape, x: 0, y: 760, width: 1080, height: 320, colorHex: "#FCA311"),
                MediaLayer(name: "Title", kind: .text, x: 80, y: 250, width: 920, height: 260,
                           text: AppCopy.text("studio.sample.title"), fontSize: 110, alignment: .leading, colorHex: "#FFFFFF"),
                MediaLayer(name: "Detail", kind: .text, x: 80, y: 830, width: 920, height: 160,
                           text: AppCopy.text("studio.sample.detail"), fontSize: 48, fontWeight: .medium, alignment: .leading, colorHex: "#14213D"),
            ])
        },
        MediaTemplate(id: "story") {
            MediaCanvas(name: "", width: 1080, height: 1920, backgroundHex: "#F1FAEE", layers: [
                MediaLayer(name: "Circle", kind: .shape, x: 190, y: 420, width: 700, height: 700, colorHex: "#E63946", shape: .ellipse),
                MediaLayer(name: "Title", kind: .text, x: 240, y: 640, width: 600, height: 260,
                           text: AppCopy.text("studio.sample.title"), fontSize: 96, colorHex: "#FFFFFF"),
                MediaLayer(name: "Detail", kind: .text, x: 140, y: 1300, width: 800, height: 200,
                           text: AppCopy.text("studio.sample.detail"), fontSize: 54, fontWeight: .medium, colorHex: "#1D3557"),
            ])
        },
        MediaTemplate(id: "thumbnail") {
            MediaCanvas(name: "", width: 1280, height: 720, backgroundHex: "#0B132B", layers: [
                MediaLayer(name: "Panel", kind: .shape, x: 60, y: 60, width: 560, height: 600, colorHex: "#5BC0BE", cornerRadius: 36),
                MediaLayer(name: "Title", kind: .text, x: 680, y: 190, width: 540, height: 240,
                           text: AppCopy.text("studio.sample.title"), fontSize: 92, alignment: .leading, colorHex: "#FFFFFF"),
                MediaLayer(name: "Detail", kind: .text, x: 680, y: 450, width: 540, height: 120,
                           text: AppCopy.text("studio.sample.detail"), fontSize: 40, fontWeight: .regular, alignment: .leading, colorHex: "#C9D6DF"),
            ])
        },
        MediaTemplate(id: "mobile", category: .uiux) {
            MediaCanvas(name: "", width: 390, height: 844, backgroundHex: "#F8FAFC", layers: [
                MediaLayer(name: "Hero", kind: .shape, x: 24, y: 80, width: 342, height: 300, colorHex: "#4F46E5", cornerRadius: 28),
                MediaLayer(name: "Title", kind: .text, x: 24, y: 420, width: 342, height: 90,
                           text: AppCopy.text("studio.sample.title"), fontSize: 34, alignment: .leading, colorHex: "#0F172A"),
                MediaLayer(name: "Detail", kind: .text, x: 24, y: 520, width: 342, height: 60,
                           text: AppCopy.text("studio.sample.detail"), fontSize: 16, fontWeight: .regular, alignment: .leading, colorHex: "#64748B"),
                MediaLayer(name: "Button", kind: .shape, x: 24, y: 720, width: 342, height: 56, colorHex: "#0F172A", cornerRadius: 16),
                MediaLayer(name: "Label", kind: .text, x: 24, y: 734, width: 342, height: 28,
                           text: AppCopy.text("studio.sample.text"), fontSize: 17, colorHex: "#FFFFFF"),
            ])
        },
        MediaTemplate(id: "slide", category: .presentation) {
            MediaCanvas(name: "", width: 1920, height: 1080, backgroundHex: "#FAFAFA", layers: [
                MediaLayer(name: "Rule", kind: .shape, x: 140, y: 470, width: 220, height: 12, colorHex: "#2A9D8F"),
                MediaLayer(name: "Title", kind: .text, x: 140, y: 240, width: 1500, height: 200,
                           text: AppCopy.text("studio.sample.title"), fontSize: 130, alignment: .leading, colorHex: "#264653"),
                MediaLayer(name: "Detail", kind: .text, x: 140, y: 530, width: 1300, height: 200,
                           text: AppCopy.text("studio.sample.detail"), fontSize: 56, fontWeight: .regular, alignment: .leading, colorHex: "#52616B"),
            ])
        },
        MediaTemplate(id: "logo", category: .other) {
            MediaCanvas(name: "", width: 512, height: 512, backgroundHex: "#FFFFFF", layers: [
                MediaLayer(name: "Mark", kind: .shape, x: 156, y: 80, width: 200, height: 200, colorHex: "#3D5A80", cornerRadius: 48),
                MediaLayer(name: "Dot", kind: .shape, x: 226, y: 150, width: 60, height: 60, colorHex: "#EE6C4D", shape: .ellipse),
                MediaLayer(name: "Name", kind: .text, x: 56, y: 320, width: 400, height: 90,
                           text: AppCopy.text("studio.sample.brand"), fontSize: 64, colorHex: "#293241"),
            ])
        },
    ]
}

/// Where the studio's generated images, videos and music come from.
public struct MediaStudioSettings: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// A connected provider account, through the model router.
        case provider
        /// An OpenAI-compatible server on this machine or network.
        case local
    }

    /// Chat model that plans layers. Empty follows the app's selected model.
    public var plannerModelID = ""
    public var imageSource: Source = .provider
    /// Empty uses the provider's own default image model.
    public var imageModel = ""
    public var videoSource: Source = .provider
    public var videoModel = ""
    public var musicSource: Source = .provider
    public var musicModel = ""
    /// Music APIs connected by address, and the one in use. Empty follows `musicSource`.
    public var musicEndpoints: [MusicEndpoint] = []
    public var musicEndpointID = ""
    // ponytail: no API key here; a keyed remote endpoint belongs in Providers, which stores credentials safely.
    public var localBaseURL = "http://127.0.0.1:8080/v1"

    public init() {}

    /// Every field is optional on disk, so settings saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plannerModelID = try c.decodeIfPresent(String.self, forKey: .plannerModelID) ?? plannerModelID
        imageSource = try c.decodeIfPresent(Source.self, forKey: .imageSource) ?? imageSource
        imageModel = try c.decodeIfPresent(String.self, forKey: .imageModel) ?? imageModel
        videoSource = try c.decodeIfPresent(Source.self, forKey: .videoSource) ?? videoSource
        videoModel = try c.decodeIfPresent(String.self, forKey: .videoModel) ?? videoModel
        musicSource = try c.decodeIfPresent(Source.self, forKey: .musicSource) ?? musicSource
        musicModel = try c.decodeIfPresent(String.self, forKey: .musicModel) ?? musicModel
        musicEndpoints = try c.decodeIfPresent([MusicEndpoint].self, forKey: .musicEndpoints) ?? musicEndpoints
        musicEndpointID = try c.decodeIfPresent(String.self, forKey: .musicEndpointID) ?? musicEndpointID
        localBaseURL = try c.decodeIfPresent(String.self, forKey: .localBaseURL) ?? localBaseURL
    }

    public var musicEndpoint: MusicEndpoint? { musicEndpoints.first { $0.id == musicEndpointID } }

    public func source(for kind: MediaKind) -> Source {
        switch kind {
        case .video: return videoSource
        case .music: return musicSource
        case .image, .audio: return imageSource
        }
    }

    public func model(for kind: MediaKind) -> String {
        let model: String
        switch kind {
        case .video: model = videoModel
        case .music: model = musicEndpoint?.model ?? musicModel
        case .image, .audio: model = imageModel
        }
        return model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
public final class MediaStudioStore: StudioProjectStore<MediaProject> {
    @Published public var settings = MediaStudioSettings() {
        didSet {
            guard settings != oldValue else { return }
            write(settings, to: root.appendingPathComponent("settings.json"))
        }
    }

    public init(root: URL) {
        super.init(root: root, fallbackAssetExtension: "bin")
    }

    public override func loadIfNeeded() {
        guard !hasLoaded else { return }
        if let saved = read(MediaStudioSettings.self, from: root.appendingPathComponent("settings.json")) {
            settings = saved
        }
        super.loadIfNeeded()
    }

    @discardableResult
    public func create(name: String, canvas: MediaCanvas? = nil) -> MediaProject {
        let project = MediaProject(name: name, canvases: canvas.map { [$0] } ?? [])
        save(project)
        return project
    }

    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var project = project(id) else { return }
        project.name = trimmed
        save(project)
    }

    public func duplicate(_ id: String) {
        guard var copy = project(id) else { return }
        let source = directory(for: id)
        copy.id = UUID().uuidString
        copy.name = AppCopy.format("studio.copyOf", copy.name)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: source, to: directory(for: copy.id))
        save(copy)
    }
}

/// Turns a written request into layer edits, and prompts into generated media.
public enum MediaStudioAI {
    public struct Step: Sendable, Equatable {
        public var layer: MediaLayer
        /// Set for image layers the model wants generated rather than left empty.
        public var imagePrompt: String?
    }

    public struct Plan: Sendable, Equatable {
        /// A name for the canvas, used when the plan fills a new one.
        public var name: String?
        public var backgroundHex: String?
        /// Ids of existing layers to delete.
        public var removals: [String]
        /// Existing layers with the model's changes already applied.
        public var updates: [MediaLayer]
        /// New layers, back to front.
        public var steps: [Step]
    }

    public static let maxLayers = 60
    public static let nextScreenRequest = "Design the screen that naturally follows the reference in this flow."

    static func instructions(imagesAvailable: Bool) -> String {
        """
        You design canvases for a graphics editor that works like Figma. Reply with a single JSON object and nothing else:
        {"name":"canvas name","background":"#RRGGBB","remove":["L2"],"update":[{"id":"L1","color":"#RRGGBB"}],\
        "layers":[{"type":"shape|text|icon|image","name":"short label","x":0,"y":0,"width":0,"height":0,\
        "rotation":0,"opacity":1,"color":"#RRGGBB","color2":"#RRGGBB","stroke":"#RRGGBB","strokeWidth":0,"shadow":0,\
        "shape":"rectangle|ellipse|polygon|star","cornerRadius":0,"text":"","fontSize":0,"fontWeight":"regular|medium|bold",\
        "font":"default|rounded|serif|mono","align":"leading|center|trailing","symbol":"","prompt":""}]}
        Every key is optional; leave out what you do not need. "layers" are new layers, drawn above the existing \
        ones in the order given, back to front. "update" changes existing layers by id and takes the same fields; \
        give only the fields that change. "remove" deletes existing layers. When the request changes the existing \
        design, use "update" and "remove" instead of adding duplicates. "background" recolours the canvas.
        Coordinates are points from the canvas's top-left corner and every layer must fit inside the canvas. \
        "color" fills a shape, colours text or an icon, and tints an image that has no picture yet. "color2" turns \
        that fill into a diagonal gradient. "shadow" is a blur radius. For an icon, "symbol" is an SF Symbols name \
        such as pawprint.fill, heart.fill, star.fill, bell.fill, house.fill, cart.fill, person.fill, magnifyingglass, \
        arrow.right, checkmark.circle.fill, play.fill, leaf.fill, bolt.fill, camera.fill, mappin, calendar, envelope.fill.
        Work like a designer: background washes and large decorative shapes first, then cards and panels, then \
        icons and text. A button is a rounded rectangle with a text layer over it. Give text layers a box wide and \
        tall enough for their words at the chosen size. Name each layer the way it should read in a layers panel. \
        Use at most \(maxLayers) layers, keep text short, and write text in the language of the request.
        \(imagesAvailable
            ? "Use image layers only for photos and illustrations; \"prompt\" is a complete description for an image generator."
            : "No image generator is connected: do not add image layers. Draw illustrations from shapes, gradients and icons.")
        """
    }

    /// Layers are shown to the model as `L1…Ln`, back to front: short, and harder to get wrong than a UUID.
    static func describe(_ canvas: MediaCanvas) -> String {
        guard !canvas.layers.isEmpty else { return "none" }
        return canvas.layers.enumerated().map { index, layer in
            var item: [String: Any] = [
                "id": "L\(index + 1)", "type": layer.kind.rawValue, "name": layer.name,
                "x": Int(layer.x), "y": Int(layer.y), "width": Int(layer.width), "height": Int(layer.height),
                "color": layer.colorHex,
            ]
            if layer.rotation != 0 { item["rotation"] = Int(layer.rotation) }
            if layer.opacity < 1 { item["opacity"] = (layer.opacity * 100).rounded() / 100 }
            if let gradient = layer.gradientHex { item["color2"] = gradient }
            if let stroke = layer.strokeHex, layer.strokeWidth > 0 {
                item["stroke"] = stroke
                item["strokeWidth"] = Int(layer.strokeWidth)
            }
            if layer.shadow > 0 { item["shadow"] = Int(layer.shadow) }
            if layer.hidden { item["hidden"] = true }
            switch layer.kind {
            case .text:
                item["text"] = layer.text
                item["fontSize"] = Int(layer.fontSize)
                item["fontWeight"] = layer.fontWeight.rawValue
                item["font"] = layer.fontDesign.rawValue
                item["align"] = layer.alignment.rawValue
            case .shape:
                item["shape"] = layer.shape.rawValue
                if layer.cornerRadius > 0 { item["cornerRadius"] = Int(layer.cornerRadius) }
            case .icon:
                item["symbol"] = layer.symbol
            case .image:
                if let prompt = layer.prompt { item["prompt"] = prompt }
            case .video, .path:
                break
            }
            let data = (try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        .joined(separator: "\n")
    }

    /// `reference` is the screen a new canvas should follow on from.
    public static func planMessages(
        prompt: String,
        canvas: MediaCanvas,
        selectedLayerID: String? = nil,
        reference: MediaCanvas? = nil,
        imagesAvailable: Bool = true
    ) -> [AgentMessage] {
        var state = """
        Canvas "\(canvas.name)": \(Int(canvas.width))x\(Int(canvas.height)) points, background \(canvas.backgroundHex).
        Layers, back to front:
        \(describe(canvas))
        """
        if let index = canvas.layers.firstIndex(where: { $0.id == selectedLayerID }) {
            state += "\nSelected layer (what \"this\" means in the request): L\(index + 1)"
        }
        if let reference {
            state += """


            Reference: the previous screen "\(reference.name)", \(Int(reference.width))x\(Int(reference.height)), \
            background \(reference.backgroundHex). Keep its palette, type, spacing and recurring elements such as \
            the logo and navigation, in the same places. Its layer ids cannot be updated; add new layers.
            \(describe(reference))
            """
        }
        state += "\n\nRequest: \(prompt)"
        return [
            AgentMessage(role: .system, content: instructions(imagesAvailable: imagesAvailable)),
            AgentMessage(role: .user, content: state),
        ]
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func hex(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces),
              raw.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return nil }
        return raw.uppercased()
    }

    /// Copies the fields `item` carries onto `layer`, then pulls the result back inside the canvas.
    private static func apply(_ item: [String: Any], to layer: inout MediaLayer, canvas: MediaCanvas) {
        if let name = item["name"] as? String, !name.isEmpty { layer.name = String(name.prefix(40)) }
        layer.width = min(max(number(item["width"]) ?? layer.width, 0), canvas.width)
        layer.height = min(max(number(item["height"]) ?? layer.height, 0), canvas.height)
        layer.x = min(max(number(item["x"]) ?? layer.x, 0), canvas.width - layer.width)
        layer.y = min(max(number(item["y"]) ?? layer.y, 0), canvas.height - layer.height)
        if let value = number(item["rotation"]) { layer.rotation = value.remainder(dividingBy: 360) }
        if let value = number(item["opacity"]) { layer.opacity = min(max(value, 0.05), 1) }
        if let value = item["hidden"] as? Bool { layer.hidden = value }
        if let value = hex(item["color"]) { layer.colorHex = value }
        if item["color2"] != nil { layer.gradientHex = hex(item["color2"]) }
        if item["stroke"] != nil { layer.strokeHex = hex(item["stroke"]) }
        if let value = number(item["strokeWidth"]) { layer.strokeWidth = min(max(value, 0), 200) }
        if let value = number(item["shadow"]) { layer.shadow = min(max(value, 0), 200) }
        if let value = item["text"] as? String { layer.text = value }
        if let value = number(item["fontSize"]) { layer.fontSize = min(max(value, 6), 600) }
        if let value = (item["fontWeight"] as? String).flatMap(MediaLayer.Weight.init(rawValue:)) { layer.fontWeight = value }
        if let value = (item["font"] as? String).flatMap(MediaLayer.FontDesign.init(rawValue:)) { layer.fontDesign = value }
        if let value = (item["align"] as? String).flatMap(MediaLayer.Alignment.init(rawValue:)) { layer.alignment = value }
        if let value = (item["shape"] as? String).flatMap(MediaLayer.Shape.init(rawValue:)) { layer.shape = value }
        if let value = item["symbol"] as? String, !value.isEmpty { layer.symbol = value }
        if let value = (item["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            layer.prompt = value
        }
        layer.cornerRadius = min(max(number(item["cornerRadius"]) ?? layer.cornerRadius, 0), min(layer.width, layer.height) / 2)
    }

    /// Tolerant of prose or code fences around the object; entries the model got wrong are dropped, not fatal.
    public static func parsePlan(_ text: String, canvas: MediaCanvas) -> Plan? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let root = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { return nil }

        func existing(_ id: Any?) -> MediaLayer? {
            guard let id = id as? String, id.hasPrefix("L"), let index = Int(id.dropFirst()),
                  canvas.layers.indices.contains(index - 1) else { return nil }
            return canvas.layers[index - 1]
        }

        let removals = ((root["remove"] as? [Any]) ?? []).compactMap { existing($0)?.id }
        let updates: [MediaLayer] = ((root["update"] as? [[String: Any]]) ?? []).compactMap { item in
            guard var layer = existing(item["id"]), !removals.contains(layer.id) else { return nil }
            apply(item, to: &layer, canvas: canvas)
            return layer.width >= 1 && layer.height >= 1 ? layer : nil
        }
        let steps: [Step] = ((root["layers"] as? [[String: Any]]) ?? []).prefix(maxLayers).compactMap { item in
            guard let kind = (item["type"] as? String).flatMap(MediaLayer.Kind.init(rawValue:)), kind != .video, kind != .path else { return nil }
            var layer = MediaLayer(
                name: kind.rawValue.capitalized, kind: kind, x: 0, y: 0, width: 0, height: 0,
                colorHex: kind == .text || kind == .icon ? "#111111" : "#D9D9D9"
            )
            apply(item, to: &layer, canvas: canvas)
            guard layer.width >= 1, layer.height >= 1 else { return nil }
            if kind == .text, layer.text.isEmpty { return nil }
            return Step(layer: layer, imagePrompt: kind == .image ? layer.prompt : nil)
        }
        let background = hex(root["background"])
        guard !steps.isEmpty || !updates.isEmpty || !removals.isEmpty || background != nil else { return nil }
        let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Plan(
            name: name?.isEmpty == false ? name.map { String($0.prefix(40)) } : nil,
            backgroundHex: background, removals: removals, updates: updates, steps: steps
        )
    }

    /// Whether an image request has somewhere to go. A provider can still refuse; callers fall back then too.
    @MainActor
    public static func canGenerateImages(router: RouterController, settings: MediaStudioSettings) async -> Bool {
        if settings.imageSource == .local { return !settings.model(for: .image).isEmpty }
        if await router.mediaConfiguration(for: .image) != nil { return true }
        return router.imagePrimaryAccount != nil
    }

    @MainActor
    public static func plan(
        prompt: String,
        canvas: MediaCanvas,
        selectedLayerID: String? = nil,
        reference: MediaCanvas? = nil,
        imagesAvailable: Bool,
        router: RouterController,
        settings: MediaStudioSettings
    ) async throws -> Plan {
        let model = router.usableModelID(settings.plannerModelID)
        let response = try await router.complete(
            messages: planMessages(
                prompt: prompt, canvas: canvas, selectedLayerID: selectedLayerID,
                reference: reference, imagesAvailable: imagesAvailable
            ),
            model: model.isEmpty ? nil : model
        )
        guard let plan = parsePlan(response.message.content, canvas: canvas) else {
            throw NativeAgentError(AppCopy.text("studio.ai.noPlan"))
        }
        return plan
    }

    @MainActor
    public static func generate(
        kind: MediaKind,
        prompt: String,
        router: RouterController,
        settings: MediaStudioSettings,
        paths: SupportPaths,
        seconds: Int? = nil,
        stem: MusicStemRequest? = nil
    ) async throws -> ChatMedia {
        let model = settings.model(for: kind)
        if kind == .music, let endpoint = settings.musicEndpoint {
            var configuration = AgentConfiguration(baseURL: endpoint.baseURL, model: model, provider: endpoint.name)
            configuration.apiKey = endpoint.apiKey
            return try await MediaGenerationClient.generate(
                kind: kind,
                prompt: prompt,
                configuration: configuration,
                provider: ProviderMediaSpec(model: model, format: endpoint.format.rawValue),
                paths: paths,
                seconds: seconds,
                stem: stem
            )
        }
        if settings.source(for: kind) == .local {
            guard !model.isEmpty else { throw NativeAgentError(AppCopy.text("media.modelMissing")) }
            return try await MediaGenerationClient.generate(
                kind: kind,
                prompt: prompt,
                configuration: AgentConfiguration(baseURL: settings.localBaseURL, model: model, provider: "Local"),
                provider: ProviderMediaSpec(model: model),
                paths: paths,
                seconds: seconds,
                stem: stem
            )
        }
        if let route = await router.mediaConfiguration(for: kind) {
            var provider = route.provider
            if !model.isEmpty { provider.model = model }
            return try await MediaGenerationClient.generate(
                kind: kind, prompt: prompt, configuration: route.configuration, provider: provider, paths: paths,
                seconds: seconds, stem: stem
            )
        }
        // Providers without a declared media endpoint may still draw through an image adapter.
        guard kind == .image else {
            throw NativeAgentError(AppCopy.format("media.unsupported", kind.displayName))
        }
        let generated = try await router.generateImage(prompt: prompt)
        return try MediaGenerationClient.save(generated.output.data, kind: .image, paths: paths, prompt: prompt)
    }
}
