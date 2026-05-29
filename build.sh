#!/usr/bin/env bash
# build.sh — Configure and build TShark from an already-prepared workspace.
#
# Prerequisite: setup.sh has been run at least once (all static deps built,
# Wireshark source cloned, EtherCAT sources integrated).
#
# Usage:
#   ./build.sh              # incremental build (reuses existing CMake cache)
#   ./build.sh --clean      # wipe CMake build dir, reconfigure, full rebuild
#   ./build.sh --jobs N     # override parallel job count (default: nproc)
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CLEAN=0
JOBS=$(nproc)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)   CLEAN=1 ; shift ;;
        --jobs)    JOBS="$2" ; shift 2 ;;
        -j)        JOBS="$2" ; shift 2 ;;
        -j*)       JOBS="${1#-j}" ; shift ;;
        --help|-h)
            echo "Usage: $0 [--clean] [--jobs N]"
            echo "  --clean    Wipe the CMake build directory and reconfigure"
            echo "  --jobs N   Number of parallel compile jobs (default: nproc)"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2 ; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Paths (must match setup.sh)
# ---------------------------------------------------------------------------
WS=/workspace
DEPINST=$WS/deps/install
OUTPUT=/build/output
BUILD_DIR=$WS/build
CACHE_FILE=$WS/toolchain/wireshark-cache.cmake
ENV_FILE=$WS/toolchain/env.sh
WIRESHARK_VERSION="v4.2.14"

fail() { echo "ERROR: $*" >&2 ; exit 1; }

# ---------------------------------------------------------------------------
# package_output <binary_dir> <version> <pkg_dest>  (shared with setup.sh)
# ---------------------------------------------------------------------------
package_output() {
    local outdir="$1" version="$2" pkg_dest="${3:-$1}"
    local pkgname="tshark-aarch64-${version}-static"
    local pkgdir="${outdir}/${pkgname}"
    local archive="${pkg_dest}/${pkgname}.tar.gz"
    mkdir -p "$pkg_dest"

    echo ">>> Creating deployment package: $(basename "$archive")"
    rm -rf "$pkgdir"
    mkdir -p "$pkgdir"

    cp "$outdir/tshark"   "$pkgdir/tshark"
    cp "$outdir/dumpcap"  "$pkgdir/dumpcap"
    chmod 755 "$pkgdir/tshark" "$pkgdir/dumpcap"
    cp "$outdir/tshark.sha256"   "$pkgdir/"
    cp "$outdir/dumpcap.sha256"  "$pkgdir/"
    cp "$outdir/BUILD_INFO.txt"  "$pkgdir/"

    # Deployment guide — sourced from README.md tracked in the repo
    local readme="/workspace/README.md"
    if [ -f "$readme" ]; then
        cp "$readme" "$pkgdir/README.md"
    else
        echo "WARNING: $readme not found — package will not include README.md" >&2
    fi

    # Dependency license list (compliance — ships with the binaries)
    [ -f "/workspace/DEPENDENCY_LICENSES.md" ] && \
        cp "/workspace/DEPENDENCY_LICENSES.md" "$pkgdir/DEPENDENCY_LICENSES.md" || true

    tar -czf "$archive" -C "$outdir" "$pkgname"
    rm -rf "$pkgdir"

    local size
    size=$(du -sh "$archive" | cut -f1)
    sha256sum "$archive" | tee "${archive%.tar.gz}.sha256" > /dev/null
    echo "    Package : $archive ($size)"
    echo "    SHA256  : $(awk '{print $1}' "${archive%.tar.gz}.sha256")"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo ">>> Preflight checks"

[ -f "$ENV_FILE" ]            || fail "env.sh not found — run setup.sh first"
[ -d "$WS/wireshark" ]        || fail "Wireshark source not found — run setup.sh first"
[ -f "$DEPINST/lib/libz.a" ]  || fail "Static deps not built — run setup.sh first"

# Check EtherCAT integration
if ! grep -q "packet-ams.c" "$WS/wireshark/epan/dissectors/CMakeLists.txt"; then
    echo "WARNING: EtherCAT not integrated — re-applying patch"
    ETHERCAT_PLUGIN="$WS/wireshark/plugins/epan/ethercat"
    DISSECTORS="$WS/wireshark/epan/dissectors"
    for src in \
        packet-ams.c packet-ams.h \
        packet-ecatmb.c packet-ecatmb.h \
        packet-esl.c \
        packet-ethercat-datagram.c packet-ethercat-datagram.h \
        packet-ethercat-frame.c packet-ethercat-frame.h \
        packet-ioraw.c packet-ioraw.h \
        packet-nv.c packet-nv.h
    do
        cp "$ETHERCAT_PLUGIN/$src" "$DISSECTORS/$src"
    done
    python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("/workspace/wireshark/epan/dissectors/CMakeLists.txt")
txt = p.read_text()
marker = "set(DISSECTOR_SRC\n"
insert = (
    "set(DISSECTOR_SRC\n"
    "\t${CMAKE_CURRENT_SOURCE_DIR}/packet-ams.c\n"
    "\t${CMAKE_CURRENT_SOURCE_DIR}/packet-ecatmb.c\n"
    "\t${CMAKE_CURRENT_SOURCE_DIR}/packet-esl.c\n"
    "\t${CMAKE_CURRENT_SOURCE_DIR}/packet-ethercat-datagram.c\n"
    "\t${CMAKE_CURRENT_SOURCE_DIR}/packet-ethercat-frame.c\n"
    "\t${CMAKE_CURRENT_SOURCE_DIR}/packet-ioraw.c\n"
    "\t${CMAKE_CURRENT_SOURCE_DIR}/packet-nv.c\n"
)
if "packet-ams.c" not in txt:
    txt = txt.replace(marker, insert, 1)
    p.write_text(txt)
    print("  EtherCAT CMakeLists.txt patched")
PYEOF
fi

# Verify key static libs
REQUIRED_LIBS=(
    libz.a libffi.a libpcre2-8.a
    libglib-2.0.a libcombined-deps.a
    libgpg-error.a libgcrypt.a
    libssl.a libcrypto.a
    libpcap.a libcares.a
    liblz4.a libzstd.a
    libbrotlidec.a libbrotlicommon.a
    libnl-3.a libnl-genl-3.a libnl-route-3.a
)
MISSING=()
for lib in "${REQUIRED_LIBS[@]}"; do
    [[ -f "$DEPINST/lib/$lib" ]] || MISSING+=("$lib")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    fail "Missing static libs: ${MISSING[*]} — run setup.sh first"
fi

# Ensure libnl static libs are in DEPINST (may be missing if setup.sh
# predates this fix — copy them on-the-fly rather than failing the build).
for lib in libnl-3 libnl-genl-3 libnl-route-3; do
    dest="$DEPINST/lib/${lib}.a"
    src="/usr/lib/aarch64-linux-gnu/${lib}.a"
    if [[ ! -f "$dest" ]]; then
        [[ -f "$src" ]] || fail "$src not found — is ${lib}-dev installed?"
        cp "$src" "$dest"
        echo "    Copied ${lib}.a to DEPINST"
    fi
done

echo "    All deps present."

# ---------------------------------------------------------------------------
# Source environment
# ---------------------------------------------------------------------------
# shellcheck source=toolchain/env.sh
source "$ENV_FILE"
GLIB_PRIV_INC=$(find "$DEPINST/lib" -name "glibconfig.h" -exec dirname {} \; | head -1)

# ---------------------------------------------------------------------------
# Regenerate CMake cache file
# (Always regenerated so paths remain correct after moves/rebuilds)
# ---------------------------------------------------------------------------
echo ">>> Generate CMake cache: $CACHE_FILE"
cat > "$CACHE_FILE" << CACHEEOF
# Auto-generated by build.sh
set(CMAKE_PREFIX_PATH "${DEPINST}" CACHE STRING "")

set(GLIB2_INTERNAL_INCLUDE_DIR "${GLIB_PRIV_INC}" CACHE PATH "")
set(GLIB2_MAIN_INCLUDE_DIR "${DEPINST}/include/glib-2.0" CACHE PATH "")
set(GLIB2_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")
set(GLIB2_VERSION "2.78.6" CACHE STRING "")
set(GLIB2_GMODULE_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")
set(GLIB2_GOBJECT_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")
set(GLIB2_GIO_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")
set(GLIB2_GTHREAD_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")

set(PCRE2_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")
set(PCRE2_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")

set(BROTLIDEC_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")
set(BROTLI_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")

set(GCRYPT_LIBRARY "${DEPINST}/lib/libgcrypt.a" CACHE FILEPATH "")
set(GCRYPT_ERROR_LIBRARY "${DEPINST}/lib/libgpg-error.a" CACHE FILEPATH "")
set(GCRYPT_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")

set(OPENSSL_ROOT_DIR "${DEPINST}" CACHE PATH "")
set(OPENSSL_USE_STATIC_LIBS TRUE CACHE BOOL "")

set(PCAP_LIBRARY "${DEPINST}/lib/libpcap.a" CACHE FILEPATH "")
set(PCAP_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")

set(CARES_LIBRARY "${DEPINST}/lib/libcares.a" CACHE FILEPATH "")
set(CARES_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")

set(LZ4_LIBRARY "${DEPINST}/lib/liblz4.a" CACHE FILEPATH "")
set(LZ4_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")
set(ZSTD_LIBRARY "${DEPINST}/lib/libzstd.a" CACHE FILEPATH "")
set(ZSTD_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")

set(ZLIB_LIBRARY "${DEPINST}/lib/libz.a" CACHE FILEPATH "")
set(ZLIB_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")
CACHEEOF

# ---------------------------------------------------------------------------
# CMake configure
# ---------------------------------------------------------------------------
if [[ $CLEAN -eq 1 ]]; then
    echo ">>> --clean: wiping $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

if [[ ! -f "$BUILD_DIR/build.ninja" ]]; then
    echo ">>> CMake configure"
    cmake -G Ninja \
        -B "$BUILD_DIR" \
        -S "$WS/wireshark" \
        -C "$CACHE_FILE" \
        \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install" \
        \
        -DBUILD_wireshark=OFF \
        -DBUILD_tshark=ON \
        -DBUILD_rawshark=OFF \
        -DBUILD_dumpcap=ON \
        -DBUILD_editcap=OFF \
        -DBUILD_mergecap=OFF \
        -DBUILD_reordercap=OFF \
        -DBUILD_text2pcap=OFF \
        -DBUILD_capinfos=OFF \
        -DBUILD_captype=OFF \
        -DBUILD_dftest=OFF \
        -DBUILD_randpkt=OFF \
        -DBUILD_sharkd=OFF \
        \
        -DENABLE_STATIC=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_PLUGINS=OFF \
        \
        -DENABLE_PCAP=ON \
        -DENABLE_GCRYPT=ON \
        -DENABLE_GNUTLS=OFF \
        -DENABLE_OPENSSL=ON \
        -DENABLE_CARES=ON \
        -DENABLE_LZ4=ON \
        -DENABLE_ZSTD=ON \
        -DENABLE_BROTLI=ON \
        -DENABLE_LUA=OFF \
        -DENABLE_SMI=OFF \
        -DENABLE_LIBXML2=OFF \
        -DENABLE_KERBEROS=OFF \
        -DENABLE_MAXMINDDB=OFF \
        -DENABLE_SBC=OFF \
        -DENABLE_SPANDSP=OFF \
        -DENABLE_AIRPCAP=OFF \
        -DENABLE_SNAPPY=OFF \
        \
        "-DGLIB2_INTERNAL_INCLUDE_DIR=${GLIB_PRIV_INC}" \
        "-DGLIB2_MAIN_INCLUDE_DIR=${DEPINST}/include/glib-2.0" \
        "-DGLIB2_LIBRARY=${DEPINST}/lib/libcombined-deps.a" \
        "-DBROTLIDEC_LIBRARY=${DEPINST}/lib/libcombined-deps.a" \
        "-DCMAKE_C_FLAGS=-I${DEPINST}/include -I${DEPINST}/include/glib-2.0 -I${GLIB_PRIV_INC}" \
        "-DCMAKE_CXX_FLAGS=-I${DEPINST}/include -I${DEPINST}/include/glib-2.0 -I${GLIB_PRIV_INC}" \
        "-DCMAKE_EXE_LINKER_FLAGS=-static -L${DEPINST}/lib"
else
    echo ">>> CMake already configured — skipping (use --clean to reconfigure)"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
echo ">>> Build tshark + dumpcap  (jobs: $JOBS)"
BUILD_START=$(date +%s)
cmake --build "$BUILD_DIR" --target tshark --target dumpcap -j"$JOBS"
BUILD_END=$(date +%s)
echo "    Build time: $((BUILD_END - BUILD_START))s"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo ">>> Verify"
TSHARK_BIN=$(find "$BUILD_DIR"  -name tshark   -type f | head -1)
DUMPCAP_BIN=$(find "$BUILD_DIR" -name dumpcap  -type f | head -1)

[ -n "$TSHARK_BIN" ]  || fail "tshark binary not found after build"
[ -n "$DUMPCAP_BIN" ] || fail "dumpcap binary not found after build"

# tshark finds dumpcap via /proc/self/exe — both binaries must be co-located.
TSHARK_DIR=$(dirname "$TSHARK_BIN")
DUMPCAP_DIR=$(dirname "$DUMPCAP_BIN")
[ "$TSHARK_DIR" = "$DUMPCAP_DIR" ] \
    || fail "tshark ($TSHARK_DIR) and dumpcap ($DUMPCAP_DIR) are in different directories — they must be co-located"

file "$TSHARK_BIN"

readelf -d "$TSHARK_BIN" | grep -q NEEDED \
    && fail "binary has shared library dependencies — not fully static" \
    || echo "    PASS: statically linked"

# grep without -q reads all nm output before exiting, preventing SIGPIPE on nm.
# With set -euo pipefail, SIGPIPE causes nm to exit 141 which pipefail
# returns as the pipeline exit code — a false failure even when the symbol exists.
nm "$TSHARK_BIN" 2>/dev/null | grep "proto_register_ecat" > /dev/null \
    && echo "    PASS: EtherCAT dissector symbols present" \
    || fail "EtherCAT symbols missing from binary"

"$TSHARK_BIN" --version 2>&1 | head -1
echo "    PASS: dumpcap at $DUMPCAP_BIN"

# ---------------------------------------------------------------------------
# Copy to output
# ---------------------------------------------------------------------------
echo ">>> Strip and copy to $OUTPUT"
mkdir -p "$OUTPUT"
strip --strip-all "$TSHARK_BIN"  -o "$OUTPUT/tshark"
strip --strip-all "$DUMPCAP_BIN" -o "$OUTPUT/dumpcap"
sha256sum "$OUTPUT/tshark"   | tee "$OUTPUT/tshark.sha256"
sha256sum "$OUTPUT/dumpcap"  | tee "$OUTPUT/dumpcap.sha256"
du -sh "$OUTPUT/tshark" "$OUTPUT/dumpcap"

package_output "$OUTPUT" "$WIRESHARK_VERSION" "$WS/out"

echo ""
echo "================================================================"
echo "  $OUTPUT/tshark   $(du -sh "$OUTPUT/tshark"   | cut -f1)"
echo "  $OUTPUT/dumpcap  $(du -sh "$OUTPUT/dumpcap"  | cut -f1)"
echo "  Package: $WS/out/tshark-aarch64-${WIRESHARK_VERSION}-static.tar.gz"
echo "  aarch64   statically linked   EtherCAT built-in"
echo "================================================================"
