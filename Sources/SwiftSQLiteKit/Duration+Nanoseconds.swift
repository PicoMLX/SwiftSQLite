import Foundation

extension Duration {
    /// This duration in whole nanoseconds, clamped at zero for negative
    /// values. Used for the progress-handler deadline.
    var nanoseconds: UInt64 {
        let parts = components
        guard parts.seconds >= 0 else { return 0 }
        // Overflow-safe: a very large Duration clamps to .max (an effectively
        // infinite deadline) rather than wrapping to a tiny one.
        let (secNanos, overflow) = UInt64(parts.seconds)
            .multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return .max }
        let attoNanos = UInt64(max(0, parts.attoseconds)) / 1_000_000_000
        let (total, addOverflow) = secNanos.addingReportingOverflow(attoNanos)
        return addOverflow ? .max : total
    }

    /// This duration in whole milliseconds as an `Int32`, for the
    /// SQLite C APIs that take a millisecond `int` (e.g. busy timeout).
    var millisecondsInt32: Int32 {
        Int32(clamping: Int64(nanoseconds / 1_000_000))
    }
}
