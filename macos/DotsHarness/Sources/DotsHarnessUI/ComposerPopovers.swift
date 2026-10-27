// Copyright (c) 2026 DOTS
// Composer popovers: project, work location, git branch, attachments, permissions.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore
import HarnessPluginKit

@MainActor
private func popoverAction(icon: String, title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 17)
                .foregroundStyle(.secondary)
            Text(title).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

enum WorkLocationOption: String, Identifiable {
    case local
    case localWorktree

    static let localCases: [WorkLocationOption] = [.local, .localWorktree]

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .local: return "laptopcomputer"
        case .localWorktree: return "arrow.up.right.square"
        }
    }

    var setting: WorkLocationSetting {
        switch self {
        case .local: return .local
        case .localWorktree: return .localWorktree
        }
    }

    var title: String { AppCopy.text("workLocation.\(rawValue)") }
    var detail: String { AppCopy.text("workLocation.\(rawValue)Detail") }
}

struct ProjectPickerPopover: View {
    let workspacePath: String
    var projects: [String] = []
    var projectTitle: ((String) -> String)? = nil
    var onSelect: ((String) -> Void)? = nil
    let onChoose: () -> Void
    let onClear: () -> Void

    @State private var searchText = ""
    @State private var hoveredPath: String?
    @FocusState private var searchFocused: Bool

    private func title(for path: String) -> String {
        projectTitle?(path) ?? URL(fileURLWithPath: path).lastPathComponent
    }

    private var visibleProjects: [String] {
        let all = projects.isEmpty && !workspacePath.isEmpty ? [workspacePath] : projects
        guard !searchText.isEmpty else { return all }
        return all.filter {
            title(for: $0).localizedCaseInsensitiveContains(searchText)
                || URL(fileURLWithPath: $0).lastPathComponent.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                TextField(AppCopy.text("studio.search"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)

            Divider().padding(.vertical, 5)

            if visibleProjects.isEmpty {
                Text(AppCopy.text("composer.noProject"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleProjects, id: \.self) { path in
                            Button {
                                onSelect?(path)
                            } label: {
                                projectRow(path: path)
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredPath = $0 ? path : (hoveredPath == path ? nil : hoveredPath) }
                            .help(path)
                        }
                    }
                }
                .frame(maxHeight: 230)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 5)

            popoverAction(icon: "plus", title: AppCopy.text("studio.newProject"), action: onChoose)
            if !workspacePath.isEmpty {
                popoverAction(
                    icon: "bubble.left.and.bubble.right",
                    title: AppCopy.text("composer.dontWorkInProject"),
                    action: onClear
                )
            }
        }
        .padding(6)
        .frame(width: 290)
        .onAppear { searchFocused = true }
    }

    private func projectRow(path: String) -> some View {
        let isSelected = ConversationStore.normalizedPath(path) == ConversationStore.normalizedPath(workspacePath)
        let name = title(for: path)
        let folder = URL(fileURLWithPath: path).lastPathComponent
        return HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 17)
                .foregroundStyle(.secondary)
            Text(name)
                .lineLimit(1)
                .layoutPriority(1)
            if folder != name {
                Text(folder)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            Color.primary.opacity(isSelected ? 0.11 : (hoveredPath == path ? 0.06 : 0)),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
    }

}

struct WorkLocationPopover: View {
    let selection: WorkLocationSetting
    let hosts: [SSHHost]
    let sshAvailable: Bool
    let remotePath: String?
    /// `owner/repo` of the project's GitHub origin; nil disables the Cloud row.
    let cloudRepository: String?
    let onSelect: (WorkLocationSetting) -> Void
    let onManageHosts: () -> Void
    let onChooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppCopy.text("workLocation.title"))
                .font(.headline)
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 5)

            ForEach(WorkLocationOption.localCases) { option in
                row(
                    icon: option.icon,
                    title: option.title,
                    detail: option.detail,
                    isSelected: selection == option.setting,
                    isEnabled: true
                ) { onSelect(option.setting) }
            }

            row(
                icon: "cloud",
                title: AppCopy.text("workLocation.cloud"),
                detail: cloudRepository.map { AppCopy.format("workLocation.cloudDetail", $0) }
                    ?? AppCopy.text("workLocation.cloudUnavailable"),
                isSelected: selection.isCloud,
                isEnabled: cloudRepository != nil
            ) { onSelect(.cloud) }

            Divider().padding(.vertical, 5)

            Text(AppCopy.text("workLocation.remoteHosts"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.bottom, 2)

            if !sshAvailable {
                Text(AppCopy.text("ssh.error.unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            } else if hosts.isEmpty {
                Text(AppCopy.text("workLocation.noHosts"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            } else {
                ForEach(hosts) { host in
                    row(
                        icon: "network",
                        title: host.alias,
                        detail: detail(for: host),
                        isSelected: selection.remoteAlias == host.alias,
                        isEnabled: true
                    ) { onSelect(.remote(alias: host.alias)) }
                }
            }

            if selection.isRemote {
                popoverAction(icon: "folder", title: AppCopy.text("workLocation.chooseRemoteFolder"), action: onChooseFolder)
            }
            popoverAction(icon: "plus", title: AppCopy.text("workLocation.addHost"), action: onManageHosts)
        }
        .padding(8)
        .frame(width: 350)
    }

    private func detail(for host: SSHHost) -> String {
        guard selection.remoteAlias == host.alias, let remotePath, !remotePath.isEmpty else {
            return host.displayDestination
        }
        return "\(host.displayDestination) · \(remotePath)"
    }

    private func row(
        icon: String,
        title: String,
        detail: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 17)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(isSelected ? .medium : .regular))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.primary.opacity(0.10) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

}

struct GitBranchPopover: View {
    let snapshot: GitSnapshot
    let error: String?
    let busy: Bool
    let onSelect: (String) -> Void
    let onSelectRemote: (String) -> Void
    let onCreate: () -> Void
    let onFetch: () -> Void
    let onPush: () -> Void

    @State private var searchText = ""

    private var filteredBranches: [String] {
        guard !searchText.isEmpty else { return snapshot.branches }
        return snapshot.branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredRemoteBranches: [String] {
        guard !searchText.isEmpty else { return snapshot.remoteBranches }
        return snapshot.remoteBranches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(AppCopy.text("git.search"), text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(AppCopy.text("git.branches"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.top, 5)

            if filteredBranches.isEmpty {
                Text(AppCopy.text("git.noBranches"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(filteredBranches, id: \.self) { branch in
                    Button {
                        onSelect(branch)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 17)
                                    .foregroundStyle(.secondary)
                                Text(branch)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if branch == snapshot.currentBranch {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if branch == snapshot.currentBranch, snapshot.uncommittedCount > 0 {
                                Text(AppCopy.format("git.uncommitted", snapshot.uncommittedCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 27)
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            branch == snapshot.currentBranch ? Color.primary.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !filteredRemoteBranches.isEmpty {
                Text(AppCopy.text("git.remoteBranches"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.top, 5)

                ForEach(filteredRemoteBranches, id: \.self) { branch in
                    Button {
                        onSelectRemote(branch)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "cloud")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 17)
                                .foregroundStyle(.secondary)
                            Text(branch)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
            }

            Divider().padding(.vertical, 5)

            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppCopy.text("git.working"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
            } else {
                actionRow(icon: "arrow.down.circle", title: AppCopy.text("git.fetch"), action: onFetch)
                    .disabled(!snapshot.hasRemote)
                    .opacity(snapshot.hasRemote ? 1 : 0.45)
                actionRow(icon: "arrow.up.circle", title: AppCopy.text("git.push"), action: onPush)
                    .disabled(!snapshot.hasRemote || snapshot.currentBranch == nil)
                    .opacity(snapshot.hasRemote && snapshot.currentBranch != nil ? 1 : 0.45)
                actionRow(icon: "plus", title: AppCopy.text("git.createBranch"), action: onCreate)
            }
        }
        .padding(8)
        .frame(width: 360)
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 17)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The composer's "+" menu: one line per action, with its shortcut or a chevron
/// for rows that lead somewhere else on the trailing side.
struct AttachmentMenu: View {
    struct Row: Identifiable {
        let icon: String
        let title: String
        var shortcut: String? = nil
        var opensElsewhere = false
        let action: () -> Void
        var id: String { title }
    }

    let rows: [Row]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 1) {
            ForEach(rows) { row in
                Button {
                    dismiss()
                    row.action()
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: row.icon)
                            .font(.system(size: 14))
                            .frame(width: 20)
                        Text(row.title)
                            .font(.system(size: 14))
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        if let shortcut = row.shortcut {
                            Text(shortcut)
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        if row.opensElsewhere {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PickerRowStyle(selected: false))
            }
        }
        .padding(6)
        .frame(width: 270)
    }
}

/// The composer's "+" button with its menu. ⌘U runs `onShortcut` whether or not the menu is open.
struct ComposerAddButton: View {
    let rows: [AttachmentMenu.Row]
    let onShortcut: () -> Void
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .regular))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { AttachmentMenu(rows: rows) }
        .background {
            Button("", action: onShortcut).keyboardShortcut("u", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
        .help(AppCopy.text("composer.add"))
        .accessibilityLabel(AppCopy.text("composer.add"))
    }
}

/// The composer's dictation button.
struct ComposerVoiceButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voiceInput: LiveVoiceInput

    var body: some View {
        let help = voiceInput.isListening ? AppCopy.text("composer.stopListening") : model.voiceInputHelp
        Button { voiceInput.toggle() } label: {
            Image(systemName: voiceInput.state.icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 25, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.isVoiceReady ? voiceInput.state.tint : .secondary)
        .opacity(model.isVoiceModelDownloading ? 0.55 : (model.isVoiceReady ? 1 : 0.7))
        .disabled(voiceInput.state == .transcribing || voiceInput.state == .sending || model.isVoiceModelDownloading)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The filled round button at the composer's trailing edge: send, stop or continue.
struct ComposerRoundButton: View {
    let icon: String
    var size: CGFloat = 12
    let label: String
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .bold))
                .frame(width: 30, height: 30)
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .background(Color.primary, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

/// The composer's model pill: the model, its effort and a chevron.
struct ComposerModelLabel: View {
    let name: String
    let effort: String

    var body: some View {
        HStack(spacing: 4) {
            Text(name).lineLimit(1)
            Text(effort).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

extension View {
    /// The rounded outline around a composer's editor and controls.
    func composerOutline() -> some View {
        overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

/// Width reported by a composer's text area so wrapped lines contribute to its height.
struct ComposerEditorWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Height of a composer editor holding `text`: it grows with the draft up to ten visual lines.
@MainActor
func composerEditorHeight(for text: String, width: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 15)
    let layoutWidth = width.isFinite && width > 0 ? width : 100_000
    let container = NSTextContainer(
        containerSize: NSSize(width: layoutWidth, height: .greatestFiniteMagnitude)
    )
    container.lineFragmentPadding = 0
    container.maximumNumberOfLines = 11

    let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: [.font: font])
    let layoutManager = NSLayoutManager()
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: container)

    var visualLines = 0
    layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, _, _, _, _ in
        visualLines += 1
    }
    let explicitLines = text.components(separatedBy: .newlines).count
    let visibleLines = min(max(max(visualLines, explicitLines), 1), 10)
    let lineHeight = ceil(layoutManager.defaultLineHeight(for: font))
    return min(238, max(44, CGFloat(visibleLines) * lineHeight + 16))
}

struct PermissionMenu: View {
    @Binding var selection: AgentPermissionMode

    private var helpURL: URL? {
        var components = URLComponents(string: "https://dots.net.tr/harness/sandboxing")
        components?.queryItems = [URLQueryItem(name: "lang", value: AppCopy.effectiveLanguage.rawValue)]
        return components?.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(AppCopy.text("permission.title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let helpURL {
                    Link(destination: helpURL) {
                        Text(AppCopy.text("permission.moreInfo"))
                            .font(.caption)
                            .underline()
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            ForEach(AgentPermissionMode.allCases) { level in
                Button {
                    selection = level
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: level.icon)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 17)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.title)
                                .font(.callout.weight(level == selection ? .medium : .regular))
                            Text(level.detail)
                                .font(.caption)
                                .foregroundStyle(level == .full ? Color.orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if level == selection {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(level == .full ? Color.orange : .secondary)
                        }
                    }
                    .foregroundStyle(level == .full ? Color.orange : .primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        level == selection ? Color.primary.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 475)
    }
}
