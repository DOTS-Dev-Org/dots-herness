// Copyright (c) 2026 DOTS
// Agent-facing control of Android emulators and devices via ADB.

import Foundation
import HarnessPluginKit

public enum AndroidEmulatorTools {
    public static let toolName = "android_emulator"

    public static let definitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: toolName,
            description: """
            Control Android emulators and connected devices. Before verification, call list_devices \
            and reuse an online emulator by its exact serial. Do not boot another emulator while one \
            is already online, unless the user explicitly asks for a different AVD. Only boot an AVD \
            if no compatible emulator is running. Supports install/launch, screenshots, input, and logs.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("list_devices"),
                            .string("list_avds"),
                            .string("boot"),
                            .string("shutdown"),
                            .string("screenshot"),
                            .string("install"),
                            .string("launch"),
                            .string("terminate"),
                            .string("open_url"),
                            .string("tap"),
                            .string("text"),
                            .string("swipe"),
                            .string("logcat"),
                        ]),
                        "description": .string("Operation to perform."),
                    ]),
                    "device": .object([
                        "type": .string("string"),
                        "description": .string("Device serial number. Defaults to an online emulator, then the first online device. Call list_devices first and use the existing emulator's exact serial."),
                    ]),
                    "avd_name": .object([
                        "type": .string("string"),
                        "description": .string("Name of the AVD to boot for the 'boot' action."),
                    ]),
                    "component": .object([
                        "type": .string("string"),
                        "description": .string("Package and activity name (e.g. com.example.app/.MainActivity) for launch."),
                    ]),
                    "package": .object([
                        "type": .string("string"),
                        "description": .string("Package identifier for terminate."),
                    ]),
                    "apk_path": .object([
                        "type": .string("string"),
                        "description": .string("Path to .apk file to install, relative to workspace or absolute."),
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("URL to open on device."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Screenshot destination relative to workspace. Defaults to android.png."),
                    ]),
                    "x": .object([
                        "type": .string("integer"),
                        "description": .string("X coordinate for tap."),
                    ]),
                    "y": .object([
                        "type": .string("integer"),
                        "description": .string("Y coordinate for tap."),
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text string to input into focused element."),
                    ]),
                    "x1": .object(["type": .string("integer"), "description": .string("Start X for swipe.")]),
                    "y1": .object(["type": .string("integer"), "description": .string("Start Y for swipe.")]),
                    "x2": .object(["type": .string("integer"), "description": .string("End X for swipe.")]),
                    "y2": .object(["type": .string("integer"), "description": .string("End Y for swipe.")]),
                ]),
                "required": .array([.string("action")]),
            ])
        ),
    ]

    public static func execute(_ arguments: [String: Any], workspace: URL) -> String {
        guard let action = arguments["action"] as? String else {
            return "Missing action."
        }

        do {
            switch action {
            case "list_devices":
                let devices = try AndroidEmulatorService.devices()
                guard !devices.isEmpty else { return "No Android devices or emulators found." }
                return devices.map { device in
                    let kind = device.isEmulator ? "Emulator" : "Connected device"
                    let status = device.isOnline ? "online" : device.state
                    return "\(kind) — \(device.name) — \(status) — serial: \(device.id)"
                }.joined(separator: "\n")

            case "list_avds":
                let avds = try AndroidEmulatorService.avds()
                guard !avds.isEmpty else { return "No Android Virtual Devices (AVDs) configured." }
                return avds.joined(separator: "\n")

            case "boot":
                guard let avd = arguments["avd_name"] as? String, !avd.isEmpty else {
                    return "Missing avd_name for boot action."
                }
                try AndroidEmulatorService.boot(avdName: avd)
                return "Booting Android emulator '\(avd)' in background."

            case "shutdown":
                let serial = try resolveDevice(arguments["device"] as? String)
                try AndroidEmulatorService.shutdown(serial: serial)
                return "Shut down emulator \(serial)."

            case "screenshot":
                let serial = try resolveDevice(arguments["device"] as? String)
                let relative = arguments["path"] as? String ?? "android.png"
                let destination = try resolveInWorkspace(relative, workspace: workspace)
                let data = try AndroidEmulatorService.screenshot(serial: serial)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
                return "Saved Android screenshot to \(relative) (\(data.count) bytes)."

            case "install":
                let serial = try resolveDevice(arguments["device"] as? String)
                guard let apk = arguments["apk_path"] as? String else { return "Missing apk_path." }
                let resolved = try resolveInWorkspace(apk, workspace: workspace, allowAbsolute: true)
                try AndroidEmulatorService.install(serial: serial, apkPath: resolved.path)
                return "Installed \(apk) onto \(serial)."

            case "launch":
                let serial = try resolveDevice(arguments["device"] as? String)
                guard let comp = arguments["component"] as? String else { return "Missing component (e.g. com.example/.MainActivity)." }
                let out = try AndroidEmulatorService.launch(serial: serial, component: comp)
                return out.isEmpty ? "Launched \(comp) on \(serial)." : out

            case "terminate":
                let serial = try resolveDevice(arguments["device"] as? String)
                guard let pkg = arguments["package"] as? String else { return "Missing package." }
                try AndroidEmulatorService.terminate(serial: serial, package: pkg)
                return "Terminated \(pkg) on \(serial)."

            case "open_url":
                let serial = try resolveDevice(arguments["device"] as? String)
                guard let url = arguments["url"] as? String else { return "Missing url." }
                try AndroidEmulatorService.openURL(serial: serial, url: url)
                return "Opened URL on \(serial)."

            case "tap":
                let serial = try resolveDevice(arguments["device"] as? String)
                guard let x = arguments["x"] as? Int, let y = arguments["y"] as? Int else {
                    return "Missing x or y coordinate for tap."
                }
                try AndroidEmulatorService.tap(serial: serial, x: x, y: y)
                return "Tapped at (\(x), \(y)) on \(serial)."

            case "text":
                let serial = try resolveDevice(arguments["device"] as? String)
                guard let text = arguments["text"] as? String else { return "Missing text." }
                try AndroidEmulatorService.textInput(serial: serial, text: text)
                return "Entered text into \(serial)."

            case "swipe":
                let serial = try resolveDevice(arguments["device"] as? String)
                guard let x1 = arguments["x1"] as? Int, let y1 = arguments["y1"] as? Int,
                      let x2 = arguments["x2"] as? Int, let y2 = arguments["y2"] as? Int else {
                    return "Missing coordinates for swipe (x1, y1, x2, y2)."
                }
                try AndroidEmulatorService.swipe(serial: serial, x1: x1, y1: y1, x2: x2, y2: y2)
                return "Swiped on \(serial)."

            case "logcat":
                let serial = try resolveDevice(arguments["device"] as? String)
                let logs = try AndroidEmulatorService.logcat(serial: serial)
                return logs.isEmpty ? "No error logs found in logcat." : logs

            default:
                return "Unknown android_emulator action: \(action)"
            }
        } catch {
            return "android_emulator error: \(error.localizedDescription)"
        }
    }

    private static func resolveDevice(_ candidate: String?) throws -> String {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty && trimmed.lowercased() != "first" {
            return trimmed
        }
        let devices = try AndroidEmulatorService.devices()
        guard let first = devices.first(where: { $0.isEmulator && $0.isOnline })
            ?? devices.first(where: \.isOnline) else {
            throw AndroidEmulatorError("No connected Android device or running emulator found.")
        }
        return first.id
    }

    private static func resolveInWorkspace(
        _ path: String,
        workspace: URL,
        allowAbsolute: Bool = false
    ) throws -> URL {
        guard let url = WorkspacePathResolver.resolve(path, workspace: workspace, allowAbsolute: allowAbsolute) else {
            throw AndroidEmulatorError("Path outside workspace: \(path)")
        }
        return url
    }
}
