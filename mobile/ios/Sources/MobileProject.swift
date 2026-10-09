import Foundation

/// The mobile project is the scope for files, transcript, model context,
/// terminal state and remote commands. It deliberately stores no credentials.
struct MobileProject: Identifiable, Codable, Equatable, Sendable {
    enum SourceKind: String, Codable, Sendable {
        case local
        case github
        case remoteDesktop
    }

    let id: String
    var name: String
    var sourceKind: SourceKind
    var repository: String?
    var branch: String?
    var localRoot: String
    var remoteProjectID: String?
    var remoteWorkspaceID: String?

    static func localDefault(root: URL) -> MobileProject {
        MobileProject(
            id: "local-default",
            name: "Default project",
            sourceKind: .local,
            repository: nil,
            branch: nil,
            localRoot: root.path,
            remoteProjectID: nil,
            remoteWorkspaceID: nil
        )
    }
}

@MainActor
final class MobileProjectStore: ObservableObject {
    @Published private(set) var projects: [MobileProject]
    @Published private(set) var selectedProjectID: String

    private let fileURL: URL
    private let defaultsKey = "herness.projects.selectedID"
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyRoot = appSupport.appendingPathComponent("HerNess/workspace", isDirectory: true)
        let directory = appSupport.appendingPathComponent("HerNess/projects", isDirectory: true)
        fileURL = directory.appendingPathComponent("projects.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let localDecoder = JSONDecoder()
        let stored = (try? Data(contentsOf: fileURL)).flatMap { try? localDecoder.decode([MobileProject].self, from: $0) } ?? []
        let initialProjects: [MobileProject]
        var shouldPersist = false
        var shouldCreateInitialRoot = false
        if stored.isEmpty {
            initialProjects = [MobileProject.localDefault(root: legacyRoot)]
            shouldPersist = true
            shouldCreateInitialRoot = true
        } else {
            initialProjects = stored
        }
        projects = initialProjects

        let initialSelectedID = UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap { candidate in initialProjects.contains(where: { $0.id == candidate }) ? candidate : nil }
            ?? initialProjects[0].id
        selectedProjectID = initialSelectedID
        UserDefaults.standard.set(selectedProjectID, forKey: defaultsKey)
        if shouldPersist {
            persist()
        }
        // Existing projects may point at a folder the user removed or moved.
        // Recreating it here would silently turn a missing project into an
        // empty one and make its previous workspace appear lost.
        if shouldCreateInitialRoot, let project = projects.first {
            try? fileManager.createDirectory(atPath: project.localRoot, withIntermediateDirectories: true)
        }
    }

    var selected: MobileProject { projects.first(where: { $0.id == selectedProjectID }) ?? projects[0] }

    func select(_ id: String) {
        guard projects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id
        UserDefaults.standard.set(id, forKey: defaultsKey)
    }

    @discardableResult
    func add(name: String, sourceKind: MobileProject.SourceKind = .local, root: URL? = nil, remoteProjectID: String? = nil, remoteWorkspaceID: String? = nil, branch: String? = nil) -> MobileProject {
        let id = UUID().uuidString
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New project" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let localRoot = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HerNess/projects/\(id)/files", isDirectory: true)
        let project = MobileProject(id: id, name: safeName, sourceKind: sourceKind, repository: nil, branch: branch, localRoot: localRoot.path, remoteProjectID: remoteProjectID, remoteWorkspaceID: remoteWorkspaceID)
        projects.append(project)
        try? fileManager.createDirectory(at: localRoot, withIntermediateDirectories: true)
        persist()
        select(id)
        return project
    }

    func remoteProject(id: String) -> MobileProject? {
        projects.first { $0.remoteProjectID == id }
    }

    func update(_ project: MobileProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        persist()
    }

    func updateLocalRoot(id: String, root: URL) {
        guard var project = projects.first(where: { $0.id == id }) else { return }
        project.localRoot = root.standardizedFileURL.path
        update(project)
    }

    func remove(_ id: String) {
        guard projects.count > 1, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects.remove(at: index)
        if selectedProjectID == id { selectedProjectID = projects[0].id }
        UserDefaults.standard.set(selectedProjectID, forKey: defaultsKey)
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(projects) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
