// Copyright (c) 2026 DOTS

import AppKit
import SwiftUI
import DotsHarnessCore

/// A five-point drag target with a one-point visual separator.
struct WorkspaceDivider: View {
    let horizontal: Bool
    @Binding var preferred: Double
    let actual: CGFloat
    let limits: ClosedRange<CGFloat>
    let sign: CGFloat
    @State private var origin: CGFloat?
    @State private var hovered = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle().fill(hovered || origin != nil ? Color.accentColor : Color.primary.opacity(0.12))
                .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
        }
        .frame(width: horizontal ? nil : 5, height: horizontal ? 5 : nil)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if origin == nil { origin = actual }
                let delta = horizontal ? drag.translation.height : drag.translation.width
                preferred = Double(clamp((origin ?? actual) + delta * sign))
            }
            .onEnded { _ in origin = nil })
        .onHover { inside in
            hovered = inside
            if inside { (horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() }
            else { NSCursor.pop() }
        }
        .onDisappear { if hovered { NSCursor.pop() } }
        .accessibilityElement()
        .accessibilityLabel(AppCopy.text("dock.split"))
        .accessibilityValue("\(Int(actual))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: preferred = Double(clamp(actual + 20))
            case .decrement: preferred = Double(clamp(actual - 20))
            @unknown default: break
            }
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(limits.upperBound, max(limits.lowerBound, value)) }
}
