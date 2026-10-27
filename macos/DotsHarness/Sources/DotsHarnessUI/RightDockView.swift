// Copyright (c) 2026 DOTS
// Tabbed dock: Review (real git), Terminal, Browser, Files. The dock stays right of the chat; a tab can be dragged to any side.

import SwiftUI
import WebKit
import DotsHarnessCore

/// `.leading` is the side next to the sidebar (the physical right in RTL).
enum DockEdge: String, Equatable {
    case leading, trailing, top, bottom

    var isSideBySide: Bool { self == .leading || self == .trailing }
}

/// Edge under `point`. Nil in the central region, so a drag near the centre does not move the tab.
func dockEdge(at point: CGPoint, in size: CGSize, rightToLeft: Bool) -> DockEdge? {
    guard size.width > 0, size.height > 0 else { return nil }
    let dx = (point.x - size.width / 2) / (size.width / 2)
    let dy = (point.y - size.height / 2) / (size.height / 2)
    if abs(dx) >= abs(dy) {
        guard abs(dx) >= 0.5 else { return nil }
        return (dx < 0) != rightToLeft ? .leading : .trailing
    }
    guard abs(dy) >= 0.5 else { return nil }
    return dy < 0 ? .top : .bottom
}

// MARK: - State

@MainActor
final class RightDockState: ObservableObject {
    enum Kind: Equatable {
        case review
        case terminal(session: UUID, key: String)
        case files
        case browser
        case plan
        case tasks
        case cloud

        var systemImage: String {
            switch self {
            case .review: return KeyboardShortcutAction.review.systemImage
            case .terminal: return "terminal"
            case .files: return "folder"
            case .browser: return "globe"
            case .plan: return "lightbulb"
            case .tasks: return "clock.arrow.circlepath"
            case .cloud: return "cloud"
            }
        }

        var title: String {
            switch self {
            case .review: return KeyboardShortcutAction.review.title
            case .terminal: return KeyboardShortcutAction.terminal.title
            case .files: return KeyboardShortcutAction.files.title
            case .browser: return KeyboardShortcutAction.browser.title
            case .plan: return AppCopy.text("plan.title")
            case .tasks: return AppCopy.text("backgroundTasks.title")
            case .cloud: return AppCopy.text("cloud.title")
            }
        }

        /// Where this tool was last dragged to; new tabs of the kind open there.
        fileprivate var edgeKey: String {
            switch self {
            case .review: return "dock.edge.review"
            case .terminal: return "dock.edge.terminal"
            case .files: return "dock.edge.files"
            case .browser: return "dock.edge.browser"
            case .plan: return "dock.edge.plan"
            case .tasks: return "dock.edge.tasks"
            case .cloud: return "dock.edge.cloud"
            }
        }
    }

    struct Tab: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
        var edge: DockEdge
        /// Project name plus a per-tool number, so two terminals stay tellable apart.
        let number: Int
        let title: String
    }

    /// The right dock itself. Tabs dragged to another edge show regardless.
    @Published var isVisible = false
    /// Right dock fills the whole detail area (conversation hidden).
    @Published var isExpanded = false
    @Published private(set) var tabs: [Tab] = []
    @Published var selected: [DockEdge: UUID] = [:]
    /// Edges that show a pair of tabs instead of one at a time.
    @Published var split = Set((UserDefaults.standard.stringArray(forKey: "dock.split") ?? []).compactMap(DockEdge.init)) {
        didSet { UserDefaults.standard.set(split.map(\.rawValue), forKey: "dock.split") }
    }
    @Published var horizontalSplits = Set((UserDefaults.standard.stringArray(forKey: "dock.horizontalSplits") ?? ["top", "bottom"]).compactMap(DockEdge.init)) {
        didSet { UserDefaults.standard.set(horizontalSplits.map(\.rawValue), forKey: "dock.horizontalSplits") }
    }
    @Published private var splitCompanions: [DockEdge: UUID] = [:]
    private var browsers: [UUID: NativeBrowserService] = [:]

    func splitTabs(on edge: DockEdge) -> [Tab] {
        let all = tabs(on: edge)
        let active = selected[edge] ?? all.first?.id
        let companion = all.first { $0.id == splitCompanions[edge] && $0.id != active }
            ?? all.first { $0.id != active }
        return all.filter { $0.id == active || $0.id == companion?.id }
    }

    func minimumWidth(on edge: DockEdge) -> CGFloat {
        split.contains(edge) && horizontalSplits.contains(edge) && tabs(on: edge).count > 1 ? 401 : 240
    }

    func minimumHeight(on edge: DockEdge) -> CGFloat {
        split.contains(edge) && !horizontalSplits.contains(edge) && tabs(on: edge).count > 1 ? 245 : 180
    }

    func browser(for tab: Tab) -> NativeBrowserService? { browsers[tab.id] }

    func toggleVisibility() {
        isVisible.toggle()
        if isVisible && !has(.trailing) { add(.browser, unique: false, at: .trailing) }
    }

    func setSplit(_ edge: DockEdge, horizontal: Bool?) {
        guard let horizontal else { split.remove(edge); splitCompanions[edge] = nil; return }
        if horizontal { horizontalSplits.insert(edge) } else { horizontalSplits.remove(edge) }
        split.insert(edge)
        if splitCompanions[edge] == nil {
            splitCompanions[edge] = tabs(on: edge).first { $0.id != selected[edge] }?.id
        }
    }

    func splitPane(_ edge: DockEdge, horizontal: Bool, model: AppModel) {
        if tabs(on: edge).count < 2 {
            if edge == .bottom { openTerminal(model: model, at: edge) }
            else { add(.browser, unique: false, at: edge) }
        }
        setSplit(edge, horizontal: horizontal)
    }

    /// Tab being dragged and the edge it would land on.
    @Published private(set) var dragging: Tab?
    @Published private(set) var dropEdge: DockEdge?
    /// Detail area in window coordinates; `RootView` keeps it current.
    var dropArea = CGRect.zero
    /// Names new tabs; `RootView` keeps it current.
    var projectName = ""

    init() {
        NativeBrowserService.shared.onNavigateRequested = { [weak self] _ in
            self?.showBrowser()
        }
    }

    func tabs(on edge: DockEdge) -> [Tab] { tabs.filter { $0.edge == edge } }

    func has(_ edge: DockEdge) -> Bool { tabs.contains { $0.edge == edge } }

    var hasMovedTabs: Bool { tabs.contains { $0.edge != .trailing } }

    func showPlan() {
        add(.plan, unique: true)
    }

    func showReview() {
        add(.review, unique: true)
    }

    func showTasks() {
        add(.tasks, unique: true)
    }

    func showCloud() {
        add(.cloud, unique: true)
    }

    func showBrowser() {
        if let tab = tabs.first(where: { browsers[$0.id] === NativeBrowserService.shared }) {
            select(tab)
        } else {
            add(.browser, unique: false, at: .trailing, browser: .shared)
        }
    }

    func openWebURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return }
        showBrowser()
        NativeBrowserService.shared.loadAddress(url.absoluteString)
    }

    /// `point` is in window coordinates, like `dropArea`.
    func previewDrop(_ tab: Tab, at point: CGPoint, rightToLeft: Bool) {
        var target = dockEdge(
            at: CGPoint(x: point.x - dropArea.minX, y: point.y - dropArea.minY),
            in: dropArea.size,
            rightToLeft: rightToLeft
        )
        if target == tab.edge { target = nil }
        // Skip no-op writes: every drag tick would otherwise re-render the whole root view.
        if dragging != tab { dragging = tab }
        if dropEdge != target { dropEdge = target }
    }

    func drop(_ tab: Tab, at point: CGPoint, rightToLeft: Bool) {
        previewDrop(tab, at: point, rightToLeft: rightToLeft)
        if let dropEdge { move(tab, to: dropEdge) }
        dropEdge = nil
        dragging = nil
    }

    func move(_ tab: Tab, to edge: DockEdge) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }), tabs[index].edge != edge else { return }
        let old = tabs[index].edge
        tabs[index].edge = edge
        UserDefaults.standard.set(edge.rawValue, forKey: tab.kind.edgeKey)
        if selected[old] == tab.id { selected[old] = tabs(on: old).last?.id }
        select(tabs[index])
    }

    func select(_ tab: Tab) {
        if split.contains(tab.edge), splitCompanions[tab.edge] == tab.id {
            splitCompanions[tab.edge] = selected[tab.edge]
        }
        if selected[tab.edge] != tab.id { selected[tab.edge] = tab.id }
        if let browser = browsers[tab.id] { NativeBrowserService.activate(browser) }
        if tab.edge == .trailing { isVisible = true }
    }

    func perform(_ action: KeyboardShortcutAction, model: AppModel) {
        switch action {
        case .review: add(.review, unique: true)
        case .files: add(.files, unique: true)
        case .browser: add(.browser, unique: false)
        case .terminal: openTerminal(model: model)
        case .newConversation: model.newConversation()
        case .simulator:
            model.isTasksPresented = false
            model.isSimulatorPresented = true
        case .toggleSidebar, .pullRequests, .scheduled: break
        }
    }

    func add(_ kind: Kind, unique: Bool, at requestedEdge: DockEdge? = nil, browser: NativeBrowserService? = nil) {
        if unique, let existing = tabs.first(where: { $0.kind == kind }) {
            select(existing)
            return
        }
        let edge = requestedEdge ?? DockEdge(rawValue: UserDefaults.standard.string(forKey: kind.edgeKey) ?? "") ?? .trailing
        let taken = Set(tabs.filter { $0.kind.edgeKey == kind.edgeKey }.map(\.number))
        let number = (1...).first { !taken.contains($0) } ?? 1
        let tab = Tab(
            kind: kind,
            edge: edge,
            number: number,
            title: kind == .browser ? AppCopy.text("dock.newTab") : "\(kind.title) · \(projectName.isEmpty ? String(number) : "\(projectName) \(number)")"
        )
        if kind == .browser {
            let service = browser ?? NativeBrowserService()
            browsers[tab.id] = service
            service.onNavigateRequested = { [weak self, weak service] _ in
                guard let self, let service,
                      let tab = self.tabs.first(where: { self.browsers[$0.id] === service }) else { return }
                self.select(tab)
            }
        }
        tabs.append(tab)
        select(tab)
    }

    func openTerminal(model: AppModel, at edge: DockEdge? = nil) {
        let key = model.terminalWorkspaceKey
        guard !key.isEmpty else {
            if !model.isRemoteWorkLocation { model.chooseWorkspace() }
            return
        }
        guard let session = model.terminalManager.openSession(
            for: key,
            executionPolicy: model.remoteWorkspace == nil ? model.sandboxExecutionPolicy : nil,
            remoteTarget: model.remoteWorkspace
        ) else { return }
        add(.terminal(session: session.id, key: key), unique: false, at: edge)
    }

    func close(_ tab: Tab, model: AppModel) {
        if case .terminal(let id, let key) = tab.kind,
           let session = model.terminalManager.sessions(for: key).first(where: { $0.id == id }) {
            model.terminalManager.closeSession(session, for: key)
        }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let closedActiveBrowser = browsers[tab.id] === NativeBrowserService.shared
        if let browser = browsers.removeValue(forKey: tab.id) {
            browser.stop()
        }
        tabs.remove(at: index)
        if selected[tab.edge] == tab.id { selected[tab.edge] = tabs(on: tab.edge).last?.id }
        if closedActiveBrowser {
            let successor = tabs(on: tab.edge).first { $0.id == selected[tab.edge] }
            NativeBrowserService.activate(successor.flatMap { browsers[$0.id] } ?? browsers.values.first ?? NativeBrowserService())
        }
        if !has(tab.edge) { split.remove(tab.edge) }
        if tab.edge == .trailing && !has(.trailing) && isVisible {
            add(.browser, unique: false, at: .trailing)
        }
    }
}

private let dockActions: [KeyboardShortcutAction] = [.review, .terminal, .browser, .files, .newConversation, .simulator]

// MARK: - Dock

/// Tabs and tools at one workspace edge.
struct RightDockView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: RightDockState
    var edge: DockEdge = .trailing

    private var tabs: [RightDockState.Tab] { state.tabs(on: edge) }
    private var selectedID: UUID? { state.selected[edge] ?? tabs.first?.id }
    private var isSplit: Bool { state.split.contains(edge) && tabs.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if edge == .trailing && tabs.isEmpty { state.add(.browser, unique: false, at: .trailing) }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in tabButton(tab).id(tab.id) }
                    }
                }
                .onChange(of: selectedID, initial: true) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .trailing) }
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                if edge == .bottom { state.openTerminal(model: model, at: .bottom) }
                else { state.add(.browser, unique: false, at: edge) }
            } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(edge == .bottom ? KeyboardShortcutAction.terminal.title : AppCopy.text("dock.newTab"))
            .accessibilityLabel(edge == .bottom ? KeyboardShortcutAction.terminal.title : AppCopy.text("dock.newTab"))

            .contextMenu {
                ForEach(dockActions) { action in
                    Button(action.title) { state.perform(action, model: model) }
                }
                Button(AppCopy.text("backgroundTasks.title")) { state.showTasks() }
                Button(AppCopy.text("cloud.title")) { model.showCloudRuns() }
                Divider()
                Button(AppCopy.text("dock.bottomTerminal")) { state.openTerminal(model: model, at: .bottom) }
            }

            if !tabs.isEmpty {
                Menu {
                    Button(AppCopy.text("dock.splitHorizontal")) { state.splitPane(edge, horizontal: true, model: model) }
                    Button(AppCopy.text("dock.splitVertical")) { state.splitPane(edge, horizontal: false, model: model) }
                    Button(AppCopy.text("dock.unsplit")) { state.setSplit(edge, horizontal: nil) }
                } label: {
                    Image(systemName: state.horizontalSplits.contains(edge) ? "rectangle.split.2x1" : "rectangle.split.1x2")
                        .foregroundStyle(isSplit ? Color.accentColor : Color.primary)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(AppCopy.text("dock.split"))
                .accessibilityLabel(AppCopy.text("dock.split"))
            }

            if edge == .trailing {
                Button { state.isExpanded.toggle() } label: {
                    Image(systemName: state.isExpanded
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(AppCopy.text(state.isExpanded ? "dock.collapse" : "dock.expand"))
                .accessibilityLabel(AppCopy.text(state.isExpanded ? "dock.collapse" : "dock.expand"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private func tabButton(_ tab: RightDockState.Tab) -> some View {
        HStack(spacing: 6) {
            // Tap selects, drag moves the tab to another edge. A plain gesture, not onDrag:
            // a pasteboard drag needs a declared UTType and this app declares none.
            HStack(spacing: 6) {
                Image(systemName: tab.kind.systemImage).font(.system(size: 12))
                if let browser = state.browser(for: tab) {
                    DockBrowserTabTitle(service: browser)
                } else {
                    Text(tab.title).font(.system(size: 13)).lineLimit(1)
                }
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .onTapGesture { state.select(tab) }
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { state.previewDrop(tab, at: $0.location, rightToLeft: model.isRTL) }
                    .onEnded { state.drop(tab, at: $0.location, rightToLeft: model.isRTL) }
            )
            .accessibilityAddTraits(.isButton)
            Button { state.close(tab, model: model) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(AppCopy.text("feedback.close"))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 220)
        .frame(height: 30)
        .background(
            Color.primary.opacity(!isSplit && tab.id == selectedID ? 0.10 : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .opacity(state.dragging?.id == tab.id ? 0.4 : 1)
    }

    @ViewBuilder
    private var content: some View {
        if isSplit {
            // Panes follow the tab bar's order.
            if !state.horizontalSplits.contains(edge) {
                VSplitView {
                    ForEach(state.splitTabs(on: edge)) { tab in
                        boundedPane(tab).frame(minHeight: 100)
                    }
                }
            } else {
                HSplitView {
                    ForEach(state.splitTabs(on: edge)) { tab in
                        boundedPane(tab).frame(minWidth: 200)
                    }
                }
            }
        } else if let tab = tabs.first(where: { $0.id == selectedID }) {
            pane(tab)
        } else {
            VStack { pickerList(inPopover: false); Spacer(minLength: 0) }
                .padding(.horizontal, 20)
                .frame(maxHeight: .infinity)
        }
    }

    private func boundedPane(_ tab: RightDockState.Tab) -> some View {
        GeometryReader { proxy in
            pane(tab).frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func pane(_ tab: RightDockState.Tab) -> some View {
        switch tab.kind {
        case .review: DockReviewView(model: model).id(model.workspacePath)
        case .terminal(let id, let key): DockTerminalView(manager: model.terminalManager, key: key, id: id)
        case .files: DockFilesView(model: model).id(model.workspacePath)
        case .browser:
            if let service = state.browser(for: tab) {
                DockBrowserView(model: model, state: state, service: service).id(tab.id)
            }
        case .plan: DockPlanView(model: model)
        case .tasks: DockTasksView(model: model)
        case .cloud: DockCloudView(model: model)
        }
    }

    private func pickerList(inPopover: Bool) -> some View {
        VStack(spacing: 8) {
            ForEach(dockActions) { action in
                PaneChoiceRow(
                    systemImage: action.systemImage,
                    title: action.title,
                    shortcut: model.shortcut(for: action).displayValue
                ) {
                    state.perform(action, model: model)
                }
            }
        }
        .padding(inPopover ? 10 : 0)
        .frame(width: inPopover ? 300 : nil)
    }
}

/// Slot, sized like the pane it becomes, that shows where the dragged tab will land.
struct DockDropPreview: View {
    let edge: DockEdge
    let tab: RightDockState.Tab

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        GeometryReader { proxy in
            VStack(spacing: 8) {
                Image(systemName: tab.kind.systemImage).font(.system(size: 24, weight: .medium))
                Text(tab.title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.accentColor.opacity(0.16), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay { shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])) }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
            .padding(8)
            .frame(
                width: edge.isSideBySide ? min(420, proxy.size.width / 2) : proxy.size.width,
                height: edge.isSideBySide ? proxy.size.height : min(320, proxy.size.height / 2)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.18), value: edge)
    }

    private var alignment: Alignment {
        switch edge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }
}

// MARK: - Plan

private struct DockPlanView: View {
    @ObservedObject var model: AppModel

    private var conversation: Conversation? { model.selected }
    private var plan: ChatMessage? {
        guard let conversation else { return nil }
        if let id = conversation.pendingPlanMessageID,
           let pending = conversation.messages.first(where: { $0.id == id }) { return pending }
        return conversation.messages.last { $0.kind == .plan }
    }
    private var isPending: Bool { plan != nil && conversation?.pendingPlanMessageID == plan?.id }
    private var canApply: Bool {
        conversation?.running == false && conversation?.continuation == nil && model.bridge.isReady
    }

    var body: some View {
        VStack(spacing: 0) {
            if let plan {
                ScrollView {
                    PlanMarkdownView(text: plan.text)
                        .textSelection(.enabled)
                        .padding(16)
                }
                if isPending { actions }
            } else {
                Spacer()
                Text(AppCopy.text("plan.empty")).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Text(AppCopy.text("plan.proposed")).font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            planButton(AppCopy.text("plan.reject")) { model.cancelPlan() }
            planButton(AppCopy.text("plan.revise")) { model.revisePlan() }
            planButton(AppCopy.text("plan.accept"), enabled: canApply) { model.applyPlan() }
            Button { model.applyPlanAndAutoApprove() } label: {
                Text(AppCopy.text("plan.acceptAuto")).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .disabled(!canApply)
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(12)
    }

    private func planButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }
}

// MARK: - Background tasks

/// Shells and background tasks the agent started in the selected conversation.
private struct DockTasksView: View {
    @ObservedObject var model: AppModel
    @State private var expanded = Set<UUID>()

    var body: some View {
        // The clock drives both the elapsed times and the running/finished grouping.
        // Nothing running: nothing to tick, so it stops waking the view every second.
        let anyRunning = model.bridge.backgroundTasks(in: model.selected?.id).contains(where: \.isRunning)
        TimelineView(.animation(minimumInterval: 1, paused: !anyRunning)) { context in
            let tasks = model.bridge.backgroundTasks(in: model.selected?.id)
            let running = tasks.filter(\.isRunning)
            let finished = tasks.filter { !$0.isRunning }
            if tasks.isEmpty {
                Text(AppCopy.text("backgroundTasks.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !running.isEmpty {
                            header(AppCopy.text("router.running"))
                            ForEach(running) { row($0, now: context.date) }
                        }
                        if !finished.isEmpty {
                            HStack {
                                header("\(AppCopy.text("backgroundTasks.finished")) \(finished.count)")
                                Spacer(minLength: 0)
                                Button {
                                    if let id = model.selected?.id { model.bridge.clearFinishedBackgroundTasks(in: id) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(AppCopy.text("backgroundTasks.clear"))
                                .accessibilityLabel(AppCopy.text("backgroundTasks.clear"))
                            }
                            .padding(.top, running.isEmpty ? 0 : 8)
                            ForEach(finished.reversed()) { row($0, now: context.date) }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.callout).foregroundStyle(.secondary)
    }

    private func row(_ task: TerminalSession, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title.isEmpty ? KeyboardShortcutAction.terminal.title : task.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(expanded.contains(task.id) ? nil : 2)
                    Text("\(status(task))  \(elapsed(task, now: now))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(task.exitCode ?? 0 == 0 ? Color.secondary : Color.red)
                }
                Spacer(minLength: 0)
                if task.isRunning {
                    Button { task.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(AppCopy.text("common.stop"))
                    .accessibilityLabel(AppCopy.text("common.stop"))
                }
            }
            if expanded.contains(task.id) {
                ScrollView {
                    Text(String(task.output.suffix(4000)))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if !expanded.insert(task.id).inserted { expanded.remove(task.id) }
        }
        .accessibilityAddTraits(.isButton)
    }

    private func status(_ task: TerminalSession) -> String {
        if task.isRunning { return AppCopy.text("router.running") }
        guard let code = task.exitCode else { return AppCopy.text("backgroundTasks.stopped") }
        return code == 0
            ? AppCopy.text("tasks.notification.completed")
            : AppCopy.format("backgroundTasks.failed", Int(code))
    }

    private func elapsed(_ task: TerminalSession, now: Date) -> String {
        let seconds = Int((task.endedAt ?? now).timeIntervalSince(task.startedAt))
        return Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
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
    let status: String   // M, A, D
    let added: Int
    let removed: Int
    var id: String { path }
}

private struct DiffRow: Identifiable {
    enum Kind { case hunk, add, del, context }
    let id: Int
    let kind: Kind
    let old: Int?
    let new: Int?
    let text: String
    let hunk: Int
}

@MainActor
private final class ReviewModel: ObservableObject {
    @Published var changes: [ReviewChange] = []
    @Published var branch = ""
    @Published var branches: [String] = []
    @Published var selected: String?
    @Published var rows: [DiffRow] = []
    @Published var selectedHunk: Int?
    @Published var why: AgentFileChange?
    @Published var error: String?
    @Published var busy = false
    @Published var notRepo = false
    @Published var gitMissing = false

    let path: String
    let app: AppModel
    private var agent: [String: AgentFileChange] = [:]
    private var diffs: [String: String] = [:]
    init(path: String, app: AppModel) { self.path = path; self.app = app }

    var added: Int { changes.map(\.added).reduce(0, +) }
    var removed: Int { changes.map(\.removed).reduce(0, +) }

    func refresh() async {
        gitMissing = !(await Task.detached { GitInstall.isAvailable() }.value)
        if gitMissing { return }
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

        // Only files the agent changed: the diff is its turn-start snapshot against the file now.
        var result: [ReviewChange] = []
        agent = [:]
        diffs = [:]
        for change in app.agentChanges() {
            let text = await diff(for: change)
            guard !text.isEmpty else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            let status = change.operation == .added ? "A" : change.operation == .deleted ? "D" : "M"
            agent[change.path] = change
            diffs[change.path] = text
            result.append(ReviewChange(path: change.path, status: status, added: added, removed: removed))
        }
        changes = result
        if let current = selected, !changes.contains(where: { $0.id == current }) { selected = nil }
        loadDiff()
    }

    /// `git diff --no-index` works on any two files, tracked or not; exit 1 just means "differs".
    private func diff(for change: AgentFileChange) async -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dots-review-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = dir.appendingPathComponent("before")
        let after = dir.appendingPathComponent("after")
        try? (app.agentBeforeContent(change) ?? Data()).write(to: before)
        let current = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(change.path))
        try? (current ?? Data()).write(to: after)
        return (await Git.run(["diff", "--no-index", "--no-color", "-U3", "--", before.path, after.path], at: path)).out
    }

    func loadDiff() {
        selectedHunk = nil
        guard let selected, let text = diffs[selected] else {
            rows = []
            why = nil
            return
        }
        why = agent[selected]
        var out: [DiffRow] = []
        var old = 0, new = 0, hunk = -1
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                let nums = line.split(separator: " ").dropFirst().prefix(2)
                    .map { $0.dropFirst().split(separator: ",")[0] }.compactMap { Int($0) }
                if nums.count == 2 { old = nums[0]; new = nums[1] }
                hunk += 1
                out.append(DiffRow(id: out.count, kind: .hunk, old: nil, new: nil, text: String(line), hunk: hunk))
            } else if hunk >= 0, let mark = line.first {
                let body = String(line.dropFirst())
                switch mark {
                case "+": out.append(DiffRow(id: out.count, kind: .add, old: nil, new: new, text: body, hunk: hunk)); new += 1
                case "-": out.append(DiffRow(id: out.count, kind: .del, old: old, new: nil, text: body, hunk: hunk)); old += 1
                case " ": out.append(DiffRow(id: out.count, kind: .context, old: old, new: new, text: body, hunk: hunk)); old += 1; new += 1
                default: break
                }
            }
        }
        rows = out
    }

    func select(_ id: String) {
        selected = id
        loadDiff()
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

    /// Sets upstream so a branch's first push works too.
    func push() async {
        // `branch` falls back to the short hash when detached, so ask git again.
        let current = (await Git.run(["branch", "--show-current"], at: path)).out.trimmed
        guard !current.isEmpty else { error = AppCopy.text("git.detached"); return }
        await run(["push", "--set-upstream", "origin", current])
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
            ReviewBody(model: model, review: ReviewModel(path: model.workspacePath, app: model))
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
            if review.gitMissing {
                VStack(spacing: 10) {
                    Text(AppCopy.text("dock.gitMissing"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(AppCopy.text("dock.installGit")) { GitInstall.install() }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if review.notRepo {
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
        .onChange(of: model.selected?.running) { _ in Task { await review.refresh() } }
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
                Button(AppCopy.text("dock.push")) { Task { await review.push() } }
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
        return Button { review.select(change.id) } label: {
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
                Text("+\(change.added)").foregroundStyle(.green)
                Text("-\(change.removed)").foregroundStyle(.red)
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
        case "A": return .green
        case "D": return .red
        default: return .orange
        }
    }

    private var diffView: some View {
        VStack(spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(review.rows) { row in diffRow(row) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let why = review.why {
                Divider()
                whyPanel(why)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func diffRow(_ row: DiffRow) -> some View {
        let picked = review.selectedHunk == row.hunk
        return HStack(spacing: 0) {
            Text(row.old.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(row.new.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(sign(row.kind)).frame(width: 18)
            Text(row.text.isEmpty ? " " : row.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(row.kind == .hunk ? Color.blue : Color.primary)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor).frame(width: 2).opacity(picked ? 1 : 0)
        }
        .background(background(row.kind).overlay(picked ? Color.accentColor.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { review.selectedHunk = row.hunk }
    }

    private func sign(_ kind: DiffRow.Kind) -> String {
        switch kind {
        case .add: return "+"
        case .del: return "-"
        default: return ""
        }
    }

    private func background(_ kind: DiffRow.Kind) -> Color {
        switch kind {
        case .add: return Color.green.opacity(0.16)
        case .del: return Color.red.opacity(0.16)
        case .hunk: return Color.blue.opacity(0.14)
        case .context: return .clear
        }
    }

    private func whyPanel(_ why: AgentFileChange) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppCopy.text("dock.whyRequest")).font(.caption.bold()).foregroundStyle(.secondary)
                Text(why.request).textSelection(.enabled)
                Text(AppCopy.text("dock.whyAgent")).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                Text(why.explanation).textSelection(.enabled)
            }
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 150)
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
        Group {
            if model.workspacePath.isEmpty || model.remoteWorkspace != nil {
                if selected == nil {
                    DockEmptyWorkspace(model: model)
                } else {
                    previewPane
                }
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
            }
        }
        .onChange(of: model.filesPaneRequestID, initial: true) { _, _ in
            if let file = model.requestedFile { selected = file }
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
