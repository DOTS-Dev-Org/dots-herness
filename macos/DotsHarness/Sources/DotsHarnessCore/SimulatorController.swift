// Copyright (c) 2026 DOTS
// Live state for the iOS simulator panel: device list, screen stream, input.

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import IOSurface

/// A frame ready for display. The live path carries an IOSurface-backed
/// `CVPixelBuffer` handed straight to a `CALayer` (no copy, no render); the
/// screenshot fallback carries a `CGImage`. `cropRect` is normalized with a
/// top-left origin and describes the device screen inside the captured area.
public struct SimulatorDisplayFrame: @unchecked Sendable {
    public enum Source {
        case buffer(CVPixelBuffer)
        case image(CGImage)
    }

    public let source: Source
    public let fullPixelSize: CGSize
    public let cropRect: CGRect

    public init(source: Source, fullPixelSize: CGSize, cropRect: CGRect) {
        self.source = source
        self.fullPixelSize = fullPixelSize
        self.cropRect = cropRect
    }

    /// Cropped device-screen size in pixels — used for pointer mapping and the
    /// panel's aspect ratio.
    public var displayPixelSize: CGSize {
        CGSize(
            width: max(fullPixelSize.width * cropRect.width, 1),
            height: max(fullPixelSize.height * cropRect.height, 1)
        )
    }

    /// `CALayer.contents` value: an IOSurface for the live path, a CGImage for
    /// the fallback. Both are valid layer contents.
    public var layerContents: Any? {
        switch source {
        case let .buffer(pixelBuffer):
            // ponytail: hands back the pooled surface; the frame store keeps the
            // CVPixelBuffer alive until the next frame replaces it. At queueDepth
            // 3 that is enough to avoid the layer reading a recycled surface.
            guard let surface = CVPixelBufferGetIOSurface(pixelBuffer) else { return nil }
            return surface.takeUnretainedValue() as IOSurface
        case let .image(image):
            return image
        }
    }

    /// `CALayer.contentsRect`: unit rect with a bottom-left origin (CoreAnimation
    /// convention), converted from the top-left `cropRect`.
    public var contentsRect: CGRect {
        CGRect(
            x: cropRect.minX,
            y: max(0, 1 - cropRect.minY - cropRect.height),
            width: cropRect.width,
            height: cropRect.height
        )
    }
}

/// High-frequency frame state lives outside `SimulatorController` so the
/// complete simulator panel does not recompute its SwiftUI body for every
/// captured frame.
@MainActor
public final class SimulatorFrameStore: ObservableObject {
    @Published public private(set) var frame: SimulatorDisplayFrame?

    public init() {}

    public func set(_ frame: SimulatorDisplayFrame) {
        self.frame = frame
    }

    public func clear() {
        frame = nil
    }
}

@MainActor
public final class SimulatorController: ObservableObject {
    public enum CaptureRate: Int, CaseIterable, Identifiable, Sendable {
        case one = 1, two = 2, four = 4, eight = 8
        case fifteen = 15, thirty = 30, sixty = 60
        public var id: Int { rawValue }
        public var title: String { "\(rawValue) FPS" }
    }

    /// Kept as a source-compatible name for callers that used the old polling
    /// terminology. New UI should use CaptureRate.
    public typealias FrameRate = CaptureRate

    public enum CaptureLatency: String, CaseIterable, Identifiable, Sendable {
        case low
        case balanced
        case smooth

        public var id: String { rawValue }
        public var titleKey: String { "simulator.latency.\(rawValue)" }

        /// ScreenCaptureKit's queue is the main built-in latency/performance
        /// trade-off. The frame delivery layer also drops stale frames.
        public var queueDepth: Int {
            switch self {
            // Apple documents three frames as ScreenCaptureKit's minimum
            // queue depth. Keep low latency at that floor instead of asking
            // the framework for an unsupported smaller buffer.
            case .low: return 3
            case .balanced: return 4
            case .smooth: return 6
            }
        }
    }

    public enum CaptureQuality: String, CaseIterable, Identifiable, Sendable {
        case performance
        case balanced
        case high

        public var id: String { rawValue }
        public var titleKey: String { "simulator.quality.\(rawValue)" }

        /// Output scale relative to the Simulator window's native pixel size.
        /// The ScreenCaptureKit session additionally selects its capture
        /// resolution preset for the chosen quality.
        public var outputScale: Double {
            switch self {
            case .performance: return 0.5
            case .balanced: return 0.75
            case .high: return 1.0
            }
        }
    }

    public enum CaptureBackend: String, Identifiable, Sendable {
        case screenCaptureKit
        case simctlFallback

        public var id: String { rawValue }
        public var titleKey: String {
            switch self {
            case .screenCaptureKit: return "simulator.capture.live"
            case .simctlFallback: return "simulator.capture.fallback"
            }
        }
    }

    @Published public private(set) var devices: [SimulatorDevice] = []
    public let frameStore = SimulatorFrameStore()
    @Published public private(set) var isStreaming = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var status: String = ""
    @Published public private(set) var captureBackend: CaptureBackend = .screenCaptureKit
    @Published public var captureRate: CaptureRate = .thirty {
        didSet {
            UserDefaults.standard.set(captureRate.rawValue, forKey: Self.captureRateKey)
            restartStreamIfNeeded()
        }
    }
    @Published public var captureLatency: CaptureLatency = .low {
        didSet {
            UserDefaults.standard.set(captureLatency.rawValue, forKey: Self.captureLatencyKey)
            restartStreamIfNeeded()
        }
    }
    @Published public var captureQuality: CaptureQuality = .balanced {
        didSet {
            UserDefaults.standard.set(captureQuality.rawValue, forKey: Self.captureQualityKey)
            restartStreamIfNeeded()
        }
    }
    @Published public var selectedDeviceID: String? {
        didSet {
            guard selectedDeviceID != oldValue else { return }
            frameStore.clear()
            hidInput = nil
            hidInputDeviceID = nil
            if selectedDevice?.isBooted == true {
                restartStreamIfNeeded()
            } else {
                stopStream()
            }
        }
    }

    private static let captureRateKey = "dots.simulator.captureRate"
    private static let captureLatencyKey = "dots.simulator.captureLatency"
    private static let captureQualityKey = "dots.simulator.captureQuality"

    private var fallbackTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var liveCapture: SimulatorScreenCapture?
    private var streamToken = UUID()
    private var captureScreenRect: CGRect?
    private var hidInput: SimulatorHIDInput?
    private var hidInputDeviceID: String?

    public init() {
        let defaults = UserDefaults.standard
        let storedRate = defaults.object(forKey: Self.captureRateKey) as? Int
        let storedLatency = defaults.string(forKey: Self.captureLatencyKey)
        let storedQuality = defaults.string(forKey: Self.captureQualityKey)

        captureRate = CaptureRate(rawValue: storedRate ?? CaptureRate.thirty.rawValue) ?? .thirty
        captureLatency = CaptureLatency(rawValue: storedLatency ?? CaptureLatency.low.rawValue) ?? .low
        captureQuality = CaptureQuality(rawValue: storedQuality ?? CaptureQuality.balanced.rawValue) ?? .balanced
    }

    public var selectedDevice: SimulatorDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    public var isSelectedDeviceBooted: Bool { selectedDevice?.isBooted == true }

    /// Screen-event injection needs the Accessibility permission.
    public var isInputTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - Devices

    public func refreshDevices() async {
        do {
            let list = try await background { try SimulatorService.devices() }
            devices = list
            if selectedDeviceID == nil || !list.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = list.first(where: \.isBooted)?.id ?? list.first?.id
            }
            if status.isEmpty { status = AppCopy.format("simulator.deviceCount", list.count) }
        } catch {
            report(error)
        }
    }

    public func boot() async {
        guard let udid = selectedDeviceID else { return }
        hidInput = nil
        hidInputDeviceID = nil
        await perform("simulator.booting") { try SimulatorService.boot(udid) }
        await refreshDevices()
        guard isSelectedDeviceBooted else { return }
        await relocateSimulatorWindowOffscreen()
        stopStream()
        startStream()
    }

    public func shutdown() async {
        guard let udid = selectedDeviceID else { return }
        hidInput = nil
        hidInputDeviceID = nil
        stopStream()
        await perform("simulator.shuttingDown") { try SimulatorService.shutdown(udid) }
        frameStore.clear()
        await refreshDevices()
    }

    // MARK: - Stream

    public func startStream() {
        guard let udid = selectedDeviceID,
              !isStreaming,
              startupTask == nil,
              fallbackTask == nil,
              liveCapture == nil else { return }

        let token = UUID()
        streamToken = token
        isStreaming = true
        captureScreenRect = nil
        captureBackend = .screenCaptureKit

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startPreferredStream(for: udid, token: token)
            if self.streamToken == token {
                self.startupTask = nil
            }
        }
    }

    public func stopStream() {
        streamToken = UUID()
        startupTask?.cancel()
        startupTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil

        let capture = liveCapture
        liveCapture = nil
        if let capture {
            Task { await capture.stop() }
        }

        isStreaming = false
        captureScreenRect = nil
    }

    public func toggleStream() {
        isStreaming ? stopStream() : startStream()
    }

    private func restartStreamIfNeeded() {
        guard isStreaming else { return }
        stopStream()
        startStream()
    }

    private func startPreferredStream(for udid: String, token: UUID) async {
        await relocateSimulatorWindowOffscreen()
        guard isCurrentStream(token) else { return }

        guard let processID = simulatorProcessIdentifier() else {
            startFallbackStream(for: udid, token: token, cause: SimulatorCaptureError.windowNotFound)
            return
        }

        let deviceName = selectedDevice?.name
        let rate = captureRate
        let latency = captureLatency
        let quality = captureQuality
        let displayAspectRatio: CGFloat?
        if let value = try? await background({ try SimulatorService.displayAspectRatio(udid) }), value > 0 {
            displayAspectRatio = CGFloat(value)
        } else {
            displayAspectRatio = nil
        }

        do {
            let capture = try await SimulatorScreenCapture.start(
                processID: processID,
                deviceName: deviceName,
                rate: rate,
                latency: latency,
                quality: quality,
                displayAspectRatio: displayAspectRatio,
                frameHandler: { @MainActor [weak self] frame in
                    guard let self,
                          self.isCurrentStream(token),
                          self.captureBackend == .screenCaptureKit else { return }
                    self.acceptFrame(frame)
                },
                geometryHandler: { @MainActor [weak self] normalizedRect in
                    guard let self,
                          self.isCurrentStream(token),
                          self.captureBackend == .screenCaptureKit else { return }
                    self.captureScreenRect = normalizedRect
                },
                failureHandler: { @MainActor [weak self] error in
                    self?.handleLiveCaptureFailure(error, for: udid, token: token)
                }
            )

            guard isCurrentStream(token) else {
                await capture.stop()
                return
            }
            liveCapture = capture
            captureBackend = .screenCaptureKit
        } catch {
            guard isCurrentStream(token) else { return }
            startFallbackStream(for: udid, token: token, cause: error)
        }
    }

    private func startFallbackStream(for udid: String, token: UUID, cause: Error?) {
        guard isCurrentStream(token) else { return }

        let capture = liveCapture
        liveCapture = nil
        if let capture {
            Task { await capture.stop() }
        }

        captureBackend = .simctlFallback
        captureScreenRect = nil
        if let cause {
            NSLog("[Simulator] ScreenCaptureKit unavailable, using screenshot fallback: %@", cause.localizedDescription)
            status = AppCopy.format("simulator.capture.fallbackMessage", cause.localizedDescription)
        }

        fallbackTask?.cancel()
        fallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isCurrentStream(token) {
                // A screenshot is a one-shot subprocess, so asking it for 15+
                // FPS only increases CPU/process churn without producing more
                // frames. Keep the fallback bounded while preserving the user's
                // selected target for the ScreenCaptureKit path.
                let effectiveRate = min(max(self.captureRate.rawValue, 1), 8)
                let interval = 1.0 / Double(effectiveRate)
                let started = Date()
                do {
                    let data = try await self.background { try SimulatorService.screenshot(udid) }
                    guard !Task.isCancelled, self.isCurrentStream(token) else { return }
                    if let image = Self.decodeImage(data) {
                        self.acceptFrame(SimulatorDisplayFrame(
                            source: .image(image),
                            fullPixelSize: CGSize(width: image.width, height: image.height),
                            cropRect: CGRect(x: 0, y: 0, width: 1, height: 1)
                        ))
                    }
                } catch {
                    guard !Task.isCancelled, self.isCurrentStream(token) else { return }
                    self.reportStreamFailure(error)
                    return
                }

                let elapsed = Date().timeIntervalSince(started)
                if elapsed < interval {
                    try? await Task.sleep(for: .seconds(interval - elapsed))
                }
            }
        }
    }

    private func handleLiveCaptureFailure(_ error: Error, for udid: String, token: UUID) {
        guard isCurrentStream(token), captureBackend == .screenCaptureKit else { return }
        startFallbackStream(for: udid, token: token, cause: error)
    }

    private func isCurrentStream(_ token: UUID) -> Bool {
        isStreaming && streamToken == token
    }

    private func acceptFrame(_ frame: SimulatorDisplayFrame) {
        frameStore.set(frame)
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func reportStreamFailure(_ error: Error) {
        stopStream()
        report(error)
    }

    // MARK: - Actions

    public func openURL(_ url: String) async {
        guard let udid = selectedDeviceID else { return }
        await perform("simulator.openingURL") { try SimulatorService.openURL(udid, url: url) }
    }

    public func installAndLaunch(appPath: String) async {
        guard let udid = selectedDeviceID else { return }
        await perform("simulator.installing") {
            try SimulatorService.install(udid, appPath: appPath)
            guard let plist = NSDictionary(contentsOfFile: appPath + "/Info.plist"),
                  let bundleID = plist["CFBundleIdentifier"] as? String else {
                throw SimulatorError(AppCopy.format("simulator.appNotFound", appPath + "/Info.plist"))
            }
            _ = try SimulatorService.launch(udid, bundleID: bundleID)
        }
        startStream()
    }

    public func setAppearance(dark: Bool) async {
        guard let udid = selectedDeviceID else { return }
        await perform("simulator.appearance") { try SimulatorService.setAppearance(udid, dark: dark) }
    }

    public func saveScreenshot(to directory: URL) async -> URL? {
        guard let udid = selectedDeviceID else { return nil }
        do {
            let data = try await background { try SimulatorService.screenshot(udid) }
            let name = "simulator-\(Int(Date().timeIntervalSince1970)).png"
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            status = AppCopy.format("simulator.savedScreenshot", url.path)
            return url
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: - Input
    //
    // `simctl` has no tap/swipe verb. Semantic Accessibility presses remain a
    // useful fast path for taps. Gestures use SimulatorKit's HID channel so
    // they are delivered as touches without moving the macOS cursor or
    // activating the standalone Simulator window.

    private static let offscreenOrigin = CGPoint(x: -8000, y: 80)

    /// - Parameter point: position inside the streamed frame, in image points.
    public func tap(at point: CGPoint) {
        guard let imageSize = frameStore.frame?.displayPixelSize else { return }
        if isInputTrusted,
           let screenPoint = screenPoint(for: point, imageSize: imageSize),
           pressSimulatorElement(at: screenPoint) {
            return
        }

        guard let udid = selectedDeviceID,
              let input = hidInput(for: udid),
              input.tap(at: point, size: imageSize) else {
            if !isInputTrusted {
                status = AppCopy.text("simulator.accessibilityRequired")
                requestAccessibilityPermission()
            } else {
                status = AppCopy.text("simulator.inputFailed")
            }
            return
        }
    }

    public func swipe(from start: CGPoint, to end: CGPoint) {
        guard let imageSize = frameStore.frame?.displayPixelSize,
              let udid = selectedDeviceID,
              let input = hidInput(for: udid),
              input.swipe(from: start, to: end, size: imageSize) else {
            status = AppCopy.text("simulator.inputFailed")
            return
        }
    }

    private func hidInput(for udid: String) -> SimulatorHIDInput? {
        if let hidInput, hidInputDeviceID == udid {
            return hidInput
        }
        let input = SimulatorHIDInput(udid: udid)
        hidInput = input
        hidInputDeviceID = udid
        return input
    }

    public func pressHome() {
        if !pressSimulatorAction(description: "Home") {
            pressKey(keyCode: 0x04, flags: [.maskCommand, .maskShift])
        }
    }

    public func pressLock() {
        if !pressSimulatorAction(description: "Sleep/Wake") {
            pressKey(keyCode: 0x25, flags: [.maskCommand])
        }
    }

    /// Ask the Simulator's AX tree to press the deepest element at a screen
    /// coordinate. Simulator exposes native iOS controls through this tree,
    /// and AXPress is delivered without changing the active macOS app.
    ///
    /// The system-wide hit-test API does not reliably see a window which has
    /// been moved outside the visible desktop. Walk the Simulator tree as a
    /// fallback and compare the elements' own global AX frames instead. This
    /// keeps the embedded panel usable while the real Simulator window stays
    /// out of the way.
    private func pressSimulatorElement(at point: CGPoint) -> Bool {
        guard let pid = simulatorProcessIdentifier() else { return false }

        let app = AXUIElementCreateApplication(pid)
        if let element = findPressableAXElement(at: point, in: app, depth: 0),
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }

        var element: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return false }
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func findPressableAXElement(
        at point: CGPoint,
        in element: AXUIElement,
        depth: Int
    ) -> AXUIElement? {
        guard depth < 32 else { return nil }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        // AX children are usually front-to-back. Search in reverse so an
        // overlapping leaf control wins over its containing groups.
        for child in children.reversed() {
            guard let frame = axFrame(of: child), frame.contains(point) else { continue }
            if let descendant = findPressableAXElement(at: point, in: child, depth: depth + 1) {
                return descendant
            }
            if axSupportsPress(child) {
                return child
            }
        }
        return nil
    }

    private func axSupportsPress(_ element: AXUIElement) -> Bool {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Find and press a named hardware/toolbar control in the Simulator AX
    /// tree. The description is stable across localized macOS UI labels.
    private func pressSimulatorAction(description: String) -> Bool {
        guard let pid = simulatorProcessIdentifier() else { return false }
        let app = AXUIElementCreateApplication(pid)
        guard let element = findAXElement(app, description: description, depth: 0) else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func findAXElement(_ element: AXUIElement, description: String, depth: Int) -> AXUIElement? {
        guard depth < 20 else { return nil }

        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let value = value as? String,
               value.caseInsensitiveCompare(description) == .orderedSame {
                return element
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let match = findAXElement(child, description: description, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    private func pressKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard isInputTrusted else {
            status = AppCopy.text("simulator.accessibilityRequired")
            requestAccessibilityPermission()
            return
        }
        guard let simulatorPID = simulatorProcessIdentifier() else {
            status = AppCopy.text("simulator.windowNotFound")
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
            event?.flags = flags
            post(event, to: simulatorPID)
        }
    }

    /// Keep the target explicit as well as using `postToPid`. Newer versions
    /// of WindowServer use this field when routing synthetic events to an
    /// inactive process.
    private func post(_ event: CGEvent?, to pid: pid_t) {
        guard let event else { return }
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.postToPid(pid)
    }

    private func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Keeps the standalone Simulator window out of the user's workspace while
    /// its framebuffer is shown in this panel. Input is routed directly to the
    /// Simulator process, so it no longer relies on this relocation to avoid
    /// activating or moving to the real Simulator window.
    /// Retries briefly: right after `boot`, the window may not exist yet.
    public func relocateSimulatorWindowOffscreen() async {
        guard isInputTrusted else { return }
        for _ in 0..<10 {
            if let window = simulatorAXWindow() {
                var target = Self.offscreenOrigin
                if let value = AXValueCreate(.cgPoint, &target) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func simulatorProcessIdentifier() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
            .first?
            .processIdentifier
    }

    private func simulatorAXWindow() -> AXUIElement? {
        guard let pid = simulatorProcessIdentifier() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        return windows.first { window in
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return false }
            var size = CGSize.zero
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            return size.width > 100 && size.height > 100
        } ?? windows.first
    }

    /// Maps a point in the streamed frame onto global screen coordinates by
    /// aspect-fitting the device screen inside the Simulator window content,
    /// wherever that window currently is (including offscreen).
    private func screenPoint(for point: CGPoint, imageSize: CGSize) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0, let window = simulatorWindowFrame() else { return nil }

        if let screenRect = captureScreenRect {
            let normalizedX = min(max(point.x / imageSize.width, 0), 1)
            let normalizedY = min(max(point.y / imageSize.height, 0), 1)
            return CGPoint(
                x: window.minX + (screenRect.minX + normalizedX * screenRect.width) * window.width,
                y: window.minY + (screenRect.minY + normalizedY * screenRect.height) * window.height
            )
        }

        let titleBar: CGFloat = 28
        let content = CGRect(
            x: window.minX,
            y: window.minY + titleBar,
            width: window.width,
            height: max(window.height - titleBar, 1)
        )
        let scale = min(content.width / imageSize.width, content.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let originX = content.minX + (content.width - fitted.width) / 2
        let originY = content.minY + (content.height - fitted.height) / 2
        return CGPoint(x: originX + point.x * scale, y: originY + point.y * scale)
    }

    /// Simulator window bounds in global (top-left origin) screen coordinates,
    /// read via Accessibility so an offscreen window is still found (unlike
    /// CGWindowList's onScreenOnly filter).
    private func simulatorWindowFrame() -> CGRect? {
        guard let window = simulatorAXWindow() else { return nil }
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 100, size.height > 100 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Plumbing

    private func perform(_ statusKey: String, _ work: @escaping @Sendable () throws -> Void) async {
        isBusy = true
        status = AppCopy.text(statusKey)
        do {
            try await background(work)
            status = AppCopy.text("simulator.done")
        } catch {
            report(error)
        }
        isBusy = false
    }

    private func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private func report(_ error: Error) {
        status = AppCopy.format("simulator.error", error.localizedDescription)
    }
}
