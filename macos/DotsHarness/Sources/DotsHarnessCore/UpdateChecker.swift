// Copyright (c) 2026 DOTS
// Multiplatform version checking, release discovery and update management.

import AppKit
import Combine
import Foundation

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
    public static let defaultEndpoint = URL(string: "https://dots.net.tr/harness/check-update")!

    @Published public private(set) var state: UpdateState = .idle
    @Published public private(set) var lastCheckedAt: Date?
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
            state = .failed(message: "Geçersiz güncelleme sunucu URL'si")
            return
        }

        var request = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed(message: "Sunucudan beklenmeyen yanıt alındı")
                return
            }

            guard (200...299).contains(http.statusCode) else {
                state = .failed(message: "Güncelleme servisi hatası (\(http.statusCode))")
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

        if let url = targetURL {
            NSWorkspace.shared.open(url)
        }
    }
}
