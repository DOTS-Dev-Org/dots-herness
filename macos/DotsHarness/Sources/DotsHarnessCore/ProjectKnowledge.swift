// Copyright (c) 2026 DOTS
// What HerNess knows about the project itself, beyond the user's preferences
// and its own mistakes: how the code is laid out, the conventions it follows
// and the design system its interface is built from. A request as short as
// "arayüzü düzelt" names none of these, so the area it belongs to is read from
// its words and the matching knowledge and lessons are handed over with it.

import Foundation

/// The part of a project a request or a file belongs to.
public enum PromptArea: String, CaseIterable, Sendable {
    case ui, api, data, test, build

    /// Words that place a request in the area, Turkish and English, written
    /// already folded. A word matches when it starts with one of them, which
    /// covers Turkish suffixes ("arayuzu", "renkleri"); the two- and
    /// three-letter ones must match whole.
    var keywords: [String] {
        switch self {
        case .ui:
            return ["ui", "ux", "css", "arayuz", "tasarim", "tema", "renk", "gorunum", "ekran", "buton", "stil", "ikon",
                    "bilesen", "karanlik", "animasyon", "interface", "design", "theme", "color", "colour", "style",
                    "screen", "button", "layout", "font", "icon", "component", "frontend", "dark", "spacing", "padding",
                    "margin", "animation", "responsive"]
        case .api:
            return ["api", "endpoint", "istek", "sunucu", "request", "route", "server", "backend", "http", "webhook"]
        case .data:
            return ["db", "sql", "veritaban", "tablo", "sema", "sorgu", "database", "migration", "table", "schema", "query"]
        case .test:
            return ["test", "spec", "mock", "coverage"]
        case .build:
            return ["ci", "derle", "yayin", "paket", "bagimlilik", "build", "compile", "deploy", "release", "pipeline",
                    "package", "dependency"]
        }
    }

    /// Path fragments of the files that make up the area.
    private var pathMarkers: [String] {
        switch self {
        case .ui:
            return [".css", ".scss", ".html", ".vue", ".svelte", ".tsx", ".jsx", ".xaml", ".axaml", ".storyboard", ".xib",
                    "view", "screen", "component", "theme", "style", "color", "layout", "widget", "ui/"]
        case .api: return ["api", "route", "controller", "handler", "endpoint"]
        case .data: return [".sql", "migration", "schema", "repository", "database"]
        case .test: return ["test", "spec"]
        case .build: return ["package.json", ".csproj", "gradle", "package.swift", "dockerfile", ".github/workflows"]
        }
    }

    public func covers(path: String) -> Bool {
        let lower = path.lowercased()
        return pathMarkers.contains { lower.contains($0) }
    }

    public static func areas(in text: String) -> Set<PromptArea> {
        let words = FeedbackStore.folded(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(allCases.filter { area in
            area.keywords.contains { keyword in
                words.contains { keyword.count <= 3 ? $0 == keyword : $0.hasPrefix(keyword) }
            }
        })
    }
}

/// A change a person makes to memory from the vault.
public enum MemoryEdit: Sendable, Equatable {
    case setProject(key: String, value: String)
    case forgetProject(key: String)
    case pinLesson(id: String)
    case forgetLesson(id: String)
    case editLesson(id: String, rule: String)
    case setManualRules(String)
}

public enum ProjectKnowledge {
    /// Project facts learned from the code rather than asked of the user. They
    /// are stored like any other project default, under these keys.
    public static let keys = ["architecture", "conventions", "design-system"]

    /// An ordinary fact is one sentence; these describe a whole codebase.
    public static func limit(forKey key: String) -> Int {
        keys.contains(key) ? 1_200 : 240
    }

    /// Asked only while an entry is missing, so a project is studied once.
    /// ponytail: an entry is refreshed when the agent notices the code disagrees
    /// with it (see the durable-memory guidance), not by hashing its source
    /// files; add the hash if entries are seen going stale unnoticed.
    static func guidance(missing: [String], explore: Bool = true) -> String {
        guard !missing.isEmpty else { return "" }
        let wanted = [
            "architecture": "the modules and layers, and how a request flows through them.",
            "conventions": "naming, file layout, error handling, how tests are written and run.",
            "design-system": "where colors, typography, spacing and shared components are defined, with their "
                + "names and values. Needed before the first change to anything the user sees; record \"none\" for "
                + "a project without an interface.",
        ]
        return """


        Project knowledge
        - <project_memory> has no entry yet for: \(missing.joined(separator: ", ")).
        - Before the first real change to this project, learn the missing ones from the code\(explore ? " - delegate the\n  sweep to explore -" : "") and record each with remember (kind "project", that key), in at most 1,200
          characters, naming the files it comes from.
        \(missing.map { "- \($0): \(wanted[$0] ?? "")" }.joined(separator: "\n"))
        - Skip this for a one-off question or a trivial edit.
        """
    }
}
