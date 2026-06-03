# SwiftSQLite

A pure-Swift package that adds a sandboxed **`sqlite3`** command to
[SwiftBash](https://github.com/picomlx/swiftbash), backed by a vendored,
compile-time-hardened `libsqlite3`. It lets an LLM agent run free-form SQL
against a database file **inside the SwiftBash sandbox**, with a SQLite
authorizer as the SQL-level safety boundary and a two-tier audit log
(attempted + committed) of every mutation.

See [`PLAN.md`](PLAN.md) for the full design (rev. 2).

## Products

| Product | Imports SwiftBash? | What it is |
|---|---|---|
| `SwiftSQLiteKit` | **No** | The engine: `SQLiteConnection` actor, authorizer policy, two-tier audit. Unit-testable with a stub `authorize` closure; reusable behind a future MCP bridge. |
| `SwiftSQLiteBash` | Yes | The `sqlite3` command + `Shell.registerSQLiteCommands(at:)`. |
| `CSQLite` | — | The vendored, hardened `libsqlite3` amalgamation. |

## Building

The SQLite amalgamation (`sqlite3.c` / `sqlite3.h`) is **vendored (committed)**,
so a fresh clone builds with no prerequisite step:

```sh
swift build
swift test
```

To **update** to a new SQLite release, bump the four fields in
`Sources/CSQLite/VERSION` (version, amalgamation id, year, and the official
SHA3-256 from <https://www.sqlite.org/download.html>) and re-vendor:

```sh
scripts/fetch-sqlite.sh --force   # downloads + SHA3-256-verifies, then commit the result
```

The script **fails closed** on a hash mismatch. (CI can also re-vendor via the
`Vendor SQLite amalgamation` workflow when `VERSION` changes.)

## Usage

Register the command on a `Shell`, then invoke it like the real `sqlite3`:

```swift
import SwiftSQLiteBash

let shell = Shell()
shell.registerSQLiteCommands()                 // installs /usr/bin/sqlite3

try await shell.run("sqlite3 data.db 'CREATE TABLE t(x); INSERT INTO t VALUES (1);'")
try await shell.run("sqlite3 -json data.db 'SELECT * FROM t;'")
```

SQL comes from the trailing argument(s), or from **stdin** when none are
given. Output modes: `list` (default), `csv`, `json`, `column`, `line`
(`-mode`, or the `-csv`/`-json`/… shorthands), plus `-header`,
`-separator`, `-nullvalue`. Use `:memory:` as the database for an
in-memory database.

### Safe dot-commands

Implemented via `sqlite_schema` queries / client-side state:
`.tables`, `.schema [NAME]`, `.indexes [TABLE]`, `.databases`, `.headers`,
`.mode`, `.separator`, `.nullvalue`, `.dump [TABLE]`, `.quit`.

Dot-commands that reach outside the database/sandbox are **removed and
error** (never silently ignored): `.shell`, `.system`, `.import`,
`.export`, `.output`, `.once`, `.load`, `.read`, `.backup`, `.restore`,
`.archive`, `.cd`, `.open`, `.recover`.

## Security model (summary)

1. **Gate the open** — the command resolves the path, calls
   `sandbox.authorize` (symlink-resolved containment), then opens it with
   `SQLITE_OPEN_NOFOLLOW` and no URI parsing. The path is canonicalized
   first, so `NOFOLLOW` guards against a component swapped to a symlink
   *after* authorization rather than tripping on legitimate system symlinks
   (e.g. macOS `/var → /private/var`, which SQLite would otherwise reject —
   it counts every symlinked component) (PLAN.md §4).
2. **Pin auxiliary files** — `temp_store=MEMORY`; WAL/journal/shm are
   in-directory siblings.
3. **Close the SQL escape hatches** — `load_extension()` compiled out,
   `ATTACH`/`DETACH` denied (and `SQLITE_LIMIT_ATTACHED=0`), all user
   `PRAGMA` denied, schema-table and reserved `_audit*` writes denied,
   defensive mode + untrusted schema on. Anything unrecognized is
   default-denied.
4. **Audit everything** — the authorizer records every *attempted*
   operation (intent, including denied/rolled-back); the commit + update
   hooks record every *committed* row. The audit log is written **outside**
   the database (opened `O_NOFOLLOW` too, so it can't be redirected by a
   symlink swapped in after its path was authorized), so a `DROP`/`DELETE`
   cannot erase its own trail.

## Engine API (SwiftBash-agnostic)

```swift
import SwiftSQLiteKit

let connection = try await SQLiteConnection(
    url: URL(fileURLWithPath: "/path/in/sandbox/data.db"),
    policy: .default,
    audit: FileAuditSink(url: auditURL),
    authorize: { url, intent in /* your sandbox check */ })

let rows = try await connection.query("SELECT * FROM users;")
let changed = try await connection.execute("DELETE FROM sessions WHERE expired;")
await connection.close()
```

## Status

Milestones M0–M6 are implemented (M7, the optional shim VFS, is deferred —
see PLAN.md §13). Cross-platform CI (macOS + Linux) runs the fetcher and
the §12 test matrix.
