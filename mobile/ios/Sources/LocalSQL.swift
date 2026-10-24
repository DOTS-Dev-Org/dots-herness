import Foundation
import SQLite3

/// SQLite is part of both mobile operating systems, so "SQL on the phone" needs
/// no runtime download: open a database file inside the workspace and run
/// statements against it. Used by the `sqlite` shell command and the `sql` agent tool.
struct LocalSQL {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let maximumRows = 500

    let path: URL

    /// Runs one or more statements and renders the last result set as text.
    func run(_ script: String) throws -> String {
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK, let database = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            sqlite3_close(handle)
            throw SQLError.message(message)
        }
        defer { sqlite3_close(database) }

        var output: [String] = []
        var remaining = script
        while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var statement: OpaquePointer?
            var nextRemaining = ""
            let prepared = remaining.withCString { start -> Int32 in
                var tail: UnsafePointer<CChar>?
                let result = sqlite3_prepare_v2(database, start, -1, &statement, &tail)
                if let tail { nextRemaining = String(cString: tail) }
                return result
            }
            guard prepared == SQLITE_OK else {
                throw SQLError.message(String(cString: sqlite3_errmsg(database)))
            }
            guard let statement else {
                if nextRemaining == remaining { break }
                remaining = nextRemaining
                continue
            }
            defer { sqlite3_finalize(statement) }

            let columns = (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
            var rows: [[String]] = []
            var reachedRowLimit = false
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw SQLError.message(String(cString: sqlite3_errmsg(database)))
                }
                rows.append((0..<Int32(columns.count)).map { column in
                    guard let value = sqlite3_column_text(statement, column) else { return "NULL" }
                    return String(cString: value)
                })
                if rows.count >= Self.maximumRows {
                    reachedRowLimit = true
                    break
                }
            }
            if columns.isEmpty {
                output = ["\(sqlite3_changes(database)) row(s) changed."]
            } else {
                output = [columns.joined(separator: " | "), columns.map { String(repeating: "-", count: max($0.count, 3)) }.joined(separator: "-+-")]
                    + rows.map { $0.joined(separator: " | ") }
                if reachedRowLimit { output.append("… first \(Self.maximumRows) rows") }
            }

            if nextRemaining == remaining { break }
            remaining = nextRemaining
        }
        return output.joined(separator: "\n")
    }
}

enum SQLError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return "sqlite: \(value)" } }
}
