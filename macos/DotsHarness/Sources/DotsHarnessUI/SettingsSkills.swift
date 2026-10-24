// Copyright (c) 2026 DOTS
// Remote-mobile and skills settings panes.

import AppKit
import UniformTypeIdentifiers
import SwiftUI
import HarnessPluginKit
import DotsHarnessCore
import PluginRuntime

struct RemoteMobileSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tunnelError = ""

    var body: some View {
        Form {
            Section(AppCopy.text("remote.title")) {
                Toggle(AppCopy.text("remote.enable"), isOn: $model.remoteControlEnabled)
                Toggle(AppCopy.text("remote.shareLan"), isOn: $model.remoteControlSharesWithLAN)
                    .disabled(!model.remoteControlEnabled)
                LabeledContent(AppCopy.text("remote.lan"), value: model.remoteControl.preferredEndpoint)
                if !model.remoteControlEnabled {
                    Text(AppCopy.text("remote.enableHint")).font(.caption).foregroundStyle(.secondary)
                }
                if let pairing = activePairing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppCopy.text("remote.scan")).font(.caption)
                        if let image = qrImage(pairing.payload) {
                            Image(nsImage: image).resizable().interpolation(.none).frame(width: 180, height: 180).accessibilityLabel(AppCopy.text("remote.qr"))
                        }
                        LabeledContent(AppCopy.text("remote.code"), value: pairing.code).textSelection(.enabled)
                        Text(pairing.payload).font(.caption.monospaced()).textSelection(.enabled)
                        Text(AppCopy.format("remote.expires", pairing.expiresAt.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                HStack {
                    Button(AppCopy.text("remote.newCode")) { _ = model.beginRemotePairing() }
                    Button(AppCopy.text("remote.copyLink")) {
                        if let value = activePairing?.payload { NSPasteboard.copy(value) }
                    }.disabled(activePairing == nil)
                }
                HStack {
                    Button(AppCopy.text("remote.tunnel.enable")) { Task { do { _ = try await model.enableRemoteCloudTunnel() } catch { tunnelError = error.localizedDescription } } }
                    if model.remoteControl.publicEndpoint != nil { Button(AppCopy.text("remote.tunnel.disable")) { model.disableRemoteCloudTunnel() } }
                }
                if !tunnelError.isEmpty { Text(tunnelError).font(.caption).foregroundStyle(.red) }
                Text(AppCopy.text("remote.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(AppCopy.text("settings.tab.mobile"))
        .onAppear { if activePairing == nil { _ = model.beginRemotePairing() } }
    }

    private var activePairing: RemotePairingInfo? {
        guard let pairing = model.remoteControl.pairing, pairing.expiresAt > Date() else { return nil }
        return pairing
    }

    private func qrImage(_ value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.insetBy(dx: -8, dy: -8)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(output, from: extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
    }
}

struct SkillsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var skills: SkillCatalog
    @ObservedObject var market: MarketplaceClient
    @State private var tab: Section = .catalog
    @State private var detailEntryID: String?
    @State private var detailSkillID: String?
    @State private var error = ""

    private enum Section: String, CaseIterable {
        case catalog, installed

        var title: String { AppCopy.text("settings.skills.\(rawValue)") }
    }

    init(model: AppModel) {
        self.model = model
        self.skills = model.activeSkills
        self.market = model.marketplace
    }

    private var catalogItems: [MarketItem] { skills.marketplaceEntries.map(item) }

    var body: some View {
        Group {
            if let entry = skills.marketplaceEntries.first(where: { $0.id == detailEntryID }) {
                catalogDetail(entry)
            } else if let skill = skills.entries.first(where: { $0.id == detailSkillID }) {
                installedDetail(skill)
            } else {
                list
            }
        }
        .task {
            if let data = await market.catalogData("skills") { skills.updateMarketplace(data) }
            await market.refreshLikes()
        }
    }

    private func likeButton(_ entry: SkillMarketplaceEntry) -> some View {
        let signedIn = market.session.isSignedIn
        let liked = market.likedCatalog["skill"]?.contains(entry.id) ?? false
        return MarketIconButton(liked ? "heart.fill" : "heart",
                                help: AppCopy.text(signedIn ? (liked ? "market.unlike" : "market.like") : "market.likeSignIn")) {
            error = ""
            Task {
                do { skills.setMetrics(id: entry.id, likes: try await market.setCatalogLiked(!liked, kind: "skill", id: entry.id)) }
                catch { self.error = error.localizedDescription }
            }
        }
        .disabled(!signedIn)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(AppCopy.text("settings.tab.skills")).font(.system(size: 24, weight: .semibold))
                HStack(spacing: 4) {
                    ForEach(Section.allCases, id: \.self) { item in
                        MarketPill(item.title, selected: tab == item) { tab = item }
                    }
                }
                if tab == .installed {
                    Text(AppCopy.text("settings.skillsHint")).font(.caption).foregroundStyle(.secondary)
                }
                if !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if tab == .catalog {
                    MarketFeatured(items: MarketItem.featured(in: catalogItems)) { detailEntryID = $0.id }
                    ForEach(MarketItem.sections(catalogItems), id: \.title) { section in
                        Text(section.title).font(.system(size: 16, weight: .medium)).padding(.top, 10)
                        LazyVGrid(columns: MarketRowLayout.columns, alignment: .leading, spacing: 20) {
                            ForEach(section.items) { catalogRow($0) }
                        }
                    }
                } else {
                    LazyVGrid(columns: MarketRowLayout.columns, alignment: .leading, spacing: 20) {
                        ForEach(skills.entries) { installedRow($0) }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(AppCopy.text("settings.tab.skills"))
    }

    private func item(_ entry: SkillMarketplaceEntry) -> MarketItem {
        let category = entry.category ?? "other"
        // No publisher in the manifest: fall back to the GitHub owner.
        let owner = entry.githubURL.flatMap(URL.init(string:))?.pathComponents.dropFirst().first
        return MarketItem(
            id: entry.id, symbol: MarketCategory.symbol(category, fallback: "cube"), title: entry.name, summary: entry.description,
            category: category, publisher: entry.publisher ?? owner ?? "", badge: entry.publisherBadge.flatMap(MarketBadge.init(rawValue:)),
            date: entry.snapshotDate, downloads: entry.downloads, likes: entry.likes, featured: entry.featured ?? false
        )
    }

    /// An installed skill borrows the listing metadata of its catalog entry when it has one.
    private func item(_ skill: SkillDescriptor) -> MarketItem {
        var listing = skills.marketplaceEntries.first { $0.id == skill.id }.map(item)
            ?? MarketItem(id: skill.id, symbol: "cube", title: skill.name, summary: skill.description, publisher: skill.source.rawValue)
        listing.title = skill.name
        listing.summary = skill.description
        return listing
    }

    private func catalogRow(_ item: MarketItem) -> some View {
        MarketRow(item: item, open: { detailEntryID = item.id }) {
            if let entry = skills.marketplaceEntries.first(where: { $0.id == item.id }) {
                if skills.isInstalled(entry) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .help(AppCopy.text("local.installed"))
                } else if entry.downloadURL != nil {
                    MarketIconButton("plus", help: AppCopy.text("common.download")) { install(entry) }
                }
            }
        }
    }

    private func installedRow(_ skill: SkillDescriptor) -> some View {
        MarketRow(item: item(skill), open: { detailSkillID = skill.id }) {
            enabledToggle(skill)
        }
    }

    private func enabledToggle(_ skill: SkillDescriptor) -> some View {
        Toggle(AppCopy.text("settings.enabled"), isOn: Binding(
            get: { skill.enabled },
            set: { skills.setEnabled(skill.id, $0) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func catalogDetail(_ entry: SkillMarketplaceEntry) -> some View {
        let listing = item(entry)
        return MarketDetail(item: listing, backTitle: AppCopy.text("settings.tab.skills"), back: { detailEntryID = nil },
                            related: listing.related(in: catalogItems), openRelated: { detailEntryID = $0.id }) {
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text(entry.description).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                if let revision = entry.revision { MarketField(AppCopy.text("skills.field.revision"), String(revision.prefix(12))) }
                MarketField(AppCopy.text("skills.field.catalog"), AppCopy.format("settings.skillsSnapshot", entry.snapshotDate))
            }
            skillLinks(github: entry.githubURL, skill: entry.skillURL)
        } actions: {
            likeButton(entry)
            if skills.isInstalled(entry) {
                Text(AppCopy.text("local.installed")).font(.caption).foregroundStyle(.secondary)
            } else if entry.downloadURL != nil {
                Button(AppCopy.text("common.download")) { install(entry) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func installedDetail(_ skill: SkillDescriptor) -> some View {
        MarketDetail(item: item(skill), backTitle: AppCopy.text("settings.tab.skills"), back: { detailSkillID = nil }) {
            Text(skill.description).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                MarketField(AppCopy.text("market.field.source"), skill.source.rawValue)
                MarketField(AppCopy.text("skills.field.location"), skill.path)

            }
            skillLinks(github: skill.githubURL, skill: skill.skillURL)
            VStack(alignment: .leading, spacing: 6) {
                Text("SKILL.md").font(.headline)
                Text((try? skills.read(id: skill.id, includeDisabled: true)) ?? AppCopy.text("settings.skillReadFailed"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } actions: {
            enabledToggle(skill)
            if skill.isInstalled {
                Button(AppCopy.text("common.delete"), role: .destructive) {
                    detailSkillID = nil
                    do { try skills.remove(skill.id) }
                    catch let caughtError { error = caughtError.localizedDescription }
                }
            }
        }
    }

    @ViewBuilder
    private func skillLinks(github: String?, skill: String?) -> some View {
        HStack(spacing: 14) {
            if let github, let url = URL(string: github) { Link("GitHub", destination: url) }
            if let skill, let url = URL(string: skill) { Link("SKILL.md", destination: url) }
        }
    }

    private func install(_ entry: SkillMarketplaceEntry) {
        error = ""
        Task {
            do {
                try await skills.install(entry)
                skills.setMetrics(id: entry.id, downloads: await market.recordCatalogDownload(kind: "skill", id: entry.id))
            }
            catch { self.error = error.localizedDescription }
        }
    }
}
