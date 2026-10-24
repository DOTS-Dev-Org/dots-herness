// Copyright (c) 2026 DOTS
// Android emulator and ADB management service for native tools.

import CoreGraphics
import Foundation

public struct AndroidDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let state: String
    public let isEmulator: Bool

    public init(id: String, name: String, state: String, isEmulator: Bool) {
        self.id = id
        self.name = name
        self.state = state
        self.isEmulator = isEmulator
    }

    public var isOnline: Bool { state.caseInsensitiveCompare("device") == .orderedSame }
    public var title: String { "\(name) (\(id)) · \(state)" }
}

public struct AndroidEmulatorError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum AndroidSDKLocator {
    public static func findADB() -> URL? {
        findTool(named: "adb", subpath: "platform-tools/adb")
    }

    public static func findEmulator() -> URL? {
        findTool(named: "emulator", subpath: "emulator/emulator")
    }

    private static func findTool(named name: String, subpath: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        var candidateRoots: [String] = []

        if let home = env["ANDROID_HOME"], !home.isEmpty { candidateRoots.append(home) }
        if let sdkRoot = env["ANDROID_SDK_ROOT"], !sdkRoot.isEmpty { candidateRoots.append(sdkRoot) }

        let userHome = NSHomeDirectory()
        candidateRoots.append("\(userHome)/Library/Android/sdk")
        candidateRoots.append("\(userHome)/Android/Sdk")
        candidateRoots.append("/usr/local/share/android-sdk")
        candidateRoots.append("/opt/homebrew/share/android-sdk")

        for root in candidateRoots {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(subpath).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        // Search PATH and standard bin dirs
        let standardPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in standardPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        if let pathEnv = env["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).standardizedFileURL
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        return nil
    }
}

public enum AndroidShell {
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 60) throws -> Data {
        try ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout) { failure in
            switch failure {
            case .launch(let message):
                return AndroidEmulatorError("Failed to execute \(executable.lastPathComponent): \(message)")
            case .timedOut:
                return AndroidEmulatorError("\(executable.lastPathComponent) timed out after \(Int(timeout))s.")
            case .nonzero(let status, let stderr):
                return AndroidEmulatorError(stderr.isEmpty ? "Exit status \(status)" : stderr)
            }
        }
    }

    public static func adb(_ arguments: [String], timeout: TimeInterval = 60) throws -> Data {
        guard let adb = AndroidSDKLocator.findADB() else {
            throw AndroidEmulatorError("Android adb tool not found. Install Android SDK Command-line Tools or set ANDROID_HOME.")
        }
        return try run(executable: adb, arguments: arguments, timeout: timeout)
    }

    public static func emulator(_ arguments: [String], timeout: TimeInterval = 60) throws -> Data {
        guard let emulator = AndroidSDKLocator.findEmulator() else {
            throw AndroidEmulatorError("Android emulator tool not found. Install Android SDK Emulator or set ANDROID_HOME.")
        }
        return try run(executable: emulator, arguments: arguments, timeout: timeout)
    }
}

/// A running emulator as announced in its discovery file (avd/running/pid_*.ini).
public struct AndroidRunningEmulator: Sendable, Hashable {
    public let processID: pid_t
    public let serial: String
    public let avdName: String
    /// Device display in pixels, from the AVD's config.ini; adb input uses these coordinates.
    public let screenSize: CGSize

    public static func running() -> [AndroidRunningEmulator] {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("pid_"), let pid = pid_t(name.dropFirst(4)),
                  kill(pid, 0) == 0, // the emulator leaves the file behind if it crashes
                  let values = ini(file) else { return nil }
            var width = 1080.0, height = 2400.0
            if let avdDirectory = values["avd.dir"],
               let config = ini(URL(fileURLWithPath: avdDirectory).appendingPathComponent("config.ini")) {
                width = Double(config["hw.lcd.width"] ?? "") ?? width
                height = Double(config["hw.lcd.height"] ?? "") ?? height
            }
            return AndroidRunningEmulator(
                processID: pid,
                serial: "emulator-" + (values["port.serial"] ?? "5554"),
                avdName: values["avd.name"] ?? name,
                screenSize: CGSize(width: width, height: height)
            )
        }
    }

    private static func ini(_ url: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if values[key] == nil { values[key] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return values
    }
}

public enum AndroidEmulatorService {
    public static func devices() throws -> [AndroidDevice] {
        let data = try AndroidShell.adb(["devices", "-l"], timeout: 15)
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var result: [AndroidDevice] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("List of devices") || trimmed.isEmpty { continue }

            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0])
            let state = String(parts[1])

            var modelName = serial
            for part in parts.dropFirst(2) {
                if part.hasPrefix("model:") {
                    modelName = String(part.dropFirst(6))
                }
            }

            let isEmulator = serial.hasPrefix("emulator-")
            result.append(AndroidDevice(id: serial, name: modelName, state: state, isEmulator: isEmulator))
        }
        return result
    }

    public static func avds() throws -> [String] {
        let data = try AndroidShell.emulator(["-list-avds"], timeout: 15)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    public static func boot(avdName: String) throws {
        guard let emulator = AndroidSDKLocator.findEmulator() else {
            throw AndroidEmulatorError("Android emulator executable not found.")
        }
        let process = Process()
        process.executableURL = emulator
        process.arguments = ["-avd", avdName, "-no-snapshot-load", "-no-boot-anim"]
        // Never read; a Pipe would fill up and stall the chatty emulator.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// One key press, e.g. 3 home, 4 back, 26 power, 187 recent apps.
    public static func keyEvent(serial: String, code: Int) throws {
        _ = try AndroidShell.adb(["-s", serial, "shell", "input", "keyevent", "\(code)"], timeout: 10)
    }

    /// The size `adb shell input` coordinates refer to: the `wm size` override if set, else the panel size.
    public static func inputSize(serial: String) throws -> CGSize? {
        let data = try AndroidShell.adb(["-s", serial, "shell", "wm", "size"], timeout: 10)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let line = lines.first { $0.hasPrefix("Override size:") } ?? lines.first { $0.hasPrefix("Physical size:") }
        guard let value = line?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return nil }
        let parts = value.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    public static func setNightMode(serial: String, dark: Bool) throws {
        _ = try AndroidShell.adb(["-s", serial, "shell", "cmd", "uimode", "night", dark ? "yes" : "no"], timeout: 10)
    }

    public static func shutdown(serial: String) throws {
        _ = try AndroidShell.adb(["-s", serial, "emu", "kill"], timeout: 10)
    }

    public static func screenshot(serial: String) throws -> Data {
        try AndroidShell.adb(["-s", serial, "exec-out", "screencap", "-p"], timeout: 20)
    }

    public static func install(serial: String, apkPath: String) throws {
        _ = try AndroidShell.adb(["-s", serial, "install", "-r", apkPath], timeout: 120)
    }

    public static func launch(serial: String, component: String) throws -> String {
        let data = try AndroidShell.adb(["-s", serial, "shell", "am", "start", "-n", component], timeout: 20)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public static func terminate(serial: String, package: String) throws {
        _ = try AndroidShell.adb(["-s", serial, "shell", "am", "force-stop", package], timeout: 15)
    }

    public static func openURL(serial: String, url: String) throws {
        _ = try AndroidShell.adb(["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url], timeout: 20)
    }

    public static func tap(serial: String, x: Int, y: Int) throws {
        _ = try AndroidShell.adb(["-s", serial, "shell", "input", "tap", "\(x)", "\(y)"], timeout: 10)
    }

    public static func textInput(serial: String, text: String) throws {
        // Escape characters for shell input text
        let escaped = text.replacingOccurrences(of: " ", with: "%s")
        _ = try AndroidShell.adb(["-s", serial, "shell", "input", "text", escaped], timeout: 15)
    }

    public static func swipe(serial: String, x1: Int, y1: Int, x2: Int, y2: Int, duration: Int = 300) throws {
        _ = try AndroidShell.adb(["-s", serial, "shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(duration)"], timeout: 10)
    }

    public static func logcat(serial: String, lines: Int = 100) throws -> String {
        let data = try AndroidShell.adb(["-s", serial, "logcat", "-d", "-t", "\(lines)", "*:E"], timeout: 15)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
