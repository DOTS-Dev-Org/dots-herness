// Copyright (c) 2026 DOTS
// The facts file: `.mem/facts.md`, the one store every HerNess client reads
// and writes. Windows, Linux and the phones keep project facts and preferences
// there as keyed lines; this host keeps them in the signed event log. Each
// change made here is copied into the file, and whatever another client put
// there is read back, so a fact recorded on one machine is known on the others.
//
// Mirrors the file format of shared/WorkspaceFacts.cs.

import Foundation

extension WorkspaceMemory {
    struct Fact: Equatable {
        var kind: String
        var key: String
        var text: String
    }

    static let factKinds = ["project", "preference", "decision"]

    private var factsURL: URL? { memoryDirectory?.appendingPathComponent("facts.md") }

    func readFacts() -> [Fact] {
        guard let factsURL, let body = try? String(contentsOf: factsURL, encoding: .utf8) else { return [] }
        var facts: [Fact] = []
        var kind = ""
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                kind = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
            } else if line.hasPrefix("- "), !kind.isEmpty, let separator = line.range(of: " — ") {
                let key = line[line.index(line.startIndex, offsetBy: 2)..<separator.lowerBound]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " `"))
                let text = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !text.isEmpty { facts.append(Fact(kind: kind, key: key, text: text)) }
            }
        }
        return facts
    }

    /// What the file holds of one kind that the event log does not.
    func foreignFacts(_ kind: String, knownKeys: Set<String>) -> [String: String] {
        Dictionary(
            readFacts().filter { $0.kind == kind && !knownKeys.contains($0.key) }.map { ($0.key, $0.text) },
            uniquingKeysWith: { _, later in later }
        )
    }

    /// Copies this host's project entries and the current actor's preferences
    /// into the file, leaving every other line as it is. `removing` drops an
    /// entry the user took back; without it the file would hand it straight back.
    func syncFacts(removing: Fact? = nil) {
        guard let factsURL, manifest != nil else { return }
        let existing = readFacts()
        var facts = existing.filter { $0.kind != removing?.kind || $0.key != removing?.key }
        let preferences = identity.flatMap { (state["activePreferences"] as? [String: Any])?[$0.personID] as? [String: Any] } ?? [:]
        let own = ((state["projectDefaults"] as? [String: Any]) ?? [:]).map { Fact(kind: "project", key: $0.key, text: "\($0.value)") }
            + preferences.map { Fact(kind: "preference", key: $0.key, text: "\($0.value)") }
        for fact in own.sorted(by: { ($0.kind, $0.key) < ($1.kind, $1.key) }) {
            if let index = facts.firstIndex(where: { $0.kind == fact.kind && $0.key == fact.key }) {
                facts[index] = fact
            } else {
                facts.append(fact)
            }
        }
        guard facts != existing else { return }
        let kinds = Self.factKinds + Set(facts.map(\.kind)).subtracting(Self.factKinds).sorted()
        let body = kinds.compactMap { kind -> String? in
            let lines = facts.filter { $0.kind == kind }.map { "- \($0.key) — \($0.text)" }
            return lines.isEmpty ? nil : "## \(kind)\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        try? (body.isEmpty ? "" : body + "\n").write(to: factsURL, atomically: true, encoding: .utf8)
    }
}
