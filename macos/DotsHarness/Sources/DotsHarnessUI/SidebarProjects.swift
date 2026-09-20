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
    case other
}

struct ProjectGroup: Identifiable {
    let title: String?
    let paths: [String]
    let kind: ProjectGroupKind
    var id: String { "\(title ?? "__other__"):\(paths.first ?? "")" }
}

/// Pure presentation rules for the unsectioned project group. Kept separate
/// from `SidebarView` state so the five-project boundary remains unit-testable.
enum OtherProjectVisibility {
    static let limit = 5

    static func visiblePaths(_ paths: [String], isExpanded: Bool) -> [String] {
        isExpanded ? paths : Array(paths.prefix(limit))
    }

    static func shouldShowRevealControl(_ paths: [String], isExpanded: Bool) -> Bool {
        !isExpanded && paths.count > limit
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
