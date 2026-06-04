import Foundation
import Testing
@testable import SwiftSQLiteKit

@Suite(.timeLimit(.minutes(1)))
struct AuditTests {

    @Test func committedInsertAppearsInBothStreams() async throws {
        let sink = InMemoryAuditSink()
        let db = try await SQLiteConnection(inMemory: .default, audit: sink)
        try await db.execute("CREATE TABLE t(x);")
        try await db.execute("INSERT INTO t(x) VALUES (1);")
        await db.close()

        let attempted = await sink.attempted
        let committed = await sink.committed
        #expect(attempted.contains {
            if case .attempted("INSERT", _, true) = $0 { return true }
            return false
        })
        #expect(committed.contains {
            if case .committed(_, _, "INSERT") = $0 { return true }
            return false
        })
    }

    @Test func rolledBackDeleteIsAttemptedButNotCommitted() async throws {
        let sink = InMemoryAuditSink()
        let db = try await SQLiteConnection(inMemory: .default, audit: sink)
        try await db.execute("CREATE TABLE t(x); INSERT INTO t(x) VALUES (1), (2), (3);")
        try await db.run("BEGIN; DELETE FROM t; ROLLBACK;")

        // The rows survive the rolled-back DELETE.
        let surviving = try await db.query("SELECT count(*) FROM t;")
        #expect(surviving.rows[0][0] == .integer(3))
        await db.close()

        let attempted = await sink.attempted
        let committed = await sink.committed
        #expect(attempted.contains {
            if case .attempted("DELETE", _, _) = $0 { return true }
            return false
        })
        #expect(!committed.contains {
            if case .committed(_, _, "DELETE") = $0 { return true }
            return false
        })
    }

    @Test func deniedOperationIsRecordedAsAttemptedNotAllowed() async throws {
        let sink = InMemoryAuditSink()
        let db = try await SQLiteConnection(inMemory: .default, audit: sink)
        _ = try? await db.run("ATTACH DATABASE '/etc/passwd' AS x;")
        await db.close()

        let attempted = await sink.attempted
        #expect(attempted.contains {
            if case .attempted("ATTACH", _, false) = $0 { return true }
            return false
        })
    }

    @Test func auditTrailSurvivesDropTable() async throws {
        let url = makeTempDatabaseURL()
        defer { cleanupTempDB(url) }
        let auditURL = url.deletingLastPathComponent().appendingPathComponent("audit.log")
        let sink = FileAuditSink(url: auditURL)

        let db = try await SQLiteConnection(url: url, audit: sink, authorize: allowAllAuthorize)
        try await db.execute("CREATE TABLE t(x);")
        try await db.execute("INSERT INTO t(x) VALUES (1);")
        try await db.execute("DROP TABLE t;")
        await db.close()

        // The trail lives outside the DB, so DROP cannot erase it.
        let text = try String(contentsOf: auditURL, encoding: .utf8)
        #expect(text.contains("\"action\":\"INSERT\""))
        #expect(text.contains("\"action\":\"DROP_TABLE\""))
    }

    /// `DELETE FROM t` (no WHERE) is a truncate-optimization candidate that
    /// would skip `sqlite3_update_hook`; the authorizer returns IGNORE for
    /// DELETE so rows are removed individually and the committed stream still
    /// records them.
    @Test func committedDeleteAppearsInCommittedStream() async throws {
        let sink = InMemoryAuditSink()
        let db = try await SQLiteConnection(inMemory: .default, audit: sink)
        try await db.execute("CREATE TABLE t(x); INSERT INTO t(x) VALUES (1),(2),(3);")
        try await db.execute("DELETE FROM t;")
        await db.close()

        let committed = await sink.committed
        #expect(committed.contains {
            if case .committed(_, _, "DELETE") = $0 { return true }
            return false
        }, "committed DELETE rows should be audited, got \(committed)")
    }

    /// A row inserted inside a savepoint that is rolled back before COMMIT
    /// never lands, so it must not appear in the committed stream (the
    /// rollback hook doesn't fire for `ROLLBACK TO` — savepoint markers handle
    /// it).
    @Test func rolledBackSavepointInsertIsNotCommitted() async throws {
        let sink = InMemoryAuditSink()
        let db = try await SQLiteConnection(inMemory: .default, audit: sink)
        try await db.execute("CREATE TABLE t(x);")
        try await db.run(
            "BEGIN; SAVEPOINT s; INSERT INTO t(x) VALUES (1); ROLLBACK TO s; COMMIT;")

        let count = try await db.query("SELECT count(*) FROM t;")
        #expect(count.rows[0][0] == .integer(0))
        await db.close()

        let committed = await sink.committed
        #expect(!committed.contains {
            if case .committed(_, _, "INSERT") = $0 { return true }
            return false
        }, "rolled-back savepoint insert leaked into committed: \(committed)")
    }

    /// Control: an insert in a savepoint that is RELEASEd (merged into the
    /// outer transaction) and committed *does* appear in the committed stream.
    @Test func releasedSavepointInsertIsCommitted() async throws {
        let sink = InMemoryAuditSink()
        let db = try await SQLiteConnection(inMemory: .default, audit: sink)
        try await db.execute("CREATE TABLE t(x);")
        try await db.run(
            "BEGIN; SAVEPOINT s; INSERT INTO t(x) VALUES (1); RELEASE s; COMMIT;")
        await db.close()

        let committed = await sink.committed
        #expect(committed.contains {
            if case .committed(_, _, "INSERT") = $0 { return true }
            return false
        }, "released savepoint insert should be committed, got \(committed)")
    }

    /// The in-memory audit buffers are bounded: past `maxAuditRecords`, records
    /// are dropped after a single `_AUDIT_TRUNCATED` marker, so untrusted
    /// high-volume writes can't grow them without bound. Enforcement (the
    /// authorizer decision) is unaffected by the cap.
    @Test func auditBuffersAreCappedWithMarker() async throws {
        var policy = EnginePolicy()
        policy.maxAuditRecords = 10
        let sink = InMemoryAuditSink()
        let db = try await SQLiteConnection(inMemory: policy, audit: sink)
        try await db.execute("CREATE TABLE t(x);")
        let values = (1...100).map { "(\($0))" }.joined(separator: ",")
        try await db.run("INSERT INTO t(x) VALUES \(values);")
        await db.close()

        let all = await sink.events
        #expect(all.contains {
            if case .attempted(action: "_AUDIT_TRUNCATED", table: _, allowed: _) = $0 {
                return true
            }
            return false
        }, "expected a truncation marker, got \(all.count) events")
        // The committed stream did not record all 100 inserts (bounded).
        let committed = await sink.committed
        #expect(committed.count <= 20, "committed: \(committed.count)")
    }

    /// The cap also holds across many *separate* autocommit statements:
    /// commit() promotes pending into events each statement, so without a cap
    /// there (and a per-drain marker latch) the committed buffer would grow one
    /// record per statement.
    @Test func committedAuditBufferCappedAcrossManyStatements() async throws {
        var policy = EnginePolicy()
        policy.maxAuditRecords = 10
        let sink = InMemoryAuditSink()
        let db = try await SQLiteConnection(inMemory: policy, audit: sink)
        try await db.execute("CREATE TABLE t(x);")
        var script = ""
        for i in 1...100 { script += "INSERT INTO t(x) VALUES (\(i));" }
        try await db.run(script)
        await db.close()

        // ~cap + one marker + a few attempted, not ~110 from uncapped promotion.
        let all = await sink.events
        #expect(all.count <= 30, "audit buffer grew unbounded: \(all.count)")
    }

    /// SQLite resolves savepoint names case-insensitively, so a `ROLLBACK TO s`
    /// must trim a `SAVEPOINT S` even when the casing differs — otherwise the
    /// rolled-back row leaks into the committed stream.
    @Test func savepointRollbackIsCaseInsensitive() async throws {
        let sink = InMemoryAuditSink()
        let db = try await SQLiteConnection(inMemory: .default, audit: sink)
        try await db.execute("CREATE TABLE t(x);")
        try await db.run(
            "BEGIN; SAVEPOINT S; INSERT INTO t(x) VALUES (1); ROLLBACK TO s; COMMIT;")
        await db.close()

        let committed = await sink.committed
        #expect(!committed.contains {
            if case .committed(_, _, "INSERT") = $0 { return true }
            return false
        }, "case-mismatched ROLLBACK TO leaked into committed: \(committed)")
    }
}
