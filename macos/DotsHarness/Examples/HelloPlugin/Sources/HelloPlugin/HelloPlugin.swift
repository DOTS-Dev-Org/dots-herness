// Copyright (c) 2026 DOTS
// Example third-party Swift plugin. Users copy this pattern.
// Example native Dots Harness plugin.

import Foundation
import SwiftUI
import HarnessPluginKit

public final class HelloPlugin: DefaultPlugin {
    public static let manifest = PluginManifest(
        id: "com.example.hello",
        name: "Hello",
        version: "0.1.0",
        plane: .session,
        inject: ["prompt", "slots"],
        description: "Example user plugin: a prompt section and a composer chip."
    )

    public init() {}

    public func apply(_ ctx: PluginContext) throws {
        ctx.prompt.section(
            name: "hello:note",
            order: 40,
            text: "The Hello example plugin is mounted. Greet the user by name if they offer one."
        )
        ctx.slots.inject(
            WellKnownSlot.composerAccessory,
            id: "hello-chip",
            order: 10,
            label: "Hello"
        ) {
            Text("Hello plugin")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
    }
}

// MARK: - C ABI for a compiled user dylib

@_cdecl("harness_plugin_abi_version")
public func harness_plugin_abi_version() -> UnsafePointer<CChar> {
    StaticCString.abi
}

@_cdecl("harness_plugin_id")
public func harness_plugin_id() -> UnsafePointer<CChar> {
    StaticCString.id
}

private enum StaticCString {
    nonisolated(unsafe) static let abi: UnsafePointer<CChar> = UnsafePointer(strdup("1.0.0")!)
    nonisolated(unsafe) static let id: UnsafePointer<CChar> = UnsafePointer(strdup("com.example.hello")!)
}

@_cdecl("harness_plugin_make")
public func harness_plugin_make() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(HelloPlugin()).toOpaque()
}
