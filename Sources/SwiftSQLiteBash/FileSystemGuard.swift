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
/// table and host translation are not public, and `SqliteCommand` hands SQLite
/// the *virtual* path (BashInterpreter deliberately hides host paths from
/// scripts — `canonicalize` returns the virtual path). When the real-disk
/// backing is reached *through* a mount we require a `sandbox` gate
/// (`hasSandbox`); under `--sandbox` the workspace is an **identity** mount
/// (virtual==host, §4), so the virtual path SQLite opens *is* the host path.
///
/// KNOWN LIMITATION (PLAN §13): a *non-identity* mount (virtual≠host) passes
/// this gate yet would make SQLite open the wrong host path. It can't be
/// detected or corrected in-repo without a host-path-translation API the
/// dependency intentionally doesn't expose, so the native engine effectively
/// supports only identity mounts (which is what the shipping `--sandbox`
/// provides). A plain `RealFileSystem` (no remapping) needs no gate.
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
