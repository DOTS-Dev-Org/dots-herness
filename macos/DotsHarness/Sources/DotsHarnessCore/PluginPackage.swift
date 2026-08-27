// Copyright (c) 2026 DOTS
// `.dotsplugin` packaging: zip via `ditto`, SHA-256 + Ed25519 detached signature.

import CryptoKit
import Foundation
import HarnessPluginKit
import PluginRuntime

/// Detached signature that travels next to a `.dotsplugin` file (and inside
/// the marketplace registry entry). Signs the hex SHA-256 of the archive.
public struct PluginSignature: Codable, Sendable, Equatable {
    public var alg: String
    public var sha256: String
    public var sig: String
    public var publisher: String
    public var publicKey: String

    public init(alg: String = "ed25519", sha256: String, sig: String, publisher: String, publicKey: String) {
        self.alg = alg
        self.sha256 = sha256
        self.sig = sig
        self.publisher = publisher
        self.publicKey = publicKey
    }
}

public enum PluginPackage {
    // MARK: Build

    /// Zips the *contents* of `folder` (so `plugin.yml` sits at archive root).
    public static func pack(folder: URL, to output: URL) throws {
        let manifestURL = folder.appendingPathComponent("plugin.yml")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PluginError.package("no plugin.yml in \(folder.lastPathComponent)")
        }
        _ = try manifest(atFolder: folder) // validate it parses before packing
        try? FileManager.default.removeItem(at: output)
        try ditto(["-c", "-k", "--sequesterRsrc", folder.path, output.path])
    }

    public static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Sign / verify

    public static func sign(
        package: URL,
        publisher: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> PluginSignature {
        let digest = try sha256(of: package)
        let signature = try privateKey.signature(for: Data(digest.utf8))
        return PluginSignature(
            sha256: digest,
            sig: signature.base64EncodedString(),
            publisher: publisher,
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    /// Throws unless the archive hash matches, the signature is valid, and the
    /// embedded public key is pinned for `signature.publisher`.
    public static func verify(
        package: URL,
        signature: PluginSignature,
        publishers: [String: String]
    ) throws {
        guard signature.alg == "ed25519" else {
            throw PluginError.package("unsupported signature alg \(signature.alg)")
        }
        guard let pinned = publishers[signature.publisher] else {
            throw PluginError.package("unknown publisher \(signature.publisher)")
        }
        guard pinned == signature.publicKey else {
            throw PluginError.package("publisher key mismatch for \(signature.publisher)")
        }
        let digest = try sha256(of: package)
        guard digest == signature.sha256.lowercased() else {
            throw PluginError.package("archive hash mismatch")
        }
        guard
            let keyData = Data(base64Encoded: signature.publicKey),
            let sigData = Data(base64Encoded: signature.sig),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
            key.isValidSignature(sigData, for: Data(digest.utf8))
        else {
            throw PluginError.package("invalid signature")
        }
    }

    // MARK: Install

    /// Extracts `package` into `pluginsDir/<manifest.id>/`, replacing any prior
    /// copy. Returns the parsed manifest. Rejects archives that would escape
    /// `pluginsDir`.
    @discardableResult
    public static func unpack(package: URL, into pluginsDir: URL) throws -> PluginManifest {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("dotsplugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try ditto(["-x", "-k", package.path, staging.path])

        let root = try folderContainingManifest(under: staging)
        let manifest = try self.manifest(atFolder: root)
        let safeID = manifest.id
        guard !safeID.isEmpty, !safeID.contains("/"), !safeID.contains(".."), safeID != "." else {
            throw PluginError.package("unsafe plugin id \(safeID)")
        }

        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let destination = pluginsDir.appendingPathComponent(safeID, isDirectory: true)
        guard destination.standardizedFileURL.path.hasPrefix(pluginsDir.standardizedFileURL.path) else {
            throw PluginError.package("archive escapes plugins directory")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: root, to: destination)
        return manifest
    }

    // MARK: Helpers

    static func manifest(atFolder folder: URL) throws -> PluginManifest {
        let text = try String(contentsOf: folder.appendingPathComponent("plugin.yml"), encoding: .utf8)
        return try MiniYAML.decode(PluginManifest.self, from: text)
    }

    private static func folderContainingManifest(under root: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("plugin.yml").path) { return root }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for child in children where child.hasDirectoryPath {
            if fm.fileExists(atPath: child.appendingPathComponent("plugin.yml").path) { return child }
        }
        throw PluginError.package("archive has no plugin.yml")
    }

    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PluginError.package("ditto failed: \(output)")
        }
    }
}
