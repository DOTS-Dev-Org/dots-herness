import XCTest
@testable import HerNessMobile

@MainActor
final class LocalShellTests: XCTestCase {
    private var store: LocalWorkspaceStore!
    private var shell: LocalShell!

    override func setUp() async throws {
        store = LocalWorkspaceStore()
        shell = LocalShell(store: store)
        try store.write(relativePath: "notes/todo.txt", data: Data("alpha\nbeta\ngamma\n".utf8))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("notes"))
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
