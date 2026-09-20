// Copyright (c) 2026 DOTS
// Right-hand tabbed dock: Review (real git), Terminal, Browser, Files.

import SwiftUI
import WebKit
import DotsHarnessCore

// MARK: - State

@MainActor
final class RightDockState: ObservableObject {
    enum Kind: Equatable {
        case review
        case terminal(session: UUID, key: String)
        case files
        case browser
    }

    struct Tab: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
    }

    @Published var isVisible = false
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?

    func perform(_ action: KeyboardShortcutAction, model: AppModel) {
        switch action {
        case .review: add(.review, unique: true)
        case .files: add(.files, unique: true)
        case .browser: add(.browser, unique: false)
        case .terminal: openTerminal(model: model)
        case .sideChat: model.newConversation()
        case .simulator:
            model.isTasksPresented = false
            model.isSimulatorPresented = true
        case .toggleSidebar, .pullRequests, .scheduled: break
        }
    }

    private func add(_ kind: Kind, unique: Bool) {
        isVisible = true
        if unique, let existing = tabs.first(where: { $0.kind == kind }) {
            selectedID = existing.id
            return
        }
        let tab = Tab(kind: kind)
        tabs.append(tab)
        selectedID = tab.id
    }

    private func openTerminal(model: AppModel) {
        let key = model.terminalWorkspaceKey
        guard !key.isEmpty else {
            if !model.isRemoteWorkLocation { model.chooseWorkspace() }
            return
        }
        guard let session = model.terminalManager.openSession(
            for: key,
            executionPolicy: model.activeArea == .chat
                ? model.chatTerminalExecutionPolicy
                : (model.remoteWorkspace == nil ? model.sandboxExecutionPolicy : nil),
            remoteTarget: model.remoteWorkspace
        ) else { return }
        add(.terminal(session: session.id, key: key), unique: false)
    }

    func close(_ tab: Tab, model: AppModel) {
        if case .terminal(let id, let key) = tab.kind,
           let session = model.terminalManager.sessions(for: key).first(where: { $0.id == id }) {
            model.terminalManager.closeSession(session, for: key)
        }
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if selectedID == tab.id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }
}

private let dockActions: [KeyboardShortcutAction] = [.review, .terminal, .browser, .files, .sideChat, .simulator]

// MARK: - Dock

struct RightDockView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: RightDockState
    @State private var isMenuPresented = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(state.tabs) { tab in tabButton(tab) }
                }
            }
            .frame(maxWidth: .infinity)

            Button { isMenuPresented.toggle() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isMenuPresented, arrowEdge: .bottom) { pickerList(inPopover: true) }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private func tabButton(_ tab: RightDockState.Tab) -> some View {
        let selected = tab.id == state.selectedID
        return HStack(spacing: 6) {
            Button { state.selectedID = tab.id } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon(tab.kind)).font(.system(size: 12))
                    Text(title(tab.kind)).font(.system(size: 13)).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Button { state.close(tab, model: model) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            Color.primary.opacity(selected ? 0.10 : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func icon(_ kind: RightDockState.Kind) -> String {
        switch kind {
        case .review: return KeyboardShortcutAction.review.systemImage
        case .terminal: return "terminal"
        case .files: return "folder"
        case .browser: return "globe"
        }
    }

    private func title(_ kind: RightDockState.Kind) -> String {
        switch kind {
        case .review: return KeyboardShortcutAction.review.title
        case .terminal: return KeyboardShortcutAction.terminal.title
        case .files: return KeyboardShortcutAction.files.title
        case .browser: return KeyboardShortcutAction.browser.title
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tab = state.tabs.first(where: { $0.id == state.selectedID }) {
            switch tab.kind {
            case .review: DockReviewView(model: model).id(model.workspacePath)
            case .terminal(let id, let key): DockTerminalView(manager: model.terminalManager, key: key, id: id)
            case .files: DockFilesView(model: model).id(model.workspacePath)
            case .browser: DockBrowserView().id(tab.id)
            }
        } else {
            VStack { Spacer(); pickerList(inPopover: false); Spacer() }
                .padding(.horizontal, 20)
                .frame(maxHeight: .infinity)
        }
    }

    private func pickerList(inPopover: Bool) -> some View {
        VStack(spacing: 8) {
            ForEach(dockActions) { action in
                if action != .files || model.activeArea == .coding {
                    PaneChoiceRow(
                        systemImage: action.systemImage,
                        title: action.title,
                        shortcut: model.shortcut(for: action).displayValue
                    ) {
                        isMenuPresented = false
                        state.perform(action, model: model)
                    }
                }
            }
        }
        .padding(inPopover ? 10 : 0)
        .frame(width: inPopover ? 300 : nil)
    }
}

// MARK: - Terminal

private struct DockTerminalView: View {
    @ObservedObject var manager: TerminalManager
    let key: String
    let id: UUID

    var body: some View {
        if let session = manager.sessions(for: key).first(where: { $0.id == id }) {
            TerminalView(session: session)
        } else {
            Text(AppCopy.text("conversation.startingShell"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Git

private enum Git {
    static func run(_ args: [String], at path: String) async -> (ok: Bool, out: String) {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "core.quotepath=false"] + args
            process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = env
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return (false, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        }.value
    }
}

private struct ReviewChange: Identifiable, Hashable {
    let path: String
    let status: String   // M, A, D, ?
    let added: Int?
    let removed: Int?
    var id: String { path }
}

@MainActor
private final class ReviewModel: ObservableObject {
    @Published var changes: [ReviewChange] = []
    @Published var branch = ""
    @Published var branches: [String] = []
    @Published var selected: String?
    @Published var diffLines: [String] = []
    @Published var error: String?
    @Published var busy = false
    @Published var notRepo = false

    let path: String
    init(path: String) { self.path = path }

    var added: Int { changes.compactMap(\.added).reduce(0, +) }
    var removed: Int { changes.compactMap(\.removed).reduce(0, +) }

    func refresh() async {
        guard (await Git.run(["rev-parse", "--is-inside-work-tree"], at: path)).ok else {
            notRepo = true
            return
        }
        notRepo = false
        var name = (await Git.run(["branch", "--show-current"], at: path)).out.trimmed
        if name.isEmpty { name = (await Git.run(["rev-parse", "--short", "HEAD"], at: path)).out.trimmed }
        branch = name
        branches = (await Git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], at: path))
            .out.split(separator: "\n").map(String.init)

        var stats: [String: (Int?, Int?)] = [:]
        for line in (await Git.run(["diff", "HEAD", "--no-renames", "--numstat"], at: path)).out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            if parts.count == 3 { stats[parts[2]] = (Int(parts[0]), Int(parts[1])) }
        }
        var result: [ReviewChange] = []
        for line in (await Git.run(["diff", "HEAD", "--no-renames", "--name-status"], at: path)).out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let s = stats[parts[1]]
            result.append(ReviewChange(path: parts[1], status: String(parts[0].prefix(1)), added: s?.0, removed: s?.1))
        }
        let known = Set(result.map(\.path))
        for file in (await Git.run(["ls-files", "--others", "--exclude-standard"], at: path)).out.split(separator: "\n")
        where !known.contains(String(file)) {
            result.append(ReviewChange(path: String(file), status: "?", added: nil, removed: nil))
        }
        changes = result.sorted { $0.path < $1.path }
        if let current = selected, !changes.contains(where: { $0.id == current }) { selected = nil }
        await loadDiff()
    }

    func loadDiff() async {
        guard let selected, let change = changes.first(where: { $0.id == selected }) else {
            diffLines = []
            return
        }
        var text: String
        if change.status == "?" {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(selected))) ?? Data()
            text = String(decoding: data.prefix(300_000), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        } else {
            text = (await Git.run(["diff", "HEAD", "--no-renames", "--", selected], at: path)).out
        }
        diffLines = text.prefix(400_000).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func select(_ id: String) async {
        selected = id
        await loadDiff()
    }

    func checkout(_ name: String) async {
        await run(["switch", name])
    }

    func commit(message: String) async {
        busy = true
        defer { busy = false }
        let add = await Git.run(["add", "-A"], at: path)
        guard add.ok else { error = add.out; return }
        let result = await Git.run(["commit", "-m", message], at: path)
        error = result.ok ? nil : result.out
        await refresh()
    }

    func run(_ args: [String]) async {
        busy = true
        defer { busy = false }
        let result = await Git.run(args, at: path)
        error = result.ok ? nil : result.out
        await refresh()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Review

private struct DockReviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.workspacePath.isEmpty || model.remoteWorkspace != nil {
            DockEmptyWorkspace(model: model)
        } else {
            ReviewBody(model: model, review: ReviewModel(path: model.workspacePath))
        }
    }
}

private struct DockEmptyWorkspace: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Text(AppCopy.text("dock.noWorkspace")).foregroundStyle(.secondary)
            Button(AppCopy.text("conversation.workspace")) { model.chooseWorkspace() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReviewBody: View {
    @ObservedObject var model: AppModel
    @StateObject var review: ReviewModel
    @State private var commitPresented = false
    @State private var message = ""

    init(model: AppModel, review: ReviewModel) {
        self.model = model
        self._review = StateObject(wrappedValue: review)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if review.notRepo {
                Text(AppCopy.text("dock.notRepo"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let error = review.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: 90)
                }
                VSplitView {
                    changeList.frame(minHeight: 120, idealHeight: 200)
                    diffView.frame(minHeight: 160)
                }
            }
        }
        .task { await review.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(review.branches, id: \.self) { name in
                    Button(name) { Task { await review.checkout(name) } }
                }
            } label: {
                Label(review.branch.isEmpty ? AppCopy.text("dock.branch") : review.branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Text("+\(review.added)").foregroundStyle(.green)
            Text("-\(review.removed)").foregroundStyle(.red)

            Spacer(minLength: 0)

            if review.busy { ProgressView().controlSize(.small) }
            Button { Task { await review.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .help(AppCopy.text("dock.refresh"))

            Menu {
                Button(AppCopy.text("dock.commit")) { commitPresented = true }
                Button(AppCopy.text("dock.push")) { Task { await review.run(["push"]) } }
                Button(AppCopy.text("dock.fetch")) { Task { await review.run(["fetch"]) } }
            } label: {
                Label(AppCopy.text("dock.commitOrPush"), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(review.busy)
            .popover(isPresented: $commitPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(AppCopy.text("dock.commitMessage"), text: $message)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                    Button(AppCopy.text("dock.commit")) {
                        let text = message.trimmed
                        commitPresented = false
                        message = ""
                        Task { await review.commit(message: text) }
                    }
                    .disabled(message.trimmed.isEmpty)
                }
                .padding(12)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var changeList: some View {
        Group {
            if review.changes.isEmpty {
                Text(AppCopy.text("dock.noChanges"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(review.changes) { change in changeRow(change) }
                    }
                }
            }
        }
    }

    private func changeRow(_ change: ReviewChange) -> some View {
        let url = URL(fileURLWithPath: change.path)
        let dir = url.deletingLastPathComponent().path
        return Button { Task { await review.select(change.id) } } label: {
            HStack(spacing: 8) {
                Text(change.status)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(color(change.status))
                    .frame(width: 16)
                Text(url.lastPathComponent).lineLimit(1)
                if dir != "/" && dir != "." {
                    Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
                if let a = change.added { Text("+\(a)").foregroundStyle(.green) }
                if let r = change.removed { Text("-\(r)").foregroundStyle(.red) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(review.selected == change.id ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "A", "?": return .green
        case "D": return .red
        default: return .orange
        }
    }

    private var diffView: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(review.diffLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(background(line))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func background(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Color.green.opacity(0.16) }
        if line.hasPrefix("-") { return Color.red.opacity(0.16) }
        if line.hasPrefix("@@") { return Color.blue.opacity(0.14) }
        return .clear
    }
}

// MARK: - Files

private struct FileEntry: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }

    static func children(of url: URL) -> [FileEntry] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return items.map {
            FileEntry(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
}

private struct DockFilesView: View {
    @ObservedObject var model: AppModel
    @State private var selected: URL?
    @State private var filter = ""
    @State private var matches: [FileEntry] = []
    @State private var preview = ""

    var body: some View {
        if model.workspacePath.isEmpty || model.remoteWorkspace != nil {
            DockEmptyWorkspace(model: model)
        } else {
            HStack(spacing: 0) {
                previewPane
                Divider()
                VStack(spacing: 6) {
                    TextField(AppCopy.text("dock.filterFiles"), text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .padding([.horizontal, .top], 8)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if filter.isEmpty {
                                ForEach(FileEntry.children(of: URL(fileURLWithPath: model.workspacePath))) {
                                    FileTreeRow(entry: $0, depth: 0, selected: $selected)
                                }
                            } else {
                                ForEach(matches) { FileTreeRow(entry: $0, depth: 0, selected: $selected, showsPath: model.workspacePath) }
                            }
                        }
                    }
                }
                .frame(width: 240)
            }
            .task(id: filter) {
                guard !filter.isEmpty else { matches = []; return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                let root = URL(fileURLWithPath: model.workspacePath)
                let query = filter
                matches = await Task.detached { Self.search(root: root, query: query) }.value
            }
            .onChange(of: selected) { _, url in
                guard let url else { preview = ""; return }
                Task {
                    preview = await Task.detached {
                        guard let data = try? Data(contentsOf: url) else { return "" }
                        guard let text = String(data: data.prefix(200_000), encoding: .utf8) else {
                            return AppCopy.text("dock.binaryFile")
                        }
                        return text
                    }.value
                }
            }
        }
    }

    private var previewPane: some View {
        Group {
            if selected == nil {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text(AppCopy.text("dock.openFile")).font(.headline)
                    Text(AppCopy.text("dock.selectFile")).font(.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(preview)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private nonisolated static func search(root: URL, query: String) -> [FileEntry] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var found: [FileEntry] = []
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir, [".git", "node_modules", ".build"].contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if !isDir, url.path.localizedCaseInsensitiveContains(query) {
                found.append(FileEntry(url: url, isDirectory: false))
                if found.count >= 300 { break }
            }
        }
        return found
    }
}

private struct FileTreeRow: View {
    let entry: FileEntry
    let depth: Int
    @Binding var selected: URL?
    var showsPath: String?
    @State private var expanded = false
    @State private var children: [FileEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if entry.isDirectory {
                    expanded.toggle()
                    if expanded { children = FileEntry.children(of: entry.url) }
                } else {
                    selected = entry.url
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: entry.isDirectory ? (expanded ? "chevron.down" : "chevron.right") : "doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(showsPath.map { String(entry.url.path.dropFirst($0.count + 1)) } ?? entry.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .padding(.leading, CGFloat(depth) * 14 + 8)
                .frame(height: 24)
                .background(selected == entry.url ? Color.accentColor.opacity(0.18) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(children) { FileTreeRow(entry: $0, depth: depth + 1, selected: $selected) }
            }
        }
    }
}

// MARK: - Browser

@MainActor
private final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView = WKWebView()
    @Published var address = ""

    override init() {
        super.init()
        webView.navigationDelegate = self
    }

    func go() {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        if let url = URL(string: text) { webView.load(URLRequest(url: url)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in address = webView.url?.absoluteString ?? address }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct DockBrowserView: View {
    @StateObject private var browser = BrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                TextField("URL", text: $browser.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { browser.go() }
            }
            .buttonStyle(.plain)
            .padding(8)
            Divider()
            WebViewHost(webView: browser.webView)
        }
    }
}
