// Copyright (c) 2026 DOTS
// Native custom API + local LRM install/serve.

import SwiftUI
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

struct LocalModelsView: View {
    @ObservedObject var local: LocalRuntimeController
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = local.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal)
            }
            List {
                Section(AppCopy.text("local.runtime")) {
                    LabeledContent(AppCopy.text("local.hardware")) {
                        Text(local.hardwareSummary).textSelection(.enabled)
                    }
                    LabeledContent("llama.cpp \(LocalRuntime.llamaTag) · Metal") {
                        Text(local.runtimeReady ? AppCopy.text("local.installed") : AppCopy.text("local.notInstalled"))
                    }
                    if local.mlxSupported {
                        LabeledContent("MLX \(LocalRuntime.mlxVersion)") {
                            Text(local.mlxReady ? AppCopy.text("local.installed") : AppCopy.text("local.notInstalled"))
                        }
                    }
                    LabeledContent(AppCopy.text("local.listen")) {
                        Text(local.runtime.serverURL.absoluteString).textSelection(.enabled)
                    }
                    if local.serving, let id = local.runningModelID {
                        LabeledContent(AppCopy.text("local.serving")) {
                            Text(local.servedContext.map { AppCopy.format("local.servingContext", id, $0) } ?? id)
                        }
                    }
                    HStack {
                        if !local.runtimeReady {
                            Button(AppCopy.text("local.installRuntime")) { Task { await local.installRuntime() } }
                        }
                        if local.mlxSupported, !local.mlxReady {
                            Button(AppCopy.text("local.installMLX")) { Task { await local.installRuntime(.mlx) } }
                        }
                        if local.serving {
                            Button(AppCopy.text("local.stopServer"), action: local.stop)
                        }
                    }
                    ForEach(["runtime", "mlx"], id: \.self) { key in
                        if let fraction = local.downloads[key], fraction < 1 {
                            ProgressView(value: fraction)
                        }
                    }
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
                Section(AppCopy.text("local.downloadRun")) {
                    ForEach(local.models) { spec in
                        modelRow(spec)
                    }
                    Button(AppCopy.text("local.importGGUF")) { importing = true }
                }
                if local.mlxSupported {
                    Section("MLX") {
                        ForEach(LocalModelCatalog.mlxModels) { spec in
                            modelRow(spec)
                        }
                    }
                }
            }
        }
        .navigationTitle(AppCopy.text("settings.tab.local"))
        .task {
            local.refreshInstalled()
            await local.refreshDevices()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { local.importModel(at: url) }
        }
    }

    /// Zero means automatic, so the field is shown empty rather than as "0".
    private func numberField(_ key: String, value: Binding<Int>) -> some View {
        TextField(AppCopy.text(key), text: Binding(
            get: { value.wrappedValue > 0 ? String(value.wrappedValue) : "" },
            set: { value.wrappedValue = max(0, Int($0.trimmingCharacters(in: .whitespaces)) ?? 0) }
        ))
    }

    private var header: some View {
        HStack {
            Text(AppCopy.text("settings.tab.local")).font(.title2.weight(.semibold))
            Spacer()
            Text(local.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func modelRow(_ spec: LocalModelSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(spec.name).font(.headline)
                        if spec.reasoning { badge(AppCopy.text("local.lrm"), .orange) }
                        if spec.minMemoryGB > 0, !local.fits(spec) { badge(AppCopy.text("local.tooLarge"), .red) }
                    }
                    Text("\(spec.family) · \(spec.sizeLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if local.runningModelID == spec.id {
                    Button(AppCopy.text("common.stop"), action: local.stop)
                } else if local.installed.contains(spec.id) {
                    Button(AppCopy.text("common.start")) { Task { await local.start(spec) } }
                } else {
                    Button(AppCopy.text("common.download")) { Task { await local.download(spec) } }
                }
            }
            Text(spec.notes).font(.caption).foregroundStyle(.secondary)
            if let fraction = local.downloads[spec.id], fraction < 1, !local.installed.contains(spec.id) {
                ProgressView(value: fraction)
            }
            if local.installed.contains(spec.id) {
                HStack {
                    Text(AppCopy.format("local.onDisk", LocalModelCatalog.prettyBytes(local.runtime.installedBytes(spec))))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(AppCopy.text(spec.localPath == nil ? "common.delete" : "local.forget"), role: .destructive) { local.delete(spec) }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
