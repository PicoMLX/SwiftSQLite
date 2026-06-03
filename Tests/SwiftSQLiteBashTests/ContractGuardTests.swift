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

    /// An explicitly-requested `-audit PATH` that the sandbox denies must fail
    /// the command — not silently downgrade to in-memory and run the SQL
    /// unaudited. The DB itself is inside the workspace (it would open fine).
    @Test func explicitAuditPathDeniedFailsClosed() async throws {
        try await withTempDirectory { workspace in
            let shell = Shell(
                fileSystem: MountedFileSystem(
                    mounts: [.init(virtual: workspace, host: workspace)],
                    backing: RealFileSystem()),
                environment: Environment(variables: [:], workingDirectory: workspace))
            shell.sandbox = Sandbox.bashWorkspace(workspace: workspace)
            shell.installShellBuiltin(SqliteCommand.self)

            let result = try await runCapturing(
                shell,
                "sqlite3 -audit /etc/swiftsqlite-evil-audit.log "
                    + "\(workspace)/t.db 'CREATE TABLE t(x);'")
            #expect(!result.status.isSuccess)
            #expect(result.stderr.contains("audit"), "stderr: \(result.stderr)")
        }
    }

    /// An explicit `-audit PATH` that resolves to the database file itself must
    /// be rejected: a FileAuditSink appending JSON Lines into the live DB would
    /// corrupt it. (The trail is contractually written *outside* the database.)
    @Test func auditPathOverlappingDatabaseIsRejected() async throws {
        try await withTempDirectory { workspace in
            let shell = Shell(
                fileSystem: MountedFileSystem(
                    mounts: [.init(virtual: workspace, host: workspace)],
                    backing: RealFileSystem()),
                environment: Environment(variables: [:], workingDirectory: workspace))
            shell.sandbox = Sandbox.bashWorkspace(workspace: workspace)
            shell.installShellBuiltin(SqliteCommand.self)

            let result = try await runCapturing(
                shell,
                "sqlite3 -audit \(workspace)/t.db \(workspace)/t.db 'CREATE TABLE t(x);'")
            #expect(!result.status.isSuccess)
            #expect(result.stderr.contains("overlap"), "stderr: \(result.stderr)")
        }
    }

    /// Real disk reached *through* a mount but with NO sandbox gate: the guard
    /// can't prove virtual==host, so a file database must fail closed (§4)
    /// rather than open the wrong host path.
    @Test func mountedFilesystemWithoutSandboxRefusesFileDatabase() async throws {
        try await withTempDirectory { workspace in
            let shell = Shell(
                fileSystem: MountedFileSystem(
                    mounts: [.init(virtual: workspace, host: workspace)],
                    backing: RealFileSystem()),
                environment: Environment(variables: [:], workingDirectory: workspace))
            // shell.sandbox intentionally NOT set.
            shell.installShellBuiltin(SqliteCommand.self)
            let result = try await runCapturing(
                shell, "sqlite3 -no-audit \(workspace)/t.db 'SELECT 1;'")
            #expect(!result.status.isSuccess)
        }
    }

    /// An explicit `-audit PATH` that is authorized but unusable as a log file
    /// (here, an existing directory) must fail closed via the preflight open,
    /// not run SQL unaudited and only error on the first post-commit flush.
    @Test func explicitAuditPathThatIsUnusableFailsClosed() async throws {
        try await withTempDirectory { workspace in
            let shell = Shell(
                fileSystem: MountedFileSystem(
                    mounts: [.init(virtual: workspace, host: workspace)],
                    backing: RealFileSystem()),
                environment: Environment(variables: [:], workingDirectory: workspace))
            shell.sandbox = Sandbox.bashWorkspace(workspace: workspace)
            shell.installShellBuiltin(SqliteCommand.self)

            let auditDir = "\(workspace)/auditdir"
            try FileManager.default.createDirectory(
                atPath: auditDir, withIntermediateDirectories: true)
            let result = try await runCapturing(
                shell, "sqlite3 -audit \(auditDir) \(workspace)/t.db 'CREATE TABLE t(x);'")
            #expect(!result.status.isSuccess)
            #expect(result.stderr.contains("audit"), "stderr: \(result.stderr)")
        }
    }
}
