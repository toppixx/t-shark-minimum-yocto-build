#!/bin/sh
# setup-termshark.sh — install tshark + dumpcap + termshark on an aarch64 target
#
# Runs ON THE TARGET device (not the build host). POSIX sh — works under
# busybox ash on a bare-minimal Yocto rootfs; no bash features used.
#
# It copies the three binaries (which sit next to this script in the extracted
# package) into a directory on PATH, sets permissions, grants dumpcap capture
# capabilities if possible, and ensures the install directory is on PATH.
#
# Usage:
#   ./setup-termshark.sh                 # install to /usr/local/bin
#   ./setup-termshark.sh --prefix /usr   # install to /usr/bin
#   ./setup-termshark.sh --help
set -eu

PREFIX=/usr/local

usage() {
    cat << EOF
Usage: $0 [--prefix DIR]

  --prefix DIR   Install prefix; binaries go to DIR/bin (default: /usr/local)
                 e.g. --prefix /usr  installs to /usr/bin
  -h, --help     Show this help

Installs: tshark, dumpcap, termshark
Must be run as root (writes to system directories).
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)   PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

BINDIR="$PREFIX/bin"
BINARIES="tshark dumpcap termshark"

# Directory this script lives in — the extracted package, where the binaries are
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
# Require write access to the install directory rather than hard-requiring
# root — this also supports rootless installs (e.g. --prefix "$HOME/.local").
mkdir -p "$BINDIR" 2>/dev/null || true
if [ ! -d "$BINDIR" ] || [ ! -w "$BINDIR" ]; then
    echo "ERROR: cannot write to $BINDIR." >&2
    if [ "$(id -u)" -ne 0 ]; then
        echo "  Re-run as root:  sudo $0 $*" >&2
    fi
    exit 1
fi

for b in $BINARIES; do
    if [ ! -f "$SCRIPT_DIR/$b" ]; then
        echo "ERROR: '$b' not found next to this script ($SCRIPT_DIR)." >&2
        echo "  Run setup-termshark.sh from inside the extracted package." >&2
        exit 1
    fi
done

echo ">>> Installing tshark + dumpcap + termshark to $BINDIR"

# ---------------------------------------------------------------------------
# Install binaries (cp + chmod — avoids depending on coreutils 'install')
# ---------------------------------------------------------------------------
mkdir -p "$BINDIR"
for b in $BINARIES; do
    cp "$SCRIPT_DIR/$b" "$BINDIR/$b"
    chmod 0755 "$BINDIR/$b"
    echo "    installed $BINDIR/$b"
done

# ---------------------------------------------------------------------------
# Grant dumpcap capture capabilities (best effort) so non-root users can
# capture. If setcap is unavailable, live capture still works as root.
# ---------------------------------------------------------------------------
if command -v setcap >/dev/null 2>&1; then
    if setcap cap_net_raw,cap_net_admin+eip "$BINDIR/dumpcap" 2>/dev/null; then
        echo "    granted CAP_NET_RAW + CAP_NET_ADMIN to dumpcap (non-root capture enabled)"
    else
        echo "    WARN: setcap failed — run termshark as root for live capture"
    fi
else
    echo "    NOTE: setcap not found — run termshark as root for live capture"
fi

# ---------------------------------------------------------------------------
# Ensure BINDIR is on PATH
# ---------------------------------------------------------------------------
case ":$PATH:" in
    *":$BINDIR:"*)
        echo "    $BINDIR is already on PATH"
        ;;
    *)
        if [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
            printf 'export PATH="$PATH:%s"\n' "$BINDIR" > /etc/profile.d/termshark.sh
            chmod 0644 /etc/profile.d/termshark.sh
            echo "    added $BINDIR to PATH via /etc/profile.d/termshark.sh (effective next login)"
            echo "    for the current shell run:  export PATH=\"\$PATH:$BINDIR\""
        else
            echo "    WARN: $BINDIR is not on PATH (cannot write /etc/profile.d)."
            echo "          Add manually:  export PATH=\"\$PATH:$BINDIR\""
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo ">>> Verify"
if "$BINDIR/termshark" --version 2>/dev/null | head -1; then
    :
else
    echo "    WARN: could not run termshark --version (check architecture)"
fi
"$BINDIR/tshark" --version 2>/dev/null | head -1 || true

echo ""
echo "================================================================"
echo "  Installed to $BINDIR"
echo "  Run:  termshark -i eth0          # live TUI capture"
echo "        termshark -r capture.pcap  # offline analysis"
echo "  Uninstall:  ./uninstall-termshark.sh --prefix $PREFIX"
echo "================================================================"
