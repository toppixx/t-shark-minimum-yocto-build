#!/bin/sh
# uninstall-termshark.sh — remove tshark + dumpcap + termshark from a target
#
# Runs ON THE TARGET device. POSIX sh — works under busybox ash.
# Reverses what setup-termshark.sh did: removes the three binaries from
# PREFIX/bin and the PATH snippet from /etc/profile.d.
#
# Usage:
#   ./uninstall-termshark.sh                 # remove from /usr/local/bin
#   ./uninstall-termshark.sh --prefix /usr   # remove from /usr/bin
#   ./uninstall-termshark.sh --help
#
# IMPORTANT: pass the SAME --prefix you used with setup-termshark.sh.
set -eu

PREFIX=/usr/local

usage() {
    cat << EOF
Usage: $0 [--prefix DIR]

  --prefix DIR   Install prefix used at setup time; binaries are removed from
                 DIR/bin (default: /usr/local)
  -h, --help     Show this help

Removes: tshark, dumpcap, termshark  and the /etc/profile.d/termshark.sh PATH snippet.
Must be run as root.
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
PROFILE_SNIPPET=/etc/profile.d/termshark.sh

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
# Require write access to the install directory rather than hard-requiring root.
if [ -d "$BINDIR" ] && [ ! -w "$BINDIR" ]; then
    echo "ERROR: cannot write to $BINDIR." >&2
    if [ "$(id -u)" -ne 0 ]; then
        echo "  Re-run as root:  sudo $0 $*" >&2
    fi
    exit 1
fi

echo ">>> Removing tshark + dumpcap + termshark from $BINDIR"

removed=0
for b in $BINARIES; do
    if [ -f "$BINDIR/$b" ]; then
        rm -f "$BINDIR/$b"
        echo "    removed $BINDIR/$b"
        removed=$((removed + 1))
    else
        echo "    not present: $BINDIR/$b"
    fi
done

# ---------------------------------------------------------------------------
# Remove PATH snippet (only the one we created)
# ---------------------------------------------------------------------------
if [ -f "$PROFILE_SNIPPET" ]; then
    rm -f "$PROFILE_SNIPPET"
    echo "    removed $PROFILE_SNIPPET"
fi

echo ""
if [ "$removed" -eq 0 ]; then
    echo "Nothing was installed in $BINDIR — did you use a different --prefix?"
else
    echo "Uninstalled $removed binarie(s) from $BINDIR."
    echo "If you exported PATH manually in your shell, that change is not undone."
fi
