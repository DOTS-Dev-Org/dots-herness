// Copyright (c) 2026 DOTS
// Browse and install plugins from the static marketplace registry.

import SwiftUI
import HarnessPluginKit
import PluginRuntime
import DotsHarnessCore

public struct MarketplaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var market: MarketplaceClient
    @State private var query = ""
    @State private var actionError: String?

    public init(model: AppModel) {
        self.model = model
        self.market = model.marketplace
    }

    private var filtered: [MarketplaceEntry] {
        guard !query.isEmpty else { return market.entries }
        let q = query.lowercased()
        return market.entries.filter {
            $0.name.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppCopy.text("marketplace.title")).font(.title2.weight(.semibold))
                Spacer()
                if market.isLoading { ProgressView().controlSize(.small) }
                Button(AppCopy.text("common.refresh")) { Task { await market.refresh() } }
                    .disabled(market.isLoading)
            }
            .padding()

            TextField(AppCopy.text("marketplace.search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if let error = market.lastError ?? actionError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal).padding(.top, 4)
            }

            if market.entries.isEmpty {
                ContentUnavailableView(
                    AppCopy.text("marketplace.empty"),
                    systemImage: "shippingbox",
                    description: Text(AppCopy.text("marketplace.emptyHint"))
                )
                .frame(maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    row(entry).padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { if market.entries.isEmpty { await market.refresh() } }
    }

    @ViewBuilder
    private func row(_ entry: MarketplaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).font(.headline)
                Text("v\(entry.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                action(entry)
            }
            Text(entry.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                badge(entry.tier)
                if entry.signature != nil { badge("signed") }
                if !entry.author.isEmpty {
                    Text(AppCopy.format("marketplace.by", entry.author)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !entry.description.isEmpty {
                Text(entry.description).font(.caption)
            }
        }
    }

    @ViewBuilder
    private func action(_ entry: MarketplaceEntry) -> some View {
        if market.busyIDs.contains(entry.id) {
            ProgressView().controlSize(.small)
        } else {
            switch market.status(entry) {
            case .notInstalled:
                Button(AppCopy.text("marketplace.install")) { install(entry) }
            case .updateAvailable(let installed):
                Button(AppCopy.format("marketplace.update", installed, entry.version)) { install(entry) }
            case .upToDate:
                HStack(spacing: 6) {
                    Text(AppCopy.text("local.installed")).font(.caption).foregroundStyle(.secondary)
                    Button(AppCopy.text("common.remove"), role: .destructive) {
                        actionError = nil
                        do { try market.remove(entry.id); model.remount() }
                        catch { actionError = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func install(_ entry: MarketplaceEntry) {
        actionError = nil
        Task {
            do {
                try await market.install(entry)
                model.remount()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
