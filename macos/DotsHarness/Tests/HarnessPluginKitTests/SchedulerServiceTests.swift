// Copyright (c) 2026 DOTS
// Background daemon plist + scheduler reload / execution-gate tests.

import XCTest
import PluginRuntime
@testable import DotsHarnessCore

final class SchedulerServiceTests: XCTestCase {
    func testPlistPointsAtExecutableAndAutoloads() throws {
        let exe = URL(fileURLWithPath: "/Applications/Dots Harness.app/Contents/MacOS/DotsHarnessScheduler")
        let data = SchedulerService.plistData(executableURL: exe)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]

        XCTAssertEqual(plist?["Label"] as? String, "com.dots.harness.scheduler")
        XCTAssertEqual(plist?["ProgramArguments"] as? [String], [exe.path])
        XCTAssertEqual(plist?["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist?["KeepAlive"] as? Bool, true)
    }

    func testPlistURLIsAUserLaunchAgent() {
        XCTAssertTrue(SchedulerService.plistURL.path.hasSuffix(
            "Library/LaunchAgents/com.dots.harness.scheduler.plist"
        ))
    }
}

@MainActor
final class TaskSchedulerReloadTests: XCTestCase {
    private func makePaths() throws -> (SupportPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessSched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins"),
            presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models"),
            runtime: root.appendingPathComponent("runtime")
        )
        return (paths, root)
    }

    func testDoesNotFireDueTasksWhenExecutionGated() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(paths: paths)
        store.save([ScheduledTask(
            name: "t", cron: "* * * * *", prompt: "p", workspacePath: "/tmp",
            createdAt: Date().addingTimeInterval(-120)
        )])

        var runs = 0
        let scheduler = TaskScheduler(store: store, runsDueTasks: false) { _ in
            runs += 1
            return TaskScheduler.RunResult(ok: true)
        }
        scheduler.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runs, 0)
        scheduler.stop()
    }

    func testFiresDueTaskWhenExecutionEnabled() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(paths: paths)
        store.save([ScheduledTask(
            name: "t", cron: "* * * * *", prompt: "p", workspacePath: "/tmp",
            createdAt: Date().addingTimeInterval(-120)
        )])

        var runs = 0
        let scheduler = TaskScheduler(store: store, runsDueTasks: true) { _ in
            runs += 1
            return TaskScheduler.RunResult(ok: true)
        }
        scheduler.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runs, 1)
        scheduler.stop()
    }

    func testCrudReloadsExternalEdits() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(paths: paths)
        let a = ScheduledTask(name: "a", cron: "0 0 * * *", prompt: "p", workspacePath: "/tmp")
        store.save([a])

        let scheduler = TaskScheduler(store: store, runsDueTasks: false) { _ in
            TaskScheduler.RunResult(ok: true)
        }
        XCTAssertEqual(scheduler.tasks.map(\.name), ["a"])

        // Another process appends task "b".
        let b = ScheduledTask(name: "b", cron: "0 0 * * *", prompt: "p", workspacePath: "/tmp")
        store.save([a, b])

        // A local edit adds "c" and must not drop "b".
        let c = ScheduledTask(name: "c", cron: "0 0 * * *", prompt: "p", workspacePath: "/tmp")
        scheduler.upsert(c)

        XCTAssertEqual(Set(scheduler.tasks.map(\.name)), ["a", "b", "c"])
        XCTAssertEqual(Set(store.load().map(\.name)), ["a", "b", "c"])
    }
}
