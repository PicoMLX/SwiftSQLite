import Foundation
import Testing
@testable import SwiftSQLiteKit

@Suite(.timeLimit(.minutes(1)))
struct EngineTests {

    @Test func crudRoundTrip() async throws {
        let db = try await SQLiteConnection(inMemory: .default, audit: InMemoryAuditSink())
        try await db.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, score REAL);")
        let changes = try await db.execute(
            "INSERT INTO t(name, score) VALUES ('alice', 1.5), ('bob', 2.0);")
        #expect(changes == 2)

        let result = try await db.query("SELECT id, name, score FROM t ORDER BY id;")
        #expect(result.columns == ["id", "name", "score"])
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == [.integer(1), .text("alice"), .real(1.5)])
        #expect(result.rows[1] == [.integer(2), .text("bob"), .real(2.0)])
        #expect(result.truncated == false)
        await db.close()
    }

    @Test func valueTypesMapToStorageClasses() async throws {
        let db = try await SQLiteConnection(inMemory: .default, audit: InMemoryAuditSink())
        try await db.execute("CREATE TABLE t(i INTEGER, r REAL, s TEXT, b BLOB, n);")
        try await db.execute("INSERT INTO t VALUES (42, 3.5, 'hi', x'00ff', NULL);")
        let row = try await db.query("SELECT i, r, s, b, n FROM t;").rows[0]
        #expect(row[0] == .integer(42))
        #expect(row[1] == .real(3.5))
        #expect(row[2] == .text("hi"))
        #expect(row[3] == .blob(Data([0x00, 0xff])))
        #expect(row[4] == .null)
        await db.close()
    }

    @Test func syntaxErrorMapsToSQLiteError() async throws {
        let db = try await SQLiteConnection(inMemory: .default, audit: InMemoryAuditSink())
        do {
            _ = try await db.query("SELEKT 1;")
            Issue.record("expected a SQLiteError for invalid SQL")
        } catch let error as SQLiteError {
            #expect(error.code != 0)
        }
        await db.close()
    }

    @Test func rowLimitSetsTruncated() async throws {
        var policy = EnginePolicy()
        policy.rowLimit = 5
        let db = try await SQLiteConnection(inMemory: policy, audit: InMemoryAuditSink())
        try await db.execute("CREATE TABLE t(x);")
        let values = (1...20).map { "(\($0))" }.joined(separator: ",")
        try await db.execute("INSERT INTO t(x) VALUES \(values);")

        let result = try await db.query("SELECT x FROM t ORDER BY x;")
        #expect(result.rows.count == 5)
        #expect(result.truncated == true)
        await db.close()
    }

    /// The total result-byte cap bounds a result set's memory even when the
    /// row count is far below `rowLimit` — `rowLimit × maxValueBytes` alone is
    /// not a real DoS bound.
    @Test func resultByteCapSetsTruncated() async throws {
        var policy = EnginePolicy()
        policy.rowLimit = 1_000_000          // not the limiting factor here
        policy.maxResultBytes = 10_000       // ~10 KB total
        let db = try await SQLiteConnection(inMemory: policy, audit: InMemoryAuditSink())
        try await db.execute("CREATE TABLE t(x);")
        let cell = String(repeating: "a", count: 1_000)   // ~1 KB per row
        let values = (1...200).map { _ in "('\(cell)')" }.joined(separator: ",")
        try await db.execute("INSERT INTO t(x) VALUES \(values);")

        let result = try await db.query("SELECT x FROM t;")
        #expect(result.truncated == true)
        #expect(result.rows.count < 200, "rows: \(result.rows.count)")
        await db.close()
    }

    /// Truncating a *writing* statement's output must not abandon its writes:
    /// an `INSERT … RETURNING` whose RETURNING rows hit the cap still inserts
    /// every row (drained to completion), unlike a read-only SELECT.
    @Test func truncatedWritingStatementStillCompletes() async throws {
        var policy = EnginePolicy()
        policy.rowLimit = 2
        let db = try await SQLiteConnection(inMemory: policy, audit: InMemoryAuditSink())
        try await db.execute("CREATE TABLE t(x);")
        let result = try await db.query(
            "INSERT INTO t(x) VALUES (1),(2),(3),(4),(5) RETURNING x;")
        #expect(result.truncated == true)
        #expect(result.rows.count == 2)
        let count = try await db.query("SELECT count(*) FROM t;")
        #expect(count.rows[0][0] == .integer(5),
                "all rows must be inserted, got \(count.rows[0][0])")
        await db.close()
    }

    @Test func longRunningQueryIsInterruptedByTimeout() async throws {
        var policy = EnginePolicy()
        policy.statementTimeout = .milliseconds(100)
        policy.rowLimit = 1_000_000_000
        let db = try await SQLiteConnection(inMemory: policy, audit: InMemoryAuditSink())
        do {
            // A non-terminating recursive CTE — only the progress handler
            // can stop it.
            _ = try await db.query(
                "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) "
                    + "SELECT max(x) FROM c;")
            Issue.record("expected the statement to be interrupted")
        } catch let error as SQLiteEngineError {
            #expect(error == .timedOut || error == .interrupted)
        } catch {
            // A raw SQLITE_INTERRUPT surfaced as SQLiteError is acceptable too.
        }
        await db.close()
    }

    @Test func openGateRejectionBlocksOpen() async throws {
        let url = makeTempDatabaseURL()
        defer { cleanupTempDB(url) }
        do {
            _ = try await SQLiteConnection(
                url: url, audit: InMemoryAuditSink(),
                authorize: { _, _ in throw StubDenied() })
            Issue.record("expected the open to be blocked by the authorize closure")
        } catch is StubDenied {
            // expected — and the file must not have been created
            #expect(FileManager.default.fileExists(atPath: url.path) == false)
        }
    }

    /// Statement-boundary detection: complete statements and whitespace/closed
    /// comments are boundaries; an unfinished statement or an *unterminated*
    /// block comment is not (a following dot-command must stay data).
    @Test func statementBoundaryClassification() {
        #expect(SQLiteSQL.isAtStatementBoundary("") == true)
        #expect(SQLiteSQL.isAtStatementBoundary("   \n\t") == true)
        #expect(SQLiteSQL.isAtStatementBoundary("-- a line comment\n") == true)
        #expect(SQLiteSQL.isAtStatementBoundary("/* a block */") == true)
        #expect(SQLiteSQL.isAtStatementBoundary("SELECT 1;") == true)
        #expect(SQLiteSQL.isAtStatementBoundary("SELECT 1") == false)
        #expect(SQLiteSQL.isAtStatementBoundary("/* unterminated") == false)
    }
}
