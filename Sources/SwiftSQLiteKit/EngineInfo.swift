import CSQLite

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
