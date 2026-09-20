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
            Section("Native mobile workspace") {
                LabeledContent("LAN endpoint", value: model.remoteControl.preferredEndpoint)
                if let pairing = activePairing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan this QR code or enter the one-time code in HerNess Mobile.").font(.caption)
                        if let image = qrImage(pairing.payload) {
                            Image(nsImage: image).resizable().interpolation(.none).frame(width: 180, height: 180).accessibilityLabel("Mobile pairing QR code")
                        }
                        LabeledContent("Code", value: pairing.code).textSelection(.enabled)
                        Text(pairing.payload).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Expires \(pairing.expiresAt.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                HStack {
                    Button("New pairing code") { _ = model.beginRemotePairing() }
                    Button("Copy pairing link") {
                        if let value = activePairing?.payload { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
                    }.disabled(activePairing == nil)
                }
                HStack {
                    Button("Enable Cloudflare Quick Tunnel") { Task { do { _ = try await model.enableRemoteCloudTunnel() } catch { tunnelError = error.localizedDescription } } }
                    if model.remoteControl.publicEndpoint != nil { Button("Disable tunnel") { model.disableRemoteCloudTunnel() } }
                }
                if !tunnelError.isEmpty { Text(tunnelError).font(.caption).foregroundStyle(.red) }
                Text("Provider keys stay on the desktop. File writes, terminal, build, deploy, and PR actions still use the selected approval mode.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Mobile control")
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
    @State private var tab: Section = .catalog
    @State private var selectedSkill: SkillDescriptor?
    @State private var error = ""

    private enum Section: String, CaseIterable {
        case catalog, installed

        var title: String { AppCopy.text("settings.skills.\(rawValue)") }
    }

    init(model: AppModel) {
        self.model = model
        self.skills = model.activeSkills
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppCopy.text("settings.tab.skills"))
                .font(.title2.weight(.semibold))
            Picker(AppCopy.text("settings.tab.skills"), selection: $tab) {
                ForEach(Section.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            if tab == .catalog { catalog } else { installed }
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .navigationTitle(AppCopy.text("settings.tab.skills"))
        .sheet(item: $selectedSkill) { skill in
            ScrollView {
                Text((try? skills.read(id: skill.id, includeDisabled: true)) ?? AppCopy.text("settings.skillReadFailed"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(minWidth: 680, minHeight: 520)
            .navigationTitle(skill.name)
        }
    }

    private var catalog: some View {
        List(skills.marketplaceEntries) { entry in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.headline)
                        Text(entry.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if skills.isInstalled(entry) {
                        Text(AppCopy.text("local.installed")).font(.caption).foregroundStyle(.secondary)
                    } else if entry.downloadURL != nil {
                        Button(AppCopy.text("common.download")) {
                            Task {
                                do { try await skills.install(entry) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                Text(entry.description).font(.caption)
                HStack(spacing: 10) {
                    if let githubURL = entry.githubURL, let url = URL(string: githubURL) { Link("GitHub", destination: url) }
                    if let skillURL = entry.skillURL, let url = URL(string: skillURL) { Link("SKILL.md", destination: url) }
                    Text(AppCopy.format("settings.skillsSnapshot", entry.snapshotDate))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var installed: some View {
        List(skills.entries) { skill in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name).font(.headline)
                    Text("\(skill.id) · \(skill.source.rawValue)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(skill.description).font(.caption).lineLimit(2)
                }
                Spacer()
                Button(AppCopy.text("common.view")) { selectedSkill = skill }
                Toggle(AppCopy.text("settings.enabled"), isOn: Binding(
                    get: { skill.enabled },
                    set: { skills.setEnabled(skill.id, $0) }
                ))
                .labelsHidden()
                if skill.isInstalled {
                    Button(AppCopy.text("common.delete"), role: .destructive) {
                        do { try skills.remove(skill.id) }
                        catch let caughtError { error = caughtError.localizedDescription }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .overlay(alignment: .bottomLeading) {
            Text(AppCopy.text("settings.skillsHint"))
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
}
