// Copyright (c) 2026 DOTS
// Right-dock pane for the Cloud work location: setup, run list and live transcript.

import AppKit
import DotsHarnessCore
import SwiftUI

struct DockCloudView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var session: MarketplaceSession
    @State private var expanded = Set<String>()
    @State private var showSetup = false
    @State private var tokenDraft = ""
    @State private var modelDraft = ""

    init(model: AppModel) {
        self.model = model
        _session = ObservedObject(wrappedValue: model.marketplaceSession)
    }

    private var repository: GitHubRepository? { model.cloudRepository }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let notice = model.cloudNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !session.isSignedIn {
                    signIn
                } else {
                    setup
                    if model.cloudRuns.isEmpty {
                        Text(AppCopy.text("cloud.empty"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(model.cloudRuns) { run($0) }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: session.isSignedIn) { await model.refreshCloudRuns() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud")
            VStack(alignment: .leading, spacing: 2) {
                Text(repository?.fullName ?? AppCopy.text("cloud.noRepository"))
                    .font(.system(size: 13, weight: .medium))
                Text(AppCopy.text("cloud.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.cloudBusy {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await model.refreshCloudRuns() } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(AppCopy.text("common.refresh"))
                .accessibilityLabel(AppCopy.text("common.refresh"))
            }
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.text("cloud.error.notSignedIn"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(MarketplaceProvider.allCases) { provider in
                    Button(provider.title) { session.beginOAuth(provider) }
                }
            }
        }
    }

    private var setup: some View {
        DisclosureGroup(isExpanded: $showSetup) {
            VStack(alignment: .leading, spacing: 10) {
                Text(AppCopy.text("cloud.setup.steps"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(AppCopy.text("cloud.setup.install")) { Task { await model.installCloudWorkflow() } }
                    .disabled(repository == nil || model.cloudBusy)
                if let repository {
                    Button(AppCopy.text("cloud.setup.secrets")) { NSWorkspace.shared.open(repository.actionsSecretsURL) }
                }

                Divider()
                Text(AppCopy.text(model.hasStoredGitHubToken ? "cloud.setup.tokenSaved" : "cloud.setup.tokenHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField(AppCopy.text("cloud.setup.token"), text: $tokenDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(AppCopy.text("common.save")) {
                        model.saveGitHubToken(tokenDraft)
                        tokenDraft = ""
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.hasStoredGitHubToken {
                        Button(AppCopy.text("common.remove")) { model.saveGitHubToken("") }
                    }
                }

                HStack {
                    TextField(AppCopy.text("cloud.setup.model"), text: $modelDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.cloudModel = modelDraft }
                    Button(AppCopy.text("common.save")) { model.cloudModel = modelDraft }
                        .disabled(modelDraft == model.cloudModel)
                }
            }
            .padding(.top, 6)
        } label: {
            Text(AppCopy.text("cloud.setup.title")).font(.callout.weight(.medium))
        }
        .onAppear {
            modelDraft = model.cloudModel
            // First visit: the steps matter more than an empty list.
            if model.cloudRuns.isEmpty { showSetup = true }
        }
    }

    private func run(_ run: CloudRun) -> some View {
        let isExpanded = expanded.contains(run.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(run.status))
                    .foregroundStyle(color(run.status))
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.prompt)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(isExpanded ? nil : 2)
                    Text(subtitle(run))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if run.status.isActive {
                    Button { Task { await model.cancelCloudRun(run) } } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(run.cancelRequested)
                    .help(AppCopy.text("common.stop"))
                    .accessibilityLabel(AppCopy.text("common.stop"))
                }
            }
            if isExpanded { details(run) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded.insert(run.id).inserted {
                Task { await model.refreshCloudRun(id: run.id) }
            } else {
                expanded.remove(run.id)
            }
        }
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func details(_ run: CloudRun) -> some View {
        let events = model.cloudRunEvents[run.id] ?? []
        if !events.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(events) { event in
                        Text(event.text)
                            .font(event.kind == "tool" ? Font.system(size: 11, design: .monospaced) : Font.system(size: 12))
                            .foregroundStyle(event.kind == "assistant" ? Color.primary : Color.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: 260)
        }
        if let error = run.error {
            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        HStack(spacing: 12) {
            if let link = run.githubRunURL.flatMap({ URL(string: $0) }) {
                Button(AppCopy.text("cloud.openRun")) { NSWorkspace.shared.open(link) }
            }
            if let branch = run.resultBranch, let repository = GitHubRepository(fullName: run.repository) {
                Button(AppCopy.format("cloud.openBranch", branch)) { NSWorkspace.shared.open(repository.branchURL(branch)) }
            }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    private func subtitle(_ run: CloudRun) -> String {
        let status = AppCopy.text("cloud.status.\(run.status.rawValue)")
        let when = run.createdDate.map { $0.formatted(.relative(presentation: .named)) } ?? ""
        return [status, run.baseRef, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func icon(_ status: CloudRunStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .cancelled: return "stop.circle"
        }
    }

    private func color(_ status: CloudRunStatus) -> Color {
        switch status {
        case .queued, .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
