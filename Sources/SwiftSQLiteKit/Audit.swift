import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A single audit record. Two tiers (PLAN.md §8):
/// - `attempted` comes from the authorizer at *prepare* time — it proves
///   intent, including operations that are later rolled back or denied.
/// - `committed` comes from the update + commit hooks — it proves a row
///   actually landed on a successful `COMMIT`.
public enum AuditEvent: Sendable, Equatable {
    case attempted(action: String, table: String?, allowed: Bool)
    case committed(table: String, rowid: Int64, op: String)

    public var isAttempted: Bool {
        if case .attempted = self { return true }
        return false
    }

    public var isCommitted: Bool {
        if case .committed = self { return true }
        return false
    }
}

/// Where audit events are flushed. Implementations must write **outside**
/// the database under audit, so a free-form `DROP`/`DELETE` cannot erase
/// its own trail. `record` is called off the SQL thread (PLAN.md §8).
public protocol AuditSink: Sendable {
    func record(_ events: [AuditEvent]) async
}

/// An `AuditSink` that keeps events in memory — for tests and callers
/// that want to inspect the trail programmatically.
public actor InMemoryAuditSink: AuditSink {
    public private(set) var events: [AuditEvent] = []

    public init() {}

    public func record(_ events: [AuditEvent]) async {
        self.events.append(contentsOf: events)
    }

    public var attempted: [AuditEvent] { events.filter(\.isAttempted) }
    public var committed: [AuditEvent] { events.filter(\.isCommitted) }
}

/// Carries an `errno`-derived message into `reportFailure`'s diagnostic.
private struct AuditWriteError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// An `AuditSink` that appends one JSON object per event (JSON Lines) to a
/// host file. The file lives outside the DB, so the trail survives a
/// `DROP TABLE` of the audited data. The append uses a raw O_NOFOLLOW open so
/// a symlink swapped in after the path was authorized can't redirect it
/// outside the sandbox.
public actor FileAuditSink: AuditSink {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func record(_ events: [AuditEvent]) async {
        guard !events.isEmpty else { return }
        var blob = Data()
        for event in events {
            blob.append(contentsOf: (event.jsonLine + "\n").utf8)
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // Open with O_NOFOLLOW so a swap of the audit log's *final* component
        // to a symlink after its path was authorized can't redirect the append
        // outside the sandbox. NOTE the deliberate limitation: POSIX O_NOFOLLOW
        // guards only the leaf, so a *parent directory* swapped to a symlink
        // after authorization is still followed here. Closing that race needs
        // openat-style walking from a trusted root fd — deferred to M7 (PLAN
        // §11: per-open symlink enforcement is defense-in-depth, and the file
        // set is already closed by the authorizer + LIMIT_ATTACHED=0 +
        // defensive mode). O_APPEND keeps each flush atomic; O_CREAT creates
        // the log on first write (mode 0600).
        let fd = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else {
            Self.reportFailure(url: url, error: Self.errnoError())
            return
        }
        defer { close(fd) }
        var failure: Error?
        blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(fd, base + written, raw.count - written)
                if n <= 0 { failure = Self.errnoError(); return }
                written += n
            }
        }
        if let failure { Self.reportFailure(url: url, error: failure) }
    }

    /// Snapshot the current `errno` as a human-readable error for
    /// `reportFailure` (e.g. "Too many levels of symbolic links" when a
    /// swapped-in symlink trips O_NOFOLLOW).
    private static func errnoError() -> Error {
        AuditWriteError(message: String(cString: strerror(errno)))
    }

    /// Surface an audit-write failure to stderr rather than silently dropping
    /// records — the audit trail matters most exactly when writes fail (full
    /// disk, I/O error). Kept to a diagnostic since `record` can't throw
    /// (it runs after the SQL has already committed).
    private static func reportFailure(url: URL, error: Error?) {
        let reason = error.map { String(describing: $0) } ?? "could not open audit file"
        let line = "SwiftSQLite: AUDIT WRITE FAILED for \(url.path): \(reason)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

extension AuditEvent {
    /// Compact, single-line JSON encoding (used by `FileAuditSink`).
    var jsonLine: String {
        var object: [String: Any] = [:]
        switch self {
        case let .attempted(action, table, allowed):
            object["kind"] = "attempted"
            object["action"] = action
            object["allowed"] = allowed
            if let table {
                object["table"] = table
            } else {
                object["table"] = NSNull()
            }
        case let .committed(table, rowid, op):
            object["kind"] = "committed"
            object["table"] = table
            object["rowid"] = rowid
            object["op"] = op
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
