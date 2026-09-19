// Copyright (c) 2026 DOTS
// Managed Chrome supervisor and CDP target ownership for the native harness.

import Darwin
import Foundation

@MainActor
public final class BrowserSessionManager {
    private final class PipeConnection: @unchecked Sendable {
        private let input: FileHandle
        private let output: FileHandle
        private let queue = DispatchQueue(label: "com.dots.herness.browser.cdp-pipe")
        private var nextID = 0

        init(input: FileHandle, output: FileHandle) {
            self.input = input
            self.output = output
        }

        func send(
            method: String,
            parametersJSON: Data,
            sessionID: String? = nil
        ) async throws -> [String: Any]? {
            let data: Data? = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        self.nextID += 1
                        var payload: [String: Any] = [
                            "id": self.nextID,
                            "method": method,
                            "params": try JSONSerialization.jsonObject(with: parametersJSON),
                        ]
                        if let sessionID { payload["sessionId"] = sessionID }
                        let encoded = try JSONSerialization.data(withJSONObject: payload)
                        try self.output.write(contentsOf: encoded)
                        try self.output.write(contentsOf: Data([0]))
                        let result = try self.readResponse(id: self.nextID)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            guard let data else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        private func readResponse(id: Int) throws -> Data? {
            while true {
                let frame = try readFrame()
                guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                    continue
                }
                guard (object["id"] as? Int) == id else { continue }
                if let error = object["error"] {
                    throw BrowserSessionError.pipe(String(describing: error))
                }
                guard let result = object["result"] else { return nil }
                return try JSONSerialization.data(withJSONObject: result)
            }
        }

        private func readFrame() throws -> Data {
            var frame = Data()
            while true {
                let byte = input.readData(ofLength: 1)
                guard let first = byte.first else { throw BrowserSessionError.pipe("CDP pipe closed.") }
                if first == 0 { return frame }
                frame.append(first)
            }
        }

        func close() {
            try? input.close()
            try? output.close()
        }
    }

    private final class Session {
        let scope: BrowserScope
        let profileURL: URL
        let leaseURL: URL
        let process: Process
        let port: Int?
        let pipe: PipeConnection?
        var pageIDs: Set<String> = []
        var openedPageIDs: [String] = []
        var closedPageIDs: [String] = []
        var targetSessions: [String: String] = [:]

        init(scope: BrowserScope, profileURL: URL, leaseURL: URL, process: Process, port: Int?, pipe: PipeConnection?) {
            self.scope = scope
            self.profileURL = profileURL
            self.leaseURL = leaseURL
            self.process = process
            self.port = port
            self.pipe = pipe
        }
    }

    private let rootURL: URL
    private var sessions: [String: Session] = [:]
    private var diagnostics: [String: String] = [:]

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DotsHarness", isDirectory: true)
                .appendingPathComponent("browser-runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        recoverStaleLeases()
    }

    public func execute(
        _ call: AgentToolCall,
        scope: BrowserScope,
        backend: BrowserBackend
    ) async -> String {
        do {
            guard let data = call.arguments.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Tool error: invalid browser arguments."
            }
            if object["backend"] != nil {
                return "Tool error: backend is selected by the host and cannot be supplied by the model."
            }
            switch call.name {
            case BrowserTools.openName:
                let url = object["url"] as? String ?? ""
                let page = try await open(scope: scope, backend: backend, url: url)
                return "Opened \(page.url)\npageID: \(page.pageID)\nbackend: \(page.backend.rawValue)"
            case BrowserTools.navigateName:
                let pageID = object["pageID"] as? String ?? ""
                let url = object["url"] as? String ?? ""
                try await navigate(scope: scope, pageID: pageID, url: url)
                return "Navigated page \(pageID) to \(url)."
            case BrowserTools.closeName:
                let pageID = object["pageID"] as? String ?? ""
                try await closePage(scope: scope, pageID: pageID)
                return "Closed page \(pageID)."
            default:
                return "Tool error: unknown browser tool \(call.name)."
            }
        } catch {
            if backend == .`extension` {
                diagnostics[scope.key] = "extension_backend_unavailable"
            }
            return "Tool error: \(error.localizedDescription)"
        }
    }

    public func open(scope: BrowserScope, backend: BrowserBackend, url: String) async throws -> BrowserPage {
        guard backend == .managed else {
            throw BrowserSessionError.extensionUnavailable
        }
        try validate(url)
        let session: Session
        if let existing = sessions[scope.key] {
            session = existing
        } else {
            let started = try await startSession(scope: scope)
            sessions[scope.key] = started
            session = started
        }

        do {
            let result = try await sendBrowserCommand(
                session: session,
                method: "Target.createTarget",
                parameters: ["url": url]
            )
            guard let pageID = result?["targetId"] as? String, !pageID.isEmpty else {
                throw BrowserSessionError.missingTargetID
            }
            session.pageIDs.insert(pageID)
            session.openedPageIDs.append(pageID)
            diagnostics.removeValue(forKey: scope.key)
            return BrowserPage(pageID: pageID, backend: backend, url: url, scope: scope)
        } catch {
            if session.pageIDs.isEmpty { _ = await closeRun(scope: scope, backend: backend) }
            throw error
        }
    }

    public func navigate(scope: BrowserScope, pageID: String, url: String) async throws {
        guard !pageID.isEmpty else { throw BrowserSessionError.missingPageID }
        try validate(url)
        let session = try ownedSession(scope: scope, pageID: pageID)
        if let pipe = session.pipe {
            let attached = try await pipe.send(
                method: "Target.attachToTarget",
                parametersJSON: try JSONSerialization.data(withJSONObject: ["targetId": pageID, "flatten": true])
            )
            guard let sessionID = attached?["sessionId"] as? String else {
                throw BrowserSessionError.pageUnavailable
            }
            _ = try await pipe.send(
                method: "Page.navigate",
                parametersJSON: try JSONSerialization.data(withJSONObject: ["url": url]),
                sessionID: sessionID
            )
            session.targetSessions[pageID] = sessionID
            return
        }
        guard let target = try await target(session: session, pageID: pageID),
              let websocket = target["webSocketDebuggerUrl"] as? String,
              let websocketURL = URL(string: websocket) else {
            throw BrowserSessionError.pageUnavailable
        }
        _ = try await sendWebSocketCommand(
            websocketURL: websocketURL,
            method: "Page.navigate",
            parameters: ["url": url]
        )
    }

    public func closePage(scope: BrowserScope, pageID: String) async throws {
        guard !pageID.isEmpty else { throw BrowserSessionError.missingPageID }
        guard let session = sessions[scope.key] else { throw BrowserSessionError.pageNotOwned }
        guard session.pageIDs.contains(pageID) else { throw BrowserSessionError.pageNotOwned }
        _ = try await sendBrowserCommand(
            session: session,
            method: "Target.closeTarget",
            parameters: ["targetId": pageID]
        )
        session.pageIDs.remove(pageID)
        session.closedPageIDs.append(pageID)
    }

    public func closeRun(scope: BrowserScope, backend: BrowserBackend = .unknown) async -> BrowserRunSummary {
        guard let session = sessions.removeValue(forKey: scope.key) else {
            if let diagnostic = diagnostics.removeValue(forKey: scope.key) {
                return BrowserRunSummary(
                    backend: backend,
                    cleanupStatus: .failed,
                    diagnosticCode: diagnostic
                )
            }
            return BrowserRunSummary(backend: backend)
        }

        var cleanupStatus: BrowserCleanupStatus = .closed
        var diagnosticCode = "closed"
        let pages = Array(session.pageIDs)
        for pageID in pages {
            do {
                _ = try await sendBrowserCommand(
                    session: session,
                    method: "Target.closeTarget",
                    parameters: ["targetId": pageID]
                )
                session.closedPageIDs.append(pageID)
            } catch {
                cleanupStatus = .pendingRecovery
                diagnosticCode = "target_close_failed"
            }
        }

        _ = try? await sendBrowserCommand(
            session: session,
            method: "Browser.close",
            parameters: [:]
        )
        await waitForExit(session.process, timeout: 2)
        if session.process.isRunning {
            session.process.terminate()
            await waitForExit(session.process, timeout: 2)
        }
        if session.process.isRunning {
            _ = kill(session.process.processIdentifier, SIGKILL)
            await waitForExit(session.process, timeout: 1)
        }

        if session.process.isRunning {
            cleanupStatus = .pendingRecovery
            diagnosticCode = "process_still_running"
        } else {
            session.pipe?.close()
            try? FileManager.default.removeItem(at: session.leaseURL)
            try? FileManager.default.removeItem(at: session.profileURL.deletingLastPathComponent())
        }

        return BrowserRunSummary(
            backend: .managed,
            openedPageIDs: session.openedPageIDs,
            closedPageIDs: session.closedPageIDs,
            cleanupStatus: cleanupStatus,
            diagnosticCode: diagnosticCode
        )
    }

    public func closeAll() async {
        let scopes = sessions.values.map(\.scope)
        for scope in scopes {
            _ = await closeRun(scope: scope, backend: .managed)
        }
    }

    private func startSession(scope: BrowserScope) async throws -> Session {
        guard let executable = findChromeExecutable() else {
            throw BrowserSessionError.chromeNotFound
        }
        let runURL = rootURL.appendingPathComponent(scope.runID, isDirectory: true)
        let profileURL = runURL.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)

        var lastError: Error?
        for _ in 0..<3 {
            do {
                return try await startPipeSession(
                    scope: scope,
                    runURL: runURL,
                    profileURL: profileURL,
                    executable: executable
                )
            } catch {
                lastError = error
            }
        }
        guard SandboxProfile.isAvailable else {
            throw BrowserSessionError.portFallbackUnavailable
        }
        for _ in 0..<3 {
            let port = try reservePort()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [
                "--user-data-dir=\(profileURL.path)",
                "--remote-debugging-port=\(port)",
                "--remote-allow-origins=http://127.0.0.1:\(port)",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-sync",
                "--new-window",
                "about:blank",
            ]
            process.currentDirectoryURL = runURL
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let leaseURL = runURL.appendingPathComponent("lease.json")
            do {
                try process.run()
                try writeLease(
                    at: leaseURL,
                    scope: scope,
                    process: process,
                    executable: executable,
                    profile: profileURL.path,
                    port: port,
                    transport: "port",
                    state: "starting"
                )
                try await waitForCDP(port: port, process: process)
                try writeLease(
                    at: leaseURL,
                    scope: scope,
                    process: process,
                    executable: executable,
                    profile: profileURL.path,
                    port: port,
                    transport: "port",
                    state: "ready"
                )
                return Session(
                    scope: scope,
                    profileURL: profileURL,
                    leaseURL: leaseURL,
                    process: process,
                    port: port,
                    pipe: nil
                )
            } catch {
                lastError = error
                if process.isRunning {
                    process.terminate()
                    await waitForExit(process, timeout: 1)
                }
                if !process.isRunning {
                    try? FileManager.default.removeItem(at: leaseURL)
                }
            }
        }
        throw lastError ?? BrowserSessionError.startFailed
    }

    private func startPipeSession(
        scope: BrowserScope,
        runURL: URL,
        profileURL: URL,
        executable: String
    ) async throws -> Session {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "--user-data-dir=\(profileURL.path)",
            "--remote-debugging-pipe",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--new-window",
            "about:blank",
        ]
        process.currentDirectoryURL = runURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pipe = PipeConnection(input: output.fileHandleForReading, output: input.fileHandleForWriting)
        let leaseURL = runURL.appendingPathComponent("lease.json")
        do {
            try writeLease(
                at: leaseURL,
                scope: scope,
                process: process,
                executable: executable,
                profile: profileURL.path,
                port: nil,
                transport: "pipe",
                state: "starting"
            )
            _ = try await pipe.send(
                method: "Browser.getVersion",
                parametersJSON: Data("{}".utf8)
            )
            try writeLease(
                at: leaseURL,
                scope: scope,
                process: process,
                executable: executable,
                profile: profileURL.path,
                port: nil,
                transport: "pipe",
                state: "ready"
            )
            return Session(
                scope: scope,
                profileURL: profileURL,
                leaseURL: leaseURL,
                process: process,
                port: nil,
                pipe: pipe
            )
        } catch {
            pipe.close()
            if process.isRunning {
                process.terminate()
                await waitForExit(process, timeout: 1)
            }
            if !process.isRunning {
                try? FileManager.default.removeItem(at: leaseURL)
            }
            throw error
        }
    }

    private func sendBrowserCommand(
        session: Session,
        method: String,
        parameters: [String: Any]
    ) async throws -> [String: Any]? {
        if let pipe = session.pipe {
            return try await pipe.send(
                method: method,
                parametersJSON: try JSONSerialization.data(withJSONObject: parameters)
            )
        }
        guard let port = session.port else { throw BrowserSessionError.missingWebsocket }
        let version = try await getJSON(URL(string: "http://127.0.0.1:\(port)/json/version")!)
        guard let websocket = version["webSocketDebuggerUrl"] as? String,
              let websocketURL = URL(string: websocket) else {
            throw BrowserSessionError.missingWebsocket
        }
        return try await sendWebSocketCommand(
            websocketURL: websocketURL,
            method: method,
            parameters: parameters
        )
    }

    private func target(session: Session, pageID: String) async throws -> [String: Any]? {
        guard let port = session.port else { return nil }
        let items = try await getJSONArray(URL(string: "http://127.0.0.1:\(port)/json/list")!)
        return items.first { $0["id"] as? String == pageID }
    }

    private func sendWebSocketCommand(
        websocketURL: URL,
        method: String,
        parameters: [String: Any]
    ) async throws -> [String: Any]? {
        let task = URLSession.shared.webSocketTask(with: websocketURL)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let id = Int.random(in: 1...Int.max)
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": parameters,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))

        while true {
            let message = try await task.receive()
            let text: String
            switch message {
            case .string(let value):
                text = value
            case .data(let value):
                text = String(decoding: value, as: UTF8.self)
            @unknown default:
                continue
            }
            guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                continue
            }
            guard (object["id"] as? Int) == id else { continue }
            if let error = object["error"] {
                throw BrowserSessionError.cdp(String(describing: error))
            }
            return object["result"] as? [String: Any]
        }
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BrowserSessionError.cdp("HTTP request failed: \(url.absoluteString)")
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func getJSONArray(_ url: URL) async throws -> [[String: Any]] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BrowserSessionError.cdp("HTTP request failed: \(url.absoluteString)")
        }
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }

    private func ownedSession(scope: BrowserScope, pageID: String) throws -> Session {
        guard let session = sessions[scope.key], session.pageIDs.contains(pageID) else {
            throw BrowserSessionError.pageNotOwned
        }
        return session
    }

    private func waitForCDP(port: Int, process: Process) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !process.isRunning {
                throw BrowserSessionError.startFailed
            }
            do {
                _ = try await getJSON(URL(string: "http://127.0.0.1:\(port)/json/version")!)
                return
            } catch {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw BrowserSessionError.startTimeout
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func reservePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrowserSessionError.portUnavailable }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw BrowserSessionError.portUnavailable }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { throw BrowserSessionError.portUnavailable }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func writeLease(
        at url: URL,
        scope: BrowserScope,
        process: Process,
        executable: String,
        profile: String,
        port: Int?,
        transport: String,
        state: String
    ) throws {
        var object: [String: Any] = [
            "scope": [
                "area": scope.area,
                "conversationID": scope.conversationID,
                "runID": scope.runID,
            ],
            "runID": scope.runID,
            "processID": process.processIdentifier,
            "executable": executable,
            "profile": profile,
            "transport": transport,
            "state": state,
        ]
        if let startDate = processStartDate(process.processIdentifier) {
            object["processStartTimeUTC"] = ISO8601DateFormatter().string(from: startDate)
        }
        if let port { object["port"] = port }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        let temporary = url.appendingPathExtension("\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    private func recoverStaleLeases() {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for case let url as URL in enumerator where url.lastPathComponent == "lease.json" {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let processID = (object["processID"] as? Int32)
                    ?? (object["processID"] as? Int).map(Int32.init) else {
                continue
            }
            if kill(processID, 0) == 0 {
                // A live PID is reclaimed only when all identity checks match.
                // If the PID was reused or inspection is unavailable, leave the
                // lease/profile intact rather than touching an unrelated process.
                if processMatchesLease(
                    processID,
                    expectedExecutable: object["executable"] as? String,
                    expectedProfile: object["profile"] as? String,
                    expectedStart: object["processStartTimeUTC"] as? String
                ) {
                    continue
                }
                continue
            }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func processMatchesLease(
        _ processID: pid_t,
        expectedExecutable: String?,
        expectedProfile: String?,
        expectedStart: String?
    ) -> Bool {
        guard let expectedExecutable,
              let expectedProfile,
              let expectedStart,
              let expectedDate = ISO8601DateFormatter().date(from: expectedStart),
              let commandLine = processCommandLine(processID),
              commandLine.contains(expectedProfile),
              commandLine.contains(URL(fileURLWithPath: expectedExecutable).lastPathComponent),
              let actualDate = processStartDate(processID) else {
            return false
        }
        return abs(actualDate.timeIntervalSince(expectedDate)) <= 5
    }

    private func processCommandLine(_ processID: pid_t) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(processID), "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func processStartDate(_ processID: pid_t) -> Date? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(processID), "-o", "etimes="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let value = String(data: data, encoding: .utf8),
                  let elapsed = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return Date().addingTimeInterval(-elapsed)
        } catch {
            return nil
        }
    }

    private func findChromeExecutable() -> String? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["HERNESS_CHROME_PATH"],
           !configured.isEmpty {
            candidates.append(configured)
        }
        candidates += [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func validate(_ value: String) throws {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http" || components.scheme?.lowercased() == "https",
              components.host != nil else {
            throw BrowserSessionError.invalidURL
        }
    }
}

public enum BrowserSessionError: LocalizedError, Equatable {
    case chromeNotFound
    case extensionUnavailable
    case invalidURL
    case missingTargetID
    case missingWebsocket
    case missingPageID
    case pageUnavailable
    case pageNotOwned
    case portUnavailable
    case portFallbackUnavailable
    case startFailed
    case startTimeout
    case cdp(String)
    case pipe(String)

    public var errorDescription: String? {
        switch self {
        case .chromeNotFound: return "Managed Chrome could not be found."
        case .extensionUnavailable: return "Chrome Extension backend is not connected."
        case .invalidURL: return "Only http and https browser URLs are allowed."
        case .missingTargetID: return "Chrome did not return a target ID."
        case .missingWebsocket: return "Chrome did not expose a CDP websocket."
        case .missingPageID: return "pageID is required."
        case .pageUnavailable: return "The owned browser page is no longer available."
        case .pageNotOwned: return "The page is not owned by this run."
        case .portUnavailable: return "A managed browser port could not be reserved."
        case .portFallbackUnavailable: return "Managed CDP pipe failed and an isolated port fallback is unavailable."
        case .startFailed: return "Managed Chrome could not be started."
        case .startTimeout: return "Managed Chrome CDP did not become ready."
        case .cdp(let message): return "CDP error: \(message)"
        case .pipe(let message): return "CDP pipe error: \(message)"
        }
    }
}
