// Copyright (c) 2026 DOTS
// In-window replacement for `.popover`.

import AppKit
import SwiftUI

extension View {
    /// Card anchored to a vertical edge of this view, drawn in the window's own
    /// content. Unlike `.popover`, it stays inside the app window. `width: nil`
    /// matches the anchor's width.
    func inWindowPopover<Card: View>(
        isPresented: Binding<Bool>,
        alignment: HorizontalAlignment = .center,
        width: CGFloat? = nil,
        cornerRadius: CGFloat = 12,
        verticalEdge: VerticalEdge = .top,
        @ViewBuilder content: @escaping () -> Card
    ) -> some View {
        modifier(InWindowPopover(
            isPresented: isPresented,
            alignment: alignment,
            width: width,
            cornerRadius: cornerRadius,
            verticalEdge: verticalEdge,
            card: content
        ))
    }
}

private struct InWindowPopover<Card: View>: ViewModifier {
    @Binding var isPresented: Bool
    let alignment: HorizontalAlignment
    let width: CGFloat?
    let cornerRadius: CGFloat
    let verticalEdge: VerticalEdge
    let card: () -> Card
    @State private var tracker = Tracker()

    /// Reference storage: the event monitor outlives any one `body` pass.
    private final class Tracker {
        var overAnchor = false
        var overCard = false
        var monitor: Any?
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    private var anchorAlignment: Alignment {
        Alignment(horizontal: alignment, vertical: verticalEdge == .top ? .top : .bottom)
    }
    private var cardAlignment: Alignment {
        Alignment(horizontal: alignment, vertical: verticalEdge == .top ? .bottom : .top)
    }
    private var spacingEdge: Edge.Set { verticalEdge == .top ? .bottom : .top }

    func body(content: Content) -> some View {
        content
            .onHover { tracker.overAnchor = $0 }
            .overlay(alignment: anchorAlignment) {
                // A zero-height strip attaches the card to the selected edge of its anchor.
                Color.clear.frame(height: 0).overlay(alignment: cardAlignment) {
                    if isPresented {
                        card()
                            .frame(width: width)
                            .frame(maxWidth: width == nil ? .infinity : nil)
                            .fixedSize(horizontal: width != nil, vertical: true)
                            .background(.regularMaterial, in: shape)
                            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                            .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
                            .onHover {
                                tracker.overCard = $0
                                // The card may cover a text view whose I-beam is still set.
                                if $0 { NSCursor.arrow.set() }
                            }
                            .padding(spacingEdge, 8)
                            .onAppear(perform: startMonitor)
                            .onDisappear(perform: stopMonitor)
                    }
                }
            }
    }

    // ponytail: outside-click test is hover-based, no frame math. A click on the
    // anchor is left to the anchor's own toggle.
    private func startMonitor() {
        tracker.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event } // Esc
                isPresented = false
                return nil
            }
            if !tracker.overAnchor && !tracker.overCard { isPresented = false }
            return event
        }
    }

    private func stopMonitor() {
        if let monitor = tracker.monitor { NSEvent.removeMonitor(monitor) }
        tracker.monitor = nil
        tracker.overCard = false
    }
}
