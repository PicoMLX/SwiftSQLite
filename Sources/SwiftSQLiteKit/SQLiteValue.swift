import Foundation

/// One cell from a result row — the five SQLite storage classes.
public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public extension SQLiteValue {
    /// `true` for `.null`.
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// A best-effort textual rendering of the value (blobs become a
    /// `<N bytes>` placeholder). Output formatting in the CLI layer
    /// applies its own per-mode rules on top of this.
    var displayText: String {
        switch self {
        case .null: return ""
        case .integer(let i): return String(i)
        case .real(let d): return String(d)
        case .text(let s): return s
        case .blob(let data): return "<\(data.count) bytes>"
        }
    }

    /// Approximate copied-out byte size — used to bound a result set's *total*
    /// memory (`EnginePolicy.maxResultBytes`). TEXT/BLOB dominate; scalars and
    /// NULL count as a small fixed cost so wide all-scalar rows still register.
    var approxByteSize: Int {
        switch self {
        case .null: return 1
        case .integer, .real: return 8
        case .text(let s): return s.utf8.count
        case .blob(let data): return data.count
        }
    }
}
