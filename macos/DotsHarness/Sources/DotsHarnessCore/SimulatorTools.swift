// Copyright (c) 2026 DOTS
// Agent-facing control of the iOS simulator, backed by `xcrun simctl`.

import Foundation
import HarnessPluginKit

public enum SimulatorTools {
    public static let definitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: "ios_simulator",
            description: """
            Control the iOS Simulator: list devices, boot or shut one down, install and launch an \
            app bundle, open a URL, switch appearance, or capture a screenshot into the workspace.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("list_devices"),
                            .string("boot"),
                            .string("shutdown"),
                            .string("screenshot"),
                            .string("open_url"),
                            .string("install"),
                            .string("launch"),
                            .string("terminate"),
                            .string("appearance"),
                            .string("list_apps"),
                        ]),
                        "description": .string("Operation to perform."),
                    ]),
                    "device": .object([
                        "type": .string("string"),
                        "description": .string("Device UDID, or 'booted' for the running device. Defaults to 'booted'."),
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("Bundle identifier for launch/terminate."),
                    ]),
                    "app_path": .object([
                        "type": .string("string"),
                        "description": .string("Path to a built .app bundle, relative to the workspace or absolute."),
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("URL to open on the device."),
                    ]),
                    "appearance": .object([
                        "type": .string("string"),
                        "enum": .array([.string("light"), .string("dark")]),
                        "description": .string("Interface style for the appearance action."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Screenshot destination, relative to the workspace. Defaults to simulator.png."),
                    ]),
                ]),
                "required": .array([.string("action")]),
            ])
        ),
    ]

    public static func execute(_ arguments: [String: Any], workspace: URL) -> String {
        guard let action = arguments["action"] as? String else {
            return AppCopy.text("simulator.tool.missingAction")
        }
        let device = (arguments["device"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "booted"

        do {
            switch action {
            case "list_devices":
                let devices = try SimulatorService.devices()
                guard !devices.isEmpty else { return AppCopy.text("simulator.tool.noDevices") }
                return devices
                    .map { "\($0.name) — \($0.runtime) — \($0.state) — \($0.id)" }
                    .joined(separator: "\n")

            case "boot":
                try SimulatorService.boot(try resolveDevice(device))
                return AppCopy.text("simulator.done")

            case "shutdown":
                try SimulatorService.shutdown(try resolveDevice(device))
                return AppCopy.text("simulator.done")

            case "screenshot":
                let relative = arguments["path"] as? String ?? "simulator.png"
                let destination = try resolveInWorkspace(relative, workspace: workspace)
                let data = try SimulatorService.screenshot(try resolveDevice(device))
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
                return AppCopy.format("simulator.savedScreenshot", relative)

            case "open_url":
                guard let url = arguments["url"] as? String else { return AppCopy.text("simulator.tool.missingURL") }
                try SimulatorService.openURL(try resolveDevice(device), url: url)
                return AppCopy.text("simulator.done")

            case "install":
                guard let path = arguments["app_path"] as? String else { return AppCopy.text("simulator.tool.missingApp") }
                let bundle = try resolveInWorkspace(path, workspace: workspace, allowAbsolute: true)
                try SimulatorService.install(try resolveDevice(device), appPath: bundle.path)
                return AppCopy.text("simulator.done")

            case "launch":
                guard let bundleID = arguments["bundle_id"] as? String else {
                    return AppCopy.text("simulator.tool.missingBundleID")
                }
                let output = try SimulatorService.launch(try resolveDevice(device), bundleID: bundleID)
                return output.isEmpty ? AppCopy.text("simulator.done") : output

            case "terminate":
                guard let bundleID = arguments["bundle_id"] as? String else {
                    return AppCopy.text("simulator.tool.missingBundleID")
                }
                try SimulatorService.terminate(try resolveDevice(device), bundleID: bundleID)
                return AppCopy.text("simulator.done")

            case "appearance":
                let style = arguments["appearance"] as? String ?? "light"
                try SimulatorService.setAppearance(try resolveDevice(device), dark: style == "dark")
                return AppCopy.text("simulator.done")

            case "list_apps":
                let apps = try SimulatorService.userApps(try resolveDevice(device))
                return apps.isEmpty ? AppCopy.text("tool.empty") : apps.joined(separator: "\n")

            default:
                return AppCopy.format("tool.unknown", action)
            }
        } catch {
            return AppCopy.format("simulator.error", error.localizedDescription)
        }
    }

    /// `simctl` accepts "booted", but fails opaquely when nothing is booted.
    private static func resolveDevice(_ device: String) throws -> String {
        guard device.caseInsensitiveCompare("booted") == .orderedSame else { return device }
        let devices = try SimulatorService.devices()
        guard let booted = devices.first(where: \.isBooted) else {
            throw SimulatorError(AppCopy.text("simulator.tool.noBootedDevice"))
        }
        return booted.id
    }

    private static func resolveInWorkspace(
        _ path: String,
        workspace: URL,
        allowAbsolute: Bool = false
    ) throws -> URL {
        if allowAbsolute, path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        // appendingPathComponent, not URL(fileURLWithPath:relativeTo:): the latter
        // drops the last base component unless the base is a directory URL.
        // resolvingSymlinksInPath keeps /var and /private/var comparable.
        let url = workspace.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.hasSuffix("/") ? root : root + "/"
        guard url.path == root || url.path.hasPrefix(rootPath) else {
            throw SimulatorError(AppCopy.format("tool.pathOutside", path))
        }
        return url
    }
}
