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
        // A buffer of only whitespace and SQL comments has no pending
        // statement — `sqlite3_complete` returns false for it (no terminating
        // `;`), but the sqlite3 shell treats it as a boundary (its
        // `_all_whitespace`), so a following dot-command is recognized rather
        // than swallowed as SQL (e.g. `-- note\n.tables`).
        if isAllWhitespaceOrComments(sql) { return true }
        return sqlite3_complete(sql) != 0
    }

    /// True if `sql` is only whitespace and complete/closed SQL comments
    /// (`-- …` line and `/* … */` block), i.e. contains no statement tokens.
    static func isAllWhitespaceOrComments(_ sql: String) -> Bool {
        let s = Array(sql.unicodeScalars)
        var i = 0
        while i < s.count {
            switch s[i] {
            case " ", "\t", "\n", "\r", "\u{0B}", "\u{0C}":
                i += 1
            case "-" where i + 1 < s.count && s[i + 1] == "-":
                i += 2
                while i < s.count && s[i] != "\n" { i += 1 }
            case "/" where i + 1 < s.count && s[i + 1] == "*":
                i += 2
                var closed = false
                while i + 1 < s.count {
                    if s[i] == "*" && s[i + 1] == "/" { i += 2; closed = true; break }
                    i += 1
                }
                // An *unterminated* block comment is a pending (incomplete)
                // statement, not a boundary — so a following dot-command stays
                // data, matching how the sqlite3 shell keeps reading.
                if !closed { return false }
            default:
                return false   // a real (non-comment) token
            }
        }
        return true
    }
}
