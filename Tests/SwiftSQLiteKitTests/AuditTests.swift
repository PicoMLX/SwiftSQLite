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
}
