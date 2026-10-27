import SwiftUI
import DotsHarnessCore

struct HerNessLoadingAnimation: View {
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let frames: [NSImage?] = (0..<4).map { frame in
        guard let url = Bundle.module.url(
            forResource: "HerNessLoaderFrame\(frame)",
            withExtension: "png"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    init(size: CGFloat = 20) {
        self.size = size
    }

    var body: some View {
        Group {
            if Self.frames.allSatisfy({ $0 != nil }) {
                // Core Animation flips the frames in the render server: a SwiftUI
                // TimelineView re-ran the whole window's view graph on every frame.
                LoaderLayerView(frames: Self.frames.compactMap { $0 }, animated: !reduceMotion)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.75, weight: .medium))
                    .foregroundStyle(Color.orange)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(AppCopy.text("conversation.thinkingPhase"))
    }
}

private struct LoaderLayerView: NSViewRepresentable {
    let frames: [NSImage]
    let animated: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        view.layer?.contents = frames.first
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer else { return }
        guard animated else { layer.removeAnimation(forKey: "frames"); return }
        // A parent re-render must not restart the loop at its first frame.
        guard layer.animation(forKey: "frames") == nil else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = 0.22 * Double(frames.count)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "frames")
    }
}
