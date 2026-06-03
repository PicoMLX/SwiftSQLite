import BashCommandKit
import BashInterpreter
import Foundation
import Testing
import SwiftSQLiteBash

/// PLAN.md §12 — output modes, safe/disabled dot-commands, SQL escape
/// hatches end-to-end through the command.
@Suite(.timeLimit(.minutes(1)))
struct CommandBehaviorTests {

    @Test func jsonOutputMode() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let result = try await runCapturing(
            shell, "sqlite3 -json :memory: \"SELECT 1 AS a, 'x' AS b;\"")
        #expect(result.status.isSuccess)
        #expect(result.stdout.contains("\"a\":1"))
        #expect(result.stdout.contains("\"b\":\"x\""))
    }

    /// JSON output preserves column order and duplicate column names — a
    /// dictionary-backed encoder reorders keys and collapses duplicates, which
    /// is silent data loss for `SELECT *` over a join.
    @Test func jsonPreservesColumnOrderAndDuplicates() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let result = try await runCapturing(
            shell, "sqlite3 -json :memory: \"SELECT 2 AS b, 1 AS a, 3 AS a;\"")
        #expect(result.status.isSuccess)
        #expect(result.stdout.contains("{\"b\":2,\"a\":1,\"a\":3}"),
                "stdout: \(result.stdout)")
    }

    /// Dot-commands interpolate user table names into SQL. A name containing a
    /// double-quote must be escaped (doubled) for the identifier context, or
    /// `.dump`'s `SELECT * FROM "<name>"` becomes a syntax error / injection.
    @Test func dumpEscapesQuotesInTableIdentifiers() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let script = """
            CREATE TABLE "a""b" (x);
            INSERT INTO "a""b" VALUES (1);
            .dump
            """
        let result = try await runCapturing(shell, "sqlite3 :memory:", stdin: script)
        #expect(result.status.isSuccess, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("INSERT INTO \"a\"\"b\""), "dump: \(result.stdout)")
    }

    /// A comment-only buffer before a dot-command must not swallow it: the
    /// statement-boundary check treats whitespace + comments as no pending SQL
    /// (e.g. `-- note\n.tables`), matching the sqlite3 shell.
    @Test func dotCommandAfterCommentOnlyBufferRuns() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let result = try await runCapturing(
            shell, "sqlite3 :memory:", stdin: "-- a comment\n.tables\n")
        #expect(result.status.isSuccess, "stderr: \(result.stderr)")
    }

    @Test func csvWithHeader() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let result = try await runCapturing(
            shell, "sqlite3 -csv -header :memory: \"SELECT 1 AS a, 2 AS b;\"")
        #expect(result.status.isSuccess)
        #expect(result.stdout.contains("a,b"))
        #expect(result.stdout.contains("1,2"))
    }

    @Test func dotTablesListsUserTables() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let script = """
            CREATE TABLE alpha(x);
            CREATE TABLE beta(y);
            .tables
            """
        let result = try await runCapturing(shell, "sqlite3 :memory:", stdin: script)
        #expect(result.status.isSuccess)
        #expect(result.stdout.contains("alpha"))
        #expect(result.stdout.contains("beta"))
    }

    @Test func disabledDotCommandIsRejected() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let result = try await runCapturing(
            shell, "sqlite3 :memory:", stdin: ".shell echo pwned\n")
        #expect(!result.status.isSuccess)
        #expect(result.stderr.contains("disabled"))
        #expect(!result.stdout.contains("pwned"))
    }

    @Test func attachIsDeniedThroughCommand() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let result = try await runCapturing(
            shell, "sqlite3 :memory: \"ATTACH DATABASE '/etc/passwd' AS x;\"")
        #expect(!result.status.isSuccess)
        #expect(result.stderr.lowercased().contains("authoriz"))
    }

    @Test func userPragmaIsDeniedThroughCommand() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let result = try await runCapturing(
            shell, "sqlite3 :memory: 'PRAGMA writable_schema=ON;'")
        #expect(!result.status.isSuccess)
    }

    @Test func registerSQLiteCommandsInstallsRunnableCommand() async throws {
        let shell = Shell()
        shell.registerSQLiteCommands()   // installs at /usr/bin/sqlite3 (on PATH)
        let result = try await runCapturing(shell, "sqlite3 :memory: 'SELECT 42;'")
        #expect(result.status.isSuccess)
        #expect(result.stdout.contains("42"))
    }

    @Test func dotTablesIncludesTempTables() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let script = """
            CREATE TABLE perm(x);
            CREATE TEMP TABLE tmp(y);
            .tables
            """
        let result = try await runCapturing(shell, "sqlite3 :memory:", stdin: script)
        #expect(result.status.isSuccess, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("perm"))
        #expect(result.stdout.contains("tmp"))
    }

    @Test func dotSchemaIncludesTempObjects() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let script = """
            CREATE TEMP TABLE tmp(y);
            .schema tmp
            """
        let result = try await runCapturing(shell, "sqlite3 :memory:", stdin: script)
        #expect(result.status.isSuccess, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("tmp"))
    }

    /// Creating an object in the reserved `_audit*` namespace must be denied
    /// even when the owning table is allowed (the new index/trigger name is in
    /// arg1, which the reserved-prefix guard now also checks).
    @Test func reservedIndexNameIsDenied() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let result = try await runCapturing(
            shell, "sqlite3 :memory:",
            stdin: "CREATE TABLE t(x);\nCREATE INDEX _audit_i ON t(x);\n")
        #expect(!result.status.isSuccess)
        #expect(result.stderr.lowercased().contains("authoriz"),
                "stderr: \(result.stderr)")
    }

    @Test func dotIndexesIncludesTempIndexes() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let script = """
            CREATE TEMP TABLE tmp(x);
            CREATE INDEX tmp_idx ON tmp(x);
            .indexes
            """
        let result = try await runCapturing(shell, "sqlite3 :memory:", stdin: script)
        #expect(result.status.isSuccess, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("tmp_idx"))
    }
}
