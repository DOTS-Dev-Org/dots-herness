// Copyright (c) 2026 DOTS

import SwiftUI
import DotsHarnessCore

struct ModelContextSettingsView: View {
    @ObservedObject var router: RouterController
    @State private var search = ""

    private var groups: [RouterModelGroup] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = router.modelContextSettings.filter { model in
            needle.isEmpty
                || model.id.localizedCaseInsensitiveContains(needle)
                || RouterCatalog.modelDisplayName(for: model).localizedCaseInsensitiveContains(needle)
                || RouterCatalog.label(for: model.provider).localizedCaseInsensitiveContains(needle)
        }
        return RouterCatalog.modelGroups(for: models)
    }

    var body: some View {
        Form {
            Section {
                Text(AppCopy.text("model.context.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField(AppCopy.text("model.context.search"), text: $search)
                        .textFieldStyle(.roundedBorder)
                    Button(AppCopy.text("settings.refreshModels")) {
                        Task { await router.refreshModels(force: true) }
                    }
                }
            }

            if groups.isEmpty {
                Section {
                    Text(AppCopy.text("model.context.empty"))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.models, id: \.id) { item in
                            ModelContextSettingRow(router: router, model: item)
                        }
                    } header: {
                        Label(group.name, systemImage: group.logoSymbol)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AppCopy.text("usage.context.window"))
        .task { await router.refreshModelsIfNeeded() }
    }
}

private struct ModelContextSettingRow: View {
    @ObservedObject var router: RouterController
    let model: RouterModel
    @State private var value: String
    @State private var error: String?
    @State private var saved = false

    init(router: RouterController, model: RouterModel) {
        self.router = router
        self.model = model
        _value = State(initialValue: router.modelContextWindowOverride(for: model.id, provider: model.provider).map(String.init) ?? "")
    }

    private var detectedText: String {
        guard let detected = router.detectedContextWindow(for: model.id, provider: model.provider) ?? model.contextWindow else {
            return AppCopy.text("model.context.notDetected")
        }
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: detected), number: .decimal)
        return AppCopy.format("model.context.detected", formatted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RouterCatalog.modelDisplayName(for: model))
                    Text(model.id).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(detectedText).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField(AppCopy.text("usage.context.window"), text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Button(AppCopy.text("model.context.save"), action: save)
                    .buttonStyle(.borderedProminent)
                Button(AppCopy.text("model.context.auto"), action: reset)
                    .disabled(value.isEmpty && router.modelContextWindowOverride(for: model.id, provider: model.provider) == nil)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if saved {
                Text(AppCopy.text("model.context.saved")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func save() {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty, let parsed = Int(digits), parsed > 0 else {
            error = AppCopy.text("model.context.invalid")
            saved = false
            return
        }
        do {
            try router.setModelContextWindowOverride(parsed, for: model.id, provider: model.provider)
            value = String(parsed)
            error = nil
            saved = true
        } catch {
            self.error = error.localizedDescription
            saved = false
        }
    }

    private func reset() {
        do {
            try router.setModelContextWindowOverride(nil, for: model.id, provider: model.provider)
            value = ""
            error = nil
            saved = true
        } catch {
            self.error = error.localizedDescription
            saved = false
        }
    }
}
