import BashInterpreter
import Foundation
import SwiftSQLiteKit

/// Dot-commands that exist in the real `sqlite3` shell but are removed
/// here because they reach outside the database / sandbox. They produce a
/// clear error (PLAN.md §10) — never a silent no-op.
private let disabledDotCommands: Set<String> = [
    ".shell", ".system", ".import", ".export", ".output", ".once",
    ".load", ".read", ".backup", ".restore", ".archive", ".cd",
    ".open", ".recover",
]

enum DotResult: Equatable {
    case ok
    case quit
    case failed(String)
}

/// Implements the safe subset of dot-commands via `sqlite_schema` queries
/// and client-side state changes (PLAN.md §10).
enum DotCommandRunner {
    static func run(
        _ line: String,
        connection: SQLiteConnection,
        state: SessionState
    ) async -> DotResult {
        let tokens = tokenize(line)
        guard let command = tokens.first else { return .ok }
        let args = Array(tokens.dropFirst())

        if disabledDotCommands.contains(command) {
            return .failed("\(command): command disabled in the sandbox")
        }

        switch command {
        case ".tables":
            return await listSchema(
                connection,
                "SELECT name FROM sqlite_schema WHERE type IN ('table','view') "
                    + "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name;")

        case ".indexes", ".indices":
            var sql = "SELECT name FROM sqlite_schema WHERE type='index' "
                + "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'"
            if let table = args.first {
                sql += " AND tbl_name='\(escapeSQLString(table))'"
            }
            sql += " ORDER BY name;"
            return await listSchema(connection, sql)

        case ".schema":
            var sql = "SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL "
                + "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'"
            if let name = args.first {
                sql += " AND name='\(escapeSQLString(name))'"
            }
            sql += " ORDER BY (type='table') DESC, name;"
            return await emitSchemaSQL(connection, sql)

        case ".databases":
            Shell.bashCurrent.stdout("main: \(state.databasePath)\n")
            return .ok

        case ".headers", ".header":
            state.options.header = parseOnOff(args.first, default: true)
            return .ok

        case ".mode":
            guard let raw = args.first, let mode = OutputMode(rawValue: raw) else {
                return .failed(".mode: expected one of "
                    + OutputMode.allCases.map(\.rawValue).joined(separator: ", "))
            }
            state.options.mode = mode
            if mode == .column { state.options.header = true }
            return .ok

        case ".separator", ".sep":
            state.options.separator = args.first ?? "|"
            return .ok

        case ".nullvalue", ".nullval":
            state.options.nullValue = args.first ?? ""
            return .ok

        case ".dump":
            return await dump(connection, only: args.first)

        case ".quit", ".exit":
            return .quit

        case ".help":
            Shell.bashCurrent.stdout(dotCommandHelp)
            return .ok

        default:
            return .failed("unknown or unsupported command: \(command)")
        }
    }

    // MARK: schema helpers

    private static func listSchema(_ connection: SQLiteConnection, _ sql: String) async -> DotResult {
        do {
            let resultSet = try await connection.query(sql)
            let names = resultSet.rows.compactMap { row -> String? in
                if case let .text(name)? = row.first { return name }
                return nil
            }
            if !names.isEmpty { Shell.bashCurrent.stdout(names.joined(separator: "\n") + "\n") }
            return .ok
        } catch {
            return .failed(errorText(error))
        }
    }

    private static func emitSchemaSQL(_ connection: SQLiteConnection, _ sql: String) async -> DotResult {
        do {
            let resultSet = try await connection.query(sql)
            var out = ""
            for row in resultSet.rows {
                if case let .text(create)? = row.first { out += create + ";\n" }
            }
            if !out.isEmpty { Shell.bashCurrent.stdout(out) }
            return .ok
        } catch {
            return .failed(errorText(error))
        }
    }

    // MARK: .dump

    private static func dump(_ connection: SQLiteConnection, only: String?) async -> DotResult {
        do {
            // No `PRAGMA foreign_keys=OFF;` here: replaying the dump through
            // this sandboxed command would hit the all-PRAGMA-denied
            // authorizer. The whole restore runs in one transaction instead.
            var out = "BEGIN TRANSACTION;\n"
            var schemaSQL = "SELECT type, name, sql FROM sqlite_schema "
                + "WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'"
            if let only {
                schemaSQL += " AND name='\(escapeSQLString(only))'"
            }
            schemaSQL += " ORDER BY (type='table') DESC, name;"

            let schema = try await connection.query(schemaSQL)
            var tableNames: [String] = []
            var deferredSchema: [String] = []   // indexes/triggers/views, emitted last
            for row in schema.rows {
                guard row.count >= 3,
                      case let .text(type) = row[0],
                      case let .text(name) = row[1],
                      case let .text(create) = row[2] else { continue }
                if type == "table" {
                    out += create + ";\n"
                    tableNames.append(name)
                } else {
                    // Defer indexes/triggers/views until after the data so a
                    // restore doesn't fire AFTER-INSERT triggers while the
                    // dumped rows are being replayed.
                    deferredSchema.append(create + ";\n")
                }
            }
            for table in tableNames {
                let rows = try await connection.query("SELECT * FROM \"\(escapeIdentifier(table))\";")
                let identifier = "\"\(escapeIdentifier(table))\""
                for row in rows.rows {
                    let values = row.map(sqlLiteral).joined(separator: ",")
                    out += "INSERT INTO \(identifier) VALUES(\(values));\n"
                }
            }
            out += deferredSchema.joined()
            out += "COMMIT;\n"
            Shell.bashCurrent.stdout(out)
            return .ok
        } catch {
            return .failed(errorText(error))
        }
    }

    // MARK: tokenizing

    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false   // distinguishes "no token" from an empty token ("" / '')
        var quote: Character?
        for character in line {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                hasToken = true
            } else if character == " " || character == "\t" {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    private static func parseOnOff(_ value: String?, default fallback: Bool) -> Bool {
        guard let value = value?.lowercased() else { return fallback }
        switch value {
        case "on", "1", "yes", "true": return true
        case "off", "0", "no", "false": return false
        default: return fallback
        }
    }
}

private let dotCommandHelp = """
.tables             List names of tables and views
.schema [NAME]      Show CREATE statements
.indexes [TABLE]    List index names
.databases          Show attached databases (always just 'main')
.headers on|off     Toggle column headers
.mode MODE          Set output mode: list csv json column line
.separator SEP      Set the list/column separator
.nullvalue STR      String to print for NULL values
.dump [TABLE]       Dump the database (or one table) as SQL text
.quit               Stop processing input

"""

// MARK: - SQL session

/// Process `text` (from args or stdin): dot-commands are handled per line;
/// everything else accumulates into a SQL buffer that is run at each
/// dot-command boundary and at EOF. Errors are reported to stderr and do
/// not abort the remaining input (lenient, like `sqlite3` non-interactive
/// without `-bail`). Returns the worst exit status seen.
func runSQLSession(
    text: String,
    connection: SQLiteConnection,
    state: SessionState
) async -> ExitStatus {
    var sqlBuffer = ""
    var status: ExitStatus = .success

    func flush() async {
        guard !sqlBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sqlBuffer = ""
            return
        }
        if await runSQLBuffer(sqlBuffer, connection: connection, options: state.options) == false {
            status = .failure
        }
        sqlBuffer = ""
    }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for line in lines {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(".") {
            await flush()
            switch await DotCommandRunner.run(line.trimmingCharacters(in: .whitespacesAndNewlines),
                                              connection: connection, state: state) {
            case .ok:
                break
            case .quit:
                return status
            case .failed(let message):
                Shell.bashCurrent.stderr("sqlite3: \(message)\n")
                status = .failure
            }
        } else {
            sqlBuffer += line
            sqlBuffer += "\n"
        }
    }
    await flush()
    return status
}

private func runSQLBuffer(
    _ sql: String,
    connection: SQLiteConnection,
    options: OutputOptions
) async -> Bool {
    do {
        let result = try await connection.run(sql)
        for resultSet in result.results {
            let rendered = ResultRenderer.render(resultSet, options: options)
            if !rendered.isEmpty { Shell.bashCurrent.stdout(rendered) }
            if resultSet.truncated {
                Shell.bashCurrent.stderr("sqlite3: output truncated at the row limit\n")
            }
        }
        return true
    } catch {
        Shell.bashCurrent.stderr("sqlite3: \(errorText(error))\n")
        return false
    }
}

// MARK: - shared SQL helpers

func errorText(_ error: Error) -> String {
    if let error = error as? SQLiteError { return error.message }
    if let error = error as? SQLiteEngineError { return error.description }
    return "\(error)"
}

/// Escape a string for use inside single quotes in a SQL literal.
func escapeSQLString(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}

/// Escape an identifier for use inside double quotes (SQLITE_DQS=0 means
/// double quotes are always identifiers, never strings).
func escapeIdentifier(_ value: String) -> String {
    value.replacingOccurrences(of: "\"", with: "\"\"")
}

/// Render a value as a SQL literal (used by `.dump`).
func sqlLiteral(_ value: SQLiteValue) -> String {
    switch value {
    case .null: return "NULL"
    case .integer(let i): return String(i)
    case .real(let d): return String(d)
    case .text(let s): return "'\(escapeSQLString(s))'"
    case .blob(let data): return blobLiteral(data)
    }
}
