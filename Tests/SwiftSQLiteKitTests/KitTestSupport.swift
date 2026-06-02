import Foundation
@testable import SwiftSQLiteKit

/// A permissive open gate for engine tests that don't exercise the seam.
let allowAllAuthorize: @Sendable (URL, AccessIntent) async throws -> Void = { _, _ in }

/// A fresh temp directory + DB URL. Caller passes the URL's parent to
/// `cleanupTempDB` when done.
func makeTempDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftsqlitekit-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("test.db")
}

func cleanupTempDB(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

struct StubDenied: Error {}
