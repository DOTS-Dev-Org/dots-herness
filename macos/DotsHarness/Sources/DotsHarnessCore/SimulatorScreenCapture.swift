// Copyright (c) 2026 DOTS
// Continuous Simulator.app window capture backed by ScreenCaptureKit.

import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import ScreenCaptureKit

/// A low-latency, single-window capture session for the standalone Simulator app.
///
/// ScreenCaptureKit delivers IOSurface-backed sample buffers on a private queue.
/// The device-screen crop is detected from the first frame, then pushed back into
/// the stream as `sourceRect`, so later buffers are already the bare screen and go
/// to the panel's `CALayer` as-is (zero copy): no per-frame `CIContext` render.
@available(macOS 14.0, *)
public final class SimulatorScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias FrameHandler = @MainActor @Sendable (SimulatorDisplayFrame) -> Void
    public typealias GeometryHandler = @MainActor @Sendable (CGRect) -> Void
    public typealias FailureHandler = @MainActor @Sendable (Error) -> Void

    /// Longest captured edge, in pixels. A ~600pt retina panel needs no more
    /// than this; capturing a full native Simulator window (often 2500px+) was
    /// the dominant cost. ScreenCaptureKit downscales in its own compositor.
    private static let maxCapturedEdge = 1600.0

    private let outputQueue = DispatchQueue(
        label: "com.dots.dotsharness.simulator.screen-capture",
        qos: .userInteractive
    )
    private let frameDelivery: LatestFrameDelivery
    private let stateLock = NSLock()
    private let displayAspectRatio: CGFloat?
    private let geometryHandler: GeometryHandler
    private let renderContext: CIContext
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var failureHandler: FailureHandler?
    private var isStopping = false
    private var screenCropPixels: CGRect?
    /// Output size once the stream crops to the screen itself; buffers of this
    /// size skip the CGImage path.
    private var croppedOutputSize: CGSize?
    private var windowPointSize: CGSize = .zero

    private init(
        displayAspectRatio: CGFloat?,
        frameHandler: @escaping FrameHandler,
        geometryHandler: @escaping GeometryHandler,
        failureHandler: @escaping FailureHandler
    ) {
        self.displayAspectRatio = displayAspectRatio
        renderContext = CIContext(options: [CIContextOption.cacheIntermediates: false])
        frameDelivery = LatestFrameDelivery(handler: frameHandler)
        self.geometryHandler = geometryHandler
        self.failureHandler = failureHandler
        super.init()
    }

    /// Locates the selected Simulator window and starts a continuous capture.
    public static func start(
        processID: pid_t,
        deviceName: String?,
        rate: SimulatorController.CaptureRate,
        latency: SimulatorController.CaptureLatency,
        quality: SimulatorController.CaptureQuality,
        displayAspectRatio: CGFloat?,
        screenFillsWindowWidth: Bool = false,
        frameHandler: @escaping FrameHandler,
        geometryHandler: @escaping GeometryHandler,
        failureHandler: @escaping FailureHandler
    ) async throws -> SimulatorScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        let candidates = content.windows.filter { window in
            guard window.owningApplication?.processID == processID else { return false }
            return window.frame.width > 100 && window.frame.height > 100
        }

        let selectedWindow = candidates.first { window in
            guard let title = window.title, let deviceName else { return false }
            return title == deviceName || title.localizedCaseInsensitiveContains(deviceName)
        } ?? candidates.first(where: \.isActive) ?? candidates.first

        guard let selectedWindow else {
            throw SimulatorCaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: selectedWindow)
        let info = SCShareableContent.info(for: filter)
        let pointPixelScale = max(CGFloat(info.pointPixelScale), 1)
        let scale = quality.outputScale
        // The Android emulator window is a title bar over the bare display, so its
        // screen is known up front: no detection, every frame is zero copy.
        var fixedCrop: CGRect?
        if screenFillsWindowWidth, let aspect = displayAspectRatio, aspect > 0 {
            let window = selectedWindow.frame.size
            let height = min(window.width / aspect, window.height)
            fixedCrop = CGRect(x: 0, y: (window.height - height) / window.height, width: 1, height: height / window.height)
        }
        let capturedPoints = fixedCrop.map {
            CGSize(width: selectedWindow.frame.width * $0.width, height: selectedWindow.frame.height * $0.height)
        } ?? selectedWindow.frame.size
        var targetWidth = Double(capturedPoints.width * pointPixelScale) * scale
        var targetHeight = Double(capturedPoints.height * pointPixelScale) * scale
        let longestEdge = max(targetWidth, targetHeight)
        if longestEdge > maxCapturedEdge {
            let clamp = maxCapturedEdge / longestEdge
            targetWidth *= clamp
            targetHeight *= clamp
        }
        let width = max(2, Int(targetWidth.rounded()))
        let height = max(2, Int(targetHeight.rounded()))

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(rate.rawValue, 1))
        )
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Skip color matching: the panel just shows the framebuffer.
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureResolution = quality.captureResolution
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.queueDepth = latency.queueDepth
        configuration.showsCursor = false
        configuration.shouldBeOpaque = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        if let fixedCrop {
            configuration.sourceRect = CGRect(
                x: 0,
                y: fixedCrop.minY * selectedWindow.frame.height,
                width: capturedPoints.width,
                height: capturedPoints.height
            )
        }

        let session = SimulatorScreenCapture(
            displayAspectRatio: displayAspectRatio,
            frameHandler: frameHandler,
            geometryHandler: geometryHandler,
            failureHandler: failureHandler
        )
        session.windowPointSize = selectedWindow.frame.size
        session.configuration = configuration
        if let fixedCrop {
            session.screenCropPixels = .zero
            session.croppedOutputSize = CGSize(width: width, height: height)
            Task { @MainActor in geometryHandler(fixedCrop) }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: session)
        session.stream = stream

        do {
            try stream.addStreamOutput(
                session,
                type: .screen,
                sampleHandlerQueue: session.outputQueue
            )
            try await stream.startCapture()
        } catch {
            session.stream = nil
            try? await stream.stopCapture()
            throw error
        }

        return session
    }

    public func stop() async {
        markStopping()
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              isCompleteFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        process(pixelBuffer)
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard shouldNotifyFailure() else { return }
        let handler = failureHandler
        Task { @MainActor in
            handler?(error)
        }
    }

    private func markStopping() {
        stateLock.lock()
        isStopping = true
        stateLock.unlock()
    }

    private func shouldNotifyFailure() -> Bool {
        stateLock.lock()
        let shouldNotify = !isStopping
        stateLock.unlock()
        return shouldNotify
    }

    // MARK: - Frames

    /// Until the stream crops to the device screen itself, renders the frame to
    /// a CGImage and crops the Simulator window chrome off. The crop is detected
    /// from the first frame and handed to ScreenCaptureKit as `sourceRect`; from
    /// then on buffers arrive pre-cropped and go to the layer as their IOSurface.
    /// (Cropping the raw surface with the layer's `contentsRect` mis-rendered on
    /// the embedded panel, so the crop is done by the stream, never the layer.)
    private func process(_ pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        let stopping = isStopping
        let cachedCrop = screenCropPixels
        let croppedSize = croppedOutputSize
        stateLock.unlock()
        guard !stopping else { return }

        let fullSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard fullSize.width > 0, fullSize.height > 0 else { return }

        if fullSize == croppedSize {
            frameDelivery.submit(
                SimulatorDisplayFrame(
                    source: .buffer(pixelBuffer),
                    fullPixelSize: fullSize,
                    cropRect: CGRect(x: 0, y: 0, width: 1, height: 1)
                )
            )
            return
        }

        autoreleasepool {
            let ciImage = CIImage(cvImageBuffer: pixelBuffer)
            guard let image = renderContext.createCGImage(ciImage, from: ciImage.extent) else { return }

            let cropPixels: CGRect
            if let cachedCrop {
                cropPixels = cachedCrop
            } else {
                cropPixels = detectScreenCrop(in: image)
                stateLock.lock()
                screenCropPixels = cropPixels
                stateLock.unlock()
                let normalized = CGRect(
                    x: cropPixels.minX / fullSize.width,
                    y: cropPixels.minY / fullSize.height,
                    width: cropPixels.width / fullSize.width,
                    height: cropPixels.height / fullSize.height
                )
                Task { @MainActor [geometryHandler] in geometryHandler(normalized) }
                cropStream(to: normalized, pixelSize: cropPixels.size)
            }

            let cropped = image.cropping(to: cropPixels) ?? image
            frameDelivery.submit(
                SimulatorDisplayFrame(
                    source: .image(cropped),
                    fullPixelSize: CGSize(width: cropped.width, height: cropped.height),
                    cropRect: CGRect(x: 0, y: 0, width: 1, height: 1)
                )
            )
        }
    }

    /// Narrows the stream to the device screen (`normalized` is relative to the
    /// window) at the same pixel density. If the update fails, frames keep
    /// taking the CGImage path.
    private func cropStream(to normalized: CGRect, pixelSize: CGSize) {
        guard let stream, let configuration, windowPointSize.width > 0 else { return }
        let width = max(2, Int(pixelSize.width))
        let height = max(2, Int(pixelSize.height))
        configuration.sourceRect = CGRect(
            x: normalized.minX * windowPointSize.width,
            y: normalized.minY * windowPointSize.height,
            width: normalized.width * windowPointSize.width,
            height: normalized.height * windowPointSize.height
        )
        configuration.width = width
        configuration.height = height
        // Set before the update: the first cropped buffers can beat the completion
        // handler. Old-size buffers still take the CGImage path, so sizes never mix.
        stateLock.lock()
        croppedOutputSize = CGSize(width: width, height: height)
        stateLock.unlock()
        stream.updateConfiguration(configuration) { [weak self] error in
            guard let self, error != nil else { return }
            self.stateLock.lock()
            self.croppedOutputSize = nil
            self.stateLock.unlock()
        }
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
        let status = SCFrameStatus(rawValue: rawStatus) else {
            // Some OS versions omit attachments for a valid first frame.
            return true
        }
        return status == .complete || status == .started
    }

    private func detectScreenCrop(in image: CGImage) -> CGRect {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard let pixels = rasterize(image),
              let outer = detectDeviceBounds(in: pixels, size: imageSize) else {
            return fallbackScreenCrop(in: imageSize)
        }

        return screenCrop(within: outer, in: imageSize)
    }

    private func fallbackScreenCrop(in imageSize: CGSize) -> CGRect {
        // Simulator's independent window layout is normally a toolbar above a
        // centered device. This is used only if the first frame has no usable
        // background/silhouette; normal frames use detectDeviceBounds above.
        let outer = CGRect(
            x: imageSize.width * 0.02,
            y: imageSize.height * 0.06,
            width: imageSize.width * 0.96,
            height: imageSize.height * 0.934
        )
        return screenCrop(within: outer, in: imageSize)
    }

    /// The display's rectangle centered inside the device silhouette `outer`.
    private func screenCrop(within outer: CGRect, in imageSize: CGSize) -> CGRect {
        let aspect = max(displayAspectRatio ?? outer.width / max(outer.height, 1), 0.1)
        let inset = displayInset(for: outer, aspect: aspect)
        let maximumWidth = max(2, outer.width - inset * 2)
        let maximumHeight = max(2, outer.height - inset * 2)
        var width = maximumWidth
        var height = width / aspect
        if height > maximumHeight {
            height = maximumHeight
            width = height * aspect
        }
        return integralCropRect(
            CGRect(x: outer.midX - width / 2, y: outer.midY - height / 2, width: width, height: height),
            in: imageSize
        )
    }

    private func displayInset(for outer: CGRect, aspect: CGFloat) -> CGFloat {
        let outerAspect = outer.width / max(outer.height, 1)
        let aspectDifference = abs(outerAspect - aspect) / max(aspect, 0.1)

        // If the detected bounds already have the framebuffer's aspect ratio,
        // Simulator is likely running without device bezels. In that mode the
        // bounds are the display itself and an artificial 4% inset would crop
        // real pixels. A noticeably wider/taller silhouette indicates the
        // physical bezel, for which the small inset removes the black frame.
        guard displayAspectRatio != nil, aspectDifference < 0.015 else {
            return max(4, min(outer.width, outer.height) * 0.04)
        }
        return 0
    }

    private func integralCropRect(_ rect: CGRect, in imageSize: CGSize) -> CGRect {
        let minX = max(0, floor(rect.minX))
        let minY = max(0, floor(rect.minY))
        let maxX = min(imageSize.width, ceil(rect.maxX))
        let maxY = min(imageSize.height, ceil(rect.maxY))
        guard maxX > minX, maxY > minY else {
            return CGRect(origin: .zero, size: imageSize)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func detectDeviceBounds(in pixels: [UInt8], size: CGSize) -> CGRect? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 20, height > 20 else { return nil }

        let background = backgroundColor(in: pixels, width: width, height: height)
        let threshold = 18
        func differs(_ x: Int, _ y: Int) -> Bool {
            let index = (y * width + x) * 4
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            return abs(red - background.red)
                + abs(green - background.green)
                + abs(blue - background.blue) > threshold
        }

        // The Simulator toolbar is at the top of the independent window. Start
        // just below its usual 5% band so toolbar text/icons cannot become the
        // device's top edge.
        let firstRow = max(0, Int(Double(height) * 0.055))
        let lastRow = min(height - 1, Int(Double(height) * 0.995))
        var rows: [Int] = []
        for y in firstRow...lastRow {
            var different = 0
            for x in 0..<width where differs(x, y) {
                different += 1
            }
            if different >= Int(Double(width) * 0.22) {
                rows.append(y)
            }
        }
        guard let top = rows.first, let bottom = rows.last, bottom > top else { return nil }

        var columns: [Int] = []
        let rowCount = bottom - top + 1
        for x in 0..<width {
            var different = 0
            for y in top...bottom where differs(x, y) {
                different += 1
            }
            if different >= Int(Double(rowCount) * 0.22) {
                columns.append(x)
            }
        }
        guard let left = columns.first, let right = columns.last, right > left else { return nil }

        return CGRect(
            x: CGFloat(left),
            y: CGFloat(top),
            width: CGFloat(right - left + 1),
            height: CGFloat(bottom - top + 1)
        )
    }

    private struct RGB {
        let red: Int
        let green: Int
        let blue: Int
    }

    private func backgroundColor(in pixels: [UInt8], width: Int, height: Int) -> RGB {
        let start = max(0, Int(Double(height) * 0.08))
        let end = min(height - 1, Int(Double(height) * 0.98))
        var red = 0
        var green = 0
        var blue = 0
        var count = 0
        let step = max(1, height / 64)
        for y in stride(from: start, through: end, by: step) {
            for x in [0, max(0, width - 1)] {
                let index = (y * width + x) * 4
                red += Int(pixels[index])
                green += Int(pixels[index + 1])
                blue += Int(pixels[index + 2])
                count += 1
            }
        }
        guard count > 0 else { return RGB(red: 255, green: 255, blue: 255) }
        return RGB(red: red / count, green: green / count, blue: blue / count)
    }

    private func rasterize(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}

@available(macOS 14.0, *)
private final class LatestFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: SimulatorScreenCapture.FrameHandler
    private var latest: SimulatorDisplayFrame?
    private var deliveryScheduled = false

    init(handler: @escaping SimulatorScreenCapture.FrameHandler) {
        self.handler = handler
    }

    func submit(_ frame: SimulatorDisplayFrame) {
        let shouldSchedule: Bool
        lock.lock()
        latest = frame
        shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.deliverLatest()
        }
    }

    @MainActor
    private func deliverLatest() {
        lock.lock()
        let frame = latest
        latest = nil
        deliveryScheduled = false
        lock.unlock()

        if let frame {
            handler(frame)
        }
    }
}

public enum SimulatorCaptureError: LocalizedError, Sendable {
    case windowNotFound

    public var errorDescription: String? {
        switch self {
        case .windowNotFound:
            return AppCopy.text("simulator.capture.windowNotFound")
        }
    }
}

@available(macOS 14.0, *)
private extension SimulatorController.CaptureQuality {
    var captureResolution: SCCaptureResolutionType {
        switch self {
        case .performance: return .nominal
        case .balanced: return .automatic
        case .high: return .best
        }
    }
}
