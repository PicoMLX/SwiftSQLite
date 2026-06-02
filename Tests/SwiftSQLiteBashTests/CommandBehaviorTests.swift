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
}
