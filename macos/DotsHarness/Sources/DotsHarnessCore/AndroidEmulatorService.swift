// Copyright (c) 2026 DOTS
// Android emulator and ADB management service for native tools.

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
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw AndroidEmulatorError("Failed to execute \(executable.lastPathComponent): \(error.localizedDescription)")
        }

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
            throw AndroidEmulatorError("\(executable.lastPathComponent) timed out after \(Int(timeout))s.")
        }
        stdoutData.append(stdoutHandle.readDataToEndOfFile())
        stderrData.append(stderrHandle.readDataToEndOfFile())

        guard process.terminationStatus == 0 else {
            let text = String(data: stderrData.prefix(4_000), encoding: .utf8) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AndroidEmulatorError(trimmed.isEmpty ? "Exit status \(process.terminationStatus)" : trimmed)
        }
        return stdoutData
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
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
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
