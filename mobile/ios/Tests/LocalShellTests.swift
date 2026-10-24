import XCTest
@testable import HerNessMobile

@MainActor
final class LocalShellTests: XCTestCase {
    private var store: LocalWorkspaceStore!
    private var shell: LocalShell!

    override func setUp() async throws {
        store = LocalWorkspaceStore()
        // These tests exercise shell behavior, so seed an available workspace
        // explicitly instead of depending on a path persisted by an earlier
        // simulator installation.
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        store.refreshSelectedProjectAvailability()
        shell = LocalShell(store: store)
        try store.write(relativePath: "notes/todo.txt", data: Data("alpha\nbeta\ngamma\n".utf8))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("notes"))
    }

    func testPagedProjectFileCanBeEditedAndReread() async throws {
        ReadLedger.shared.reset()
        let original = (1...240).map { "line-\($0):" + String(repeating: "x", count: 1_000) }.joined(separator: "\n")
        try store.write(relativePath: "notes/project.swift", data: Data(original.utf8))
        let file = try store.resolve("notes/project.swift")
        for start in stride(from: 1, through: 240, by: 10) {
            _ = try AgentTools.readFile(at: file, offset: start, limit: 10)
            if start == 1 { XCTAssertEqual(ReadLedger.shared.state(for: file, data: Data(original.utf8)), .unread) }
        }
        XCTAssertEqual(ReadLedger.shared.state(for: file, data: Data(original.utf8)), .fresh)
        let result = await FileEditTools.edit(path: "notes/project.swift", edits: [["old_text": "line-180:", "new_text": "fixed-180:"]]) { _ in file }
        XCTAssertTrue(result.hasPrefix("Edited"), result)
        XCTAssertTrue(try AgentTools.readFile(at: file, offset: 180, limit: 1).hasPrefix("fixed-180:"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original.replacingOccurrences(of: "line-180:", with: "fixed-180:"))
    }

    func testPagesFromDifferentVersionsDoNotCombine() throws {
        ReadLedger.shared.reset()
        try store.write(relativePath: "notes/pages.txt", data: Data("one\ntwo\nthree\nfour".utf8))
        let file = try store.resolve("notes/pages.txt")
        _ = try AgentTools.readFile(at: file, limit: 2)
        let changed = Data("changed\ntwo\nthree\nfour".utf8)
        try changed.write(to: file)
        _ = try AgentTools.readFile(at: file, offset: 3)
        XCTAssertEqual(ReadLedger.shared.state(for: file, data: changed), .unread)
        _ = try AgentTools.readFile(at: file, limit: 2)
        XCTAssertEqual(ReadLedger.shared.state(for: file, data: changed), .fresh)
    }

    func testPipelineAndRedirection() throws {
        XCTAssertEqual(shell.execute("cat notes/todo.txt | grep a | wc"), "3 3 16")
        shell.execute("echo hello > notes/greeting.txt")
        XCTAssertEqual(shell.execute("cat notes/greeting.txt"), "hello")
        shell.execute("echo again >> notes/greeting.txt")
        XCTAssertEqual(shell.execute("cat notes/greeting.txt"), "hello\nagain")
    }

    func testQuotingKeepsArgumentsTogether() {
        XCTAssertEqual(shell.execute("echo \"one two\" three"), "one two three")
    }

    /// The jail is the whole security story for the in-app shell: no argument may
    /// escape the workspace root, however many `..` segments it uses.
    func testPathsCannotEscapeTheWorkspace() {
        // Shell arguments are normalised before they reach the filesystem, so the
        // traversal collapses to a path inside the root rather than reaching /etc.
        XCTAssertFalse(shell.execute("cat ../../../etc/passwd").contains("root:"))
        shell.execute("cd notes")
        XCTAssertEqual(shell.directory, "notes")
        shell.execute("cd ../../..")
        XCTAssertEqual(shell.directory, "")
        // And a path that survives normalisation is refused outright.
        XCTAssertThrowsError(try store.resolve("../escape.txt"))
    }

    func testUnknownCommandExplainsTheSandbox() {
        XCTAssertTrue(shell.execute("node index.js").contains("cannot launch external binaries"))
    }

    func testConditionalStopsOnFailure() {
        let output = shell.execute("cat missing.txt && echo reached")
        XCTAssertFalse(output.contains("reached"))
    }

    func testSQLiteRoundTrip() throws {
        let database = try store.resolve("notes/app.db")
        let sql = LocalSQL(path: database)
        _ = try sql.run("create table if not exists items (id integer primary key, name text);")
        _ = try sql.run("insert into items (name) values ('phone');")
        XCTAssertTrue(try sql.run("select name from items;").contains("phone"))
        try? FileManager.default.removeItem(at: database)
    }
}
