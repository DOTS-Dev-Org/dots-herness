import SwiftUI
import UIKit
import WebKit
import Foundation
import UniformTypeIdentifiers

enum MobileProviderMarkCatalog {
    static func imageName(for providerID: String) -> String? {
        switch providerID.lowercased() {
        case "gpt", "openai", "openai-responses": return "ProviderOpenAI"
        case "anthropic", "claude": return "ProviderAnthropic"
        default: return nil
        }
    }

    static func isMonochrome(_ imageName: String) -> Bool {
        ["ProviderOpenAI", "ProviderAnthropic"].contains(imageName)
    }
}

struct MobileProviderBrandMark: View {
    let providerID: String
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let imageName = MobileProviderMarkCatalog.imageName(for: providerID) {
                Image(imageName)
                    .resizable()
                    .renderingMode(MobileProviderMarkCatalog.isMonochrome(imageName) ? .template : .original)
                    .foregroundStyle(.black)
                    .scaledToFit()
                    .padding(size * 0.17)
            } else {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.white, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

struct MobileRootView: View {
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var localization: MobileLocalization
    @EnvironmentObject private var theme: MobileTheme
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @State private var showingSplash = true
    @StateObject private var legal = LegalModel()
    var body: some View {
        Group {
            if showingSplash {
                SplashView()
                    .transition(.opacity)
            } else if !hasSeenIntro {
                ZStack {
                    (theme.isDark ? Color.black : Color.white)
                    IntroView { hasSeenIntro = true }
                }
                .ignoresSafeArea()
            } else if legal.needsAcceptance {
                LegalGateView(legal: legal)
            } else {
                // The on-device runtime is the default. Pairing remains a
                // backwards-compatible deep link, never an app-start gate.
                WorkspaceView()
                    .environmentObject(legal)
            }
        }
        .environment(\.locale, localization.locale)
        .environment(\.layoutDirection, localization.isRTL ? .rightToLeft : .leftToRight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeOut(duration: 0.2)) { showingSplash = false }
        }
        .task {
            legal.setLanguage(localization.effective)
            await legal.load()
        }
        .onChange(of: localization.effective) { _, language in
            legal.setLanguage(language)
            Task { await legal.load() }
        }
        .alert(localization.text("mobile.connection.title"), isPresented: .constant(client.errorMessage != nil), actions: { Button(localization.text("app.ok")) { client.errorMessage = nil } }, message: { Text(client.errorMessage ?? "") })
    }
}

private struct SplashView: View {
    @EnvironmentObject private var localization: MobileLocalization

    var body: some View {
        ZStack {
            Color("SplashBackground")
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image("HerNessLogo")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 184, height: 184)
                    .accessibilityLabel(localization.text("mobile.splash.logo"))

                Text("HerNess")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .tracking(-0.6)
                    .foregroundStyle(Color(red: 0.15, green: 0.11, blue: 0.08))

                Text(localization.text("mobile.splash.buildLine"))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.black.opacity(0.52))
            }
        }
        .preferredColorScheme(.light)
        .accessibilityElement(children: .combine)
    }
}

private struct IntroSlide: Identifiable {
    let id: String
    let imageName: String
    let titleKey: String
    let descriptionKey: String
}

private let introSlides = [
    IntroSlide(id: "connect", imageName: "IntroConnect", titleKey: "intro.title.connect", descriptionKey: "intro.description.connect"),
    IntroSlide(id: "agent", imageName: "IntroAgent", titleKey: "intro.title.agent", descriptionKey: "intro.description.agent"),
    IntroSlide(id: "ship", imageName: "IntroShip", titleKey: "intro.title.ship", descriptionKey: "intro.description.ship")
]

private struct IntroView: View {
    @EnvironmentObject private var theme: MobileTheme
    let onFinish: () -> Void
    @State private var page = 0

    var body: some View {
        ZStack {
            (theme.isDark ? Color.black : Color.white)
            IntroSlideView(slide: introSlides[page], page: $page, onFinish: onFinish)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width < -50, page < introSlides.count - 1 {
                        withAnimation(.easeInOut) { page += 1 }
                    } else if value.translation.width > 50, page > 0 {
                        withAnimation(.easeInOut) { page -= 1 }
                    }
                }
        )
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

private struct IntroSlideView: View {
    @EnvironmentObject private var localization: MobileLocalization
    @EnvironmentObject private var theme: MobileTheme
    let slide: IntroSlide
    @Binding var page: Int
    let onFinish: () -> Void
    @State private var isLanguageDropdownOpen = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Image(uiImage: UIImage(named: slide.imageName) ?? UIImage())
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                LinearGradient(
                    colors: theme.isDark
                        ? [Color.black.opacity(0.70), Color.black.opacity(0.30), Color.clear]
                        : [Color.white.opacity(0.85), Color.white.opacity(0.40), Color.clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.22)
                )

                LinearGradient(
                    colors: theme.isDark
                        ? [.clear, .black.opacity(0.08), .black.opacity(0.92)]
                        : [.clear, .white.opacity(0.20), .white.opacity(0.96)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center) {
                        if localization.isRTL {
                            HStack(spacing: 12) {
                                if page < introSlides.count - 1 {
                                    Button(localization.text("intro.skip"), action: onFinish)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(theme.isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.88))
                                }
                                Button {
                                    theme.toggle()
                                } label: {
                                    Image(systemName: theme.isDark ? "sun.max.fill" : "moon.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(theme.isDark ? .white : Color(red: 0.12, green: 0.12, blue: 0.14))
                                        .frame(width: 34, height: 34)
                                        .background(theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(theme.isDark ? "Switch to light theme" : "Switch to dark theme")
                            }
                            Spacer()
                            MobileLanguagePicker(isDropdownOpen: $isLanguageDropdownOpen, darkAppearance: theme.isDark)
                        } else {
                            MobileLanguagePicker(isDropdownOpen: $isLanguageDropdownOpen, darkAppearance: theme.isDark)
                            Spacer()
                            HStack(spacing: 12) {
                                Button {
                                    theme.toggle()
                                } label: {
                                    Image(systemName: theme.isDark ? "sun.max.fill" : "moon.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(theme.isDark ? .white : Color(red: 0.12, green: 0.12, blue: 0.14))
                                        .frame(width: 34, height: 34)
                                        .background(theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(theme.isDark ? "Switch to light theme" : "Switch to dark theme")
                                if page < introSlides.count - 1 {
                                    Button(localization.text("intro.skip"), action: onFinish)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(theme.isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.88))
                                }
                            }
                        }
                    }

                    Spacer()

                    Text(localization.text(slide.titleKey))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.isDark ? Color.white : Color.black)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(localization.text(slide.descriptionKey))
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .foregroundStyle(theme.isDark ? Color.white.opacity(0.76) : Color.black.opacity(0.75))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)

                    HStack(spacing: 8) {
                        ForEach(introSlides.indices, id: \.self) { index in
                            Capsule()
                                .fill(index == page
                                    ? (theme.isDark ? Color.white : Color.black)
                                    : (theme.isDark ? Color.white.opacity(0.3) : Color.black.opacity(0.25)))
                                .frame(width: index == page ? 26 : 8, height: 8)
                        }
                    }
                    .padding(.top, 24)
                    .accessibilityLabel(localization.format("intro.page", page + 1, introSlides.count))

                    HStack(spacing: 8) {
                        if localization.isRTL {
                            primaryButton
                            if page > 0 { backButton }
                        } else {
                            if page > 0 { backButton }
                            primaryButton
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                }
                .padding(.horizontal, 24)
                // IntroView intentionally draws edge-to-edge for the artwork;
                // keep the header below the Dynamic Island/status area even
                // when the parent has opted out of safe-area clipping.
                .padding(.top, max(geometry.safeAreaInsets.top, 54) + 12)
                .padding(.bottom, geometry.safeAreaInsets.bottom + 18)

                if isLanguageDropdownOpen {
                    CustomLanguageDropdown(isPresented: $isLanguageDropdownOpen, darkAppearance: theme.isDark)
                        .padding(.top, max(geometry.safeAreaInsets.top, 54) + 48)
                        .padding(.leading, localization.isRTL ? 0 : 20)
                        .padding(.trailing, localization.isRTL ? 20 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: localization.isRTL ? .topTrailing : .topLeading)
                        .zIndex(999)
                }
            }
        }
    }

    private var primaryButton: some View {
        Button {
            if page == introSlides.count - 1 {
                onFinish()
            } else {
                withAnimation(.easeInOut) { page += 1 }
            }
        } label: {
            Text(page == introSlides.count - 1 ? localization.text("intro.start") : localization.text("intro.continue"))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
        }
        .frame(height: 58)
        .background(theme.isDark ? Color.white : Color(red: 0.10, green: 0.10, blue: 0.12))
        .foregroundStyle(theme.isDark ? Color.black : Color.white)
        .clipShape(Capsule())
    }

    private var backButton: some View {
        Button {
            withAnimation(.easeInOut) { page -= 1 }
        } label: {
            Image(systemName: localization.isRTL ? "chevron.right" : "chevron.left")
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 58, height: 58)
        }
        .accessibilityLabel(localization.text("intro.back"))
        .foregroundStyle(theme.isDark ? Color.white : Color.black)
        .background(theme.isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.08))
        .clipShape(Capsule())
    }
}

struct MobileFileBrowserEntry: Identifiable {
    let path: String
    let isDirectory: Bool
    let file: WorkspaceFile?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct WorkspaceView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var local: LocalWorkspaceStore
    @EnvironmentObject private var agent: MobileAgent
    @EnvironmentObject private var loops: LoopScheduler
    @EnvironmentObject private var localization: MobileLocalization
    @EnvironmentObject private var theme: MobileTheme
    @AppStorage("confirmBeforeExit") private var confirmBeforeExit = true
    @State private var selected: WorkspaceFile?
    @State private var selectedTab = 0
    @State private var editor = ""
    @State private var prompt = ""
    @State private var showingSettings = false
    @State private var showingPreview = false
    @State private var previewURL = ""
    @State private var showingExitConfirmation = false
    @State private var browserDirectory = ""
    @State private var showingFolderImporter = false
    @State private var isImportingFolder = false
    @State private var folderImportError: String?
    @State private var isLeftDrawerPresented = false
    @State private var isToolsDrawerPresented = false

    var files: [WorkspaceFile] { local.snapshot?.files.sorted { $0.path < $1.path } ?? client.snapshot?.files.sorted { $0.path < $1.path } ?? local.files() }

    private var browserEntries: [MobileFileBrowserEntry] {
        let prefix = browserDirectory.isEmpty ? "" : browserDirectory + "/"
        var directories = Set<String>()
        var directFiles: [WorkspaceFile] = []
        for file in files where file.path.hasPrefix(prefix) {
            let remainder = String(file.path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }
            if let slash = remainder.firstIndex(of: "/") {
                directories.insert(prefix + String(remainder[..<slash]))
            } else {
                directFiles.append(file)
            }
        }
        for entry in local.directoryEntries(at: browserDirectory) where entry.isDirectory {
            directories.insert(entry.path)
        }
        let folders = directories.map { MobileFileBrowserEntry(path: $0, isDirectory: true, file: nil) }
        let documents = directFiles.map { MobileFileBrowserEntry(path: $0.path, isDirectory: false, file: $0) }
        return (folders + documents).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private var selectedScreen: some View {
        switch selectedTab {
        case 0:
            AgentTab(prompt: $prompt)
        case 1:
            NavigationSplitView {
                List {
                    if isImportingFolder {
                        HStack { ProgressView(); Text(localization.text("conversation.files")) }
                    }
                    ForEach(browserEntries) { entry in
                        if entry.isDirectory {
                            Button {
                                browserDirectory = entry.path
                                selected = nil
                                editor = ""
                            } label: {
                                Label(entry.name, systemImage: "folder")
                            }
                        } else if let file = entry.file {
                            Button {
                                selected = file
                            } label: {
                                Label(entry.name, systemImage: "doc.text")
                            }
                            .tag(file as WorkspaceFile?)
                        }
                    }
                }
                .navigationTitle(browserDirectory.isEmpty ? localization.text("conversation.files") : URL(fileURLWithPath: browserDirectory).lastPathComponent)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button { selectedTab = 0 } label: {
                            Image(systemName: localization.isRTL ? "chevron.right" : "chevron.left")
                        }
                        .accessibilityLabel(localization.text("intro.back"))
                        if !browserDirectory.isEmpty {
                            Button {
                                browserDirectory = (browserDirectory as NSString).deletingLastPathComponent
                                selected = nil
                                editor = ""
                            } label: {
                                Image(systemName: "folder")
                            }
                            .accessibilityLabel(localization.text("conversation.files"))
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { showingFolderImporter = true } label: { Image(systemName: "folder.badge.plus") }
                            .accessibilityLabel(localization.text("agent.chooseWorkspace"))
                            .disabled(agent.isRunning || loops.running != nil || local.activeSandbox != nil || isImportingFolder)
                        Button {
                            Task {
                                if client.isPaired && local.selectedProject.remoteProjectID != nil && local.selectedProject.remoteProjectID == client.remoteSelectedProjectID {
                                    await client.requestSnapshot()
                                    if let value = client.snapshot { await local.importSnapshot(value, read: client.readFileData) }
                                } else {
                                    local.refresh()
                                }
                            }
                        } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            } detail: {
                EditorView(file: selected, editor: $editor)
            }
            .fileImporter(isPresented: $showingFolderImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                Task {
                    isImportingFolder = true
                    defer { isImportingFolder = false }
                    do {
                        guard let folder = try result.get().first else { return }
                        try await local.importProject(from: folder)
                        selected = nil
                        editor = ""
                        browserDirectory = ""
                    } catch {
                        folderImportError = error.localizedDescription
                    }
                }
            }
            .alert(localization.text("conversation.files"), isPresented: Binding(
                get: { folderImportError != nil },
                set: { if !$0 { folderImportError = nil } }
            )) {
                Button(localization.text("app.ok"), role: .cancel) { folderImportError = nil }
            } message: {
                Text(folderImportError ?? "")
            }
        case 2:
            TerminalTab(onBack: { selectedTab = 0 })
        case 3:
            PreviewTab(url: $previewURL, onBack: { selectedTab = 0 })
        default:
            SettingsView(
                previewURL: $previewURL,
                confirmBeforeExit: $confirmBeforeExit,
                prompt: $prompt,
                onExit: requestExit,
                onBack: { selectedTab = 0 },
            )
        }
    }

    private var compactWorkspace: some View {
        VStack(spacing: 0) {
            if selectedTab == 0 {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { isLeftDrawerPresented = true }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(localization.text("mobile.nav.menu"))

                    Menu {
                        ForEach(local.projects) { project in
                            Button {
                                switchProject(project.id)
                            } label: {
                                Label(project.name, systemImage: project.id == local.selectedProjectID ? "checkmark" : "folder")
                                    .opacity(project.sidebarOpacity)
                            }
                        }
                    } label: {
                        Label(local.selectedProject.name, systemImage: "folder")
                            .lineLimit(1)
                            .opacity(local.selectedProjectLocationAvailable ? 1 : 0.55)
                    }
                    .disabled(agent.isRunning || loops.running != nil || local.activeSandbox != nil || isImportingFolder)

                    if !client.remoteProjects.isEmpty {
                        Menu {
                            ForEach(client.remoteProjects) { project in
                                Button {
                                    guard !agent.isRunning, loops.running == nil, local.activeSandbox == nil else {
                                        local.localError = "Stop the active run before changing projects."
                                        return
                                    }
                                    Task { await client.selectRemoteProject(project.id) }
                                } label: {
                                    Label(project.name, systemImage: project.id == client.remoteSelectedProjectID ? "checkmark" : "desktopcomputer")
                                }
                            }
                        } label: {
                            Label("Desktop", systemImage: "desktopcomputer")
                        }
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { isToolsDrawerPresented = true }
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel(localization.text("mobile.nav.menu"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            if selectedTab == 0 {
                if let sandbox = local.activeSandbox {
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.white)
                        Text(localization.format("mobile.workspace.sandboxLabel", sandbox.name)).font(.footnote.bold()).foregroundStyle(.white)
                        Spacer()
                        Text(sandbox.branch).font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.9))
                }
            }
            selectedScreen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if selectedTab == 0 {
                        Rectangle()
                            .fill(Color(uiColor: .systemBackground))
                            .frame(height: 1)
                            .allowsHitTesting(false)
                    }
                }
        }
        .overlay(alignment: .leading) {
            if isLeftDrawerPresented {
                MobileNavigationDrawer(
                    projects: local.projects,
                    selectedProjectID: local.selectedProjectID,
                    conversations: agent.previousConversations(limit: 20),
                    selectedTab: selectedTab,
                    darkAppearance: theme.isDark,
                    settingsTitle: localization.text("mobile.nav.settings"),
                    newConversationTitle: localization.text("mobile.agent.newConversation"),
                    closeTitle: localization.text("mobile.agent.close"),
                    noChatsTitle: localization.text("sidebar.noChats"),
                    canChangeProject: !agent.isRunning && loops.running == nil && local.activeSandbox == nil && !isImportingFolder,
                    canCreateConversation: local.selectedProjectLocationAvailable && !agent.isRunning && loops.running == nil && local.activeSandbox == nil,
                    onDismiss: { withAnimation(.easeInOut(duration: 0.22)) { isLeftDrawerPresented = false } },
                    onProjectSelected: { id in
                        switchProject(id)
                        withAnimation(.easeInOut(duration: 0.22)) { isLeftDrawerPresented = false }
                    },
                    onNewConversation: {
                        agent.reset()
                        selectedTab = 0
                        withAnimation(.easeInOut(duration: 0.22)) { isLeftDrawerPresented = false }
                    },
                    onConversationSelected: { id in
                        if agent.openConversation(id) {
                            selectedTab = 0
                            withAnimation(.easeInOut(duration: 0.22)) { isLeftDrawerPresented = false }
                        }
                    },
                    onAddProject: { name in
                        let project = local.addProject(name: name)
                        agent.selectProject(project.id)
                        selectedTab = 0
                        withAnimation(.easeInOut(duration: 0.22)) { isLeftDrawerPresented = false }
                    },
                    onSettings: {
                        selectedTab = 4
                        withAnimation(.easeInOut(duration: 0.22)) { isLeftDrawerPresented = false }
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .overlay(alignment: .trailing) {
            if isToolsDrawerPresented {
                MobileWorkspaceToolsDrawer(
                    projectName: local.selectedProject.name,
                    selectedTab: selectedTab,
                    darkAppearance: theme.isDark,
                    filesTitle: localization.text("conversation.files"),
                    terminalTitle: localization.text("mobile.nav.terminal"),
                    previewTitle: localization.text("mobile.nav.preview"),
                    closeTitle: localization.text("intro.back"),
                    onDismiss: { withAnimation(.easeInOut(duration: 0.22)) { isToolsDrawerPresented = false } },
                    onSelect: { tab in
                        selectedTab = tab
                        withAnimation(.easeInOut(duration: 0.22)) { isToolsDrawerPresented = false }
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isLeftDrawerPresented)
        .animation(.easeInOut(duration: 0.22), value: isToolsDrawerPresented)
    }

    private var foldableWorkspace: some View {
        NavigationSplitView {
            MobileNavigationDrawer(
                projects: local.projects,
                selectedProjectID: local.selectedProjectID,
                conversations: agent.previousConversations(limit: 50),
                selectedTab: selectedTab,
                darkAppearance: theme.isDark,
                settingsTitle: localization.text("mobile.nav.settings"),
                newConversationTitle: localization.text("mobile.agent.newConversation"),
                closeTitle: localization.text("mobile.agent.close"),
                noChatsTitle: localization.text("sidebar.noChats"),
                canChangeProject: !agent.isRunning && loops.running == nil && local.activeSandbox == nil && !isImportingFolder,
                canCreateConversation: local.selectedProjectLocationAvailable && !agent.isRunning && loops.running == nil && local.activeSandbox == nil,
                onDismiss: {},
                onProjectSelected: switchProject,
                onNewConversation: {
                    agent.reset()
                    selectedTab = 0
                },
                onConversationSelected: { id in
                    if agent.openConversation(id) { selectedTab = 0 }
                },
                onAddProject: { name in
                    let project = local.addProject(name: name)
                    agent.selectProject(project.id)
                    selectedTab = 0
                },
                onSettings: { selectedTab = 4 },
                isPersistent: true,
                onSelectTab: { selectedTab = $0 }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 340)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(selectedWorkspaceTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !client.remoteProjects.isEmpty {
                        Menu {
                            ForEach(client.remoteProjects) { project in
                                Button {
                                    guard !agent.isRunning, loops.running == nil, local.activeSandbox == nil else {
                                        local.localError = "Stop the active run before changing projects."
                                        return
                                    }
                                    Task { await client.selectRemoteProject(project.id) }
                                } label: {
                                    Label(project.name, systemImage: project.id == client.remoteSelectedProjectID ? "checkmark" : "desktopcomputer")
                                }
                            }
                        } label: {
                            Label("Desktop", systemImage: "desktopcomputer")
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

                if selectedTab == 0, let sandbox = local.activeSandbox {
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.white)
                        Text(localization.format("mobile.workspace.sandboxLabel", sandbox.name)).font(.footnote.bold()).foregroundStyle(.white)
                        Spacer()
                        Text(sandbox.branch).font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.green.opacity(0.9))
                }

                Divider()
                selectedScreen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var selectedWorkspaceTitle: String {
        switch selectedTab {
        case 0: localization.text("mobile.nav.agent")
        case 1: localization.text("mobile.nav.code")
        case 2: localization.text("mobile.nav.terminal")
        case 3: localization.text("mobile.nav.preview")
        default: localization.text("mobile.nav.settings")
        }
    }

    var body: some View {
        GeometryReader { geometry in
            // iPhone Duo reports regular width on its inner display and compact width
            // on its outer display. Use the trait instead of fixed device dimensions.
            let usesFoldableLayout = UIDevice.current.userInterfaceIdiom == .phone
                && horizontalSizeClass == .regular

            Group {
                if usesFoldableLayout {
                    foldableWorkspace
                } else {
                    compactWorkspace
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.easeInOut(duration: 0.2), value: usesFoldableLayout)
            .onChange(of: usesFoldableLayout) { _, isWide in
                if isWide {
                    isLeftDrawerPresented = false
                    isToolsDrawerPresented = false
                }
            }
        }
        // Only ask the desktop for a snapshot when there is a desktop; offline the
        // mirror (a GitHub clone or the last snapshot) is already the workspace.
        .onAppear {
            bindSelectedRemoteProject()
            guard client.isPaired, local.selectedProject.remoteProjectID != nil, local.selectedProject.remoteProjectID == client.remoteSelectedProjectID else { return }
            Task { await client.requestSnapshot(); if let value = client.snapshot { await local.importSnapshot(value, read: client.readFileData) } }
        }
        .onChange(of: client.remoteSelectedProjectID) { _, _ in
            bindSelectedRemoteProject()
            guard client.isPaired, local.selectedProject.remoteProjectID != nil, local.selectedProject.remoteProjectID == client.remoteSelectedProjectID else { return }
            Task { await client.requestSnapshot(); if let value = client.snapshot { await local.importSnapshot(value, read: client.readFileData) } }
        }
        .onChange(of: local.selectedProjectID) { _, _ in
            selected = nil
            editor = ""
            browserDirectory = ""
            previewURL = ""
            guard let remoteID = local.selectedProject.remoteProjectID else {
                client.clearRemoteProjectScope()
                return
            }
            guard remoteID != client.remoteSelectedProjectID else { return }
            Task { await client.selectRemoteProject(remoteID) }
        }
        .onChange(of: selected) { _, file in
            guard let file else { return }
            Task { editor = local.text(for: file.path); if editor.isEmpty && client.isPaired && local.selectedProject.remoteProjectID != nil && local.selectedProject.remoteProjectID == client.remoteSelectedProjectID { editor = (try? await client.readFile(file.path)) ?? "" }; local.select(file) }
        }
        .alert(localization.text("mobile.exit.title"), isPresented: $showingExitConfirmation) {
            Button(localization.text("mobile.exit.rememberAndExit"), role: .destructive) {
                confirmBeforeExit = false
                closeApp()
            }
            Button(localization.text("mobile.exit.action"), role: .destructive, action: closeApp)
            Button(localization.text("mobile.exit.cancel"), role: .cancel) { }
        } message: {
            Text(localization.text("mobile.exit.message"))
        }
    }

    private func requestExit() {
        if confirmBeforeExit {
            showingExitConfirmation = true
        } else {
            closeApp()
        }
    }

    private func switchProject(_ id: String) {
        guard id != local.selectedProjectID else { return }
        guard !agent.isRunning, loops.running == nil, !isImportingFolder else {
            local.localError = "Stop the active run before changing projects."
            return
        }
        agent.cancel()
        guard local.switchProject(id) else { return }
        agent.selectProject(id)
    }

    private func bindSelectedRemoteProject() {
        guard !agent.isRunning, loops.running == nil,
              let remoteID = client.remoteSelectedProjectID,
              let descriptor = client.remoteProjects.first(where: { $0.id == remoteID }),
              local.selectedProject.remoteProjectID != descriptor.id else { return }
        _ = local.bindRemoteProject(descriptor)
    }

    @MainActor
    private func closeApp() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
    }
}

private struct MobileNavigationDrawer: View {
    @EnvironmentObject private var localization: MobileLocalization

    let projects: [MobileProject]
    let selectedProjectID: String
    let conversations: [StoredMobileConversation]
    let selectedTab: Int
    let darkAppearance: Bool
    let settingsTitle: String
    let newConversationTitle: String
    let closeTitle: String
    let noChatsTitle: String
    let canChangeProject: Bool
    let canCreateConversation: Bool
    let onDismiss: () -> Void
    let onProjectSelected: (String) -> Void
    let onNewConversation: () -> Void
    let onConversationSelected: (String) -> Void
    let onAddProject: (String) -> Void
    let onSettings: () -> Void
    let isPersistent: Bool
    let onSelectTab: ((Int) -> Void)?
    @State private var expandedProjectID: String?
    @State private var isAddingProject = false
    @State private var newProjectName = ""

    init(
        projects: [MobileProject],
        selectedProjectID: String,
        conversations: [StoredMobileConversation],
        selectedTab: Int,
        darkAppearance: Bool,
        settingsTitle: String,
        newConversationTitle: String,
        closeTitle: String,
        noChatsTitle: String,
        canChangeProject: Bool,
        canCreateConversation: Bool,
        onDismiss: @escaping () -> Void,
        onProjectSelected: @escaping (String) -> Void,
        onNewConversation: @escaping () -> Void,
        onConversationSelected: @escaping (String) -> Void,
        onAddProject: @escaping (String) -> Void,
        onSettings: @escaping () -> Void,
        isPersistent: Bool = false,
        onSelectTab: ((Int) -> Void)? = nil
    ) {
        self.projects = projects
        self.selectedProjectID = selectedProjectID
        self.conversations = conversations
        self.selectedTab = selectedTab
        self.darkAppearance = darkAppearance
        self.settingsTitle = settingsTitle
        self.newConversationTitle = newConversationTitle
        self.closeTitle = closeTitle
        self.noChatsTitle = noChatsTitle
        self.canChangeProject = canChangeProject
        self.canCreateConversation = canCreateConversation
        self.onDismiss = onDismiss
        self.onProjectSelected = onProjectSelected
        self.onNewConversation = onNewConversation
        self.onConversationSelected = onConversationSelected
        self.onAddProject = onAddProject
        self.onSettings = onSettings
        self.isPersistent = isPersistent
        self.onSelectTab = onSelectTab
        _expandedProjectID = State(initialValue: selectedProjectID)
    }

    private var backgroundColor: Color { darkAppearance ? Color(red: 0.06, green: 0.06, blue: 0.07) : .white }

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = isPersistent ? proxy.size.width : min(proxy.size.width * 0.64, 260)
            ZStack(alignment: .leading) {
                if !isPersistent {
                    Color.black.opacity(darkAppearance ? 0.52 : 0.28)
                        .ignoresSafeArea()
                        .onTapGesture(perform: onDismiss)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image("HerNessLogo").resizable().scaledToFit().frame(width: 30, height: 30)
                        Text("HerNess").font(.title3.bold())
                        Spacer(minLength: 4)
                        if !isPersistent {
                            Button(action: onDismiss) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 40, height: 40)
                            }
                            .accessibilityLabel(closeTitle)
                        }
                    }
                    .padding(.bottom, 12)

                    Button(action: onNewConversation) {
                        Label(newConversationTitle, systemImage: "square.and.pencil")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(Color.accentColor.opacity(darkAppearance ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCreateConversation)
                    .opacity(canCreateConversation ? 1 : 0.5)
                    .padding(.bottom, 14)

                    HStack(spacing: 6) {
                        Text("Projects")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) { isAddingProject.toggle() }
                        } label: {
                            Image(systemName: isAddingProject ? "xmark" : "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canChangeProject)
                        .accessibilityLabel(isAddingProject ? closeTitle : "Add project")
                    }
                    .padding(.horizontal, 4)

                    if isAddingProject {
                        HStack(spacing: 8) {
                            TextField("New project", text: $newProjectName)
                                .textFieldStyle(.roundedBorder)
                                .submitLabel(.done)
                                .onSubmit(addProject)
                            Button(action: addProject) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                            }
                            .buttonStyle(.plain)
                            .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canChangeProject)
                        }
                        .padding(.bottom, 8)
                    }

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(projects) { project in
                                projectRow(project)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    Divider().padding(.vertical, 8)
                    if isPersistent {
                        VStack(spacing: 2) {
                            MobileDrawerItem(title: localization.text("mobile.nav.agent"), systemImage: "bubble.left.and.bubble.right", isSelected: selectedTab == 0, darkAppearance: darkAppearance) { onSelectTab?(0) }
                            MobileDrawerItem(title: localization.text("mobile.nav.code"), systemImage: "chevron.left.forwardslash.chevron.right", isSelected: selectedTab == 1, darkAppearance: darkAppearance) { onSelectTab?(1) }
                            MobileDrawerItem(title: localization.text("mobile.nav.terminal"), systemImage: "terminal", isSelected: selectedTab == 2, darkAppearance: darkAppearance) { onSelectTab?(2) }
                            MobileDrawerItem(title: localization.text("mobile.nav.preview"), systemImage: "globe", isSelected: selectedTab == 3, darkAppearance: darkAppearance) { onSelectTab?(3) }
                            MobileDrawerItem(title: settingsTitle, systemImage: "gearshape", isSelected: selectedTab == 4, darkAppearance: darkAppearance, action: onSettings)
                        }
                    } else {
                        MobileDrawerItem(title: settingsTitle, systemImage: "gearshape", isSelected: selectedTab == 4, darkAppearance: darkAppearance, action: onSettings)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, isPersistent ? 12 : 4)
                .padding(.bottom, 12)
                .frame(width: drawerWidth, height: proxy.size.height, alignment: .topLeading)
                .background {
                    Rectangle()
                        .fill(backgroundColor)
                        .ignoresSafeArea()
                }
                .transition(isPersistent ? .identity : .move(edge: .leading))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onChange(of: selectedProjectID) { _, id in expandedProjectID = id }
    }

    @ViewBuilder
    private func projectRow(_ project: MobileProject) -> some View {
        let isSelected = project.id == selectedProjectID
        let isExpanded = project.id == expandedProjectID
        Button {
            if isSelected {
                expandedProjectID = isExpanded ? nil : project.id
            } else {
                onProjectSelected(project.id)
                expandedProjectID = project.id
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(project.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(isSelected ? Color.accentColor.opacity(darkAppearance ? 0.18 : 0.09) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canChangeProject && !isSelected)
        .opacity((project.sidebarOpacity < 1 && !isSelected) ? 0.68 : 1)

        if isSelected && isExpanded {
            VStack(alignment: .leading, spacing: 2) {
                if conversations.isEmpty {
                    Text(noChatsTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)
                        .padding(.vertical, 6)
                } else {
                    ForEach(conversations) { conversation in
                        Button {
                            onConversationSelected(conversation.id)
                        } label: {
                            Text(conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? newConversationTitle : conversation.title)
                                .font(.system(size: 13))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 34)
                                .padding(.trailing, 6)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canChangeProject)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func addProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, canChangeProject else { return }
        onAddProject(name)
    }
}

private extension MobileProject {
    var sidebarOpacity: Double {
        FileManager.default.fileExists(atPath: localRoot) ? 1 : 0.55
    }
}

private struct MobileWorkspaceToolsDrawer: View {
    let projectName: String
    let selectedTab: Int
    let darkAppearance: Bool
    let filesTitle: String
    let terminalTitle: String
    let previewTitle: String
    let closeTitle: String
    let onDismiss: () -> Void
    let onSelect: (Int) -> Void

    private var backgroundColor: Color { darkAppearance ? .black : .white }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(darkAppearance ? 0.52 : 0.28)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(projectName).font(.headline).lineLimit(1)
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel(closeTitle)
                    }
                    .padding(.bottom, 8)

                    MobileDrawerItem(title: filesTitle, systemImage: "folder", isSelected: selectedTab == 1, darkAppearance: darkAppearance) { onSelect(1) }
                    MobileDrawerItem(title: terminalTitle, systemImage: "terminal", isSelected: selectedTab == 2, darkAppearance: darkAppearance) { onSelect(2) }
                    MobileDrawerItem(title: previewTitle, systemImage: "globe", isSelected: selectedTab == 3, darkAppearance: darkAppearance) { onSelect(3) }
                }
                .padding(18)
                .frame(width: min(proxy.size.width * 0.78, 300), alignment: .topLeading)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.24), radius: 22, x: -8, y: 0)
                .padding(.top, max(proxy.safeAreaInsets.top, 12) + 8)
                .padding(.trailing, 12)
                .transition(.move(edge: .trailing))
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
        }
        .ignoresSafeArea()
    }
}

private struct MobileDrawerItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let darkAppearance: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(
                    isSelected ? Color.primary.opacity(darkAppearance ? 0.16 : 0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}

struct EditorView: View {
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var local: LocalWorkspaceStore
    @EnvironmentObject private var localization: MobileLocalization
    let file: WorkspaceFile?
    @Binding var editor: String
    @State private var saved = false
    @State private var conflict = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(file?.path ?? localization.text("mobile.workspace.selectFile")).font(.headline); Spacer(); Button(localization.text("mobile.workspace.save")) { Task { await save() } }.disabled(file == nil) }.padding()
            Divider()
            TextEditor(text: $editor).font(.system(.body, design: .monospaced)).lineSpacing(3).padding(8).accessibilityLabel(localization.text("mobile.workspace.codeEditor"))
            if saved { Text(localization.text("mobile.workspace.saved")).font(.footnote).foregroundStyle(.green).padding(.horizontal) }
        }.alert(localization.text("mobile.workspace.conflict"), isPresented: $conflict) { Button(localization.text("mobile.workspace.keepLocalEdit"), role: .cancel) { } } message: { Text(localization.text("mobile.workspace.conflictMessage")) }
    }

    private func save() async {
        guard let file else { return }
        var remoteConflict = false
        if client.bootstrap != nil && local.selectedProject.remoteProjectID != nil && local.selectedProject.remoteProjectID == client.remoteSelectedProjectID {
            do {
                let response = try await client.command(kind: "write_file", payload: ["path": .string(file.path), "content": .string(editor), "expectedSha256": .string(file.sha256)], expectedRevision: client.snapshot?.revision)
                remoteConflict = response.status == "conflict"
            } catch {
                // A disconnected desktop must not prevent a local mirror save.
            }
        }
        do {
            local.select(path: file.path); local.updateCurrentText(editor); try local.saveCurrent()
            if remoteConflict { conflict = true } else { saved = true }
        } catch { client.errorMessage = error.localizedDescription }
    }

}

struct EventFeedView: View {
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var localization: MobileLocalization
    @Binding var prompt: String
    @State private var artifactText = ""
    @State private var showingArtifact = false
    @State private var artifactURL: URL?
    @State private var questionAnswer = ""
    var body: some View {
        NavigationStack {
            VStack {
                List(client.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(eventTitle(event)).font(.caption.bold()).foregroundStyle(.tint)
                        Text(eventDescription(event)).font(.system(.body, design: .monospaced)).lineLimit(8)
                        if event.kind == "approval.required", let approvalID = event.payload["approvalId"]?.string {
                            HStack {
                                Button(localization.text("permission.allowOnce")) { Task { try? await client.command(kind: "approve", payload: ["approvalId": .string(approvalID), "answer": .string("allowed-once")]) } }
                                Button(localization.text("permission.reject"), role: .destructive) { Task { try? await client.command(kind: "approve", payload: ["approvalId": .string(approvalID), "answer": .string("rejected")]) } }
                            }
                        }
                        if event.kind == "question.required", let questionID = event.payload["questionId"]?.string {
                            Text(localization.text("mobile.agent.clarification")).font(.headline)
                            Text(event.payload["questions"]?.string ?? localization.text("mobile.agent.answer")).font(.caption).foregroundStyle(.secondary)
                            TextField(localization.text("mobile.agent.answer"), text: $questionAnswer)
                            Button(localization.text("mobile.agent.answer")) {
                                let answer = questionAnswer
                                questionAnswer = ""
                                Task { try? await client.command(kind: "question", payload: ["questionId": .string(questionID), "answers": .array([.string(answer)])]) }
                            }.disabled(questionAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let artifactID = event.artifactId {
                            if event.kind == "artifact.ready" {
                                let path = event.payload["path"]?.string ?? "artifact.bin"
                                Button(localization.text("common.download")) {
                                    Task {
                                        if let data = try? await client.artifactData(artifactID) {
                                            let name = URL(fileURLWithPath: path).lastPathComponent
                                            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                                            try? data.write(to: url, options: .atomic)
                                            artifactURL = url
                                        }
                                    }
                                }
                                if path.lowercased().hasSuffix(".ipa") { Text(localization.text("mobile.artifact.ipaHint")).font(.caption).foregroundStyle(.secondary) }
                            } else {
                                Button(localization.text("mobile.artifact.openOutput")) { Task { if let value = try? await client.artifactText(artifactID) { artifactText = value; showingArtifact = true } } }
                            }
                        }
                    }
                }
                HStack { TextField(localization.text("mobile.agent.ask") + "…", text: $prompt, axis: .vertical).textFieldStyle(.roundedBorder); Button(localization.text("mobile.agent.send")) { let value = prompt; prompt = ""; Task { try? await client.command(kind: "prompt", payload: ["text": .string(value), "mode": .string("queue")]) } }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.padding()
                if let artifactURL { ShareLink(item: artifactURL, preview: SharePreview(artifactURL.lastPathComponent)) { Label(localization.text("mobile.artifact.share"), systemImage: "square.and.arrow.up") }.padding(.bottom, 6) }
            }.navigationTitle(localization.text("mobile.event.live")).sheet(isPresented: $showingArtifact) { NavigationStack { TextEditor(text: $artifactText).font(.system(.body, design: .monospaced)).padding().navigationTitle(localization.text("mobile.artifact.fullOutput")).navigationBarTitleDisplayMode(.inline) } }
        }
    }

    private func eventTitle(_ event: ControlEvent) -> String {
        switch event.kind {
        case "file.changed", "file.deleted": return localization.text("mobile.event.fileOperation")
        case "run.summary": return localization.text("mobile.event.runSummary")
        case "connection.changed": return localization.text("mobile.event.connectionChanged")
        default: return event.kind
        }
    }

    private func localizedFileOperation(_ raw: String?, kind: String) -> String {
        switch (raw ?? (kind == "file.deleted" ? "removed" : "changed")).lowercased() {
        case "added": return localization.text("mobile.event.added")
        case "modified", "changed": return localization.text("mobile.event.changed")
        case "deleted", "removed": return localization.text("mobile.event.removed")
        default: return raw ?? localization.text("mobile.event.changed")
        }
    }

    private func eventDescription(_ event: ControlEvent) -> String {
        let payload = event.payload
        switch event.kind {
        case "file.changed", "file.deleted":
            let operation = localizedFileOperation(payload["operation"]?.string, kind: event.kind)
            return localization.format("mobile.event.fileDetail", operation, payload["path"]?.string ?? localization.text("mobile.event.workspaceFile"))
        case "run.summary":
            return localization.format(
                "mobile.event.runDetail",
                payload["addedCount"]?.string ?? "0",
                payload["modifiedCount"]?.string ?? "0",
                payload["deletedCount"]?.string ?? "0",
                payload["cleanupNote"]?.string ?? localization.text("mobile.event.runFinished"))
        case "connection.changed":
            let previous = payload["previousConnectionLabel"]?.string ?? localization.text("mobile.event.previousConnection")
            let current = payload["currentConnectionLabel"]?.string ?? localization.text("mobile.event.currentConnection")
            switch payload["cleanupStatus"]?.string {
            case "verified":
                return localization.format("mobile.event.connectionVerified", previous)
            case "failed":
                return localization.format("mobile.event.connectionFailed", previous)
            case "preserved":
                return localization.format("mobile.event.connectionPreserved", previous, current)
            default:
                return localization.format("mobile.event.connectionDefault", previous, current)
            }
        default:
            return (payload["warning"]?.string.map { "⚠️ \($0)\n" } ?? "") + (payload["text"]?.string ?? payload["preview"]?.string ?? payload["output"]?.string ?? localization.text("mobile.event.live"))
        }
    }
}

struct PreviewTab: View {
    @EnvironmentObject private var localization: MobileLocalization
    @EnvironmentObject private var local: LocalWorkspaceStore
    @EnvironmentObject private var client: RemoteControlClient
    @Binding var url: String
    let onBack: () -> Void
    @StateObject private var browser = MobilePreviewBrowser()
    @State private var draftURL = ""
    @State private var port = "3000"
    @State private var message = ""

    private var remoteAvailable: Bool {
        client.isPaired && local.selectedProject.remoteProjectID != nil
            && local.selectedProject.remoteProjectID == client.remoteSelectedProjectID
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField(localization.text("mobile.preview.url"), text: $draftURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button(localization.text("mobile.preview.open"), action: openDraft)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 10)

                HStack {
                    Button { browser.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!browser.canGoBack)
                    Button { browser.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(!browser.canGoForward)
                    Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(browser.currentURL == nil)
                    Spacer()
                    if !browser.currentURLString.isEmpty {
                        Text(browser.currentURLString).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 10)

                if remoteAvailable {
                    HStack(spacing: 6) {
                        TextField(localization.text("mobile.preview.port"), text: $port)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 110)
                        Button(localization.text("mobile.preview.sharePort")) { Task { await sharePort() } }
                            .buttonStyle(.borderedProminent)
                        Button(localization.text("mobile.preview.stopSharing")) { Task { await stopSharing() } }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 10)
                    Text(localization.text("mobile.preview.publicHint"))
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                }

                if !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                }

                if browser.currentURL != nil {
                    WebPreview(browser: browser)
                } else {
                    ContentUnavailableView(
                        localization.text("mobile.preview.none"),
                        systemImage: "globe",
                        description: Text(localization.text("mobile.preview.description"))
                    )
                }
            }
            .navigationTitle(localization.text("mobile.preview.title"))
            .task(id: local.selectedProject.id) {
                let key = "pages.preview.\(local.selectedProject.id)"
                let stored = UserDefaults.standard.string(forKey: key) ?? ""
                let candidate = url.isEmpty ? stored : url
                draftURL = candidate
                if let target = normalizedURL(candidate) { browser.load(target) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: localization.isRTL ? "chevron.right" : "chevron.left")
                    }
                    .accessibilityLabel(localization.text("intro.back"))
                }
            }
        }
    }

    private func normalizedURL(_ candidate: String) -> URL? {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let normalized = value.hasPrefix("http://") || value.hasPrefix("https://") ? value : "https://" + value
        guard let target = URL(string: normalized), let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme), target.host != nil else { return nil }
        return target
    }

    private func openDraft() {
        guard let target = normalizedURL(draftURL) else { message = localization.text("mobile.preview.error"); return }
        draftURL = target.absoluteString
        url = target.absoluteString
        UserDefaults.standard.set(target.absoluteString, forKey: "pages.preview.\(local.selectedProject.id)")
        browser.load(target)
        message = ""
    }

    private func sharePort() async {
        guard let value = Int(port), (1...65_535).contains(value) else { message = localization.text("mobile.preview.error"); return }
        do {
            let response = try await client.command(kind: "preview_tunnel", payload: ["action": .string("start"), "port": .number(Double(value))])
            if response.status == "approval-required" { message = localization.text("mobile.preview.approvalHint"); return }
            if let error = response.error { message = error; return }
            guard case .object(let result) = response.result, let address = result["url"]?.string else { message = localization.text("mobile.preview.error"); return }
            draftURL = address
            openDraft()
        } catch { message = error.localizedDescription }
    }

    private func stopSharing() async {
        do {
            _ = try await client.command(kind: "preview_tunnel", payload: ["action": .string("stop")])
            message = ""
        } catch { message = error.localizedDescription }
    }
}

@MainActor
final class MobilePreviewBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published private(set) var currentURL: URL?
    @Published private(set) var currentURLString = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    override init() {
        webView = WKWebView(frame: .zero)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL) {
        guard currentURL != url else { return }
        currentURL = url
        currentURLString = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateNavigationState() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { updateNavigationState() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { updateNavigationState() }

    private func updateNavigationState() {
        currentURL = webView.url ?? currentURL
        currentURLString = webView.url?.absoluteString ?? currentURLString
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

struct WebPreview: UIViewRepresentable {
    @ObservedObject var browser: MobilePreviewBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard let url = browser.currentURL, view.url != url else { return }
        view.load(URLRequest(url: url))
    }
}

struct SettingsView: View {
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var localization: MobileLocalization
    @EnvironmentObject private var agent: MobileAgent
    @EnvironmentObject private var github: GitHubOAuth
    @EnvironmentObject private var chatGPT: ChatGPTOAuth
    @Binding var previewURL: String
    @Binding var confirmBeforeExit: Bool
    @Binding var prompt: String
    let onExit: () -> Void
    let onBack: () -> Void
    @State private var pagesAccountId = UserDefaults.standard.string(forKey: "herness.pages.accountId") ?? ""
    @State private var pagesProject = UserDefaults.standard.string(forKey: "herness.pages.project") ?? ""
    @State private var pagesToken = ""
    @State private var pagesStatus = ""
    @State private var pagesBusy = false
    @State private var providerKey = ""
    @State private var providerKeyStored = false
    @State private var githubOwner = ""
    @State private var githubRepository = ""
    @State private var githubBase = "main"
    @State private var githubBranch = "herness/mobile-\(Int(Date().timeIntervalSince1970))"
    @State private var githubStatus = ""
    @State private var repoSlug = ""
    @State private var repositories: [GitHubRepository] = []
    @State private var branches: [String] = []
    @State private var sandboxName = ""
    @EnvironmentObject private var local: LocalWorkspaceStore
    @EnvironmentObject private var legal: LegalModel
    @EnvironmentObject private var theme: MobileTheme

    private func providerCredential(for provider: String) -> String {
        client.phoneSecret("provider.\(provider)")
    }

    private var selectedProvider: MobileProviderDefinition {
        MobileAgent.definition(for: agent.provider) ?? MobileAgent.providerDefinitions[0]
    }

    private var hasProviderCredential: Bool {
        providerKeyStored
    }

    /// More sections than a phone screen can show at once, so the settings form
    /// is grouped behind a segmented tab bar pinned above the list.
    private enum SettingsTab: String, CaseIterable {
        case general, providers, accounts, repository, tools
    }

    @State private var settingsTab: SettingsTab = .general

    private func settingsTabTitle(_ tab: SettingsTab) -> String {
        switch tab {
        case .general: return localization.text("settings.tab.general")
        case .providers: return localization.text("settings.tab.providers")
        case .accounts: return localization.text("settings.tab.accounts")
        case .repository: return localization.text("settings.tab.repository")
        case .tools: return localization.text("settings.tab.tools")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if settingsTab == .general {
                    Section(localization.text("mobile.exit.settingsSection")) {
                        Toggle(localization.text("mobile.exit.askBeforeExit"), isOn: $confirmBeforeExit)
                        Text(localization.text("mobile.exit.settingsHint"))
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(localization.text("mobile.exit.actionLabel"), role: .destructive, action: onExit)
                    }
                    Section(localization.text("mobile.agent.planSettingsSection")) {
                        Toggle(localization.text("mobile.agent.autoApprovePlans"), isOn: Binding(
                            get: { agent.autoApprovePlans },
                            set: { agent.setAutoApprovePlans($0) }
                        ))
                        Text(localization.text("mobile.agent.autoApprovePlansHint"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section(localization.text("mobile.agent.subagentsSection")) {
                        Toggle(localization.text("mobile.agent.subagents"), isOn: Binding(
                            get: { agent.subagentsEnabled },
                            set: { agent.setSubagentsEnabled($0) }
                        ))
                        Text(localization.text("mobile.agent.subagentsHint"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section(localization.text("settings.compactTrigger")) {
                        HStack(spacing: 8) {
                            Button {
                                agent.setContextCompactionThresholdPercent(agent.contextCompactionThresholdPercent - 1)
                            } label: {
                                Image(systemName: "minus")
                            }
                            .buttonStyle(.bordered)
                            TextField("", value: Binding(
                                get: { agent.contextCompactionThresholdPercent },
                                set: { agent.setContextCompactionThresholdPercent($0) }
                            ), format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.center)
                                .frame(width: 72)
                                .textFieldStyle(.plain)
                                .accessibilityLabel(localization.text("settings.compactTrigger"))
                            Text("%")
                            Button {
                                agent.setContextCompactionThresholdPercent(agent.contextCompactionThresholdPercent + 1)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.bordered)
                            Spacer(minLength: 0)
                        }
                    }
                    Section(localization.text("intro.language")) {
                        HStack {
                            Text(localization.selected.nativeName)
                            Spacer()
                            SettingsLanguageMenu(darkAppearance: theme.isDark)
                        }
                    }
                    Section(localization.text("settings.theme") == "settings.theme" ? "Appearance" : localization.text("settings.theme")) {
                        Toggle("Dark Mode", isOn: Binding(
                            get: { theme.isDark },
                            set: { _ in theme.toggle() }
                        ))
                    }
                    Section {
                        NavigationLink(localization.text("legal.title")) {
                            LegalSettingsView(legal: legal)
                        }
                    }
                }

                if settingsTab == .providers {
                    Section(localization.text("settings.tab.providers")) {
                        Picker(localization.text("router.provider"), selection: Binding(get: { agent.provider }, set: { agent.setProvider($0) })) {
                            ForEach(MobileAgent.providerDefinitions) { provider in
                                HStack(spacing: 8) {
                                    MobileProviderBrandMark(providerID: provider.id, size: 18)
                                    Text(provider.name)
                                }.tag(provider.id)
                            }
                        }
                        HStack {
                            HStack(spacing: 8) {
                                MobileProviderBrandMark(providerID: selectedProvider.id, size: 21)
                                Text(selectedProvider.name)
                            }
                            Spacer()
                            Text(localization.text(
                                selectedProvider.requiresAPIKey
                                    ? (hasProviderCredential ? "mobile.settings.providerStored" : "mobile.settings.providerMissing")
                                    : "mobile.settings.providerOAuth"
                            ))
                                .font(.caption)
                                .foregroundStyle(!selectedProvider.requiresAPIKey || hasProviderCredential ? .green : .secondary)
                        }
                        Picker(localization.text("modelPicker.model"), selection: Binding(get: { agent.model }, set: { agent.setModel($0) })) {
                            ForEach(agent.availableModels(for: agent.provider), id: \.self) { model in
                                if let mark = MobileProviderMarkCatalog.imageName(for: agent.provider) {
                                    Label(model, image: mark).tag(model)
                                } else {
                                    Text(model).tag(model)
                                }
                            }
                        }
                        if selectedProvider.requiresAPIKey {
                            SecureField(localization.text("mobile.settings.providerKey"), text: $providerKey)
                            HStack {
                                Button(localization.text("mobile.settings.saveProviderKey")) {
                                    client.savePhoneSecret(providerKey, key: "provider.\(agent.provider)")
                                    providerKeyStored = !providerKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    Task { await agent.refreshModelsIfNeeded(force: true) }
                                }
                                .disabled(providerKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                if hasProviderCredential {
                                    Button(localization.text("common.remove"), role: .destructive) {
                                        client.savePhoneSecret("", key: "provider.\(agent.provider)")
                                        providerKey = ""
                                        providerKeyStored = false
                                    }
                                }
                            }
                        } else {
                            Text(localization.text("mobile.settings.gptHint"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text(localization.text("mobile.settings.providerKeyHint")).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if settingsTab == .accounts {
                    Section(localization.text("mobile.settings.gptAccount")) {
                        if !chatGPT.accounts.isEmpty {
                            Picker(localization.text("mobile.settings.gptAccount"), selection: Binding(
                                get: { chatGPT.accountID },
                                set: { chatGPT.selectAccount($0) }
                            )) {
                                ForEach(chatGPT.accounts) { account in
                                    Text(account.title).tag(account.id)
                                }
                            }
                            Label("ChatGPT \(localization.text("mobile.settings.connected"))", systemImage: "checkmark.circle.fill")
                            Button(localization.text("mobile.settings.signOut"), role: .destructive) { chatGPT.signOut() }
                        }
                        Button(chatGPT.isSigningIn ? localization.text("mobile.settings.waitingChatGPT") : localization.text("mobile.settings.signInChatGPT")) { chatGPT.start() }
                            .disabled(chatGPT.isSigningIn)
                        if !chatGPT.status.isEmpty { Text(chatGPT.status).font(.footnote).foregroundStyle(.secondary) }
                        Text(localization.text("mobile.settings.gptHint")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section(localization.text("mobile.settings.githubAccount")) {
                        if github.accessToken.isEmpty {
                            Button(github.isSigningIn ? localization.text("mobile.settings.waitingGitHub") : localization.text("mobile.settings.signInGitHub")) { github.start() }.disabled(github.isSigningIn)
                        } else {
                            Label("GitHub \(localization.text("mobile.settings.connected"))", systemImage: "checkmark.circle.fill")
                            Button(localization.text("mobile.settings.signOut"), role: .destructive) { github.signOut() }
                        }
                        if !github.status.isEmpty { Text(github.status).font(.footnote).foregroundStyle(.secondary) }
                        Text(localization.text("mobile.settings.githubHint")).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if settingsTab == .repository {
                    Section(localization.text("mobile.settings.offlineRepository")) {
                        Button(localization.text("mobile.settings.loadRepositories")) { Task { await loadRepositories() } }.disabled(github.accessToken.isEmpty)
                        if !repositories.isEmpty {
                            Picker(localization.text("mobile.settings.repository"), selection: $repoSlug) {
                                Text(localization.text("mobile.settings.chooseRepository")).tag("")
                                ForEach(repositories) { Text($0.fullName).tag($0.fullName) }
                            }
                        } else {
                            TextField(localization.text("mobile.settings.ownerRepository"), text: $repoSlug).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        if !branches.isEmpty {
                            Picker(localization.text("mobile.settings.branch"), selection: $githubBase) { ForEach(branches, id: \.self) { Text($0).tag($0) } }
                        } else {
                            TextField(localization.text("mobile.settings.branch"), text: $githubBase).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        Button(localization.text("mobile.settings.clone")) { Task { await clone() } }.disabled(github.accessToken.isEmpty || repoSlug.isEmpty)
                        if !local.cloneStatus.isEmpty { Text(local.cloneStatus).font(.footnote).foregroundStyle(.secondary) }
                        Text(localization.text("mobile.settings.selectedBranchHint")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section(localization.text("settings.sandbox")) {
                        if let active = local.activeSandbox {
                            Label("\(localization.text("settings.sandboxOn")): \(active.name)", systemImage: "shippingbox.fill").foregroundStyle(.green)
                            Text("\(localization.text("settings.sandboxBranch")): \(active.branch)").font(.caption).foregroundStyle(.secondary)
                            Text(localization.text("settings.sandboxOn")).font(.footnote).foregroundStyle(.secondary)
                            if let notice = local.sandboxNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                            Button(localization.text("settings.sandboxMerge")) {
                                do { _ = try local.exitSandbox(merge: true) } catch { local.localError = error.localizedDescription }
                            }
                            Button(localization.text("settings.sandboxDiscard"), role: .destructive) {
                                do { _ = try local.exitSandbox(merge: false) } catch { local.localError = error.localizedDescription }
                            }
                            if let err = local.localError { Text(err).font(.footnote).foregroundStyle(.red) }
                        } else {
                            TextField(localization.text("settings.sandboxName"), text: $sandboxName).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button(localization.text("settings.sandboxEnter")) {
                                do { try local.enterSandbox(name: sandboxName); sandboxName = "" } catch { local.localError = error.localizedDescription }
                            }.disabled(sandboxName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if let notice = local.sandboxNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                            let others = local.sandboxes()
                            if !others.isEmpty {
                                ForEach(others, id: \.name) { sb in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(sb.name).font(.body)
                                            Text(sb.branch).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button(localization.text("settings.sandboxDiscard"), role: .destructive) { do { try local.discardSandbox(sb) } catch { local.localError = error.localizedDescription } }
                                    }
                                }
                            } else {
                                Text(localization.text("settings.sandboxOff")).font(.footnote).foregroundStyle(.secondary)
                            }
                            if let err = local.localError { Text(err).font(.footnote).foregroundStyle(.red) }
                            Text(localization.text("settings.sandboxOrigin")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section(localization.text("mobile.settings.githubChanges")) {
                        TextField(localization.text("mobile.settings.owner"), text: $githubOwner).textInputAutocapitalization(.never)
                        TextField(localization.text("mobile.settings.repository"), text: $githubRepository).textInputAutocapitalization(.never)
                        TextField(localization.text("mobile.settings.baseBranch"), text: $githubBase).textInputAutocapitalization(.never)
                        TextField(localization.text("mobile.settings.newBranch"), text: $githubBranch).textInputAutocapitalization(.never)
                        Button(localization.text("mobile.settings.commitPR")) { Task { await createPullRequest() } }.disabled(github.accessToken.isEmpty || githubOwner.isEmpty || githubRepository.isEmpty)
                        if !githubStatus.isEmpty { Text(githubStatus).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section(localization.text("mobile.settings.snapshotExclusions")) { ForEach(client.snapshot?.excluded ?? []) { item in VStack(alignment: .leading) { Text(item.path); Text(item.reason).font(.caption).foregroundStyle(.secondary) } } }
                }

                if settingsTab == .tools {
                    Section(localization.text("mobile.settings.remoteRunner")) {
                        if client.isPaired {
                            Label(localization.text("mobile.settings.desktopPaired"), systemImage: "desktopcomputer").foregroundStyle(.green)
                            Text(localization.text("mobile.settings.remoteRunnerHint")).font(.footnote).foregroundStyle(.secondary)
                            if let caps = client.bootstrap?.capabilities.joined(separator: ", "), !caps.isEmpty { Text("Capabilities: \(caps)").font(.caption).foregroundStyle(.secondary) }
                        } else {
                            Label(localization.text("mobile.settings.noDesktop"), systemImage: "wifi.slash").foregroundStyle(.orange)
                            Text(localization.text("mobile.settings.remoteRunnerHint")).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(localization.text("mobile.settings.accessModeHint")).font(.caption).foregroundStyle(.secondary)
                    }
                    Section(localization.text("mobile.event.live")) {
                        NavigationLink(localization.text("mobile.event.live")) {
                            EventFeedView(prompt: $prompt)
                        }
                        Text("Approvals and desktop questions appear here while a command waits.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Sites (Cloudflare Pages)") {
                        TextField("Account ID", text: $pagesAccountId).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: pagesAccountId) { _, value in UserDefaults.standard.set(value, forKey: "herness.pages.accountId") }
                        TextField("Pages project name", text: $pagesProject).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: pagesProject) { _, value in UserDefaults.standard.set(value, forKey: "herness.pages.project") }
                        SecureField("API token (stored in phone keychain)", text: $pagesToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onAppear {
                                let stored = client.phoneSecret("pages.token")
                                if stored.isEmpty { pagesToken = "" } else { pagesToken = stored }
                            }
                        Button("Deploy workspace") {
                            client.savePhoneSecret(pagesToken, key: "pages.token")
                            pagesBusy = true
                            pagesStatus = "Collecting files…"
                            Task {
                                pagesStatus = await deployToPages()
                                pagesBusy = false
                            }
                        }
                        .disabled(pagesBusy || pagesAccountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pagesProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pagesToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !pagesStatus.isEmpty { Text(pagesStatus).font(.footnote).foregroundStyle(.secondary) }
                    }
                    LoopsView()
                    MCPSettingsView()
                    PluginsView()
                    Section(localization.text("mobile.settings.preview")) { TextField(localization.text("mobile.settings.pagesURL"), text: $previewURL).textInputAutocapitalization(.never) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.isDark ? Color.black : Color.white)
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker(localization.text("settings.title"), selection: $settingsTab) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Text(settingsTabTitle(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.isDark ? Color.black : Color.white)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: localization.isRTL ? "chevron.right" : "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(localization.text("intro.back"))
                }
            }
            .toolbarBackground(theme.isDark ? Color.black : Color.white, for: .navigationBar)
            .toolbarColorScheme(theme.isDark ? .dark : .light, for: .navigationBar)
            .onAppear {
                providerKey = providerCredential(for: agent.provider)
                providerKeyStored = !providerKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Task { await agent.refreshModelsIfNeeded() }
                loadProjectRepository()
                if !github.accessToken.isEmpty { Task { await loadRepositories() } }
            }.onChange(of: agent.provider) { _, provider in
                providerKey = providerCredential(for: provider)
                providerKeyStored = !providerKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Task { await agent.refreshModelsIfNeeded() }
            }.onChange(of: chatGPT.accountID) { _, _ in
                if agent.provider == "gpt" { Task { await agent.refreshModelsIfNeeded(force: true) } }
            }.onChange(of: local.selectedProjectID) { _, _ in
                loadProjectRepository()
            }
        }
    }

    private func loadProjectRepository() {
        let stored = local.selectedProject.repository.flatMap { RepoCoordinates.parse($0, branch: local.selectedProject.branch ?? "main") }
            ?? RepoCoordinates.load()
        if stored.isComplete {
            repoSlug = stored.slug
            githubOwner = stored.owner
            githubRepository = stored.repository
            githubBase = stored.branch
        }
    }

    private func clone() async {
        guard let repo = RepoCoordinates.parse(repoSlug, branch: githubBase.isEmpty ? "main" : githubBase) else {
            local.localError = localization.text("mobile.settings.repositoryInputError")
            return
        }
        githubOwner = repo.owner; githubRepository = repo.repository
        agent.selectRepository(repo)
        await local.clone(repo, token: github.accessToken, git: MobileGitClient(root: local.root, token: { SecureStore().read("oauth.github.access") ?? "" }))
    }

    private func loadRepositories() async {
        do {
            repositories = try await GitHubClient(token: github.accessToken).repositories()
            if let selected = repositories.first(where: { $0.fullName == repoSlug }) {
                repoSlug = selected.fullName; githubOwner = selected.owner; githubRepository = selected.name; githubBase = selected.defaultBranch
                branches = try await GitHubClient(token: github.accessToken).branches(owner: selected.owner, repository: selected.name)
            }
        } catch { githubStatus = error.localizedDescription }
    }

    private func createPullRequest() async {
        let changes = local.githubChanges()
        guard !changes.isEmpty else { githubStatus = localization.text("mobile.settings.noLocalChanges"); return }
        let branch = githubBranch.isEmpty ? "herness/mobile-\(Int(Date().timeIntervalSince1970))" : githubBranch
        do {
            let url = try await GitHubClient(token: github.accessToken).commitAndOpenPullRequest(owner: githubOwner, repository: githubRepository, base: githubBase, branch: branch, message: "Update from HerNess mobile", changes: changes, title: "HerNess mobile changes", body: "Created from HerNess offline workspace mirror.")
            githubStatus = url.absoluteString
        } catch { githubStatus = error.localizedDescription }
    }

    /// Collects the workspace with the same exclusions the agent sees, applies
    /// size caps so a phone-sized upload cannot blow past Cloudflare's limits,
    /// then hands the files to the direct-upload endpoint.
    private func deployToPages() async -> String {
        let limits = PagesDeployLimits()
        do {
            var bundle: [String: Data] = [:]
            var total = 0
            var skipped = 0
            for file in try local.agentFiles() {
                guard let url = try? local.resolve(file.path) else { continue }
                let data = try Data(contentsOf: url)
                if data.count > limits.maxFileBytes { skipped += 1; continue }
                if total + data.count > limits.maxTotalBytes { skipped += 1; continue }
                if bundle.count >= limits.maxFileCount { skipped += 1; continue }
                bundle[file.path] = data
                total += data.count
            }
            guard !bundle.isEmpty else { return "No files to deploy." }
            let client = PagesDeployClient(accountId: pagesAccountId.trimmingCharacters(in: .whitespacesAndNewlines), apiToken: pagesToken.trimmingCharacters(in: .whitespacesAndNewlines))
            let url = try await client.deploy(project: pagesProject.trimmingCharacters(in: .whitespacesAndNewlines), files: bundle)
            previewURL = url.absoluteString
            UserDefaults.standard.set(url.absoluteString, forKey: "pages.preview.\(local.selectedProjectID)")
            let note = skipped > 0 ? " (\(skipped) files skipped by size limits)." : "."
            return "Deployed \(bundle.count) files to \(url.absoluteString)\(note)"
        } catch {
            return "Deploy failed: \(error.localizedDescription)"
        }
    }
}

/// Phone-side upload caps: keep a single file at 5 MB and the whole bundle at
/// 50 MB so a large workspace fails loudly instead of timing out on cellular.
private struct PagesDeployLimits {
    let maxFileBytes = 5 * 1024 * 1024
    let maxTotalBytes = 50 * 1024 * 1024
    let maxFileCount = 5000
}
