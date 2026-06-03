import CSQLite
import Foundation

/// SQL-text utilities backed by the SQLite C API.
public enum SQLiteSQL {
    /// True when `sql` sits at a statement boundary: it is empty/whitespace, or
    /// every statement in it is complete with no trailing partial statement —
    /// correctly accounting for string literals, comments, and quoted
    /// identifiers. Wraps `sqlite3_complete`.
    ///
    /// The `sqlite3` REPL only treats a line beginning with `.` as a
    /// dot-command when no SQL is pending. Callers reproduce that rule with
    /// this check so a `.`-leading line that falls *inside* an unfinished
    /// multi-line statement (e.g. a string literal containing `\n.tables\n`)
    /// is kept as data rather than misfired as a command.
    public static func isAtStatementBoundary(_ sql: String) -> Bool {
        if sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return sqlite3_complete(sql) != 0
    }
}
