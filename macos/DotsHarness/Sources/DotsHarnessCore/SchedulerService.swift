// Copyright (c) 2026 DOTS
// Installs/removes the background scheduler as a per-user launchd LaunchAgent.

import Foundation

public enum SchedulerService {
    public static let label = "com.dots.harness.scheduler"

    public static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Best-effort path to the bundled `DotsHarnessScheduler` executable. Inside a
    /// packaged `.app` it sits next to the main binary; in a dev build it is a
    /// sibling of the running executable in `.build/<config>/`.
    public static func defaultExecutableURL() -> URL {
        let mainExe = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "DotsHarness")
        return mainExe.deletingLastPathComponent().appendingPathComponent("DotsHarnessScheduler")
    }

    public static func plistData(executableURL: URL) -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
        ]
        return (try? PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )) ?? Data()
    }

    /// Writes the plist and loads it into the current GUI session.
    @discardableResult
    public static func install(executableURL: URL = defaultExecutableURL()) throws -> URL {
        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plistData(executableURL: executableURL).write(to: url, options: .atomic)
        // Reload so an updated executable path takes effect.
        runLaunchctl(["bootout", domainTarget()])
        runLaunchctl(["bootstrap", domainTarget(), url.path])
        return url
    }

    public static func uninstall() {
        runLaunchctl(["bootout", "\(domainTarget())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func domainTarget() -> String {
        "gui/\(getuid())"
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
