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

    public init(model: AppModel) {
        self.model = model
        self.market = model.marketplace
        _session = ObservedObject(wrappedValue: model.marketplaceSession)
        _publisher = StateObject(wrappedValue: MarketplacePublisher(session: model.marketplaceSession))
    }

    private var filtered: [MarketplaceEntry] {
        let source = selectedArea == "core" ? market.entries : market.communityEntries
        guard !query.isEmpty else { return source }
        let q = query.lowercased()
        return source.filter {
            $0.name.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppCopy.text("marketplace.title")).font(.title2.weight(.semibold))
                Spacer()
                if session.isSignedIn {
                    Text(session.profile?.email ?? "HerNess hesabı")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Plugin yayınla") { showPublish = true }
                Button("Çıkış") { signOutMarketplace() }
                } else {
                    Menu("Giriş yap") {
                        ForEach(MarketplaceProvider.allCases) { provider in
                            Button(provider.title) { session.beginOAuth(provider) }
                        }
                        Divider()
                        Button("Email ve şifre") { showEmailSignIn = true }
                    }
                }
                if market.isLoading { ProgressView().controlSize(.small) }
                Button(AppCopy.text("common.refresh")) { Task { await market.refresh() } }
                    .disabled(market.isLoading)
            }
            .padding()

            TextField(AppCopy.text("marketplace.search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Picker("Marketplace alanı", selection: $selectedArea) {
                Text("Ana Marketplace").tag("core")
                Text("Community / Experimental").tag("community")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            Text(selectedArea == "core"
                 ? "DOTS Harness iş akışına doğrudan katkı veren, incelenmiş pluginler."
                 : "Ana keşif alanından ayrı, AI tarafından topluluk veya deneysel olarak sınıflandırılmış pluginler.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 4)

            if !market.forks.forks.isEmpty {
                localForks
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            if session.isSignedIn && !market.ownedPlugins.isEmpty {
                ownedPlugins
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            if let error = market.lastError ?? actionError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal).padding(.top, 4)
            }

            if filtered.isEmpty {
                ContentUnavailableView(
                    selectedArea == "core" ? AppCopy.text("marketplace.empty") : "Community alanında henüz plugin yok",
                    systemImage: "shippingbox",
                    description: Text(selectedArea == "core"
                                      ? AppCopy.text("marketplace.emptyHint")
                                      : "Community pluginleri ayrı inceleme ve açık native-code onayı gerektirir.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    row(entry).padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task {
            if market.entries.isEmpty && market.communityEntries.isEmpty { await market.refresh() }
            await market.refreshOwnedPlugins()
        }
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn {
                model.syncAccountFromMarketplace()
                Task { await market.refreshOwnedPlugins() }
            } else {
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
            "Bu plugin native kod çalıştırır",
            isPresented: Binding(
                get: { pendingConsent != nil },
                set: { if !$0 { pendingConsent = nil } }
            ),
            presenting: pendingConsent
        ) { entry in
            Button("Kabul et ve etkinleştir", role: .destructive) {
                pendingConsent = nil
                installAccepted(entry)
            }
            Button("İptal", role: .cancel) { pendingConsent = nil }
        } message: { entry in
            let area = entry.catalogScope == "core"
                ? "ana Marketplace"
                : (entry.catalogScope == "experimental" ? "Experimental alanı" : "Community alanı")
            let review = entry.verificationStatus == "verified" ? "DOTS incelemesinden geçmiş" : "inceleme bekleyen"
            Text("\(entry.name), \(area) içindeki \(review) üçüncü taraf native pluginidir. Kategori: \(categoryTitle(entry.category)). İzinleri ve kaynak kodunu inceleyin. Kabul ederseniz plugin trusted olarak hemen çalıştırılır.")
        }
        .confirmationDialog(
            "Özelleştirilmiş plugin native kod çalıştırır",
            isPresented: Binding(
                get: { pendingForkConsent != nil },
                set: { if !$0 { pendingForkConsent = nil } }
            ),
            presenting: pendingForkConsent
        ) { fork in
            Button("Kabul et ve etkinleştir", role: .destructive) {
                pendingForkConsent = nil
                market.forks.acceptAndEnable(fork)
                model.remount()
            }
            Button("İptal", role: .cancel) { pendingForkConsent = nil }
        } message: { fork in
            Text("\(fork.id) yerel fork'tur. Kaynak upstream'den bağımsızdır; değişiklikleri inceledikten sonra etkinleştirin.")
        }
    }

    @ViewBuilder
    private func row(_ entry: MarketplaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).font(.headline)
                Text("v\(entry.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                action(entry)
            }
            Text(entry.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TagBadge(entry.tier, background: AnyShapeStyle(.quaternary))
                TagBadge(scopeTitle(entry.catalogScope), background: AnyShapeStyle(.quaternary))
                TagBadge(categoryTitle(entry.category), background: AnyShapeStyle(.quaternary))
                TagBadge(entry.verificationStatus == "verified" ? "DOTS reviewed" : "inceleme bekliyor", background: AnyShapeStyle(.quaternary))
                if entry.riskLevel != "low" && entry.riskLevel != "unknown" {
                    TagBadge("risk: \(entry.riskLevel)", background: AnyShapeStyle(.quaternary))
                }
                if entry.signature != nil || entry.currentArtifact?.signature != nil {
                    TagBadge("signed", background: AnyShapeStyle(.quaternary))
                }
                if market.forks.hasFork(for: entry.id) {
                    TagBadge("Özelleştirildi", background: AnyShapeStyle(.quaternary))
                }
                if !entry.author.isEmpty {
                    Text(AppCopy.format("marketplace.by", entry.author)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !entry.description.isEmpty {
                Text(entry.description).font(.caption)
            }
            HStack(spacing: 8) {
                if !entry.permissions.isEmpty {
                    Text("İzinler: \(entry.permissions.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if session.isSignedIn {
                    Button("Raporla") { pendingReport = entry }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
            }
        }
    }

    private func categoryTitle(_ category: String) -> String {
        switch category {
        case "coding": return "Coding"
        case "git": return "Git"
        case "devops": return "DevOps"
        case "qa": return "QA"
        case "browser": return "Browser"
        case "workspace": return "Workspace"
        case "models": return "Models"
        case "integrations": return "Integrations"
        case "productivity": return "Productivity"
        case "community": return "Community"
        default: return "Other"
        }
    }

    private func scopeTitle(_ scope: String) -> String {
        switch scope {
        case "core": return "Ana"
        case "experimental": return "Experimental"
        default: return "Community"
        }
    }

    @ViewBuilder
    private func action(_ entry: MarketplaceEntry) -> some View {
        if market.busyIDs.contains(entry.id) {
            ProgressView().controlSize(.small)
        } else {
            switch market.status(entry) {
            case .notInstalled:
                Button(AppCopy.text("marketplace.install")) { pendingConsent = entry }
            case .updateAvailable(let installed):
                Button(AppCopy.format("marketplace.update", installed, entry.version)) { pendingConsent = entry }
            case .upToDate:
                HStack(spacing: 6) {
                    Text(AppCopy.text("local.installed")).font(.caption).foregroundStyle(.secondary)
                    if !market.forks.hasFork(for: entry.id) {
                        Button("Özelleştir") { createFork(entry) }
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
    }

    private var localForks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Yerel özelleştirmeler").font(.headline)
            ForEach(market.forks.forks) { fork in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fork.id).font(.caption.monospaced())
                        Text("upstream \(fork.upstreamID) · v\(fork.upstreamVersion)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let available = fork.upstreamVersionAvailable {
                            Text("Yeni upstream: v\(available); yerel değişiklikler korunuyor")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Klasörü aç") { NSWorkspace.shared.open(market.forks.folder(for: fork)) }
                    Button("Dışa aktar") { exportFork(fork) }
                    Button("Sil", role: .destructive) { deleteFork(fork) }
                    if fork.upstreamVersionAvailable != nil {
                        Button("Karşılaştırıldı") { market.forks.acknowledgeUpstream(fork, version: fork.upstreamVersionAvailable!) }
                    }
                    Button("Kabul et") { pendingForkConsent = fork }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var ownedPlugins: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Yayınlarım").font(.headline)
            ForEach(market.ownedPlugins) { plugin in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(plugin.name).font(.subheadline.weight(.semibold))
                        Text(plugin.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text(plugin.sourceVisibility == "private" ? "private source" : "public source")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("Yayından kaldır", role: .destructive) {
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
            actionError = "Özelleştirilmiş fork oluşturuldu: \(fork.id). Kaynak upstream'den bağımsızdır."
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
            actionError = "Fork dışa aktarıldı."
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
                Text("HerNess hesabıyla giriş").font(.title2.weight(.semibold))
                Spacer()
                Button("Kapat") { dismiss() }
            }
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
            SecureField("Şifre", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Giriş yap") { submit() }
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
                Text("Native plugin yayınla").font(.title2.weight(.semibold))
                Spacer()
                Button("Kapat") { dismiss() }
            }
            Text("Plugin klasöründe plugin.yml, plugin.ir.json ve license bulunmalı. JavaScript ve declarative runtime kabul edilmez; platform buildleri CI'da oluşturulur.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(folder?.path ?? "Plugin klasörü seçilmedi")
                    .font(.caption.monospaced())
                    .lineLimit(2)
                Spacer()
                Button("Klasör seç") { chooseFolder() }
            }
            if let irPreview {
                DisclosureGroup("plugin.ir.json önizleme") {
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
                DisclosureGroup("Native kaynak önizleme") {
                    ScrollView {
                        Text(nativeSourcePreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            TextField("Sürüm (SemVer)", text: $version)
                .textFieldStyle(.roundedBorder)
            TextField("SPDX lisansı (ör. MIT)", text: $license)
                .textFieldStyle(.roundedBorder)
            Picker("Kaynak görünürlüğü", selection: $sourceVisibility) {
                Text("Public — kaynak paketi listelenir").tag("public")
                Text("Private — yalnızca sahibi ve CI erişir").tag("private")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Platform hedefleri").font(.caption.weight(.semibold))
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
                Text("Yayın sonrası AI kategori, alan ve risk sınıflandırması yapar. Plugin build tamamlandıktan sonra da insan incelemesi bitene kadar listelenmez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Yayınla") { publish() }
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
        ("malware", "Malware veya zararlı davranış"),
        ("credential_theft", "Kimlik bilgisi / credential hırsızlığı"),
        ("data_exfiltration", "Veri dışarı aktarma"),
        ("deceptive_listing", "Yanıltıcı listeleme / impersonation"),
        ("spam", "Spam veya boş wrapper"),
        ("copyright", "Telif / lisans ihlali"),
        ("other", "Diğer"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plugin'i raporla").font(.title2.weight(.semibold))
                Spacer()
                Button("Kapat") { dismiss() }
            }
            Text("\(entry.name) · v\(entry.version)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Picker("Neden", selection: $reason) {
                ForEach(Self.reasons, id: \.0) { value, label in
                    Text(label).tag(value)
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
                Button("Raporu gönder") { submit() }
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
