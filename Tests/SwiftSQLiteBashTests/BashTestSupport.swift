import BashCommandKit
import BashInterpreter
import Foundation
import SwiftSQLiteBash

/// Output captured from running a command line through a `Shell`.
struct CaptureResult: Sendable {
    let status: ExitStatus
    let stdout: String
    let stderr: String
}

/// Wrap a String as an `InputSource` using only public API
/// (`InputSource(bytes:)` over an `AsyncStream<Data>` — the same shape the
/// SwiftBash source uses for in-process stdin).
func stringInput(_ text: String) -> InputSource {
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    continuation.yield(Data(text.utf8))
    continuation.finish()
    return InputSource(bytes: stream)
}

/// Run `commandLine` on `shell`, capturing stdout/stderr via buffering
/// `OutputSink`s (the public pattern from `SwiftJSCore.ChildProcess`).
@discardableResult
func runCapturing(
    _ shell: Shell,
    _ commandLine: String,
    stdin: String? = nil
) async throws -> CaptureResult {
    let outSink = OutputSink()
    let errSink = OutputSink()
    shell.stdout = outSink
    shell.stderr = errSink
    if let stdin { shell.stdin = stringInput(stdin) }

    async let outDrain: String = outSink.readAllString()
    async let errDrain: String = errSink.readAllString()

    let status = try await shell.run(commandLine)
    outSink.finish()
    errSink.finish()
    return CaptureResult(status: status, stdout: await outDrain, stderr: await errDrain)
}

/// A throwaway temp directory; the closure receives its absolute path.
func withTempDirectory<T>(_ body: (String) async throws -> T) async rethrows -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftsqlite-bash-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory.path)
}
