// Copyright (c) 2026 DOTS
// System (loopback) audio capture backed by ScreenCaptureKit.

import Foundation
import CoreMedia
import ScreenCaptureKit

/// Captures the machine's audio output as a PCM stream. Uses ScreenCaptureKit's
/// audio path, which is what registers the app under macOS' "System Audio
/// Recording Only" privacy list — the first `startCapture()` triggers that TCC
/// prompt and adds the app to the list. No screen output is requested, so no
/// video frames are produced.
@available(macOS 14.0, *)
public final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias SampleHandler = @Sendable (CMSampleBuffer) -> Void
    public typealias FailureHandler = @MainActor @Sendable (Error) -> Void

    private let sampleQueue = DispatchQueue(
        label: "com.dots.dotsharness.system-audio-capture",
        qos: .userInitiated
    )
    private let sampleHandler: SampleHandler
    private let failureHandler: FailureHandler?
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var isStopping = false

    private init(sampleHandler: @escaping SampleHandler, failureHandler: FailureHandler?) {
        self.sampleHandler = sampleHandler
        self.failureHandler = failureHandler
        super.init()
    }

    /// Starts a continuous system-audio capture. `sampleHandler` is called on a
    /// background queue with interleaved PCM sample buffers.
    public static func start(
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        excludeOwnAudio: Bool = true,
        sampleHandler: @escaping SampleHandler,
        failureHandler: FailureHandler? = nil
    ) async throws -> SystemAudioCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = excludeOwnAudio
        configuration.sampleRate = sampleRate
        configuration.channelCount = channelCount
        // No screen output is added; keep the mandatory video config minimal.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let session = SystemAudioCapture(sampleHandler: sampleHandler, failureHandler: failureHandler)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: session)
        session.stream = stream

        do {
            try stream.addStreamOutput(session, type: .audio, sampleHandlerQueue: session.sampleQueue)
            try await stream.startCapture()
        } catch {
            session.stream = nil
            try? await stream.stopCapture()
            throw error
        }
        return session
    }

    public func stop() async {
        try? await takeStreamForStop()?.stopCapture()
    }

    private func takeStreamForStop() -> SCStream? {
        stateLock.lock()
        defer { stateLock.unlock() }
        isStopping = true
        let current = stream
        stream = nil
        return current
    }

    // MARK: - SCStreamOutput

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer) else { return }
        sampleHandler(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let notify = !isStopping
        stateLock.unlock()
        guard notify, let failureHandler else { return }
        Task { @MainActor in failureHandler(error) }
    }
}

public enum SystemAudioCaptureError: LocalizedError, Sendable {
    case noDisplay

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display available for system audio capture."
        }
    }
}
