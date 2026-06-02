import CSQLite

/// A SQLite C-API error: the result code plus the engine's message.
public struct SQLiteError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "SQLite error \(code): \(message)" }
}

/// Engine-level (non-SQLite-C) failures.
public enum SQLiteEngineError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A method was called on a connection that is closed or never opened.
    case notOpen
    /// `sqlite3_interrupt` aborted the statement because the owning
    /// `Task` was cancelled.
    case interrupted
    /// The statement exceeded `EnginePolicy.statementTimeout`.
    case timedOut
    /// A configuration the engine cannot serve (e.g. a non-file URL that
    /// is not `:memory:`).
    case unsupported(String)

    public var description: String {
        switch self {
        case .notOpen: return "the database connection is not open"
        case .interrupted: return "the statement was interrupted (cancelled)"
        case .timedOut: return "the statement exceeded its timeout"
        case .unsupported(let reason): return reason
        }
    }
}
