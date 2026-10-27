// Copyright (c) 2026 DOTS
// Media section: the project grid, templates and the settings that feed generation.

import SwiftUI
import DotsHarnessCore

struct MediaView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: MediaStudioStore
    @ObservedObject private var music: MusicStudioStore

    /// The request typed on the home screen, run once by the editor it opens.
    @State private var pendingPrompt = ""

    init(model: AppModel) {
        self.model = model
        self.store = model.mediaStudio
        self.music = model.musicStudio
    }

    var body: some View {
        Group {
            if let id = store.openProjectID, let project = store.project(id) {
                MediaEditorView(model: model, project: project, initialPrompt: pendingPrompt)
                    .id(id)
            } else if let id = music.openProjectID, let song = music.project(id) {
                MusicEditorView(model: model, project: song)
                    .id(id)
            } else {
                MediaHomeView(
                    model: model, store: store, pendingPrompt: $pendingPrompt
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.loadIfNeeded() }
        .onChange(of: store.openProjectID) { id in
            if id == nil { pendingPrompt = "" }
        }
    }
}

private struct MediaHomeView: View {
    private enum Tab: String, CaseIterable {
        case projects, templates, music, library
        var title: String { AppCopy.text("studio.\(rawValue)") }
        var systemImage: String {
            switch self {
            case .projects: return "clock"
            case .templates: return "square.grid.2x2"
            case .music: return "music.note"
            case .library: return "books.vertical"
            }
        }
    }

    private enum Sort: String, CaseIterable {
        case updated, name
        var title: String { AppCopy.text(self == .updated ? "sidebar.sortLastUpdate" : "studio.home.sort.name") }
    }

    /// How far back an edit may lie, in days; zero keeps everything.
    private enum Period: Int, CaseIterable {
        case all = 0, week = 7, month = 30
        var title: String { AppCopy.text("studio.home.filter.\(self)") }
    }

    @ObservedObject var model: AppModel
    @ObservedObject var store: MediaStudioStore
    @Binding var pendingPrompt: String
    @State private var idea = ""
    @State private var query = ""
    @State private var sort: Sort = .updated
    @State private var period: Period = .all
    @AppStorage("media.home.list") private var listMode = false
    /// Starred project ids, comma separated.
    @AppStorage("media.home.starred") private var starredRaw = ""
    /// Remembered, so closing a song lands back on Music rather than on Projects.
    @AppStorage("media.home.tab") private var storedTab = Tab.projects.rawValue
    private var tab: Tab {
        get { Tab(rawValue: storedTab) ?? .projects }
        set { storedTab = newValue.rawValue }
    }
    /// The sidebar button hands the tab over in an escaping closure, so the
    /// write goes through the storage directly instead of the computed setter.
    private func selectTab(_ value: Tab) {
        storedTab = value.rawValue
    }
    @State private var category: MediaTemplate.Category = .social
    @State private var showSettings = false
    @State private var renameTarget: MediaProject?
    @State private var renameText = ""
    @State private var deleteTarget: MediaProject?
    /// Built once: a template hands out fresh layer ids on every call.
    @State private var templates = MediaTemplate.all.map { (template: $0, canvas: $0.canvas()) }

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 20)]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            if tab == .music {
                MusicStudioPane(model: model, query: query)
            } else if tab == .library {
                MediaLibraryPane(model: model, query: query)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            hero
                            filterBar
                            Group {
                                if tab == .templates {
                                    if listMode { templateList } else { templateGrid }
                                } else if store.projects.isEmpty {
                                    emptyState
                                } else if listMode {
                                    projectList
                                } else {
                                    projectGrid
                                }
                            }
                            .padding(.horizontal, 28)
                            .padding(.bottom, 28)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettings) { MediaSettingsSheet(model: model) }
        .onAppear { if Tab(rawValue: storedTab) == nil { storedTab = Tab.projects.rawValue } }
        .alert(AppCopy.text("studio.rename"), isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField(AppCopy.text("studio.projectName"), text: $renameText)
            Button(AppCopy.text("common.save")) {
                if let renameTarget { store.rename(renameTarget.id, to: renameText) }
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            AppCopy.format("studio.deleteConfirm", deleteTarget?.name ?? ""),
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button(AppCopy.text("common.delete"), role: .destructive) {
                if let deleteTarget { store.delete(deleteTarget.id) }
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
        }
    }

    private var starred: Set<String> { Set(starredRaw.split(separator: ",").map(String.init)) }

    private func toggleStar(_ id: String) {
        starredRaw = starred.symmetricDifference([id]).sorted().joined(separator: ",")
    }

    private func matches(_ name: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    private var visibleProjects: [MediaProject] {
        let cutoff = period == .all ? Date.distantPast : Date().addingTimeInterval(-Double(period.rawValue) * 86_400)
        let found = store.projects.filter { matches($0.name) && $0.updatedAt >= cutoff }
        return sort == .name
            ? found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            : found.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var visibleTemplates: [(template: MediaTemplate, canvas: MediaCanvas)] {
        templates.filter { $0.template.category == category && matches($0.template.title) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(AppCopy.text("studio.home.search"), text: $query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
            .padding(.bottom, 8)

            ForEach(Tab.allCases, id: \.self) { item in
                sidebarRow(item.title, item.systemImage, selected: tab == item) { selectTab(item) }
            }

            Divider().padding(.vertical, 10)

            Button { showSettings = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppCopy.text("studio.settings.title")).font(.system(size: 13, weight: .medium))
                        Text(MediaSettingsView.summary(of: store.settings, for: .image))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.14)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.vertical, 10)

            Text(AppCopy.text("studio.home.starred"))
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(store.projects.filter { starred.contains($0.id) }) { project in
                sidebarRow(project.name, "folder.fill", selected: false) { open(project) }
                    .contextMenu { projectMenu(project) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    private func sidebarRow(
        _ title: String, _ systemImage: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(selected ? 0.3 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(AppCopy.text("rail.media"))
                .font(.system(size: 15, weight: .medium))
            Spacer()
            pill(AppCopy.text("studio.newProject"), "plus", action: newProject)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    private func pill(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The band that turns a typed idea into a project with the request already running.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(AppCopy.text("studio.home.title"))
                    .font(.system(size: 20, weight: .semibold))
                Text(verbatim: "AI")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
            }
            HStack(spacing: 12) {
                TextField(AppCopy.text("studio.ai.placeholder.design"), text: $idea)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit(makeFromIdea)
                Button(action: makeFromIdea) {
                    Label(AppCopy.text("studio.create"), systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.primary.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 22)
            .padding(.trailing, 16)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            )
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            if tab == .templates {
                ForEach(MediaTemplate.Category.allCases, id: \.self) { item in
                    chip(item.title, item.systemImage, selected: category == item) { category = item }
                }
            }
            Spacer()
            if tab == .projects {
                Picker("", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Picker("", selection: $period) {
                    ForEach(Period.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }
            Picker("", selection: $listMode) {
                Image(systemName: "square.grid.2x2").tag(false)
                Image(systemName: "list.bullet").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .labelsHidden()
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    private func chip(
        _ title: String, _ systemImage: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(shape.fill(Color.accentColor.opacity(selected ? 0.3 : 0)))
                .overlay(shape.stroke(Color.primary.opacity(0.16)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(AppCopy.text("studio.empty.title")).font(.headline)
            Text(AppCopy.text("studio.empty.detail"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(AppCopy.text("studio.newProject"), action: newProject)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func meta(_ project: MediaProject) -> String {
        project.updatedAt.formatted(.relative(presentation: .named))
    }

    @ViewBuilder
    private func projectMenu(_ project: MediaProject) -> some View {
        Button(AppCopy.text(starred.contains(project.id) ? "studio.home.unstar" : "studio.home.star")) {
            toggleStar(project.id)
        }
        Button(AppCopy.text("studio.rename")) {
            renameText = project.name
            renameTarget = project
        }
        Button(AppCopy.text("studio.duplicate")) { store.duplicate(project.id) }
        Divider()
        Button(AppCopy.text("common.delete"), role: .destructive) { deleteTarget = project }
    }

    private var projectGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(visibleProjects) { project in
                Button { open(project) } label: {
                    card(
                        canvas: project.canvases.first,
                        projectID: project.id,
                        title: project.name,
                        detail: AppCopy.format("studio.projectMeta", project.canvases.count, meta(project))
                    )
                }
                .buttonStyle(.plain)
                .contextMenu { projectMenu(project) }
            }
        }
    }

    private var projectList: some View {
        LazyVStack(spacing: 0) {
            listRow(AppCopy.text("studio.home.sort.name"), AppCopy.text("studio.home.modified"),
                    AppCopy.text("studio.home.canvases"), header: true)
            ForEach(visibleProjects) { project in
                Button { open(project) } label: {
                    listRow(project.name, meta(project), "\(project.canvases.count)")
                }
                .buttonStyle(.plain)
                .contextMenu { projectMenu(project) }
            }
        }
    }

    private func useTemplate(_ template: MediaTemplate) {
        open(store.create(name: template.title, canvas: template.canvas()))
    }

    private var templateGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(visibleTemplates, id: \.template.id) { item in
                Button { useTemplate(item.template) } label: {
                    card(
                        canvas: item.canvas,
                        projectID: "",
                        title: item.template.title,
                        detail: "\(Int(item.canvas.width)) × \(Int(item.canvas.height))"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var templateList: some View {
        LazyVStack(spacing: 0) {
            listRow(AppCopy.text("studio.home.sort.name"), "", "", header: true)
            ForEach(visibleTemplates, id: \.template.id) { item in
                Button { useTemplate(item.template) } label: {
                    listRow(item.template.title, "\(Int(item.canvas.width)) × \(Int(item.canvas.height))", "")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func listRow(_ name: String, _ second: String, _ third: String, header: Bool = false) -> some View {
        HStack(spacing: 12) {
            badge.opacity(header ? 0 : 1)
            Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(second).lineLimit(1).frame(width: 200, alignment: .leading)
            Text(third).lineLimit(1).frame(width: 110, alignment: .leading)
        }
        .font(.system(size: 13, weight: header ? .regular : .medium))
        .foregroundStyle(header ? Color.secondary : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    private var badge: some View {
        Image(systemName: "photo.on.rectangle")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
    }

    private func card(canvas: MediaCanvas?, projectID: String, title: String, detail: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black.opacity(0.18)
                if let canvas {
                    MediaCanvasPreview(canvas: canvas) { store.assetURL(projectID: projectID, name: $0) }
                        .padding(14)
                }
            }
            .frame(height: 200)
            Divider()
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.12)))
        .contentShape(shape)
    }

    /// Opens a new project and hands the typed idea to its editor.
    private func makeFromIdea() {
        let text = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingPrompt = text
        idea = ""
        open(store.create(name: String(text.prefix(40))))
    }

    /// A new project opens on an empty board; its canvases are picked or drawn there.
    private func newProject() {
        open(store.create(name: AppCopy.text("studio.untitled")))
    }

    private func open(_ project: MediaProject) {
        store.openProjectID = project.id
    }
}

private extension MediaTemplate.Category {
    var systemImage: String {
        switch self {
        case .social: return "bubble.left.and.bubble.right"
        case .uiux: return "iphone"
        case .presentation: return "rectangle.on.rectangle"
        case .other: return "square.on.circle"
        }
    }
}

/// Which models the studio uses. Shown in Media and under Settings.
struct MediaSettingsView: View {
    @ObservedObject var router: RouterController
    @ObservedObject var store: MediaStudioStore

    init(model: AppModel) {
        self.router = model.router
        self.store = model.mediaStudio
    }

    static func summary(of settings: MediaStudioSettings, for kind: MediaKind) -> String {
        let model = settings.model(for: kind)
        let source = (kind == .music ? settings.musicEndpoint?.name : nil)
            ?? AppCopy.text("studio.settings.source.\(settings.source(for: kind).rawValue)")
        return model.isEmpty ? source : "\(source) · \(model)"
    }

    var body: some View {
        Form {
            Section(AppCopy.text("studio.settings.design")) {
                LabeledContent(AppCopy.text("studio.settings.model")) {
                    ChatModelMenu(router: router, modelID: $store.settings.plannerModelID)
                        .fixedSize()
                }
                Text(AppCopy.text("studio.settings.designHelp")).font(.caption).foregroundStyle(.secondary)
            }
            Section(AppCopy.text("studio.ai.kind.image")) {
                sourcePicker($store.settings.imageSource)
                TextField(
                    AppCopy.text("studio.settings.model"),
                    text: $store.settings.imageModel,
                    prompt: Text(AppCopy.text("studio.settings.modelDefault"))
                )
            }
            Section(AppCopy.text("studio.ai.kind.video")) {
                sourcePicker($store.settings.videoSource)
                TextField(
                    AppCopy.text("studio.settings.model"),
                    text: $store.settings.videoModel,
                    prompt: Text(AppCopy.text("studio.settings.modelDefault"))
                )
            }
            Section(MediaLibraryItem.Kind.music.title) {
                MusicSourceSettings(store: store)
            }
            Section(AppCopy.text("studio.settings.local")) {
                TextField(AppCopy.text("studio.settings.localURL"), text: $store.settings.localBaseURL)
                Text(AppCopy.text("studio.settings.localHelp")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.loadIfNeeded() }
    }

    private func sourcePicker(_ selection: Binding<MediaStudioSettings.Source>) -> some View {
        Picker(AppCopy.text("studio.settings.source"), selection: selection) {
            ForEach(MediaStudioSettings.Source.allCases, id: \.self) { source in
                Text(AppCopy.text("studio.settings.source.\(source.rawValue)")).tag(source)
            }
        }
    }
}

struct MediaSettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            MediaSettingsView(model: model)
            Divider()
            HStack {
                Spacer()
                Button(AppCopy.text("common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
    }
}
