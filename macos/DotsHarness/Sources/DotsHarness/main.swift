// Copyright (c) 2026 DOTS
// Single executable, two modes: the app, and (when launched through the
// `DotsHarnessScheduler` symlink from the launchd LaunchAgent) a headless
// daemon that runs scheduled tasks while the app is closed.

import AppKit
import DotsHarnessCore

if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "DotsHarnessScheduler" {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    // Retained for the process lifetime: `app.run()` never returns.
    let model = AppModel()
    model.startHeadless()
    _ = model

    app.run()
} else {
    DotsHarnessApp.main()
}
