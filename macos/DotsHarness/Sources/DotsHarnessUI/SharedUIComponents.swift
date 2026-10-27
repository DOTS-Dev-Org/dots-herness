// Copyright (c) 2026 DOTS
// Small shared primitives for the native macOS UI.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore

/// `NSImage(contentsOf:)` inside a view body reads and decodes the file on every
/// render. Keyed by path and modification date, so a rewritten file is reloaded.
@MainActor
enum ImageFileCache {
    private static let costLimit = 24 * 1024 * 1024
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 96
        // Decoded pixels, not compressed file size, determine the retained memory.
        cache.totalCostLimit = costLimit
        return cache
    }()

    static func image(at url: URL) -> NSImage? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let pixels = image.representations.reduce(into: 0) { largest, representation in
            let width = max(representation.pixelsWide, 0)
            let height = max(representation.pixelsHigh, 0)
            let (count, overflow) = width.multipliedReportingOverflow(by: height)
            if !overflow { largest = max(largest, count) }
        }
        let (cost, overflow) = pixels.multipliedReportingOverflow(by: 4)
        // NSCache's cost limit is advisory. Do not let a single panorama or
        // screenshot exceed the entire cache budget and remain retained.
        if pixels > 0, !overflow, cost <= costLimit {
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
    nonisolated static func thumbnailData(at url: URL, maxPixelSize: Int = 256) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              ) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

enum ImageAttachmentData {
    static func png(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 65_536,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              ) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

struct DraftAttachmentThumbnail: View {
    let url: URL
    let name: String
    let icon: String

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.title3)
                    Text(name)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 64)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) {
            thumbnail = nil
            let data = await Task.detached(priority: .utility) {
                ImageFileCache.thumbnailData(at: url)
            }.value
            guard !Task.isCancelled, let data else { return }
            thumbnail = NSImage(data: data)
        }
    }
}

enum DroppedAttachment: Sendable, Equatable {
    case file(URL)
    case image(Data, typeIdentifier: String)
}

@MainActor
private final class AttachmentDropBatch {
    private var remaining: Int
    private var items: [DroppedAttachment?]
    private var finished: [Bool]
    private let onItems: @MainActor ([DroppedAttachment]) -> Void

    init(count: Int, onItems: @escaping @MainActor ([DroppedAttachment]) -> Void) {
        remaining = count
        items = Array(repeating: nil, count: count)
        finished = Array(repeating: false, count: count)
        self.onItems = onItems
    }

    func finish(_ item: DroppedAttachment?, at index: Int) {
        guard items.indices.contains(index), !finished[index] else { return }
        finished[index] = true
        items[index] = item
        remaining -= 1
        guard remaining == 0 else { return }
        let loadedItems = items.compactMap { $0 }
        if !loadedItems.isEmpty { onItems(loadedItems) }
    }
}

@MainActor
func handleAttachmentDrop(
    _ providers: [NSItemProvider],
    onItems: @escaping @MainActor ([DroppedAttachment]) -> Void
) -> Bool {
    guard !providers.isEmpty else { return false }
    let batch = AttachmentDropBatch(count: providers.count, onItems: onItems)

    for (index, provider) in providers.enumerated() {
        if provider.canLoadObject(ofClass: NSURL.self) {
            _ = provider.loadObject(ofClass: NSURL.self) { item, _ in
                let url = (item as? NSURL).map { $0 as URL }
                Task { @MainActor in batch.finish(url.map(DroppedAttachment.file), at: index) }
            }
        } else if let imageType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                let item = data.map { DroppedAttachment.image($0, typeIdentifier: imageType) }
                Task { @MainActor in batch.finish(item, at: index) }
            }
        } else {
            _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in batch.finish(url.map(DroppedAttachment.file), at: index) }
            }
        }
    }
    return true
}

@MainActor
func handleFileDrop(_ providers: [NSItemProvider], onURLs: @escaping @MainActor ([URL]) -> Void) -> Bool {
    handleAttachmentDrop(providers) { items in
        onURLs(items.compactMap { item in
            guard case let .file(url) = item else { return nil }
            return url
        })
    }
}

struct VoiceTranscriptPreview: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 15)
                .padding(.bottom, 7)
                .allowsHitTesting(false)
        }
    }
}

struct ComposerBanner<Content: View>: View {
    private let verticalPadding: CGFloat
    private let content: Content

    init(verticalPadding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, verticalPadding)
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
    }
}

/// The filled capsule for a composer banner's main action.
struct BannerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.16), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Shows a short, localized confirmation after writing text to the pasteboard.
struct CopyFeedbackButton: View {
    let text: String

    @State private var isCopied = false
    @State private var resetID = UUID()

    private var label: String {
        AppCopy.text(isCopied ? "common.copied" : "conversation.copy")
    }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                guard NSPasteboard.copy(text) else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    isCopied = true
                    resetID = UUID()
                }
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(label)
            .accessibilityLabel(label)

            if isCopied {
                Text(AppCopy.text("common.copied"))
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .task(id: resetID) {
            guard isCopied else { return }
            do {
                try await Task.sleep(for: .seconds(2.5))
            } catch {
                return
            }
            withAnimation(.easeInOut(duration: 0.16)) {
                isCopied = false
            }
        }
    }
}

extension NSPasteboard {
    /// Replaces the general pasteboard's contents with `text`.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        general.clearContents()
        return general.setString(text, forType: .string)
    }
}

/// Shows a message in the app language under the original, or hides it again.
@MainActor
func toggleTranslation(
    id: String, text: String, model: AppModel,
    translations: Binding<[String: String]>, translating: Binding<Set<String>>
) {
    if translations.wrappedValue.removeValue(forKey: id) != nil { return }
    translating.wrappedValue.insert(id)
    Task { @MainActor in
        defer { translating.wrappedValue.remove(id) }
        do {
            translations.wrappedValue[id] = try await model.translate(text)
        } catch {
            translations.wrappedValue[id] = error.localizedDescription
        }
    }
}

struct TagBadge: View {
    private let text: String
    private let background: AnyShapeStyle

    init(_ text: String, background: AnyShapeStyle = AnyShapeStyle(Color.primary.opacity(0.08))) {
        self.text = text
        self.background = background
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }
}

extension ChatAttachment.Kind {
    var systemImageName: String {
        switch self {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "video"
        case .file: return "doc"
        }
    }
}

extension View {
    /// Shows a "jump to latest" arrow at the bottom trailing edge of a chat
    /// scroll view once the reader has scrolled up from the end.
    func scrollToBottomButton(action: @escaping () -> Void) -> some View {
        modifier(ScrollToBottomButton(action: action))
    }
}

private struct ScrollToBottomButton: ViewModifier {
    let action: () -> Void
    @State private var scrolledUp = false

    func body(content: Content) -> some View {
        // ponytail: scroll geometry needs macOS 15; older systems just get no arrow.
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY > 120
                } action: { _, isScrolledUp in
                    scrolledUp = isScrolledUp
                }
                .overlay(alignment: .bottomTrailing) {
                    if scrolledUp {
                        Button(action: action) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(.regularMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(.separator))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(AppCopy.text("conversation.scrollToBottom"))
                        .accessibilityLabel(AppCopy.text("conversation.scrollToBottom"))
                        .padding(16)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: scrolledUp)
        } else {
            content
        }
    }
}
