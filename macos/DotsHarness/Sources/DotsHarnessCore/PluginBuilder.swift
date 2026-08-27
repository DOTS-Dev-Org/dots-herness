// Copyright (c) 2026 DOTS
// Compiles a third-party Swift plugin package to a signed `.dylib` and lays it
// out as a plugin folder ready for `PluginPackage.pack`.

import Foundation
import HarnessPluginKit
import PluginRuntime

public enum PluginBuilder {
    public struct Output: Sendable {
        public var pluginFolder: URL
        public var dylib: URL
        public var manifest: PluginManifest
    }

    /// `source` must contain `plugin.yml` (with `library:` set) and a SwiftPM
    /// package whose dynamic-library product builds that dylib.
    public static func build(
        source: URL,
        into destination: URL,
        signIdentity: String?,
        hardenedRuntime: Bool = false
    ) throws -> Output {
        let manifest = try PluginPackage.manifest(atFolder: source)
        guard let library = manifest.library, !library.isEmpty else {
            throw PluginError.package("plugin.yml needs `library: <name>.dylib` for a compiled plugin")
        }

        try run("/usr/bin/swift", ["build", "--package-path", source.path, "-c", "release"])
        let binPath = try capture("/usr/bin/swift", ["build", "--package-path", source.path, "-c", "release", "--show-bin-path"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let binURL = URL(fileURLWithPath: binPath)

        let dylib = try locateDylib(in: binURL, preferred: library)
        try codesign(dylib, identity: signIdentity ?? "-", hardened: hardenedRuntime)

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let manifestOut = destination.appendingPathComponent("plugin.yml")
        let dylibOut = destination.appendingPathComponent(library)
        try? FileManager.default.removeItem(at: manifestOut)
        try? FileManager.default.removeItem(at: dylibOut)
        try FileManager.default.copyItem(at: source.appendingPathComponent("plugin.yml"), to: manifestOut)
        try FileManager.default.copyItem(at: dylib, to: dylibOut)

        return Output(pluginFolder: destination, dylib: dylibOut, manifest: manifest)
    }

    static func locateDylib(in binURL: URL, preferred: String) throws -> URL {
        let fm = FileManager.default
        let exact = binURL.appendingPathComponent(preferred)
        if fm.fileExists(atPath: exact.path) { return exact }
        // SwiftPM names a dynamic product `Foo` as `libFoo.dylib`.
        let stem = (preferred as NSString).deletingPathExtension
        let libName = stem.hasPrefix("lib") ? "\(stem).dylib" : "lib\(stem).dylib"
        let guessed = binURL.appendingPathComponent(libName)
        if fm.fileExists(atPath: guessed.path) { return guessed }
        let dylibs = ((try? fm.contentsOfDirectory(at: binURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "dylib" }
        if dylibs.count == 1 { return dylibs[0] }
        throw PluginError.package("could not find the built dylib in \(binURL.path)")
    }

    private static func codesign(_ url: URL, identity: String, hardened: Bool) throws {
        var args = ["--force", "--sign", identity]
        if hardened { args += ["--options", "runtime", "--timestamp"] }
        else { args += ["--timestamp=none"] }
        args.append(url.path)
        try run("/usr/bin/codesign", args)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PluginError.package("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus)): \(output)")
        }
        return process.terminationStatus
    }

    private static func capture(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PluginError.package("\((tool as NSString).lastPathComponent) \(args.joined(separator: " ")) failed")
        }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
