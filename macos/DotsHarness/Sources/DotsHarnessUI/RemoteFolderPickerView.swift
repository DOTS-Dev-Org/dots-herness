// Copyright (c) 2026 DOTS
// Browses folders on a remote host. NSOpenPanel only knows this machine, so
// the listing comes from `ls` over the same SSH connection the agent uses.

import SwiftUI
import DotsHarnessCore

struct RemoteFolderPickerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var path = "~"
    @State private var entries: [String] = []
    @State private var isLoading = false

    private var alias: String { model.workLocation.remoteAlias ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppCopy.format("workLocation.remoteFolderTitle", alias))
                .font(.headline)

            HStack(spacing: 8) {
                Button {
                    path = Self.parent(of: path)
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(isLoading)
                .help(AppCopy.text("workLocation.remoteFolderUp"))

                TextField(AppCopy.text("workLocation.remoteFolderPath"), text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await load() } }

                Button(AppCopy.text("workLocation.remoteFolderList")) {
                    Task { await load() }
                }
                .disabled(isLoading)
            }

            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if entries.isEmpty {
                    Text(AppCopy.text("workLocation.remoteFolderEmpty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    List(entries, id: \.self) { entry in
                        Button {
                            path = Self.join(path, entry)
                            Task { await load() }
                        } label: {
                            Label(entry, systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(height: 220)

            let recents = model.sshStore.record(alias: alias).recentRemotePaths
            if !recents.isEmpty {
                Text(AppCopy.text("workLocation.remoteFolderRecent"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(recents.prefix(3), id: \.self) { recent in
                        Button(URL(fileURLWithPath: recent).lastPathComponent) {
                            path = recent
                            Task { await load() }
                        }
                        .buttonStyle(.link)
                        .help(recent)
                    }
                }
            }

            if let notice = model.sshNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(AppCopy.text("common.cancel")) { dismiss() }
                Button(AppCopy.text("workLocation.remoteFolderUse")) {
                    model.setRemoteWorkspace(path: path)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task {
            path = model.remoteWorkspace?.remotePath
                ?? model.sshStore.record(alias: alias).lastRemotePath
                ?? "~"
            await load()
        }
    }

    private func load() async {
        guard !alias.isEmpty else { return }
        isLoading = true
        entries = await model.remoteDirectories(alias: alias, path: path)
        isLoading = false
    }

    private static func join(_ base: String, _ component: String) -> String {
        base.hasSuffix("/") ? base + component : base + "/" + component
    }

    private static func parent(of path: String) -> String {
        guard path != "/", path != "~" else { return path }
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "~" }
        let parent = String(trimmed[trimmed.startIndex..<slash])
        return parent.isEmpty ? "/" : parent
    }
}
