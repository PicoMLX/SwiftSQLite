import BashCommandKit
import BashInterpreter

public extension Shell {
    /// Install the `sqlite3` command at `path` (default `/usr/bin/sqlite3`).
    ///
    /// This is the external-package registration helper (PLAN.md §1 / §M5):
    /// `which sqlite3` and `exec` work off the install path. Making `/bin`
    /// *listings* surface `sqlite3` is a separate one-line `BinCatalog`
    /// change upstream in SwiftBash — not assumed here.
    ///
    /// ```swift
    /// let shell = Shell()
    /// shell.registerSQLiteCommands()
    /// try await shell.run("sqlite3 data.db 'SELECT count(*) FROM users;'")
    /// ```
    func registerSQLiteCommands(at path: String = "/usr/bin/sqlite3") {
        install(SqliteCommand.self, at: path)
    }
}
