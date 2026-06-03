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
/// A `MountedFileSystem` remaps virtual paths to host paths, but its mount
/// table is private — so we can't confirm virtual==host here. When the
/// real-disk backing is reached *through* a mount, we therefore require a
/// `sandbox` gate (`hasSandbox`): under `--sandbox` it re-checks the
/// symlink-resolved path against the host workspace root, so a non-identity
/// or out-of-root path **fails closed** (§4) instead of opening the wrong
/// host file. A plain `RealFileSystem` (no remapping) needs no such gate.
/// `Shell.fileSystem` is always wrapped in an `OverlayFileSystem`, so the
/// peel below is required even for the plain real-disk case.
func backingIsSupportedForSQLite(
    _ fileSystem: any FileSystem, hasSandbox: Bool
) -> Bool {
    var current: any FileSystem = fileSystem
    var passedThroughMount = false
    // Bounded peel of wrapper layers (guards against a pathological cycle).
    for _ in 0..<16 {
        if current is RealFileSystem {
            return passedThroughMount ? hasSandbox : true
        }
        if let overlay = current as? OverlayFileSystem {
            current = overlay.backing
            continue
        }
        if let mounted = current as? MountedFileSystem {
            passedThroughMount = true
            current = mounted.backing
            continue
        }
        return false   // InMemoryFileSystem / unknown → refuse
    }
    return false
}
