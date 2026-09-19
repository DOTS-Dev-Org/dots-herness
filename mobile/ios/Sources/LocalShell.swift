import Foundation
import CryptoKit

/// The terminal that runs *inside the app*.
///
/// iOS sandboxes every process: `fork`/`exec` is unavailable and JIT is not
/// permitted, so a real shell is impossible here — an app cannot launch `sh`,
/// `git`, or `node` no matter how it is packaged. What it *can* do is implement
/// the commands itself over the workspace mirror, which is what this is: a small
/// POSIX-shaped command set with pipelines, redirection, and `&&`, all confined
/// to the workspace root.
///
/// Android uses the same constrained virtual command set; see `LocalShell.kt`.
@MainActor
final class LocalShell: ObservableObject {
    @Published private(set) var lines: [String] = []
    /// Working directory, always workspace-relative ("" is the root).
    @Published private(set) var directory = ""

    private let store: LocalWorkspaceStore
    private var variables: [String: String] = [:]

    init(store: LocalWorkspaceStore) { self.store = store }

    static let commands = ["cd", "pwd", "ls", "cat", "head", "tail", "echo", "mkdir", "rm", "mv", "cp",
                           "touch", "wc", "grep", "find", "sed", "sort", "uniq", "sha256", "tree",
                           "env", "export", "sqlite", "clear", "help"]

    func append(_ text: String) { lines.append(text); if lines.count > 2_000 { lines.removeFirst(lines.count - 2_000) } }

    /// Runs one command line and returns everything it wrote. The transcript is
    /// also appended so the terminal view and the agent see the same history.
    @discardableResult
    func run(_ line: String) async -> String {
        append("\(prompt) \(line)")
        let output = execute(line)
        if !output.isEmpty { append(output) }
        return output
    }

    var prompt: String { "/\(directory)" }

    func execute(_ line: String) -> String {
        var output = ""
        for clause in splitTopLevel(line, separator: "&&") {
            let result = pipeline(clause)
            output += result.text
            if result.failed { break }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    // MARK: - Pipelines and redirection

    private func pipeline(_ clause: String) -> (text: String, failed: Bool) {
        var clause = clause.trimmingCharacters(in: .whitespaces)
        guard !clause.isEmpty else { return ("", false) }

        var redirect: (path: String, append: Bool)?
        if let range = clause.range(of: ">>", options: .backwards) ?? clause.range(of: ">", options: .backwards) {
            let isAppend = clause[range] == ">>"
            let target = clause[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !target.isEmpty, !target.contains(" ") {
                redirect = (target, isAppend)
                clause = String(clause[..<range.lowerBound])
            }
        }

        var input = ""
        let failed = false
        for segment in splitTopLevel(clause, separator: "|") {
            let argv = tokenize(segment)
            guard let name = argv.first else { continue }
            do { input = try dispatch(name: name, arguments: Array(argv.dropFirst()), input: input) }
            catch { return ("\(error.localizedDescription)\n", true) }
        }

        if let redirect {
            do {
                let existing = redirect.append ? (try? String(contentsOf: try store.resolve(resolved(redirect.path)), encoding: .utf8)) ?? "" : ""
                try store.write(relativePath: resolved(redirect.path), data: Data((existing + input).utf8))
                return ("", false)
            } catch { return ("\(error.localizedDescription)\n", true) }
        }
        return (input.isEmpty ? "" : input + (input.hasSuffix("\n") ? "" : "\n"), failed)
    }

    private func dispatch(name: String, arguments: [String], input: String) throws -> String {
        let expanded = arguments.map(expand)
        switch name {
        case "help": return LocalShell.commands.joined(separator: " ") + "\nPipelines (|), redirection (>, >>), and && are supported. This shell runs inside the app: it cannot launch external binaries."
        case "clear": lines.removeAll(); return ""
        case "pwd": return "/" + directory
        case "cd": return try changeDirectory(expanded.first ?? "")
        case "ls": return try list(expanded)
        case "tree": return try tree(expanded.first)
        case "cat": return try expanded.map { try read($0) }.joined()
        case "head": return slice(expanded, input: input, fromEnd: false)
        case "tail": return slice(expanded, input: input, fromEnd: true)
        case "echo": return expanded.joined(separator: " ") + "\n"
        case "mkdir": try expanded.forEach { try FileManager.default.createDirectory(at: try store.resolve(resolved($0)), withIntermediateDirectories: true) }; return ""
        case "touch": try expanded.forEach { let url = try store.resolve(resolved($0)); if !FileManager.default.fileExists(atPath: url.path) { try store.write(relativePath: resolved($0), data: Data()) } }; return ""
        case "rm": return try remove(expanded)
        case "mv": return try move(expanded, copyOnly: false)
        case "cp": return try move(expanded, copyOnly: true)
        case "wc": return count(expanded, input: input)
        case "grep": return try grep(expanded, input: input)
        case "find": return try find(expanded)
        case "sed": return try sed(expanded, input: input)
        case "sort": return (input.isEmpty ? "" : input).split(separator: "\n", omittingEmptySubsequences: false).map(String.init).sorted().joined(separator: "\n")
        case "uniq": return unique(input)
        case "sha256": return try expanded.map { "\(LocalWorkspaceStore.digest(try Data(contentsOf: try store.resolve(resolved($0)))))  \($0)" }.joined(separator: "\n")
        case "sqlite":
            guard let file = expanded.first else { throw ShellError.message("sqlite: needs a database path") }
            let script = expanded.dropFirst().joined(separator: " ")
            guard !script.isEmpty else { throw ShellError.message("sqlite: needs a statement, e.g. sqlite app.db \"select * from notes\"") }
            return try LocalSQL(path: try store.resolve(resolved(file))).run(script) + "\n"
        case "env": return variables.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        case "export":
            for pair in expanded {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { variables[parts[0]] = parts[1] }
            }
            return ""
        default:
            throw ShellError.unknown(name)
        }
    }

    // MARK: - Commands

    private func changeDirectory(_ path: String) throws -> String {
        let target = path.isEmpty ? "" : resolved(path)
        let url = try store.resolve(target)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ShellError.message("cd: \(path): no such directory")
        }
        directory = target
        return ""
    }

    private func list(_ arguments: [String]) throws -> String {
        let long = arguments.contains("-l")
        let all = arguments.contains("-a")
        let path = arguments.first { !$0.hasPrefix("-") } ?? ""
        let url = try store.resolve(path.isEmpty ? directory : resolved(path))
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { all || !$0.hasPrefix(".") }
            .sorted()
        guard long else { return names.joined(separator: "\n") }
        return names.map { name in
            let child = url.appendingPathComponent(name)
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let size = values?.fileSize ?? 0
            return "\(values?.isDirectory == true ? "d" : "-") \(String(format: "%8d", size))  \(name)"
        }.joined(separator: "\n")
    }

    private func tree(_ path: String?) throws -> String {
        let base = resolved(path ?? "")
        return AgentTools.walk(store).filter { base.isEmpty || $0.hasPrefix(base) }.prefix(500).joined(separator: "\n")
    }

    private func read(_ path: String) throws -> String {
        let data = try Data(contentsOf: try store.resolve(resolved(path)))
        guard let text = String(data: data, encoding: .utf8) else { throw ShellError.message("cat: \(path): not UTF-8 text") }
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    private func slice(_ arguments: [String], input: String, fromEnd: Bool) -> String {
        var count = 10
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-n", index + 1 < arguments.count { count = Int(arguments[index + 1]) ?? 10; index += 2; continue }
            paths.append(arguments[index]); index += 1
        }
        let text = paths.isEmpty ? input : paths.compactMap { try? read($0) }.joined()
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let selected = fromEnd ? all.suffix(count) : all.prefix(count)
        return selected.joined(separator: "\n")
    }

    private func remove(_ arguments: [String]) throws -> String {
        let recursive = arguments.contains { $0 == "-r" || $0 == "-rf" || $0 == "-fr" }
        for path in arguments where !path.hasPrefix("-") {
            let url = try store.resolve(resolved(path))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw ShellError.message("rm: \(path): no such file") }
            if isDirectory.boolValue && !recursive { throw ShellError.message("rm: \(path): is a directory (use -r)") }
            try FileManager.default.removeItem(at: url)
        }
        return ""
    }

    private func move(_ arguments: [String], copyOnly: Bool) throws -> String {
        let paths = arguments.filter { !$0.hasPrefix("-") }
        guard paths.count == 2 else { throw ShellError.message("\(copyOnly ? "cp" : "mv"): needs a source and a destination") }
        let source = try store.resolve(resolved(paths[0]))
        let destination = try store.resolve(resolved(paths[1]))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        if copyOnly { try FileManager.default.copyItem(at: source, to: destination) }
        else { try FileManager.default.moveItem(at: source, to: destination) }
        return ""
    }

    private func count(_ arguments: [String], input: String) -> String {
        let text = arguments.isEmpty ? input : arguments.compactMap { try? read($0) }.joined()
        let lineCount = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return "\(lineCount) \(words) \(text.utf8.count)"
    }

    private func grep(_ arguments: [String], input: String) throws -> String {
        var options: NSRegularExpression.Options = []
        var rest = arguments
        if let index = rest.firstIndex(of: "-i") { options.insert(.caseInsensitive); rest.remove(at: index) }
        let invert = rest.firstIndex(of: "-v").map { rest.remove(at: $0); return true } ?? false
        guard let pattern = rest.first else { throw ShellError.message("grep: needs a pattern") }
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let paths = Array(rest.dropFirst())
        let sources: [(String, String)] = paths.isEmpty
            ? [("", input)]
            : try paths.map { ($0, try read($0)) }
        var hits: [String] = []
        for (path, text) in sources {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let value = String(line)
                let matched = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
                if matched != invert && !value.isEmpty {
                    hits.append(path.isEmpty ? value : "\(path):\(index + 1):\(value)")
                }
            }
        }
        return hits.joined(separator: "\n")
    }

    private func find(_ arguments: [String]) throws -> String {
        let base = resolved(arguments.first { !$0.hasPrefix("-") } ?? "")
        var namePattern: String?
        if let index = arguments.firstIndex(of: "-name"), index + 1 < arguments.count { namePattern = arguments[index + 1] }
        return AgentTools.walk(store)
            .filter { base.isEmpty || $0.hasPrefix(base) }
            .filter { path in
                guard let namePattern else { return true }
                return NSPredicate(format: "SELF LIKE %@", namePattern).evaluate(with: (path as NSString).lastPathComponent)
            }
            .prefix(500)
            .joined(separator: "\n")
    }

    /// `sed s/pattern/replacement/[g]` over stdin or a file. Enough to edit a
    /// line without opening the editor; anything richer belongs in the agent.
    private func sed(_ arguments: [String], input: String) throws -> String {
        guard let script = arguments.first(where: { $0.hasPrefix("s") }), script.count > 3 else { throw ShellError.message("sed: only s/pattern/replacement/ is supported") }
        let separator = script[script.index(script.startIndex, offsetBy: 1)]
        let parts = script.dropFirst(2).components(separatedBy: String(separator))
        guard parts.count >= 2 else { throw ShellError.message("sed: malformed substitution") }
        let global = parts.count > 2 && parts[2].contains("g")
        let regex = try NSRegularExpression(pattern: parts[0])
        let paths = arguments.filter { $0 != script && !$0.hasPrefix("-") }
        let inPlace = arguments.contains("-i")
        var output = ""
        for source in paths.isEmpty ? [""] : paths {
            let text = source.isEmpty ? input : try read(source)
            let range = NSRange(text.startIndex..., in: text)
            var replaced = regex.stringByReplacingMatches(in: text, range: range, withTemplate: parts[1])
            if !global, let match = regex.firstMatch(in: text, range: range) {
                replaced = (text as NSString).replacingCharacters(in: match.range, with: parts[1])
            }
            if inPlace, !source.isEmpty { try store.write(relativePath: resolved(source), data: Data(replaced.utf8)) }
            else { output += replaced }
        }
        return output
    }

    private func unique(_ input: String) -> String {
        var previous: String?
        return input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            defer { previous = line }
            return line != previous
        }.joined(separator: "\n")
    }

    // MARK: - Parsing

    private func expand(_ token: String) -> String {
        guard token.contains("$") else { return token }
        var value = token
        for (name, replacement) in variables { value = value.replacingOccurrences(of: "$" + name, with: replacement) }
        return value
    }

    /// Resolves a shell argument against the current directory, keeping the
    /// result workspace-relative; `store.resolve` still enforces the jail.
    private func resolved(_ path: String) -> String {
        if path.hasPrefix("/") { return String(path.dropFirst()) }
        var parts = directory.split(separator: "/").map(String.init)
        for component in path.split(separator: "/").map(String.init) {
            switch component {
            case ".", "": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return parts.joined(separator: "/")
    }

    private func splitTopLevel(_ value: String, separator: String) -> [String] {
        var results: [String] = []
        var current = ""
        var quote: Character?
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if let active = quote {
                if character == active { quote = nil }
                current.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if value[index...].hasPrefix(separator) {
                results.append(current)
                current = ""
                index = value.index(index, offsetBy: separator.count)
                continue
            } else {
                current.append(character)
            }
            index = value.index(after: index)
        }
        results.append(current)
        return results.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

enum ShellError: LocalizedError {
    case unknown(String), message(String)
    var errorDescription: String? {
        switch self {
        case .unknown(let name): return "\(name): command not found. This shell runs inside the app sandbox and cannot launch external binaries; type help for what it does support."
        case .message(let value): return value
        }
    }
}
