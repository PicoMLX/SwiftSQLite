/// The access a caller intends for a database file, handed to the
/// `authorize` closure that gates `SQLiteConnection`'s open (PLAN.md §5,
/// step 1). The engine itself performs no path resolution — the closure
/// is the SwiftBash seam (or a stub, in tests).
public enum AccessIntent: Sendable, Equatable {
    case read
    case write
    case create
}
