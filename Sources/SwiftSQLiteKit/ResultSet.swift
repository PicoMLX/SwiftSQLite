/// The rows produced by a single column-returning statement.
public struct ResultSet: Sendable, Equatable {
    public let columns: [String]
    public let rows: [[SQLiteValue]]
    /// `true` when the row cap (`EnginePolicy.rowLimit`) was hit and the
    /// statement was stopped before producing all rows.
    public let truncated: Bool

    public init(columns: [String], rows: [[SQLiteValue]], truncated: Bool) {
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
    }

    public var isEmpty: Bool { rows.isEmpty }
}

/// The full outcome of running a SQL script (which may contain several
/// statements): every column-returning statement's `ResultSet`, plus the
/// total number of rows changed by write statements.
public struct RunResult: Sendable {
    public let results: [ResultSet]
    public let changes: Int

    public init(results: [ResultSet], changes: Int) {
        self.results = results
        self.changes = changes
    }
}
