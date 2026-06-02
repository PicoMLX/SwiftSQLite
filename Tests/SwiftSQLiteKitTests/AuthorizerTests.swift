import Foundation
import Testing
@testable import SwiftSQLiteKit

@Suite(.timeLimit(.minutes(1)))
struct AuthorizerTests {

    private func memoryDB() async throws -> SQLiteConnection {
        try await SQLiteConnection(inMemory: .default, audit: InMemoryAuditSink())
    }

    private func expectDenied(_ db: SQLiteConnection, _ sql: String, _ label: String) async {
        do {
            _ = try await db.run(sql)
            Issue.record("expected '\(label)' to be denied")
        } catch {
            // expected — authorizer DENY surfaces as a SQLiteError
        }
    }

    @Test func attachIsDenied() async throws {
        let db = try await memoryDB()
        await expectDenied(db, "ATTACH DATABASE '/etc/passwd' AS x;", "ATTACH")
        await db.close()
    }

    @Test func detachIsDenied() async throws {
        let db = try await memoryDB()
        await expectDenied(db, "DETACH DATABASE x;", "DETACH")
        await db.close()
    }

    @Test func writingSchemaTableIsDenied() async throws {
        let db = try await memoryDB()
        await expectDenied(db, "UPDATE sqlite_master SET name='evil';", "UPDATE sqlite_master")
        await db.close()
    }

    @Test func allUserPragmaIsDenied() async throws {
        let db = try await memoryDB()
        await expectDenied(db, "PRAGMA writable_schema=ON;", "PRAGMA writable_schema")
        await expectDenied(db, "PRAGMA user_version;", "PRAGMA user_version")
        await db.close()
    }

    @Test func reservedAuditNamespaceIsDenied() async throws {
        let db = try await memoryDB()
        await expectDenied(db, "CREATE TABLE _audit_secret(x);", "CREATE _audit_*")
        await db.close()
    }

    @Test func loadExtensionFunctionIsAbsent() async throws {
        let db = try await memoryDB()
        // Compile-omitted: the function does not exist, so prepare fails.
        await expectDenied(db, "SELECT load_extension('evil.so');", "load_extension()")
        await db.close()
    }

    @Test func readOnlyPolicyDeniesWrites() async throws {
        // Seed a file, reopen read-only, attempt a write.
        let url = makeTempDatabaseURL()
        defer { cleanupTempDB(url) }
        let writable = try await SQLiteConnection(url: url, audit: InMemoryAuditSink(), authorize: allowAllAuthorize)
        try await writable.execute("CREATE TABLE t(x); INSERT INTO t VALUES (1);")
        await writable.close()

        var policy = EnginePolicy()
        policy.readOnly = true
        let readonly = try await SQLiteConnection(url: url, policy: policy, audit: InMemoryAuditSink(), authorize: allowAllAuthorize)
        // reads work
        let count = try await readonly.query("SELECT count(*) FROM t;")
        #expect(count.rows[0][0] == .integer(1))
        // writes are denied
        await expectDenied(readonly, "INSERT INTO t VALUES (2);", "INSERT (read-only)")
        await readonly.close()
    }

    @Test func ordinarySQLIsAllowed() async throws {
        let db = try await memoryDB()
        try await db.execute("CREATE TABLE t(a, b);")
        try await db.execute("INSERT INTO t VALUES (1, 'x');")
        try await db.execute("CREATE INDEX idx_t_a ON t(a);")
        let rows = try await db.query("SELECT a, b FROM t WHERE a = 1;").rows
        #expect(rows == [[.integer(1), .text("x")]])
        await db.close()
    }
}
