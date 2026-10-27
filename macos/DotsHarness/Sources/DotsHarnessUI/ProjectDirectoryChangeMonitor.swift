// Copyright (c) 2026 DOTS
// Watches project roots for renames without polling the filesystem.

import CoreServices
import Foundation

private final class ProjectDirectoryChangeCallbackContext: @unchecked Sendable {
    let onRootChanged: @Sendable () -> Void

    init(onRootChanged: @escaping @Sendable () -> Void) {
        self.onRootChanged = onRootChanged
    }
}

@MainActor
final class ProjectDirectoryChangeMonitor {
    private let eventQueue = DispatchQueue(label: "net.dots.herness.project-directory-events", qos: .utility)
    private var stream: FSEventStreamRef?
    private var callbackContext: ProjectDirectoryChangeCallbackContext?
    private var watchedPaths: [String] = []
    private var onRootChanged: (@MainActor () -> Void)?

    func update(paths: [String], onRootChanged: (@MainActor () -> Void)? = nil) {
        if let onRootChanged {
            self.onRootChanged = onRootChanged
        }

        let fileManager = FileManager.default
        let existingDirectories = Set(paths.compactMap { path -> String? in
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return normalized
        }).sorted()

        guard existingDirectories != watchedPaths || (stream == nil && !existingDirectories.isEmpty) else {
            return
        }

        stopStream()
        watchedPaths = existingDirectories
        guard !watchedPaths.isEmpty else { return }

        let context = ProjectDirectoryChangeCallbackContext { [weak self] in
            Task { @MainActor [weak self] in
                self?.onRootChanged?()
            }
        }
        callbackContext = context

        var streamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(context).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            projectDirectoryChangeCallback,
            &streamContext,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            callbackContext = nil
            watchedPaths = []
            return
        }

        FSEventStreamSetDispatchQueue(stream, eventQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventQueue.sync {}
            callbackContext = nil
            watchedPaths = []
            return
        }
        self.stream = stream
    }

    func stop() {
        stopStream()
        onRootChanged = nil
    }

    private func stopStream() {
        guard let stream else {
            watchedPaths = []
            callbackContext = nil
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventQueue.sync {}
        self.stream = nil
        watchedPaths = []
        callbackContext = nil
    }
}

private let projectDirectoryChangeCallback: FSEventStreamCallback = { _, info, eventCount, _, eventFlags, _ in
    guard let info, eventCount > 0 else { return }
    let rootChangedFlag = UInt32(kFSEventStreamEventFlagRootChanged)
    guard (0..<eventCount).contains(where: { eventFlags[$0] & rootChangedFlag != 0 }) else { return }

    Unmanaged<ProjectDirectoryChangeCallbackContext>
        .fromOpaque(info)
        .takeUnretainedValue()
        .onRootChanged()
}
