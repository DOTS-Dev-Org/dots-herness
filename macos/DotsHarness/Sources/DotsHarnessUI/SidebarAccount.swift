// Copyright (c) 2026 DOTS
// Sidebar account menu and badge.

import AppKit
import SwiftUI
import DotsHarnessCore
import HarnessPluginKit
import PluginRuntime

struct AccountMenuPopover: View {
    let account: AccountIdentity
    let onUsage: () -> Void
    let onSettings: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AccountBadge(initials: account.initials, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)

                    Text(account.isSignedIn ? "Plus" : AppCopy.text("sidebar.signOut"))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider()
                .opacity(0.7)

            VStack(spacing: 2) {
                AccountMenuRow(
                    title: AppCopy.text("sidebar.usage"),
                    systemImage: "chart.bar.fill",
                    trailingSystemImage: "chevron.right",
                    action: onUsage
                )
                AccountMenuRow(
                    title: AppCopy.text("sidebar.settings"),
                    systemImage: "gearshape",
                    shortcut: "⌘,",
                    action: onSettings
                )

                Divider()
                    .padding(.vertical, 2)

                AccountMenuRow(
                    title: AppCopy.text("sidebar.signOut"),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    isDestructive: true,
                    role: .destructive,
                    action: onSignOut
                )
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
    }
}

struct AccountMenuRow: View {
    let title: String
    let systemImage: String
    var trailingSystemImage: String? = nil
    var shortcut: String? = nil
    var isDestructive = false
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 13) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)

                Spacer(minLength: 10)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .background(
                isHovered ? Color.primary.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct AccountBadge: View {
    var initials: String
    var size: CGFloat = 22

    var body: some View {
        Text(initials)
            .font(.system(size: max(8, size * 0.43), weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(Color(red: 0.20, green: 0.72, blue: 0.55), in: Circle())
    }
}
