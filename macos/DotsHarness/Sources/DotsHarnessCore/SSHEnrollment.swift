// Copyright (c) 2026 DOTS
// First-time setup for a remote work location: trust the host key, generate a
// key pair, and hand the password to ssh exactly once to install the public
// key. After this the app authenticates with the key and never needs the
// password again.

import Darwin
import Foundation

public enum SSHEnrollment {
    public static let keyName = "dots_harness_ed25519"

    public struct HostKeyScan: Sendable {
        /// Raw `known_hosts` lines as ssh-keyscan produced them.
        public let lines: [String]
        /// SHA256 fingerprints to show the user before anything is trusted.
        public let fingerprints: [String]
    }

    public struct Result: Sendable {
        public let host: SSHHost
        public let publicKey: String
    }

    static var sshDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)
    }

    static var privateKeyURL: URL { sshDirectory.appendingPathComponent(keyName) }
    static var publicKeyURL: URL { sshDirectory.appendingPathComponent(keyName + ".pub") }
    static var knownHostsURL: URL { sshDirectory.appendingPathComponent("known_hosts") }

    /// `~/.ssh/<key>` rather than an absolute path: the config stays portable
    /// and readable next to whatever the user wrote by hand.
    public static var identityFileReference: String { "~/.ssh/\(keyName)" }

    // MARK: - Key material

    @discardableResult
    public static func ensureKeyPair() throws -> String {
        try ensureSSHDirectory()
        if FileManager.default.fileExists(atPath: publicKeyURL.path),
           let existing = try? String(contentsOf: publicKeyURL, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A stale private key with no public half would make ssh-keygen refuse.
        if FileManager.default.fileExists(atPath: privateKeyURL.path) {
            try? FileManager.default.removeItem(at: privateKeyURL)
        }
        let comment = "dotsharness@\(Host.current().localizedName ?? "mac")"
        let result = try runTool(
            "/usr/bin/ssh-keygen",
            ["-t", "ed25519", "-N", "", "-C", comment, "-f", privateKeyURL.path]
        )
        guard result.status == 0 else {
            throw SSHError.configWriteFailed(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let key = (try? String(contentsOf: publicKeyURL, encoding: .utf8)) ?? ""
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SSHError.configWriteFailed(publicKeyURL.path) }
        return trimmed
    }

    public static func publicKey() -> String? {
        guard let key = try? String(contentsOf: publicKeyURL, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Host key

    /// Fetches the host's public keys so the user can confirm the fingerprint.
    /// Nothing is trusted until `trust(scan:)` is called with their approval.
    public static func scanHostKey(hostName: String, port: Int) throws -> HostKeyScan {
        let scan = try runTool(
            "/usr/bin/ssh-keyscan",
            ["-p", String(port), "-T", "5", hostName]
        )
        let lines = scan.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { throw SSHError.notReachable(hostName) }

        var fingerprints: [String] = []
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("dots-hostkey-\(UUID().uuidString)")
        try lines.joined(separator: "\n").write(to: temporary, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let printed = try runTool("/usr/bin/ssh-keygen", ["-lf", temporary.path])
        if printed.status == 0 {
            fingerprints = printed.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return HostKeyScan(lines: lines, fingerprints: fingerprints)
    }

    /// Writes the confirmed host keys into `known_hosts`. Only ever called
    /// after a human has seen the fingerprint — the app never passes
    /// `StrictHostKeyChecking=no` or `accept-new` to ssh in its place.
    public static func trust(scan: HostKeyScan) throws {
        try ensureSSHDirectory()
        var existing = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
        let known = Set(existing.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        let additions = scan.lines.filter { !known.contains($0) }
        guard !additions.isEmpty else { return }
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        existing += additions.joined(separator: "\n") + "\n"
        try existing.write(to: knownHostsURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
    }

    /// Drops a host's remembered key so a genuinely reinstalled machine can be
    /// re-trusted. Destructive enough that only an explicit user action calls it.
    public static func forgetHostKey(hostName: String, port: Int) {
        let target = port == 22 ? hostName : "[\(hostName)]:\(port)"
        _ = try? runTool("/usr/bin/ssh-keygen", ["-R", target])
    }

    // MARK: - Key installation

    /// Runs one password authentication over a pty and appends our public key
    /// to the remote `authorized_keys`.
    ///
    /// The password lives in this call and nowhere else: it is written to the
    /// pty once and the string goes out of scope when the function returns.
    /// A pty is used rather than `SSH_ASKPASS` because ssh reads passwords
    /// only from a terminal, and this avoids shipping a second helper binary.
    public static func installPublicKey(
        user: String,
        hostName: String,
        port: Int,
        password: String,
        publicKey: String
    ) throws {
        let remote = """
        umask 077; mkdir -p ~/.ssh && \
        printf '%s\\n' \(SSHRunner.shellQuote(publicKey)) >> ~/.ssh/authorized_keys && \
        chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh
        """
        let arguments = [
            "ssh",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "PubkeyAuthentication=no",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=10",
            "-p", String(port),
            "\(user)@\(hostName)",
            "--",
            remote,
        ]
        let transcript = try PTYCommand.run(
            executable: SSHRunner.executableURL.path,
            arguments: arguments,
            timeout: 45
        ) { output in
            output.lowercased().contains("assword:") ? password + "\n" : nil
        }
        let lower = transcript.text.lowercased()
        if lower.contains("permission denied (publickey")
            || lower.contains("no matching authentications")
            || (lower.contains("permission denied") && !lower.contains("assword")) {
            throw SSHError.passwordAuthDisabled
        }
        if lower.contains("remote host identification has changed")
            || lower.contains("host key verification failed") {
            throw SSHError.hostKeyChanged(hostName)
        }
        if lower.contains("permission denied") || transcript.status != 0 {
            throw SSHError.authFailed(hostName)
        }
    }

    // MARK: - Small process helpers

    struct ToolOutput {
        let status: Int32
        let text: String
    }

    @discardableResult
    static func runTool(_ path: String, _ arguments: [String]) throws -> ToolOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolOutput(status: process.terminationStatus, text: String(data: data, encoding: .utf8) ?? "")
    }

    static func ensureSSHDirectory() throws {
        if !FileManager.default.fileExists(atPath: sshDirectory.path) {
            try FileManager.default.createDirectory(
                at: sshDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}

/// Runs a child on a pty so it accepts input programs only read from a
/// terminal — here, ssh's password prompt.
enum PTYCommand {
    struct Transcript {
        let status: Int32
        let text: String
    }

    /// `respond` is handed the transcript so far each time new output arrives;
    /// returning a string writes it to the pty. Each distinct response is sent
    /// at most once, so a repeated prompt (a wrong password) ends the attempt
    /// instead of retrying forever.
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        respond: (String) -> String?
    ) throws -> Transcript {
        var master: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let child = forkpty(&master, nil, nil, &size)
        guard child >= 0 else { throw SSHError.configWriteFailed(String(cString: strerror(errno))) }

        if child == 0 {
            let path = strdup(executable)!
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0)! }
            argv.append(nil)
            argv.withUnsafeMutableBufferPointer { buffer in
                _ = execv(path, buffer.baseAddress)
            }
            _exit(127)
        }

        var transcript = ""
        var answered: Set<String> = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var finished = false

        while Date() < deadline {
            var readSet = fd_set()
            fdZero(&readSet)
            fdSet(master, &readSet)
            var wait = timeval(tv_sec: 0, tv_usec: 200_000)
            let ready = select(master + 1, &readSet, nil, nil, &wait)
            if ready > 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 {
                    transcript += String(decoding: buffer[0..<count], as: UTF8.self)
                    if let reply = respond(transcript), answered.insert(reply).inserted {
                        _ = reply.withCString { pointer in
                            write(master, pointer, strlen(pointer))
                        }
                    }
                } else {
                    break // EOF: the child closed the pty.
                }
            } else if ready < 0, errno != EINTR {
                break
            }
            var waited: Int32 = 0
            if waitpid(child, &waited, WNOHANG) == child {
                status = exitStatus(waited)
                finished = true
                break
            }
        }

        if !finished {
            var waited: Int32 = 0
            if waitpid(child, &waited, WNOHANG) == child {
                status = exitStatus(waited)
            } else {
                kill(child, SIGTERM)
                while waitpid(child, &waited, 0) < 0, errno == EINTR {}
                status = exitStatus(waited)
            }
        }
        close(master)
        return Transcript(status: status, text: transcript)
    }

    private static func exitStatus(_ raw: Int32) -> Int32 {
        (raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F)
    }

    private static func fdZero(_ set: inout fd_set) {
        set = fd_set()
    }

    private static func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let index = Int(fd) / 32
        let bit = Int32(1) << (Int32(fd) % 32)
        withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                bits[index] |= bit
            }
        }
    }
}
