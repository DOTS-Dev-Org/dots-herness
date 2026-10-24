// Copyright (c) 2026 DOTS
// Conversation pane chooser and welcome cards.

import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore

struct PaneChoiceRow: View {
    let systemImage: String
    let title: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 16)
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.075), in: Capsule())
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PaneChoiceButtonStyle())
    }
}

struct PaneChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// Claude-Code-style new-chat welcome: app icon + project-aware heading + a 2x2
/// grid of action cards. Selecting a card fills the composer draft (never sends).
struct WelcomeView: View {
    let projectName: String
    let showConnectHint: Bool
    let showCards: Bool
    let cards: [WelcomeCard]
    let onSelect: (WelcomeCard) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 20) {
            logo
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)

            Text(AppCopy.format("welcome.heading", projectName))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: 460)

            if showCards {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(cards) { card in
                        WelcomeCardButton(card: card) { onSelect(card) }
                    }
                }
                .frame(maxWidth: 520)
            }

            if showConnectHint {
                Text(AppCopy.text("welcome.connectHint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private var logo: some View {
        // Transparent mascot generated from shared/branding/herness-logo.webp.
        if let url = Bundle.module.url(forResource: "WelcomeLogo", withExtension: "png"),
           let mark = ImageFileCache.image(at: url) {
            Image(nsImage: mark)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
        }
    }
}

struct WelcomeCardButton: View {
    let card: WelcomeCard
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: card.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                    Text(card.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                Text(card.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(WelcomeCardButtonStyle(hovered: hovered))
        .onHover { hovered = $0 }
        .accessibilityLabel(card.title)
        .accessibilityHint(card.subtitle)
    }
}

struct WelcomeCardButtonStyle: ButtonStyle {
    let hovered: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : (hovered ? 0.08 : 0.045)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
