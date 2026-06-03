import CSQLite
import Dispatch
import Foundation

/// Mutable state shared between the `SQLiteConnection` actor and the C
/// callbacks SQLite invokes (authorizer, progress, commit/update/rollback
/// hooks). A pointer to one of these is handed to the C layer as the
/// callback "app data".
///
/// Concurrency: every callback fires **synchronously on the SQL thread**,
/// i.e. inside the `sqlite3_prepare_v2` / `sqlite3_step` / `sqlite3_exec`
/// calls the actor makes on its own executor. So all field access happens
/// on one thread at a time — except `cancelled`, which `onCancel` may set
/// from another thread (a benign best-effort flag; `sqlite3_interrupt` is
/// the authoritative abort). Hence `@unchecked Sendable`.
final class EngineContext: @unchecked Sendable {
    private let reservedPrefix: String          // lowercased; "" disables
    private let readOnly: Bool

    /// Drained to the `AuditSink` after each script / on close.
    private(set) var events: [AuditEvent] = []
    /// Per-row update-hook records awaiting a commit. Promoted to
    /// `committed` events on `commit()`, dropped on `rollback()`.
    private var pending: [(table: String, rowid: Int64, op: String)] = []

    var deadlineNanos: UInt64?
    var cancelled: Bool = false

    init(reservedTablePrefix: String, readOnly: Bool) {
        self.reservedPrefix = reservedTablePrefix.lowercased()
        self.readOnly = readOnly
    }

    // MARK: Authorizer (PLAN.md §7)

    /// The single SQL-enforcement choke point. Returns `SQLITE_OK`,
    /// `SQLITE_DENY`, or `SQLITE_IGNORE`, and records an `attempted`
    /// audit event for every decision.
    func authorize(action: Int32, arg1: String?, arg2: String?) -> Int32 {
        let decision = decide(action: action, arg1: arg1, arg2: arg2)
        events.append(.attempted(
            action: Self.actionName(action),
            table: guardedObjectName(action: action, arg1: arg1, arg2: arg2),
            allowed: decision == SQLITE_OK))
        return decision
    }

    private func decide(action: Int32, arg1: String?, arg2: String?) -> Int32 {
        let object = guardedObjectName(action: action, arg1: arg1, arg2: arg2)

        // The reserved audit namespace is hidden from user SQL entirely
        // (read *and* write), so it can be neither inspected nor forged.
        if isReserved(object) { return SQLITE_DENY }

        switch action {
        case SQLITE_ATTACH, SQLITE_DETACH:
            // ATTACH/DETACH are SQLite's "open another file" — denied
            // (also belt-and-suspenders via SQLITE_LIMIT_ATTACHED=0).
            return SQLITE_DENY

        case SQLITE_PRAGMA:
            // All user PRAGMA denied. The few we need are issued via the
            // C API before the authorizer is installed.
            return SQLITE_DENY

        case SQLITE_SELECT, SQLITE_TRANSACTION, SQLITE_SAVEPOINT,
             SQLITE_FUNCTION, SQLITE_RECURSIVE:
            return SQLITE_OK

        case SQLITE_READ:
            // Reads are allowed, including of the `sqlite_*` schema tables
            // — query planning and `.schema`/`.tables` introspection need
            // them. (`_audit*` was already denied above.)
            return SQLITE_OK

        case SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE,
             SQLITE_CREATE_TABLE, SQLITE_CREATE_TEMP_TABLE,
             SQLITE_CREATE_INDEX, SQLITE_CREATE_TEMP_INDEX,
             SQLITE_CREATE_VIEW, SQLITE_CREATE_TEMP_VIEW,
             SQLITE_CREATE_TRIGGER, SQLITE_CREATE_TEMP_TRIGGER,
             SQLITE_DROP_TABLE, SQLITE_DROP_TEMP_TABLE,
             SQLITE_DROP_INDEX, SQLITE_DROP_TEMP_INDEX,
             SQLITE_DROP_VIEW, SQLITE_DROP_TEMP_VIEW,
             SQLITE_DROP_TRIGGER, SQLITE_DROP_TEMP_TRIGGER,
             SQLITE_ALTER_TABLE,
             // REINDEX/ANALYZE are safe maintenance on the one DB file —
             // and CREATE INDEX reports the index build to the authorizer as
             // SQLITE_REINDEX, so denying it breaks CREATE INDEX.
             SQLITE_REINDEX, SQLITE_ANALYZE:
            if readOnly { return SQLITE_DENY }
            // `sqlite_schema` writes are deliberately NOT denied here:
            // legitimate DDL (CREATE/DROP/ALTER) is reported to the
            // authorizer as an INSERT/DELETE on `sqlite_master`, so denying
            // it would reject all DDL. Direct user writes to the schema
            // table are instead blocked by SQLITE_DBCONFIG_DEFENSIVE
            // (enabled in configure()).
            return SQLITE_OK

        default:
            // Default-deny: ANALYZE, REINDEX, virtual-table create/drop,
            // the deprecated COPY, and any code a future SQLite adds.
            return SQLITE_DENY
        }
    }

    /// The object name the namespace policy applies to for a given
    /// action. SQLite passes the operands in different slots per action
    /// (e.g. ALTER_TABLE puts the table in arg2; index/trigger ops put
    /// the owning table in arg2).
    private func guardedObjectName(action: Int32, arg1: String?, arg2: String?) -> String? {
        switch action {
        case SQLITE_ALTER_TABLE:
            return arg2
        case SQLITE_CREATE_INDEX, SQLITE_CREATE_TEMP_INDEX,
             SQLITE_DROP_INDEX, SQLITE_DROP_TEMP_INDEX,
             SQLITE_CREATE_TRIGGER, SQLITE_CREATE_TEMP_TRIGGER,
             SQLITE_DROP_TRIGGER, SQLITE_DROP_TEMP_TRIGGER:
            return arg2 ?? arg1
        default:
            return arg1
        }
    }

    private func isReserved(_ name: String?) -> Bool {
        guard !reservedPrefix.isEmpty, let name else { return false }
        return name.lowercased().hasPrefix(reservedPrefix)
    }

    // MARK: Hooks (PLAN.md §8)

    /// Known limitation: `sqlite3_update_hook` does not fire for
    /// `WITHOUT ROWID` tables, so committed *per-row* records exclude writes
    /// to those tables. The authorizer still records the INSERT/UPDATE/DELETE
    /// in the attempted stream, which remains the authoritative intent log.
    func recordUpdate(op: Int32, table: String?, rowid: Int64) {
        let opName: String
        switch op {
        case SQLITE_INSERT: opName = "INSERT"
        case SQLITE_UPDATE: opName = "UPDATE"
        case SQLITE_DELETE: opName = "DELETE"
        default: opName = "OP(\(op))"
        }
        pending.append((table: table ?? "", rowid: rowid, op: opName))
    }

    /// Promote everything in `pending` into the committed stream.
    func commit() {
        for record in pending {
            events.append(.committed(table: record.table, rowid: record.rowid, op: record.op))
        }
        pending.removeAll(keepingCapacity: true)
    }

    /// Drop pending rows — the transaction rolled back, so they never
    /// committed. They remain in the *attempted* stream (recorded by the
    /// authorizer), never the committed stream.
    ///
    /// Known limitation: this fires only on a full transaction rollback, not
    /// on `ROLLBACK TO SAVEPOINT` (SQLite exposes no savepoint-execution
    /// hook), and the pending buffer has no savepoint boundaries. So rows
    /// written after a savepoint that is later rolled back to may still be
    /// promoted to the committed stream. The attempted stream is unaffected.
    func rollback() {
        pending.removeAll(keepingCapacity: true)
    }

    // MARK: Timeout / cancellation

    func isExpired() -> Bool {
        if cancelled { return true }
        if let deadline = deadlineNanos,
           DispatchTime.now().uptimeNanoseconds > deadline { return true }
        return false
    }

    func beginScript(deadlineNanos: UInt64?) {
        self.deadlineNanos = deadlineNanos
        // Clear any cancellation latched by a previous run's cancellation
        // handler — otherwise a reused connection would interrupt every
        // subsequent statement until it is closed.
        self.cancelled = false
    }

    // MARK: Draining

    /// Return and clear the accumulated events (called after each script
    /// and on close). Uncommitted `pending` rows are intentionally left in
    /// place so a transaction spanning calls can still resolve.
    func drainEvents() -> [AuditEvent] {
        let out = events
        events.removeAll(keepingCapacity: true)
        return out
    }

    func discardPending() {
        pending.removeAll(keepingCapacity: false)
    }

    // MARK: Action-code names (for the attempted stream)

    private static func actionName(_ code: Int32) -> String {
        switch code {
        case SQLITE_CREATE_INDEX: return "CREATE_INDEX"
        case SQLITE_CREATE_TABLE: return "CREATE_TABLE"
        case SQLITE_CREATE_TEMP_INDEX: return "CREATE_TEMP_INDEX"
        case SQLITE_CREATE_TEMP_TABLE: return "CREATE_TEMP_TABLE"
        case SQLITE_CREATE_TEMP_TRIGGER: return "CREATE_TEMP_TRIGGER"
        case SQLITE_CREATE_TEMP_VIEW: return "CREATE_TEMP_VIEW"
        case SQLITE_CREATE_TRIGGER: return "CREATE_TRIGGER"
        case SQLITE_CREATE_VIEW: return "CREATE_VIEW"
        case SQLITE_DELETE: return "DELETE"
        case SQLITE_DROP_INDEX: return "DROP_INDEX"
        case SQLITE_DROP_TABLE: return "DROP_TABLE"
        case SQLITE_DROP_TEMP_INDEX: return "DROP_TEMP_INDEX"
        case SQLITE_DROP_TEMP_TABLE: return "DROP_TEMP_TABLE"
        case SQLITE_DROP_TEMP_TRIGGER: return "DROP_TEMP_TRIGGER"
        case SQLITE_DROP_TEMP_VIEW: return "DROP_TEMP_VIEW"
        case SQLITE_DROP_TRIGGER: return "DROP_TRIGGER"
        case SQLITE_DROP_VIEW: return "DROP_VIEW"
        case SQLITE_INSERT: return "INSERT"
        case SQLITE_PRAGMA: return "PRAGMA"
        case SQLITE_READ: return "READ"
        case SQLITE_SELECT: return "SELECT"
        case SQLITE_TRANSACTION: return "TRANSACTION"
        case SQLITE_UPDATE: return "UPDATE"
        case SQLITE_ATTACH: return "ATTACH"
        case SQLITE_DETACH: return "DETACH"
        case SQLITE_ALTER_TABLE: return "ALTER_TABLE"
        case SQLITE_REINDEX: return "REINDEX"
        case SQLITE_ANALYZE: return "ANALYZE"
        case SQLITE_CREATE_VTABLE: return "CREATE_VTABLE"
        case SQLITE_DROP_VTABLE: return "DROP_VTABLE"
        case SQLITE_FUNCTION: return "FUNCTION"
        case SQLITE_SAVEPOINT: return "SAVEPOINT"
        case SQLITE_RECURSIVE: return "RECURSIVE"
        default: return "ACTION(\(code))"
        }
    }
}

// MARK: - C callback trampolines

/// SQLite hands callbacks a `void *` app-data pointer; we pass an
/// unretained pointer to the connection's `EngineContext`.
private func context(_ pointer: UnsafeMutableRawPointer?) -> EngineContext? {
    guard let pointer else { return nil }
    return Unmanaged<EngineContext>.fromOpaque(pointer).takeUnretainedValue()
}

private func swiftString(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
}

let csqliteAuthorizerCallback: @convention(c) (
    UnsafeMutableRawPointer?, Int32,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Int32 = { appData, action, arg1, arg2, _, _ in
    guard let ctx = context(appData) else { return SQLITE_DENY }
    return ctx.authorize(action: action, arg1: swiftString(arg1), arg2: swiftString(arg2))
}

let csqliteProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { appData in
    guard let ctx = context(appData) else { return 0 }
    return ctx.isExpired() ? 1 : 0   // non-zero → sqlite3_step returns SQLITE_INTERRUPT
}

let csqliteCommitCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { appData in
    context(appData)?.commit()
    return 0   // 0 → allow the COMMIT to proceed
}

let csqliteRollbackCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { appData in
    context(appData)?.rollback()
}

let csqliteUpdateCallback: @convention(c) (
    UnsafeMutableRawPointer?, Int32,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, sqlite3_int64
) -> Void = { appData, op, _, table, rowid in
    context(appData)?.recordUpdate(op: op, table: swiftString(table), rowid: Int64(rowid))
}
