import Foundation

extension Duration {
    /// This duration in whole nanoseconds, clamped at zero for negative
    /// values. Used for the progress-handler deadline.
    var nanoseconds: UInt64 {
        let parts = components
        let secs = parts.seconds < 0 ? 0 : UInt64(parts.seconds)
        let attos = parts.attoseconds < 0 ? 0 : UInt64(parts.attoseconds)
        return secs &* 1_000_000_000 &+ (attos / 1_000_000_000)
    }

    /// This duration in whole milliseconds as an `Int32`, for the
    /// SQLite C APIs that take a millisecond `int` (e.g. busy timeout).
    var millisecondsInt32: Int32 {
        Int32(clamping: Int64(nanoseconds / 1_000_000))
    }
}
