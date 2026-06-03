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
/// calls the actor makes on its own executor. So all field access happens on
/// one thread at a time. (Task cancellation is handled purely by
/// `sqlite3_interrupt`, which is thread-safe, so no flag is shared across
/// threads here.) `@unchecked Sendable` because the C-pointer plumbing isn't
/// expressible to the checker.
final class EngineContext: @unchecked Sendable {
    private let reservedPrefix: String          // lowercased; "" disables
    private let readOnly: Bool
    private let maxAuditRecords: Int            // cap on `events`/`pending`
    private var auditTruncated = false          // latched per transaction

    /// Drained to the `AuditSink` after each script / on close.
    private(set) var events: [AuditEvent] = []
    /// Per-row update-hook records awaiting a commit. Promoted to
    /// `committed` events on `commit()`, dropped on `rollback()`.
    private var pending: [(table: String, rowid: Int64, op: String)] = []
    /// Open savepoints as `(name, pending.count when created)`. Lets a
    /// `ROLLBACK TO s` discard the pending rows recorded after `s` (SQLite
    /// fires no rollback hook for `ROLLBACK TO`).
    private var savepoints: [(name: String, mark: Int)] = []

    var deadlineNanos: UInt64?

    init(reservedTablePrefix: String, readOnly: Bool, maxAuditRecords: Int) {
        self.reservedPrefix = reservedTablePrefix.lowercased()
        self.readOnly = readOnly
        self.maxAuditRecords = maxAuditRecords
    }

    // MARK: Authorizer (PLAN.md §7)

    /// The single SQL-enforcement choke point. Returns `SQLITE_OK`,
    /// `SQLITE_DENY`, or `SQLITE_IGNORE`, and records an `attempted`
    /// audit event for every decision.
    func authorize(action: Int32, arg1: String?, arg2: String?) -> Int32 {
        let decision = decide(action: action, arg1: arg1, arg2: arg2)
        // The decision above is returned regardless of the audit cap, so
        // bounding the buffer never weakens enforcement — only recording.
        if events.count < maxAuditRecords {
            events.append(.attempted(
                action: Self.actionName(action),
                table: guardedObjectName(action: action, arg1: arg1, arg2: arg2),
                allowed: decision != SQLITE_DENY))
        } else {
            noteAuditTruncated()
        }
        // Track savepoint boundaries so `ROLLBACK TO s` drops the pending
        // committed-audit rows recorded after `s`. arg1 is the operation
        // ("BEGIN"/"RELEASE"/"ROLLBACK"), arg2 the savepoint name. The
        // authorizer fires at prepare time and runScript prepares+steps one
        // statement at a time, so when `ROLLBACK TO s` is prepared the
        // intervening rows are already in `pending`.
        if action == SQLITE_SAVEPOINT, decision == SQLITE_OK {
            applySavepoint(operation: arg1, name: arg2)
        }
        return decision
    }

    private func applySavepoint(operation: String?, name: String?) {
        guard let name else { return }
        switch operation {
        case "BEGIN":
            savepoints.append((name: name, mark: pending.count))
        case "ROLLBACK":
            // Discard pending rows recorded after `s`, and drop nested
            // savepoints above it; `s` itself stays active.
            guard let idx = savepoints.lastIndex(where: { $0.name == name })
            else { return }
            let mark = savepoints[idx].mark
            if mark < pending.count { pending.removeLast(pending.count - mark) }
            savepoints.removeSubrange((idx + 1)...)
        case "RELEASE":
            // `s` (and nested savepoints) merge into the parent; rows remain.
            if let idx = savepoints.lastIndex(where: { $0.name == name }) {
                savepoints.removeSubrange(idx...)
            }
        default:
            break
        }
    }

    private func decide(action: Int32, arg1: String?, arg2: String?) -> Int32 {
        let object = guardedObjectName(action: action, arg1: arg1, arg2: arg2)

        // The reserved audit namespace is denied to user SQL for reads *and*
        // writes of the object itself, so an `_audit*` table's rows can be
        // neither queried nor forged. (Catalog metadata is NOT row-filtered:
        // a `SELECT … FROM sqlite_schema` can still reveal that such an object
        // exists and its DDL — `SQLITE_READ` fires for `sqlite_schema`, not the
        // reserved object. A deliberate limitation; the audit trail itself is
        // an external file, not an in-DB `_audit*` table.)
        if isReserved(object) { return SQLITE_DENY }
        // CREATE INDEX/TRIGGER puts the NEW object's name in arg1 (the owning
        // table is in arg2, already covered by `object`). Reject a reserved new
        // name too — e.g. `CREATE INDEX _audit_i ON t` / `CREATE TRIGGER
        // _audit_tr … ON t` — so the reserved namespace can't be populated.
        if action == SQLITE_CREATE_INDEX || action == SQLITE_CREATE_TEMP_INDEX
            || action == SQLITE_CREATE_TRIGGER
            || action == SQLITE_CREATE_TEMP_TRIGGER,
           isReserved(arg1) {
            return SQLITE_DENY
        }

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

        case SQLITE_DELETE:
            if readOnly { return SQLITE_DENY }
            // DDL is reported as a DELETE on `sqlite_master` (see the schema
            // note below) and other internal bookkeeping touches `sqlite_*`
            // tables — leave all those as OK, unperturbed. For a real
            // *user-table* delete, return IGNORE so SQLite disables the
            // truncate optimization and deletes rows individually. Otherwise
            // `DELETE FROM t` (no WHERE) skips sqlite3_update_hook and the
            // committed-audit stream would miss those rows (sqlite3.h: the
            // update hook is "not invoked when rows are deleted using the
            // truncate optimization"). For SQLITE_DELETE, IGNORE means
            // "proceed, but row-by-row" (sqlite3.h authorizer docs) — it does
            // NOT skip the delete. (ON CONFLICT REPLACE deletes are still
            // missed; capturing those needs the preupdate hook — open-knob #4.)
            if (object ?? "").lowercased().hasPrefix("sqlite_") {
                return SQLITE_OK
            }
            return SQLITE_IGNORE

        case SQLITE_INSERT, SQLITE_UPDATE,
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
            // arg2 is the table being altered (its OLD name on a RENAME).
            // Limitation: SQLite doesn't pass the NEW name to the authorizer,
            // so `ALTER TABLE t RENAME TO _audit_x` isn't caught by the
            // reserved-prefix guard. Low severity — the audit trail is an
            // external file, not an in-DB `_audit*` table, so the reserved
            // namespace is defense-in-depth only.
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
        guard pending.count < maxAuditRecords else { noteAuditTruncated(); return }
        let opName: String
        switch op {
        case SQLITE_INSERT: opName = "INSERT"
        case SQLITE_UPDATE: opName = "UPDATE"
        case SQLITE_DELETE: opName = "DELETE"
        default: opName = "OP(\(op))"
        }
        pending.append((table: table ?? "", rowid: rowid, op: opName))
    }

    /// Record (once per transaction) that the audit buffers hit `maxAuditRecords`
    /// and started dropping records. Bounded memory beats unbounded fidelity for
    /// untrusted SQL; the marker keeps the trail honest about the gap.
    private func noteAuditTruncated() {
        guard !auditTruncated else { return }
        auditTruncated = true
        events.append(.attempted(action: "_AUDIT_TRUNCATED", table: nil, allowed: false))
    }

    /// Promote everything in `pending` into the committed stream.
    func commit() {
        for record in pending {
            events.append(.committed(table: record.table, rowid: record.rowid, op: record.op))
        }
        pending.removeAll(keepingCapacity: true)
        savepoints.removeAll(keepingCapacity: true)
        auditTruncated = false
    }

    /// Drop pending rows — the transaction rolled back, so they never
    /// committed. They remain in the *attempted* stream (recorded by the
    /// authorizer), never the committed stream.
    ///
    /// `ROLLBACK TO SAVEPOINT` (which fires no rollback hook) is handled
    /// separately via the savepoint markers in `applySavepoint` — a partial
    /// rollback trims `pending` back to the savepoint boundary, so this full
    /// rollback only has to clear what remains.
    func rollback() {
        pending.removeAll(keepingCapacity: true)
        savepoints.removeAll(keepingCapacity: true)
        auditTruncated = false
    }

    // MARK: Timeout / cancellation

    func isExpired() -> Bool {
        if let deadline = deadlineNanos,
           DispatchTime.now().uptimeNanoseconds > deadline { return true }
        return false
    }

    func beginScript(deadlineNanos: UInt64?) {
        self.deadlineNanos = deadlineNanos
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
        savepoints.removeAll(keepingCapacity: false)
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
