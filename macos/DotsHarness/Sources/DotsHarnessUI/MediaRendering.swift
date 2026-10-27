// Copyright (c) 2026 DOTS
// Drawing of media canvases, shared by the editor, the project grid and export.

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore

extension Color {
    /// `#RRGGBB`; anything else reads as mid grey so a bad value is visible, not invisible.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#808080" }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}

struct HexColorPicker: View {
    let title: String
    @Binding var hex: String

    var body: some View {
        ColorPicker(
            title,
            selection: Binding(get: { Color(hex: hex) }, set: { hex = $0.hexString }),
            supportsOpacity: false
        )
    }
}

/// First frame of a video file, decoded once per path.
@MainActor
enum VideoPosterCache {
    private static let costLimit = 16 * 1024 * 1024
    private static let posters: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        cache.totalCostLimit = costLimit
        return cache
    }()

    static func poster(for url: URL) -> NSImage? {
        if let cached = posters.object(forKey: url.path as NSString) { return cached }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        let (pixels, pixelOverflow) = frame.width.multipliedReportingOverflow(by: frame.height)
        let (cost, costOverflow) = pixels.multipliedReportingOverflow(by: 4)
        if !pixelOverflow, !costOverflow, cost > 0, cost <= costLimit {
            posters.setObject(image, forKey: url.path as NSString, cost: cost)
        }
        return image
    }
}

/// A triangle, or a five-pointed star, filling its frame.
struct MediaPolygonShape: Shape {
    let star: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if star {
            for index in 0..<10 {
                let angle = Double(index) * .pi / 5 - .pi / 2
                let reach = index.isMultiple(of: 2) ? 1.0 : 0.4
                let point = CGPoint(
                    x: rect.midX + cos(angle) * reach * rect.width / 2,
                    y: rect.midY + sin(angle) * reach * rect.height / 2
                )
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        } else {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// An open path through points given as 0…1 pairs across the frame, with an optional arrowhead at the end.
struct MediaPathShape: Shape {
    let points: [Double]
    let arrow: Bool
    let head: CGFloat

    func path(in rect: CGRect) -> Path {
        let scaled = stride(from: 0, to: points.count - 1, by: 2).map {
            CGPoint(x: rect.minX + points[$0] * rect.width, y: rect.minY + points[$0 + 1] * rect.height)
        }
        var path = Path()
        guard scaled.count >= 2 else { return path }
        path.addLines(scaled)
        if arrow {
            let tip = scaled[scaled.count - 1]
            let from = scaled[scaled.count - 2]
            let angle = atan2(tip.y - from.y, tip.x - from.x)
            for side in [-1.0, 1.0] {
                path.move(to: tip)
                path.addLine(to: CGPoint(
                    x: tip.x - cos(angle + side * 0.5) * head,
                    y: tip.y - sin(angle + side * 0.5) * head
                ))
            }
        }
        return path
    }
}

/// One layer at its natural size. Positioning is the caller's job.
struct MediaLayerContent: View {
    let layer: MediaLayer
    let assetURL: URL?

    var body: some View {
        content
            .frame(width: layer.width, height: layer.height)
            // One shadow for the whole layer; without this a stroke casts its own inside the fill.
            .compositingGroup()
            .shadow(color: .black.opacity(layer.shadow > 0 ? 0.22 : 0), radius: layer.shadow, y: layer.shadow / 3)
            .opacity(layer.opacity)
            .rotationEffect(.degrees(layer.rotation))
    }

    private var fill: AnyShapeStyle {
        guard let gradient = layer.gradientHex else { return AnyShapeStyle(Color(hex: layer.colorHex)) }
        return AnyShapeStyle(LinearGradient(
            colors: [Color(hex: layer.colorHex), Color(hex: gradient)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
    }

    private var outline: AnyShape {
        switch layer.shape {
        case .ellipse: return AnyShape(Ellipse())
        case .polygon: return AnyShape(MediaPolygonShape(star: false))
        case .star: return AnyShape(MediaPolygonShape(star: true))
        case .rectangle: return AnyShape(RoundedRectangle(cornerRadius: layer.cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layer.kind {
        case .text where layer.arc != 0:
            arcText
        case .text:
            Text(layer.text)
                .font(.system(size: layer.fontSize, weight: weight, design: design))
                .foregroundStyle(fill)
                .multilineTextAlignment(textAlignment)
                .frame(width: layer.width, height: layer.height, alignment: frameAlignment)
        case .shape:
            outline.fill(fill)
                .overlay {
                    if let stroke = layer.strokeHex, layer.strokeWidth > 0 {
                        switch layer.shape {
                        case .ellipse:
                            Ellipse().strokeBorder(Color(hex: stroke), lineWidth: layer.strokeWidth)
                        case .rectangle:
                            RoundedRectangle(cornerRadius: layer.cornerRadius, style: .continuous)
                                .strokeBorder(Color(hex: stroke), lineWidth: layer.strokeWidth)
                        case .polygon, .star:
                            outline.stroke(Color(hex: stroke), style: StrokeStyle(lineWidth: layer.strokeWidth, lineJoin: .round))
                        }
                    }
                }
        case .path:
            MediaPathShape(points: layer.points, arrow: layer.arrow, head: max(layer.strokeWidth, 1) * 4)
                .stroke(fill, style: StrokeStyle(lineWidth: max(layer.strokeWidth, 1), lineCap: .round, lineJoin: .round))
        case .icon:
            // An unknown symbol name would draw nothing at all; a visible stand-in can be fixed.
            Image(systemName: NSImage(systemSymbolName: layer.symbol, accessibilityDescription: nil) == nil
                ? "questionmark.square.dashed" : layer.symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(fill)
        case .image:
            picture(assetURL.flatMap(ImageFileCache.image(at:)), placeholder: "photo")
        case .video:
            picture(assetURL.flatMap(VideoPosterCache.poster(for:)), placeholder: "film")
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: min(layer.width, layer.height) * 0.22))
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
        }
    }

    /// The text set along a circular arc, one character at a time.
    // ponytail: every character gets the same advance, so spacing is even rather than kerned,
    // and the path is always an arc; follow a drawn path if text on arbitrary curves is needed.
    private var arcText: some View {
        let characters = Array(layer.text.replacingOccurrences(of: "\n", with: " "))
        let total = layer.arc * .pi / 180
        let radius = Double(characters.count) * layer.fontSize * 0.6 / total
        let step = total / Double(max(characters.count - 1, 1))
        return ZStack {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                let angle = -total / 2 + step * Double(index)
                Text(String(character))
                    .font(.system(size: layer.fontSize, weight: weight, design: design))
                    .foregroundStyle(fill)
                    .rotationEffect(.radians(angle))
                    .offset(x: radius * sin(angle), y: radius * (1 - cos(angle)) - radius * (1 - cos(total / 2)) / 2)
            }
        }
        .frame(width: layer.width, height: layer.height)
    }

    /// Without a file the layer still reads as part of the design: its own tint, and a mark that says what belongs there.
    @ViewBuilder
    private func picture(_ image: NSImage?, placeholder: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: layer.cornerRadius, style: .continuous)
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: layer.width, height: layer.height)
                .clipShape(shape)
        } else {
            shape.fill(fill)
                .overlay {
                    Image(systemName: placeholder)
                        .font(.system(size: min(layer.width, layer.height) * 0.2))
                        .foregroundStyle(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.25), radius: 2)
                }
        }
    }

    private var weight: Font.Weight {
        switch layer.fontWeight {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        }
    }

    private var design: Font.Design {
        switch layer.fontDesign {
        case .standard: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }

    private var textAlignment: TextAlignment {
        switch layer.alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch layer.alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// A whole canvas at its natural size, clipped to its bounds.
struct MediaCanvasContent: View {
    let canvas: MediaCanvas
    /// Canvases nested inside this one, parents before children; drawn over its own layers.
    var nested: [MediaCanvas] = []
    let assetURL: (String) -> URL

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: canvas.backgroundHex)
            ForEach(canvas.layers.filter { !$0.hidden && !$0.comment }) { layer in
                MediaLayerContent(layer: layer, assetURL: layer.assetName.map(assetURL))
                    .offset(x: layer.x, y: layer.y)
            }
            ForEach(nested) { child in
                MediaCanvasContent(canvas: child, assetURL: assetURL)
                    .offset(x: child.x - canvas.x, y: child.y - canvas.y)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        // Canvas coordinates are absolute, so a right-to-left interface must not mirror them.
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// A canvas scaled down to fit the space it is given.
struct MediaCanvasPreview: View {
    let canvas: MediaCanvas
    let assetURL: (String) -> URL

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / canvas.width, proxy.size.height / canvas.height)
            MediaCanvasContent(canvas: canvas, assetURL: assetURL)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }
}

enum MediaExportFormat: String, CaseIterable, Identifiable {
    case png, jpeg, pdf

    var id: String { rawValue }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var title: String { rawValue.uppercased() }
}

@MainActor
enum MediaExport {
    /// PNG keeps transparency, JPEG is flattened onto white, PDF stays vector and ignores `scale`.
    static func data(of content: some View, format: MediaExportFormat, scale: CGFloat) -> Data? {
        let renderer = ImageRenderer(
            content: content
                .background(format == .jpeg ? Color.white : Color.clear)
                .environment(\.layoutDirection, .leftToRight)
        )
        renderer.scale = scale
        if format == .pdf {
            let data = NSMutableData()
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: data as CFMutableData),
                      let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
            }
            return data.length > 0 ? data as Data : nil
        }
        guard let image = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return format == .jpeg
            ? bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            : bitmap.representation(using: .png, properties: [:])
    }

    static func data(
        of canvas: MediaCanvas, nested: [MediaCanvas] = [], format: MediaExportFormat, scale: CGFloat,
        assetURL: @escaping (String) -> URL
    ) -> Data? {
        data(of: MediaCanvasContent(canvas: canvas, nested: nested, assetURL: assetURL), format: format, scale: scale)
    }

    /// One rectangle of a canvas, in the canvas's own coordinates.
    static func data(
        of canvas: MediaCanvas, nested: [MediaCanvas] = [], region: CGRect, format: MediaExportFormat, scale: CGFloat,
        assetURL: @escaping (String) -> URL
    ) -> Data? {
        data(
            of: MediaCanvasContent(canvas: canvas, nested: nested, assetURL: assetURL)
                .offset(x: -region.minX, y: -region.minY)
                .frame(width: region.width, height: region.height, alignment: .topLeading)
                .clipped(),
            format: format, scale: scale
        )
    }

    /// A layer exports inside the bounds of its rotated frame plus its shadow's
    /// reach, so neither is cut at the unrotated frame edge.
    static func data(
        of layer: MediaLayer, format: MediaExportFormat, scale: CGFloat, assetURL: @escaping (String) -> URL
    ) -> Data? {
        let bounds = exportBounds(of: layer)
        return data(
            of: MediaLayerContent(layer: layer, assetURL: layer.assetName.map(assetURL))
                .frame(width: bounds.width, height: bounds.height),
            format: format, scale: scale
        )
    }

    static func exportBounds(of layer: MediaLayer) -> CGSize {
        let radians = layer.rotation * .pi / 180
        let cosine = abs(cos(radians)), sine = abs(sin(radians))
        // Blur reaches ~radius past the edge, plus the radius/3 downward offset, on both sides to stay centered.
        let reach = layer.shadow > 0 ? (layer.shadow + layer.shadow / 3) * 2 : 0
        return CGSize(
            width: (layer.width * cosine + layer.height * sine).rounded(.up) + reach,
            height: (layer.width * sine + layer.height * cosine).rounded(.up) + reach
        )
    }

    static func save(_ data: Data?, name: String, format: MediaExportFormat) {
        guard let data else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = "\(fileName(name)).\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Writes every canvas into a folder the user picks; canvases sharing a name get a number.
    static func saveAll(
        _ canvases: [MediaCanvas], nested: (MediaCanvas) -> [MediaCanvas], format: MediaExportFormat, scale: CGFloat,
        assetURL: @escaping (String) -> URL
    ) {
        var used: [String: Int] = [:]
        let files: [(String, Data)] = canvases.compactMap { canvas in
            guard let data = data(of: canvas, nested: nested(canvas), format: format, scale: scale, assetURL: assetURL)
            else { return nil }
            let base = fileName(canvas.name)
            let count = used[base, default: 0] + 1
            used[base] = count
            return ("\(count == 1 ? base : "\(base) \(count)").\(format.fileExtension)", data)
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            for (name, data) in files {
                try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
            }
        }
    }

    private static func fileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "canvas" : cleaned
    }
}
