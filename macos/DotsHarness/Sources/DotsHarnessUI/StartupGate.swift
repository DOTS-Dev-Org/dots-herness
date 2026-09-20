// Copyright (c) 2026 DOTS
// Lets the first frame reach the screen before the heavy lists are built.

import AppKit
import QuartzCore
import SwiftUI

/// The window used to appear only after SwiftUI had also built every sidebar row and
/// every message bubble. Those are built one step later instead: the chrome, the
/// composer and the empty transcript are on screen first, and the lists follow as
/// soon as that frame has been committed. Nothing is skipped, only ordered.
@MainActor
public final class StartupGate: ObservableObject {
    public static let shared = StartupGate()
    private static let processStartTime = ProcessInfo.processInfo.systemUptime

    @Published public private(set) var isOpen = false
    public private(set) var startupDurationMs: Double = 0
    private var scheduled = false

    private init() {}

    /// Call once the first frame's views exist (the window's `onAppear`).
    public func openAfterFirstFrame() {
        guard !scheduled else { return }
        scheduled = true
        // The completion block runs when the transaction holding the first frame has
        // been committed; the dispatch queue covers immediately on the next frame tick.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in self?.open() }
        }
        CATransaction.commit()
        DispatchQueue.main.async { [weak self] in
            self?.open()
        }
    }

    private func open() {
        guard !isOpen else { return }
        isOpen = true
        startupDurationMs = (ProcessInfo.processInfo.systemUptime - Self.processStartTime) * 1000
        print("[StartupMetric] Full UI interactive in \(Int(startupDurationMs)) ms")
    }
}
