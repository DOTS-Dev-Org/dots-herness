// Copyright (c) 2026 DOTS
// Media's Library tab: everything generated or filed.

import AppKit
import QuickLookThumbnailing
import SwiftUI
import Vision
import DotsHarnessCore

struct MediaLibraryPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var library: MediaLibraryStore
    let query: String

    /// Nil shows every kind.
    @State private var kind: MediaLibraryItem.Kind?
    @State private var error: String?
    @State private var favoritesOnly = false
    @State private var folderFilter: String?
    @State private var selectedIDs: Set<String> = []
    @State private var ocrInProgress: Set<String> = []
    @State private var newestFirst = true

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 20)]

    init(model: AppModel, query: String) {
        self.model = model
        self.library = model.mediaLibrary
        self.query = query
    }

    private var visible: [MediaLibraryItem] {
        let result = library.items.filter { item in
            (kind == nil || item.kind == kind)
                && (!favoritesOnly || item.favorite == true)
                && (folderFilter.map { (item.folder ?? "") == $0 } ?? true)
                && (query.isEmpty || [item.displayTitle, item.title, item.folder ?? "", item.ocrText ?? ""]
                    .joined(separator: " ").localizedCaseInsensitiveContains(query)
                    || (item.tags ?? []).contains(where: { $0.localizedCaseInsensitiveContains(query) }))
        }
        return result.sorted { newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt }
    }

    private var folders: [String] { Array(Set(library.items.map { $0.folder ?? "" })).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(AppCopy.text("studio.library"))
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                if !selectedIDs.isEmpty {
                    Button(action: exportSelected) { Label(AppCopy.text("library.exportSelected"), systemImage: "square.and.arrow.up") }
                    Text("\(selectedIDs.count)").foregroundStyle(.secondary)
                }
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
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $kind) {
                Text(AppCopy.text("library.all")).tag(MediaLibraryItem.Kind?.none)
                ForEach(MediaLibraryItem.Kind.allCases, id: \.self) { Text($0.title).tag(MediaLibraryItem.Kind?.some($0)) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            HStack(spacing: 8) {
                Toggle(AppCopy.text("library.favorites"), isOn: $favoritesOnly).toggleStyle(.button)
                Menu(AppCopy.text(folderFilter == nil ? "library.allFolders" : "library.folderFilter")) {
                    Button(AppCopy.text("library.allFolders")) { folderFilter = nil }
                    ForEach(folders, id: \.self) { value in
                        Button(value.isEmpty ? AppCopy.text("library.unfiled") : value) { folderFilter = value }
                    }
                }
                Button(AppCopy.text(newestFirst ? "library.sortNewest" : "library.sortOldest")) { newestFirst.toggle() }
                    .buttonStyle(.bordered)
                Button(AppCopy.text(selectedIDs.count == visible.count ? "library.deselectAll" : "library.selectAll")) {
                    selectedIDs = selectedIDs.count == visible.count ? [] : Set(visible.map(\.id))
                }.buttonStyle(.bordered)
            }
        }
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
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 7) {
                    Button { toggleFavorite(item) } label: {
                        Image(systemName: item.favorite == true ? "star.fill" : "star")
                            .foregroundStyle(item.favorite == true ? .yellow : .white)
                    }.buttonStyle(.borderedProminent).tint(.black.opacity(0.55))
                    Button { toggleSelection(item.id) } label: {
                        Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.white)
                    }.buttonStyle(.borderedProminent).tint(.black.opacity(0.55))
                }.padding(7)
            }
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
                let organization = [item.folder].compactMap { $0?.isEmpty == false ? $0 : nil } + (item.tags ?? []).map { "#\($0)" }
                if !organization.isEmpty {
                    Text(organization.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
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
            Button(AppCopy.text(item.favorite == true ? "library.unfavorite" : "library.favorite")) { toggleFavorite(item) }
            Button(AppCopy.text("library.organize")) { organize(item) }
            if item.kind == .image {
                Button(ocrInProgress.contains(item.id) ? AppCopy.text("library.ocrRunning") : AppCopy.text("library.ocrLocal")) { recognizeTextLocally(item) }
                    .disabled(ocrInProgress.contains(item.id) || !exists)
            }
            Button(selectedIDs.contains(item.id) ? AppCopy.text("library.deselect") : AppCopy.text("library.select")) { toggleSelection(item.id) }
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

    private func toggleFavorite(_ item: MediaLibraryItem) {
        library.update(item.id) { $0.favorite = !($0.favorite ?? false) }
    }

    private func toggleSelection(_ id: String) {
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }

    private func organize(_ item: MediaLibraryItem) {
        let alert = NSAlert()
        alert.messageText = AppCopy.text("library.organize")
        alert.addButton(withTitle: AppCopy.text("common.save"))
        alert.addButton(withTitle: AppCopy.text("common.cancel"))
        let folder = NSTextField(string: item.folder ?? "")
        folder.placeholderString = AppCopy.text("library.folder")
        let tags = NSTextField(string: (item.tags ?? []).joined(separator: ", "))
        tags.placeholderString = AppCopy.text("library.tags")
        let fields = NSStackView(views: [folder, tags])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 320, height: 64)
        alert.accessoryView = fields
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.update(item.id) {
            $0.folder = folder.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.tags = tags.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
    }

    private func exportSelected() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = AppCopy.text("library.exportSelected")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            _ = try library.export(selectedIDs, to: destination)
            selectedIDs.removeAll()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func recognizeTextLocally(_ item: MediaLibraryItem) {
        guard item.kind == .image else { return }
        ocrInProgress.insert(item.id)
        Task {
            do {
                let url = item.url
                let text = try await Task.detached(priority: .utility) { () throws -> String in
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    try VNImageRequestHandler(url: url, options: [:]).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                }.value
                library.update(item.id) { $0.ocrText = text }
                ocrInProgress.remove(item.id)
            } catch {
                ocrInProgress.remove(item.id)
                self.error = error.localizedDescription
            }
        }
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
