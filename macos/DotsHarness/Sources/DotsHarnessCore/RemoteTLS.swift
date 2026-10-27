// Copyright (c) 2026 DOTS
// The remote-control gateway only speaks TLS. Its certificate is self-signed and
// long-lived; a phone trusts it by the SHA-256 fingerprint carried in the pairing
// QR code, never by a CA, so a LAN attacker cannot stand in for the desktop.

import CryptoKit
import Foundation
import Security

enum RemoteTLS {
    struct Material { let identity: SecIdentity; let fingerprint: String }

    /// Loads the saved identity, or mints one with the system LibreSSL (Security
    /// has no certificate builder). The PKCS#12 sits in the support directory
    /// with 0600 permissions; its password lives in the Keychain.
    static func loadOrCreate(root: URL) throws -> Material {
        let file = root.appendingPathComponent("remote-control-tls.p12")
        let keychain = RemoteKeychain()
        if let password = keychain.read(account: "remote.tls.password"), let data = try? Data(contentsOf: file),
           let material = try? load(data, password: password) {
            return material
        }
        let password = Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("herness-tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let key = scratch.appendingPathComponent("key.pem").path, cert = scratch.appendingPathComponent("cert.pem").path, p12 = scratch.appendingPathComponent("tls.p12").path
        // RSA, not EC: SecPKCS12Import cannot read LibreSSL's EC key bags.
        try openssl(["req", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256", "-days", "3650",
                     "-subj", "/CN=HerNess Remote Control", "-keyout", key, "-out", cert])
        try openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12, "-passout", "env:HERNESS_TLS_PASSWORD"], password: password)
        let data = try Data(contentsOf: URL(fileURLWithPath: p12))
        let material = try load(data, password: password)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: file)
        try keychain.write(password, account: "remote.tls.password")
        return material
    }

    static func fingerprint(_ certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    private static func load(_ data: Data, password: String) throws -> Material {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String] else { throw RouterTestError.message("Remote-control certificate could not be loaded (\(status)).") }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw RouterTestError.message("Remote-control certificate is missing.") }
        return Material(identity: identity, fingerprint: fingerprint(certificate))
    }

    private static func openssl(_ arguments: [String], password: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        // The password goes through the environment, never argv (visible in ps).
        if let password { process.environment = ["HERNESS_TLS_PASSWORD": password] }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RouterTestError.message("openssl \(arguments.first ?? "") failed with status \(process.terminationStatus).") }
    }
}
