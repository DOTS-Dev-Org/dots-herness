// Copyright (c) 2026 DOTS
import AppKit
import SwiftUI

/// Native horizontal scrolling with mouse dragging, without visible scroll bars.
struct DraggableTaskCards<Content: View>: NSViewRepresentable {
    let contentSize: CGSize
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        let document = NSHostingView(rootView: draggableContent(context.coordinator))
        document.sizingOptions = []
        document.frame = CGRect(origin: .zero, size: contentSize)
        scroll.documentView = document
        context.coordinator.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = scroll.documentView as? NSHostingView<AnyView> else { return }
        document.rootView = draggableContent(context.coordinator)
        document.setFrameSize(contentSize)
        let maximum = max(0, contentSize.width - scroll.contentSize.width)
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: CGPoint(x: min(maximum, max(0, origin.x)), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func draggableContent(_ coordinator: Coordinator) -> AnyView {
        AnyView(content().highPriorityGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { coordinator.drag(translation: $0.translation.width) }
                .onEnded { _ in coordinator.finishDrag() }
        ))
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scroll: NSScrollView?
        private var start: CGFloat?

        func drag(translation: CGFloat) {
            guard let scroll, let document = scroll.documentView else { return }
            if start == nil { start = scroll.contentView.bounds.origin.x }
            let maximum = max(0, document.frame.width - scroll.contentSize.width)
            let x = min(maximum, max(0, (start ?? 0) - translation))
            scroll.contentView.scroll(to: CGPoint(x: x, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func finishDrag() { start = nil }
    }
}
