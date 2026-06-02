import BashInterpreter

/// PLAN.md §4 — the native-file contract. SQLite must open a **real host
/// path** (its random-access page I/O can't go through SwiftBash's
/// whole-file `FileSystem` protocol), so a command refuses to run when the
/// bound shell's filesystem cannot serve real-disk I/O.
///
/// Default-deny: returns `true` only for backings we can *prove* reach real
/// disk — a `RealFileSystem`, or a `MountedFileSystem`/`OverlayFileSystem`
/// that (recursively) wraps one. Everything else — `InMemoryFileSystem`,
/// an overlay over memory, any future backing — is refused.
///
/// This guard does **not** replace `sandbox.authorize`, which remains the
/// real containment boundary (and fails closed for a non-identity mount
/// whose virtual path escapes the host root). The guard only prevents the
/// surprising case of silently opening the wrong file under an in-memory
/// or non-disk backing. (`Shell.fileSystem` is always wrapped in an
/// `OverlayFileSystem`, so the peel below is required even for the plain
/// real-disk case.)
func backingReachesRealDisk(_ fileSystem: any FileSystem) -> Bool {
    var current: any FileSystem = fileSystem
    // Bounded peel of wrapper layers (guards against a pathological cycle).
    for _ in 0..<16 {
        if current is RealFileSystem { return true }
        if let overlay = current as? OverlayFileSystem {
            current = overlay.backing
            continue
        }
        if let mounted = current as? MountedFileSystem {
            current = mounted.backing
            continue
        }
        return false
    }
    return false
}
