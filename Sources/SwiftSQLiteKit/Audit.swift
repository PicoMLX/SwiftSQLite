import Foundation

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

/// An `AuditSink` that appends one JSON object per event (JSON Lines) to a
/// host file. The file lives outside the DB, so the trail survives a
/// `DROP TABLE` of the audited data.
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
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: blob)
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? blob.write(to: url)
        }
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
