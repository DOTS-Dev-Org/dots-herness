// Copyright (c) 2026 DOTS
// Drives the user's own Safari or Chrome through Apple Events: no extra browser,
// no extension, the user's signed-in profile. macOS asks once per browser for
// Automation consent.

import Foundation

enum SystemBrowser: String, Sendable {
    case safari = "Safari"
    case chrome = "Google Chrome"

    static let textLimit = 20_000

    /// Opens a page the run owns and returns its pageID. Safari tabs have no stable
    /// id, so a Safari page is its own window; a Chrome page is a tab, found by id.
    func open(url: String) async throws -> String {
        switch self {
        case .safari:
            // Closed windows linger in Safari's list and "front window" can name one,
            // so the new window is the id that was not there before.
            let id = try await run("""
                if not running then activate
                set known to id of every window
                make new document with properties {URL:item 1 of argv}
                repeat with n in (get id of every window)
                    if known does not contain (n as integer) then return (n as integer)
                end repeat
                error "Safari did not open a window."
                """, [url])
            return "safari-\(id)"
        case .chrome:
            let id = try await run("""
                if not running then activate
                if (count of windows) is 0 then make new window
                set t to make new tab at end of tabs of front window with properties {URL:item 1 of argv}
                return id of t
                """, [url])
            return "chrome-\(id)"
        }
    }

    func navigate(pageID: String, url: String) async throws {
        _ = try await onPage(pageID, safari: "set URL of current tab of w to item 2 of argv",
                             chrome: "set URL of t to item 2 of argv", [url])
    }

    /// Page text. Chrome needs View > Developer > Allow JavaScript from Apple Events.
    func text(pageID: String) async throws -> String {
        let text = try await onPage(pageID, safari: "return text of current tab of w",
                                    chrome: "return execute t javascript \"document.body.innerText\"")
        return String(text.prefix(Self.textLimit))
    }

    func close(pageID: String) async throws {
        _ = try await onPage(pageID, safari: "close w", chrome: "close t")
    }

    private func onPage(_ pageID: String, safari: String, chrome: String, _ extra: [String] = []) async throws -> String {
        let id = String(pageID.drop { $0 != "-" }.dropFirst())
        guard Int(id) != nil else { throw BrowserSessionError.pageNotOwned }
        switch self {
        case .safari:
            return try await run("""
                set w to window id ((item 1 of argv) as integer)
                \(safari)
                """, [id] + extra)
        case .chrome:
            return try await run("""
                repeat with w in windows
                    repeat with t in tabs of w
                        if ((id of t) as text) is (item 1 of argv) then
                            \(chrome)
                            return ""
                        end if
                    end repeat
                end repeat
                error "The page is no longer open."
                """, [id] + extra)
        }
    }

    /// Values travel as argv, never spliced into the script text.
    private func run(_ body: String, _ arguments: [String]) async throws -> String {
        let script = """
            on run argv
                with timeout of 30 seconds
                    tell application "\(rawValue)"
                        \(body)
                    end tell
                end timeout
            end run
            """
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script] + arguments
            let output = Pipe(), failure = Pipe()
            process.standardOutput = output
            process.standardError = failure
            try process.run()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = failure.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw BrowserSessionError.systemBrowser(
                    String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
