import Foundation
import CryptoKit

@MainActor
final class LocalWorkspaceStore: ObservableObject {
    @Published private(set) var snapshot: WorkspaceSnapshot?
    @Published private(set) var selectedPath = ""
    @Published private(set) var selectedText = ""
    @Published var localError: String?
    @Published var cloneStatus = ""
    @Published private(set) var activeSandbox: SandboxWorkspace?
    @Published var sandboxNotice: String?

    private let baseRoot: URL
    var root: URL { activeSandbox.map { URL(fileURLWithPath: $0.path, isDirectory: true) } ?? baseRoot }
    /// Metadata lives beside the mirror, never inside it: the shell, the agent,
    /// and any GitHub push all treat everything under `root` as user files.
    private let meta: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        baseRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("HerNess/workspace", isDirectory: true)
        meta = baseRoot.deletingLastPathComponent().appendingPathComponent("meta", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        let legacy = baseRoot.appendingPathComponent("snapshot.json")
        if FileManager.default.fileExists(atPath: legacy.path) { try? FileManager.default.moveItem(at: legacy, to: meta.appendingPathComponent("snapshot.json")) }
        if let data = try? Data(contentsOf: meta.appendingPathComponent("snapshot.json")) { snapshot = try? decoder.decode(WorkspaceSnapshot.self, from: data) }
        // Restore sandbox that survived a relaunch — the directory is on disk.
        if let name = UserDefaults.standard.string(forKey: "herness.sandbox.name"),
           let origin = UserDefaults.standard.string(forKey: "herness.sandbox.origin") {
            let candidate = SandboxWorkspaces.directory(origin: URL(fileURLWithPath: origin), name: name)
            let marker = candidate.appendingPathComponent(".herness-sandbox-marker")
            if FileManager.default.fileExists(atPath: marker.path) {
                activeSandbox = SandboxWorkspace(name: name, path: candidate.path, originPath: origin)
            } else {
                UserDefaults.standard.removeObject(forKey: "herness.sandbox.name")
                UserDefaults.standard.removeObject(forKey: "herness.sandbox.origin")
            }
        }
    }

    var hasMirror: Bool { snapshot != nil }

    func files() -> [WorkspaceFile] { (try? agentFiles()) ?? [] }

    /// Hashes the local workspace for an agent run. A failed read is an error,
    /// not an empty snapshot: an empty result could falsely claim cleanup was
    /// verified.
    func agentFiles() throws -> [WorkspaceFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            throw NSError(domain: "HerNess.Workspace", code: 1, userInfo: [NSLocalizedDescriptionKey: "The local workspace could not be enumerated."])
        }
        var result: [WorkspaceFile] = []
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) }
            catch { throw error }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                if Self.ignoredDirectories.contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".mem") {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            result.append(WorkspaceFile(path: relativePath(url), bytes: Int64(data.count), sha256: Self.digest(data), mode: 0o644))
        }
        return result.sorted { $0.path < $1.path }
    }

    func refresh() {
        let current = files()
        guard !current.isEmpty || snapshot != nil else { return }
        let previous = snapshot
        snapshot = WorkspaceSnapshot(version: 1, workspaceId: previous?.workspaceId ?? "local:phone", workspace: previous?.workspace ?? "phone", revision: (previous?.revision ?? 0) + 1, baseCommitSha: previous?.baseCommitSha, files: current, excluded: previous?.excluded ?? [], createdAt: Date())
        try? encoder.encode(snapshot).write(to: meta.appendingPathComponent("snapshot.json"), options: .atomic)
    }

    // MARK: - Sandbox

    var sandboxRoot: URL { baseRoot }

    func sandboxes() -> [SandboxWorkspace] {
        SandboxWorkspaces.list(origin: baseRoot.path)
    }

    func enterSandbox(name: String) throws {
        let sandbox = try SandboxWorkspaces.enter(origin: baseRoot.path, name: name)
        activeSandbox = sandbox
        UserDefaults.standard.set(sandbox.name, forKey: "herness.sandbox.name")
        UserDefaults.standard.set(sandbox.originPath, forKey: "herness.sandbox.origin")
        sandboxNotice = "Sandbox '\(sandbox.name)' started."
        // Fresh snapshot for the isolated workspace
        refresh()
    }

    func exitSandbox(merge: Bool) throws -> SandboxExit {
        guard let sandbox = activeSandbox else { return .discarded }
        let result = try SandboxWorkspaces.exit(sandbox, merge: merge)
        switch result {
        case .merged(let commits):
            sandboxNotice = commits == 0 ? "Sandbox '\(sandbox.name)' had no changes; removed." : "Sandbox '\(sandbox.name)' merged (\(commits) file(s))."
        case .conflicted(let files):
            sandboxNotice = "Merge conflicts: \(files.joined(separator: ", "))"
            // Keep sandbox active on conflict (mirrors macOS SandboxWorkspace.exit conflict case)
            return result
        case .discarded:
            sandboxNotice = "Sandbox '\(sandbox.name)' discarded."
        }
        activeSandbox = nil
        UserDefaults.standard.removeObject(forKey: "herness.sandbox.name")
        UserDefaults.standard.removeObject(forKey: "herness.sandbox.origin")
        refresh()
        return result
    }

    func discardSandbox(_ sandbox: SandboxWorkspace) throws {
        _ = try SandboxWorkspaces.exit(sandbox, merge: false)
        if activeSandbox == sandbox {
            activeSandbox = nil
            UserDefaults.standard.removeObject(forKey: "herness.sandbox.name")
            UserDefaults.standard.removeObject(forKey: "herness.sandbox.origin")
            refresh()
        }
    }

    /// Every path that reaches the filesystem goes through here, so a traversal
    /// in a snapshot, a shell argument, or an agent tool call all fail the same way.
    func resolve(_ relativePath: String) throws -> URL {
        guard relativePath.split(separator: "/").allSatisfy({ !$0.hasPrefix(".mem") }) else { throw ClientError.pathOutsideWorkspace }
        let target = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else { throw ClientError.pathOutsideWorkspace }
        return target
    }

    func hasSymlinkComponent(_ relativePath: String) throws -> Bool {
        var current = root
        for component in relativePath.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                current.deleteLastPathComponent()
                continue
            }
            current.appendPathComponent(String(component))
            if try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { return true }
        }
        return false
    }

    func write(relativePath: String, data: Data) throws {
        let target = try resolve(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    func replaceSnapshot(_ value: WorkspaceSnapshot) throws {
        snapshot = value
        try encoder.encode(value).write(to: meta.appendingPathComponent("snapshot.json"), options: .atomic)
    }

    func importSnapshot(_ value: WorkspaceSnapshot, read: (String) async throws -> Data) async {
        do {
            let previous = snapshot
            var conflicts: [String] = []
            for file in value.files {
                let target = try resolve(file.path)
                if let old = previous?.files.first(where: { $0.path == file.path }),
                   let localData = try? Data(contentsOf: target),
                   Self.digest(localData) != old.sha256 {
                    if file.sha256 != old.sha256 { conflicts.append(file.path) }
                    continue
                }
                let data = try await read(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            snapshot = value; try encoder.encode(value).write(to: meta.appendingPathComponent("snapshot.json"), options: .atomic)
            localError = conflicts.isEmpty ? nil : "Conflict: \(conflicts.joined(separator: ", ")) changed on both the phone and desktop. Local edits were kept."
        } catch { localError = error.localizedDescription }
    }

    func select(_ file: WorkspaceFile) {
        selectedPath = file.path
        selectedText = (try? String(contentsOf: resolve(file.path), encoding: .utf8)) ?? ""
    }

    func select(path: String) {
        selectedPath = path
        selectedText = (try? String(contentsOf: resolve(path), encoding: .utf8)) ?? ""
    }

    func saveCurrent() throws {
        guard !selectedPath.isEmpty else { return }
        let file = try resolve(selectedPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try selectedText.data(using: .utf8)?.write(to: file, options: .atomic)
    }

    func updateCurrentText(_ value: String) {
        selectedText = value
    }

    func text(for path: String) -> String { (try? String(contentsOf: resolve(path), encoding: .utf8)) ?? "" }

    func githubChanges() -> [GitHubFileChange] {
        guard let snapshot else { return [] }
        return snapshot.files.compactMap { file in
            guard let url = try? resolve(file.path),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return Self.fileDigest(data) == file.sha256 ? nil : GitHubFileChange(path: file.path, content: text)
        }
    }

    private static let ignoredDirectories: Set<String> = [".git", ".mem", ".build", "build", "bin", "obj", "dist", "node_modules", "Pods", "DerivedData"]

    private func relativePath(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private static func fileDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
