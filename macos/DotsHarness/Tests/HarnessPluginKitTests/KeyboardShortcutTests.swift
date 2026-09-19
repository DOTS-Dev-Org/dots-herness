// Copyright (c) 2026 DOTS

import Foundation
import XCTest
import PluginRuntime
@testable import DotsHarnessCore

final class KeyboardShortcutTests: XCTestCase {
    func testDefaultShortcutsAreUniqueAndUseExpectedDisplayValues() {
        let defaults = KeyboardShortcutAction.allCases.map(\.defaultShortcut)

        XCTAssertEqual(Set(defaults).count, defaults.count)
        XCTAssertEqual(KeyboardShortcutAction.toggleSidebar.defaultShortcut.displayValue, "⌘B")
        XCTAssertEqual(KeyboardShortcutAction.pullRequests.defaultShortcut.displayValue, "⌘⇧P")
        XCTAssertEqual(KeyboardShortcutAction.scheduled.defaultShortcut.displayValue, "⌘⇧T")
        XCTAssertEqual(KeyboardShortcutAction.terminal.defaultShortcut.displayValue, "⌃`")
    }

    func testStoredShortcutRoundTripsAndRejectsInvalidValues() throws {
        let shortcut = try XCTUnwrap(
            UserKeyboardShortcut(
                key: "P",
                modifierMask: UserKeyboardShortcut.command | UserKeyboardShortcut.shift
            )
        )

        XCTAssertEqual(shortcut.storedValue, "p|5")
        XCTAssertEqual(UserKeyboardShortcut(storedValue: shortcut.storedValue), shortcut)
        XCTAssertNil(UserKeyboardShortcut(storedValue: "p|0"))
        XCTAssertNil(UserKeyboardShortcut(storedValue: "too-long|5"))
        XCTAssertNil(UserKeyboardShortcut(storedValue: "p|255"))
    }

    @MainActor
    func testShortcutUpdatePersistsAndRejectsConflicts() throws {
        let paths = temporaryPaths()
        let model = AppModel(paths: paths)
        let custom = try XCTUnwrap(
            UserKeyboardShortcut(key: "k", modifierMask: UserKeyboardShortcut.command)
        )

        XCTAssertEqual(model.updateShortcut(custom, for: .toggleSidebar), .saved)
        XCTAssertEqual(model.shortcut(for: .toggleSidebar), custom)

        let reloaded = AppModel(paths: paths)
        XCTAssertEqual(reloaded.shortcut(for: .toggleSidebar), custom)

        let conflict = reloaded.updateShortcut(custom, for: .browser)
        guard case .conflict(.toggleSidebar) = conflict else {
            return XCTFail("Expected the duplicate shortcut to be rejected")
        }
        XCTAssertEqual(reloaded.shortcut(for: .browser), KeyboardShortcutAction.browser.defaultShortcut)
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarness-KeyboardShortcutTests-\(UUID().uuidString)", isDirectory: true)
        return SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
    }
}
