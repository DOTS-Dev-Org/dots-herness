// Copyright (c) 2026 DOTS
// Git snapshot + command helpers used by the composer's branch popover.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore
import HarnessPluginKit

enum GitNetworkOp: Sendable {
    case fetch
    case push(String)
}

struct GitSnapshot {
    var isRepository: Bool
    var currentBranch: String?
    var branches: [String]
    var remoteBranches: [String]
    var uncommittedCount: Int
    var hasRemote: Bool
    var ahead: Int
    var behind: Int
    var added = 0
    var removed = 0

    static let empty = GitSnapshot(
        isRepository: false,
        currentBranch: nil,
        branches: [],
        remoteBranches: [],
        uncommittedCount: 0,
        hasRemote: false,
        ahead: 0,
        behind: 0
    )
}

struct GitCommandResult {
    let status: Int32
    let output: String
}

/// Collects the outputs of git commands that ran side by side.
final class GitOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: String] = [:]

    func set(_ value: String?, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    subscript(index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[index]
    }
}

enum GitRepository {
    static func snapshot(at path: String) -> GitSnapshot {
        guard !path.isEmpty,
              let marker = run(["rev-parse", "--is-inside-work-tree"], at: path),
              marker.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return .empty
        }

        // The remaining reads are independent, so they run together: the snapshot costs
        // the slowest command (`status`) instead of the sum of all seven processes.
        let commands: [[String]] = [
            ["branch", "--show-current"],
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes"],
            ["status", "--porcelain", "--untracked-files=all"],
            ["remote"],
            // Ahead/behind vs the current branch's upstream, if one is configured.
            ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
            ["diff", "HEAD", "--numstat"],
        ]
        let outputs = GitOutputs()
        DispatchQueue.concurrentPerform(iterations: commands.count) { index in
            outputs.set(run(commands[index], at: path), at: index)
        }

        let branch = outputs[0]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let branches = (outputs[1] ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let remoteBranches = (outputs[2] ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasSuffix("/HEAD") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let uncommittedCount = (outputs[3] ?? "")
            .split(whereSeparator: \.isNewline)
            .count
        let hasRemote = !(outputs[4] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var ahead = 0
        var behind = 0
        if let counts = outputs[5] {
            let parts = counts.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
            if parts.count == 2 {
                behind = Int(parts[0]) ?? 0
                ahead = Int(parts[1]) ?? 0
            }
        }

        var added = 0
        var removed = 0
        for line in (outputs[6] ?? "").split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t")
            if cols.count >= 2 { added += Int(cols[0]) ?? 0; removed += Int(cols[1]) ?? 0 }
        }

        var snapshot = GitSnapshot(
            isRepository: true,
            currentBranch: branch?.isEmpty == true ? nil : branch,
            branches: branches,
            remoteBranches: remoteBranches,
            uncommittedCount: uncommittedCount,
            hasRemote: hasRemote,
            ahead: ahead,
            behind: behind
        )
        snapshot.added = added
        snapshot.removed = removed
        return snapshot
    }

    /// `git fetch --prune` against all remotes. Relies on the user's system git
    /// credentials (SSH agent or credential helper); the app stores no token.
    static func fetch(at path: String) -> String? {
        let result = runResult(["fetch", "--prune", "--all"], at: path)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? AppCopy.text("git.fetchFailed") : detail
        }
        return nil
    }

    /// Push the branch to `origin`, setting upstream on first push.
    static func push(_ branch: String, at path: String) -> String? {
        guard !branch.isEmpty, !branch.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return AppCopy.text("git.pushFailed")
        }
        let result = runResult(["push", "--set-upstream", "origin", branch], at: path)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? AppCopy.text("git.pushFailed") : detail
        }
        return nil
    }

    static func checkout(_ branch: String, at path: String) -> String? {
        guard !branch.isEmpty, !branch.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return AppCopy.text("git.checkoutFailed")
        }
        let result = runResult(["switch", branch], at: path)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? AppCopy.text("git.checkoutFailed") : detail
        }
        return nil
    }

    static func createBranch(_ branch: String, at path: String) -> String? {
        guard !branch.isEmpty, !branch.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return AppCopy.text("git.createBranchFailed")
        }
        let result = runResult(["switch", "-c", branch], at: path)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? AppCopy.text("git.createBranchFailed") : detail
        }
        return nil
    }

    private static func run(_ arguments: [String], at path: String) -> String? {
        let result = runResult(arguments, at: path)
        return result.status == 0 ? result.output : nil
    }

    private static func runResult(_ arguments: [String], at path: String) -> GitCommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return GitCommandResult(status: 1, output: error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitCommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
