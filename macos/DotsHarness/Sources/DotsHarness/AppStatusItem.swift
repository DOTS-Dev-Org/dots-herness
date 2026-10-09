// Copyright (c) 2026 DOTS
// Standalone native plugin harness.

import AppKit
import SwiftUI
import DotsHarnessCore
import DotsHarnessUI

/// Menu bar presence. While it is installed the window can close without
/// ending the process, so running agent turns keep going in the background.
/// Clicking it opens a small panel that works as the app itself.
@MainActor
final class AppStatusItem: NSObject {
    var onOpen: (() -> Void)?
    var onQuit: (() -> Void)?
    weak var model: AppModel?

    private var item: NSStatusItem?
    private let popover = NSPopover()

    func install() {
        guard item == nil, let model else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = Self.templateIcon
        status.button?.toolTip = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        status.button?.target = self
        status.button?.action = #selector(togglePanel)
        item = status

        // ponytail: transient closes on any outside click, including system panels
        // the chat opens (file picker). Switch to a floating NSPanel if that bites.
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 620)
        popover.contentViewController = NSHostingController(
            rootView: TrayPanelView(
                model: model,
                onOpenWindow: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.onOpen?()
                },
                onQuit: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.onQuit?()
                }
            )
        )
    }

    @objc private func togglePanel() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Without activation the composer never receives key events.
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private static let templateIcon: NSImage? = {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for name in ["TrayIcon", "TrayIcon@2x", "TrayIcon@3x"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
                  let rep = NSImageRep(contentsOf: url) else { continue }
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }()
}
