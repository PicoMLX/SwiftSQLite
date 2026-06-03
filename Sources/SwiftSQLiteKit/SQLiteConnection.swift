import CSQLite
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A serialized connection to one SQLite database, hardened for running
/// untrusted SQL inside a sandbox (PLAN.md §3, §5, §7).
///
/// The engine is **SwiftBash-agnostic**: it takes a host `URL` plus an
/// `authorize` closure (the SwiftBash seam, or a stub in tests) and never
/// resolves paths itself.
///
/// The raw `sqlite3` handle and all synchronous C interaction live in a
/// `ConnectionHandle` (a Sendable class), not in the actor's stored state, so
/// the non-Sendable pointer never has to cross an actor-isolation boundary.
/// The actor serializes every call into the handle, so there is no real
/// concurrency on it.
public actor SQLiteConnection {
    private let handle: ConnectionHandle
    private let policy: EnginePolicy
    private let audit: any AuditSink
    private let ctx: EngineContext
    private var isClosed = false

    /// The per-query row cap (`EnginePolicy.rowLimit`). Exposed so callers
    /// like `.dump` can detect and report an export that would exceed it,
    /// instead of silently emitting a truncated-but-valid-looking result.
    public nonisolated var rowLimit: Int { policy.rowLimit }

    /// A connection to the file at `url` (a HOST file URL — the caller is
    /// responsible for resolution and sandboxing). `authorize` is invoked
    /// with `(url, intent)` **before** any C call; throwing from it aborts
    /// the open (PLAN.md §5, step 1).
    public init(
        url: URL,
        policy: EnginePolicy = .default,
        audit: any AuditSink,
        authorize: @Sendable (URL, AccessIntent) async throws -> Void
    ) async throws {
        // Require a host file URL: anything else (e.g. `foo:bar`) would be
        // authorized as one string but handed to sqlite3_open_v2 as a
        // different filename. Use the in-memory initializer for ':memory:'.
        guard url.isFileURL else {
            throw SQLiteEngineError.unsupported(
                "SQLiteConnection(url:) requires a file URL")
        }
        self.policy = policy
        self.audit = audit
        let ctx = EngineContext(
            reservedTablePrefix: policy.reservedTablePrefix,
            readOnly: policy.readOnly)
        self.ctx = ctx
        self.handle = ConnectionHandle(location: url.path, policy: policy, ctx: ctx)

        let intent: AccessIntent = policy.readOnly ? .read : .create
        try await authorize(url, intent)
        try handle.open()
        try handle.configure()
    }

    /// An in-memory database (PLAN.md open-knob #3) — the supported answer
    /// for callers without a real host file. There is no path to gate, so
    /// no `authorize` closure is taken.
    public init(
        inMemory policy: EnginePolicy = .default,
        audit: any AuditSink
    ) async throws {
        self.policy = policy
        self.audit = audit
        let ctx = EngineContext(
            reservedTablePrefix: policy.reservedTablePrefix,
            readOnly: policy.readOnly)
        self.ctx = ctx
        self.handle = ConnectionHandle(location: ":memory:", policy: policy, ctx: ctx)
        try handle.open()
        try handle.configure()
    }

    // No actor `deinit` — `ConnectionHandle.deinit` closes the database as a
    // safety net. (An actor deinit can't touch the non-Sendable handle, and
    // can't flush the audit asynchronously anyway; callers should `close()`.)

    // MARK: Public API

    /// Run a SQL script (one or more statements). Every column-returning
    /// statement contributes a `ResultSet`. Audit events are flushed to
    /// the sink afterward, on success *or* failure.
    @discardableResult
    public func run(_ sql: String) async throws -> RunResult {
        try ensureOpen()
        let timeoutNanos = policy.statementTimeout.nanoseconds
        ctx.beginScript(deadlineNanos: timeoutNanos == 0
            ? nil
            : DispatchTime.now().uptimeNanoseconds &+ timeoutNanos)

        // Capture a Sendable reference for the cancellation handler.
        let handle = self.handle
        do {
            let result = try await withTaskCancellationHandler {
                try handle.runScript(sql)
            } onCancel: {
                // sqlite3_interrupt is thread-safe (SQLITE_THREADSAFE=1) and
                // makes the in-flight step return SQLITE_INTERRUPT. No shared
                // Swift flag is needed (avoids a cross-thread data race).
                handle.interrupt()
            }
            await flushAudit()
            return result
        } catch {
            await flushAudit()   // surface attempted-denied / partial events too
            throw error
        }
    }

    /// Convenience: run `sql` and return the number of rows changed.
    @discardableResult
    public func execute(_ sql: String) async throws -> Int {
        try await run(sql).changes
    }

    /// Convenience: run `sql` and return the last column-returning
    /// statement's rows (capped + timed).
    public func query(_ sql: String) async throws -> ResultSet {
        let result = try await run(sql)
        return result.results.last ?? ResultSet(columns: [], rows: [], truncated: false)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await flushAudit()
        ctx.discardPending()
        handle.close()
    }

    // MARK: Helpers

    private func flushAudit() async {
        let events = ctx.drainEvents()
        guard !events.isEmpty else { return }
        await audit.record(events)
    }

    private func ensureOpen() throws {
        if isClosed || !handle.isOpen { throw SQLiteEngineError.notOpen }
    }
}

/// Owns the raw `sqlite3` handle and every synchronous C call. A plain
/// (`@unchecked Sendable`) class rather than actor state, so the non-Sendable
/// `OpaquePointer` never trips Swift 6 actor-isolation / data-race checks. The
/// owning `SQLiteConnection` actor serializes all access, and the C callbacks
/// fire synchronously on that same executor thread — so the access is
/// single-threaded in practice. The one exception is `interrupt()`, which the
/// cancellation handler may call from another thread; `sqlite3_interrupt` is
/// documented thread-safe with `SQLITE_THREADSAFE=1`.
private final class ConnectionHandle: @unchecked Sendable {
    private var db: OpaquePointer?
    private let location: String
    private let policy: EnginePolicy
    private let ctx: EngineContext

    init(location: String, policy: EnginePolicy, ctx: EngineContext) {
        self.location = location
        self.policy = policy
        self.ctx = ctx
    }

    deinit { close() }

    var isOpen: Bool { db != nil }

    // MARK: Open + harden

    func open() throws {
        var opened: OpaquePointer?
        // No SQLITE_OPEN_URI — file: URI tricks are off here and at compile
        // time (SQLITE_USE_URI=0).
        var flags: Int32 = policy.readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)

        // Symlink-swap backstop (§5 step 1). `sandbox.authorize` already checks
        // the symlink-resolved path against the workspace root — but that's a
        // check-then-open (TOCTOU): a component swapped to a symlink *after*
        // authorization and *before* this open would otherwise escape the tree.
        // SQLITE_OPEN_NOFOLLOW closes that race — SQLite fails the open if it
        // walks ANY symlinked path component (unixFullPathname → nSymlink). To
        // keep it from tripping on *legitimate* system symlinks (macOS temp/app
        // dirs live under /var → /private/var), canonicalize the path first: a
        // fully-resolved path has no symlinks left to count, so NOFOLLOW only
        // fires on a *post-resolution* swap — exactly the window we're closing.
        let openPath: String
        if location == ":memory:" {
            openPath = location
        } else {
            openPath = Self.canonicalOpenPath(location)
            flags |= SQLITE_OPEN_NOFOLLOW
        }

        let rc = sqlite3_open_v2(openPath, &opened, flags, nil)
        if rc != SQLITE_OK {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unable to open database"
            if let opened { sqlite3_close_v2(opened) }
            throw SQLiteError(code: rc, message: message)
        }
        guard let opened else {
            throw SQLiteError(code: rc, message: "open returned no handle")
        }
        db = opened
    }

    /// Canonicalize `path` so SQLITE_OPEN_NOFOLLOW won't reject legitimate
    /// symlinks in the path while still catching a post-authorization swap.
    /// An existing file resolves whole; for a not-yet-created DB the leaf has
    /// nothing to resolve, so canonicalize the parent dir and re-attach the
    /// leaf. Falls back to the original path if neither resolves (the open
    /// then fails closed via SQLite).
    private static func canonicalOpenPath(_ path: String) -> String {
        if let resolved = realpathOrNil(path) { return resolved }
        let url = URL(fileURLWithPath: path)
        if let parent = realpathOrNil(url.deletingLastPathComponent().path) {
            return (parent as NSString)
                .appendingPathComponent(url.lastPathComponent)
        }
        return path
    }

    /// POSIX `realpath(3)` wrapper: the fully symlink-resolved path, or nil if
    /// `path` can't be resolved (e.g. it doesn't exist yet).
    private static func realpathOrNil(_ path: String) -> String? {
        guard let c = realpath(path, nil) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

    /// Runtime hardening + the pragmas we need, then install the authorizer
    /// and hooks (PLAN.md §7). Order matters: pragmas are issued *before* the
    /// authorizer (which denies all user PRAGMA).
    func configure() throws {
        guard let db else { throw SQLiteEngineError.notOpen }

        _ = csqlite_db_config_onoff(db, SQLITE_DBCONFIG_DEFENSIVE, 1)
        _ = csqlite_db_config_onoff(db, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 0)
        _ = csqlite_db_config_onoff(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0)

        sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, Int32(clamping: policy.maxSQLLength))
        // Cap the size of any single string/blob result so an untrusted
        // query like `SELECT zeroblob(500000000)` can't exhaust memory when
        // its value is copied out in columnValue (DoS guard).
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(clamping: policy.maxValueBytes))
        sqlite3_busy_timeout(db, policy.busyTimeout.millisecondsInt32)

        try execInternal("PRAGMA foreign_keys=ON;")
        try execInternal("PRAGMA temp_store=MEMORY;")   // pin temp spill (§5 step 2)
        if location != ":memory:" && !policy.readOnly {
            // WAL keeps -wal/-shm as in-dir siblings; best-effort.
            _ = try? execInternal("PRAGMA journal_mode=WAL;")
        }

        let appData = Unmanaged.passUnretained(ctx).toOpaque()
        sqlite3_set_authorizer(db, csqliteAuthorizerCallback, appData)
        sqlite3_progress_handler(db, 10_000, csqliteProgressCallback, appData)
        _ = sqlite3_commit_hook(db, csqliteCommitCallback, appData)
        _ = sqlite3_update_hook(db, csqliteUpdateCallback, appData)
        _ = sqlite3_rollback_hook(db, csqliteRollbackCallback, appData)
    }

    // MARK: Step loop

    func runScript(_ sql: String) throws -> RunResult {
        guard let db else { throw SQLiteEngineError.notOpen }
        var results: [ResultSet] = []
        // Attribute changes via the monotonic total-changes counter so that
        // DDL, COMMIT, and other non-DML statements don't re-add a prior
        // DML's count — sqlite3_changes() persists until the next DML, so
        // summing it per columnless statement over-counts scripts that mix
        // writes with transaction control or schema changes.
        let startTotal = Int(sqlite3_total_changes(db))

        try sql.withCString { start in
            var cursor: UnsafePointer<CChar>? = start
            while let head = cursor, head.pointee != 0 {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let rc = sqlite3_prepare_v2(db, head, -1, &statement, &tail)
                if rc != SQLITE_OK {
                    throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
                }
                cursor = tail
                guard let statement else { continue }   // whitespace / comment
                defer { sqlite3_finalize(statement) }
                if let resultSet = try step(statement) {
                    results.append(resultSet)
                }
            }
        }
        let changed = Int(sqlite3_total_changes(db)) - startTotal
        return RunResult(results: results, changes: changed)
    }

    /// Drive one prepared statement to completion. Returns a `ResultSet`
    /// for column-returning statements, `nil` otherwise.
    private func step(_ statement: OpaquePointer) throws -> ResultSet? {
        let columnCount = Int(sqlite3_column_count(statement))

        if columnCount == 0 {
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                if rc == SQLITE_ROW { continue }
                throw mapStepError(rc)
            }
            return nil
        }

        var columns: [String] = []
        columns.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            columns.append(String(cString: sqlite3_column_name(statement, Int32(index))))
        }

        var rows: [[SQLiteValue]] = []
        var truncated = false
        loop: while true {
            let rc = sqlite3_step(statement)
            switch rc {
            case SQLITE_ROW:
                if rows.count >= policy.rowLimit {
                    truncated = true
                    break loop
                }
                var row: [SQLiteValue] = []
                row.reserveCapacity(columnCount)
                for index in 0..<columnCount {
                    row.append(columnValue(statement, Int32(index)))
                }
                rows.append(row)
            case SQLITE_DONE:
                break loop
            default:
                throw mapStepError(rc)
            }
        }
        return ResultSet(columns: columns, rows: rows, truncated: truncated)
    }

    private func columnValue(_ statement: OpaquePointer, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            if let bytes = sqlite3_column_text(statement, index) {
                // Length-based decode so embedded NULs in TEXT are preserved
                // (String(decodingCString:) would stop at the first NUL).
                let count = Int(sqlite3_column_bytes(statement, index))
                return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: count),
                                    as: UTF8.self))
            }
            return .text("")
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(statement, index) {
                let count = Int(sqlite3_column_bytes(statement, index))
                return .blob(Data(bytes: bytes, count: count))
            }
            return .blob(Data())
        default:
            return .null
        }
    }

    private func mapStepError(_ rc: Int32) -> Error {
        if rc == SQLITE_INTERRUPT {
            if let deadline = ctx.deadlineNanos,
               DispatchTime.now().uptimeNanoseconds > deadline {
                return SQLiteEngineError.timedOut
            }
            return SQLiteEngineError.interrupted
        }
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed"
        return SQLiteError(code: rc, message: message)
    }

    @discardableResult
    private func execInternal(_ sql: String) throws -> Int {
        guard let db else { throw SQLiteEngineError.notOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            throw SQLiteError(code: rc, message: message)
        }
        return Int(sqlite3_changes(db))
    }

    // MARK: Lifecycle

    /// Thread-safe with `SQLITE_THREADSAFE=1` — called from the cancellation
    /// handler, possibly off the actor's executor.
    func interrupt() {
        if let db { sqlite3_interrupt(db) }
    }

    func close() {
        if let db {
            sqlite3_set_authorizer(db, nil, nil)
            sqlite3_close_v2(db)
        }
        db = nil
    }
}
