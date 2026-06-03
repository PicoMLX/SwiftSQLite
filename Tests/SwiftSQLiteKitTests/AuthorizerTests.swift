import Foundation
import Testing
@testable import SwiftSQLiteKit

@Suite(.timeLimit(.minutes(1)))
struct AuthorizerTests {

    private func memoryDB() async throws -> SQLiteConnection {
        try await SQLiteConnection(inMemory: .default, audit: InMemoryAuditSink())
    }

    /// Loose denial: the statement must fail at the SQL engine (a `SQLiteError`)
    /// — e.g. defensive-mode schema protection or a compile-omitted function,
    /// which are *not* authorizer-owned. Use `expectAuthDenied` for the
    /// authorizer's own DENYs so the test can't pass on an unrelated failure.
    private func expectDenied(_ db: SQLiteConnection, _ sql: String, _ label: String) async {
        do {
            _ = try await db.run(sql)
            Issue.record("expected '\(label)' to be denied")
        } catch is SQLiteError {
            // expected
        } catch {
            Issue.record("'\(label)' threw a non-SQLiteError: \(error)")
        }
    }

    /// Strict denial: must be an authorizer DENY (message contains "authoriz",
    /// i.e. "not authorized"). This fails if the authorizer case were removed
    /// and the statement started failing for some *other* reason — which the
    /// old any-error helper would have silently accepted.
    private func expectAuthDenied(_ db: SQLiteConnection, _ sql: String, _ label: String) async {
        do {
            _ = try await db.run(sql)
            Issue.record("expected '\(label)' to be denied")
        } catch let error as SQLiteError {
            // A SQLITE_DENY surfaces as "not authorized" for most operations,
            // but as "access to TABLE.COLUMN is prohibited" for a denied READ —
            // both are authorizer-owned denials (vs. defensive-mode "may not be
            // modified", a syntax error, or "no such function").
            let message = error.message.lowercased()
            #expect(message.contains("authoriz") || message.contains("prohibit"),
                    "'\(label)' must be an authorizer DENY, got: \(error.message)")
        } catch {
            Issue.record("'\(label)' threw a non-SQLiteError: \(error)")
        }
    }

    @Test func attachIsDenied() async throws {
        let db = try await memoryDB()
        await expectAuthDenied(db, "ATTACH DATABASE '/etc/passwd' AS x;", "ATTACH")
        await db.close()
    }

    @Test func detachIsDenied() async throws {
        let db = try await memoryDB()
        await expectAuthDenied(db, "DETACH DATABASE x;", "DETACH")
        await db.close()
    }

    @Test func writingSchemaTableIsDenied() async throws {
        let db = try await memoryDB()
        await expectDenied(db, "UPDATE sqlite_master SET name='evil';", "UPDATE sqlite_master")
        await db.close()
    }

    @Test func allUserPragmaIsDenied() async throws {
        let db = try await memoryDB()
        await expectAuthDenied(db, "PRAGMA writable_schema=ON;", "PRAGMA writable_schema")
        await expectAuthDenied(db, "PRAGMA user_version;", "PRAGMA user_version")
        await db.close()
    }

    @Test func reservedAuditNamespaceIsDenied() async throws {
        let db = try await memoryDB()
        await expectAuthDenied(db, "CREATE TABLE _audit_secret(x);", "CREATE _audit_*")
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
        await expectAuthDenied(readonly, "INSERT INTO t VALUES (2);", "INSERT (read-only)")
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

    /// The reserved namespace is denied for *reads*, not just creation — user
    /// SQL must not be able to query an `_audit*` table. Seed it with the
    /// reservation disabled, then reopen with it enabled and read it.
    @Test func readingReservedAuditTableIsDenied() async throws {
        let url = makeTempDatabaseURL()
        defer { cleanupTempDB(url) }
        var seedPolicy = EnginePolicy()
        seedPolicy.reservedTablePrefix = ""        // reservation off for seeding
        let seed = try await SQLiteConnection(
            url: url, policy: seedPolicy, audit: InMemoryAuditSink(),
            authorize: allowAllAuthorize)
        try await seed.execute(
            "CREATE TABLE _audit_secret(x); INSERT INTO _audit_secret VALUES (1);")
        await seed.close()

        let guarded = try await SQLiteConnection(
            url: url, audit: InMemoryAuditSink(), authorize: allowAllAuthorize)
        await expectAuthDenied(guarded, "SELECT x FROM _audit_secret;", "SELECT _audit_*")
        await guarded.close()
    }

    /// A reserved trigger name is rejected (the new object's name is in arg1) —
    /// the create-side guard must cover triggers, not just tables/indexes.
    @Test func reservedTriggerNameIsDenied() async throws {
        let db = try await memoryDB()
        try await db.execute("CREATE TABLE t(x);")
        await expectAuthDenied(
            db, "CREATE TRIGGER _audit_tr AFTER INSERT ON t BEGIN SELECT 1; END;",
            "CREATE TRIGGER _audit_*")
        await db.close()
    }

    /// A non-file URL is rejected up front: it would be authorized as one
    /// string but handed to sqlite3_open_v2 as a different filename.
    @Test func nonFileURLIsRejected() async throws {
        await #expect(throws: SQLiteEngineError.self) {
            _ = try await SQLiteConnection(
                url: URL(string: "https://evil.example/db")!,
                audit: InMemoryAuditSink(), authorize: allowAllAuthorize)
        }
    }

    /// The headline symlink-escape defense (PLAN §12): a DB path that is a
    /// symlink to a file *outside* the sandbox is resolved to its real target
    /// BEFORE the authorize gate runs, so a containment check sees — and can
    /// reject — the outside path rather than the in-sandbox link.
    @Test func symlinkedDatabasePathResolvesBeforeAuthorize() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftsqlite-symlink-\(UUID().uuidString)",
                                    isDirectory: true)
        let sandbox = root.appendingPathComponent("sandbox", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = outside.appendingPathComponent("secret.db")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let link = sandbox.appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        do {
            // Throw from the gate so the open aborts; the thrown path tells us
            // what the gate was actually handed.
            _ = try await SQLiteConnection(
                url: link, audit: InMemoryAuditSink(),
                authorize: { resolved, _ in throw AuthorizeSawPath(path: resolved.path) })
            Issue.record("open should have aborted in the authorize gate")
        } catch let seen as AuthorizeSawPath {
            #expect(seen.path.contains("/outside/") && seen.path.contains("secret.db"),
                    "authorize saw the unresolved link, not the target: \(seen.path)")
        }
    }
}
