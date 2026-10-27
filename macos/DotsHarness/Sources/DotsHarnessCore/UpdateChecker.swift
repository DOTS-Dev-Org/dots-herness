// Copyright (c) 2026 DOTS
// Multiplatform version checking, release discovery and update management.

import AppKit
import Combine
import Foundation
import Security

public struct UpdateInfo: Codable, Sendable, Equatable {
    public let platform: String
    public let currentVersion: String
    public let latestVersion: String
    public let buildNumber: Int
    public let minSupportedVersion: String
    public let updateAvailable: Bool
    public let mandatory: Bool
    public let releaseNotes: String
    public let downloadURL: String
    public let publishedAt: String

    enum CodingKeys: String, CodingKey {
        case platform
        case currentVersion = "current_version"
        case latestVersion = "latest_version"
        case buildNumber = "build_number"
        case minSupportedVersion = "min_supported_version"
        case updateAvailable = "update_available"
        case mandatory
        case releaseNotes = "release_notes"
        case downloadURL = "download_url"
        case publishedAt = "published_at"
    }

    public init(
        platform: String = "macos",
        currentVersion: String,
        latestVersion: String,
        buildNumber: Int = 1,
        minSupportedVersion: String = "0.1.0",
        updateAvailable: Bool,
        mandatory: Bool = false,
        releaseNotes: String = "",
        downloadURL: String = "",
        publishedAt: String = ""
    ) {
        self.platform = platform
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.buildNumber = buildNumber
        self.minSupportedVersion = minSupportedVersion
        self.updateAvailable = updateAvailable
        self.mandatory = mandatory
        self.releaseNotes = releaseNotes
        self.downloadURL = downloadURL
        self.publishedAt = publishedAt
    }
}

public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case updateAvailable(UpdateInfo)
    case upToDate(checkedAt: Date)
    case mandatoryUpdate(UpdateInfo)
    case installing(UpdateInfo)
    case failed(message: String)

    public var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }

    public var hasUpdate: Bool {
        switch self {
        case .updateAvailable, .mandatoryUpdate: return true
        default: return false
        }
    }
}

@MainActor
public final class UpdateChecker: ObservableObject {
    // dots.net.tr is served by the cPanel host, which answers /harness/* with 403;
    // the Worker that owns the route lives on workers.dev like the other APIs.
    public static let defaultEndpoint = URL(string: "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/harness/check-update")!

    @Published public private(set) var state: UpdateState = .idle
    @Published public private(set) var lastCheckedAt: Date?
    /// Set once the new bundle is staged, so quitting skips the exit prompt.
    public private(set) var isRelaunching = false
    public let currentVersion: String
    public let currentBuild: String

    private let endpoint: URL
    private let session: URLSession
    private static let minAutoCheckInterval: TimeInterval = 24 * 3600

    public init(
        endpoint: URL = UpdateChecker.defaultEndpoint,
        session: URLSession = .shared,
        bundle: Bundle = .main
    ) {
        self.endpoint = endpoint
        self.session = session
        let info = bundle.infoDictionary
        self.currentVersion = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.1.0"
        self.currentBuild = (info?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
    }

    /// Checks the remote backend for newer application releases.
    /// - Parameter manual: If `false`, throttles checks to once every 24 hours.
    public func checkForUpdates(manual: Bool = false) async {
        if !manual, let last = lastCheckedAt, Date().timeIntervalSince(last) < Self.minAutoCheckInterval {
            return
        }

        state = .checking

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "platform", value: "macos"))
        queryItems.append(URLQueryItem(name: "version", value: currentVersion))
        queryItems.append(URLQueryItem(name: "build", value: currentBuild))
        components?.queryItems = queryItems

        guard let targetURL = components?.url else {
            state = .failed(message: AppCopy.text("updates.error.url"))
            return
        }

        var request = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed(message: AppCopy.text("updates.error.response"))
                return
            }

            guard (200...299).contains(http.statusCode) else {
                state = .failed(message: AppCopy.format("updates.error.status", http.statusCode))
                return
            }

            let decoder = JSONDecoder()
            let info = try decoder.decode(UpdateInfo.self, from: data)
            let now = Date()
            lastCheckedAt = now

            if info.mandatory && info.updateAvailable {
                state = .mandatoryUpdate(info)
            } else if info.updateAvailable {
                state = .updateAvailable(info)
            } else {
                state = .upToDate(checkedAt: now)
            }
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Opens the downloaded DMG or latest release page in default browser.
    public func openDownloadPage(customURL: URL? = nil) {
        let targetURL: URL?
        if let custom = customURL {
            targetURL = custom
        } else {
            switch state {
            case .updateAvailable(let info), .mandatoryUpdate(let info):
                targetURL = URL(string: info.downloadURL)
            default:
                targetURL = URL(string: "https://github.com/DOTS-Dev-Org/dots-herness/releases/latest")
            }
        }

        // The download address comes from the update server. Opening it
        // unchecked would let a hijacked endpoint run anything in the user's
        // name (`file://`, `x-apple-...`), so only the release hosts we publish
        // on are allowed.
        guard let url = targetURL, Self.isAllowedDownloadURL(url) else {
            state = .failed(message: AppCopy.text("updates.error.url"))
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Downloads the release DMG, swaps it in for the running bundle once the
    /// app quits, and relaunches. Falls back to the download page when the
    /// app is not a writable `.app` bundle (e.g. `swift run`).
    public func installUpdate() async {
        let info: UpdateInfo
        switch state {
        case .updateAvailable(let i), .mandatoryUpdate(let i): info = i
        default: return
        }
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app", Self.runningAppTeamID() != nil,
              FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path),
              let dmgURL = URL(string: info.downloadURL), Self.isAllowedDownloadURL(dmgURL),
              dmgURL.pathExtension.lowercased() == "dmg" else {
            openDownloadPage()
            return
        }

        state = .installing(info)
        do {
            let (tmp, response) = try await session.download(from: dmgURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw UpdateInstallError.download
            }
            let mount = FileManager.default.temporaryDirectory.appendingPathComponent("DotsHarnessUpdate-\(UUID().uuidString)")
            try await Self.run("/usr/bin/hdiutil", ["attach", tmp.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }),
                  Self.signatureMatchesRunningApp(newApp) else {
                try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
                throw UpdateInstallError.signature
            }

            // Waits for this process to exit, swaps the bundle (restoring the old
            // one if the copy fails), unmounts and relaunches. Paths go in as
            // positional arguments so nothing is interpolated into the script.
            let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$3.old"
            if mv "$3" "$3.old" && /usr/bin/ditto "$2" "$3"; then rm -rf "$3.old"; else rm -rf "$3"; mv "$3.old" "$3"; fi
            /usr/bin/hdiutil detach "$4" -quiet
            /usr/bin/open "$3"
            """
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/sh")
            swap.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), newApp.path, appURL.path, mount.path]
            try swap.run()
            isRelaunching = true
            NSApplication.shared.terminate(nil)
        } catch {
            state = .failed(message: AppCopy.text("updates.error.install"))
        }
    }

    /// The new bundle must carry a valid signature with the running app's
    /// bundle id and team id. An unsigned or ad-hoc running app has no team
    /// to pin, so it never self-installs.
    nonisolated static func signatureMatchesRunningApp(_ candidate: URL) -> Bool {
        func signing(_ url: URL) -> [String: Any]? {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess else { return nil }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
            return info as? [String: Any]
        }
        guard let currentTeam = signing(Bundle.main.bundleURL)?[kSecCodeInfoTeamIdentifier as String] as? String,
              let new = signing(candidate),
              new[kSecCodeInfoIdentifier as String] as? String == Bundle.main.bundleIdentifier else { return false }
        return new[kSecCodeInfoTeamIdentifier as String] as? String == currentTeam
    }

    nonisolated static func runningAppTeamID() -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.terminationHandler = { $0.terminationStatus == 0 ? cont.resume() : cont.resume(throwing: UpdateInstallError.tool) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Hosts that may serve an update, and nothing else.
    nonisolated static let allowedDownloadHosts = ["dots.net.tr", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    /// True for an HTTPS address on a host that publishes our releases.
    nonisolated public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return allowedDownloadHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

private enum UpdateInstallError: Error { case download, signature, tool }
