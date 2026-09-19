// Copyright (c) 2026 DOTS
// Project-scoped interactive shells for the native macOS app.

import Combine
import Darwin
import Foundation

@MainActor
public final class TerminalSession: ObservableObject, Identifiable {
    public let id: UUID
    public let workspacePath: String
    public let sandboxPolicy: SandboxExecutionPolicy?
    /// Set when this shell lives on another machine: the session then runs
    /// `ssh` on the pty instead of a local login shell, and `workspacePath` is
    /// the folder on that machine rather than a path on this disk.
    public let remoteTarget: SSHTarget?
    public var executionPolicy: SandboxExecutionPolicy? { sandboxPolicy }

    @Published public private(set) var output = ""
    @Published public private(set) var isRunning = false

    private var masterHandle: FileHandle?
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var generation = UUID()

    public init(
        workspacePath: String,
        sandboxPolicy: SandboxExecutionPolicy? = nil,
        remoteTarget: SSHTarget? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.workspacePath = workspacePath
        self.sandboxPolicy = remoteTarget == nil ? sandboxPolicy : nil
        self.remoteTarget = remoteTarget
    }

    public convenience init(remoteTarget: SSHTarget, id: UUID = UUID()) {
        self.init(
            workspacePath: remoteTarget.identity,
            sandboxPolicy: nil,
            remoteTarget: remoteTarget,
            id: id
        )
    }

    public convenience init(
        workspacePath: String,
        executionPolicy: SandboxExecutionPolicy?,
        id: UUID = UUID()
    ) {
        self.init(workspacePath: workspacePath, sandboxPolicy: executionPolicy, id: id)
    }

    public func start() {
        stop()
        output = ""

        let directory = URL(fileURLWithPath: workspacePath, isDirectory: true)
        if remoteTarget == nil {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                output = AppCopy.format(
                    "conversation.terminalStartError",
                    "Working directory does not exist: \(workspacePath)"
                ) + "\n"
                return
            }
        }

        let launchExecutable: String
        let launchArguments: [String]
        do {
            if let remoteTarget {
                guard SSHRunner.isAvailable else { throw SSHError.sshUnavailable }
                // No pre-flight probe here: it would block the main thread for
                // as long as the connect timeout. ssh writes its own failure to
                // the pty, which is exactly what a terminal should show.
                launchExecutable = SSHRunner.executableURL.path
                // `$SHELL -l` here, not the tools' `/bin/sh`: an interactive
                // shell should be the one the user actually set up remotely.
                launchArguments = ["ssh"]
                    + SSHRunner.launchPrefix(alias: remoteTarget.alias, interactive: true)
                    + ["cd -- \(SSHRunner.shellQuote(remoteTarget.remotePath)) && exec ${SHELL:-/bin/sh} -l"]
            } else if let sandboxPolicy {
                guard SandboxProfile.canonicalURL(directory).path == sandboxPolicy.workspaceURL.path else {
                    throw NativeAgentError("Sandbox policy workspace does not match the terminal workspace.")
                }
                launchExecutable = SandboxProfile.executableURL.path
                launchArguments = ["sandbox-exec"] + (try SandboxProfile.arguments(
                    executable: "/bin/zsh",
                    arguments: ["-l", "-i"],
                    policy: sandboxPolicy
                ))
            } else {
                launchExecutable = "/bin/zsh"
                launchArguments = ["zsh", "-l", "-i"]
            }
        } catch {
            output = AppCopy.format(
                "conversation.terminalStartError",
                error.localizedDescription
            ) + "\n"
            return
        }

        let currentGeneration = UUID()
        generation = currentGeneration
        let remoteWorkspace = remoteTarget

        var master: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let child = forkpty(&master, nil, nil, &size)
        guard child >= 0 else {
            output = AppCopy.format(
                "conversation.terminalStartError",
                String(cString: strerror(errno))
            ) + "\n"
            return
        }

        if child == 0 {
            // forkpty gives zsh a controlling terminal. The shell therefore
            // keeps its cwd, job control, stdin, signals, and interactive
            // programs instead of evaluating isolated lines through a pipe.
            // ssh does the cd on the far side; there is no such directory here.
            if remoteWorkspace == nil {
                guard chdir(directory.path) == 0 else { _exit(126) }
            }
            setenv("TERM", "xterm-256color", 1)
            setenv("TERM_PROGRAM", "DotsHarness", 1)
            setenv("COLORTERM", "truecolor", 1)
            if let sandboxPolicy {
                for (key, value) in SandboxProfile.cacheEnvironment(workspaceURL: sandboxPolicy.workspaceURL) {
                    setenv(key, value, 1)
                }
            }

            let executable = strdup(launchExecutable)!
            var arguments: [UnsafeMutablePointer<CChar>?] = launchArguments.map { strdup($0)! }
            arguments.append(nil)
            arguments.withUnsafeMutableBufferPointer { buffer in
                _ = execv(executable, buffer.baseAddress)
            }
            _exit(127)
        }

        let handle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        masterFD = master
        masterHandle = handle
        childPID = child
        isRunning = true

        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.append(data, generation: currentGeneration)
            }
        }

        let waiter = Task.detached(priority: .utility) {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
            return status
        }
        Task { @MainActor [weak self] in
            let status = await waiter.value
            self?.finish(child: child, generation: currentGeneration, status: status)
        }
    }

    public func send(_ command: String) {
        sendInput(command + "\n")
    }

    public func sendInput(_ input: String) {
        guard isRunning, let masterHandle, !input.isEmpty else { return }
        guard let data = input.data(using: .utf8) else { return }
        do {
            try masterHandle.write(contentsOf: data)
        } catch {
            append("\n" + AppCopy.format("conversation.terminalStartError", error.localizedDescription) + "\n")
        }
    }

    public func resize(rows: UInt16, columns: UInt16) {
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &size)
    }

    public func stop() {
        generation = UUID()
        let child = childPID
        childPID = 0
        isRunning = false

        if child > 0 {
            _ = kill(-child, SIGHUP)
            _ = kill(child, SIGTERM)
        }

        masterHandle?.readabilityHandler = nil
        try? masterHandle?.close()
        masterHandle = nil
        masterFD = -1
    }

    private func append(_ data: Data, generation: UUID) {
        guard self.generation == generation else { return }
        append(String(decoding: data, as: UTF8.self), generation: generation)
    }

    private func append(_ text: String, generation: UUID? = nil) {
        if let generation, self.generation != generation { return }
        guard !text.isEmpty else { return }
        output.append(Self.renderableText(text))
        output = Self.transcriptText(output)
        if output.count > 200_000 {
            output = String(output.suffix(180_000))
        }
    }

    private static func renderableText(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var result = String.UnicodeScalarView()
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let scalar = scalars[index]
            let value = scalar.value
            index = scalars.index(after: index)

            guard value == 0x1B else {
                if value == 0x0D {
                    result.append(scalar)
                } else if value == 0x08 {
                    result.append(scalar)
                } else if value == 0x09 || value == 0x0A || value >= 0x20 {
                    result.append(scalar)
                }
                continue
            }

            guard index < scalars.endIndex else { break }
            let control = scalars[index].value
            index = scalars.index(after: index)
            if control == 0x5B { // CSI: ESC [ ... final byte
                while index < scalars.endIndex {
                    let value = scalars[index].value
                    index = scalars.index(after: index)
                    if (0x40...0x7E).contains(value) { break }
                }
            } else if control == 0x5D { // OSC: ESC ] ... BEL or ST
                while index < scalars.endIndex {
                    let value = scalars[index].value
                    index = scalars.index(after: index)
                    if value == 0x07 { break }
                    if value == 0x1B, index < scalars.endIndex, scalars[index].value == 0x5C {
                        index = scalars.index(after: index)
                        break
                    }
                }
            }
        }

        return String(result)
    }

    private static func transcriptText(_ raw: String) -> String {
        var result = String.UnicodeScalarView()
        let scalars = Array(raw.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0x0D:
                if index + 1 >= scalars.count || scalars[index + 1].value != 0x0A {
                    while let last = result.last, last.value != 0x0A { result.removeLast() }
                }
            case 0x08:
                if !result.isEmpty { result.removeLast() }
            default:
                result.append(scalar)
            }
        }

        return String(result).components(separatedBy: "\n").map { line in
            var line = line
            while line.last == " " || line.last == "\t" { line.removeLast() }
            return line
        }.joined(separator: "\n")
    }

    private func finish(child: pid_t, generation: UUID, status: Int32) {
        guard self.generation == generation, childPID == child else { return }
        masterHandle?.readabilityHandler = nil
        try? masterHandle?.close()
        masterHandle = nil
        masterFD = -1
        childPID = 0
        isRunning = false
    }
}

@MainActor
public final class TerminalManager: ObservableObject {
    @Published private var sessionsByWorkspace: [String: [TerminalSession]] = [:]
    private var selectedSessionIDs: [String: UUID] = [:]

    public init() {}

    public func sessions(for workspacePath: String) -> [TerminalSession] {
        guard let key = Self.normalizedWorkspacePath(workspacePath) else { return [] }
        return sessionsByWorkspace[key] ?? []
    }

    public func selectedSession(for workspacePath: String) -> TerminalSession? {
        let sessions = sessions(for: workspacePath)
        guard !sessions.isEmpty else { return nil }
        if let selectedID = selectedSessionIDs[Self.normalizedWorkspacePath(workspacePath) ?? ""],
           let selected = sessions.first(where: { $0.id == selectedID }) {
            return selected
        }
        return sessions.first
    }

    @discardableResult
    public func openSession(
        for workspacePath: String,
        executionPolicy: SandboxExecutionPolicy? = nil,
        remoteTarget: SSHTarget? = nil
    ) -> TerminalSession? {
        guard let key = Self.normalizedWorkspacePath(workspacePath) else { return nil }
        if let remoteTarget, remoteTarget.identity != key { return nil }
        if remoteTarget == nil, let executionPolicy, executionPolicy.workspaceURL.path != key { return nil }
        let session = remoteTarget.map { TerminalSession(remoteTarget: $0) }
            ?? TerminalSession(workspacePath: key, sandboxPolicy: executionPolicy)
        sessionsByWorkspace[key, default: []].append(session)
        selectedSessionIDs[key] = session.id
        session.start()
        return session
    }

    /// Compatibility label for callers written against the initial Layer 2 API.
    @discardableResult
    public func openSession(
        for workspacePath: String,
        sandboxPolicy: SandboxExecutionPolicy?
    ) -> TerminalSession? {
        openSession(for: workspacePath, executionPolicy: sandboxPolicy)
    }

    public func selectSession(_ sessionID: UUID, for workspacePath: String) {
        guard let key = Self.normalizedWorkspacePath(workspacePath),
              sessionsByWorkspace[key]?.contains(where: { $0.id == sessionID }) == true else { return }
        selectedSessionIDs[key] = sessionID
    }

    public func closeSession(_ session: TerminalSession, for workspacePath: String) {
        guard let key = Self.normalizedWorkspacePath(workspacePath),
              var sessions = sessionsByWorkspace[key] else { return }
        session.stop()
        sessions.removeAll { $0.id == session.id }
        if sessions.isEmpty {
            sessionsByWorkspace[key] = nil
            selectedSessionIDs[key] = nil
        } else {
            sessionsByWorkspace[key] = sessions
            if selectedSessionIDs[key] == session.id {
                selectedSessionIDs[key] = sessions.last?.id
            }
        }
    }

    public func stopAll() {
        sessionsByWorkspace.values.flatMap { $0 }.forEach { $0.stop() }
        sessionsByWorkspace.removeAll()
        selectedSessionIDs.removeAll()
    }

    public func stopSessions(for workspacePath: String) {
        guard let key = Self.normalizedWorkspacePath(workspacePath) else { return }
        sessionsByWorkspace[key]?.forEach { $0.stop() }
        sessionsByWorkspace[key] = nil
        selectedSessionIDs[key] = nil
    }

    private static func normalizedWorkspacePath(_ path: String) -> String? {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // A remote workspace key ("ssh://alias/path") names a folder on another
        // machine; there is nothing here to canonicalise or stat.
        if path.hasPrefix("ssh://") { return path }
        let url = SandboxProfile.canonicalURL(URL(fileURLWithPath: path, isDirectory: true))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url.path
    }
}
