// Copyright (c) 2026 DOTS
// Library: one index of everything the app generated or the user filed in it —
// images, videos, speech, music and documents.

import Foundation
import UniformTypeIdentifiers

public struct MediaLibraryItem: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case image, video, audio, music, document

        public var title: String { AppCopy.text("library.kind.\(rawValue)") }

        public var systemImage: String {
            switch self {
            case .image: return "photo"
            case .video: return "video"
            case .audio: return "waveform"
            case .music: return "music.note"
            case .document: return "doc"
            }
        }

        /// What a file the user adds is filed as. Anything that is not media is a document.
        public init(file: URL) {
            let type = UTType(filenameExtension: file.pathExtension)
            if type?.conforms(to: .image) == true {
                self = .image
            } else if type?.conforms(to: .movie) == true {
                self = .video
            } else if type?.conforms(to: .audio) == true {
                self = .audio
            } else {
                self = .document
            }
        }
    }

    public var id: String
    public var kind: Kind
    /// The prompt that made it, or the name of the file it was added from. May be empty.
    public var title: String
    public var path: String
    public var createdAt: Date

    public var url: URL { URL(fileURLWithPath: path) }
    public var displayTitle: String { title.isEmpty ? kind.title : title }
}

/// The index on disk. Callable from any thread, so generation can file its output
/// without going through the main-actor store.
public enum MediaLibrary {
    public static let didChange = Notification.Name("DotsHarness.MediaLibrary.didChange")

    private static let lock = NSLock()

    static func directory(_ root: URL) -> URL { root.appendingPathComponent("library", isDirectory: true) }
    private static func index(_ root: URL) -> URL { directory(root).appendingPathComponent("index.json") }
    /// Copies of files the user added. Generated media stays where generation wrote it.
    private static func files(_ root: URL) -> URL { directory(root).appendingPathComponent("files", isDirectory: true) }

    /// Newest first.
    public static func items(root: URL) -> [MediaLibraryItem] {
        lock.lock()
        defer { lock.unlock() }
        return read(root)
    }

    /// Files `file` under `kind`. A path already in the library keeps its entry.
    @discardableResult
    public static func record(_ file: URL, kind: MediaLibraryItem.Kind, prompt: String? = nil, root: URL) -> MediaLibraryItem {
        mutate(root) { items in
            if let existing = items.first(where: { $0.path == file.path }) { return existing }
            let line = prompt?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let item = MediaLibraryItem(
                id: UUID().uuidString,
                kind: kind,
                title: String(line.trimmingCharacters(in: .whitespaces).prefix(80)),
                path: file.path,
                createdAt: Date()
            )
            items.insert(item, at: 0)
            return item
        }
    }

    /// Copies a file into the library so the entry never depends on where it came from.
    @discardableResult
    public static func importFile(_ source: URL, root: URL) throws -> MediaLibraryItem {
        let folder = files(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()
        let copy = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: copy)
        return record(copy, kind: MediaLibraryItem.Kind(file: source), prompt: source.lastPathComponent, root: root)
    }

    /// Drops the entry. Only the library's own copy is deleted from disk: a generated
    /// file is still shown by the conversation or project that made it.
    public static func remove(_ id: String, root: URL) {
        mutate(root) { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            let item = items.remove(at: index)
            if item.path.hasPrefix(files(root).path + "/") {
                try? FileManager.default.removeItem(at: item.url)
            }
        }
    }

    // ponytail: one JSON file rewritten per change; move to SQLite when a library reaches tens of thousands of items.
    private static func mutate<Result>(_ root: URL, _ change: (inout [MediaLibraryItem]) -> Result) -> Result {
        lock.lock()
        let before = read(root)
        var items = before
        let result = change(&items)
        if items != before {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try? FileManager.default.createDirectory(at: directory(root), withIntermediateDirectories: true)
            try? encoder.encode(items).write(to: index(root), options: .atomic)
        }
        lock.unlock()
        if items != before {
            DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
        }
        return result
    }

    private static func read(_ root: URL) -> [MediaLibraryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: index(root)) else { return [] }
        return (try? decoder.decode([MediaLibraryItem].self, from: data)) ?? []
    }
}

/// The library as the views see it.
@MainActor
public final class MediaLibraryStore: ObservableObject {
    @Published public private(set) var items: [MediaLibraryItem] = []

    private let root: URL

    public init(root: URL) {
        self.root = root
        items = MediaLibrary.items(root: root)
        // Never removed: the store lives as long as the app, and the block holds it weakly.
        _ = NotificationCenter.default.addObserver(
            forName: MediaLibrary.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.items = MediaLibrary.items(root: self.root)
            }
        }
    }

    /// Returns how many of `urls` could not be copied in.
    @discardableResult
    public func add(_ urls: [URL]) -> Int {
        urls.filter { (try? MediaLibrary.importFile($0, root: root)) == nil }.count
    }

    public func remove(_ id: String) {
        MediaLibrary.remove(id, root: root)
    }
}
