// Copyright (c) 2026 DOTS
// Memory that learns the project by itself. Once a first prompt has given a project its
// memory, it is read a part at a time in the background - its root, then each top-level
// folder - by a light model that turns its documents, manifests and commit subjects into
// findings. A project no prompt was sent in is never touched.

import Foundation

extension WorkspaceMemory {
    static let studyAreas = 12
    static let studyDocuments = 5
    static let studyRoot = "."

    static let studySystemPrompt = """
    You are building the long-term memory of one software project before any work was done in it. You are \
    given one part of the project - its file names, its own documents and manifests, and for the root its \
    recent commit subjects - and the findings already known.
    Extract only what someone starting a task here must know and would not see at a glance:
    - decision: a choice the project made and holds to - an architecture, a library, a convention, something \
    ruled out - with the reason when it is stated.
    - error: a failure the documents or commits record, and its fix.
    - lesson: the exact command that builds, tests, runs or deploys; a limit of the environment; a rule the \
    documents set for whoever works here.
    - area: where one concern of this part lives (packaging, tests, a feature) - the concern, then the files \
    that hold it. Only when the file names or documents show it plainly.
    Rules:
    - One fact per finding, at most 200 characters, in the language of the documents. At most 6 findings.
    - Name real files and commands from the input. Never invent one. Never include a credential.
    - When the part repeats a known finding, return that finding with its "id" instead of a new one.
    - A part that states nothing lasting yields nothing.
    - Give each finding up to 8 "keywords": words a later request about it would use, in English and in the \
    language of the documents, with common synonyms - lowercase, one or two words each. Recall matches on them.
    Reply with JSON only:
    {"insights":[{"id":"<known id, or omit>","kind":"decision|error|lesson|area","text":"...","files":["path"],"keywords":["word"]}]}
    """

    /// A folder that is a project, not the home folder, a volume or a temporary directory:
    /// the background work studies nothing in those.
    static func isProjectFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let temporary = ["/tmp", "/private/tmp", "/private/var", "/var/folders"]
        return path.split(separator: "/").count >= 3
            && path != FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
            && !temporary.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The parts of the project no study has read yet: the root, then its folders.
    private func unstudiedAreas(_ file: InsightFile) -> [String] {
        guard let workspaceURL else { return [] }
        let folders = Set(WorkspaceTools.scanFilePaths(workspaceURL).compactMap { path -> String? in
            guard let slash = path.firstIndex(of: "/") else { return nil }
            return String(path[..<slash])
        }).sorted()
        let studied = Set(file.studied ?? [])
        return ([Self.studyRoot] + folders.prefix(Self.studyAreas)).filter { !studied.contains($0) }
    }

    /// The next part for the model: its name and the text describing it.
    /// ponytail: file names two levels down and the first documents found, not the source
    /// itself; read code when the findings turn out too thin to steer a task.
    func nextStudyBatch() -> (area: String, payload: String)? {
        guard manifest != nil, let workspaceURL else { return nil }
        let file = insightFile()
        guard let area = unstudiedAreas(file).first else { return nil }
        let isRoot = area == Self.studyRoot
        let paths = WorkspaceTools.scanFilePaths(workspaceURL)
        var names: [String] = []
        var documents: [URL] = []
        let areaDepth = isRoot ? 0 : area.split(separator: "/").count
        for path in paths.prefix(3_000) where names.count < 150 {
            let components = path.split(separator: "/")
            let partDepth = components.count - areaDepth
            if isRoot {
                guard partDepth == 1 else { continue }
            } else {
                guard path.hasPrefix(area + "/"), (1...3).contains(partDepth) else { continue }
            }
            names.append(path)
            let name = String(components.last ?? "")
            let lower = name.lowercased()
            if partDepth == 1 && lower.hasSuffix(".md") || lower.hasPrefix("readme") || Self.isStackManifest(name) || name == "Makefile" {
                documents.append(workspaceURL.appendingPathComponent(path))
            }
        }
        // A part with nothing in it still counts as read, so the study moves on.
        var sections = ["## Part: \(isRoot ? "the project root" : area + "/")", "## Files\n" + names.map { "- \($0)" }.joined(separator: "\n")]
        if isRoot {
            sections.append("## Project map\n\(mapText)")
            let commits = Self.gitLines(["log", "-n", "40", "--pretty=%s"], workspace: workspaceURL)
            if !commits.isEmpty { sections.append("## Recent commits\n" + commits.map { "- \(sanitize($0, limit: 160))" }.joined(separator: "\n")) }
        }
        // Shallowest first: a part's own README says more than one three folders down.
        for url in documents.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }).prefix(Self.studyDocuments) {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 400_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            sections.append("## \(url.path.dropFirst(workspaceURL.path.count + 1))\n\(sanitize(text, limit: 3_000))")
        }
        let known = file.insights.map { "- \($0.id) [\($0.kind.rawValue)] \($0.text)" }.joined(separator: "\n")
        return (area, "## Known findings\n\(known.isEmpty ? "None" : known)\n\n" + sections.joined(separator: "\n\n"))
    }

    /// Folds the model's reply into the findings and marks the part as read. The part is
    /// marked whatever the reply says: a model that cannot answer for it is not asked again.
    func applyStudy(reply: String, area: String) {
        let lastScan = insightFile().lastScan
        applyScan(reply: reply, runIDs: [])
        var file = insightFile()
        file.studied = (file.studied ?? []) + [area]
        // A study is not a scan of finished tasks, and must not put that one off.
        file.lastScan = lastScan
        save(file)
    }
}
