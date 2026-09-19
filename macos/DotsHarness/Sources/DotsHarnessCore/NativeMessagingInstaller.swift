// Copyright (c) 2026 DOTS
// Per-user Chrome Native Messaging manifest installation for macOS.

import Foundation

public enum NativeMessagingInstallerError: LocalizedError, Equatable {
    case invalidExtensionID
    case invalidHostName
    case executableMissing
    case pathUnavailable
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidExtensionID: return "Chrome extension ID must be 32 lowercase a-p characters."
        case .invalidHostName: return "Invalid Native Messaging host name."
        case .executableMissing: return "The Native Messaging executable must be an existing absolute file."
        case .pathUnavailable: return "The Chrome Native Messaging manifest directory is unavailable."
        case .verificationFailed: return "The Native Messaging manifest could not be verified after installation."
        }
    }
}

public struct NativeMessagingInstallResult: Equatable, Sendable {
    public let installed: Bool
    public let manifestURL: URL
    public let diagnosticCode: String
}

public enum NativeMessagingManifestInstaller {
    public static let defaultHostName = "com.dots.herness.browser"

    public static func install(
        extensionID: String,
        executableURL: URL,
        hostName: String = defaultHostName
    ) throws -> NativeMessagingInstallResult {
        guard extensionID.range(of: "^[a-p]{32}$", options: .regularExpression) != nil else {
            throw NativeMessagingInstallerError.invalidExtensionID
        }
        guard hostName.range(of: "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil else {
            throw NativeMessagingInstallerError.invalidHostName
        }
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw NativeMessagingInstallerError.executableMissing
        }

        let manifestURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent(hostName + ".json")
        let originalData = try? Data(contentsOf: manifestURL)
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let object: [String: Any] = [
            "name": hostName,
            "description": "HerNess Browser Native Messaging host",
            "path": executableURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temporary = manifestURL.appendingPathExtension(UUID().uuidString + ".tmp")
        try data.write(to: temporary, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: manifestURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        do {
            guard let installedData = try? Data(contentsOf: manifestURL),
                  let installed = try? JSONSerialization.jsonObject(with: installedData) as? [String: Any],
                  installed["name"] as? String == hostName,
                  installed["type"] as? String == "stdio",
                  installed["path"] as? String == executableURL.path,
                  (installed["allowed_origins"] as? [String]) == ["chrome-extension://\(extensionID)/"] else {
                throw NativeMessagingInstallerError.verificationFailed
            }
        } catch {
            if let originalData {
                try? originalData.write(to: manifestURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: manifestURL)
            }
            throw error
        }
        return NativeMessagingInstallResult(installed: true, manifestURL: manifestURL, diagnosticCode: "installed")
    }
}
