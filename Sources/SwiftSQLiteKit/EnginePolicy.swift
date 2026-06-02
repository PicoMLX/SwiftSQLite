import Foundation

/// Tunable limits and switches for a `SQLiteConnection`. All fields have
/// safe defaults (PLAN.md §7 / §10).
public struct EnginePolicy: Sendable {
    /// Maximum rows returned per statement; extra rows set
    /// `ResultSet.truncated` and stop the step loop. Default 10k.
    public var rowLimit: Int = 10_000

    /// Per-script wall-clock budget enforced by the progress handler
    /// (`sqlite3_interrupt` fires when exceeded). `.zero` disables it.
    public var statementTimeout: Duration = .seconds(30)

    /// Open the database read-only and deny every write/DDL action in
    /// the authorizer (defense in depth).
    public var readOnly: Bool = false

    /// Table-name prefix reserved for audit infrastructure. The
    /// authorizer denies *all* access (read and write) to objects whose
    /// name starts with this prefix, so user SQL can neither read nor
    /// forge an audit table. Empty disables the reservation.
    public var reservedTablePrefix: String = "_audit"

    /// Busy-handler timeout for contended writes.
    public var busyTimeout: Duration = .seconds(5)

    /// `SQLITE_LIMIT_SQL_LENGTH` ceiling — a DoS guard against pathological
    /// statement text.
    public var maxSQLLength: Int = 1_000_000

    public init() {}

    public static let `default` = EnginePolicy()
}
