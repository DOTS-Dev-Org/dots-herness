// Copyright (c) 2026 DOTS
// `dotsplugin` CLI: keygen / pack / sign / verify for `.dotsplugin` packages.

import CryptoKit
import Foundation
import DotsHarnessCore

struct KeyFile: Codable {
    var id: String
    var privateKey: String
    var publicKey: String
}

let usage = """
dotsplugin keygen   <publisher-id> [-o key.json]
dotsplugin pack     <folder> [-o out.dotsplugin]
dotsplugin sign     <package.dotsplugin> --key key.json [-o package.dotsplugin.sig]
dotsplugin verify   <package.dotsplugin> --sig file.sig (--key key.json | --publishers publishers.json)
dotsplugin scaffold <plugin-id> --harness <path/to/HarnessPluginSDK> [-o dir]
dotsplugin build    <src-folder> [--sign <identity>] [--hardened] [-o out.dotsplugin]
"""

func scaffoldName(from id: String) -> String {
    let stem = id.split(separator: ".").last.map(String.init) ?? id
    let cleaned = stem.filter { $0.isLetter || $0.isNumber }
    let name = cleaned.isEmpty ? "Plugin" : cleaned
    return name.prefix(1).uppercased() + name.dropFirst()
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func flag(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { die(usage) }
let rest = Array(args.dropFirst())

do {
    switch command {
    case "keygen":
        guard let publisher = rest.first, !publisher.hasPrefix("-") else { die(usage) }
        let priv = Curve25519.Signing.PrivateKey()
        let key = KeyFile(
            id: publisher,
            privateKey: priv.rawRepresentation.base64EncodedString(),
            publicKey: priv.publicKey.rawRepresentation.base64EncodedString()
        )
        let output = URL(fileURLWithPath: flag("-o", in: rest) ?? "\(publisher).key.json")
        try JSONEncoder().encode(key).write(to: output, options: .atomic)
        print("wrote \(output.path)")
        print("publisher \(publisher) pinned key: \(key.publicKey)")

    case "pack":
        guard let folder = rest.first, !folder.hasPrefix("-") else { die(usage) }
        let source = URL(fileURLWithPath: folder)
        let output = URL(fileURLWithPath: flag("-o", in: rest) ?? source.lastPathComponent + ".dotsplugin")
        try PluginPackage.pack(folder: source, to: output)
        print("packed \(output.path)  sha256=\(try PluginPackage.sha256(of: output))")

    case "sign":
        guard let package = rest.first, !package.hasPrefix("-") else { die(usage) }
        guard let keyPath = flag("--key", in: rest) else { die(usage) }
        let keyFile = try JSONDecoder().decode(KeyFile.self, from: Data(contentsOf: URL(fileURLWithPath: keyPath)))
        guard let privData = Data(base64Encoded: keyFile.privateKey) else { die("bad private key") }
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privData)
        let signature = try PluginPackage.sign(
            package: URL(fileURLWithPath: package),
            publisher: keyFile.id,
            privateKey: priv
        )
        let output = URL(fileURLWithPath: flag("-o", in: rest) ?? package + ".sig")
        try JSONEncoder().encode(signature).write(to: output, options: .atomic)
        print("wrote \(output.path)")

    case "verify":
        guard let package = rest.first, !package.hasPrefix("-") else { die(usage) }
        guard let sigPath = flag("--sig", in: rest) else { die(usage) }
        let signature = try JSONDecoder().decode(
            PluginSignature.self,
            from: Data(contentsOf: URL(fileURLWithPath: sigPath))
        )
        var publishers: [String: String] = [:]
        if let keyPath = flag("--key", in: rest) {
            let keyFile = try JSONDecoder().decode(KeyFile.self, from: Data(contentsOf: URL(fileURLWithPath: keyPath)))
            publishers[keyFile.id] = keyFile.publicKey
        } else if let pubPath = flag("--publishers", in: rest) {
            publishers = try JSONDecoder().decode(
                [String: String].self,
                from: Data(contentsOf: URL(fileURLWithPath: pubPath))
            )
        } else {
            die(usage)
        }
        try PluginPackage.verify(
            package: URL(fileURLWithPath: package),
            signature: signature,
            publishers: publishers
        )
        print("OK  publisher=\(signature.publisher)  sha256=\(signature.sha256)")

    case "scaffold":
        guard let id = rest.first, !id.hasPrefix("-") else { die(usage) }
        guard let harness = flag("--harness", in: rest) else { die("scaffold needs --harness <path/to/HarnessPluginSDK>") }
        let name = scaffoldName(from: id)
        let dir = URL(fileURLWithPath: flag("-o", in: rest) ?? id)
        let sourceDir = dir.appendingPathComponent("Sources/\(name)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let harnessPath = URL(fileURLWithPath: harness).standardizedFileURL.path
        try """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            platforms: [.macOS(.v14)],
            products: [.library(name: "\(name)", type: .dynamic, targets: ["\(name)"])],
            dependencies: [.package(path: "\(harnessPath)")],
            targets: [.target(name: "\(name)", dependencies: [
                .product(name: "HarnessPluginKit", package: "HarnessPluginSDK")
            ])]
        )
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        id: \(id)
        name: \(name)
        version: 0.1.0
        plane: session
        inject:
          - prompt
        library: lib\(name).dylib
        """.write(to: dir.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        import HarnessPluginKit

        public final class \(name): HarnessPlugin {
            public static let manifest = PluginManifest(
                id: "\(id)", name: "\(name)", version: "0.1.0",
                plane: .session, inject: ["prompt"], library: "lib\(name).dylib"
            )

            public init() {}

            public func apply(_ ctx: PluginContext) throws {
                ctx.prompt.section(name: "\(id):note", order: 40, text: "\(name) is mounted.")
            }
        }

        // C ABI — do not edit.
        @_cdecl("harness_plugin_abi_version")
        public func harness_plugin_abi_version() -> UnsafePointer<CChar> { CString.abi }
        @_cdecl("harness_plugin_id")
        public func harness_plugin_id() -> UnsafePointer<CChar> { CString.id }
        @_cdecl("harness_plugin_make")
        public func harness_plugin_make() -> UnsafeMutableRawPointer { Unmanaged.passRetained(\(name)()).toOpaque() }

        private enum CString {
            nonisolated(unsafe) static let abi = UnsafePointer(strdup("1.0.0")!)
            nonisolated(unsafe) static let id = UnsafePointer(strdup("\(id)")!)
        }
        """.write(to: sourceDir.appendingPathComponent("\(name).swift"), atomically: true, encoding: .utf8)
        print("scaffolded \(dir.path)")
        print("next:  dotsplugin build \(dir.path) --sign <identity>")

    case "build":
        guard let src = rest.first, !src.hasPrefix("-") else { die(usage) }
        let source = URL(fileURLWithPath: src)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("dotsplugin-build-\(UUID().uuidString)", isDirectory: true)
        let output = try PluginBuilder.build(
            source: source,
            into: staging,
            signIdentity: flag("--sign", in: rest),
            hardenedRuntime: rest.contains("--hardened")
        )
        let out = URL(fileURLWithPath: flag("-o", in: rest) ?? output.manifest.id + ".dotsplugin")
        try PluginPackage.pack(folder: output.pluginFolder, to: out)
        try? FileManager.default.removeItem(at: staging)
        print("built \(out.path)  sha256=\(try PluginPackage.sha256(of: out))")

    default:
        die(usage)
    }
} catch {
    die("error: \(error.localizedDescription)")
}
