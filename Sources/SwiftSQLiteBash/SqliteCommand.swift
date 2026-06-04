import ArgumentParser
import BashCommandKit
import BashInterpreter
import Foundation
import SwiftSQLiteKit

/// `sqlite3 [OPTIONS] DBFILE [SQL]` — run SQL against a SQLite database
/// confined to the SwiftBash sandbox (PLAN.md §10).
///
/// SQL comes from the trailing arguments, or from stdin to EOF when none
/// are given. Argv is captured raw (`.captureForPassthrough`) and parsed
/// here so arbitrary SQL — which routinely contains `-`, `;`, quotes —
/// is never mistaken for option syntax.
public struct SqliteCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sqlite3",
        abstract: "Run SQL against a SQLite database inside the SwiftBash sandbox."
    )

    @Argument(parsing: .captureForPassthrough, help: "[OPTIONS] DBFILE [SQL]")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var options = OutputOptions()
        var readOnly = false
        var auditEnabled = true
        var auditPath: String?
        var index = 0

        // --- leading options (sqlite3-style single-dash long options) ---
        while index < rawArgv.count {
            let token = rawArgv[index]
            guard token.hasPrefix("-"), token != "-" else { break }
            switch token {
            case "-readonly":
                readOnly = true; index += 1
            case "-header", "-headers":
                options.header = true; index += 1
            case "-noheader":
                options.header = false; index += 1
            case "-csv":
                options.mode = .csv; index += 1
            case "-json":
                options.mode = .json; index += 1
            case "-line":
                options.mode = .line; index += 1
            case "-list":
                options.mode = .list; index += 1
            case "-column":
                options.mode = .column; options.header = true; index += 1
            case "-mode":
                guard let value = optionValue(after: index), let mode = OutputMode(rawValue: value) else {
                    return usageError("-mode requires one of: "
                        + OutputMode.allCases.map(\.rawValue).joined(separator: ", "))
                }
                options.mode = mode
                if mode == .column { options.header = true }
                index += 2
            case "-separator", "-fieldsep":
                guard let value = optionValue(after: index) else {
                    return usageError("-separator requires an argument")
                }
                options.separator = value; index += 2
            case "-nullvalue":
                guard let value = optionValue(after: index) else {
                    return usageError("-nullvalue requires an argument")
                }
                options.nullValue = value; index += 2
            case "-audit":
                guard let value = optionValue(after: index) else {
                    return usageError("-audit requires a path")
                }
                auditPath = value; auditEnabled = true; index += 2
            case "-no-audit", "-noaudit":
                auditEnabled = false; index += 1
            case "-help", "--help", "-h":
                Shell.bashCurrent.stdout(usageText)
                return .success
            case "-version", "--version":
                Shell.bashCurrent.stdout("SwiftSQLite — sqlite3 (libsqlite3 \(SQLiteEngine.version))\n")
                return .success
            default:
                return usageError("unknown option: \(token)")
            }
        }

        guard index < rawArgv.count else {
            return usageError("missing DBFILE")
        }
        let dbfile = rawArgv[index]
        index += 1
        let sqlArguments = Array(rawArgv[index...])

        // --- §4 native-file contract guard (skip for :memory:) ---
        let isMemory = (dbfile == ":memory:")
        if !isMemory,
           !backingIsSupportedForSQLite(Shell.bashCurrent.fileSystem,
                                        hasSandbox: Shell.bashCurrent.sandbox != nil) {
            Shell.bashCurrent.stderr("""
                sqlite3: this shell's filesystem is not backed by real disk, \
                so a database file cannot be opened safely. Use ':memory:' for \
                an in-memory database, or run under a real filesystem / a \
                --sandbox workspace. (See the native-file contract, PLAN.md §4.)

                """)
            return .failure
        }

        // --- build the connection ---
        var policy = EnginePolicy()
        policy.readOnly = readOnly

        let shell = Shell.bashCurrent   // captured for the @Sendable authorize closure
        let resolved = isMemory ? ":memory:" : shell.resolvePath(dbfile)
        let databasePath = resolved

        // Build the audit sink first. An explicit `-audit PATH` the sandbox
        // denies fails the command: when the user asked for a persistent trail
        // we refuse to run (possibly destructive) SQL unaudited. A denied
        // *default* sibling path downgrades to in-memory inside makeAuditSink.
        let sink: any AuditSink
        do {
            sink = try await makeAuditSink(
                enabled: auditEnabled, explicitPath: auditPath,
                databaseURL: isMemory ? nil : URL(fileURLWithPath: resolved),
                shell: shell)
        } catch {
            Shell.bashCurrent.stderr("sqlite3: \(errorText(error))\n")
            return .failure
        }

        let connection: SQLiteConnection
        do {
            if isMemory {
                connection = try await SQLiteConnection(inMemory: policy, audit: sink)
            } else {
                connection = try await SQLiteConnection(
                    url: URL(fileURLWithPath: resolved),
                    policy: policy,
                    audit: sink,
                    authorize: { url, _ in
                        // §4: symlink-resolved containment. No-op when the
                        // shell has no sandbox (a trusted, unconfined shell).
                        try await shell.sandbox?.authorize(url)
                    })
            }
        } catch {
            Shell.bashCurrent.stderr("sqlite3: cannot open '\(dbfile)': \(errorText(error))\n")
            return .failure
        }

        // --- run input, then always close (flushes the audit trail) ---
        let state = SessionState(options: options, databasePath: databasePath)
        let text: String
        if sqlArguments.isEmpty {
            text = await Shell.bashCurrent.stdin.readAllString()
        } else {
            text = sqlArguments.joined(separator: " ")
        }
        let status = await runSQLSession(text: text, connection: connection, state: state)
        await connection.close()
        return status
    }

    // MARK: helpers

    private func optionValue(after index: Int) -> String? {
        let next = index + 1
        return next < rawArgv.count ? rawArgv[next] : nil
    }

    private func usageError(_ message: String) -> ExitStatus {
        Shell.bashCurrent.stderr("sqlite3: \(message)\nusage: sqlite3 [OPTIONS] DBFILE [SQL]\n")
        return ExitStatus(2)
    }

    /// Build the audit sink (writes JSON Lines **outside** the DB). The
    /// default path is a `<db>.audit.log` sibling, which lives inside the
    /// already-authorized directory. An explicit `-audit PATH` is authorized
    /// too; if **that** is denied this throws (the caller fails the command,
    /// since the user explicitly asked for a persistent trail). A denied
    /// *default* sibling path downgrades to in-memory and the command runs.
    private func makeAuditSink(
        enabled: Bool, explicitPath: String?, databaseURL: URL?, shell: Shell
    ) async throws -> any AuditSink {
        guard enabled else { return NoOpAuditSink() }
        // Explicit -audit PATH wins (honored even for :memory:); otherwise
        // default to a `<db>.audit.log` sibling for file DBs. An in-memory DB
        // with no explicit path has nowhere persistent to write.
        let auditURL: URL
        let isExplicit: Bool
        if let explicitPath {
            auditURL = URL(fileURLWithPath: shell.resolvePath(explicitPath))
            isExplicit = true
        } else if let databaseURL {
            auditURL = databaseURL.appendingPathExtension("audit.log")
            isExplicit = false
        } else {
            return NoOpAuditSink()
        }
        // A FileAuditSink writes a real host file, so it needs the same native
        // backing the §4 DB guard requires. That guard is skipped for :memory:,
        // so without this an explicit `-audit` on a non-native shell would still
        // write to the host even though the shell refuses file databases.
        guard backingIsSupportedForSQLite(
            shell.fileSystem, hasSandbox: shell.sandbox != nil) else {
            if isExplicit {
                throw AuditPathDenied(
                    message: "-audit needs a real-disk filesystem; this shell's "
                    + "backing can't safely write a host audit file")
            }
            return NoOpAuditSink()
        }
        // Refuse an audit path that resolves to the database file or one of its
        // SQLite sidecars: a FileAuditSink appending JSON Lines into the live DB
        // (or its -wal/-shm/-journal) would corrupt it after otherwise-successful
        // SQL. The audit trail is contractually written *outside* the database.
        if let databaseURL {
            let dbPath = databaseURL.standardizedFileURL.path
            let auditPath = auditURL.standardizedFileURL.path
            if auditPath == dbPath || ["-wal", "-shm", "-journal"].contains(
                where: { auditPath == dbPath + $0 }) {
                throw AuditPathDenied(
                    message: "-audit path overlaps the database file or its "
                    + "sidecars (\(auditPath)); the audit trail must be written "
                    + "outside the database")
            }
        }
        do {
            try await shell.sandbox?.authorize(auditURL)
            let sink = FileAuditSink(url: auditURL)
            // Preflight the open so an authorized-but-unusable path (directory,
            // unwritable, leaf-symlink) fails closed here rather than running
            // SQL unaudited and only erroring on the first post-commit flush.
            try await sink.preflight()
            return sink
        } catch {
            if isExplicit {
                // Fail closed: don't run unaudited when a persistent trail was
                // explicitly requested.
                throw AuditPathDenied(
                    message: "-audit path denied: \(errorText(error))")
            }
            shell.stderr("sqlite3: audit log disabled (path denied): \(errorText(error))\n")
            return NoOpAuditSink()
        }
    }
}

/// Thrown when an explicitly-requested `-audit PATH` is denied by the sandbox,
/// so the command fails closed instead of running unaudited.
private struct AuditPathDenied: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private let usageText = """
usage: sqlite3 [OPTIONS] DBFILE [SQL]

Run SQL against a SQLite database confined to the SwiftBash sandbox. SQL is
read from the trailing arguments, or from stdin when none are given. Use
':memory:' as DBFILE for an in-memory database.

Options:
  -readonly            Open the database read-only
  -header | -noheader  Show / hide column headers
  -mode MODE           Output mode: list (default) csv json column line
  -csv -json           Shorthand for -mode csv / -mode json
  -line -column -list  Shorthand for the matching -mode
  -separator SEP       Field separator for list/column modes (default '|')
  -nullvalue STR       Text to print for NULL (default empty)
  -audit PATH          Write the audit log to PATH (default: <db>.audit.log)
  -no-audit            Disable the persistent audit log
  -help                Show this help
  -version             Show the engine version

Safe dot-commands: .tables .schema .indexes .databases .headers .mode
.separator .nullvalue .dump .quit

"""
