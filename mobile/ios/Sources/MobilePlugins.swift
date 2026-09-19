import Foundation
import JavaScriptCore

/// `runtime: js` plugins on the phone, mirroring the desktop's `JSPlugin`: a
/// sandboxed JavaScriptCore context with no filesystem, network, or timers —
/// only the `harness` bridge below. Plugins live in the workspace under
/// `.herness/plugins/<id>/`, so cloning a repo brings its plugins with it.
struct PluginManifest: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String = "0.0.0"
    var main: String = "plugin.js"
    var description: String = ""
}

@MainActor
final class MobilePlugins: ObservableObject {
    @Published private(set) var loaded: [PluginManifest] = []
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var log: [String] = []
    /// Prompt text plugins contribute, appended to the agent's system prompt.
    @Published private(set) var promptSections: [String] = []

    static let directory = ".herness/plugins"

    private let store: LocalWorkspaceStore
    private var contexts: [String: JSContext] = [:]
    /// JSValue is not Sendable, so tool closures carry only a string key and call
    /// back into this main-actor object to reach the function.
    private var functions: [String: (context: JSContext, function: JSValue)] = [:]

    init(store: LocalWorkspaceStore) { self.store = store }

    /// Reloads every plugin in the workspace and returns the tools they register.
    func reload() -> [AgentToolSpec] {
        loaded = []
        failures = [:]
        promptSections = []
        contexts = [:]
        functions = [:]
        var specs: [AgentToolSpec] = []

        guard let root = try? store.resolve(Self.directory),
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            do { specs += try load(directory: entry) }
            catch { failures[entry.lastPathComponent] = error.localizedDescription }
        }
        return specs
    }

    private func load(directory: URL) throws -> [AgentToolSpec] {
        let manifestURL = directory.appendingPathComponent("plugin.json")
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: try Data(contentsOf: manifestURL))
        let source = try String(contentsOf: directory.appendingPathComponent(manifest.main), encoding: .utf8)

        guard let context = JSContext() else { throw PluginError.message("could not create a JS context") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() ?? "unknown JS exception" }

        var registered: [(name: String, description: String, schema: [String: Any], function: JSValue)] = []
        let bridge = JSValue(newObjectIn: context)!

        let tool: @convention(block) (String, String, JSValue, JSValue) -> Void = { name, description, schema, function in
            MainActor.assumeIsolated {
                let value = schema.toDictionary() as? [String: Any] ?? ["type": "object"]
                registered.append((name, description, value, function))
            }
        }
        let prompt: @convention(block) (String) -> Void = { [weak self] text in
            MainActor.assumeIsolated { self?.promptSections.append(text) }
        }
        let logLine: @convention(block) (String) -> Void = { [weak self] text in
            MainActor.assumeIsolated { self?.append(log: "\(manifest.id): \(text)") }
        }
        bridge.setObject(tool, forKeyedSubscript: "tool" as NSString)
        bridge.setObject(prompt, forKeyedSubscript: "prompt" as NSString)
        bridge.setObject(logLine, forKeyedSubscript: "log" as NSString)
        bridge.setObject(manifest.id, forKeyedSubscript: "id" as NSString)
        context.setObject(bridge, forKeyedSubscript: "harness" as NSString)

        context.evaluateScript(source, withSourceURL: directory.appendingPathComponent(manifest.main))
        if let failure { throw PluginError.message("js: \(failure)") }
        if let apply = context.objectForKeyedSubscript("apply"), !apply.isUndefined {
            apply.call(withArguments: [bridge])
            if let failure { throw PluginError.message("js apply(): \(failure)") }
        }

        contexts[manifest.id] = context
        loaded.append(manifest)

        let slug = manifest.id.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        return registered.map { entry in
            let key = "plugin__\(slug)__\(entry.name)"
            functions[key] = (context, entry.function)
            return AgentToolSpec(
                name: key,
                description: entry.description.isEmpty ? "\(entry.name) from the \(manifest.name) plugin." : entry.description,
                schema: entry.schema
            ) { [weak self] input in
                guard let self else { throw PluginError.message("\(key) is no longer loaded") }
                return try await MainActor.run { try self.invoke(key: key, input: input) }
            }
        }
    }

    func invoke(key: String, input: AgentInput) throws -> String {
        guard let entry = functions[key] else { throw PluginError.message("\(key) is not registered") }
        let arguments = (try? JSONSerialization.jsonObject(with: input.data)) as? [String: Any] ?? [:]
        entry.context.exception = nil
        let result = entry.function.call(withArguments: [arguments])
        if let exception = entry.context.exception { throw PluginError.message("\(key): \(exception.toString() ?? "JS exception")") }
        guard let result, !result.isUndefined, !result.isNull else { return "" }
        return result.toString() ?? ""
    }

    private func append(log line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}

enum PluginError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}
