// Copyright (c) 2026 DOTS
// Media's Music tab: songs as projects, and the editor where a song's script, lyrics and tracks are worked on.

import AppKit
import SwiftUI
import DotsHarnessCore

struct MusicStudioPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: MusicStudioStore
    @ObservedObject private var studio: MediaStudioStore
    let query: String

    @State private var brief = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showSettings = false
    @State private var deleteTarget: MusicProject?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 20)]

    init(model: AppModel, query: String) {
        self.model = model
        self.store = model.musicStudio
        self.studio = model.mediaStudio
        self.query = query
    }

    private var visible: [MusicProject] {
        store.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        home
        .onAppear { store.loadIfNeeded() }
        .sheet(isPresented: $showSettings) { MediaSettingsSheet(model: model) }
        .confirmationDialog(
            AppCopy.format("studio.music.deleteConfirm", deleteTarget?.name ?? ""),
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button(AppCopy.text("common.delete"), role: .destructive) {
                if let deleteTarget { store.delete(deleteTarget.id) }
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(AppCopy.text("studio.music")).font(.system(size: 15, weight: .medium))
                Spacer()
                Button(action: createEmpty) { Label(AppCopy.text("studio.music.new"), systemImage: "plus") }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    composer
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                    if visible.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(.secondary)
                            Text(AppCopy.text("studio.music.empty"))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 380)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(visible) { card($0) }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 12) {
            TextField(AppCopy.text("studio.music.placeholder"), text: $brief)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(plan)
            Button { showSettings = true } label: {
                Text(MediaSettingsView.summary(of: studio.settings, for: .music)).lineLimit(1)
            }
            .help(AppCopy.text("studio.settings.title"))
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(AppCopy.text("studio.music.plan"), action: plan)
                    .buttonStyle(.borderedProminent)
                    .disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func card(_ project: MusicProject) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { store.openProjectID = project.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "music.note.list").font(.system(size: 22)).foregroundStyle(.secondary)
                    .padding(.bottom, 10)
                Text(project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(
                    AppCopy.format("studio.music.trackCount", project.tracks.count)
                        + " · " + project.updatedAt.formatted(.relative(presentation: .named))
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(shape.stroke(Color.primary.opacity(0.12)))
        .contextMenu {
            Button(AppCopy.text("common.delete"), role: .destructive) { deleteTarget = project }
        }
    }

    private func createEmpty() {
        let project = MusicProject(
            name: AppCopy.text("studio.untitled"),
            sections: [MusicSection(name: AppCopy.text("studio.music.section.default"))]
        )
        store.save(project)
        store.openProjectID = project.id
    }

    /// Writes the song first and opens it; audio is generated from the editor, once the plan reads right.
    private func plan() {
        let text = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                let project = try await MusicStudioAI.plan(brief: text, router: model.router, settings: studio.settings)
                store.save(project)
                brief = ""
                store.openProjectID = project.id
            } catch {
                self.error = (error as? NativeAgentError)?.message ?? error.localizedDescription
            }
            busy = false
        }
    }
}

/// Media models > Music: which backend makes the tracks, and which of its models.
struct MusicSourceSettings: View {
    @ObservedObject var store: MediaStudioStore
    /// What the chosen backend says it offers.
    @State private var models: [String] = []
    @State private var key = ""

    /// A source's raw value, or the id of a connected API.
    private var selection: Binding<String> {
        Binding(
            get: { store.settings.musicEndpoint?.id ?? store.settings.musicSource.rawValue },
            set: { tag in
                if let source = MediaStudioSettings.Source(rawValue: tag) {
                    store.settings.musicSource = source
                    store.settings.musicEndpointID = ""
                } else {
                    store.settings.musicEndpointID = tag
                }
            }
        )
    }

    private var endpointIndex: Int? {
        store.settings.musicEndpoints.firstIndex { $0.id == store.settings.musicEndpointID }
    }

    /// Where the model list comes from; it is read again whenever this changes.
    private var listing: String {
        if let endpoint = store.settings.musicEndpoint { return "\(endpoint.id) \(endpoint.baseURL)" }
        return store.settings.musicSource == .local ? store.settings.localBaseURL : ""
    }

    var body: some View {
        Picker(AppCopy.text("studio.settings.source"), selection: selection) {
            ForEach(MediaStudioSettings.Source.allCases, id: \.self) { source in
                Text(AppCopy.text("studio.settings.source.\(source.rawValue)")).tag(source.rawValue)
            }
            ForEach(store.settings.musicEndpoints) { Text($0.name).tag($0.id) }
        }
        if let index = endpointIndex {
            let endpoint = $store.settings.musicEndpoints[index]
            TextField(AppCopy.text("studio.settings.music.name"), text: endpoint.name)
            TextField(AppCopy.text("studio.settings.localURL"), text: endpoint.baseURL)
            SecureField(AppCopy.text("studio.settings.music.key"), text: $key)
                .onChange(of: key) { _, key in
                    if key != (endpoint.wrappedValue.apiKey ?? "") { endpoint.wrappedValue.setAPIKey(key) }
                }
            modelField(endpoint.model)
            Button(AppCopy.text("common.remove"), role: .destructive) { remove(endpoint.wrappedValue) }
        } else {
            modelField($store.settings.musicModel)
        }
        Menu(AppCopy.text("studio.settings.music.connect")) {
            ForEach(MusicEndpoint.Format.allCases, id: \.self) { format in
                Button(AppCopy.text("studio.settings.music.type.\(format.rawValue)")) { connect(format) }
            }
        }
        .fixedSize()
        .task(id: listing) { await load() }
        Text(AppCopy.text("studio.settings.music.help")).font(.caption).foregroundStyle(.secondary)
    }

    private func modelField(_ model: Binding<String>) -> some View {
        HStack {
            TextField(
                AppCopy.text("studio.settings.model"), text: model,
                prompt: Text(AppCopy.text("studio.settings.modelDefault"))
            )
            if !models.isEmpty {
                Menu {
                    ForEach(models, id: \.self) { id in Button(id) { model.wrappedValue = id } }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .fixedSize()
            }
        }
    }

    private func load() async {
        let endpoint = store.settings.musicEndpoint
        key = endpoint?.apiKey ?? ""
        models = []
        if let known = endpoint?.format.knownModels, !known.isEmpty {
            models = known
        } else if let base = endpoint?.baseURL ?? (listing.isEmpty ? nil : listing) {
            models = await MusicStudioAI.models(baseURL: base, apiKey: endpoint?.apiKey)
        }
    }

    private func connect(_ format: MusicEndpoint.Format) {
        let endpoint = MusicEndpoint(name: AppCopy.text("studio.settings.music.type.\(format.rawValue)"), format: format)
        store.settings.musicEndpoints.append(endpoint)
        store.settings.musicEndpointID = endpoint.id
    }

    private func remove(_ endpoint: MusicEndpoint) {
        endpoint.setAPIKey(nil)
        store.settings.musicEndpointID = ""
        store.settings.musicEndpoints.removeAll { $0.id == endpoint.id }
    }
}
