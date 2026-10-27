// Copyright (c) 2026 DOTS
// Media's Library tab: everything generated or filed.

import AppKit
import QuickLookThumbnailing
import SwiftUI
import DotsHarnessCore

struct MediaLibraryPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var library: MediaLibraryStore
    let query: String

    /// Nil shows every kind.
    @State private var kind: MediaLibraryItem.Kind?
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 20)]

    init(model: AppModel, query: String) {
        self.model = model
        self.library = model.mediaLibrary
        self.query = query
    }

    private var visible: [MediaLibraryItem] {
        library.items.filter { item in
            (kind == nil || item.kind == kind)
                && (query.isEmpty || item.displayTitle.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(AppCopy.text("studio.library"))
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                Button(action: addFiles) { Label(AppCopy.text("library.add"), systemImage: "plus") }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    kindBar
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                    if visible.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(visible) { card($0) }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            }
            return true
        }
    }

    private var kindBar: some View {
        Picker("", selection: $kind) {
            Text(AppCopy.text("library.all")).tag(MediaLibraryItem.Kind?.none)
            ForEach(MediaLibraryItem.Kind.allCases, id: \.self) { Text($0.title).tag(MediaLibraryItem.Kind?.some($0)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(AppCopy.text("library.empty.title")).font(.headline)
            Text(AppCopy.text("library.empty.detail"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func card(_ item: MediaLibraryItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let exists = FileManager.default.fileExists(atPath: item.path)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black.opacity(0.18)
                if !exists {
                    Label(AppCopy.text("media.fileMissing"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if item.kind == .audio || item.kind == .music {
                    InlineAudioPlayer(url: item.url).padding(.horizontal, 14)
                } else {
                    Button { NSWorkspace.shared.open(item.url) } label: { thumbnail(item) }
                        .buttonStyle(.plain)
                }
            }
            .frame(height: 150)
            .clipped()
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Label(
                    "\(item.kind.title) · \(item.createdAt.formatted(.relative(presentation: .named)))",
                    systemImage: item.kind.systemImage
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.12)))
        .help(item.title)
        .contextMenu {
            Button(AppCopy.text("library.open")) { NSWorkspace.shared.open(item.url) }.disabled(!exists)
            Button(AppCopy.text("media.showInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            .disabled(!exists)
            Divider()
            Button(AppCopy.text("common.remove"), role: .destructive) { library.remove(item.id) }
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: MediaLibraryItem) -> some View {
        if item.kind == .image, let image = ImageFileCache.image(at: item.url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            QuickLookThumbnail(url: item.url)
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        let failed = library.add(urls)
        error = failed == 0 ? nil : AppCopy.format("library.addFailed", failed)
    }
}

/// Poster frame for videos, first page for documents (Quick Look); the Finder
/// icon until it renders or when Quick Look has no generator for the type.
private struct QuickLookThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 320, height: 240), scale: displayScale, representationTypes: .thumbnail
            )
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}
