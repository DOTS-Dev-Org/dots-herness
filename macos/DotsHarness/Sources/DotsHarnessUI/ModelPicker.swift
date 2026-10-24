// Copyright (c) 2026 DOTS
// Composer model picker, effort slider and supporting styles.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore
import HarnessPluginKit

struct ModelPickerPopover: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var router: RouterController
    @State private var collapsedProviders: Set<String> = []
    /// Card shows only the selected model; tapping its title swaps in the model list.
    @State private var showingModels = false

    init(model: AppModel) {
        self.model = model
        self.router = model.router
    }

    private var modelGroups: [RouterModelGroup] {
        RouterCatalog.modelGroups(for: router.models)
    }

    /// Levels the selected model accepts. Auto combines supported levels across
    /// routable models; its empty first stop leaves effort selection adaptive.
    private var effortLevels: [String] {
        if router.isAutoSelected {
            let options = router.automaticEffortOptions
            return options.isEmpty ? [] : [""] + options
        }
        return router.efforts(for: model.selectedModelID)
    }

    private var supportsFast: Bool {
        !router.isAutoSelected && router.supportsFast(model.selectedModelID)
    }

    private var isFast: Bool { supportsFast && router.fastMode }

    var body: some View {
        Group {
            if showingModels { modelList } else { effortCard }
        }
        .padding(8)
        .frame(width: 225)
        .animation(.easeInOut(duration: 0.15), value: showingModels)
        .task {
            await router.refreshModelsIfNeeded()
        }
    }

    // MARK: Effort card

    private var effortCard: some View {
        let stops = effortLevels
        let enabled = !stops.isEmpty
        let selectedEffort = router.isAutoSelected
            ? router.selectedEffort
            : router.effectiveEffort(for: model.selectedModelID)
        let index = stops.firstIndex(of: selectedEffort) ?? 0
        return VStack(spacing: 8) {
            HStack {
                if supportsFast {
                Button {
                    model.setFast(!isFast)
                } label: {
                    Image(systemName: isFast ? "bolt.fill" : "bolt")
                        .foregroundStyle(isFast ? Color.accentColor : .secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(AppCopy.text("modelPicker.speed")): \(AppCopy.text(isFast ? "modelPicker.fast" : "modelPicker.standard"))")
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }

                Spacer()
                Button { showingModels = true } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Text(effortTitle)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isUltra ? Color.purple : (enabled ? Color.accentColor : .secondary))
                        if let selectedModelName {
                            Text(selectedModelName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(AppCopy.text("modelPicker.selectModel"))
                Spacer()

                Button {
                    model.setEffort(router.isAutoSelected ? "" : "low")
                    model.setFast(false)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(AppCopy.text("modelPicker.reset"))
            }
            .font(.system(size: 10, weight: .medium))

            EffortSlider(count: max(stops.count, 1), index: index, ultra: isUltra) { model.setEffort(stops[$0]) }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)

            Picker(AppCopy.text("modelPicker.contextEconomy"), selection
: Binding(
                get: { router.usageMode },
                set: { model.setUsageMode($0) }
            )) {
                ForEach(AgentUsageMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }

    /// Top "max" level gets the Codex-style starry purple track.
    private var isUltra: Bool {
        let selected = router.isAutoSelected
            ? router.selectedEffort
            : router.effectiveEffort(for: model.selectedModelID)
        return selected == "max" && effortLevels.last == "max"
    }

    private var effortTitle: String {
        if router.isAutoSelected, router.selectedEffort.isEmpty {
            return AppCopy.text("modelPicker.effort.default")
        }
        if effortLevels.isEmpty { return AppCopy.text("modelPicker.effortUnsupported") }
        let selected = router.isAutoSelected
            ? router.selectedEffort
            : router.effectiveEffort(for: model.selectedModelID)
        return Self.effortLabel(selected)
    }

    private var selectedModelName: String? {
        guard !router.isAutoSelected else { return nil }
        return router.modelLabel(forID: model.selectedModelID)
    }

    static func effortLabel(_ level: String) -> String {
        level.isEmpty ? AppCopy.text("modelPicker.effort.default") : AppCopy.text("modelPicker.effort.\(level)")
    }

    // MARK: Model list

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { showingModels = false } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    Text(AppCopy.text("modelPicker.selectModel"))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if modelGroups.isEmpty {
                Text(AppCopy.text("modelPicker.noModel"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        pickerRow(
                            title: AppCopy.text("modelPicker.auto"),
                            subtitle: AppCopy.text("modelPicker.autoHint"),
                            selected: router.isAutoSelected
                        ) { model.setModel(ModelRouter.autoModelID); showingModels = false }

                        ForEach(modelGroups) { group in
                            providerHeader(group)
                            if !collapsedProviders.contains(group.provider) {
                                ForEach(group.models) { item in
                                    pickerRow(
                                        title: RouterCatalog.modelDisplayName(for: item),
                                        selected: !router.isAutoSelected && item.id == model.selectedModelID
                                    ) { model.setModel(item.id); showingModels = false }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func providerHeader(_ group: RouterModelGroup) -> some View {
        let collapsed = collapsedProviders.contains(group.provider)
        return Button {
            if collapsed { collapsedProviders.remove(group.provider) } else { collapsedProviders.insert(group.provider) }
        } label: {
            HStack(spacing: 6) {
                providerLogo(for: group)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(group.name)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func providerLogo(for group: RouterModelGroup) -> some View {
        let resource = ProviderLogoSource.mark(for: group.provider)
        if let resource,
           let url = Bundle.module.url(forResource: resource, withExtension: "svg")
                ?? Bundle.module.url(forResource: resource, withExtension: "png"),
           let image = ImageFileCache.image(at: url) {
            if Self.adaptiveMonochromeMarks.contains(resource) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .scaledToFit()
            } else {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(1)
                    .background(.white, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
        } else {
            Image(systemName: group.logoSymbol)
        }
    }

    private static let adaptiveMonochromeMarks: Set<String> = ["OpenAIMark", "AnthropicMark", "OpenRouterMark"]

    private func pickerRow(
        title: String,
        subtitle: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickerRowStyle(selected: selected))
    }
}

/// Hover/selection highlight for popover rows.
struct PickerRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration, selected: selected)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : (selected ? 0.04 : 0))))
                )
                .onHover { hovering = $0 }
        }
    }
}

/// Codex-style discrete slider: filled accent track, stop dots, white knob.
struct EffortSlider: View {
    let count: Int
    let index: Int
    var ultra = false
    let onChange: (Int) -> Void
    @Environment(\.isEnabled) private var isEnabled

    private let height: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let knob = height - 4
            let travel = max(geo.size.width - knob - 4, 1)
            let step = count > 1 ? travel / CGFloat(count - 1) : 0
            let knobX = 2 + CGFloat(index) * step

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(ultra
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 0.25, green: 0.2, blue: 0.75), Color(red: 0.72, green: 0.6, blue: 1), Color(red: 0.3, green: 0.15, blue: 0.7)],
                            startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.accentColor))
                    .overlay(ultra ? AnyView(Starfield()) : AnyView(EmptyView()))
                    .clipShape(Capsule())
                    .frame(width: knobX + knob + 2)
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(i <= index ? Color.white.opacity(ultra ? 0 : 0.55) : Color.primary.opacity(0.35))
                        .frame(width: 5, height: 5)
                        .offset(x: 2 + CGFloat(i) * step + knob / 2 - 2.5)
                }
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: knobX)
            }
            .frame(width: geo.size.width, height: height, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { value in
                    guard isEnabled, count > 1 else { return }
                    let raw = (value.location.x - 2 - knob / 2) / step
                    let next = min(max(Int(raw.rounded()), 0), count - 1)
                    if next != index { onChange(next) }
                }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: index)
        }
        .frame(height: height)
    }
}

/// Fixed sparkle dots for the "max" track; deterministic so it doesn't flicker.
struct Starfield: View {
    private static let stars: [(CGFloat, CGFloat, CGFloat)] = (0..<18).map { i in
        let f = CGFloat(i)
        return ((f * 0.618).truncatingRemainder(dividingBy: 1), (f * 0.381 + 0.2).truncatingRemainder(dividingBy: 0.8) + 0.1, i % 4 == 0 ? 2.5 : 1.5)
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(Self.stars.indices, id: \.self) { i in
                let star = Self.stars[i]
                Circle()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: star.2, height: star.2)
                    .position(x: star.0 * geo.size.width, y: star.1 * geo.size.height)
            }
        }
    }
}
