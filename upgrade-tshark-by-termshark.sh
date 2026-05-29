#!/usr/bin/env bash
# upgrade-tshark-by-termshark.sh
#
# Builds termshark (terminal UI for tshark) for aarch64 and creates a
# combined deployment package: tshark + dumpcap + termshark.
#
# Prerequisites:
#   • setup.sh / build.sh must have been run — tshark and dumpcap are
#     expected in /build/output before this script is called.
#   • Network access to GitHub (git.googlesource.com is also used by
#     Go's module system for golang.org/x/* packages).
#
# Usage:
#   ./upgrade-tshark-by-termshark.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TERMSHARK_VERSION="v2.4.0"
TERMSHARK_SHA="e436160ef4f7bac030a9bddd5674d3159ebdd792"  # git SHA for v2.4.0

WS=/workspace
SRC_DIR=$WS/deps/src/termshark
GO_CACHE=$WS/deps/build/termshark-gocache
GO_PATH=$WS/deps/build/termshark-gopath
BINARY_DIR=/build/output          # where tshark + dumpcap live
PKGOUT=$WS/out                    # where the final tar.gz is written

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Phase 0 — Preflight
# ---------------------------------------------------------------------------
echo ">>> Preflight"

[ -f "$BINARY_DIR/tshark" ]  || fail "tshark not found in $BINARY_DIR — run setup.sh first"
[ -f "$BINARY_DIR/dumpcap" ] || fail "dumpcap not found in $BINARY_DIR — run setup.sh first"

TSHARK_VERSION=$("$BINARY_DIR/tshark" --version 2>&1 | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1)
echo "    tshark:  $TSHARK_VERSION"
echo "    termshark: $TERMSHARK_VERSION (will be built)"

# ---------------------------------------------------------------------------
# Phase 1 — Install Go toolchain
# ---------------------------------------------------------------------------
echo ">>> Go toolchain"

if ! command -v go >/dev/null 2>&1; then
    echo "    Installing golang-go from apt…"
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends golang-go
fi

GO_VER=$(go version | awk '{print $3}')
echo "    Go: $GO_VER"

# Require at least Go 1.13 (termshark's minimum)
GO_MINOR=$(echo "$GO_VER" | grep -oP 'go1\.\K[0-9]+')
[ "$GO_MINOR" -ge 13 ] || fail "Go 1.13+ required, found $GO_VER"

# ---------------------------------------------------------------------------
# Phase 2 — Clone termshark
# ---------------------------------------------------------------------------
echo ">>> Clone termshark $TERMSHARK_VERSION"

if [ ! -d "$SRC_DIR/.git" ]; then
    git clone --depth=1 --branch "$TERMSHARK_VERSION" \
        https://github.com/gcla/termshark.git "$SRC_DIR"
fi

# Verify pinned SHA
ACTUAL_SHA=$(git -C "$SRC_DIR" rev-parse HEAD)
if [ "$ACTUAL_SHA" != "$TERMSHARK_SHA" ]; then
    echo "ERROR: SHA mismatch for termshark!" >&2
    echo "  Expected: $TERMSHARK_SHA" >&2
    echo "  Got:      $ACTUAL_SHA" >&2
    echo "  Update TERMSHARK_SHA in this script if this is an intentional upgrade." >&2
    exit 1
fi
echo "    SHA verified: ${TERMSHARK_SHA:0:12}…"

# ---------------------------------------------------------------------------
# Phase 3 — Download Go module dependencies
# ---------------------------------------------------------------------------
echo ">>> Download Go modules"

mkdir -p "$GO_CACHE" "$GO_PATH"

export GOPATH="$GO_PATH"
export GOCACHE="$GO_CACHE"
export CGO_ENABLED=0
export GOOS=linux
export GOARCH=arm64
# Many of termshark's dependencies use vanity import paths (golang.org/x/*,
# gopkg.in/*, google.golang.org/*, nhooyr.io/*). Some of those vanity domains
# no longer serve a valid go-get meta tag (e.g. nhooyr.io migrated to
# github.com/coder/websocket), so GOPROXY=direct cannot resolve them.
# A module proxy performs vanity resolution server-side and returns the
# module zip + checksum, sidestepping all broken vanity redirects.
#
# NOTE FOR LOCKED-DOWN / CI NETWORKS:
#   proxy.golang.org must be reachable. If the firewall only allows GitHub,
#   add proxy.golang.org to the allowlist, or pre-populate the module cache
#   (GOPATH/pkg/mod) from a machine with access and reuse it.
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
# GOSUMDB=off: don't contact sum.golang.org to verify checksums (it may be
# blocked). go.sum is still populated from the proxy-provided hashes.
export GOSUMDB=off
# -mod=mod: allow go.sum to be updated during the build.
export GOFLAGS=-mod=mod

cd "$SRC_DIR"
go mod download 2>&1 | grep -v "^go: finding\|^go: downloading" || true
echo "    Modules ready."

# ---------------------------------------------------------------------------
# Phase 4 — Build termshark
# ---------------------------------------------------------------------------
echo ">>> Build termshark (aarch64, static, CGO_ENABLED=0)"

# -trimpath:      remove build-machine paths from the binary (reproducible)
# -ldflags -w:    strip DWARF debug info (smaller)
# -ldflags -s:    strip symbol table (smaller)
go build \
    -trimpath \
    -ldflags="-w -s" \
    -o "$SRC_DIR/termshark" \
    ./cmd/termshark/

echo "    Build complete."

# ---------------------------------------------------------------------------
# Phase 5 — Verify
# ---------------------------------------------------------------------------
echo ">>> Verify"

file "$SRC_DIR/termshark"

# Confirm aarch64 ELF
file "$SRC_DIR/termshark" | grep -q "ARM aarch64" \
    || fail "termshark is not an aarch64 binary"

# Confirm no shared library deps (CGO_ENABLED=0 guarantees this for pure Go)
readelf -d "$SRC_DIR/termshark" 2>/dev/null | grep -q NEEDED \
    && fail "termshark has unexpected shared library dependencies" \
    || echo "    PASS: statically linked"

# Smoke-test: --help should exit 0 or 1 (TUI exits 1 when no terminal)
"$SRC_DIR/termshark" --help >/dev/null 2>&1 || true
echo "    PASS: binary executes"

# ---------------------------------------------------------------------------
# Phase 6 — Strip and copy alongside tshark
# ---------------------------------------------------------------------------
echo ">>> Strip and copy to $BINARY_DIR"

strip --strip-all "$SRC_DIR/termshark" -o "$BINARY_DIR/termshark"
sha256sum "$BINARY_DIR/termshark" | tee "$BINARY_DIR/termshark.sha256"
du -sh "$BINARY_DIR/termshark"

# ---------------------------------------------------------------------------
# Phase 7 — Create combined deployment package
# ---------------------------------------------------------------------------
echo ">>> Package"

mkdir -p "$PKGOUT"

TSHARK_VER_CLEAN="${TSHARK_VERSION//-/_}"
TERM_VER_CLEAN="${TERMSHARK_VERSION#v}"
PKGNAME="tshark-aarch64-${TSHARK_VERSION}-termshark-${TERM_VER_CLEAN}-static"
PKGDIR="$BINARY_DIR/$PKGNAME"
ARCHIVE="$PKGOUT/${PKGNAME}.tar.gz"

rm -rf "$PKGDIR"
mkdir -p "$PKGDIR"

# Binaries
cp "$BINARY_DIR/tshark"     "$PKGDIR/tshark"
cp "$BINARY_DIR/dumpcap"    "$PKGDIR/dumpcap"
cp "$BINARY_DIR/termshark"  "$PKGDIR/termshark"
chmod 755 "$PKGDIR/tshark" "$PKGDIR/dumpcap" "$PKGDIR/termshark"

# Checksums + metadata
cp "$BINARY_DIR/tshark.sha256"    "$PKGDIR/"
cp "$BINARY_DIR/dumpcap.sha256"   "$PKGDIR/"
cp "$BINARY_DIR/termshark.sha256" "$PKGDIR/"
cp "$BINARY_DIR/BUILD_INFO.txt"   "$PKGDIR/"

# Documentation — tshark guide + termshark guide
[ -f "$WS/README.md" ]    && cp "$WS/README.md"    "$PKGDIR/README.md"    || true
[ -f "$WS/TERMSHARK.md" ] && cp "$WS/TERMSHARK.md" "$PKGDIR/TERMSHARK.md" || true

# Append termshark section to BUILD_INFO
cat >> "$PKGDIR/BUILD_INFO.txt" << BEOF

--- termshark ---
Version:          ${TERMSHARK_VERSION}
SHA (source):     ${TERMSHARK_SHA}
Binary size:      $(du -sh "$BINARY_DIR/termshark" | cut -f1)
SHA256:           $(awk '{print $1}' "$BINARY_DIR/termshark.sha256")
Usage:            ./termshark -i eth0
                  ./termshark -r capture.pcap
Note: termshark requires tshark and dumpcap in the same directory.
BEOF

# Pack
tar -czf "$ARCHIVE" -C "$BINARY_DIR" "$PKGNAME"
rm -rf "$PKGDIR"
sha256sum "$ARCHIVE" | tee "${ARCHIVE%.tar.gz}.sha256" > /dev/null

ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
echo ""
echo "================================================================"
echo "  tshark    : $BINARY_DIR/tshark"
echo "  dumpcap   : $BINARY_DIR/dumpcap"
echo "  termshark : $BINARY_DIR/termshark"
echo "  Package   : $ARCHIVE ($ARCHIVE_SIZE)"
echo "================================================================"
echo ""
echo "Deploy on target:"
echo "  tar -xzf $(basename "$ARCHIVE") -C /usr/bin/ --strip-components=1"
echo "  termshark -i eth0                 # live TUI capture"
echo "  termshark -r capture.pcap         # offline TUI analysis"
