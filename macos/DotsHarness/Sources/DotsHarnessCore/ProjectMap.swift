// Copyright (c) 2026 DOTS
// The project's layout two folders deep, written into the project map so the agent
// knows where things live without listing or searching the workspace: per folder
// one line on what it is - from its README, its manifest, or the kinds of
// file it holds - and the files to open first. Built from git's file list (the walk
// elsewhere), with no model.
//
// Mirrors shared/ProjectMap.cs on Windows and Linux.

import Foundation

enum ProjectMap {
    static let maxFiles = 20_000
    private static let maxFolders = 30, maxSubfolders = 8, maxEntries = 4, maxPurpose = 100

    private static let manifests: [String: String] = [
        "package.swift": "Swift package", "package.json": "Node package", "cargo.toml": "Rust crate",
        "go.mod": "Go module", "pyproject.toml": "Python project", "requirements.txt": "Python project",
        "build.gradle": "Gradle project", "build.gradle.kts": "Gradle project", "settings.gradle": "Gradle project",
        "settings.gradle.kts": "Gradle project", "wrangler.toml": "Cloudflare Worker", "wrangler.jsonc": "Cloudflare Worker",
        "project.yml": "XcodeGen project", "pubspec.yaml": "Dart package", "composer.json": "PHP package",
        "gemfile": "Ruby project", "pom.xml": "Maven project", "cmakelists.txt": "CMake project",
        "makefile": "", "dockerfile": "",
    ]
    private static let entryStems: Set<String> = ["main", "index", "program", "app", "server", "startup", "appdelegate"]

    /// Workspace-relative paths of the files the map counts.
    static func files(in workspace: URL) -> [String] {
        var files: [String] = []
        let root = workspace.standardizedFileURL
        WorkspaceTools.scanFiles(root) { url in
            files.append(WorkspaceTools.relativePath(url, workspace: root))
            return files.count < maxFiles
        }
        return files
    }

    /// The map of a file list; `read` returns the start of a file, or nil.
    static func markdown(_ files: [String], read: (String) -> String?) -> String {
        let folders = Dictionary(grouping: files.filter { $0.contains("/") }) { String($0[..<$0.firstIndex(of: "/")!]) }
        guard !folders.isEmpty else { return "" }
        var lines = [
            "## Structure",
            "Folders two levels deep: what each holds, the files to open first. Start from these instead of listing or searching the workspace.",
        ]
        let rootEntries = entries("", files)
        if !rootEntries.isEmpty { lines.append("- root - open: \(rootEntries)") }
        let names = folders.keys.sorted()
        for name in names.prefix(maxFolders) {
            let inside = folders[name]!
            lines.append("- " + line(name, inside, read))
            let subfolders = Dictionary(grouping: inside.filter { $0.dropFirst(name.count + 1).contains("/") }) { path -> String in
                let rest = path.dropFirst(name.count + 1)
                return name + "/" + rest[..<rest.firstIndex(of: "/")!]
            }.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            for (subfolder, files) in subfolders.prefix(maxSubfolders) {
                lines.append("  - " + line(subfolder, files, read))
            }
            if subfolders.count > maxSubfolders { lines.append("  - +\(subfolders.count - maxSubfolders) more folders") }
        }
        if names.count > maxFolders { lines.append("- +\(names.count - maxFolders) more folders") }
        return lines.joined(separator: "\n")
    }

    private static func line(_ folder: String, _ inside: [String], _ read: (String) -> String?) -> String {
        // No file count: it moves with every added file and forces project_memory to be captured again.
        let line = "`\(folder)/` - \(purpose(folder, inside, read))"
        let found = entries(folder, inside)
        return found.isEmpty ? line : line + " - open: " + found
    }

    /// Files directly in `folder` worth opening first: its README, manifests, entry points.
    private static func entries(_ folder: String, _ files: [String]) -> String {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var ranked: [(name: String, rank: Int)] = []
        for path in files where path.hasPrefix(prefix) {
            let name = String(path.dropFirst(prefix.count))
            if !name.contains("/"), let value = rank(name) { ranked.append((name, value)) }
        }
        ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.name < $1.name }
        return ranked.prefix(maxEntries).map(\.name).joined(separator: ", ")
    }

    private static func rank(_ name: String) -> Int? {
        if name.uppercased().hasPrefix("README") { return 0 }
        let ext = (name as NSString).pathExtension
        if manifests[name.lowercased()] != nil || ext == "csproj" || ext == "sln" { return 1 }
        return entryStems.contains((name as NSString).deletingPathExtension.lowercased()) ? 2 : nil
    }

    /// The first sentence of the folder's README, else its manifest's kind and its main file types.
    private static func purpose(_ folder: String, _ inside: [String], _ read: (String) -> String?) -> String {
        let direct = inside.map { String($0.dropFirst(folder.count + 1)) }.filter { !$0.contains("/") }.sorted()
        if let readme = direct.first(where: { $0.uppercased().hasPrefix("README") }),
           let summary = firstLine(read("\(folder)/\(readme)")) { return summary }
        if direct.contains("package.json"), let description = description(read("\(folder)/package.json")) { return description }
        let kind = direct.lazy.compactMap { name -> String? in
            let ext = (name as NSString).pathExtension
            let value = manifests[name.lowercased()] ?? (ext == "csproj" || ext == "sln" ? ".NET project" : nil)
            return value?.isEmpty == false ? value : nil
        }.first
        var counts: [String: Int] = [:]
        for path in inside {
            let ext = (path as NSString).pathExtension
            if !ext.isEmpty { counts["." + ext.lowercased(), default: 0] += 1 }
        }
        let types = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2).map(\.key)
        let mostly = types.isEmpty ? "" : "mostly " + types.joined(separator: ", ")
        guard let kind else { return mostly.isEmpty ? "files" : mostly }
        return mostly.isEmpty ? kind : "\(kind), \(mostly)"
    }

    /// The first prose line of a Markdown file: no heading, badge, HTML, rule or list marker.
    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count >= 8, let first = line.first, !"#![<=-*|>`".contains(first) else { continue }
            return line.count <= maxPurpose ? line : String(line.prefix(maxPurpose)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return nil
    }

    /// package.json's description, matched rather than parsed: only the file's start is read.
    private static func description(_ json: String?) -> String? {
        guard let json, let match = json.range(of: #""description"\s*:\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        let found = json[match]
        guard let colon = found.firstIndex(of: ":") else { return nil }
        let value = found[found.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return firstLine(value)
    }

    /// The start of a file, enough for its first lines.
    static func head(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_096) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
