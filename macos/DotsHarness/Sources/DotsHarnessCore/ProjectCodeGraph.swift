// Copyright (c) 2026 DOTS
// A local, incrementally refreshed Tree-sitter graph used to retrieve small code subgraphs.

import CryptoKit
import Foundation

struct CodeGraphFileStamp: Codable, Equatable, Sendable {
    var path: String
    var size: Int64
    var modifiedAtNanoseconds: Int64
}

struct CodeGraphNode: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: String
    var name: String
    var path: String
    var line: Int
    var language: String
    var signature: String?
}

struct CodeGraphEdge: Codable, Equatable, Sendable, Identifiable {
    var from: String
    var to: String
    var relation: String
    var provenance: String
    var confidence: Double

    var id: String { "\(from)|\(relation)|\(to)|\(provenance)" }
}

struct CodeGraphReference: Codable, Equatable, Sendable {
    var from: String
    var name: String
    var relation: String
}

struct CodeGraphFile: Codable, Equatable, Sendable {
    var stamp: CodeGraphFileStamp
    var sha256: String
    var nodes: [CodeGraphNode]
    /// Edges returned directly by the parser, without symbol-name resolution.
    var extractedEdges: [CodeGraphEdge]
    /// Names visible in AST-bounded signatures and bodies. Resolved only when unique.
    var references: [CodeGraphReference]
}

private struct CodeGraphFinding {
    var id: String
    var kind: String
    var text: String
    var evidence: String
    var paths: [String]
    var score: Int
    var updatedAt: String
}

/// Whole-word, case-insensitive mentions in one text, built once and asked per graph
/// node. A regex compiled per node name hung the main actor for minutes on a 17k-node graph.
struct ExplicitMentions {
    private let text: String
    private let words: Set<Substring>

    init(_ text: String) {
        self.text = text.lowercased()
        words = Set(self.text.split(whereSeparator: { !Self.isWordCharacter($0) }))
    }

    /// A node name prepared once per graph query: lowercasing and classifying 17k
    /// names again for every insight was ~1M string allocations per prompt.
    struct Target {
        let name: String
        let isWord: Bool
        /// The name's first run of word characters. A whole-word match of the name makes
        /// it a whole word of the text too, so a name whose anchor is absent is skipped
        /// without a substring search.
        let anchor: Substring?

        init(_ name: String) {
            self.name = name.lowercased()
            isWord = self.name.allSatisfy(ExplicitMentions.isWordCharacter)
            anchor = self.name.split(whereSeparator: { !ExplicitMentions.isWordCharacter($0) }).first
        }
    }

    func contains(_ name: String) -> Bool {
        contains(Target(name))
    }

    func contains(_ target: Target) -> Bool {
        let name = target.name
        guard !name.isEmpty else { return false }
        if target.isWord { return words.contains(Substring(name)) }
        if let anchor = target.anchor, !words.contains(anchor) { return false }
        // Paths and dotted names span several words: bounded substring search.
        return text.ranges(of: name).contains { found in
            (found.lowerBound == text.startIndex || !Self.isWordCharacter(text[text.index(before: found.lowerBound)]))
                && (found.upperBound == text.endIndex || !Self.isWordCharacter(text[found.upperBound]))
        }
    }

    fileprivate static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }
}

/// What `ProjectCodeGraph.context` reads from every node, built once per graph.
/// Tokenizing 17k names and paths, and matching every finding against every symbol,
/// again for each prompt cost ~0.4 s of CPU per prompt: chats sent together pinned cores.
final class CodeGraphScoringIndex: @unchecked Sendable {
    struct Entry {
        let node: Int
        let nameTerms: Set<String>
        let pathTerms: Set<String>
        let lowerName: [UInt8]
    }

    let key: String
    let entries: [Entry]
    let parsedPaths: Set<String>
    let unparsed: [(path: String, terms: Set<String>)]
    let fileTargets: [(node: CodeGraphNode, path: ExplicitMentions.Target, name: ExplicitMentions.Target)]
    let symbolNodes: [(node: CodeGraphNode, name: ExplicitMentions.Target)]
    let byID: [String: CodeGraphNode]
    private let lock = NSLock()
    // ponytail: unbounded, but keyed by saved findings, which stay in the dozens per project.
    private var linked: [String: [String]] = [:]

    init(_ graph: ProjectCodeGraph, key: String) {
        self.key = key
        var pathTerms: [String: Set<String>] = [:]
        entries = graph.nodes.indices.compactMap { index in
            let node = graph.nodes[index]
            guard node.kind != "import" else { return nil }
            let terms = pathTerms[node.path] ?? FileIndex.words(node.path)
            pathTerms[node.path] = terms
            return Entry(node: index, nameTerms: FileIndex.words(node.name), pathTerms: terms, lowerName: Array(node.name.lowercased().utf8))
        }
        let fileNodes = graph.nodes.filter { $0.kind == "file" }
        let parsed = Set(fileNodes.map(\.path))
        parsedPaths = parsed
        unparsed = graph.inventory.map(\.path).filter { !parsed.contains($0) }.map { ($0, FileIndex.words($0)) }
        fileTargets = fileNodes.map { (node: $0, path: ExplicitMentions.Target($0.path), name: ExplicitMentions.Target($0.name)) }
        symbolNodes = graph.nodes.filter { $0.kind != "file" && $0.kind != "import" }
            .map { (node: $0, name: ExplicitMentions.Target($0.name)) }
        byID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A finding's linked files depend on the finding and the graph, not on the prompt.
    func linkedPaths(key: String, compute: () -> [String]) -> [String] {
        if let cached = lock.withLock({ linked[key] }) { return cached }
        let paths = compute()
        lock.withLock { linked[key] = paths }
        return paths
    }
}

struct ProjectCodeGraph: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    private static let scoringLock = NSLock()
    nonisolated(unsafe) private static var scoring: CodeGraphScoringIndex?

    /// One graph is open at a time; concurrent prompts wait for one build instead of each making its own.
    /// The full graph and its query index share nodes, so they share this index.
    func scoringIndex() -> CodeGraphScoringIndex {
        let key = "\(inventoryFingerprint)|\(generatedAt)|\(nodes.count)"
        return Self.scoringLock.withLock {
            if let scoring = Self.scoring, scoring.key == key { return scoring }
            let built = CodeGraphScoringIndex(self, key: key)
            Self.scoring = built
            return built
        }
    }
    static let folderName = "code-graph"
    static let queryIndexFileName = "query.json"

    var schemaVersion: Int
    var generatedAt: String
    var inventoryFingerprint: String
    var inventory: [CodeGraphFileStamp]
    var coverageComplete: Bool
    var skippedFiles: Int
    /// Per-file parse results are retained so identical contents can reuse their AST extraction.
    var files: [CodeGraphFile]
    /// Flattened query/visualization view.
    var nodes: [CodeGraphNode]
    var edges: [CodeGraphEdge]

    private static let maximumFiles = 12_000
    private static let maximumFileBytes = 300_000
    static let maximumCachedQueryNodeCount = 20_000
    static let maximumCachedQueryEdgeCount = 35_000
    private static let explicitGraphRequestPhrases = [
        "graphify", "project graph", "code graph", "dependency graph", "architecture graph", "relationship graph", "call graph",
        "project map", "code map", "dependency map", "architecture map", "relationship map", "map the project", "map this project",
        "proje harit", "kod harit", "bagimlilik harit", "mimari harit", "iliski harit", "proje graf", "kod graf",
        "bagimlilik graf", "mimari graf", "iliski graf", "cagri graf",
    ]

    static func isExplicitGraphRequest(_ prompt: String) -> Bool {
        let normalized = prompt.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).replacingOccurrences(of: "ı", with: "i")
        return explicitGraphRequestPhrases.contains { normalized.contains($0) }
    }

    static func hasUnsafePathComponent(_ target: URL, in workspace: URL) -> Bool {
        let root = workspace.standardizedFileURL
        let destination = target.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard destination.path.hasPrefix(prefix) else { return true }
        let relative = destination.path.dropFirst(prefix.count)
        var cursor = root
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return true }
        }
        return false
    }

    static func load(from directory: URL) -> ProjectCodeGraph? {
        let graphURL = directory.appendingPathComponent("graph.json")
        guard (try? graphURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data = try? Data(contentsOf: graphURL) else { return nil }
        return try? JSONDecoder().decode(ProjectCodeGraph.self, from: data)
    }

    static func loadQueryIndex(from directory: URL) -> ProjectCodeGraph? {
        let indexURL = directory.appendingPathComponent(queryIndexFileName)
        guard (try? indexURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder().decode(ProjectCodeGraph.self, from: data)
    }

    func queryIndex() -> ProjectCodeGraph {
        ProjectCodeGraph(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            inventoryFingerprint: inventoryFingerprint,
            inventory: inventory,
            coverageComplete: coverageComplete,
            skippedFiles: skippedFiles,
            files: [],
            nodes: nodes,
            // File containment is already represented by each node's path. Omitting these
            // duplicate edges keeps the prompt-time index substantially smaller.
            edges: edges.filter { $0.relation != "CONTAINS" }
        )
    }

    var isCacheableQueryIndex: Bool {
        nodes.count <= Self.maximumCachedQueryNodeCount && edges.count <= Self.maximumCachedQueryEdgeCount
    }

    static func currentInventory(in workspace: URL) -> [CodeGraphFileStamp] {
        let root = workspace.standardizedFileURL
        var result: [CodeGraphFileStamp] = []
        WorkspaceTools.scanFiles(root) { url in
            let ext = url.pathExtension.lowercased()
            guard ProjectCodeParser.languageName(forExtension: ext) != nil else { return true }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return true }
            let fullPath = url.standardizedFileURL.path
            guard fullPath.hasPrefix(root.path + "/") else { return true }
            let relative = String(fullPath.dropFirst(root.path.count + 1))
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            result.append(CodeGraphFileStamp(
                path: relative,
                size: Int64(values.fileSize ?? -1),
                modifiedAtNanoseconds: Int64((modified * 1_000_000_000).rounded())
            ))
            return true
        }
        return result.sorted { $0.path < $1.path }
    }

    static func inventoryFingerprint(_ inventory: [CodeGraphFileStamp]) -> String {
        let text = inventory.map { "\($0.path)\t\($0.size)\t\($0.modifiedAtNanoseconds)" }.joined(separator: "\n")
        return sha256(Data(text.utf8))
    }

    static func isCurrent(_ graph: ProjectCodeGraph, in workspace: URL) -> Bool {
        guard graph.schemaVersion == currentSchemaVersion else { return false }
        let current = currentInventory(in: workspace)
        return current == graph.inventory && inventoryFingerprint(current) == graph.inventoryFingerprint
    }

    static func rebuild(in workspace: URL, reusing previous: ProjectCodeGraph?) -> ProjectCodeGraph {
        let root = workspace.standardizedFileURL
        let inventory = currentInventory(in: root)
        let reusableFiles = previous?.schemaVersion == currentSchemaVersion ? (previous?.files ?? []) : []
        let previousFiles = Dictionary(
            reusableFiles.map { ($0.stamp.path, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var parsed: [CodeGraphFile] = []
        var skipped = 0
        var complete = inventory.count <= maximumFiles

        for stamp in inventory.prefix(maximumFiles) {
            if Task.isCancelled { break }
            guard stamp.size >= 0, stamp.size <= maximumFileBytes else {
                skipped += 1
                complete = false
                continue
            }
            let url = root.appendingPathComponent(stamp.path)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                skipped += 1
                complete = false
                continue
            }
            let digest = sha256(data)
            if let cached = previousFiles[stamp.path], cached.sha256 == digest {
                var reused = cached
                reused.stamp = stamp
                parsed.append(reused)
                continue
            }
            guard let source = String(data: data, encoding: .utf8),
                  let file = ProjectCodeParser.parse(path: stamp.path, source: source, stamp: stamp, digest: digest) else {
                skipped += 1
                complete = false
                continue
            }
            parsed.append(file)
        }

        if Task.isCancelled { complete = false }
        let baseEdges = parsed.flatMap(\.extractedEdges)
        let allNodes = parsed.flatMap(\.nodes)
        let inferred = inferEdges(files: parsed, nodes: allNodes)
        let edges = Dictionary((baseEdges + inferred).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.id < $1.id }
        return ProjectCodeGraph(
            schemaVersion: currentSchemaVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            inventoryFingerprint: inventoryFingerprint(inventory),
            inventory: inventory,
            coverageComplete: complete && parsed.count == inventory.count,
            skippedFiles: skipped + max(0, inventory.count - maximumFiles),
            files: parsed,
            nodes: allNodes.sorted { $0.id < $1.id },
            edges: edges
        )
    }

    private static func inferEdges(files: [CodeGraphFile], nodes: [CodeGraphNode]) -> [CodeGraphEdge] {
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let symbols = nodes.filter { $0.kind != "file" && $0.kind != "import" }
        let names = Dictionary(grouping: symbols, by: \.name)
        let typeSymbols = symbols.filter { isTypeKind($0.kind) }
        let types = Dictionary(grouping: typeSymbols, by: \.name)
        // Namesakes per file: filtering every same-named symbol for each reference was
        // O(references × namesakes), quadratic for names like `body` or `init`.
        let namesInFile = Dictionary(grouping: symbols) { $0.name + "\u{0}" + $0.path }
        let typesInFile = Dictionary(grouping: typeSymbols) { $0.name + "\u{0}" + $0.path }
        let paths = Set(nodes.filter { $0.kind == "file" }.map(\.path))
        var output: [CodeGraphEdge] = []

        for file in files {
            for reference in file.references {
                guard let source = nodesByID[reference.from] else { continue }
                if reference.relation == "RESOLVES_TO" {
                    let targets = resolveLocalImport(reference.name, from: source.path, paths: paths)
                    guard targets.count == 1, let targetPath = targets.first,
                          let target = nodesByID["file:\(targetPath)"] else { continue }
                    output.append(CodeGraphEdge(from: source.id, to: target.id, relation: "RESOLVES_TO", provenance: "INFERRED", confidence: 0.82))
                    continue
                }
                let inherits = reference.relation == "INHERITS"
                let candidates = inherits ? (types[reference.name] ?? []) : (names[reference.name] ?? [])
                let local = (inherits ? typesInFile : namesInFile)[reference.name + "\u{0}" + source.path] ?? []
                let sameFile = local.filter { $0.id != source.id }
                // Only uniqueness matters: two other candidates already rule the reference out.
                let resolved = sameFile.count == 1 ? sameFile : Array(candidates.lazy.filter { $0.id != source.id }.prefix(2))
                guard resolved.count == 1, let target = resolved.first else { continue }
                output.append(CodeGraphEdge(
                    from: source.id,
                    to: target.id,
                    relation: reference.relation,
                    provenance: "INFERRED",
                    confidence: reference.relation == "INHERITS" ? 0.8 : 0.62
                ))
            }
        }
        return output
    }

    private static func resolveLocalImport(_ raw: String, from sourcePath: String, paths: Set<String>) -> [String] {
        let module = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard module.hasPrefix("."), !module.contains("\\") else { return [] }
        let parent = (sourcePath as NSString).deletingLastPathComponent
        let baseURL = URL(fileURLWithPath: parent.isEmpty ? "." : parent, isDirectory: true)
            .appendingPathComponent(module)
            .standardizedFileURL
        let candidateBase = baseURL.path.hasPrefix("/") ? String(baseURL.path.dropFirst()) : baseURL.path
        let baseWithoutExtension = (candidateBase as NSString).deletingPathExtension
        var candidates: Set<String> = [candidateBase, baseWithoutExtension]
        for ext in ProjectCodeParser.supportedExtensions {
            candidates.insert("\(baseWithoutExtension).\(ext)")
            candidates.insert("\(baseWithoutExtension)/index.\(ext)")
        }
        return candidates.intersection(paths).sorted()
    }

    private static func isTypeKind(_ kind: String) -> Bool {
        let value = kind.lowercased()
        return ["class", "struct", "enum", "interface", "trait", "protocol", "actor", "record"].contains { value.contains($0) }
    }

    func context(
        for prompt: String,
        insights: [MemoryInsight],
        projectFacts: [MemoryTransferFact],
        lessons: [Lesson],
        workspace: URL
    ) -> String? {
        guard schemaVersion == Self.currentSchemaVersion else { return nil }
        let terms = FeedbackStore.tokens(prompt)
        guard !terms.isEmpty else { return nil }

        let index = scoringIndex()
        let parsedPaths = index.parsedPaths
        let unparsedPaths = index.unparsed.map(\.path)
        let requestNamesAnUnparsedFile = index.unparsed.contains { file in
            !file.terms.isDisjoint(with: terms) || prompt.localizedCaseInsensitiveContains(file.path)
        }
        // A partial graph can answer a scoped request only when its omissions do not
        // lexically overlap the request. Otherwise the caller uses the established index.
        guard !requestNamesAnUnparsedFile else { return nil }

        var scores: [String: Double] = [:]
        var nodeScores: [String: Double] = [:]
        // Byte search: Foundation's `contains` over 17k names was ~0.1 s per prompt.
        let promptBytes = Array(prompt.lowercased().utf8)
        var starts: [UInt8: [Int]] = [:]
        for (offset, byte) in promptBytes.enumerated() { starts[byte, default: []].append(offset) }
        func promptContains(_ name: [UInt8]) -> Bool {
            guard let first = name.first, let offsets = starts[first] else { return false }
            return offsets.contains { start in
                start + name.count <= promptBytes.count && promptBytes[start..<start + name.count].elementsEqual(name)
            }
        }
        for entry in index.entries {
            let node = nodes[entry.node]
            var score = Double(entry.nameTerms.intersection(terms).count) + Double(entry.pathTerms.intersection(terms).count) * 0.35
            if promptContains(entry.lowerName) { score += 4 }
            if score > 0 {
                nodeScores[node.id] = score
                scores[node.path, default: 0] = max(scores[node.path] ?? 0, score)
            }
        }

        func linkedCodePaths(explicitPaths: [String], evidence: String) -> [String] {
            index.linkedPaths(key: workspace.path + "\0" + explicitPaths.joined(separator: "\0") + "\0" + evidence) {
                Self.linkedCodePaths(explicitPaths: explicitPaths, evidence: evidence, available: parsedPaths, fileTargets: index.fileTargets, symbolNodes: index.symbolNodes, workspace: workspace)
            }
        }
        var findings: [CodeGraphFinding] = []
        for insight in insights {
            let evidence = ([insight.text] + (insight.keywords ?? [])).joined(separator: " ")
            let insightTerms = FeedbackStore.tokens(([insight.text] + insight.files + insight.tools + (insight.keywords ?? [])).joined(separator: " "))
            let overlap = terms.intersection(insightTerms)
            let linkedPaths = linkedCodePaths(explicitPaths: insight.files, evidence: evidence)
            guard !linkedPaths.isEmpty else { continue }
            let weight = min(overlap.count, 4)
            if weight > 0 {
                for path in linkedPaths where parsedPaths.contains(path) {
                    scores[path, default: 0] += Double(weight) * 1.4
                }
            }
            findings.append(CodeGraphFinding(
                id: "insight:\(insight.id)", kind: insight.kind.rawValue, text: insight.text,
                evidence: evidence, paths: linkedPaths, score: weight, updatedAt: insight.updatedAt
            ))
        }
        for fact in projectFacts {
            let evidence = "\(fact.key) \(fact.text)"
            let linkedPaths = linkedCodePaths(explicitPaths: [], evidence: evidence)
            guard !linkedPaths.isEmpty else { continue }
            let factTerms = FeedbackStore.tokens(evidence)
            let weight = min(terms.intersection(factTerms).count, 4)
            if weight > 0 {
                for path in linkedPaths where parsedPaths.contains(path) {
                    scores[path, default: 0] += Double(weight) * 1.4
                }
            }
            findings.append(CodeGraphFinding(
                id: "project-fact:\(fact.key)", kind: fact.kind, text: fact.text,
                evidence: evidence, paths: linkedPaths, score: weight, updatedAt: ""
            ))
        }
        for lesson in lessons where !lesson.paths.isEmpty && lesson.isActive() {
            let evidence = lesson.cited + " " + lesson.when + " " + lesson.rule + " " + lesson.why
            let linkedPaths = Self.lessonCodePaths(scopes: lesson.paths, available: parsedPaths, workspace: workspace)
            guard !linkedPaths.isEmpty else { continue }
            let lessonTerms = FeedbackStore.tokens(evidence + " " + lesson.paths.joined(separator: " "))
            let weight = min(terms.intersection(lessonTerms).count, 4)
            if weight > 0 {
                for path in linkedPaths where parsedPaths.contains(path) {
                    scores[path, default: 0] += Double(weight) * 1.4
                }
            }
            findings.append(CodeGraphFinding(
                id: "lesson:\(lesson.id)", kind: "lesson", text: lesson.cited,
                evidence: evidence + " " + lesson.paths.joined(separator: " "), paths: linkedPaths,
                score: weight, updatedAt: lesson.lastSeen.ISO8601Format()
            ))
        }

        let ranked = scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let best = ranked.first, best.value >= 1 else { return nil }
        if ranked.count > 1, best.value - ranked[1].value < 0.2 { return nil }
        let selectedPaths = ranked.filter { $0.value >= best.value * 0.48 }.prefix(3).map(\.key)
        guard !selectedPaths.isEmpty else { return nil }

        let selected = Set(selectedPaths)
        let visibleFiles = nodes.filter { $0.kind == "file" && selected.contains($0.path) }
        var includedIDs = Set(visibleFiles.map(\.id))
        var visibleNodes = visibleFiles
        for path in selectedPaths {
            let symbols = nodes.filter { $0.path == path && $0.kind != "file" && $0.kind != "import" }
                .sorted { (nodeScores[$0.id] ?? 0) == (nodeScores[$1.id] ?? 0) ? $0.id < $1.id : (nodeScores[$0.id] ?? 0) > (nodeScores[$1.id] ?? 0) }
                .prefix(8)
            for node in symbols where includedIDs.insert(node.id).inserted { visibleNodes.append(node) }
        }

        let linked = findings
            .filter { !$0.paths.filter(selected.contains).isEmpty }
            .sorted { $0.score == $1.score ? $0.updatedAt > $1.updatedAt : $0.score > $1.score }
            .prefix(4)
        var memoryEdges: [CodeGraphEdge] = []
        for item in linked {
            let insightID = item.id
            visibleNodes.append(CodeGraphNode(
                id: insightID,
                kind: "memory-\(item.kind)",
                name: item.text,
                path: "",
                line: 0,
                language: "memory",
                signature: nil
            ))
            let mentions = ExplicitMentions(item.evidence)
            for path in item.paths where selected.contains(path) {
                let fileID = "file:\(path)"
                memoryEdges.append(CodeGraphEdge(from: insightID, to: fileID, relation: "RELATES_TO", provenance: "MEMORY", confidence: 1))
                let mentionedSymbols = nodes.filter {
                    $0.path == path && $0.kind != "file" && $0.kind != "import" && mentions.contains($0.name)
                }
                // A finding names a symbol only when one declaration in this file
                // matches its saved text. Otherwise its persisted association is file-level.
                if mentionedSymbols.count == 1, let symbol = mentionedSymbols.first {
                    memoryEdges.append(CodeGraphEdge(from: insightID, to: symbol.id, relation: "RELATES_TO", provenance: "MEMORY", confidence: 1))
                }
            }
        }

        // Add two relationship hops so a selected file can show file -> import -> local file.
        let seedIDs = Set(visibleNodes.filter { $0.kind != "memory-decision" && $0.kind != "memory-lesson" && $0.kind != "memory-error" && $0.kind != "memory-area" }.map(\.id))
        let byID = index.byID
        var frontier = seedIDs
        for _ in 0..<2 {
            let neighborhood = edges.filter { frontier.contains($0.from) || frontier.contains($0.to) }
            var nextFrontier = Set<String>()
            for edge in neighborhood {
                for endpoint in [edge.from, edge.to] where !includedIDs.contains(endpoint) {
                    guard let node = byID[endpoint], includedIDs.count < 35 else { continue }
                    visibleNodes.append(node)
                    includedIDs.insert(endpoint)
                    nextFrontier.insert(endpoint)
                }
            }
            frontier = nextFrontier
            if frontier.isEmpty { break }
        }
        let visibleIDSet = Set(visibleNodes.map(\.id))
        let visibleEdges = (edges + memoryEdges)
            .filter { visibleIDSet.contains($0.from) && visibleIDSet.contains($0.to) }
            .sorted { $0.id < $1.id }
            .prefix(60)

        let nodeLines = visibleNodes.prefix(35).map { node in
            let location = node.path.isEmpty ? "memory" : "\(node.path):\(node.line)"
            let signature = node.signature.map { " — \($0.prefix(120))" } ?? ""
            return "- `\(node.id)` [\(node.kind)] \(location)\(signature)"
        }
        let edgeLines = visibleEdges.map { edge in
            "- `\(edge.from)` —\(edge.relation) [\(edge.provenance), \(String(format: "%.2f", edge.confidence))]→ `\(edge.to)`"
        }
        let coverageNote = unparsedPaths.isEmpty ? "" : "\n### Coverage note\n\(unparsedPaths.count) source files were not parsed. Their filenames do not match this request, but inspect them if source review suggests they are relevant. Omitted paths: \(unparsedPaths.prefix(8).map { "`\($0)`" }.joined(separator: ", "))."
        return [
            "## Relevant code graph (fresh local Tree-sitter index)",
            "This is a query-sized subgraph, not the full repository graph. Verify every finding in the source files.",
            "### Nodes",
            nodeLines.isEmpty ? "- None" : nodeLines.joined(separator: "\n"),
            "### Relationships",
            edgeLines.isEmpty ? "- None" : edgeLines.joined(separator: "\n"),
            "### Source files to inspect",
            selectedPaths.map { "- `\($0)`" }.joined(separator: "\n"),
        ].joined(separator: "\n") + coverageNote
    }

    func jsonData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    func queryIndexData() -> Data? {
        queryIndex().jsonData()
    }

    func report() -> String {
        let languages = Dictionary(grouping: files.flatMap(\.nodes).filter { $0.kind == "file" }, by: \.language)
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "- \($0.key): \($0.value) files" }
            .joined(separator: "\n")
        return [
            "# Project code graph",
            "",
            "- Updated: \(generatedAt)",
            "- Schema: \(schemaVersion)",
            "- Source files in freshness inventory: \(inventory.count)",
            "- Parsed files: \(files.count)",
            "- Nodes: \(nodes.count)",
            "- Edges: \(edges.count)",
            "- Tree-sitter coverage complete for indexed extensions: \(coverageComplete ? "yes" : "no")",
            "- Skipped files: \(skippedFiles)",
            "- Prompt-time lookup: `\(Self.queryIndexFileName)` (compact symbols and relationships)",
            "- Unsupported extensions are outside this inventory and use the existing file-index fallback.",
            "",
            "## Languages",
            "",
            languages.isEmpty ? "- None" : languages,
            "",
            "## Relationship provenance",
            "",
            "- `EXTRACTED`: the parser found the structure or import in source.",
            "- `INFERRED`: a unique local symbol or module match resolved a reference; confidence is included in `graph.json`.",
            "- Query context may add a `MEMORY` link from a saved finding to its named file; a symbol link is added only when exactly one declaration in that file is named.",
            "",
            "## Rebuild behavior",
            "",
            "Source files are scanned locally. A content SHA-256 match reuses the previous per-file graph; changed contents are parsed again. User preferences and project findings are stored separately from this code-only graph.",
            "",
        ].joined(separator: "\n")
    }

    private static func normalizedMemoryPath(_ path: String, workspace: URL) -> String {
        let root = workspace.standardizedFileURL.path
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }

    private static func linkedCodePaths(
        explicitPaths: [String],
        evidence: String,
        available: Set<String>,
        fileTargets: [(node: CodeGraphNode, path: ExplicitMentions.Target, name: ExplicitMentions.Target)],
        symbolNodes: [(node: CodeGraphNode, name: ExplicitMentions.Target)],
        workspace: URL
    ) -> [String] {
        let saved = Set(explicitPaths.map { normalizedMemoryPath($0, workspace: workspace) }).intersection(available)
        if !saved.isEmpty { return saved.sorted() }

        let mentions = ExplicitMentions(evidence)
        let namedFiles = fileTargets.filter { mentions.contains($0.path) || mentions.contains($0.name) }
        if namedFiles.count == 1, let file = namedFiles.first { return [file.node.path] }
        if namedFiles.count > 1 { return [] }

        let namedSymbols = symbolNodes.filter { mentions.contains($0.name) }
        guard namedSymbols.count == 1, let symbol = namedSymbols.first else { return [] }
        return [symbol.node.path]
    }

    private static func lessonCodePaths(
        scopes: [String],
        available: Set<String>,
        workspace: URL
    ) -> [String] {
        return Set(scopes.flatMap { scope -> [String] in
            let path = normalizedMemoryPath(scope, workspace: workspace)
            guard !path.isEmpty, path != "..", !path.hasPrefix("../") else { return [] }
            return available.filter { candidate in
                candidate == path || candidate.hasPrefix(path.hasSuffix("/") ? path : path + "/")
            }
        }).sorted()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension WorkspaceMemory {
    var codeGraphDirectory: URL? { memoryDirectory?.appendingPathComponent(ProjectCodeGraph.folderName, isDirectory: true) }

    func relevantCodeGraphText(for prompt: String, lessons: [Lesson] = []) -> String? {
        guard enabled, let workspaceURL, let directory = codeGraphDirectory else { return nil }
        let explicitGraphRequest = ProjectCodeGraph.isExplicitGraphRequest(prompt)
        guard !ProjectCodeGraph.hasUnsafePathComponent(directory, in: workspaceURL) else {
            codeGraphCache = nil
            return nil
        }

        guard let graph = codeGraphCache else {
            if explicitGraphRequest {
                scheduleCodeGraphUpdateInBackground()
            } else {
                scheduleCodeGraphLookupLoadInBackground()
            }
            return nil
        }
        // The freshness check lists and stats every source file; on the main actor it
        // stalled every prompt. ponytail: verified off-main after use, so one prompt right
        // after an edit can still get the previous graph's hints; await the check if that matters.
        verifyCodeGraphInBackground(graph, workspace: workspaceURL)
        if let prepared = preparedCodeGraphContext, prepared.prompt == prompt { return prepared.text }
        return graph.context(
            for: prompt,
            insights: insights,
            projectFacts: projectMemoryFacts(),
            lessons: lessons,
            workspace: workspaceURL
        )
    }

    /// Scoring walks every graph node (up to 20k) and froze the UI for ~0.3 s per prompt
    /// on the main actor. Run it on a worker before the prompt is built; the synchronous
    /// lookup above then returns this result for the same prompt.
    func prepareCodeGraphContext(for prompt: String, lessons: [Lesson]) async {
        guard enabled, let workspaceURL, let graph = codeGraphCache else { return }
        let generation = codeGraphGeneration
        let insights = insights
        let facts = projectMemoryFacts()
        let text = await Task.detached(priority: .userInitiated) {
            AppBackgroundWorkLimiter.withPermit {
                graph.context(for: prompt, insights: insights, projectFacts: facts, lessons: lessons, workspace: workspaceURL)
            }
        }.value
        guard generation == codeGraphGeneration, self.workspaceURL == workspaceURL else { return }
        preparedCodeGraphContext = (prompt, text)
    }

    private func verifyCodeGraphInBackground(_ graph: ProjectCodeGraph, workspace: URL) {
        guard !codeGraphCheckInFlight else { return }
        codeGraphCheckInFlight = true
        Task { @MainActor [weak self] in
            let current = await MemoryWorkQueue.run {
                ProjectCodeGraph.isCurrent(graph, in: workspace)
            }
            guard let self else { return }
            self.codeGraphCheckInFlight = false
            guard !current, self.workspaceURL == workspace else { return }
            self.codeGraphCache = nil
            self.scheduleCodeGraphUpdateInBackground()
        }
    }

    func scheduleCodeGraphLookupLoadInBackground() {
        guard enabled,
              let workspace = workspaceURL?.standardizedFileURL,
              let directory = codeGraphDirectory,
              let projectID,
              !ProjectCodeGraph.hasUnsafePathComponent(directory, in: workspace) else { return }
        let requestKey = workspace.path
        guard codeGraphLookupLoadAttempted.insert(requestKey).inserted else { return }
        Task { @MainActor [weak self] in
            let result = await MemoryWorkQueue.run { () -> (graph: ProjectCodeGraph?, needsRefresh: Bool) in
                guard !ProjectCodeGraph.hasUnsafePathComponent(directory, in: workspace) else { return (nil, false) }
                if let queryIndex = ProjectCodeGraph.loadQueryIndex(from: directory) {
                    // Both files are written together from one inventory: a stale index
                    // means a stale graph.json too. Decoding that (~40 MB) only to learn it
                    // is stale, then again inside the rebuild, cost ~150 MB of peak heap.
                    guard ProjectCodeGraph.isCurrent(queryIndex, in: workspace) else { return (nil, true) }
                    _ = queryIndex.scoringIndex() // built here, not by the first prompt
                    return (queryIndex, false)
                }
                // A project does not need an explicit "build graph" request. The first
                // ordinary code prompt starts the graph after this fast lookup misses.
                guard let fullGraph = ProjectCodeGraph.load(from: directory) else { return (nil, true) }
                guard ProjectCodeGraph.isCurrent(fullGraph, in: workspace) else { return (nil, true) }

                // Upgrade an existing full graph without rebuilding the project.
                let queryIndex = fullGraph.queryIndex()
                let indexURL = directory.appendingPathComponent(ProjectCodeGraph.queryIndexFileName)
                if !ProjectCodeGraph.hasUnsafePathComponent(indexURL, in: workspace),
                   let data = queryIndex.jsonData() {
                    try? data.write(to: indexURL, options: .atomic)
                }
                return (queryIndex, false)
            }
            guard let self else { return }
            guard self.enabled,
                  self.workspaceURL?.standardizedFileURL == workspace,
                  self.projectID == projectID else { return }
            if let graph = result.graph, graph.isCacheableQueryIndex {
                self.codeGraphCache = graph
            } else {
                self.codeGraphLookupLoadAttempted.remove(requestKey)
                if result.needsRefresh { self.scheduleCodeGraphUpdateInBackground() }
            }
        }
    }

    func scheduleCodeGraphUpdateInBackground() {
        guard enabled,
              let workspace = workspaceURL?.standardizedFileURL,
              let directory = codeGraphDirectory,
              let projectID,
              !ProjectCodeGraph.hasUnsafePathComponent(directory, in: workspace) else { return }
        let requestKey = workspace.path
        guard codeGraphRefreshInFlight.insert(requestKey).inserted else { return }
        Task { @MainActor [weak self] in
            let graph = await MemoryWorkQueue.run {
                // A large graph.json takes a second to decode: never on the main actor.
                ProjectCodeGraph.rebuild(in: workspace, reusing: ProjectCodeGraph.load(from: directory))
            }
            guard let self else { return }
            guard self.enabled,
                  self.workspaceURL?.standardizedFileURL == workspace,
                  self.projectID == projectID,
                  !ProjectCodeGraph.hasUnsafePathComponent(directory, in: workspace) else {
                self.codeGraphRefreshInFlight.remove(requestKey)
                return
            }

            let persisted = await MemoryWorkQueue.run {
                let jsonURL = directory.appendingPathComponent("graph.json")
                let queryURL = directory.appendingPathComponent(ProjectCodeGraph.queryIndexFileName)
                let reportURL = directory.appendingPathComponent("GRAPH_REPORT.md")
                guard !ProjectCodeGraph.hasUnsafePathComponent(directory, in: workspace),
                      !ProjectCodeGraph.hasUnsafePathComponent(jsonURL, in: workspace),
                      !ProjectCodeGraph.hasUnsafePathComponent(queryURL, in: workspace),
                      !ProjectCodeGraph.hasUnsafePathComponent(reportURL, in: workspace) else { return false }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    do {
                        guard let data = graph.jsonData() else { return false }
                        try data.write(to: jsonURL, options: .atomic)
                    }
                    do {
                        guard let data = graph.queryIndexData() else { return false }
                        try data.write(to: queryURL, options: .atomic)
                    }
                    do {
                        let report = graph.report()
                        try report.write(to: reportURL, atomically: true, encoding: .utf8)
                    }
                    // graph.html (~14 MB, ~2 s to build) was rewritten on every rebuild and
                    // read by nothing; an older copy would only show a stale graph.
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("graph.html"))
                    _ = graph.scoringIndex()
                    return true
                } catch {
                    return false
                }
            }

            self.codeGraphRefreshInFlight.remove(requestKey)
            guard persisted else { return }
            let queryIndex = graph.queryIndex()
            self.codeGraphCache = queryIndex.isCacheableQueryIndex ? queryIndex : nil
        }
    }
}
