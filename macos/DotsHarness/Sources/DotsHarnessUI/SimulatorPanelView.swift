// Copyright (c) 2026 DOTS
// iOS simulator panel: live device screen, device controls, pointer input.

import SwiftUI
import AppKit
import DotsHarnessCore

public struct SimulatorPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: SimulatorController
    @State private var isDark = false

    public init(model: AppModel) {
        self.model = model
        controller = model.simulator
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            screen
            Divider()
            controls
        }
        .frame(minWidth: 280, idealWidth: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await controller.refreshDevices()
            if controller.isSelectedDeviceBooted {
                await controller.relocateSimulatorWindowOffscreen()
                controller.startStream()
            }
        }
        .onDisappear { controller.stopStream() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(AppCopy.text("simulator.title")).font(.headline)
                Spacer()
                Button {
                    model.isSimulatorPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(AppCopy.text("simulator.close"))
            }

            Picker("", selection: $controller.selectedDeviceID) {
                ForEach(controller.devices) { device in
                    Text(device.title + (device.isBooted ? " ●" : ""))
                        .tag(Optional(device.id))
                }
            }
            .labelsHidden()
            .disabled(controller.devices.isEmpty)

            HStack(spacing: 8) {
                Text(AppCopy.text("simulator.captureRate"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $controller.captureRate) {
                    ForEach(SimulatorController.CaptureRate.allCases) { rate in
                        Text(rate.title).tag(rate)
                    }
                }
                .labelsHidden()
                .frame(width: 88)
                .help(AppCopy.text("simulator.captureRateHelp"))

                Text(controller.measuredFPS > 0
                     ? String(format: "%.1f", controller.measuredFPS)
                     : "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(AppCopy.text(controller.captureBackend.titleKey))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle(isOn: $isDark) {
                    Image(systemName: isDark ? "moon.fill" : "sun.max")
                }
                .toggleStyle(.button)
                .help(AppCopy.text("simulator.appearance"))
                .onChange(of: isDark) { _, value in
                    Task { await controller.setAppearance(dark: value) }
                }
            }

            HStack(spacing: 8) {
                Text(AppCopy.text("simulator.latency"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $controller.captureLatency) {
                    ForEach(SimulatorController.CaptureLatency.allCases) { latency in
                        Text(AppCopy.text(latency.titleKey)).tag(latency)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Text(AppCopy.text("simulator.quality"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $controller.captureQuality) {
                    ForEach(SimulatorController.CaptureQuality.allCases) { quality in
                        Text(AppCopy.text(quality.titleKey)).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var screen: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let frame = controller.frame {
                GeometryReader { geometry in
                    DeviceBezelView(image: frame, containerSize: geometry.size) { start, end, drawnSize in
                        send(start: start, end: end, in: drawnSize, image: frame.size)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .padding(16)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(AppCopy.text("simulator.noFrame"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            if controller.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .frame(minHeight: 420)
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                button("house", "simulator.home") { controller.pressHome() }
                button("lock", "simulator.lock") { controller.pressLock() }
                button("camera", "simulator.screenshot") {
                    Task { await saveScreenshot() }
                }
                button(controller.isStreaming ? "pause" : "play", "simulator.stream") {
                    controller.toggleStream()
                }
                button("arrow.clockwise", "simulator.refresh") {
                    Task { await controller.refreshDevices() }
                }
                button("power", controller.isSelectedDeviceBooted ? "simulator.shutdown" : "simulator.boot") {
                    Task {
                        controller.isSelectedDeviceBooted ? await controller.shutdown() : await controller.boot()
                    }
                }
            }
            if !controller.status.isEmpty {
                Text(controller.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    private func button(_ symbol: String, _ helpKey: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 20, height: 18)
        }
        .buttonStyle(.bordered)
        .help(AppCopy.text(helpKey))
    }

    private func saveScreenshot() async {
        let directory = URL(fileURLWithPath: model.workspacePath.isEmpty
                            ? NSTemporaryDirectory()
                            : model.workspacePath)
        _ = await controller.saveScreenshot(to: directory)
    }

    /// Converts view coordinates to image points, then taps or swipes.
    private func send(start: CGPoint, end: CGPoint, in viewSize: CGSize, image: CGSize) {
        guard let from = imagePoint(start, viewSize: viewSize, image: image),
              let to = imagePoint(end, viewSize: viewSize, image: image) else { return }
        let distance = hypot(to.x - from.x, to.y - from.y)
        if distance < 6 {
            controller.tap(at: from)
        } else {
            controller.swipe(from: from, to: to)
        }
    }

    private func imagePoint(_ point: CGPoint, viewSize: CGSize, image: CGSize) -> CGPoint? {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(viewSize.width / image.width, viewSize.height / image.height)
        let drawn = CGSize(width: image.width * scale, height: image.height * scale)
        let originX = (viewSize.width - drawn.width) / 2
        let originY = (viewSize.height - drawn.height) / 2
        let local = CGPoint(x: point.x - originX, y: point.y - originY)
        guard local.x >= 0, local.y >= 0, local.x <= drawn.width, local.y <= drawn.height else { return nil }
        return CGPoint(x: local.x / scale, y: local.y / scale)
    }
}

/// Draws the streamed frame inside a phone-shaped bezel — metal edge, notch,
/// side buttons — sized to the image's own aspect ratio so the screen fills
/// its slot exactly with no letterboxing.
private struct DeviceBezelView: View {
    let image: NSImage
    let containerSize: CGSize
    let onGesture: (CGPoint, CGPoint, CGSize) -> Void

    private let bezelWidth: CGFloat = 12
    private let cornerRadius: CGFloat = 44

    var body: some View {
        let aspect = max(image.size.width, 1) / max(image.size.height, 1)
        let outer = fittedSize(aspect: aspect, in: containerSize)
        let screenSize = CGSize(width: outer.width - bezelWidth * 2, height: outer.height - bezelWidth * 2)
        let screenRadius = max(cornerRadius - bezelWidth, 4)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(bezelGradient)
                .frame(width: outer.width, height: outer.height)
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)

            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: screenSize.width, height: screenSize.height)
                .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
                .allowsHitTesting(false)

            // SwiftUI's DragGesture is not exposed as a coordinate-bearing
            // accessibility target on macOS.  A transparent AppKit view keeps
            // the framebuffer purely visual while receiving real mouse
            // down/drag/up events for the embedded screen.
            SimulatorScreenInputView { start, end in
                onGesture(start, end, screenSize)
            }
            .frame(width: screenSize.width, height: screenSize.height)

            // Dynamic-island-style notch; purely decorative.
            Capsule()
                .fill(Color.black)
                .frame(width: screenSize.width * 0.3, height: max(screenSize.height * 0.02, 6))
                .offset(y: -screenSize.height / 2 + max(screenSize.height * 0.028, 10))
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.55), lineWidth: 1)
                .frame(width: outer.width, height: outer.height)
                .allowsHitTesting(false)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    private var bezelGradient: LinearGradient {
        LinearGradient(
            colors: [Color(white: 0.24), Color(white: 0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func fittedSize(aspect: CGFloat, in container: CGSize) -> CGSize {
        guard aspect > 0 else { return container }
        if container.width / container.height > aspect {
            let height = container.height
            return CGSize(width: height * aspect, height: height)
        } else {
            let width = container.width
            return CGSize(width: width, height: width / aspect)
        }
    }
}

private struct SimulatorScreenInputView: NSViewRepresentable {
    let onGesture: (CGPoint, CGPoint) -> Void

    func makeNSView(context: Context) -> SimulatorScreenInputNSView {
        let view = SimulatorScreenInputNSView()
        view.onGesture = onGesture
        return view
    }

    func updateNSView(_ nsView: SimulatorScreenInputNSView, context: Context) {
        nsView.onGesture = onGesture
    }
}

private final class SimulatorScreenInputNSView: NSView {
    var onGesture: ((CGPoint, CGPoint) -> Void)?

    private var dragStart: CGPoint?
    private var lastAccessibilityElement: SimulatorScreenAccessibilityElement?

    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { "iOS simulator screen" }

    override func accessibilityPerformPress() -> Bool {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        onGesture?(center, center)
        return true
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let local = localPoint(forScreenPoint: point), bounds.contains(local) else {
            return super.accessibilityHitTest(point)
        }

        let screenFrame = NSAccessibility.screenRect(
            fromView: self,
            rect: NSRect(x: local.x - 1, y: local.y - 1, width: 2, height: 2)
        )
        let element = SimulatorScreenAccessibilityElement(
            frame: screenFrame,
            label: "iOS simulator coordinate (Int(local.x)), (Int(local.y))"
        ) { [weak self] in
            guard let self else { return }
            self.onGesture?(local, local)
        }
        lastAccessibilityElement = element
        return element
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = localPoint(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        onGesture?(start, localPoint(for: event))
    }

    private func localPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func localPoint(forScreenPoint point: NSPoint) -> CGPoint? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: point)
        return convert(windowPoint, from: nil)
    }
}

private final class SimulatorScreenAccessibilityElement: NSAccessibilityElement {
    private let onPress: () -> Void

    init(frame: NSRect, label: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init()
        setAccessibilityFrame(frame)
        setAccessibilityLabel(label)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}
