// swift-tools-version: 6.0
// SwiftSQLite — a sandboxed `sqlite3` command for SwiftBash.
// See PLAN.md for the full design (rev. 2).
import PackageDescription

let package = Package(
    name: "SwiftSQLite",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // SwiftBash-agnostic engine: the SQLiteConnection actor, the
        // authorizer, the two-tier audit. Unit-testable with a stub
        // `authorize` closure; reusable behind a future MCP bridge.
        .library(name: "SwiftSQLiteKit", targets: ["SwiftSQLiteKit"]),
        // The only target that imports SwiftBash — the `sqlite3` command
        // plus the `Shell.registerSQLiteCommands(at:)` helper.
        .library(name: "SwiftSQLiteBash", targets: ["SwiftSQLiteBash"]),
    ],
    dependencies: [
        // No changes to SwiftBash are required: the `install(_:at:)`
        // registration API already exists on `Shell`. Full virtual-`/bin`
        // visibility is a separate upstream BinCatalog change (PLAN.md §M5).
        .package(url: "https://github.com/picomlx/swiftbash", branch: "main"),
    ],
    targets: [
        // Vendored libsqlite3 amalgamation, hardened at compile time
        // (PLAN.md §6). `sqlite3.c` / `include/sqlite3.h` ARE committed
        // (vendored in-repo, so a clean checkout builds offline);
        // `scripts/fetch-sqlite.sh` regenerates them — SHA3-256-pinned — on a
        // version bump. `shims.c` / `include/csqlite_shims.h` are committed
        // too: they wrap the variadic `sqlite3_db_config()` calls Swift
        // cannot reach directly.
        .target(
            name: "CSQLite",
            exclude: ["VERSION"],
            cSettings: [
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),   // load_extension() gone at compile time
                .define("SQLITE_DQS", to: "0"),          // no double-quoted string literals
                .define("SQLITE_USE_URI", to: "0"),      // no file: URI tricks
                .define("SQLITE_DEFAULT_FOREIGN_KEYS", to: "1"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
                // NOTE: no .unsafeFlags here — a target that uses unsafe flags
                // and sits in a product's dependency chain makes that product
                // unusable as a dependency by downstream SwiftPM packages
                // (e.g. SwiftBash consuming SwiftSQLite). The amalgamation's
                // benign warnings are acceptable noise.
            ],
            linkerSettings: [
                // sqlite3.c calls into libm; Apple links it by default,
                // Linux does not.
                .linkedLibrary("m", .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "SwiftSQLiteKit",
            dependencies: ["CSQLite"]
        ),
        .target(
            name: "SwiftSQLiteBash",
            dependencies: [
                "SwiftSQLiteKit",
                .product(name: "BashCommandKit", package: "swiftbash"),
                .product(name: "BashInterpreter", package: "swiftbash"),
            ]
        ),
        .testTarget(
            name: "SwiftSQLiteKitTests",
            dependencies: ["SwiftSQLiteKit"]
        ),
        .testTarget(
            name: "SwiftSQLiteBashTests",
            dependencies: [
                "SwiftSQLiteBash",
                "SwiftSQLiteKit",
                .product(name: "BashCommandKit", package: "swiftbash"),
                .product(name: "BashInterpreter", package: "swiftbash"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
