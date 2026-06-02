#!/usr/bin/env bash
#
# fetch-sqlite.sh — download, verify, and stage the SQLite amalgamation
# for the CSQLite target.
#
# The amalgamation (sqlite3.c + sqlite3.h, ~9 MB of generated C) is NOT
# committed to the repo — it is fetched and SHA3-256-pinned here, the same
# way SwiftBash's scripts/fetch-bun-webkit.sh stages its prebuilt blob.
# CI must run this once before `swift build` / `swift test`.
#
# Pin lives in Sources/CSQLite/VERSION. Override the network for testing
# with SQLITE_MIRROR_URL=<base url ending in />.
#
# Flags:
#   --force          re-download even if sqlite3.c is already present
#   --update-hash    after a verified download, write the computed hash
#                    back into VERSION (use only on a trusted first fetch)
#
# Env:
#   SQLITE_ALLOW_UNPINNED=1   proceed even though VERSION holds the
#                             placeholder hash (NEVER set this in CI)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CSQLITE_DIR="${REPO_ROOT}/Sources/CSQLite"
VERSION_FILE="${CSQLITE_DIR}/VERSION"

FORCE=0
UPDATE_HASH=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --update-hash) UPDATE_HASH=1 ;;
        *) echo "fetch-sqlite.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "fetch-sqlite.sh: missing $VERSION_FILE" >&2
    exit 1
fi

# Pull KEY=VALUE pins out of VERSION (ignoring comment lines).
get_pin() { grep -E "^$1=" "$VERSION_FILE" | head -n1 | cut -d= -f2-; }
SQLITE_AMALGAMATION="$(get_pin SQLITE_AMALGAMATION)"
SQLITE_YEAR="$(get_pin SQLITE_YEAR)"
SQLITE_SHA3_256="$(get_pin SQLITE_SHA3_256)"
PLACEHOLDER="REPLACE_WITH_OFFICIAL_SHA3_256_FROM_SQLITE_ORG"

if [[ -z "$SQLITE_AMALGAMATION" || -z "$SQLITE_YEAR" ]]; then
    echo "fetch-sqlite.sh: VERSION is missing SQLITE_AMALGAMATION / SQLITE_YEAR" >&2
    exit 1
fi

DEST_C="${CSQLITE_DIR}/sqlite3.c"
DEST_H="${CSQLITE_DIR}/include/sqlite3.h"

if [[ -f "$DEST_C" && -f "$DEST_H" && "$FORCE" -ne 1 ]]; then
    echo "fetch-sqlite.sh: amalgamation already present (use --force to refresh)."
    exit 0
fi

# Fail closed unless the maintainer has pinned a real hash.
if [[ "$SQLITE_SHA3_256" == "$PLACEHOLDER" && "${SQLITE_ALLOW_UNPINNED:-0}" != "1" && "$UPDATE_HASH" -ne 1 ]]; then
    cat >&2 <<EOF
fetch-sqlite.sh: refusing to fetch — SHA3-256 is unpinned.

  Copy the official SHA3-256 for ${SQLITE_AMALGAMATION}.zip from the
  "Source Code" table at https://www.sqlite.org/download.html into
  Sources/CSQLite/VERSION (field SQLITE_SHA3_256), then re-run.

  First-time bootstrap from a trusted machine:
      scripts/fetch-sqlite.sh --update-hash
  Escape hatch (NOT for CI):
      SQLITE_ALLOW_UNPINNED=1 scripts/fetch-sqlite.sh
EOF
    exit 1
fi

BASE_URL="${SQLITE_MIRROR_URL:-https://www.sqlite.org/${SQLITE_YEAR}/}"
ZIP_URL="${BASE_URL}${SQLITE_AMALGAMATION}.zip"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ZIP_PATH="${TMP_DIR}/${SQLITE_AMALGAMATION}.zip"

echo "fetch-sqlite.sh: downloading ${ZIP_URL}"
if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 4 --retry-delay 2 -o "$ZIP_PATH" "$ZIP_URL"
elif command -v wget >/dev/null 2>&1; then
    wget --tries=5 -O "$ZIP_PATH" "$ZIP_URL"
else
    echo "fetch-sqlite.sh: neither curl nor wget is available" >&2
    exit 1
fi

# --- integrity check (SHA3-256, matching sqlite.org's published digest) ---
compute_sha3_256() {
    if command -v openssl >/dev/null 2>&1 && openssl dgst -sha3-256 </dev/null >/dev/null 2>&1; then
        openssl dgst -sha3-256 "$1" | awk '{print $NF}'
    else
        echo ""   # signal "no SHA3 tool available"
    fi
}

ACTUAL_SHA3="$(compute_sha3_256 "$ZIP_PATH")"

if [[ "$UPDATE_HASH" -eq 1 ]]; then
    if [[ -z "$ACTUAL_SHA3" ]]; then
        echo "fetch-sqlite.sh: --update-hash needs openssl with SHA3-256 support" >&2
        exit 1
    fi
    echo "fetch-sqlite.sh: writing pinned hash ${ACTUAL_SHA3} into VERSION"
    tmp_version="$(mktemp)"
    sed "s|^SQLITE_SHA3_256=.*|SQLITE_SHA3_256=${ACTUAL_SHA3}|" "$VERSION_FILE" > "$tmp_version"
    mv "$tmp_version" "$VERSION_FILE"
    SQLITE_SHA3_256="$ACTUAL_SHA3"
elif [[ "$SQLITE_SHA3_256" != "$PLACEHOLDER" ]]; then
    if [[ -z "$ACTUAL_SHA3" ]]; then
        echo "fetch-sqlite.sh: cannot verify — no SHA3-256 tool (install openssl)" >&2
        exit 1
    fi
    if [[ "$ACTUAL_SHA3" != "$SQLITE_SHA3_256" ]]; then
        echo "fetch-sqlite.sh: SHA3-256 MISMATCH" >&2
        echo "  expected ${SQLITE_SHA3_256}" >&2
        echo "  actual   ${ACTUAL_SHA3}" >&2
        exit 1
    fi
    echo "fetch-sqlite.sh: SHA3-256 verified."
else
    echo "fetch-sqlite.sh: WARNING — unpinned download (SQLITE_ALLOW_UNPINNED)." >&2
fi

# --- unpack + stage ---
echo "fetch-sqlite.sh: unpacking"
if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$ZIP_PATH" -d "$TMP_DIR"
else
    echo "fetch-sqlite.sh: unzip is not available" >&2
    exit 1
fi

SRC_DIR="${TMP_DIR}/${SQLITE_AMALGAMATION}"
if [[ ! -f "${SRC_DIR}/sqlite3.c" || ! -f "${SRC_DIR}/sqlite3.h" ]]; then
    echo "fetch-sqlite.sh: archive did not contain sqlite3.c / sqlite3.h" >&2
    exit 1
fi

mkdir -p "${CSQLITE_DIR}/include"
cp "${SRC_DIR}/sqlite3.c" "$DEST_C"
cp "${SRC_DIR}/sqlite3.h" "$DEST_H"

echo "fetch-sqlite.sh: staged"
echo "  $DEST_C"
echo "  $DEST_H"
echo "fetch-sqlite.sh: done."
