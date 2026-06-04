import BashCommandKit
import BashInterpreter
import Foundation
import Testing
@testable import SwiftSQLiteBash
@testable import SwiftSQLiteKit

/// Regression coverage for two Codex-flagged correctness bugs:
///  - `.dump` silently truncating tables past the row cap, and
///  - dot-command detection misfiring on a `.`-leading line that is really
///    data inside an unfinished multi-line SQL statement.
@Suite(.timeLimit(.minutes(1)))
struct DumpAndParsingTests {

    // MARK: .dump truncation

    /// With more rows than the cap, `.dump` must abort loudly rather than emit
    /// a truncated dump that replays (with a valid-looking COMMIT) as silent
    /// data loss.
    @Test func dumpAbortsInsteadOfSilentlyTruncating() async throws {
        var policy = EnginePolicy()
        policy.rowLimit = 2
        let conn = try await SQLiteConnection(inMemory: policy,
                                              audit: InMemoryAuditSink())
        try await conn.execute(
            "CREATE TABLE t(x); INSERT INTO t(x) VALUES (1),(2),(3);")
        let state = SessionState(options: OutputOptions(),
                                 databasePath: ":memory:")
        // The truncation path returns before any stdout, so no current shell
        // is needed.
        let result = await DotCommandRunner.run(".dump",
                                                connection: conn, state: state)
        await conn.close()

        guard case .failed(let message) = result else {
            Issue.record("expected .dump to fail on truncation, got \(result)")
            return
        }
        #expect(message.contains("export cap") || message.contains("incomplete"))
    }

    // MARK: dot-command vs. SQL data

    /// A `.`-leading line that falls *inside* an open string literal is data,
    /// not a command: the value must round-trip and nothing should error.
    /// (Under the old bare-`hasPrefix(".")` check this flushed the incomplete
    /// INSERT and misfired `.tables`.)
    @Test func dotLineInsideStringLiteralIsTreatedAsData() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let script = """
            CREATE TABLE t(x);
            INSERT INTO t(x) VALUES('before
            .tables
            after');
            SELECT x FROM t;
            """
        let result = try await runCapturing(shell, "sqlite3 :memory:",
                                            stdin: script)
        // Old behaviour: the ".tables" line flushed the half-written INSERT,
        // erroring (failure status) and misfiring the command. New behaviour:
        // the statement completes and the literal round-trips verbatim.
        #expect(result.status.isSuccess, "stderr: \(result.stderr)")
        #expect(result.stdout.contains(".tables"))
    }

    /// Sanity: dot-commands interleaved with *complete* statements still work
    /// — the boundary check must treat a finished (semicolon-terminated)
    /// buffer as a boundary, not block the command.
    @Test func dotCommandAfterCompleteStatementStillRuns() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let script = """
            CREATE TABLE alpha(x);
            .tables
            """
        let result = try await runCapturing(shell, "sqlite3 :memory:",
                                            stdin: script)
        #expect(result.status.isSuccess, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("alpha"))
    }

    // MARK: .dump fidelity

    /// `.dump` must preserve the AUTOINCREMENT high-water mark by emitting
    /// `sqlite_sequence`, so a restore doesn't reuse a freed id.
    @Test func dumpPreservesAutoincrementSequence() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let script = """
            CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, v);
            INSERT INTO t(v) VALUES ('a'),('b'),('c');
            DELETE FROM t WHERE id=3;
            .dump
            """
        let result = try await runCapturing(shell, "sqlite3 :memory:",
                                            stdin: script)
        #expect(result.status.isSuccess, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("INSERT INTO sqlite_sequence"),
                "dump should carry the AUTOINCREMENT counter:\n\(result.stdout)")
    }

    /// A TEXT value with an embedded NUL must be dumped NUL-safely (a hex blob
    /// cast), not as a raw quoted literal that would truncate the replayed
    /// script at the NUL.
    @Test func dumpEncodesEmbeddedNulSafely() async throws {
        let shell = Shell()
        shell.installShellBuiltin(SqliteCommand.self)
        let script = """
            CREATE TABLE t(x);
            INSERT INTO t(x) VALUES('a' || char(0) || 'b');
            .dump
            """
        let result = try await runCapturing(shell, "sqlite3 :memory:",
                                            stdin: script)
        #expect(result.status.isSuccess, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("CAST(x'"),
                "NUL-bearing TEXT should dump as a hex-blob cast:\n\(result.stdout)")
    }
}
