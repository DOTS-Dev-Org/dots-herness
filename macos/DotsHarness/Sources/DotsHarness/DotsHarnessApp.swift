// Copyright (c) 2026 DOTS
// Standalone native plugin harness.

import AppKit
import SwiftUI
import DotsHarnessCore
import DotsHarnessUI
import FableThinkingPlugin

@main
struct DotsHarnessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel(builtins: [
        FableThinkingPlugin.self,
    ])

    init() {
        // AsyncImage uses URLSession.shared; give it a real disk cache so pet
        // avatars are fetched from the CDN once, then served from disk/memory.
        URLCache.shared = URLCache(
            memoryCapacity: 8 << 20,
            diskCapacity: 64 << 20,
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("DotsHarnessAvatars")
        )
    }

    var body: some Scene {
        WindowGroup("Dots Harness") {
            RootView(model: model, logo: Image("ai-watcher", bundle: .module))
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    appDelegate.model = model
                    model.start()
                    DispatchQueue.main.async {
                        let window = NSApplication.shared.keyWindow
                            ?? NSApplication.shared.mainWindow
                            ?? NSApplication.shared.windows.first(where: { $0.styleMask.contains(.titled) })
                        if let window {
                            appDelegate.installCloseConfirmation(on: window)
                            let visible = NSScreen.screens.contains {
                                NSIntersectionRect($0.visibleFrame, window.frame).width > 80
                            }
                            if !visible {
                                window.center()
                            }
                        }
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button(AppCopy.text("app.quit")) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel?
    private var terminationRequested = false

    func installCloseConfirmation(on window: NSWindow) {
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard terminationRequested else {
            NSApplication.shared.terminate(nil)
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shouldAllowTermination() else { return .terminateCancel }
        model?.shutdownVoice()
        terminationRequested = true
        return .terminateNow
    }

    private func shouldAllowTermination() -> Bool {
        guard let model, model.confirmBeforeExit else { return true }

        let alert = NSAlert()
        alert.messageText = AppCopy.text("quit.title")
        alert.informativeText = AppCopy.text("quit.message")
        alert.addButton(withTitle: AppCopy.text("quit.confirm"))
        alert.addButton(withTitle: AppCopy.text("quit.cancel"))
        let remember = NSButton(
            checkboxWithTitle: AppCopy.text("quit.remember"),
            target: nil,
            action: nil
        )
        alert.accessoryView = remember

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if remember.state == .on {
            model.setConfirmBeforeExit(false)
        }
        return true
    }
}
