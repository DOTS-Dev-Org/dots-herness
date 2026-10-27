// Copyright (c) 2026 DOTS
// Sidebar project grouping and project editor.

import AppKit
import SwiftUI
import DotsHarnessCore
import HarnessPluginKit
import PluginRuntime

enum ProjectGroupKind: Equatable {
    case pinned
    case named
    case folder
    case other
}

struct ProjectGroup: Identifiable {
    let title: String?
    let paths: [String]
    let kind: ProjectGroupKind
    var id: String { "\(title ?? "__other__"):\(paths.first ?? "")" }
}

enum ProjectSidebarGrouping: String, CaseIterable, Hashable {
    case sections
    case folder
    case none
}

enum ProjectSidebarSort: String, CaseIterable, Hashable {
    case defaultOrder
    case name
}

enum ProjectFolderGrouping {
    static func groups(for paths: [String]) -> [ProjectGroup] {
        let grouped = Dictionary(grouping: paths) { path in
            URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        }
        let nameCounts = Dictionary(grouping: grouped.keys, by: { URL(fileURLWithPath: $0).lastPathComponent })
            .mapValues(\.count)
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { folderPath in
            guard let projectPaths = grouped[folderPath], !projectPaths.isEmpty else { return nil }
            let folderURL = URL(fileURLWithPath: folderPath)
            let name = folderURL.lastPathComponent
            let title = nameCounts[name, default: 0] > 1
                ? "\(folderURL.deletingLastPathComponent().lastPathComponent)/\(name)"
                : name
            return ProjectGroup(title: title, paths: projectPaths, kind: .folder)
        }
    }
}

/// Presentation rules for unsectioned projects. The sidebar passes the space
/// remaining in its viewport so the reveal control follows the projects that fit.
enum OtherProjectVisibility {
    /// Used until the first sidebar layout measurement is available.
    static let limit = 5

    static func visiblePaths(
        _ paths: [String],
        isExpanded: Bool,
        limit: Int = limit
    ) -> [String] {
        isExpanded ? paths : Array(paths.prefix(max(1, limit)))
    }

    static func shouldShowRevealControl(
        _ paths: [String],
        isExpanded: Bool,
        visibleCount: Int? = nil
    ) -> Bool {
        !isExpanded && paths.count > (visibleCount ?? limit)
    }

    static func fittingPrefixCount(
        itemHeights: [CGFloat],
        availableHeight: CGFloat,
        revealControlHeight: CGFloat
    ) -> Int {
        guard !itemHeights.isEmpty else { return 0 }

        var visibleCount = 0
        var usedHeight: CGFloat = 0
        for (index, itemHeight) in itemHeights.enumerated() {
            let hasMoreItems = index < itemHeights.count - 1
            let requiredHeight = usedHeight + itemHeight + (hasMoreItems ? revealControlHeight : 0)
            guard requiredHeight <= availableHeight else { break }
            usedHeight += itemHeight
            visibleCount += 1
        }

        // Always leave the most recently opened project reachable, even in a
        // short window where the row and reveal control need scrolling.
        return max(1, visibleCount)
    }
}

struct ProjectEditorTarget: Identifiable {
    let id: String
}

struct ProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let path: String
    @State private var title: String
    @State private var searchFolders: [String]
    @State private var showRemoveConfirmation = false

    init(model: AppModel, path: String) {
        self.model = model
        self.path = path
        _title = State(initialValue: model.projectTitle(for: path))
        _searchFolders = State(initialValue: model.projectSearchFolders(for: path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppCopy.text("sidebar.editProject"))
                .font(.title2.weight(.semibold))
                .padding(.bottom, 16)

            Form {
                TextField(AppCopy.text("sidebar.projectTitle"), text: $title)

                Section(AppCopy.text("sidebar.searchFolders")) {
                    folderRow(path, removable: false)
                    ForEach(searchFolders, id: \.self) { folder in
                        folderRow(folder, removable: true)
                    }
                    Button(AppCopy.text("sidebar.addExtraFolder"), systemImage: "plus") {
                        addFolder()
                    }
                }
            }

            Divider().padding(.top, 12)

            HStack {
                Button(AppCopy.text("sidebar.removeLocalProject"), role: .destructive) {
                    showRemoveConfirmation = true
                }
                Spacer()
                Button(AppCopy.text("common.cancel")) { dismiss() }
                Button(AppCopy.text("common.save")) {
                    model.saveProjectMetadata(for: path, title: title, searchFolders: searchFolders)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 520, height: 430)
        .confirmationDialog(
            AppCopy.text("sidebar.removeProjectQuestion"),
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppCopy.text("sidebar.removeLocalProject"), role: .destructive) {
                model.removeProject(path)
                dismiss()
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(AppCopy.text("sidebar.removeProjectMessage"))
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: String, removable: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(folder)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if removable {
                Button {
                    searchFolders.removeAll { $0 == folder }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = AppCopy.text("sidebar.addExtraFolder")
        panel.begin { response in
            guard response == .OK else { return }
            let paths = panel.urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            for value in paths where value != path && !searchFolders.contains(value) {
                searchFolders.append(value)
            }
        }
    }
}
