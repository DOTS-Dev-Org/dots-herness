// Copyright (c) 2026 DOTS
// Cloud runs on the phone: start, follow and cancel GitHub Actions runs of the
// HerNess agent in the selected project's repository (parity with the desktop
// Cloud work location, see docs/cloud-runs.md).
//
// The phone creates the run record with the HerNess account session, then
// dispatches herness-cloud.yml with the GitHub token from Settings. The runner
// streams its transcript back to the HerNess API and pushes its changes to a
// herness/cloud-* branch.

import Foundation
import SwiftUI

struct MobileCloudRepository: Equatable, Sendable {
    let owner: String
    let name: String

    var fullName: String { "\(owner)/\(name)" }
    var webURL: URL { URL(string: "https://github.com/\(fullName)")! }
    var actionsSecretsURL: URL { webURL.appendingPathComponent("settings/secrets/actions") }
    func branchURL(_ branch: String) -> URL { webURL.appendingPathComponent("tree").appendingPathComponent(branch) }

    init?(fullName: String?) {
        let parts = (fullName ?? "").split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }
}

enum MobileCloudRunStatus: String, Codable, Sendable {
    case queued, running, succeeded, failed, cancelled
    var isActive: Bool { self == .queued || self == .running }
}

struct MobileCloudRun: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let repository: String
    let baseRef: String
    let prompt: String
    let status: MobileCloudRunStatus
    let cancelRequested: Bool
    let githubRunID: String?
    let githubRunURL: String?
    let resultBranch: String?
    let error: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, repository, prompt, status, error
        case baseRef = "base_ref"
        case cancelRequested = "cancel_requested"
        case githubRunID = "github_run_id"
        case githubRunURL = "github_run_url"
        case resultBranch = "result_branch"
        case createdAt = "created_at"
    }

    var createdDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }
}

struct MobileCloudEvent: Codable, Identifiable, Equatable, Sendable {
    let seq: Int
    let kind: String
    let text: String
    var id: Int { seq }
}

/// A failure whose message is already localized.
struct MobileCloudError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// api.github.com calls a cloud run needs, made with the phone's GitHub sign-in.
struct MobileGitHubActions: Sendable {
    static let workflowFile = "herness-cloud.yml"
    static let workflowPath = ".github/workflows/herness-cloud.yml"
    let token: String
    var apiBase = URL(string: "https://api.github.com")!

    func defaultBranch(_ repository: MobileCloudRepository) async throws -> (branch: String?, status: Int, message: String?) {
        let (json, status) = try await send("GET", "repos/\(repository.fullName)")
        return (json?["default_branch"] as? String, status, json?["message"] as? String)
    }

    /// Returns the HTTP status and GitHub's message: 204 is success, 404 means the workflow is missing on `ref`.
    func dispatch(_ repository: MobileCloudRepository, ref: String, inputs: [String: String]) async throws -> (status: Int, message: String?) {
        let (json, status) = try await send("POST", "repos/\(repository.fullName)/actions/workflows/\(Self.workflowFile)/dispatches", body: ["ref": ref, "inputs": inputs])
        return (status, json?["message"] as? String)
    }

    func install(_ repository: MobileCloudRepository, branch: String, content: String) async throws -> (status: Int, message: String?) {
        let path = "repos/\(repository.fullName)/contents/\(Self.workflowPath)"
        let (existing, existingStatus) = try await send("GET", path, query: "ref=\(branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch)")
        var body: [String: Any] = ["message": "Add HerNess cloud workflow", "content": Data(content.utf8).base64EncodedString(), "branch": branch]
        if existingStatus == 200, let sha = existing?["sha"] as? String { body["sha"] = sha }
        let (json, status) = try await send("PUT", path, body: body)
        return (status, json?["message"] as? String)
    }

    func cancel(_ repository: MobileCloudRepository, runID: String) async throws {
        _ = try await send("POST", "repos/\(repository.fullName)/actions/runs/\(runID)/cancel")
    }

    private func send(_ method: String, _ path: String, query: String? = nil, body: [String: Any]? = nil) async throws -> ([String: Any]?, Int) {
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

@MainActor
final class MobileCloudStore: ObservableObject {
    @Published private(set) var runs: [MobileCloudRun] = []
    @Published private(set) var events: [String: [MobileCloudEvent]] = [:]
    @Published var notice: String?
    @Published private(set) var busy = false
    private let session: MobileMarketplaceSession
    private var polling = false
    var text: (String) -> String = { $0 }
    var format: (String, [CVarArg]) -> String = { key, _ in key }

    init(session: MobileMarketplaceSession = .shared) {
        self.session = session
    }

    var isSignedIn: Bool { session.isSignedIn }

    /// The GitHub token from the phone's GitHub sign-in (Settings).
    private var githubToken: String? {
        let token = SecureStore().read("oauth.github.access") ?? ""
        return token.isEmpty ? nil : token
    }

    @discardableResult
    func start(prompt: String, repository: MobileCloudRepository?, branch: String?) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        notice = nil
        do {
            guard let repository else { throw fail(text("cloud.error.notGitHub")) }
            guard session.isSignedIn else { throw fail(text("cloud.error.notSignedIn")) }
            let github = try githubClient()
            var baseRef = branch?.trimmingCharacters(in: .whitespaces) ?? ""
            if baseRef.isEmpty {
                let result = try await github.defaultBranch(repository)
                guard let branch = result.branch else { throw githubFailure(result.status, result.message) }
                baseRef = branch
            }
            let run = try await create(repository: repository, baseRef: baseRef, prompt: prompt)
            upsert(run)
            let inputs = ["run_id": run.id, "prompt": prompt, "api_url": session.apiBase]
            let dispatch = try await github.dispatch(repository, ref: baseRef, inputs: inputs)
            if dispatch.status != 204 && dispatch.status != 200 {
                let error = dispatch.status == 404
                    ? fail(format("cloud.error.workflowMissing", [repository.fullName, baseRef]))
                    : githubFailure(dispatch.status, dispatch.message)
                // Close the record so a failed dispatch does not hold an active-run slot.
                if let closed = try? await cancelRecord(run.id, error: error.message) { upsert(closed) }
                throw error
            }
            startPolling()
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func refresh() async {
        guard session.isSignedIn else { return }
        do {
            let (data, _) = try await request("api/cloud-runs")
            struct Envelope: Decodable { let runs: [MobileCloudRun] }
            runs = try JSONDecoder().decode(Envelope.self, from: data).runs
            startPolling()
        } catch {
            notice = error.localizedDescription
        }
    }

    func refreshRun(_ id: String) async {
        struct Envelope: Decodable { let run: MobileCloudRun; let events: [MobileCloudEvent] }
        do {
            while true {
                let after = events[id]?.last?.seq ?? 0
                let (data, _) = try await request("api/cloud-runs/\(id)", query: "after=\(after)")
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                upsert(envelope.run)
                // A poll and a manual refresh can both ask from the same seq.
                let fresh = envelope.events.filter { $0.seq > (events[id]?.last?.seq ?? 0) }
                if !fresh.isEmpty { events[id, default: []].append(contentsOf: fresh) }
                if envelope.events.count < 200 { break }
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func cancel(_ run: MobileCloudRun) async {
        do {
            upsert(try await cancelRecord(run.id, error: nil))
            if let runID = run.githubRunID, let repository = MobileCloudRepository(fullName: run.repository), let github = try? githubClient() {
                try? await github.cancel(repository, runID: runID)
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Commits herness-cloud.yml to the default branch. The GitHub sign-in needs the workflow scope.
    func installWorkflow(repository: MobileCloudRepository?) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        notice = nil
        do {
            guard let repository else { throw fail(text("cloud.error.notGitHub")) }
            guard let url = Bundle.main.url(forResource: "herness-cloud", withExtension: "yml"),
                  let template = try? String(contentsOf: url, encoding: .utf8) else { throw fail("herness-cloud.yml is missing from the app.") }
            let github = try githubClient()
            let result = try await github.defaultBranch(repository)
            guard let branch = result.branch else { throw githubFailure(result.status, result.message) }
            let install = try await github.install(repository, branch: branch, content: template)
            if install.status == 403 || install.status == 404 { throw fail(text("cloud.error.installForbidden")) }
            guard install.status == 200 || install.status == 201 else { throw githubFailure(install.status, install.message) }
            notice = format("cloud.installed", [repository.fullName, branch])
        } catch {
            notice = error.localizedDescription
        }
    }

    private func create(repository: MobileCloudRepository, baseRef: String, prompt: String) async throws -> MobileCloudRun {
        let body = try JSONSerialization.data(withJSONObject: ["repository": repository.fullName, "base_ref": baseRef, "prompt": prompt])
        return try decodeRun(try await request("api/cloud-runs", method: "POST", body: body).0)
    }

    private func cancelRecord(_ id: String, error: String?) async throws -> MobileCloudRun {
        let body = try JSONSerialization.data(withJSONObject: error.map { ["error": String($0.prefix(500))] } ?? [:])
        return try decodeRun(try await request("api/cloud-runs/\(id)/cancel", method: "POST", body: body).0)
    }

    private func decodeRun(_ data: Data) throws -> MobileCloudRun {
        struct Envelope: Decodable { let run: MobileCloudRun }
        return try JSONDecoder().decode(Envelope.self, from: data).run
    }

    private func request(_ path: String, query: String? = nil, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.authorizedData(path: path, query: query, method: method, body: body)
        guard (200..<300).contains(response.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            if response.statusCode == 429, error == "cloud_run_limit" {
                throw fail(format("cloud.error.limit", [json?["limit"] as? Int ?? 3]))
            }
            if response.statusCode == 401 { throw fail(text("cloud.error.notSignedIn")) }
            throw fail(format("cloud.error.api", [response.statusCode, error]))
        }
        return (data, response)
    }

    private func githubClient() throws -> MobileGitHubActions {
        guard let token = githubToken else { throw fail(text("cloud.error.noToken")) }
        return MobileGitHubActions(token: token)
    }

    private func githubFailure(_ status: Int, _ message: String?) -> MobileCloudError {
        fail(format("cloud.error.github", [status, message ?? "HTTP \(status)"]))
    }

    private func fail(_ message: String) -> MobileCloudError { MobileCloudError(message: message) }

    private func upsert(_ run: MobileCloudRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            if runs[index] != run { runs[index] = run }
        } else {
            runs.insert(run, at: 0)
        }
    }

    /// Polls while any run is queued or running, then stops.
    private func startPolling() {
        guard !polling, runs.contains(where: { $0.status.isActive }) else { return }
        polling = true
        Task { [weak self] in
            while let self, case let active = self.runs.filter({ $0.status.isActive }), !active.isEmpty {
                for run in active { await self.refreshRun(run.id) }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            self?.polling = false
        }
    }
}

struct MobileCloudView: View {
    @EnvironmentObject private var local: LocalWorkspaceStore
    @EnvironmentObject private var localization: MobileLocalization
    @StateObject private var store = MobileCloudStore()
    @ObservedObject private var session = MobileMarketplaceSession.shared
    let onBack: () -> Void
    @State private var prompt = ""
    @State private var selectedRunID: String?
    @State private var email = ""
    @State private var password = ""
    @State private var showSetup = false

    private var repository: MobileCloudRepository? { MobileCloudRepository(fullName: local.selectedProject.repository) }
    private var branch: String? { local.selectedProject.branch }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(repository?.fullName ?? localization.text("cloud.noRepository")).font(.headline)
                        Text(localization.text("cloud.subtitle")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let notice = store.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if !session.isSignedIn { signIn } else { content }
            }
            .navigationTitle(localization.text("cloud.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) { Image(systemName: localization.isRTL ? "chevron.right" : "chevron.left") }
                        .accessibilityLabel(localization.text("intro.back"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(localization.text("common.refresh"))
                }
            }
            .refreshable { await store.refresh() }
            .task(id: session.isSignedIn) {
                store.text = { localization.text($0) }
                store.format = { key, arguments in String(format: localization.text(key), arguments: arguments) }
                await store.refresh()
                showSetup = store.runs.isEmpty
            }
        }
    }

    @ViewBuilder
    private var signIn: some View {
        Section(localization.text("market.signIn.title")) {
            Text(localization.text("cloud.error.notSignedIn")).font(.footnote).foregroundStyle(.secondary)
            TextField(localization.text("market.email"), text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            SecureField(localization.text("market.password"), text: $password)
                .textContentType(.password)
            Button(localization.text("cloud.signIn")) {
                Task {
                    do {
                        try await session.signIn(email: email, password: password)
                        password = ""
                    } catch {
                        store.notice = error.localizedDescription
                    }
                }
            }
            .disabled(email.isEmpty || password.isEmpty)
        }
    }

    @ViewBuilder
    private var content: some View {
        Section {
            DisclosureGroup(localization.text("cloud.setup.title"), isExpanded: $showSetup) {
                Text(localization.text("cloud.setup.steps")).font(.footnote)
                Button(localization.text("cloud.setup.install")) { Task { await store.installWorkflow(repository: repository) } }
                    .disabled(repository == nil || store.busy)
                if let repository {
                    Link(localization.text("cloud.setup.secrets"), destination: repository.actionsSecretsURL)
                }
            }
        }
        Section(localization.text("cloud.prompt")) {
            TextField(localization.text("cloud.prompt"), text: $prompt, axis: .vertical)
                .lineLimit(3...8)
            Button {
                let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { if await store.start(prompt: text, repository: repository, branch: branch) { prompt = "" } }
            } label: {
                HStack {
                    Text(localization.text("cloud.start"))
                    if store.busy { Spacer(); ProgressView() }
                }
            }
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy || repository == nil)
        }
        Section {
            if store.runs.isEmpty {
                Text(localization.text("cloud.empty")).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(store.runs) { run in
                runRow(run)
            }
        }
    }

    private func runRow(_ run: MobileCloudRun) -> some View {
        let expanded = selectedRunID == run.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: icon(run.status)).foregroundStyle(color(run.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.prompt).font(.subheadline.weight(.medium)).lineLimit(expanded ? nil : 2)
                    Text(subtitle(run)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if expanded {
                ForEach(store.events[run.id] ?? []) { event in
                    Text(event.text)
                        .font(event.kind == "tool" ? Font.system(.caption, design: .monospaced) : Font.footnote)
                        .foregroundStyle(event.kind == "assistant" ? Color.primary : Color.secondary)
                        .textSelection(.enabled)
                }
                if let error = run.error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack(spacing: 16) {
                    if let url = run.githubRunURL.flatMap({ URL(string: $0) }) {
                        Link(localization.text("cloud.openRun"), destination: url)
                    }
                    if let branch = run.resultBranch, let repository = MobileCloudRepository(fullName: run.repository) {
                        Link(localization.format("cloud.openBranch", branch), destination: repository.branchURL(branch))
                    }
                    if run.status.isActive {
                        Button(localization.text("common.stop"), role: .destructive) { Task { await store.cancel(run) } }
                            .disabled(run.cancelRequested)
                    }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded {
                selectedRunID = nil
            } else {
                selectedRunID = run.id
                Task { await store.refreshRun(run.id) }
            }
        }
    }

    private func subtitle(_ run: MobileCloudRun) -> String {
        let when = run.createdDate.map { $0.formatted(.relative(presentation: .named)) } ?? ""
        return [localization.text("cloud.status.\(run.status.rawValue)"), run.baseRef, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func icon(_ status: MobileCloudRunStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .cancelled: return "stop.circle"
        }
    }

    private func color(_ status: MobileCloudRunStatus) -> Color {
        switch status {
        case .queued, .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
