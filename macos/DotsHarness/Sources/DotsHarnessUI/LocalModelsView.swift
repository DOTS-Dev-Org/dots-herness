// Copyright (c) 2026 DOTS
// Native custom API + local LRM install/serve.

import SwiftUI
import AppKit
import DotsHarnessCore

struct CustomAPIView: View {
    @ObservedObject var router: RouterController
    @ObservedObject var local: LocalRuntimeController

    var body: some View {
        Form {
            Section(AppCopy.text("custom.addEndpoint")) {
                Text(AppCopy.text("custom.endpointHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(AppCopy.text("custom.name"), text: $router.customName)
                TextField(AppCopy.text("custom.prefix"), text: $router.customPrefix)
                TextField(AppCopy.text("custom.baseURL"), text: $router.customBaseURL)
                SecureField(AppCopy.text("custom.apiKeyOptional"), text: $router.customAPIKey)
                TextField(AppCopy.text("custom.modelOptional"), text: $router.customModel)
                TextField(AppCopy.text("custom.contextOptional"), text: $router.customContextWindow)
                Text(AppCopy.text("custom.contextHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(AppCopy.text("custom.api"), selection: $router.customKind) {
                    ForEach(CustomAPIKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                if router.customKind == .openai {
                    Picker(AppCopy.text("custom.openAIStyle"), selection: $router.customAPIType) {
                        Text(AppCopy.text("custom.chatCompletions")).tag(CustomOpenAIAPIType.chat)
                    }
                }
                Button(router.editingNodeID == nil ? AppCopy.text("custom.addAPI") : AppCopy.text("common.save")) {
                    Task { await router.createCustomNode(registerKey: router.editingNodeID == nil) }
                }
                .disabled(!router.reachable)
                if router.editingNodeID != nil {
                    Button(AppCopy.text("conversation.cancelEdit")) { router.cancelEditNode() }
                }
            }
            if !router.detectedServers.isEmpty {
                Section(AppCopy.text("custom.detected")) {
                    ForEach(router.detectedServers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(.headline)
                                Text(server.baseURL)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(AppCopy.text("common.connect")) { Task { await router.connect(server) } }
                        }
                    }
                }
            }
            Section(AppCopy.text("custom.providers")) {
                if router.nodes.isEmpty {
                    Text(AppCopy.text("custom.noneYet"))
                        .foregroundStyle(.secondary)
                }
                ForEach(router.nodes) { node in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.name).font(.headline)
                        Text("\(node.prefix) · \(node.type) · \(node.baseURL)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(AppCopy.text("common.connect")) { Task { await router.connectExistingNode(node) } }
                            Button(AppCopy.text("common.test")) { Task { await router.testNode(node) } }
                            Button(AppCopy.text("conversation.edit")) { router.beginEditNode(node) }
                            Button(AppCopy.text("common.delete"), role: .destructive) { Task { await router.deleteNode(node) } }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let error = router.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AppCopy.text("settings.tab.custom"))
        .task {
            await router.refresh()
            await router.detectLocalServers()
        }
    }
}

/// Local models as a marketplace: curated picks, category shelves and a live
/// Hugging Face listing, with runtime tuning tucked into a sheet.
struct LocalModelsView: View {
    @ObservedObject var local: LocalRuntimeController
    @State private var importing = false
    @State private var showSettings = false
    @State private var query = ""
    @State private var category: String?
    @State private var detail: Detail?
    @State private var hub: [HubModel] = []
    @State private var hubLoading = false
    @State private var hubError: String?

    private enum Detail: Hashable {
        case spec(String)
        case hub(HubModel, category: String)
    }

    private var shelf: LocalModelCategory? { LocalModelCategory.named(category) }

    private func matches(_ spec: LocalModelSpec) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return (category == nil || spec.category == category)
            && terms.allSatisfy { term in [spec.name, spec.family, spec.sizeLabel].contains { $0.localizedStandardContains(term) } }
    }

    private var curated: [LocalModelSpec] {
        (local.models + (local.mlxSupported ? LocalModelCatalog.mlxModels : []) + LocalDiffusion.presets).filter(matches)
    }

    var body: some View {
        Group {
            switch detail {
            case .spec(let id)?:
                if let spec = local.allModels.first(where: { $0.id == id }) { specDetail(spec) } else { catalog }
            case .hub(let model, let category)?:
                LocalHubDetail(local: local, model: model, category: category,
                               related: hub.filter { $0.id != model.id }.prefix(4).map { hubItem($0) }) { detail = nil }
                    openRelated: { item in
                        if let other = hub.first(where: { $0.id == item.id }) { detail = .hub(other, category: category) }
                    }
            case nil:
                catalog
            }
        }
        .navigationTitle(AppCopy.text("settings.tab.local"))
        .task {
            local.refreshInstalled()
            await local.refreshDevices()
        }
        .task(id: "\(category ?? "")|\(query)") { await loadHub() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { local.importModel(at: url) }
        }
        .sheet(isPresented: $showSettings) { LocalRuntimeSettingsSheet(local: local) }
    }

    private func loadHub() async {
        // Typing restarts the task; the pause keeps one request per word, not per key.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        hubLoading = true
        defer { hubLoading = false }
        do {
            let found = try await HuggingFaceHub.search(shelf, query: query)
            guard !Task.isCancelled else { return }
            hub = found
            hubError = nil
        } catch {
            if !Task.isCancelled { hubError = error.localizedDescription }
        }
    }

    // MARK: Catalog

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MarketFeatured(items: MarketItem.featured(in: curated.map(item))) { detail = .spec($0.id) }

                Text(AppCopy.text("settings.tab.local")).font(.system(size: 24, weight: .semibold))
                toolbar
                runtimeStrip

                if let error = local.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        MarketPill(AppCopy.text("library.all"), selected: category == nil) { category = nil }
                        ForEach(LocalModelCategory.all) { shelf in
                            MarketPill(MarketCategory.title(shelf.id), selected: category == shelf.id) { category = shelf.id }
                        }
                    }
                }

                let picks = curated
                if !picks.isEmpty {
                    sectionTitle(AppCopy.text("local.recommended"))
                    grid(picks.map(item)) { listing in
                        if let spec = picks.first(where: { $0.id == listing.id }) {
                            MarketRow(item: listing, open: { detail = .spec(spec.id) }) { LocalModelAction(local: local, spec: spec) }
                        }
                    }
                }

                let downloaded = local.settings.hubModels.filter(matches)
                if !downloaded.isEmpty {
                    sectionTitle(AppCopy.text("local.downloaded"))
                    grid(downloaded.map(item)) { listing in
                        if let spec = downloaded.first(where: { $0.id == listing.id }) {
                            MarketRow(item: listing, open: { detail = .spec(spec.id) }) { LocalModelAction(local: local, spec: spec) }
                        }
                    }
                }

                hubSection
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(AppCopy.text("local.search"), text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(Capsule().stroke(Color.primary.opacity(0.18)))

            Text(local.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)

            MarketIconButton("slider.horizontal.3", help: AppCopy.text("local.settings")) { showSettings = true }
                .foregroundStyle(.secondary)

            Button { importing = true } label: {
                Label(AppCopy.text("local.importGGUF"), systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    /// What this Mac can run and which servers are ready, one glance.
    private var runtimeStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                Label(local.hardwareSummary, systemImage: "memorychip").textSelection(.enabled)
                engineStatus("llama.cpp \(LocalRuntime.llamaTag)", ready: local.runtimeReady)
                if local.mlxSupported { engineStatus("MLX \(LocalRuntime.mlxVersion)", ready: local.mlxReady) }
                engineStatus("stable-diffusion.cpp", ready: local.diffusionReady)
                if local.serving, let id = local.runningModelID {
                    Label(local.servedContext.map { AppCopy.format("local.servingContext", id, $0) } ?? id, systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !local.runtimeReady {
                    Button(AppCopy.text("local.installRuntime")) { Task { await local.installRuntime() } }
                }
                if local.mlxSupported, !local.mlxReady {
                    Button(AppCopy.text("local.installMLX")) { Task { await local.installRuntime(.mlx) } }
                }
                if !local.diffusionReady {
                    Button(AppCopy.text("local.installDiffusion")) { Task { await local.installRuntime(.diffusion) } }
                }
                if local.serving { Button(AppCopy.text("local.stopServer"), action: local.stop) }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            ForEach(["runtime", "mlx", "diffusion"], id: \.self) { key in
                if let fraction = local.downloads[key], fraction < 1 { ProgressView(value: fraction) }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func engineStatus(_ name: String, ready: Bool) -> some View {
        Label(name, systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
            .symbolRenderingMode(.multicolor)
            .help(AppCopy.text(ready ? "local.installed" : "local.notInstalled"))
    }

    private var hubSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(AppCopy.text("local.hub.title"))
                if hubLoading { ProgressView().controlSize(.small) }
                Spacer()
                Link(AppCopy.text("local.hub.viewAll"), destination: HuggingFaceHub.webURL(shelf, query: query))
                    .font(.system(size: 12, weight: .medium))
            }
            if let hubError {
                Text(hubError).font(.caption).foregroundStyle(.red)
            } else if hub.isEmpty, !hubLoading {
                Text(AppCopy.text("local.hub.empty")).font(.callout).foregroundStyle(.secondary)
            }
            grid(hub.map(hubItem)) { listing in
                if let model = hub.first(where: { $0.id == listing.id }) {
                    MarketRow(item: listing, open: { detail = .hub(model, category: listing.category) }) { EmptyView() }
                }
            }
            Text(AppCopy.text("local.hub.attribution")).font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 16, weight: .medium)).padding(.top, 10)
    }

    private func grid<Row: View>(_ items: [MarketItem], @ViewBuilder row: @escaping (MarketItem) -> Row) -> some View {
        LazyVGrid(columns: MarketRowLayout.columns, alignment: .leading, spacing: 20) {
            ForEach(items) { row($0) }
        }
    }

    private func item(_ spec: LocalModelSpec) -> MarketItem {
        MarketItem(
            id: spec.id, symbol: MarketCategory.symbol(spec.category, fallback: "cpu"), title: spec.name,
            summary: spec.engine == .mlx ? "MLX · \(spec.sizeLabel)" : spec.sizeLabel,
            category: spec.category, publisher: spec.family,
            // Featured: what this Mac runs comfortably.
            featured: spec.localPath == nil && spec.minMemoryGB > 0 && local.fits(spec)
        )
    }

    private func hubItem(_ model: HubModel) -> MarketItem {
        let category = shelf?.id ?? model.category
        return MarketItem(
            id: model.id, symbol: MarketCategory.symbol(category, fallback: "cpu"), title: model.name,
            summary: model.id, category: category, publisher: model.author,
            date: model.createdAt, downloads: model.downloads, likes: model.likes
        )
    }

    // MARK: Curated detail

    private func specDetail(_ spec: LocalModelSpec) -> some View {
        let listing = item(spec)
        let installed = local.installed.contains(spec.id)
        return MarketDetail(item: listing, backTitle: AppCopy.text("settings.tab.local"), back: { detail = nil },
                            related: listing.related(in: curated.map(item)), openRelated: { detail = .spec($0.id) }) {
            if !spec.notes.isEmpty, spec.localPath == nil, spec.repo == nil || spec.engine == .mlx {
                Text(spec.notes).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TagBadge(spec.engine == .mlx ? "MLX" : spec.engine == .diffusion ? "stable-diffusion.cpp"
                         : (spec.runnable ? "llama.cpp" : AppCopy.text("local.hub.fileOnly")))
                if spec.reasoning { TagBadge(AppCopy.text("local.lrm"), background: AnyShapeStyle(Color.orange.opacity(0.18))) }
                if spec.minMemoryGB > 0, !local.fits(spec) {
                    TagBadge(AppCopy.text("local.tooLarge"), background: AnyShapeStyle(Color.red.opacity(0.18)))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                MarketField(AppCopy.text("local.size"), spec.sizeLabel)
                if spec.runnable { MarketField(AppCopy.text("local.context"), spec.context.formatted()) }
                if spec.minMemoryGB > 0 { MarketField(AppCopy.text("local.memory"), "\(spec.minMemoryGB) GB") }
                if installed {
                    MarketField(AppCopy.text("local.disk"), LocalModelCatalog.prettyBytes(local.runtime.installedBytes(spec)))
                }
            }
            if let fraction = local.downloads[spec.id], fraction < 1, !installed { ProgressView(value: fraction) }
            if !spec.runnable, installed {
                Text(AppCopy.text("local.hub.downloadOnly")).font(.callout).foregroundStyle(.secondary)
            }
            if spec.engine == .diffusion {
                Text(AppCopy.text(spec.category == "video" ? "local.videoHint" : "local.imageHint"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let parts = spec.components, parts.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppCopy.text("local.hub.files")).font(.headline)
                    ForEach(parts) { part in
                        Label("\(URL(fileURLWithPath: part.filename).lastPathComponent) · \(part.sizeLabel)",
                              systemImage: local.runtime.isInstalled(part) ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 14) {
                if let url = spec.hubURL { Link(AppCopy.text("local.hub.open"), destination: url) }
                if installed {
                    Button(AppCopy.text("local.reveal")) { LocalModelAction.reveal(local, spec) }.buttonStyle(.link)
                    Button(AppCopy.text(spec.localPath == nil ? "common.delete" : "local.forget"), role: .destructive) {
                        local.delete(spec)
                        if spec.id.hasPrefix("hf:") || spec.localPath != nil { detail = nil }
                    }
                    .buttonStyle(.link)
                }
            }
        } actions: {
            LocalModelAction(local: local, spec: spec, prominent: true)
        }
    }
}

/// Download, start, stop or reveal: whatever the model's state calls for.
struct LocalModelAction: View {
    @ObservedObject var local: LocalRuntimeController
    let spec: LocalModelSpec
    var prominent = false

    static func reveal(_ local: LocalRuntimeController, _ spec: LocalModelSpec) {
        NSWorkspace.shared.activateFileViewerSelecting([local.runtime.modelURL(spec)])
    }

    var body: some View {
        let installed = local.installed.contains(spec.id)
        if let fraction = local.downloads[spec.id], fraction < 1, !installed {
            ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small).frame(width: 28, height: 28)
        } else if local.runningModelID == spec.id || local.diffusionModelID == spec.id {
            button("stop.circle", "common.stop") { spec.engine == .diffusion ? local.stopDiffusion() : local.stop() }
        } else if installed {
            if spec.runnable {
                button("play.circle", "common.start") { Task { await local.start(spec) } }
            } else {
                button("folder", "local.reveal") { Self.reveal(local, spec) }
            }
        } else {
            button("arrow.down.circle", "common.download") { Task { await local.download(spec) } }
        }
    }

    @ViewBuilder
    private func button(_ symbol: String, _ key: String, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(AppCopy.text(key), action: action).buttonStyle(.borderedProminent)
        } else {
            MarketIconButton(symbol, help: AppCopy.text(key), action: action)
        }
    }
}

/// One Hugging Face repository: its page, its weight files (pick any) or the whole repo.
private struct LocalHubDetail: View {
    @ObservedObject var local: LocalRuntimeController
    let model: HubModel
    let category: String
    let related: [MarketItem]
    let back: () -> Void
    let openRelated: (MarketItem) -> Void
    @State private var files: [HubFile]?
    @State private var error: String?

    init(local: LocalRuntimeController, model: HubModel, category: String, related: [MarketItem],
         back: @escaping () -> Void, openRelated: @escaping (MarketItem) -> Void) {
        self.local = local
        self.model = model
        self.category = category
        self.related = related
        self.back = back
        self.openRelated = openRelated
    }

    private var runnable: Bool { LocalModelCategory.named(category)?.runnable ?? true }

    var body: some View {
        let listing = MarketItem(
            id: model.id, symbol: MarketCategory.symbol(category, fallback: "cpu"), title: model.name, summary: model.id,
            category: category, publisher: model.author, date: model.createdAt, downloads: model.downloads, likes: model.likes
        )
        MarketDetail(item: listing, backTitle: AppCopy.text("settings.tab.local"), back: back,
                     related: related, openRelated: openRelated) {
            Link(AppCopy.text("local.hub.open"), destination: model.pageURL)
            if let tags = model.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(tags.prefix(8), id: \.self) { TagBadge($0) } }
                }
            }
            if !runnable { Text(AppCopy.text("local.hub.downloadOnly")).font(.callout).foregroundStyle(.secondary) }
            Text(AppCopy.text("local.hub.files")).font(.headline)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let files {
                let weights = HuggingFaceHub.weights(files)
                if weights.isEmpty { Text(AppCopy.text("local.hub.empty")).foregroundStyle(.secondary) }
                ForEach(weights) { file in
                    let spec = HuggingFaceHub.spec(repo: model.id, file: file, category: category)
                    HStack(spacing: 10) {
                        Image(systemName: spec.runnable ? "cpu" : "doc").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Text(LocalModelCatalog.prettyBytes(file.size)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if local.installed.contains(spec.id) {
                            MarketIconButton("trash", help: AppCopy.text("common.delete")) { local.delete(spec) }
                        }
                        LocalModelAction(local: local, spec: spec)
                    }
                }
                if !runnable {
                    let repo = HuggingFaceHub.spec(repo: model.id, file: nil, category: category,
                                                   total: files.reduce(0) { $0 + $1.size })
                    HStack {
                        Text(AppCopy.format("local.hub.downloadRepo", repo.sizeLabel)).font(.system(size: 13, weight: .medium))
                        Spacer()
                        LocalModelAction(local: local, spec: repo)
                    }
                    .padding(.top, 6)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } actions: {
            Link(destination: model.pageURL) { Image(systemName: "arrow.up.right.square").font(.system(size: 15)) }
                .help(AppCopy.text("local.hub.open"))
        }
        .task(id: model.id) {
            do { files = try await HuggingFaceHub.tree(model.id) } catch { self.error = error.localizedDescription }
        }
    }
}

/// Runtime installs and llama.cpp / MLX tuning, out of the catalog's way.
private struct LocalRuntimeSettingsSheet: View {
    @ObservedObject var local: LocalRuntimeController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(AppCopy.text("local.runtime")) {
                    LabeledContent(AppCopy.text("local.hardware")) { Text(local.hardwareSummary).textSelection(.enabled) }
                    LabeledContent(AppCopy.text("local.listen")) { Text(local.runtime.serverURL.absoluteString).textSelection(.enabled) }
                }
                Section(AppCopy.text("local.tuning")) {
                    Text(AppCopy.text("local.tuningHint")).font(.caption).foregroundStyle(.secondary)
                    numberField("local.contextSize", value: $local.settings.contextSize)
                    TextField(AppCopy.text("local.gpuLayers"), text: $local.settings.gpuLayers)
                    numberField("local.threads", value: $local.settings.threads)
                    numberField("local.batchSize", value: $local.settings.batchSize)
                    Picker(AppCopy.text("local.flashAttention"), selection: $local.settings.flashAttention) {
                        ForEach(["auto", "on", "off"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker(AppCopy.text("local.kvCache"), selection: $local.settings.kvCacheType) {
                        Text("f16").tag("")
                        ForEach(["q8_0", "q5_1", "q4_0"], id: \.self) { Text($0).tag($0) }
                    }
                    TextField(AppCopy.text("local.extraArgs"), text: $local.settings.extraArgs)
                    if local.mlxSupported {
                        TextField(AppCopy.text("local.mlxExtraArgs"), text: $local.settings.mlxExtraArgs)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(AppCopy.text("common.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    /// Zero means automatic, so the field is shown empty rather than as "0".
    private func numberField(_ key: String, value: Binding<Int>) -> some View {
        TextField(AppCopy.text(key), text: Binding(
            get: { value.wrappedValue > 0 ? String(value.wrappedValue) : "" },
            set: { value.wrappedValue = max(0, Int($0.trimmingCharacters(in: .whitespaces)) ?? 0) }
        ))
    }
}
