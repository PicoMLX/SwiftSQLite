import BashCommandKit
import BashInterpreter
import Foundation
import Testing
import SwiftSQLiteBash

/// PLAN.md §12 — the native-file contract (§4) test matrix.
@Suite(.timeLimit(.minutes(1)))
struct ContractGuardTests {

    @Test func inMemoryFilesystemRefusesFileDatabase() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        shell.installShellBuiltin(SqliteCommand.self)
        let result = try await runCapturing(shell, "sqlite3 /data/x.db 'SELECT 1;'")
        #expect(!result.status.isSuccess)
        #expect(result.stderr.contains("real disk"))
    }

    @Test func memoryDatabaseRunsRegardlessOfBacking() async throws {
        // ':memory:' is the supported answer for a non-disk backing.
        let shell = Shell(fileSystem: InMemoryFileSystem())
        shell.installShellBuiltin(SqliteCommand.self)
        let result = try await runCapturing(shell, "sqlite3 :memory: 'SELECT 1 + 1;'")
        #expect(result.status.isSuccess)
        #expect(result.stdout.contains("2"))
    }

    @Test func realFileDatabaseRoundTrips() async throws {
        try await withTempDirectory { directory in
            let dbPath = "\(directory)/t.db"
            let shell = Shell(fileSystem: RealFileSystem())
            shell.installShellBuiltin(SqliteCommand.self)
            let result = try await runCapturing(
                shell,
                "sqlite3 -no-audit \(dbPath) 'CREATE TABLE t(x); INSERT INTO t VALUES (7); SELECT x FROM t;'")
            #expect(result.status.isSuccess)
            #expect(result.stdout.contains("7"))
        }
    }

    @Test func databaseOutsideSandboxIsDenied() async throws {
        try await withTempDirectory { workspace in
            let shell = Shell(
                fileSystem: MountedFileSystem(
                    mounts: [.init(virtual: workspace, host: workspace)],
                    backing: RealFileSystem()),
                environment: Environment(variables: [:], workingDirectory: workspace))
            shell.sandbox = Sandbox.bashWorkspace(workspace: workspace)
            shell.installShellBuiltin(SqliteCommand.self)

            // Backing reaches real disk (guard passes), but the path is
            // outside the workspace → sandbox.authorize must deny the open.
            let result = try await runCapturing(
                shell, "sqlite3 -no-audit /etc/swiftsqlite-evil.db 'SELECT 1;'")
            #expect(!result.status.isSuccess)
        }
    }
}
