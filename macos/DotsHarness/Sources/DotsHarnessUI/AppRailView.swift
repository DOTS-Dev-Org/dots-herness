// Copyright (c) 2026 DOTS
// Leading rail that switches between the app's top-level sections.

import SwiftUI
import DotsHarnessCore

struct AppRailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var updateChecker: UpdateChecker
    @State private var isAccountMenuPresented = false
    @State private var showSignOutConfirmation = false
    @State private var isAccountHovered = false

    static let width: CGFloat = 68

    init(model: AppModel) {
        self.model = model
        _updateChecker = ObservedObject(wrappedValue: model.updateChecker)
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(AppSection.allCases.filter { $0 != .memory || model.bridge.memoryEnabled }) { section in
                RailButton(
                    title: section.title,
                    systemImage: section.systemImage,
                    isSelected: model.section == section
                ) {
                    model.open(section)
                }
            }

            Spacer(minLength: 0)

            if let update = availableUpdate {
                Button {
                    Task { await updateChecker.installUpdate() }
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.blue, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(AppCopy.format("settings.updates.available", update.latestVersion))
                .accessibilityLabel(AppCopy.text("settings.updates.install"))
                .padding(.bottom, 2)
            }

            Button {
                isAccountMenuPresented.toggle()
            } label: {
                VStack(spacing: 3) {
                    AccountBadge(initials: model.account.initials, size: 28)
                        .frame(width: 40, height: 30)
                        .background(
                            Color.primary.opacity(isAccountMenuPresented ? 0.12 : (isAccountHovered ? 0.06 : 0)),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )

                    Text(model.account.displayName)
                        .font(.system(size: 10, weight: isAccountMenuPresented ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(isAccountMenuPresented ? Color.primary : Color.secondary)
                .frame(width: Self.width - 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isAccountHovered = $0 }
            .help(AppCopy.text("sidebar.accountOptions"))
            .accessibilityLabel(Text("\(model.account.displayName), \(AppCopy.text("sidebar.accountOptions"))"))
            .inWindowPopover(isPresented: $isAccountMenuPresented, alignment: .leading, width: 280, cornerRadius: 18) {
                AccountMenuPopover(
                    account: model.account,
                    router: model.router,
                    onSettings: {
                        isAccountMenuPresented = false
                        model.presentSettings()
                    },
                    onSignOut: {
                        isAccountMenuPresented = false
                        showSignOutConfirmation = true
                    }
                )
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .onExitCommand { isAccountMenuPresented = false }
        .alert(AppCopy.text("sidebar.signOutQuestion"), isPresented: $showSignOutConfirmation) {
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
            Button(AppCopy.text("sidebar.signOut"), role: .destructive) {
                model.signOut()
            }
        } message: {
            Text(AppCopy.text("sidebar.signOutMessage"))
        }
        .zIndex(2)
    }

    private var availableUpdate: UpdateInfo? {
        switch updateChecker.state {
        case .updateAvailable(let info), .mandatoryUpdate(let info): return info
        default: return nil
        }
    }
}

private struct RailButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .symbolVariant(isSelected ? .fill : .none)
                    .frame(width: 40, height: 30)
                    .background(
                        Color.primary.opacity(isSelected ? 0.12 : (isHovered ? 0.06 : 0)),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(width: AppRailView.width - 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Picks one of the connected chat models. An empty id follows the app's own selection.
struct ChatModelMenu: View {
    @ObservedObject var router: RouterController
    @Binding var modelID: String

    var body: some View {
        Menu {
            Button {
                modelID = ""
            } label: {
                Label(AppCopy.text("models.followApp"), systemImage: modelID.isEmpty ? "checkmark" : "")
            }
            ForEach(RouterCatalog.modelGroups(for: router.models)) { group in
                Section(group.name) {
                    ForEach(group.models) { item in
                        Button {
                            modelID = item.id
                        } label: {
                            Label(RouterCatalog.modelDisplayName(for: item), systemImage: modelID == item.id ? "checkmark" : "")
                        }
                    }
                }
            }
        } label: {
            Text(modelID.isEmpty ? AppCopy.text("models.followApp") : router.modelLabel(forID: modelID))
                .lineLimit(1)
        }
        .task { await router.refreshModelsIfNeeded() }
    }
}
