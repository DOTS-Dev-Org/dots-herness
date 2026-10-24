// Copyright (c) 2026 DOTS
// Browse, install, fork, and publish native plugins through Marketplace.

import SwiftUI
import AppKit
import HarnessPluginKit
import PluginRuntime
import DotsHarnessCore

public struct MarketplaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var market: MarketplaceClient
    @ObservedObject private var session: MarketplaceSession
    @StateObject private var publisher: MarketplacePublisher
    @State private var query = ""
    @State private var actionError: String?
    @State private var pendingConsent: MarketplaceEntry?
    @State private var pendingForkConsent: MarketplaceFork?
    @State private var pendingReport: MarketplaceEntry?
    @State private var showPublish = false
    @State private var showEmailSignIn = false
    @State private var selectedArea = "core"
    @State private var selectedCategory: String?
    @State private var detailID: String?

    public init(model: AppModel) {
        self.model = model
        self.market = model.marketplace
        _session = ObservedObject(wrappedValue: model.marketplaceSession)
        _publisher = StateObject(wrappedValue: MarketplacePublisher(session: model.marketplaceSession))
    }

    private var source: [MarketplaceEntry] {
        selectedArea == "core" ? market.entries : market.communityEntries
    }

    /// Categories present in the current area, in display order.
    private var categories: [String] {
        Set(source.map { MarketCategory.key($0.category) }).sorted { MarketCategory.rank($0) < MarketCategory.rank($1) }
    }

    /// Category chip plus search: every typed word must match, ignoring case and diacritics.
    private var filtered: [MarketplaceEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return source.filter { entry in
            (selectedCategory == nil || MarketCategory.key(entry.category) == selectedCategory)
                && terms.allSatisfy { term in
                    [entry.name, entry.id, entry.description, entry.author, MarketCategory.title(entry.category)]
                        .contains { $0.localizedStandardContains(term) }
                }
        }
    }

    public var body: some View {
        Group {
            if let entry = (market.entries + market.communityEntries).first(where: { $0.id == detailID }) {
                detail(entry)
            } else {
                catalog
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task {
            // Always refetch: the cached registry would show stale download and like counts.
            await market.refresh()
            await market.refreshOwnedPlugins()
            await market.refreshLikes()
        }
        .onChange(of: selectedArea) { selectedCategory = nil }
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn {
                model.syncAccountFromMarketplace()
                Task {
                    await market.refreshOwnedPlugins()
                    await market.refreshLikes()
                }
            } else {
                Task { await market.refreshLikes() }
                model.setAccountIdentity(.signedOut())
            }
        }
        .sheet(isPresented: $showPublish) {
            MarketplacePublishView(session: session, publisher: publisher)
                .onDisappear {
                    Task {
                        await market.refresh()
                        await market.refreshOwnedPlugins()
                    }
                }
        }
        .sheet(isPresented: $showEmailSignIn) {
            MarketplaceEmailSignInView(session: session)
        }
        .sheet(item: $pendingReport) { entry in
            MarketplaceReportView(market: market, entry: entry)
        }
        .confirmationDialog(
            AppCopy.text("market.consent.title"),
            isPresented: Binding(
                get: { pendingConsent != nil },
                set: { if !$0 { pendingConsent = nil } }
            ),
            presenting: pendingConsent
        ) { entry in
            Button(AppCopy.text("market.consent.accept"), role: .destructive) {
                pendingConsent = nil
                installAccepted(entry)
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) { pendingConsent = nil }
        } message: { entry in
            Text(AppCopy.format("market.consent.message", entry.name, scopeTitle(entry.catalogScope),
                                reviewTitle(entry), MarketCategory.title(entry.category)))
        }
        .confirmationDialog(
            AppCopy.text("market.fork.consent.title"),
            isPresented: Binding(
                get: { pendingForkConsent != nil },
                set: { if !$0 { pendingForkConsent = nil } }
            ),
            presenting: pendingForkConsent
        ) { fork in
            Button(AppCopy.text("market.consent.accept"), role: .destructive) {
                pendingForkConsent = nil
                market.forks.acceptAndEnable(fork)
                model.remount()
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) { pendingForkConsent = nil }
        } message: { fork in
            Text(AppCopy.format("market.fork.consent.message", fork.id))
        }
    }

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Always shown: hiding it while searching would shift the search field under the cursor.
                MarketFeatured(items: MarketItem.featured(in: source.map(item))) { detailID = $0.id }

                Text(AppCopy.text("market.tab.plugins")).font(.system(size: 24, weight: .semibold))

                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(AppCopy.text("marketplace.search"), text: $query).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.18)))

                    if market.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await market.refresh() } } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(AppCopy.text("common.refresh"))
                    }

                    Menu {
                        if session.isSignedIn {
                            Text(session.profile?.email ?? AppCopy.text("market.account"))
                            Button(AppCopy.text("sidebar.signOut")) { signOutMarketplace() }
                        } else {
                            ForEach(MarketplaceProvider.allCases) { provider in
                                Button(provider.title) { session.beginOAuth(provider) }
                            }
                            Divider()
                            Button(AppCopy.text("market.signIn.email")) { showEmailSignIn = true }
                        }
                    } label: {
                        Image(systemName: session.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(session.isSignedIn ? (session.profile?.email ?? AppCopy.text("market.account")) : AppCopy.text("market.signIn"))

                    Menu {
                        Button(AppCopy.text("market.publish")) { showPublish = true }
                            .disabled(!session.isSignedIn)
                    } label: {
                        HStack(spacing: 6) {
                            Text(AppCopy.text("composer.add")).font(.system(size: 13, weight: .medium))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.primary, in: Capsule())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                HStack(spacing: 4) {
                    MarketPill(AppCopy.text("market.area.core"), selected: selectedArea == "core") { selectedArea = "core" }
                    MarketPill(AppCopy.text("market.area.communityExperimental"), selected: selectedArea == "community") { selectedArea = "community" }
                }

                if categories.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            MarketPill(AppCopy.text("library.all"), selected: selectedCategory == nil) { selectedCategory = nil }
                            ForEach(categories, id: \.self) { id in
                                MarketPill(MarketCategory.title(id), selected: selectedCategory == id) { selectedCategory = id }
                            }
                        }
                    }
                }

                if !market.forks.forks.isEmpty { localForks }
                if session.isSignedIn && !market.ownedPlugins.isEmpty { ownedPlugins }

                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                }

                if filtered.isEmpty {
                    ContentUnavailableView(
                        selectedArea == "core" ? AppCopy.text("marketplace.empty") : AppCopy.text("market.community.empty"),
                        systemImage: "shippingbox",
                        description: Text(selectedArea == "core"
                                          ? AppCopy.text("marketplace.emptyHint")
                                          : AppCopy.text("market.community.emptyHint"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(MarketItem.sections(filtered.map(item)), id: \.title) { section in
                        Text(section.title).font(.system(size: 16, weight: .medium)).padding(.top, 10)
                        LazyVGrid(columns: MarketRowLayout.columns, alignment: .leading, spacing: 20) {
                            ForEach(section.items) { listing in
                                if let entry = filtered.first(where: { $0.id == listing.id }) { row(entry) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func item(_ entry: MarketplaceEntry) -> MarketItem {
        let verified = entry.verificationStatus == "verified"
        return MarketItem(
            id: entry.id, symbol: MarketCategory.symbol(entry.category), title: entry.name,
            summary: entry.description.isEmpty ? entry.id : entry.description, category: entry.category, publisher: entry.author,
            badge: verified ? (entry.author == "DOTS" ? .official : .verified) : nil,
            date: entry.publishedAt, downloads: entry.downloads, likes: entry.likes, featured: entry.featured
        )
    }

    /// Compact catalog row; the full listing opens in place on click.
    private func row(_ entry: MarketplaceEntry) -> some View {
        MarketRow(item: item(entry), open: { detailID = entry.id }) { quickAction(entry) }
    }

    @ViewBuilder
    private func quickAction(_ entry: MarketplaceEntry) -> some View {
        if market.busyIDs.contains(entry.id) {
            ProgressView().controlSize(.small)
        } else {
            switch market.status(entry) {
            case .notInstalled:
                MarketIconButton("plus", help: AppCopy.text("marketplace.install")) {
                    pendingConsent = entry
                }
            case .updateAvailable(let installed):
                MarketIconButton("arrow.down.circle", help: AppCopy.format("marketplace.update", installed, entry.version)) {
                    pendingConsent = entry
                }
            case .upToDate:
                Image(systemName: "checkmark")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .help(AppCopy.text("local.installed"))
            }
        }
    }

    private func detail(_ entry: MarketplaceEntry) -> some View {
        let listing = item(entry)
        return MarketDetail(item: listing, backTitle: AppCopy.text("market.tab.plugins"), back: { detailID = nil },
                            related: listing.related(in: source.map(item)), openRelated: { detailID = $0.id }) {
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red)
            }
            if !entry.description.isEmpty {
                Text(entry.description).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    TagBadge(scopeTitle(entry.catalogScope))
                    TagBadge(MarketCategory.title(entry.category))
                    TagBadge(reviewTitle(entry))
                    if entry.riskLevel != "low" && entry.riskLevel != "unknown" {
                        TagBadge(AppCopy.format("market.risk", entry.riskLevel))
                    }
                    if entry.signature != nil || entry.currentArtifact?.signature != nil { TagBadge(AppCopy.text("market.signed")) }
                    if market.forks.hasFork(for: entry.id) { TagBadge(AppCopy.text("market.customized")) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                MarketField(AppCopy.text("market.field.version"), "v\(entry.version)")
                if let license = entry.license { MarketField(AppCopy.text("market.field.license"), license) }
                MarketField(AppCopy.text("market.field.type"), entry.tier)
                MarketField(AppCopy.text("market.field.source"), entry.sourceVisibility)
            }
            HStack(spacing: 14) {
                if let homepage = entry.homepage, let url = URL(string: homepage) { Link(AppCopy.text("market.homepage"), destination: url) }
                if let source = entry.sourceURL, let url = URL(string: source) { Link(AppCopy.text("market.sourceCode"), destination: url) }
            }
            if !entry.permissions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppCopy.text("market.permissions")).font(.headline)
                    ForEach(entry.permissions, id: \.self) { permission in
                        Label(permission, systemImage: "lock").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if session.isSignedIn {
                Button(AppCopy.text("market.report")) {
                    pendingReport = entry
                }
                .buttonStyle(.link)
            }
        } actions: {
            likeButton(entry)
            action(entry)
        }
    }

    private func scopeTitle(_ scope: String) -> String {
        switch scope {
        case "core": return AppCopy.text("market.area.core")
        case "experimental": return AppCopy.text("market.area.experimental")
        default: return AppCopy.text("market.area.community")
        }
    }

    private func reviewTitle(_ entry: MarketplaceEntry) -> String {
        AppCopy.text(entry.verificationStatus == "verified" ? "market.review.verified" : "market.review.pending")
    }

    private func likeButton(_ entry: MarketplaceEntry) -> some View {
        let liked = market.likedIDs.contains(entry.id)
        return MarketIconButton(liked ? "heart.fill" : "heart",
                                help: AppCopy.text(session.isSignedIn ? (liked ? "market.unlike" : "market.like") : "market.likeSignIn")) {
            actionError = nil
            Task {
                do { try await market.setLiked(!liked, id: entry.id) }
                catch { actionError = error.localizedDescription }
            }
        }
        .disabled(!session.isSignedIn)
    }

    @ViewBuilder
    private func action(_ entry: MarketplaceEntry) -> some View {
        if market.busyIDs.contains(entry.id) {
            ProgressView().controlSize(.small)
        } else {
            switch market.status(entry) {
            case .notInstalled:
                Button(AppCopy.text("marketplace.install")) {
                    pendingConsent = entry
                }
                .buttonStyle(.borderedProminent)
            case .updateAvailable(let installed):
                Button(AppCopy.format("marketplace.update", installed, entry.version)) {
                    pendingConsent = entry
                }
                .buttonStyle(.borderedProminent)
            case .upToDate:
                if !market.forks.hasFork(for: entry.id) {
                    Button(AppCopy.text("market.customize")) {
                        createFork(entry)
                    }
                }
                Button(AppCopy.text("common.remove"), role: .destructive) {
                    actionError = nil
                    do {
                        if entry.id == VisionFallbackDefaults.pluginID {
                            try model.removeVisionPlugin()
                        } else {
                            try market.remove(entry.id)
                            model.remount()
                        }
                    }
                    catch { actionError = error.localizedDescription }
                }
            }
        }
    }

    private var localForks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppCopy.text("market.localForks")).font(.headline)
            ForEach(market.forks.forks) { fork in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fork.id).font(.caption.monospaced())
                        Text(AppCopy.format("market.fork.upstream", fork.upstreamID, fork.upstreamVersion))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let available = fork.upstreamVersionAvailable {
                            Text(AppCopy.format("market.fork.newUpstream", available))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button(AppCopy.text("market.openFolder")) { NSWorkspace.shared.open(market.forks.folder(for: fork)) }
                    Button(AppCopy.text("studio.export")) { exportFork(fork) }
                    Button(AppCopy.text("common.delete"), role: .destructive) { deleteFork(fork) }
                    if fork.upstreamVersionAvailable != nil {
                        Button(AppCopy.text("market.fork.compared")) { market.forks.acknowledgeUpstream(fork, version: fork.upstreamVersionAvailable!) }
                    }
                    Button(AppCopy.text("plan.accept")) { pendingForkConsent = fork }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var ownedPlugins: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppCopy.text("market.owned")).font(.headline)
            ForEach(market.ownedPlugins) { plugin in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(plugin.name).font(.subheadline.weight(.semibold))
                        Text(plugin.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text(AppCopy.text(plugin.sourceVisibility == "private" ? "market.source.private" : "market.source.public"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button(AppCopy.text("market.unpublish"), role: .destructive) {
                            unpublish(plugin)
                        }
                    }
                    ForEach(plugin.releases) { release in
                        HStack(spacing: 6) {
                            Text("v\(release.version)").font(.caption.monospaced())
                            Text(release.license).font(.caption2).foregroundStyle(.secondary)
                            Text("\(release.catalogScope) / \(release.category)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(release.moderationStatus)
                                .font(.caption2)
                                .foregroundStyle(release.moderationStatus == "rejected" || release.moderationStatus == "suspended" ? .red : .secondary)
                            ForEach(release.artifacts) { artifact in
                                Text("\(artifact.platform)/\(artifact.architecture): \(artifact.status)")
                                    .font(.caption2)
                                    .foregroundStyle(artifact.status == "failed" ? .red : .secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func createFork(_ entry: MarketplaceEntry) {
        do {
            let fork = try market.forks.createFork(upstreamID: entry.id, upstreamVersion: entry.version)
            actionError = AppCopy.format("market.fork.created", fork.id)
            model.remount()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteFork(_ fork: MarketplaceFork) {
        do {
            try market.forks.delete(fork)
            model.remount()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func exportFork(_ fork: MarketplaceFork) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(fork.id).dotsplugin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try market.forks.export(fork, to: url)
            actionError = AppCopy.text("market.fork.exported")
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func unpublish(_ plugin: MarketplaceOwnedPlugin) {
        actionError = nil
        Task {
            do {
                try await market.unpublish(plugin.id)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func signOutMarketplace() {
        Task {
            await session.signOut()
            model.setAccountIdentity(.signedOut())
        }
    }

    private func installAccepted(_ entry: MarketplaceEntry) {
        actionError = nil
        Task {
            do {
                if entry.id == VisionFallbackDefaults.pluginID {
                    try await model.installVisionPlugin()
                } else {
                    try await market.install(entry)
                    model.remount()
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

}

@MainActor
private struct MarketplaceEmailSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: MarketplaceSession
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppCopy.text("market.signIn.title")).font(.title2.weight(.semibold))
                Spacer()
                Button(AppCopy.text("feedback.close")) { dismiss() }
            }
            TextField(AppCopy.text("market.email"), text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
            SecureField(AppCopy.text("market.password"), text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(AppCopy.text("market.signIn")) { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || email.isEmpty || password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func submit() {
        isSubmitting = true
        error = nil
        Task {
            do {
                try await session.signIn(email: email, password: password)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

@MainActor
private struct MarketplacePublishView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: MarketplaceSession
    @ObservedObject var publisher: MarketplacePublisher
    @State private var folder: URL?
    @State private var license = "MIT"
    @State private var version = "1.0.0"
    @State private var sourceVisibility = "public"
    @State private var selectedTargets = Set(MarketplaceTarget.defaultTargets.map(\.id))
    @State private var error: String?
    @State private var irPreview: String?
    @State private var nativeSourcePreview: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppCopy.text("market.publish.title")).font(.title2.weight(.semibold))
                Spacer()
                Button(AppCopy.text("feedback.close")) { dismiss() }
            }
            Text(AppCopy.text("market.publish.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(folder?.path ?? AppCopy.text("market.publish.noFolder"))
                    .font(.caption.monospaced())
                    .lineLimit(2)
                Spacer()
                Button(AppCopy.text("market.publish.chooseFolder")) { chooseFolder() }
            }
            if let irPreview {
                DisclosureGroup(AppCopy.text("market.publish.irPreview")) {
                    ScrollView {
                        Text(irPreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            if let nativeSourcePreview {
                DisclosureGroup(AppCopy.text("market.publish.sourcePreview")) {
                    ScrollView {
                        Text(nativeSourcePreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            TextField(AppCopy.text("market.publish.version"), text: $version)
                .textFieldStyle(.roundedBorder)
            TextField(AppCopy.text("market.publish.license"), text: $license)
                .textFieldStyle(.roundedBorder)
            Picker(AppCopy.text("market.publish.visibility"), selection: $sourceVisibility) {
                Text(AppCopy.text("market.publish.public")).tag("public")
                Text(AppCopy.text("market.publish.private")).tag("private")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(AppCopy.text("market.publish.targets")).font(.caption.weight(.semibold))
                ForEach(MarketplaceTarget.defaultTargets) { target in
                    Toggle(target.title, isOn: Binding(
                        get: { selectedTargets.contains(target.id) },
                        set: { enabled in
                            if enabled { selectedTargets.insert(target.id) }
                            else { selectedTargets.remove(target.id) }
                        }
                    ))
                }
            }
            if let status = publisher.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = error ?? session.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text(AppCopy.text("market.publish.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(AppCopy.text("market.publish.submit")) { publish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(folder == nil || publisher.isPublishing || !session.isSignedIn || selectedTargets.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            loadPreviews(from: url)
        }
    }

    private func loadPreviews(from folder: URL) {
        irPreview = (try? String(contentsOf: folder.appendingPathComponent("plugin.ir.json"), encoding: .utf8))
            .map { String($0.prefix(12_000)) }
        let sourceRoot = folder.appendingPathComponent("source", isDirectory: true)
        let sourceFiles: [URL] = {
            guard let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
                return []
            }
            return enumerator
                .compactMap { $0 as? URL }
                .filter { ["swift", "cs", "xaml"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
        }()
        nativeSourcePreview = sourceFiles.prefix(2).compactMap { url in
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return "// \(url.path.replacingOccurrences(of: folder.path + "/", with: ""))\n\(String(contents.prefix(4_000)))"
        }.joined(separator: "\n\n")
        if nativeSourcePreview?.isEmpty == true { nativeSourcePreview = nil }
    }

    private func publish() {
        guard let folder else { return }
        error = nil
        Task {
            do {
                let targets = MarketplaceTarget.defaultTargets.filter { selectedTargets.contains($0.id) }
                try await publisher.publish(MarketplacePublishDraft(
                    folder: folder,
                    license: license,
                    version: version,
                    sourceVisibility: sourceVisibility,
                    targets: targets
                ))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

@MainActor
private struct MarketplaceReportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var market: MarketplaceClient
    let entry: MarketplaceEntry
    @State private var reason = "other"
    @State private var details = ""
    @State private var error: String?
    @State private var isSubmitting = false

    private static let reasons: [(String, String)] = [
        ("malware", "market.report.malware"),
        ("credential_theft", "market.report.credentialTheft"),
        ("data_exfiltration", "market.report.exfiltration"),
        ("deceptive_listing", "market.report.deceptive"),
        ("spam", "market.report.spam"),
        ("copyright", "market.report.copyright"),
        ("other", "sidebar.other"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppCopy.text("market.report.title")).font(.title2.weight(.semibold))
                Spacer()
                Button(AppCopy.text("feedback.close")) { dismiss() }
            }
            Text("\(entry.name) · v\(entry.version)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Picker(AppCopy.text("market.report.reason"), selection: $reason) {
                ForEach(Self.reasons, id: \.0) { value, label in
                    Text(AppCopy.text(label)).tag(value)
                }
            }
            TextEditor(text: $details)
                .font(.body)
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(AppCopy.text("market.report.submit")) { submit() }

                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func submit() {
        isSubmitting = true
        error = nil
        Task {
            do {
                try await market.report(entry, reason: reason, details: details)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}
