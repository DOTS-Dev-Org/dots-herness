// Copyright (c) 2026 DOTS
// Small, workspace-scoped tools for the native agent loop.

import Foundation
import HarnessPluginKit

public enum WorkspaceTools {
    public static let definitions: [AgentToolDefinition] = workspaceDefinitions + SimulatorTools.definitions
    public static let readOnlyDefinitions: [AgentToolDefinition] = workspaceDefinitions.filter {
        $0.name == "list_files" || $0.name == "read_file"
    }

    public static func isReadOnly(_ name: String) -> Bool {
        name == "list_files" || name == "read_file"
    }

    static let workspaceDefinitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: "list_files",
            description: "List files and directories inside the current workspace.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path. Use . for the workspace root."),
                    ]),
                ]),
            ])
        ),
        AgentToolDefinition(
            name: "read_file",
            description: "Read a UTF-8 text file inside the current workspace.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path to the file."),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
        AgentToolDefinition(
            name: "write_file",
            description: "Create or replace a UTF-8 text file inside the current workspace.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path to the file."),
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("Complete file contents."),
                    ]),
                ]),
                "required": .array([.string("path"), .string("content")]),
            ])
        ),
        AgentToolDefinition(
            name: "run_command",
            description: "Run a shell command with the workspace as its current directory.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("Command to run with /bin/zsh."),
                    ]),
                ]),
                "required": .array([.string("command")]),
            ])
        ),
    ]

    public static func execute(
        _ call: AgentToolCall,
        workspace: URL
    ) -> String {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AppCopy.format("tool.invalidArguments", call.name)
        }

        do {
            switch call.name {
            case "list_files":
                let path = object["path"] as? String ?? "."
                return try listFiles(at: path, workspace: workspace)
            case "read_file":
                guard let path = object["path"] as? String else { return AppCopy.text("tool.missingPath") }
                return try readFile(at: path, workspace: workspace)
            case "write_file":
                guard let path = object["path"] as? String,
                      let content = object["content"] as? String else {
                    return AppCopy.text("tool.missingPathOrContent")
                }
                return try writeFile(at: path, content: content, workspace: workspace)
            case "run_command":
                guard let command = object["command"] as? String else { return AppCopy.text("tool.missingCommand") }
                return try run(command: command, workspace: workspace)
            case "ios_simulator":
                return SimulatorTools.execute(object, workspace: workspace)
            default:
                return AppCopy.format("tool.unknown", call.name)
            }
        } catch {
            return AppCopy.format("tool.error", error.localizedDescription)
        }
    }

    private static func listFiles(at path: String, workspace: URL) throws -> String {
        let directory = try resolve(path, workspace: workspace)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return AppCopy.format("tool.notDirectory", path)
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsPackageDescendants]
        )
        let names = try urls
            .filter { $0.lastPathComponent != ".mem" }
            .filter { try $0.resourceValues(forKeys: [.isHiddenKey]).isHidden != true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(200)
            .map { url -> String in
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                return isDirectory ? "\(url.lastPathComponent)/" : url.lastPathComponent
            }
        return names.isEmpty ? AppCopy.text("tool.empty") : names.joined(separator: "\n")
    }

    private static func readFile(at path: String, workspace: URL) throws -> String {
        let file = try resolve(path, workspace: workspace)
        let data = try Data(contentsOf: file)
        let limited = data.prefix(200_000)
        guard let text = String(data: limited, encoding: .utf8) else {
            return AppCopy.format("tool.notUTF8", path)
        }
        if data.count > limited.count {
            return text + "\n\n" + AppCopy.text("tool.truncated")
        }
        return text
    }

    private static func writeFile(at path: String, content: String, workspace: URL) throws -> String {
        let file = try resolve(path, workspace: workspace)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.data(using: .utf8)?.write(to: file, options: .atomic)
        return AppCopy.format("tool.wrote", relativePath(file, workspace: workspace), content.utf8.count)
    }

    private static func run(command: String, workspace: URL) throws -> String {
        if command.range(of: #"(?:^|[\s/])\.mem(?:[\s/]|$)"#, options: .regularExpression) != nil {
            throw NativeAgentError(AppCopy.text("tool.pathUnavailable"))
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workspace
        process.standardOutput = output
        process.standardError = output

        // Drain the pipe concurrently: a poll-then-read approach deadlocks once the
        // child fills the ~64KB pipe buffer and blocks on write before it can exit.
        let sink = OutputSink()
        let reader = output.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { sink.append(chunk) }
        }
        try process.run()

        let deadline = Date().addingTimeInterval(45)
        while process.isRunning, Date() < deadline {
            try awaitRunLoop()
        }
        if process.isRunning {
            process.terminate()
            reader.readabilityHandler = nil
            return AppCopy.text("tool.timedOut")
        }
        process.waitUntilExit()
        reader.readabilityHandler = nil

        let data = sink.drain()
        let text = String(data: data.prefix(100_000), encoding: .utf8) ?? AppCopy.text("tool.binaryOutput")
        let suffix = process.terminationStatus == 0
            ? ""
            : "\n" + AppCopy.format("tool.exitStatus", process.terminationStatus)
        return text.isEmpty ? AppCopy.text("tool.noOutput") + suffix : text + suffix
    }

    private static func awaitRunLoop() throws {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private static func resolve(_ path: String, workspace: URL) throws -> URL {
        let relative = path.isEmpty ? "." : path
        // resolvingSymlinksInPath() is required: standardizedFileURL only normalizes
        // syntax, so a symlink placed inside the workspace would slip past the prefix
        // check (e.g. workspace/escape -> /etc, then read escape/hosts).
        let url = URL(fileURLWithPath: relative, relativeTo: workspace).standardizedFileURL.resolvingSymlinksInPath()
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(rootPath) else {
            throw NativeAgentError(AppCopy.format("tool.pathOutside", path))
        }
        let memoryRoot = root.appendingPathComponent(".mem").path
        guard url.path != memoryRoot && !url.path.hasPrefix(memoryRoot + "/") else {
            throw NativeAgentError(AppCopy.text("tool.pathUnavailable"))
        }
        return url
    }

    private static func relativePath(_ url: URL, workspace: URL) -> String {
        let root = workspace.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root ? "." : String(path.dropFirst(root.count + 1))
    }

    /// Thread-safe accumulator for a pipe's readabilityHandler callbacks.
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        func drain() -> Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }
}
