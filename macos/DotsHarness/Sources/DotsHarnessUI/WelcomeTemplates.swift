// Copyright (c) 2026 DOTS
// Offline welcome-card prompts + a lightweight project stack sniff.

import Foundation
import DotsHarnessCore

/// Best-effort language/stack detection from root manifest files. Returns a short
/// display name (e.g. "Swift", "TypeScript") or nil when nothing recognizable is found.
@MainActor
enum ProjectStackSniffer {
    // ponytail: per-session cache; a stack change needs a restart to show in welcome cards.
    private static var cache: [String: String?] = [:]

    /// Called from view bodies (every keystroke on the welcome screen), so the
    /// file-system probe runs once per workspace path.
    static func detect(at workspacePath: String) -> String? {
        if let cached = cache[workspacePath] { return cached }
        let stack = sniff(at: workspacePath)
        cache[workspacePath] = stack
        return stack
    }

    private static func sniff(at workspacePath: String) -> String? {
        guard !workspacePath.isEmpty else { return nil }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)

        func has(_ name: String) -> Bool {
            fm.fileExists(atPath: root.appendingPathComponent(name).path)
        }
        func hasEntry(withSuffix suffix: String) -> Bool {
            (try? fm.contentsOfDirectory(atPath: workspacePath))?.contains { $0.hasSuffix(suffix) } ?? false
        }

        if has("Package.swift") { return "Swift" }
        if has("pubspec.yaml") { return "Flutter/Dart" }
        if has("package.json") { return has("tsconfig.json") ? "TypeScript" : "JavaScript" }
        if has("Cargo.toml") { return "Rust" }
        if has("go.mod") { return "Go" }
        if has("pyproject.toml") || has("requirements.txt") || has("setup.py") || has("Pipfile") { return "Python" }
        if has("pom.xml") || has("build.gradle") || has("build.gradle.kts")
            || has("settings.gradle") || has("settings.gradle.kts") { return "Java/Kotlin" }
        if has("Gemfile") { return "Ruby" }
        if has("composer.json") { return "PHP" }
        if hasEntry(withSuffix: ".csproj") || hasEntry(withSuffix: ".sln") || hasEntry(withSuffix: ".fsproj") { return ".NET" }
        return nil
    }
}

struct WelcomeCard: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let prompt: String
}

enum WelcomeCatalog {
    /// The four Claude-Code-style actions, in fixed order.
    static func cards(projectName: String, stack: String?) -> [WelcomeCard] {
        // Prompts always name the project; the stack, when known, is appended in
        // parens. A single `%@` per prompt key keeps the l10n parity checker happy.
        let scope = stack.map { "\(projectName) (\($0))" } ?? projectName
        return [
            card("explore", icon: "text.magnifyingglass", scope: scope),
            card("build", icon: "hammer", scope: scope),
            card("review", icon: "checkmark.seal", scope: scope),
            card("fix", icon: "ladybug", scope: scope),
        ]
    }

    private static func card(_ id: String, icon: String, scope: String) -> WelcomeCard {
        WelcomeCard(
            id: id,
            icon: icon,
            title: AppCopy.text("welcome.card.\(id).title"),
            subtitle: AppCopy.text("welcome.card.\(id).subtitle"),
            prompt: AppCopy.format("welcome.card.\(id).prompt", scope)
        )
    }
}
