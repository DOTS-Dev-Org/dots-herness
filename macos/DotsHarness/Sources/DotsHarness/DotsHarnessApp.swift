// Copyright (c) 2026 DOTS
// Standalone native plugin harness.

import AppKit
import SwiftUI
import DotsHarnessCore
import DotsHarnessUI
import PluginRuntime

@main
struct DotsHarnessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel(builtins: [
        PluginAuthorPlugin.self,
    ])

    init() {
        // AsyncImage-based remote assets use a real disk cache.
        URLCache.shared = URLCache(
            memoryCapacity: 8 << 20,
            diskCapacity: 64 << 20,
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("DotsHarnessAvatars")
        )
    }

    var body: some Scene {
        WindowGroup {
            let _ = model.prepareForFirstFrame()
            RootView(model: model, logo: Image("ai-watcher", bundle: .module))
                .frame(
                    minWidth: model.legalNeedsAcceptance ? 560 : 520,
                    minHeight: model.legalNeedsAcceptance ? 620 : 640
                )
                .onAppear {
                    appDelegate.model = model
                    model.requestNotificationAuthorization()
                    model.start()
                    DispatchQueue.main.async {
                        let window = NSApplication.shared.keyWindow
                            ?? NSApplication.shared.mainWindow
                            ?? NSApplication.shared.windows.first(where: { $0.styleMask.contains(.titled) })
                        if let window {
                            appDelegate.configureWindow(
                                window,
                                legalNeedsAcceptance: model.legalNeedsAcceptance
                            )
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
                .onChange(of: model.legalNeedsAcceptance) { _, needsAcceptance in
                    DispatchQueue.main.async {
                        let window = NSApplication.shared.keyWindow
                            ?? NSApplication.shared.mainWindow
                            ?? NSApplication.shared.windows.first(where: { $0.styleMask.contains(.titled) })
                        if let window {
                            appDelegate.configureWindow(window, legalNeedsAcceptance: needsAcceptance)
                        }
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            DotsHarnessCommands(model: model, navigationState: model.navigationState)
        }
    }
}

private struct DotsHarnessCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var navigationState: SidebarVisibilityState

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            // Keep global navigation shortcuts in the menu bar. This makes
            // them work even when a view inside the sidebar is not mounted,
            // and lets macOS show the key equivalents to the user.
            Button(
                navigationState.visibility == .detailOnly
                    ? AppCopy.text("sidebar.show")
                    : AppCopy.text("sidebar.hide")
            ) {
                model.toggleSidebarVisibility()
            }
            .keyboardShortcut(model.shortcut(for: .toggleSidebar).swiftUIShortcut)

            Button(AppCopy.text("sidebar.pullRequests")) {
                model.openPullRequests()
            }
            .keyboardShortcut(model.shortcut(for: .pullRequests).swiftUIShortcut)
            .disabled(model.activeProjectForgeURL == nil)

            Button(AppCopy.text("sidebar.scheduled")) {
                model.presentTasks()
            }
            .keyboardShortcut(model.shortcut(for: .scheduled).swiftUIShortcut)
        }

        CommandGroup(replacing: .appTermination) {
            Button(AppCopy.text("app.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel?
    private var terminationRequested = false

    func configureWindow(_ window: NSWindow, legalNeedsAcceptance: Bool) {
        window.styleMask.remove(.fullSizeContentView)
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.title = ""

        let contentMinimum = NSSize(
            width: legalNeedsAcceptance ? 560 : 520,
            height: legalNeedsAcceptance ? 620 : 640
        )
        window.contentMinSize = contentMinimum
    }

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
        model?.terminalManager.stopAll()
        model?.bridge.stopAllAgentTerminals()
        if let registry = model?.mcpRegistry { Task { await registry.disconnectAll() } }
        terminationRequested = true
        Task { @MainActor [weak self] in
            await self?.model?.bridge.closeBrowserSessions()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func shouldAllowTermination() -> Bool {
        guard let model, model.confirmBeforeExit else { return true }

        let panel = CloseConfirmationPanel()
        panel.center()
        let response = NSApplication.shared.runModal(for: panel)
        panel.orderOut(nil)

        guard response == .alertFirstButtonReturn else { return false }
        if panel.remembersChoice {
            model.setConfirmBeforeExit(false)
        }
        return true
    }
}

extension AppDelegate {
    func application(_ application: NSApplication, open urls: [URL]) -> Bool {
        for url in urls where url.scheme == "herness" {
            Task { @MainActor [weak self] in
                guard let model = self?.model else { return }
                await model.marketplaceSession.handleOAuthCallback(url)
                model.syncAccountFromMarketplace()
            }
        }
        return urls.contains { $0.scheme == "herness" }
    }
}

@MainActor
private final class CloseConfirmationPanel: NSPanel {
    private let remember: NSButton
    private(set) var remembersChoice = false

    init() {
        let size = NSSize(width: 420, height: 182)
        let remember = NSButton(
            checkboxWithTitle: AppCopy.text("quit.remember"),
            target: nil,
            action: nil
        )
        self.remember = remember
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        title = AppCopy.text("quit.title")
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        hidesOnDeactivate = false

        let surface = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        surface.material = .hudWindow
        surface.blendingMode = .withinWindow
        surface.state = .active
        surface.autoresizingMask = [.width, .height]
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 20
        surface.layer?.masksToBounds = true
        contentView = surface

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(root)

        let icon = NSImageView(image: NSApplication.shared.applicationIconImage
            ?? NSImage(size: NSSize(width: 1, height: 1)))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 14
        icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: AppCopy.text("quit.title"))
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let message = NSTextField(labelWithString: AppCopy.text("quit.message"))
        message.font = NSFont.systemFont(ofSize: 14)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        remember.font = NSFont.systemFont(ofSize: 13)
        let copy = NSStackView(views: [title, message, remember])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 5
        copy.translatesAutoresizingMaskIntoConstraints = false

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(icon)
        body.addSubview(copy)

        let cancel = NSButton(title: AppCopy.text("quit.cancel"), target: self, action: #selector(cancelQuit))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: AppCopy.text("quit.confirm"), target: self, action: #selector(confirmQuit))
        confirm.bezelStyle = .rounded
        confirm.controlSize = .large
        confirm.isBordered = true
        confirm.bezelColor = NSColor.controlAccentColor
        confirm.contentTintColor = .white
        confirm.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, confirm])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(body)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: surface.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -20),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: root.topAnchor),
            body.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 82),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 34),
            confirm.heightAnchor.constraint(equalTo: cancel.heightAnchor),
            icon.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 58),
            icon.heightAnchor.constraint(equalToConstant: 58),
            copy.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            copy.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            copy.centerYAnchor.constraint(equalTo: body.centerYAnchor),
        ])

        initialFirstResponder = confirm
    }

    @objc private func confirmQuit() {
        remembersChoice = remember.state == .on
        NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn)
    }

    @objc private func cancelQuit() {
        NSApplication.shared.stopModal(withCode: .alertSecondButtonReturn)
    }

    override func cancelOperation(_ sender: Any?) {
        cancelQuit()
    }
}
