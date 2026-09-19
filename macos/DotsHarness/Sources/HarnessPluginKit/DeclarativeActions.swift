// Copyright (c) 2026 DOTS
// Executes declarative ToolAction payloads. No plugin code involved.

import Foundation

/// Process-launch policy for a `shell` plugin action, mirroring the agent's
/// own `run_command` sandbox. Defined here (not in DotsHarnessCore, which
/// this package cannot import) so `DeclarativeShell` — the plugin bypass a
/// sandboxed agent could otherwise reach for — stays inside the same jail.
public struct ShellSandbox: Sendable {
    public let executableURL: URL
    /// `sandbox-exec`'s own arguments (the `-D ... -p <profile>` block), with
    /// the caller's real executable and arguments appended after it.
    public let argumentsPrefix: [String]
    public let workspaceURL: URL
    public let environment: [String: String]

    public init(executableURL: URL, argumentsPrefix: [String], workspaceURL: URL, environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.argumentsPrefix = argumentsPrefix
        self.workspaceURL = workspaceURL
        self.environment = environment
    }
}

public enum DeclarativeShell {
    private static let lock = NSLock()
    // Guarded exclusively by `lock`; accessed only through the `activeSandbox`
    // computed property below.
    nonisolated(unsafe) private static var _activeSandbox: ShellSandbox?

    /// Set by the host whenever the agent's sandbox changes (nil when no
    /// sandbox is active). Guarded because plugin tool calls run off the main
    /// actor.
    public static var activeSandbox: ShellSandbox? {
        get { lock.withLock { _activeSandbox } }
        set { lock.withLock { _activeSandbox = newValue } }
    }

    public static func subst(_ s: String, _ args: [String: String]) -> String {
        var out = s
        for (key, value) in args {
            out = out.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return out
    }

    /// Runs argv through `/usr/bin/env`, or through the active sandbox's
    /// `sandbox-exec` wrapper when one is set. Caller must have gated this on
    /// trust.
    public static func shell(_ argv: [String], _ args: [String: String]) throws -> String {
        guard !argv.isEmpty else { throw PluginError.applyFailed("shell action needs a command") }
        let command = argv.map { subst($0, args) }
        let process = Process()
        let sandbox = activeSandbox
        if let sandbox {
            process.executableURL = sandbox.executableURL
            process.arguments = sandbox.argumentsPrefix + ["/usr/bin/env"] + command
            process.currentDirectoryURL = sandbox.workspaceURL
            if !sandbox.environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(sandbox.environment) { _, new in new }
            }
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 {
            throw PluginError.applyFailed("command exited \(process.terminationStatus): \(output)")
        }
        return output
    }

    public static func http(_ action: ToolAction, _ args: [String: String]) async throws -> String {
        guard let raw = action.url, let url = URL(string: subst(raw, args)) else {
            throw PluginError.applyFailed("http action needs a url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = action.method ?? "GET"
        if let body = action.body { request.httpBody = Data(subst(body, args).utf8) }
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }
}
