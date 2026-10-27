// Copyright (c) 2026 DOTS
// Cloud work location: start, follow and cancel GitHub Actions runs of the agent.

import Combine
import Foundation

@MainActor
extension AppModel {
    private static let cloudPollInterval: UInt64 = 4_000_000_000
    private static let cloudEventPage = 200

    /// The github.com repository of the open project, from its `origin` remote.
    public var cloudRepository: GitHubRepository? { GitHubRepository(workspacePath: workspacePath) }

    /// Model id passed to the runner; empty uses the repository provider's default.
    public var cloudModel: String {
        get { host.settings.get("cloud.model")?.string ?? "" }
        set {
            host.settings.set("cloud.model", .string(newValue.trimmingCharacters(in: .whitespacesAndNewlines)))
            persistSettings()
            objectWillChange.send()
        }
    }

    public var hasStoredGitHubToken: Bool { GitHubCredential.hasStoredToken }

    public func saveGitHubToken(_ token: String) {
        GitHubCredential.store(token)
        objectWillChange.send()
    }

    public func showCloudRuns() {
        cloudPaneRequestID += 1
        Task { await refreshCloudRuns() }
    }

    /// Composer entry point. The draft is cleared at once and restored if the run could not start.
    func sendToCloud(text: String, draftText: String?) {
        if draftText != nil {
            guard draftAttachments.isEmpty else {
                cloudNotice = AppCopy.text("cloud.error.attachments")
                showCloudRuns()
                return
            }
            draft = ""
        }
        Task { [weak self] in
            guard let self else { return }
            let started = await self.startCloudRun(prompt: text)
            if !started, let draftText, self.draft.isEmpty { self.draft = draftText }
        }
    }

    @discardableResult
    public func startCloudRun(prompt: String) async -> Bool {
        guard !cloudBusy else { return false }
        cloudBusy = true
        defer { cloudBusy = false }
        cloudNotice = nil
        cloudPaneRequestID += 1
        do {
            guard let repository = cloudRepository else { throw CloudRunError.notGitHubRepository }
            guard marketplaceSession.isSignedIn else { throw CloudRunError.notSignedIn }
            let github = try await githubClient()
            // The runner checks out what GitHub has: unpushed commits are not part of the run.
            let baseRef: String
            if let branch = GitRemote.currentBranch(atRepository: workspacePath) {
                baseRef = branch
            } else {
                baseRef = try await github.defaultBranch(of: repository)
            }
            let model = cloudModel.isEmpty ? nil : cloudModel
            let api = CloudRunAPI(session: marketplaceSession)
            let run = try await api.create(repository: repository, baseRef: baseRef, prompt: prompt, model: model)
            upsertCloudRun(run)
            do {
                var inputs = [
                    "run_id": run.id,
                    "prompt": prompt,
                    "api_url": marketplaceSession.apiBase.absoluteString,
                ]
                if let model { inputs["model"] = model }
                try await github.dispatchCloudRun(repository: repository, ref: baseRef, inputs: inputs)
            } catch {
                // Close the record so a failed dispatch does not hold an active-run slot.
                if let closed = try? await api.cancel(id: run.id, error: error.localizedDescription) {
                    upsertCloudRun(closed)
                }
                throw error
            }
            ensureCloudPolling()
            return true
        } catch {
            cloudNotice = error.localizedDescription
            return false
        }
    }

    public func refreshCloudRuns() async {
        guard marketplaceSession.isSignedIn else { return }
        do {
            cloudRuns = try await CloudRunAPI(session: marketplaceSession).list()
            ensureCloudPolling()
        } catch {
            cloudNotice = error.localizedDescription
        }
    }

    /// Fetches the run and every event after the last one received.
    public func refreshCloudRun(id: String) async {
        let api = CloudRunAPI(session: marketplaceSession)
        do {
            while true {
                let (run, events) = try await api.detail(id: id, after: cloudRunEvents[id]?.last?.seq ?? 0)
                upsertCloudRun(run)
                if !events.isEmpty { cloudRunEvents[id, default: []].append(contentsOf: events) }
                if events.count < Self.cloudEventPage { break }
            }
        } catch {
            cloudNotice = error.localizedDescription
        }
    }

    public func cancelCloudRun(_ run: CloudRun) async {
        do {
            upsertCloudRun(try await CloudRunAPI(session: marketplaceSession).cancel(id: run.id))
            // The runner stops on its next heartbeat; cancelling the job as well
            // also stops a runner that is still installing.
            if let runID = run.githubRunID, let repository = GitHubRepository(fullName: run.repository) {
                try? await githubClient().cancelRun(repository: repository, runID: runID)
            }
        } catch {
            cloudNotice = error.localizedDescription
        }
    }

    /// Commits herness-cloud.yml to the repository's default branch.
    public func installCloudWorkflow() async {
        guard !cloudBusy else { return }
        cloudBusy = true
        defer { cloudBusy = false }
        cloudNotice = nil
        do {
            guard let repository = cloudRepository else { throw CloudRunError.notGitHubRepository }
            guard let template = CloudWorkflow.template() else {
                throw CloudRunError.api(status: 0, message: "herness-cloud.yml is missing from the app bundle")
            }
            let github = try await githubClient()
            let branch = try await github.defaultBranch(of: repository)
            try await github.installWorkflow(repository: repository, branch: branch, content: template)
            cloudNotice = AppCopy.format("cloud.installed", repository.fullName, branch)
        } catch {
            cloudNotice = error.localizedDescription
        }
    }

    private func githubClient() async throws -> GitHubActionsClient {
        let token = await Task.detached(priority: .userInitiated) { GitHubCredential.resolve() }.value
        guard let token else { throw CloudRunError.noGitHubToken }
        return GitHubActionsClient(token: token)
    }

    private func upsertCloudRun(_ run: CloudRun) {
        if let index = cloudRuns.firstIndex(where: { $0.id == run.id }) {
            if cloudRuns[index] != run { cloudRuns[index] = run }
        } else {
            cloudRuns.insert(run, at: 0)
        }
    }

    /// Polls while any run is queued or running, then stops.
    func ensureCloudPolling() {
        guard cloudPollTask == nil, cloudRuns.contains(where: { $0.status.isActive }) else { return }
        cloudPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = self.cloudRuns.filter { $0.status.isActive }
                if active.isEmpty { break }
                for run in active { await self.refreshCloudRun(id: run.id) }
                try? await Task.sleep(nanoseconds: Self.cloudPollInterval)
            }
            self?.cloudPollTask = nil
        }
    }
}
