// Copyright (c) 2026 DOTS
// Native plugin ABI for Dots Harness.

import Foundation

/// C ABI for compiled user dylibs. Keep this table tiny and append-only.
///
/// Required exports:
/// - `harness_plugin_abi_version() -> UnsafePointer<CChar>`
/// - `harness_plugin_id() -> UnsafePointer<CChar>`
/// - `harness_plugin_make() -> UnsafeMutableRawPointer`
///
/// `harness_plugin_make` returns an unretained `HarnessPlugin` instance
/// allocated with `Unmanaged.passRetained`. The loader releases it on unmount.
public enum PluginABI {
    public static let version = PluginManifest.currentABI
    public static let abiSymbol = "harness_plugin_abi_version"
    public static let idSymbol = "harness_plugin_id"
    public static let makeSymbol = "harness_plugin_make"
}

#if os(macOS)
import Darwin

public enum PluginDylib {
    public static func load(from url: URL) throws -> HarnessPlugin {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw PluginError.applyFailed(String(cString: dlerror()))
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else {
                dlclose(handle)
                throw PluginError.applyFailed("missing symbol \(name)")
            }
            return unsafeBitCast(raw, to: T.self)
        }
        typealias CStringFn = @convention(c) () -> UnsafePointer<CChar>?
        typealias MakeFn = @convention(c) () -> UnsafeMutableRawPointer?
        let abiFn: CStringFn = try symbol(PluginABI.abiSymbol, as: CStringFn.self)
        let idFn: CStringFn = try symbol(PluginABI.idSymbol, as: CStringFn.self)
        let makeFn: MakeFn = try symbol(PluginABI.makeSymbol, as: MakeFn.self)
        guard let abiPtr = abiFn(), let idPtr = idFn() else {
            dlclose(handle)
            throw PluginError.applyFailed("null ABI export")
        }
        let abi = String(cString: abiPtr)
        _ = String(cString: idPtr)
        guard SemVer(abi)?.major == SemVer(PluginABI.version)?.major else {
            dlclose(handle)
            throw PluginError.incompatibleABI(abi)
        }
        guard let raw = makeFn() else {
            dlclose(handle)
            throw PluginError.applyFailed("plugin factory returned nil")
        }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue() as! HarnessPlugin
    }
}
#endif
