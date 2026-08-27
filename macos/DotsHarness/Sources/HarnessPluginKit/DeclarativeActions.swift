// Copyright (c) 2026 DOTS
// Executes declarative ToolAction payloads. No plugin code involved.

import Foundation

public enum DeclarativeShell {
    public static func subst(_ s: String, _ args: [String: String]) -> String {
        var out = s
        for (key, value) in args {
            out = out.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return out
    }

    /// Runs argv through `/usr/bin/env`. Caller must have gated this on trust.
    public static func shell(_ argv: [String], _ args: [String: String]) throws -> String {
        guard !argv.isEmpty else { throw PluginError.applyFailed("shell action needs a command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv.map { subst($0, args) }
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
