// Copyright (c) 2026 DOTS
// Thin wrapper around `xcrun simctl` used by the iOS simulator panel and tools.

import Foundation

public struct SimulatorDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let runtime: String
    public let state: String

    public init(id: String, name: String, runtime: String, state: String) {
        self.id = id
        self.name = name
        self.runtime = runtime
        self.state = state
    }

    public var isBooted: Bool { state.caseInsensitiveCompare("Booted") == .orderedSame }
    public var title: String { "\(name) · \(runtime)" }
}

public struct SimulatorError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Blocking `xcrun` calls. Never call these on the main actor; use
/// `SimulatorService` helpers which hop to a background executor.
public enum SimulatorShell {
    public static func run(_ arguments: [String], timeout: TimeInterval = 60) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw SimulatorError(AppCopy.text("simulator.xcodeMissing"))
        }

        // Drain both pipes while the child runs so a large screenshot cannot
        // deadlock on a full pipe buffer.
        var stdoutData = Data()
        var stderrData = Data()
        let stdoutHandle = output.fileHandleForReading
        let stderrHandle = errors.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            stdoutData.append(stdoutHandle.availableData)
            stderrData.append(stderrHandle.availableData)
        }
        if process.isRunning {
            process.terminate()
            throw SimulatorError(AppCopy.text("simulator.timedOut"))
        }
        stdoutData.append(stdoutHandle.readDataToEndOfFile())
        stderrData.append(stderrHandle.readDataToEndOfFile())

        guard process.terminationStatus == 0 else {
            let text = String(data: stderrData.prefix(4_000), encoding: .utf8) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorError(trimmed.isEmpty ? AppCopy.format("simulator.exitStatus", process.terminationStatus) : trimmed)
        }
        return stdoutData
    }

    public static func simctl(_ arguments: [String], timeout: TimeInterval = 60) throws -> Data {
        try run(["simctl"] + arguments, timeout: timeout)
    }

    public static func text(_ arguments: [String], timeout: TimeInterval = 60) throws -> String {
        let data = try simctl(arguments, timeout: timeout)
        let text = String(data: data.prefix(100_000), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SimulatorService {
    public static func devices() throws -> [SimulatorDevice] {
        let data = try SimulatorShell.simctl(["list", "devices", "available", "--json"], timeout: 30)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: Any] else {
            throw SimulatorError(AppCopy.text("simulator.listFailed"))
        }

        var result: [SimulatorDevice] = []
        for (runtimeID, value) in runtimes {
            guard let entries = value as? [[String: Any]] else { continue }
            let runtime = prettyRuntime(runtimeID)
            for entry in entries {
                guard entry["isAvailable"] as? Bool != false,
                      let udid = entry["udid"] as? String,
                      let name = entry["name"] as? String else { continue }
                result.append(SimulatorDevice(
                    id: udid,
                    name: name,
                    runtime: runtime,
                    state: entry["state"] as? String ?? "Shutdown"
                ))
            }
        }
        return result.sorted {
            $0.runtime == $1.runtime
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.runtime.localizedStandardCompare($1.runtime) == .orderedDescending
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> "iOS 26.5"
    public static func prettyRuntime(_ identifier: String) -> String {
        let tail = identifier.components(separatedBy: ".").last ?? identifier
        let parts = tail.components(separatedBy: "-")
        guard parts.count > 1 else { return tail }
        return parts[0] + " " + parts.dropFirst().joined(separator: ".")
    }

    public static func boot(_ udid: String) throws {
        do {
            _ = try SimulatorShell.simctl(["boot", udid], timeout: 120)
        } catch let error as SimulatorError where error.message.contains("current state: Booted") {
            // Already booted is the state we wanted.
        }
        openSimulatorApp()
    }

    public static func shutdown(_ udid: String) throws {
        _ = try SimulatorShell.simctl(["shutdown", udid], timeout: 60)
    }

    /// Returns the aspect ratio of the simulator's connected main display.
    ///
    /// The window rendered by Simulator contains a toolbar and a device bezel,
    /// while `simctl screenshot` contains only this display. ScreenCaptureKit
    /// uses the ratio to find the display inside the independent Simulator
    /// window without making assumptions about iPhone versus iPad geometry.
    public static func displayAspectRatio(_ udid: String) throws -> Double {
        let text = try SimulatorShell.text(["io", udid, "enumerate"], timeout: 30)
        guard let ratio = parseDisplayAspectRatio(from: text) else {
            throw SimulatorError(AppCopy.text("simulator.captureFailed"))
        }
        return ratio
    }

    static func parseDisplayAspectRatio(from output: String) -> Double? {
        guard let connectedScreens = output.range(of: "Connected Screens:") else {
            return nil
        }

        let connectedText = String(output[connectedScreens.upperBound...])
        let pattern = #"(?m)^\s*Pixel Size:\s*\{\s*(\d+)\s*,\s*(\d+)\s*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(location: 0, length: connectedText.utf16.count)
        let dimensions = regex.matches(in: connectedText, range: range).compactMap { match -> (Double, Double)? in
            guard let widthRange = Range(match.range(at: 1), in: connectedText),
                  let heightRange = Range(match.range(at: 2), in: connectedText),
                  let width = Double(connectedText[widthRange]),
                  let height = Double(connectedText[heightRange]),
                  width > 0,
                  height > 0 else { return nil }
            return (width, height)
        }
        guard let (width, height) = dimensions.max(by: { $0.0 * $0.1 < $1.0 * $1.1 }) else {
            return nil
        }
        return width / height
    }

    /// `simctl io ... screenshot` writes to a file: piping to "-" is rejected
    /// when the working directory is not writable, so use a temp file.
    public static func screenshot(_ udid: String) throws -> Data {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dots-sim-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try SimulatorShell.simctl(["io", udid, "screenshot", "--type=png", file.path], timeout: 20)
        let data = try Data(contentsOf: file)
        guard data.count > 8 else { throw SimulatorError(AppCopy.text("simulator.captureFailed")) }
        return data
    }

    public static func openURL(_ udid: String, url: String) throws {
        guard let parsed = URL(string: url), parsed.scheme != nil else {
            throw SimulatorError(AppCopy.format("simulator.invalidURL", url))
        }
        _ = try SimulatorShell.simctl(["openurl", udid, parsed.absoluteString], timeout: 30)
    }

    public static func install(_ udid: String, appPath: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SimulatorError(AppCopy.format("simulator.appNotFound", appPath))
        }
        _ = try SimulatorShell.simctl(["install", udid, appPath], timeout: 180)
    }

    public static func launch(_ udid: String, bundleID: String) throws -> String {
        try SimulatorShell.text(["launch", udid, bundleID], timeout: 60)
    }

    public static func terminate(_ udid: String, bundleID: String) throws {
        _ = try SimulatorShell.simctl(["terminate", udid, bundleID], timeout: 30)
    }

    public static func setAppearance(_ udid: String, dark: Bool) throws {
        _ = try SimulatorShell.simctl(["ui", udid, "appearance", dark ? "dark" : "light"], timeout: 30)
    }

    /// Bundle identifiers of the apps installed by the user on this device.
    public static func userApps(_ udid: String) throws -> [String] {
        let text = try SimulatorShell.text(["listapps", udid], timeout: 60)
        // The plist output is verbose; the bundle ids are enough for a picker.
        let pattern = #"CFBundleIdentifier\s*=\s*"?([A-Za-z0-9_.\-]+)"?;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let ids = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        return Array(Set(ids.filter { !$0.hasPrefix("com.apple.") })).sorted()
    }

    public static func openSimulatorApp() {
        // `simctl boot` starts the device headless; the Simulator app is what
        // renders it (and what receives hardware-key events from the panel).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", "Simulator"]
        try? process.run()
    }
}
