# SwiftSQLite — Sandboxed SQLite CLI for SwiftBash (rev. 2)

A pure-Swift package that adds a `sqlite3` command to [SwiftBash](https://github.com/picomlx/swiftbash), backed by a vendored `libsqlite3`. It lets an LLM agent run SQL against a database file **inside the SwiftBash sandbox**, with a SQLite authorizer as the SQL-level safety boundary and a two-tier audit log (attempted + committed) of every mutation.

> **Revisions vs. rev. 1 (addressing design review):** removed the invented `resolveFileURL` API; added **§4 Native-file contract** (M0.5) modeled on `SwiftJSCore` rather than a new translation API; split the **audit** into attempted vs. committed; **deny user `PRAGMA`** and implement dot-commands via `sqlite_schema` queries; tightened the confinement claim; pinned the **external-package boundary**; expanded the **test matrix**.

## 1. Status / locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Engine | Vendored `libsqlite3` amalgamation (no fork) | Full control of compile-time hardening; cross-platform; matches SwiftPorts' "vendor the C lib" pattern |
| Surface | **CLI only** | A generic CLI→MCP bridge comes later; no SQLite-specific MCP tools here |
| Tenancy | **None in this package** | Caller passes an already-sandboxed file URL; tenant/DB routing is the caller's concern |
| SQL policy | **Free-form SQL allowed**, authorizer-bounded | Flexibility; blast radius is one DB file (caller's responsibility), recoverable via caller's backups |
| Audit | **Yes** — two-tier (authorizer + commit hook), written outside the DB | A `DROP`/`DELETE` can't erase its own trail; rolled-back statements don't masquerade as committed |
| Platform | Primary macOS; engine is portable C, keep it Linux-clean | PicoServer is macOS; SwiftBash itself is cross-platform |
| Distribution | **External package** + a `registerSQLiteCommands(at:)` helper | `which`/exec work off-catalog; full virtual-`/bin` visibility is a separate upstream SwiftBash PR |

## 2. Non-goals

- ❌ No MCP server/tools, no JSON-RPC, no network transport.
- ❌ No users, teams, tenants, or per-tenant path resolution.
- ❌ No connection pooling / multi-DB orchestration (one DB per invocation).
- ❌ No interactive REPL (agents pipe SQL via args or stdin).
- ❌ No `FileSystem`-protocol-backed VFS — that protocol is whole-file/sequential (`FileSystem.swift:33-53`) and cannot serve SQLite's random-access page I/O.

## 3. Architecture — three layers

```
┌──────────────────────────────────────────────────────────┐
│ SwiftSQLiteBash   (depends on SwiftBash)                   │
│   SqliteCommand: ParsableBashCommand                       │
│   • argv + safe dot-commands + output modes                │
│   • resolvePath(argv) → authorize → open  (see §4)         │
│   • all output via Shell.current (pipes/redirection)       │
└───────────────▲──────────────────────────────────────────┘
                │ injects `authorize: (URL, Intent) async throws -> Void`
                │ and passes a host file URL
┌───────────────┴──────────────────────────────────────────┐
│ SwiftSQLiteKit   (SwiftBash-AGNOSTIC, unit-testable)       │
│   actor SQLiteConnection(url:policy:audit:authorize:)      │
│   • open/exec/query, row cap, timeout, interrupt-on-cancel │
│   • sqlite3_set_authorizer (policy + attempted-audit)      │
│   • commit/update hooks (committed-audit)                  │
│   • runtime hardening (defensive mode, no ATTACH, …)       │
└───────────────▲──────────────────────────────────────────┘
                │ C interop
┌───────────────┴──────────────────────────────────────────┐
│ CSQLite   (vendored sqlite3.c/.h amalgamation, hardened)   │
└──────────────────────────────────────────────────────────┘
```

**The engine never resolves paths.** It receives a host `URL` plus an `authorize` closure. All path resolution and the virtual==host reasoning (§4) live in `SwiftSQLiteBash`. This keeps the engine unit-testable with a stub authorizer and reusable behind the future MCP bridge.

## 4. Native-file contract (the M0.5 fix)

SwiftBash's `FileSystem` protocol is whole-file, so SQLite can't go through it — it must open a **real host path**, like every other native engine in SwiftBash. We copy the existing, working contract from `SwiftJSCore` rather than invent new API.

**How JS does it (the template):** `Modules+FS.swift` opens host paths directly — `Data(contentsOf: URL(fileURLWithPath: resolved))`, `FileManager.*` — each preceded by `awaitSync { authorizePath(resolved, …) }` (`SandboxBridge.swift:42-69`). `resolved` is just `resolveAgainstShellCWD(path)`. No virtual→host translation happens.

**Why that's sound:** under `swift-bash --sandbox`, the workspace's **virtual path *is* its host path** — `ExecCommand.makeShellSetup()` sets `env["PWD"] = workspace` and mounts the host workspace at that same path (`ExecCommand.swift:158-178`). Bash builtins go through the mount table; native bridges authorize the identical path via `Shell.current.sandbox`; both hit the same real files.

**SQLite's contract (CLI surface):**

```
resolved  = Shell.current.resolvePath(argvPath)   // lexical; ~ + cwd + ./.. only (Shell+Path.swift:20)
canonical = realpath(resolved)                    // resolve symlinks ONCE, in the engine, BEFORE authorize
try await Shell.current.sandbox?.authorize(URL(fileURLWithPath: canonical))   // containment on the resolved path
sqlite3_open_v2(canonical, &db, flags | SQLITE_OPEN_NOFOLLOW, vfs)            // open the SAME path; NOFOLLOW catches later swaps
```

- `resolvePath` is **lexical and does not resolve symlinks** (`Shell+Path.swift:13-14, 57-66`) — that's fine: the **symlink-escape defense lives in `sandbox.authorize`**, which re-checks the symlink-resolved path against the mount root (`Sandbox+BashWorkspace.swift:57-74`). `SQLITE_OPEN_NOFOLLOW` adds a syscall-level backstop against a component swapped to a symlink *after* authorization: SQLite counts **every** symlinked component (`unixFullPathname` → `nSymlink`), so a clean fully-resolved path passes and only a later swap trips it. The engine therefore **canonicalizes once, before `authorize`**, and authorizes + opens that *same* `canonical` string — so they target the identical real file and `NOFOLLOW` guards it (canonicalizing *after* `authorize` would instead re-resolve and silently follow a post-authorization swap, defeating the flag). A naive `NOFOLLOW` on the lexical path would also wrongly reject macOS system symlinks (`/var → /private/var`), which canonicalizing avoids.
- **Engine API** takes a host `URL` directly (per the "caller passes a sandboxed file URL" decision), so it never touches this resolution at all.

**Supported configurations & fail-closed behavior:**

| Bound `Shell` FS / sandbox | Behavior |
|---|---|
| `--sandbox` (MountedFileSystem, workspace virtual==host) + `bashWorkspace` gate | ✅ Supported. Authorize + open the resolved path. |
| `RealFileSystem` / `processDefault` (no sandbox) | ✅ Supported (user's own shell; no confinement expected). |
| Custom MountedFileSystem where virtual≠host **with the `bashWorkspace` gate** | ✅ **Fails closed** — the gate is `rooted(at: hostWorkspace)`, so a virtual path that isn't under the host root is *denied*, not silently mis-opened. |
| `InMemoryFileSystem`, or virtual≠host with a *matching* custom gate | ❌ **Unsupported for the CLI** — refuse with a clear error. Use the engine API with explicit host URLs, or `:memory:`. (This is the same latent limitation `SwiftJSCore` already has.) |

**M0.5 deliverable is documentation + a guard, not a new API:** mirror the `SwiftJSCore` resolve→authorize→open contract, document the virtual==host requirement, and have `SqliteCommand` refuse non-real/non-identity backings with a clear message instead of opening the wrong file.

## 5. Security model — "authorize, then native I/O"

Four steps, priority order:

1. **Gate the open** (async Swift, before any C call) — §4: `resolvePath` → `sandbox.authorize` → `sqlite3_open_v2(… NOFOLLOW)`, no `SQLITE_OPEN_URI`.
2. **Pin auxiliary files in-region** — `-journal`/`-wal`/`-shm` are siblings of the DB (already in the authorized dir). Temp spill defaults to *host* temp (and the `/tmp`↔host-temp split frays the invariant), so set `sqlite3_temp_directory` into a subdir of the authorized workspace, or `PRAGMA temp_store = MEMORY`.
3. **Close the SQL escape hatches** — `ATTACH`/`load_extension()` are SQLite's `child_process`. Removed via compile flags + runtime config + the authorizer (§7).
4. **(Optional, M7) Shim VFS** — wraps the *native unix VFS* and runs `authorize()` inside `xOpen`/`xAccess`/`xDelete` before delegating, for per-open enforcement. VFS callbacks are sync C, so this is the only place needing the `awaitSync` semaphore bridge. WAL/random-I/O still work (it's an interceptor, not a reimplementation).

**Confinement claim (precise):** *Steps 1–3 confine the authorized primary DB path and SQLite's **known** auxiliary files (journal/WAL/shm siblings + pinned temp). The set of files SQLite can open is closed and enumerable — `OMIT_LOAD_EXTENSION` (compile), `LIMIT_ATTACHED=0`, defensive mode, URI off — so M7 is defense-in-depth (per-`xOpen` enforcement against future SQLite features), not a correctness prerequisite.*

## 6. Compile-time hardening (`CSQLite`)

```
SQLITE_THREADSAFE=1
SQLITE_OMIT_LOAD_EXTENSION       // load_extension() removed at compile time — cannot be re-enabled
SQLITE_DQS=0                     // no double-quoted string literals
SQLITE_USE_URI=0                 // no file: URI tricks
SQLITE_DEFAULT_FOREIGN_KEYS=1
SQLITE_OMIT_DEPRECATED
SQLITE_DEFAULT_MEMSTATUS=0       // perf
// optional: SQLITE_ENABLE_PREUPDATE_HOOK (value-level audit), SQLITE_ENABLE_FTS5
// (JSON functions are already default-on in modern SQLite)
```

## 7. Runtime hardening + authorizer

After `open`, before any user SQL:

```swift
sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, nil)
sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 0, nil)
sqlite3_db_config(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, nil)
sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)            // belt-and-suspenders: no attached DBs
sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 1_000_000)  // DoS guard
sqlite3_busy_timeout(db, 5_000)
sqlite3_exec(db, "PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;", …)  // we issue needed pragmas
sqlite3_set_authorizer(db, authCallback, ctx)
sqlite3_progress_handler(db, 10_000, progressCallback, ctx)
sqlite3_commit_hook(db, commitCallback, ctx)
sqlite3_update_hook(db, updateCallback, ctx)
```

**Authorizer policy** (the single SQL-enforcement choke point; fires at `prepare`):

| Action code | Decision |
|---|---|
| `SQLITE_ATTACH`, `SQLITE_DETACH` | **DENY** |
| `SQLITE_PRAGMA` | **DENY (all user PRAGMA).** We set the few we need via the C API above; dot-commands use `sqlite_schema` queries, not PRAGMA. |
| `SQLITE_READ`/`INSERT`/`UPDATE`/`DELETE`/`CREATE_*`/`DROP_*`/`ALTER_TABLE` | **ALLOW** on user tables; **DENY** when the table matches `sqlite_*` or the reserved `_audit*` namespace |
| `SQLITE_SELECT`, `SQLITE_TRANSACTION`, `SQLITE_FUNCTION` (safe builtins) | **ALLOW** |
| anything unrecognized | **DENY** (default-deny) |

Result limits (in the Swift step-loop, not the authorizer): **row cap** (default 10k, configurable) and **timeout** (progress handler checks a captured deadline; a cancelled `Task` calls `sqlite3_interrupt(db)`).

## 8. Audit model (two tiers)

The authorizer fires at **prepare**, so by itself it only proves *intent*, not *commit*. We record both:

- **Attempted stream** — from the authorizer callback: `(action, table, decision)` for every allowed/denied operation. Captures a rolled-back `DELETE` as *attempted*, never as committed.
- **Committed stream** — from `sqlite3_commit_hook` (fires on successful `COMMIT`) plus `sqlite3_update_hook` (per-row `INSERT`/`UPDATE`/`DELETE` with table + rowid). For value-level detail, optionally use the preupdate hook (`SQLITE_ENABLE_PREUPDATE_HOOK`).

Implementation rules:
- C callbacks are sync on the SQL thread — push **lightweight records into an in-memory buffer**; flush to the `AuditSink` (async) after statement/transaction completion or on `close()`. Never do async I/O inside a C callback.
- `AuditSink` writes **outside the tenant DB** (separate append-only file or audit DB) so a free-form `DROP`/`DELETE` can't erase its own trail.

## 9. Package.swift (sketch)

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftSQLite",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftSQLiteKit", targets: ["SwiftSQLiteKit"]),
        .library(name: "SwiftSQLiteBash", targets: ["SwiftSQLiteBash"]),
    ],
    dependencies: [
        .package(url: "https://github.com/picomlx/swiftbash", branch: "main"),
    ],
    targets: [
        .target(
            name: "CSQLite",
            cSettings: [
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_DQS", to: "0"),
                .define("SQLITE_USE_URI", to: "0"),
                .define("SQLITE_DEFAULT_FOREIGN_KEYS", to: "1"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
                // .define("SQLITE_ENABLE_PREUPDATE_HOOK"),
            ]
        ),
        .target(name: "SwiftSQLiteKit", dependencies: ["CSQLite"]),
        .target(
            name: "SwiftSQLiteBash",
            dependencies: [
                "SwiftSQLiteKit",
                .product(name: "BashCommandKit", package: "swiftbash"),
                .product(name: "BashInterpreter", package: "swiftbash"),
            ]
        ),
        .testTarget(name: "SwiftSQLiteKitTests", dependencies: ["SwiftSQLiteKit"]),
        .testTarget(name: "SwiftSQLiteBashTests", dependencies: ["SwiftSQLiteBash"]),
    ]
)
```

`Sources/CSQLite/` holds `sqlite3.c`, `include/sqlite3.h`, a module map, and a `VERSION` file pinning the amalgamation release.

## 10. Public API (sketch)

```swift
// SwiftSQLiteKit — SwiftBash-agnostic

public enum AccessIntent: Sendable { case read, write, create }

public protocol AuditSink: Sendable {
    func record(_ events: [AuditEvent]) async   // flushed off the SQL thread; writes OUTSIDE the DB
}

public enum AuditEvent: Sendable {
    case attempted(action: String, table: String?, allowed: Bool)   // from authorizer (prepare-time)
    case committed(table: String, rowid: Int64, op: String)         // from update/commit hooks
}

public struct EnginePolicy: Sendable {
    public var rowLimit = 10_000
    public var statementTimeout: Duration = .seconds(30)
    public var readOnly = false
    public var reservedTablePrefix = "_audit"
    public static let `default` = EnginePolicy()
}

public actor SQLiteConnection {
    /// `url` is a HOST file URL (caller-resolved). `authorize` is the SwiftBash seam;
    /// pass a stub in tests. The engine calls `authorize(url, intent)` before opening.
    public init(
        url: URL,
        policy: EnginePolicy = .default,
        audit: any AuditSink,
        authorize: @Sendable @escaping (URL, AccessIntent) async throws -> Void
    ) async throws

    public func execute(_ sql: String) async throws -> Int        // affected rows
    public func query(_ sql: String) async throws -> ResultSet     // capped + timed
    public func close() async
}

public struct ResultSet: Sendable {
    public let columns: [String]
    public let rows: [[SQLiteValue]]
    public let truncated: Bool   // true if rowLimit hit
}
```

```swift
// SwiftSQLiteBash — the only target that imports SwiftBash

public struct SqliteCommand: ParsableBashCommand {
    @Argument var database: String
    @Argument(parsing: .remaining) var sql: [String]
    @Flag(name: .customLong("readonly")) var readOnly = false
    @Option var mode: OutputMode = .list      // list | csv | json | column | line
    @Flag var header = false

    public mutating func execute() async throws -> ExitStatus {
        // §4 contract: refuse unsupported backings, else resolve + authorize + open the same string.
        let resolved = Shell.current.resolvePath(database)
        let conn = try await SQLiteConnection(
            url: URL(fileURLWithPath: resolved),
            policy: policy,
            audit: ShellAuditSink(),                              // writes outside the DB
            authorize: { url, _ in
                try await Shell.current.sandbox?.authorize(url)   // symlink-resolved containment
            })
        // statements from args or stdin; render via Shell.current's stdout sink.
    }
}

/// External-package registration helper (see §1 / Milestone 5).
public extension Shell {
    func registerSQLiteCommands(at path: String = "/usr/bin/sqlite3") {
        install(SqliteCommand.self, at: path)
    }
}
```

**CLI surface:** `sqlite3 [OPTS] DBFILE [SQL...]` — SQL from args, else stdin to EOF. Output modes `list`/`csv`/`json`/`column`/`line`, `-header`, `-separator`. **Safe dot-commands implemented via `sqlite_schema` queries:** `.tables`, `.schema [T]`, `.indexes`, `.databases`, plus client-side `.headers`/`.mode`/`.separator`/`.quit`/`.dump`(stdout). **Removed (error, not silent):** `.shell`, `.system`, `.import`, `.export`, `.output`, `.once`, `.load`, `.read`, `.backup`, `.restore`, `.archive`, `.cd`, `.open`, `.recover`.

## 11. Milestones

- [ ] **M0** — Package skeleton; vendor `CSQLite` amalgamation with hardening flags; builds clean on macOS **and** Linux.
- [ ] **M0.5** — **Native-file contract (§4):** adopt the `SwiftJSCore` resolve→authorize→open pattern; document the virtual==host assumption; `SqliteCommand` refuses non-real/non-identity backings with a clear error; engine API takes a host `URL`.
- [ ] **M1** — `SQLiteConnection` actor: gated open, `execute`/`query`, value/row mapping, error→Swift mapping.
- [ ] **M2** — Authorizer policy (§7) + `LIMIT_ATTACHED=0` + runtime hardening; row cap + progress-handler timeout + `sqlite3_interrupt` on cancel.
- [ ] **M3** — Two-tier audit (§8): authorizer stream + commit/update hooks; buffered flush to an `AuditSink` that writes outside the DB.
- [ ] **M4** — `SqliteCommand`: argv, output modes, stdin, safe dot-commands via `sqlite_schema`, temp pinned in-region, wired to `Shell.current.sandbox`.
- [ ] **M5** — **External-package registration:** `Shell.registerSQLiteCommands(at:)` via `install(_:at:)`; README + usage. *(Full virtual-`/bin` visibility — so `/bin` listings show `sqlite3` — is a separate one-line `BinCatalog` PR to SwiftBash; note it, don't assume it.)*
- [ ] **M6** — Security/escape + audit-semantics test suite (§12) + cross-platform CI.
- [ ] **M7** *(optional)* — Shim VFS over the native unix VFS for per-`xOpen` enforcement, using the `awaitSync` bridge.

## 12. Testing

**Engine (`SwiftSQLiteKit`, injected `authorize` stub):** CRUD; row cap sets `truncated`; timeout interrupts a hot loop; error mapping; `authorize` rejection blocks open.

**Native-file contract (§4):**
- Virtual-path open under `--sandbox` resolves and opens the correct host file.
- `InMemoryFileSystem` (and non-identity mount) → **refused with a clear error**, not a wrong-file open.
- A DB path symlinked outside the workspace → `Sandbox.Denial`.
- `WAL`/`-journal`/`-shm` and temp spill all land **inside** the authorized dir.

**SQL escape hatches:**
- `ATTACH DATABASE '/etc/passwd' AS x` → denied (authorizer + `LIMIT_ATTACHED=0`).
- `SELECT load_extension(...)` → function absent (compile-omitted).
- Writes to `sqlite_master` / `_audit*` → denied.
- `PRAGMA writable_schema=ON` (and any user PRAGMA) → blocked.
- `.shell echo pwned` → command rejected.

**Audit semantics:**
- A rolled-back `DELETE` appears in the **attempted** stream and **not** in the **committed** stream.
- A committed `INSERT`/`UPDATE`/`DELETE` appears in **both**.
- Audit trail intact after a `DROP TABLE` (written outside the DB).

**Cross-platform:** the escape + contract suites run identically on macOS + Linux.

## 13. Open knobs

1. **Journal mode** — WAL (best concurrency; `-wal`/`-shm` siblings) vs rollback (`-journal`; simplest). Both fine on native I/O.
2. **M7 shim VFS** — ship now vs defer (recommended: defer; §5 confinement is closed/enumerable without it). Partial symlink-race hardening is already in place: the **DB open** canonicalizes before `authorize` and opens with `SQLITE_OPEN_NOFOLLOW`, which is race-free (SQLite rejects the open if any component became a symlink after authorization). Two residual TOCTOU gaps are explicitly **M7-scope**: (a) the **audit-log append** uses leaf-only `O_NOFOLLOW`, so a *parent-directory* swapped to a symlink after authorization is still followed (needs `openat`-style walking from a trusted root fd); and (b) **WAL `-wal`/`-shm` sidecars** aren't separately authorized, so a Kit caller whose `authorize` grants a single file rather than its directory could see siblings created next to it.
3. **`:memory:`** — the supported answer for in-memory/non-identity-mount callers that can't use a host file URL.
4. **Value-level audit** — enable `SQLITE_ENABLE_PREUPDATE_HOOK` if old/new row values are needed (vs. table+rowid only). It is also the way to capture the remaining committed-DELETE case: the authorizer returns `SQLITE_IGNORE` for `SQLITE_DELETE` so `DELETE FROM t` is deleted row-by-row (defeating the truncate optimization) and thus seen by `sqlite3_update_hook`, but rows deleted via `ON CONFLICT REPLACE` are still not reported by the update hook — only the preupdate hook sees those. **`WITHOUT ROWID` tables** are the same shape: `sqlite3_update_hook` doesn't fire for them at all, so their writes appear in the attempted stream but not the committed stream until the preupdate hook is enabled. **DDL-bulk row changes** are also in this family — `CREATE TABLE … AS SELECT` (CTAS) populating rows, and `DROP TABLE` removing a table's rows, don't fire the update hook either, so the *committed* stream has no per-row events for them. (Both operations are still recorded at DDL granularity in the *attempted* stream via the authorizer — `CREATE_TABLE`/`DROP_TABLE` — so the trail shows that they happened; only per-row enumeration awaits the preupdate hook.) (Full `COMMIT`/`ROLLBACK` and `ROLLBACK TO SAVEPOINT` audit boundaries are accurate; two best-effort edges remain in the same family: a statement the engine aborts mid-way *within an open cross-call transaction* can leave its pre-error update-hook rows pending, and savepoint markers are applied at *prepare* time, so a `RELEASE`/`ROLLBACK TO` that fails at *step* — e.g. a deferred-FK violation on an outermost `RELEASE` — can momentarily desync a marker. Both need step-time hooks the SQLite C API doesn't expose for savepoints.)
5. **Bounded stdin** — SQL piped on stdin is currently read fully into memory before `SQLITE_LIMIT_SQL_LENGTH` (a prepare-time cap) applies. An incremental, capped stdin read (rejecting input past `EnginePolicy.maxSQLLength` as it's consumed) is a follow-up for hardening against a large-pipe memory DoS.
6. **`.dump` fidelity edges** — (a) **non-UTF-8 TEXT**: SQLite doesn't enforce UTF-8; bytes from e.g. `CAST(x'80' AS TEXT)` are lossily decoded to U+FFFD at read time, so `.dump` can't recover them (preserving them needs the value model to carry raw bytes for TEXT vs. a Swift `String`). (b) **generated columns**: a `SELECT *`-based positional `VALUES(...)` includes generated values that can't be inserted, so replay fails. Excluding them needs per-table column introspection — but `pragma_table_xinfo` trips the denied `SQLITE_PRAGMA` authorizer, so a fix must either allow that one read-only introspection pragma (safe: it exposes nothing beyond `sqlite_schema`, which is already readable) or parse the schema text. Both advanced edges; follow-ups.
7. **Internal `sqlite_*` table tampering** — user SQL can still `UPDATE sqlite_sequence SET seq=…` / `DELETE FROM sqlite_sequence` (perturbing future AUTOINCREMENT rowid allocation), and `ALTER TABLE t RENAME TO _audit_x` can place an object in the reserved namespace (the authorizer sees only the OLD name on a RENAME). Neither is cleanly fixable at the authorizer: `ALTER … RENAME` emits an internal nested `UPDATE "…".sqlite_sequence SET name=…` (sqlite3.c) and `DROP TABLE` an internal `DELETE FROM …sqlite_sequence`, which fire the **same** `SQLITE_UPDATE`/`SQLITE_DELETE` on the same table as the user statements — so denying those would break legitimate AUTOINCREMENT DDL. Impact is bounded: rowid-allocation perturbation, not a sandbox escape, and the authoritative audit trail is an external file, so a forged in-DB `_audit*` table can't corrupt it. A real fix needs the preupdate hook or post-execution schema validation.
8. **Blanket `SQLITE_FUNCTION` allow** — the authorizer allows every scalar/aggregate function rather than an allowlist. Safe for the *pinned* build (`load_extension` compile-omitted; `readfile`/`writefile`/`fsdir`/`edit` are CLI-shell-only, absent from the amalgamation; `dbpage`/`dbstat` vtabs not enabled; `zeroblob`/`randomblob` bounded by `SQLITE_LIMIT_LENGTH`), but a future flag change (FTS tokenizers, DBPAGE, app-defined functions) would widen the boundary with no authorizer backstop. Hardening follow-up: an arg2 function-name allow/deny-list, re-validated on SQLite version bumps.
9. **`.dump` / large-output buffering & hot loops** — `.dump` builds the whole export into one in-memory `String` before writing (bounded per-table by `rowLimit`, but not *across* tables); blob/embedded-NUL rendering formats hex one byte at a time via `String(format:)`; and `SQLiteStatements.split` re-scans the growing buffer with `sqlite3_complete` at every `;` (O(n²) on large multi-statement input). All are performance / peak-memory follow-ups (stream rows incrementally, direct nibble→hex encoding, incremental statement splitting) — not correctness or escape issues. (Total *result-set* memory and the audit buffers are now bounded — `maxResultBytes`/`maxAuditRecords`.)
10. **Native engine supports identity mounts only** — the native-file engine opens the *host* path handed to SQLite, but `SqliteCommand` only has the script-visible *virtual* path (BashInterpreter intentionally hides host paths: `MountedFileSystem.canonicalize` returns the virtual path, and the mount table / `resolve()` are not public). The shipping `--sandbox` workspace is an **identity** mount (virtual==host, §4), so this is correct. A *non-identity* mount (virtual≠host) passes `backingIsSupportedForSQLite`'s sandbox gate yet would make SQLite open the wrong host path — neither detectable nor correctable in-repo. A real fix needs a trusted host-path-translation API added to BashInterpreter (which deliberately hides host paths) plus a dependency repoint — out of scope and PR-coupling — so non-identity mounts are unsupported. (Explicit `-audit` now also requires native backing, so it can't write a host file on a non-native shell.)
11. **Create-vs-existing open race** — `SQLiteConnection.init(url:)` checks file existence once to pick the `AccessIntent` (`.create` vs `.write`) and the open's `CREATE` flag. Between that check and `sqlite3_open_v2`, a file racing into the path means a caller that authorized only `.create` ends up opening a pre-existing DB, so a policy that allows *creating* new DBs but denies *writing* existing ones could be bypassed in an attacker-writable directory. Closing it needs an exclusive-create open (`O_EXCL` semantics, not exposed by `sqlite3_open_v2`) or re-authorizing as `.write` when a non-exclusive open finds existing content — same open-time-atomicity family as knob #2 (M7). Narrow: requires a create-but-not-write policy *and* a writable parent *and* a race; the shipping `--sandbox` authorize doesn't draw that create/write distinction.

## 14. References (SwiftBash files this design mirrors)

- `Sources/SwiftJSCore/Modules+FS.swift` + `SwiftJSCore/SandboxBridge.swift` — the native-engine resolve→authorize→open template (§4).
- `Sources/swift-bash/ExecCommand.swift:158-178` — proves workspace virtual==host under `--sandbox`.
- `Sources/BashInterpreter/API/Shell+Path.swift:13-14,20,57-66` — `resolvePath` is lexical (symlink handling is the sandbox's job).
- `Sources/BashInterpreter/API/Sandbox+BashWorkspace.swift:57-74` — symlink-resolved containment check.
- `Sources/BashInterpreter/API/FileSystem.swift:33-53` — whole-file API (why no protocol VFS).
- `Sources/BashCommandKit/API/ParsableBashCommand.swift` — the command protocol; `Shell+Commands.swift` (`install(_:at:)`) — registration.
