// Copyright (c) 2026 DOTS
// The single place the app spawns /usr/bin/ssh. Every remote command, probe
// and terminal is built from the argument vectors below.

import Foundation
import PluginRuntime

public enum SSHRunner {
    public static let executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    // MARK: - Connection multiplexing

    /// One authenticated master connection is reused by every later command,
    /// so a tool call costs a round trip instead of a full handshake.
    /// `%C` is ssh's hash of (host, port, user) — a literal path would blow the
    /// 104-byte `sun_path` limit inside Application Support.
    static func controlDirectory() -> URL {
        let directory = SupportPaths.default().root.appendingPathComponent("ssh", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    static func controlPath() -> String {
        controlDirectory().appendingPathComponent("cm-%C").path
    }

    /// ssh's own options, common to every invocation.
    ///
    /// `BatchMode=yes` on the non-interactive path is load-bearing: without it
    /// a host that wants a password blocks on a prompt nobody can answer and
    /// the caller only finds out when its timeout fires.
    /// `StrictHostKeyChecking=yes` is never relaxed — a new host key is
    /// accepted through the enrollment flow, where a human sees its
    /// fingerprint, and nowhere else.
    public static func options(interactive: Bool) -> [String] {
        var options = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath())",
            "-o", "ControlPersist=120",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=yes",
        ]
        if interactive {
            options.append("-tt")
        } else {
            options.append(contentsOf: ["-o", "BatchMode=yes", "-T"])
        }
        return options
    }

    /// `ssh <options> <alias> --` with the remote command appended by the caller.
    public static func launchPrefix(alias: String, interactive: Bool) -> [String] {
        options(interactive: interactive) + [alias, "--"]
    }

    // MARK: - Remote command construction

    /// Single-quote wrapping is the only quoting a POSIX shell honours without
    /// exception: nothing inside `'…'` is expanded, and an embedded quote is
    /// closed, escaped and reopened. Every remote path and command goes
    /// through here, so this is the boundary that keeps a workspace path with
    /// `$(…)` in it from becoming a command.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `/bin/sh`, not zsh: the remote machine is frequently a Linux box where
    /// zsh is not installed. The login flag keeps the user's PATH.
    public static func remoteCommand(cwd: String, command: String) -> String {
        "cd -- \(shellQuote(cwd)) && exec /bin/sh -lc \(shellQuote(command))"
    }

    // MARK: - Execution

    public struct Output: Sendable {
        public let status: Int32
        public let text: String
        public let timedOut: Bool
    }

    /// Runs `command` in `cwd` on the host and captures merged output.
    public static func run(
        target: SSHTarget,
        command: String,
        timeout: TimeInterval = 90,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> Output {
        try spawn(
            arguments: launchPrefix(alias: target.alias, interactive: false)
                + [remoteCommand(cwd: target.remotePath, command: command)],
            timeout: timeout,
            onOutput: onOutput
        )
    }

    /// Runs a command on the host without assuming a working directory — used
    /// for probes and for browsing before a folder has been picked.
    public static func runOnHost(
        alias: String,
        command: String,
        timeout: TimeInterval = 30
    ) throws -> Output {
        try spawn(
            arguments: launchPrefix(alias: alias, interactive: false) + ["/bin/sh -lc \(shellQuote(command))"],
            timeout: timeout,
            onOutput: nil
        )
    }

    static func spawn(
        arguments: [String],
        timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> Output {
        guard isAvailable else { throw SSHError.sshUnavailable }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let sink = SSHOutputSink()
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                sink.append(chunk)
                if let text = String(data: chunk, encoding: .utf8) { onOutput?(text) }
            }
        }
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            process.waitUntilExit()
        } else {
            process.waitUntilExit()
        }
        reader.readabilityHandler = nil
        let text = String(data: sink.drain(), encoding: .utf8) ?? ""
        return Output(status: process.terminationStatus, text: text, timedOut: timedOut)
    }

    // MARK: - Probes and lifecycle

    /// Cheap "can we still reach this host and is its key what we trusted".
    public static func probe(alias: String) -> Result<Void, SSHError> {
        guard isAvailable else { return .failure(.sshUnavailable) }
        do {
            let output = try spawn(
                arguments: launchPrefix(alias: alias, interactive: false) + ["true"],
                timeout: 20,
                onOutput: nil
            )
            if output.timedOut { return .failure(.notReachable(alias)) }
            if output.status == 0 { return .success(()) }
            return .failure(classify(output.text, alias: alias))
        } catch {
            return .failure(.notReachable(alias))
        }
    }

    public static func directoryExists(target: SSHTarget) -> Bool {
        guard let output = try? runOnHost(
            alias: target.alias,
            command: "test -d \(shellQuote(target.remotePath))"
        ) else { return false }
        return output.status == 0 && !output.timedOut
    }

    /// Expands `~` and relative input the way the remote login shell would, so
    /// the stored path is stable across sessions.
    public static func resolveDirectory(alias: String, path: String) -> String? {
        let probe = "cd -- \(shellQuote(path)) >/dev/null 2>&1 && pwd -P"
        let expanded = path.hasPrefix("~")
            ? "cd \(path.replacingOccurrences(of: "'", with: "")) >/dev/null 2>&1 && pwd -P"
            : probe
        guard let output = try? runOnHost(alias: alias, command: expanded), output.status == 0 else { return nil }
        let resolved = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? nil : resolved
    }

    public static func listDirectories(alias: String, path: String) -> [String] {
        let command = "cd -- \(shellQuote(path)) && ls -1Ap"
        guard let output = try? runOnHost(alias: alias, command: command), output.status == 0 else { return [] }
        return output.text
            .components(separatedBy: .newlines)
            .filter { $0.hasSuffix("/") }
            .map { String($0.dropLast()) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Tears the multiplexed master down — after removing a host, leaving
    /// remote mode, or a connection that went bad.
    public static func closeMaster(alias: String) {
        guard isAvailable else { return }
        _ = try? spawn(
            arguments: ["-o", "ControlPath=\(controlPath())", "-O", "exit", alias],
            timeout: 5,
            onOutput: nil
        )
    }

    /// Maps ssh's stderr onto the errors the UI can act on. The host-key case
    /// matters most: it is the one failure a user must never click past.
    public static func classify(_ text: String, alias: String) -> SSHError {
        let lower = text.lowercased()
        if lower.contains("remote host identification has changed")
            || lower.contains("host key verification failed") {
            return .hostKeyChanged(alias)
        }
        if lower.contains("permission denied") || lower.contains("too many authentication failures") {
            return .authFailed(alias)
        }
        if lower.contains("could not resolve")
            || lower.contains("connection refused")
            || lower.contains("connection closed")
            || lower.contains("connection timed out")
            || lower.contains("operation timed out")
            || lower.contains("no route to host")
            || lower.contains("network is unreachable") {
            return .notReachable(alias)
        }
        return .notReachable(alias)
    }

    /// True when a failed remote command failed because the transport dropped,
    /// not because the command itself did. Told apart so the agent does not go
    /// hunting for a bug in code that never ran.
    public static func isTransportFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("connection to ") && lower.contains("closed")
            || lower.contains("broken pipe")
            || lower.contains("connection reset by peer")
            || lower.contains("ssh: connect to host")
            || lower.contains("control socket connect")
    }
}

/// Serialises pipe chunks arriving on the reader queue.
final class SSHOutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func drain() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
