// Copyright (c) 2026 DOTS
// Background daemon: runs scheduled harness tasks while the app is closed.
// Launched by the launchd LaunchAgent installed from Settings.

import AppKit
import DotsHarnessCore

@main
struct SchedulerDaemon {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        // Retained for the process lifetime: `app.run()` never returns.
        let model = AppModel()
        model.startHeadless()
        _ = model

        app.run()
    }
}
