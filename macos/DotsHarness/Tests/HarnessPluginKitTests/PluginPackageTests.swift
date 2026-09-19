// Copyright (c) 2026 DOTS
// `.dotsplugin` pack / sign / verify / install round trip.

import CryptoKit
import XCTest
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

final class PluginPackageTests: XCTestCase {
    func testPackSignVerifyUnpackRoundTrip() throws {
        let work = try makeWorkDir()
        let folder = work.appendingPathComponent("srcplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        id: com.example.packed
        name: Packed
        version: 0.2.0
        plane: session
        runtime: native
        library: plugin.native
        """.write(to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)
        try "{\"version\":1,\"prompt\":[],\"tools\":[],\"events\":[],\"settings\":[],\"panels\":[]}".write(
            to: folder.appendingPathComponent("plugin.ir.json"), atomically: true, encoding: .utf8
        )
        try Data("native placeholder".utf8).write(to: folder.appendingPathComponent("plugin.native"))

        let package = work.appendingPathComponent("packed.dotsplugin")
        try PluginPackage.pack(folder: folder, to: package)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))

        let priv = Curve25519.Signing.PrivateKey()
        let signature = try PluginPackage.sign(package: package, publisher: "dots", privateKey: priv)
        let publishers = ["dots": priv.publicKey.rawRepresentation.base64EncodedString()]

        XCTAssertNoThrow(try PluginPackage.verify(package: package, signature: signature, publishers: publishers))
        XCTAssertThrowsError(try PluginPackage.verify(package: package, signature: signature, publishers: ["dots": "AAAA"]))

        // Tamper: append a byte, hash no longer matches.
        let handle = try FileHandle(forWritingTo: package)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()
        XCTAssertThrowsError(try PluginPackage.verify(package: package, signature: signature, publishers: publishers))

        // Re-pack clean and unpack into a plugins dir.
        try PluginPackage.pack(folder: folder, to: package)
        let pluginsDir = work.appendingPathComponent("plugins", isDirectory: true)
        let manifest = try PluginPackage.unpack(package: package, into: pluginsDir)
        XCTAssertEqual(manifest.id, "com.example.packed")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent("com.example.packed/plugin.yml").path
        ))
    }

    @MainActor
    func testInstallerAddsToCatalogAndRemoves() throws {
        let work = try makeWorkDir()
        let folder = work.appendingPathComponent("srcplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        id: com.example.installed
        name: Installed
        version: 0.1.0
        plane: session
        runtime: native
        library: plugin.native
        """.write(to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)
        try "{\"version\":1,\"prompt\":[],\"tools\":[],\"events\":[],\"settings\":[],\"panels\":[]}".write(
            to: folder.appendingPathComponent("plugin.ir.json"), atomically: true, encoding: .utf8
        )
        try Data("native placeholder".utf8).write(to: folder.appendingPathComponent("plugin.native"))
        let package = work.appendingPathComponent("installed.dotsplugin")
        try PluginPackage.pack(folder: folder, to: package)

        let paths = supportPaths(root: work.appendingPathComponent("support", isDirectory: true))
        let catalog = PluginCatalog(paths: paths)
        let installer = PluginInstaller(catalog: catalog)

        let manifest = try installer.install(package: package, signature: nil)
        XCTAssertEqual(manifest.id, "com.example.installed")
        XCTAssertTrue(catalog.entries.contains { $0.manifest.id == "com.example.installed" })

        try installer.remove(id: "com.example.installed")
        XCTAssertFalse(catalog.entries.contains { $0.manifest.id == "com.example.installed" })
    }

    private func makeWorkDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsPkgTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func supportPaths(root: URL) -> SupportPaths {
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
        paths.ensure()
        return paths
    }
}
