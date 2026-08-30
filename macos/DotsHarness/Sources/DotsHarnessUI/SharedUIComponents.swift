// Copyright (c) 2026 DOTS
// Small shared primitives for the native macOS UI.

import SwiftUI
import DotsHarnessCore

struct ComposerBanner<Content: View>: View {
    private let verticalPadding: CGFloat
    private let content: Content

    init(verticalPadding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, verticalPadding)
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
    }
}

struct TagBadge: View {
    private let text: String
    private let background: AnyShapeStyle

    init(_ text: String, background: AnyShapeStyle = AnyShapeStyle(Color.primary.opacity(0.08))) {
        self.text = text
        self.background = background
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }
}

extension ChatAttachment.Kind {
    var systemImageName: String {
        switch self {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "video"
        case .file: return "doc"
        }
    }
}
