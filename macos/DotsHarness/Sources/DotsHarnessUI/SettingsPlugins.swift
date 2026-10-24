// Copyright (c) 2026 DOTS
// Plugin settings pane.

import AppKit
import UniformTypeIdentifiers
import SwiftUI
import HarnessPluginKit
import DotsHarnessCore
import PluginRuntime

struct PluginSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showMarketplace = false
    @State private var visionError: String?
    @State private var visionBusy = false
    @State private var pluginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppCopy.text("settings.pluginsTitle")).font(.title2.weight(.semibold))
                Spacer()
                Button(AppCopy.text("settings.installFromFile")) { installFromFile() }
                Button(AppCopy.text("settings.marketplace")) { showMarketplace = true }
                Button(AppCopy.text("settings.revealFolder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.plugins])
                }
                Button(AppCopy.text("settings.reload")) { model.remount() }
            }
            .padding()
            .sheet(isPresented: $showMarketplace) {
                MarketplaceView(model: model)
            }
            Text(AppCopy.text("settings.pluginsHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if let pluginError {
                Text(pluginError).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            visionSection
                .padding(.horizontal)
                .padding(.top, 8)
            List(model.catalog.entries, id: \.id) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.manifest.name).font(.headline)
                            Text(entry.manifest.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(AppCopy.text("settings.enabled"), isOn: Binding(
                            get: { entry.enabled },
                            set: { value in
                                model.catalog.setEnabled(entry.manifest.id, value)
                                model.remount()
                            }
                        ))
                        .labelsHidden()
                        .disabled(entry.broken != nil)
                    }
                    HStack(spacing: 8) {
                        TagBadge(entry.kind.rawValue)
                        TagBadge(entry.manifest.plane.rawValue)
                        TagBadge(entry.trust.rawValue)
                        Text("v\(entry.manifest.version) · ABI \(entry.manifest.abi)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let description = Optional(entry.manifest.description), !description.isEmpty {
                        Text(description).font(.caption)
                    }
                    if let broken = entry.broken {
                        Text(broken).font(.caption).foregroundStyle(.red)
                    }
                    if entry.kind != .builtin && entry.trust != .system {
                        Picker(AppCopy.text("settings.trust"), selection: Binding(
                            get: { entry.trust },
                            set: { value in
                                model.catalog.setTrust(entry.manifest.id, value)
                                model.remount()
                            }
                        )) {
                            Text(AppCopy.text("settings.untrusted")).tag(PluginTrust.untrusted)
                            Text(AppCopy.text("settings.trusted")).tag(PluginTrust.trusted)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                    }
                    if entry.kind != .builtin {
                        HStack(spacing: 8) {
                            Button(AppCopy.text("settings.exportPlugin")) { exportPlugin(entry.manifest.id) }
                            Button(AppCopy.text("common.remove"), role: .destructive) {
                                pluginError = nil
                                do { try model.removePlugin(id: entry.manifest.id) }
                                catch { pluginError = error.localizedDescription }
                            }
                        }
                        .font(.caption)
                    }
                    SlotStack(slot: WellKnownSlot.pluginsDetail, registry: model.host.slots)
                }
                .padding(.vertical, 6)
            }
            if !model.host.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppCopy.text("settings.lastMountFailed")).font(.headline)
                    ForEach(model.host.issues) { issue in
                        Text("\(issue.rowId): \(issue.message)").font(.caption).foregroundStyle(.red)
                    }
                }
                .padding()
            }
        }
    }

    private func installFromFile() {
        pluginError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dotsplugin") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.installPluginFile(url) }
        catch { pluginError = error.localizedDescription }
    }

    private func exportPlugin(_ id: String) {
        pluginError = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dotsplugin") ?? .data]
        panel.nameFieldStringValue = "\(id).dotsplugin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportPlugin(id: id, to: url) }
        catch { pluginError = error.localizedDescription }
    }

    private var visionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(AppCopy.text("vision.title"), systemImage
: "eye")
                        .font(.headline)
                    Spacer()
                    if model.visionPluginInstalled {
                        Toggle(AppCopy.text("settings.enabled"), isOn: Binding(
                            get: { model.visionPluginEnabled },
                            set: { model.setVisionPluginEnabled($0) }
                        ))
                        .labelsHidden()
                    }
                }
                Text(visionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.visionState == .downloading || model.visionState == .preparing {
                    ProgressView(value: model.visionModelProgress)
                        .progressViewStyle(.linear)
                }
                if model.visionPluginInstalled {
                    HStack(spacing: 8) {
                        if model.visionPluginEnabled && model.visionState != .ready {
                            Button(AppCopy.text("vision.prepareModel")) {
                                run { try await model.prepareVision() }
                            }
                            .disabled(visionBusy)
                        }
                        if model.visionState != .unavailable && model.visionState != .modelMissing {
                            Button(AppCopy.text("vision.deleteModel"), role: .destructive) {
                                do { try model.deleteVisionModel() }
                                catch { visionError = error.localizedDescription }
                            }
                            .disabled(visionBusy)
                        }
                        Button(AppCopy.text("vision.removePlugin"), role: .destructive) {
                            do { try model.removeVisionPlugin() }
                            catch { visionError = error.localizedDescription }
                        }
                        .disabled(visionBusy)
                    }
                } else {
                    Button(AppCopy.text("vision.installPlugin")) {
                        run { try await model.installVisionPlugin() }
                    }
                    .disabled(visionBusy)
                }
                if let visionError {
                    Text(visionError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(4)
        }
    }

    private var visionStatus: String {
        if !model.visionPluginInstalled { return AppCopy.text("vision.notInstalled") }
        if !model.visionPluginEnabled { return AppCopy.text("vision.disabled") }
        switch model.visionState {
        case .modelMissing:
            return "\(AppCopy.text("vision.modelMissing")) · \(ByteCountFormatter.string(fromByteCount: model.visionModelBytes, countStyle: .file))"
        case .downloading:
            return "\(AppCopy.text("vision.downloading")) (\(Int(model.visionModelProgress * 100))%)"
        case .preparing:
            return "\(AppCopy.text("vision.preparing")) (\(Int(model.visionModelProgress * 100))%)"
        case .ready: return AppCopy.format("vision.ready", ByteCountFormatter.string(fromByteCount: model.visionModelBytes, countStyle: .file))
        case .failed: return AppCopy.text("vision.failed")
        case .unavailable: return AppCopy.text("vision.unavailable")
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        visionError = nil
        visionBusy = true
        Task { @MainActor in
            defer { visionBusy = false }
            do { try await operation() }
            catch { visionError = error.localizedDescription }
        }
    }

}
