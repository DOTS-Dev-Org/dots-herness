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
                Button(router.editingNodeID == nil ? AppCopy.text("custom.addAPI") : "Save changes") {
                    Task { await router.createCustomNode(registerKey: router.editingNodeID == nil) }
                }
                .disabled(!router.reachable)
                if router.editingNodeID != nil {
                    Button("Cancel edit") { router.cancelEditNode() }
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
                            Button("Edit") { router.beginEditNode(node) }
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
        .task { await router.refresh() }
    }
}

struct LocalModelsView: View {
    @ObservedObject var local: LocalRuntimeController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = local.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            List {
                Section(AppCopy.text("local.runtime")) {
                    LabeledContent("llama-server") {
                        Text(local.runtimeReady ? AppCopy.text("local.installed") : AppCopy.text("local.notInstalled"))
                    }
                    LabeledContent(AppCopy.text("local.listen")) {
                        Text(local.runtime.serverURL.absoluteString).textSelection(.enabled)
                    }
                    if local.serving, let id = local.runningModelID {
                        LabeledContent(AppCopy.text("local.serving")) { Text(id) }
                    }
                    HStack {
                        Button(local.runtimeReady ? AppCopy.text("local.reinstallRuntime") : AppCopy.text("local.installRuntime")) {
                            Task { await local.installRuntime() }
                        }
                        if local.serving {
                            Button(AppCopy.text("local.stopServer"), action: local.stop)
                        }
                    }
                    if let fraction = local.downloads["runtime"], fraction < 1 {
                        ProgressView(value: fraction)
                    }
                }
                Section(AppCopy.text("local.downloadRun")) {
                    ForEach(LocalModelCatalog.models) { spec in
                        modelRow(spec)
                    }
                }
            }
        }
        .navigationTitle(AppCopy.text("settings.tab.local"))
        .onAppear { local.refreshInstalled() }
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

    private func modelRow(_ spec: LocalModelSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(spec.name).font(.headline)
                        if spec.reasoning {
                            Text(AppCopy.text("local.lrm"))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                        }
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
                    Button(AppCopy.text("common.delete"), role: .destructive) { local.delete(spec) }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
