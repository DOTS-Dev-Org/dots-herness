// Copyright (c) 2026 DOTS
// `runtime: js` plugins: a sandboxed JavaScriptCore context bridged to the
// same registries the native and declarative plugins use.
//
// The context gets NO filesystem, network, or timer APIs — only the `harness`
// bridge object below. That keeps an untrusted `.js` plugin as safe as a
// declarative one: prompt sections, sync tools, events, settings, and
// declarative panels.
//
// Every bridge callback is invoked synchronously by JavaScriptCore from inside
// `apply(_:)`, which the plugin contract runs on the main actor — hence the
// `MainActor.assumeIsolated` hops.

import Foundation
import JavaScriptCore
import HarnessPluginKit

public final class JSPlugin: HarnessPlugin {
    public static var manifest: PluginManifest {
        PluginManifest(id: "dots.js-placeholder", name: "JS", version: "0.0.0", plane: .session)
    }

    public let resolved: PluginManifest
    public let directory: URL?
    private var context: JSContext?

    public init(manifest: PluginManifest, directory: URL?) {
        self.resolved = manifest
        self.directory = directory
    }

    public func apply(_ ctx: PluginContext) throws {
        guard let directory else {
            throw PluginError.applyFailed("js plugin \(resolved.id) has no directory")
        }
        let entry = resolved.main ?? "plugin.js"
        let source = try String(contentsOf: directory.appendingPathComponent(entry), encoding: .utf8)

        guard let js = JSContext() else {
            throw PluginError.applyFailed("could not create JS context")
        }
        context = js
        var failure: String?
        js.exceptionHandler = { _, exception in
            failure = exception?.toString() ?? "unknown JS exception"
        }
        ctx.effect { [weak self] in self?.context = nil }

        let bridge = makeBridge(js: js, ctx: ctx)
        js.setObject(bridge, forKeyedSubscript: "harness" as NSString)

        js.evaluateScript(source, withSourceURL: directory.appendingPathComponent(entry))
        if let failure { throw PluginError.applyFailed("js: \(failure)") }

        guard let applyFn = js.objectForKeyedSubscript("apply"), !applyFn.isUndefined else {
            throw PluginError.applyFailed("\(entry) defines no global apply(harness)")
        }
        applyFn.call(withArguments: [bridge])
        if let failure { throw PluginError.applyFailed("js apply(): \(failure)") }
    }

    // MARK: Bridge

    @MainActor
    private func makeBridge(js: JSContext, ctx: PluginContext) -> JSValue {
        let bridge = JSValue(newObjectIn: js) ?? JSValue(nullIn: js)!

        let prompt: @convention(block) (String, Double, String) -> Void = { name, order, text in
            MainActor.assumeIsolated { ctx.prompt.section(name: name, order: Int(order), text: text) }
        }
        bridge.setObject(prompt, forKeyedSubscript: "prompt" as NSString)

        let tool: @convention(block) (String, String, JSValue) -> Void = { name, description, callback in
            MainActor.assumeIsolated {
                ctx.tools.register(name: name, description: description, parameters: []) { args in
                    // ponytail: JS tool callbacks are synchronous (return a string).
                    // Untrusted JS has no async I/O anyway; wire Promises if a
                    // trusted tier ever needs them.
                    let jsArgs = JSValue(object: args, in: js)
                    let result = callback.call(withArguments: [jsArgs as Any])
                    return result?.toString() ?? ""
                }
            }
        }
        bridge.setObject(tool, forKeyedSubscript: "tool" as NSString)

        let on: @convention(block) (String, JSValue) -> Void = { event, handler in
            MainActor.assumeIsolated {
                ctx.on(event) { payload in
                    _ = handler.call(withArguments: [JSValue(object: payload ?? NSNull(), in: js) as Any])
                }
            }
        }
        bridge.setObject(on, forKeyedSubscript: "on" as NSString)

        let emit: @convention(block) (String, JSValue) -> Void = { event, payload in
            MainActor.assumeIsolated {
                ctx.events.emit(event, payload.isUndefined || payload.isNull ? nil : payload.toObject())
            }
        }
        bridge.setObject(emit, forKeyedSubscript: "emit" as NSString)

        let get: @convention(block) (String) -> Any? = { key in
            var out: Any?
            MainActor.assumeIsolated {
                switch ctx.settings.get(key) {
                case .string(let value): out = value
                case .number(let value): out = value
                case .bool(let value): out = value
                default: out = nil
                }
            }
            return out
        }
        bridge.setObject(get, forKeyedSubscript: "get" as NSString)

        let set: @convention(block) (String, JSValue) -> Void = { key, value in
            MainActor.assumeIsolated {
                if value.isBoolean {
                    ctx.settings.set(key, .bool(value.toBool()))
                } else if value.isNumber {
                    ctx.settings.set(key, .number(value.toDouble()))
                } else {
                    ctx.settings.set(key, .string(value.toString() ?? ""))
                }
            }
        }
        bridge.setObject(set, forKeyedSubscript: "set" as NSString)

        let panel: @convention(block) (String, String, Double, String, JSValue) -> Void = { slot, id, order, label, body in
            MainActor.assumeIsolated {
                guard let object = body.toObject(),
                      let data = try? JSONSerialization.data(withJSONObject: object),
                      let node = try? JSONDecoder().decode(PanelNode.self, from: data)
                else { return }
                ctx.slots.inject(slot, id: id, order: Int(order), label: label) {
                    PanelView(node: node, ctx: ctx)
                }
            }
        }
        bridge.setObject(panel, forKeyedSubscript: "panel" as NSString)

        return bridge
    }
}
