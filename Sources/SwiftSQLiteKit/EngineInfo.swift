import CSQLite
import Foundation

/// Build/version information for the vendored SQLite engine.
public enum SQLiteEngine {
    /// The `libsqlite3` version string, e.g. `"3.47.2"`.
    public static var version: String {
        String(cString: sqlite3_libversion())
    }

    /// The numeric version, e.g. `3047002`.
    public static var versionNumber: Int32 {
        sqlite3_libversion_number()
    }
}

/// Splitting SQL text into individual statements.
public enum SQLiteStatements {
    /// Split `sql` into individual statements at complete-statement
    /// boundaries, using `sqlite3_complete` so a `;` inside a string literal
    /// or comment does not split a statement. Lets a CLI run statements one
    /// at a time (continuing past a failed one) rather than as one
    /// all-or-nothing script. A trailing incomplete fragment is returned as a
    /// final element so the caller can surface its error.
    public static func split(_ sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        for character in sql {
            current.append(character)
            if character == ";" {
                let complete = current.withCString { sqlite3_complete($0) != 0 }
                if complete {
                    statements.append(current)
                    current = ""
                }
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statements.append(current)
        }
        return statements
    }
}
