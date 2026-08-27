// Copyright (c) 2026 DOTS
// Direct touch injection for the embedded iOS Simulator screen.

import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

/// Sends touch events through SimulatorKit's HID client instead of through
/// WindowServer. This keeps the macOS cursor and the standalone Simulator
/// window completely out of the gesture path.
final class SimulatorHIDInput {
    private let udid: String
    private let simulatorKit: UnsafeMutableRawPointer?

    private var client: AnyObject?
    private var touchIdentifier: UInt32 = 0

    private typealias CreateDigitizerFn = @convention(c) (
        CFAllocator?, UInt64, UInt32,
        UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double,
        Bool, Bool, UInt32
    ) -> Unmanaged<CFTypeRef>?

    private typealias CreateFingerFn = @convention(c) (
        CFAllocator?, UInt64,
        UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double,
        Bool, Bool, UInt32
    ) -> Unmanaged<CFTypeRef>?

    private typealias AppendEventFn = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    private typealias TrackpadWrapFn = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias SendFn = @convention(c) (
        AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?
    ) -> Void

    private let createDigitizer: CreateDigitizerFn?
    private let createFinger: CreateFingerFn?
    private let appendEvent: AppendEventFn?
    private let wrapTrackpadEvent: TrackpadWrapFn?

    init(udid: String) {
        self.udid = udid

        let developerDir = Self.developerDirectory()
        let coreSimulatorPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
        _ = dlopen(coreSimulatorPath, RTLD_NOW | RTLD_GLOBAL)

        if let path = Self.simulatorKitPath(developerDir: developerDir) {
            simulatorKit = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
        } else {
            simulatorKit = nil
        }

        let dyld = UnsafeMutableRawPointer(bitPattern: -2)
        if let simulatorKit,
           let pCreateDigitizer = dlsym(dyld, "IOHIDEventCreateDigitizerEvent"),
           let pCreateFinger = dlsym(dyld, "IOHIDEventCreateDigitizerFingerEvent"),
           let pAppendEvent = dlsym(dyld, "IOHIDEventAppendEvent"),
           let pWrapTrackpad = dlsym(simulatorKit, "IndigoHIDMessageForTrackpadEventFromHIDEventRef") {
            createDigitizer = unsafeBitCast(pCreateDigitizer, to: CreateDigitizerFn.self)
            createFinger = unsafeBitCast(pCreateFinger, to: CreateFingerFn.self)
            appendEvent = unsafeBitCast(pAppendEvent, to: AppendEventFn.self)
            wrapTrackpadEvent = unsafeBitCast(pWrapTrackpad, to: TrackpadWrapFn.self)
        } else {
            createDigitizer = nil
            createFinger = nil
            appendEvent = nil
            wrapTrackpadEvent = nil
        }
    }

    /// Sends a complete touch sequence at one point.
    func tap(at point: CGPoint, size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0,
              ensureClient() else { return false }

        let identifier = nextTouchIdentifier()
        let normalized = normalized(point, in: size)
        guard send(point: normalized, identifier: identifier, phase: .down, edge: .none) else { return false }
        usleep(80_000)
        return send(point: normalized, identifier: identifier, phase: .up, edge: .none)
    }

    /// Sends a single-finger touch sequence with interpolated move events.
    func swipe(from start: CGPoint, to end: CGPoint, size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0,
              ensureClient() else { return false }

        let identifier = nextTouchIdentifier()
        let normalizedStart = normalized(start, in: size)
        let normalizedEnd = normalized(end, in: size)
        let edge = edge(for: normalizedStart)
        let steps = 14

        guard send(point: normalizedStart, identifier: identifier, phase: .down, edge: edge) else { return false }
        var successfulMoves = 0
        for step in 1...steps {
            usleep(16_000)
            let progress = Double(step) / Double(steps)
            let point = CGPoint(
                x: normalizedStart.x + (normalizedEnd.x - normalizedStart.x) * progress,
                y: normalizedStart.y + (normalizedEnd.y - normalizedStart.y) * progress
            )
            if send(point: point, identifier: identifier, phase: .move, edge: edge) {
                successfulMoves += 1
            }
        }

        usleep(16_000)
        let released = send(point: normalizedEnd, identifier: identifier, phase: .up, edge: edge)
        return released && successfulMoves >= steps / 2
    }

    private enum TouchEdge {
        case none
        case left
        case top
        case right
        case bottom

        var bit: UInt8 {
            switch self {
            case .none: return 0x00
            case .left: return 0x02
            case .top: return 0x08
            case .right: return 0x04
            case .bottom: return 0x01
            }
        }
    }

    /// iOS treats a touch that starts in these regions as a system-edge
    /// gesture. The 6% horizontal threshold is about 24 logical points on
    /// the current 3x iPhone simulator and still leaves the screen interior
    /// behaving like an ordinary drag surface.
    private func edge(for normalizedPoint: CGPoint) -> TouchEdge {
        if normalizedPoint.x <= 0.06 { return .left }
        if normalizedPoint.x >= 0.94 { return .right }
        if normalizedPoint.y <= 0.05 { return .top }
        if normalizedPoint.y >= 0.95 { return .bottom }
        return .none
    }

    private enum TouchPhase {
        case down
        case move
        case up

        var eventMask: UInt32 {
            switch self {
            case .down, .move: return 0x07
            case .up: return 0x06
            }
        }

        var isInRange: Bool { self != .up }
        var isTouching: Bool { self != .up }
    }

    private func send(
        point: CGPoint,
        identifier: UInt32,
        phase: TouchPhase,
        edge: TouchEdge
    ) -> Bool {
        guard let createDigitizer,
              let createFinger,
              let appendEvent,
              let wrapTrackpadEvent,
              let client else { return false }

        let timestamp = mach_absolute_time()
        guard let parentUnmanaged = createDigitizer(
            nil,
            timestamp,
            2,
            0,
            identifier,
            phase.eventMask,
            0,
            point.x,
            point.y,
            0,
            0,
            0,
            phase.isInRange,
            phase.isTouching,
            0
        ) else { return false }
        let parent = parentUnmanaged.takeRetainedValue()

        guard let fingerUnmanaged = createFinger(
            nil,
            timestamp,
            0,
            identifier,
            phase.eventMask,
            point.x,
            point.y,
            0,
            0,
            0,
            phase.isInRange,
            phase.isTouching,
            0
        ) else { return false }
        let finger = fingerUnmanaged.takeRetainedValue()
        appendEvent(parent, finger, 0)

        let rawEvent = Unmanaged.passUnretained(parent as AnyObject).toOpaque()
        guard let message = withExtendedLifetime(parent, {
            wrapTrackpadEvent(rawEvent)
        }) else { return false }

        // The trackpad wrapper leaves the HID routing tag unset.  0x32 is
        // the integrated phone digitizer target on current SimulatorKit.
        message.storeBytes(of: UInt32(0x32), toByteOffset: 0x6c, as: UInt32.self)
        if malloc_size(message) >= 0x110 {
            message.storeBytes(of: UInt32(0x32), toByteOffset: 0x10c, as: UInt32.self)
        }
        let edgePresent: UInt8 = edge == .none ? 0x00 : 0x04
        message.storeBytes(of: edgePresent, toByteOffset: 0x3a, as: UInt8.self)
        message.storeBytes(of: edge.bit, toByteOffset: 0x3b, as: UInt8.self)
        if malloc_size(message) >= 0xdc {
            message.storeBytes(of: edgePresent, toByteOffset: 0xda, as: UInt8.self)
            message.storeBytes(of: edge.bit, toByteOffset: 0xdb, as: UInt8.self)
        }

        return send(message: message, to: client)
    }

    private func send(message: UnsafeMutableRawPointer, to client: AnyObject) -> Bool {
        let selector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let cls = object_getClass(client),
              let implementation = class_getMethodImplementation(cls, selector) else { return false }
        let send = unsafeBitCast(implementation, to: SendFn.self)
        send(client, selector, message, ObjCBool(true), nil, nil)
        return true
    }

    private func ensureClient() -> Bool {
        if client != nil { return true }
        guard simulatorKit != nil,
              let device = resolveDevice(),
              let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {
            return false
        }

        let selector = NSSelectorFromString("initWithDevice:error:")
        guard let implementation = class_getMethodImplementation(cls, selector),
              let metaclass = object_getClass(cls),
              let allocImplementation = class_getMethodImplementation(metaclass, NSSelectorFromString("alloc")) else {
            return false
        }

        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        typealias InitFn = @convention(c) (
            AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?

        let allocate = unsafeBitCast(allocImplementation, to: AllocFn.self)
        let initialize = unsafeBitCast(implementation, to: InitFn.self)
        guard let allocated = allocate(cls, NSSelectorFromString("alloc")) else { return false }

        var error: NSError?
        client = initialize(allocated, selector, device, &error)
        return client != nil
    }

    private func resolveDevice() -> NSObject? {
        guard let cls = NSClassFromString("SimServiceContext") else { return nil }
        let selector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let metaclass = object_getClass(cls),
              let implementation = class_getMethodImplementation(metaclass, selector) else { return nil }

        typealias ContextFn = @convention(c) (
            AnyClass, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        let contextFn = unsafeBitCast(implementation, to: ContextFn.self)
        var contextError: NSError?
        guard let context = contextFn(cls, selector, Self.developerDirectory() as NSString, &contextError),
              let contextClass = object_getClass(context) else { return nil }

        let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let setImplementation = class_getMethodImplementation(contextClass, setSelector) else { return nil }
        typealias SetFn = @convention(c) (
            AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        var setError: NSError?
        guard let set = unsafeBitCast(setImplementation, to: SetFn.self)(context, setSelector, &setError),
              let devices = (set.value(forKey: "availableDevices") as? [NSObject]) else { return nil }

        return devices.first { device in
            (device.value(forKey: "UDID") as? NSUUID)?.uuidString.caseInsensitiveCompare(udid) == .orderedSame
        }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / size.width, 0), 1),
            y: min(max(point.y / size.height, 0), 1)
        )
    }

    private func nextTouchIdentifier() -> UInt32 {
        touchIdentifier &+= 1
        if touchIdentifier == 0 { touchIdentifier = 1 }
        return touchIdentifier
    }

    private static func simulatorKitPath(developerDir: String) -> String? {
        let developerURL = URL(fileURLWithPath: developerDir)
        let contentsURL = developerURL.deletingLastPathComponent()
        let candidates = [
            developerURL.appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit").path,
            contentsURL.appendingPathComponent("SharedFrameworks/SimulatorKit.framework/SimulatorKit").path,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func developerDirectory() -> String {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["DEVELOPER_DIR"], !override.isEmpty {
            candidates.append(override)
        }
        if let selected = xcodeSelectDirectory() {
            candidates.append(selected)
        }
        candidates.append("/Applications/Xcode.app/Contents/Developer")

        return candidates.first { simulatorKitPath(developerDir: $0) != nil }
            ?? candidates[0]
    }

    private static func xcodeSelectDirectory() -> String? {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
