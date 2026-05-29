#!/usr/bin/env bash
# setup.sh — Build TShark 4.2.x (static, aarch64) with EtherCAT dissector support
# Tested inside the tshark-builder devcontainer (debian:bookworm, aarch64 host).
# Network access limited to GitHub IP ranges.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WIRESHARK_VERSION="v4.2.14"   # latest v4.2.x tag at time of writing

WS=/workspace                  # workspace root
DEPINST=$WS/deps/install       # where all static dep libs/headers go
OUTPUT=/build/output            # final artefact destination

MESON="python3 $WS/toolchain/meson/meson.py"

# ---------------------------------------------------------------------------
# Phase 0 — Prerequisites & Directory Layout
# ---------------------------------------------------------------------------
echo ">>> Phase 0: prerequisites"

sudo apt-get update -qq
sudo apt-get install -y \
    gcc g++ binutils \
    binutils-aarch64-linux-gnu \
    cmake ninja-build \
    python3 git perl \
    flex bison \
    pkg-config \
    m4 autoconf automake libtool gettext \
    musl musl-dev musl-tools \
    libnl-3-dev libnl-genl-3-dev 2>&1 | grep -E "^(Get:|Setting up|E:)" || true

mkdir -p \
    "$WS/deps/src" \
    "$WS/deps/build" \
    "$DEPINST/lib/pkgconfig" \
    "$DEPINST/include" \
    "$WS/toolchain" \
    "$OUTPUT"

# ---------------------------------------------------------------------------
# Phase 0 — Clone meson (needed for glib2; no PyPI access in this network)
# ---------------------------------------------------------------------------
echo ">>> Clone meson"
if [ ! -d "$WS/toolchain/meson/.git" ]; then
    git clone --depth=1 https://github.com/mesonbuild/meson.git \
        "$WS/toolchain/meson"
fi
python3 "$WS/toolchain/meson/meson.py" --version

# ---------------------------------------------------------------------------
# Phase 0 — env.sh (compiler environment for dep builds; no -static here,
#           that flag is only passed at the final tshark link stage)
# ---------------------------------------------------------------------------
cat > "$WS/toolchain/env.sh" << 'ENVEOF'
export DEPINST=/workspace/deps/install
export CC=gcc
export CXX=g++
export AR=ar
export RANLIB=ranlib
export STRIP=strip
export NM=nm
export CFLAGS="-O2 -pipe"
export CXXFLAGS="-O2 -pipe"
export LDFLAGS="-L${DEPINST}/lib"
export CPPFLAGS="-I${DEPINST}/include"
export PKG_CONFIG_LIBDIR="${DEPINST}/lib/pkgconfig"
export PKG_CONFIG_PATH="${DEPINST}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""
export MESON="python3 /workspace/toolchain/meson/meson.py"
ENVEOF
# shellcheck source=toolchain/env.sh
source "$WS/toolchain/env.sh"

# ---------------------------------------------------------------------------
# H-3: Pinned dependency commit SHAs.
# Every dependency is locked to the exact commit used in the verified build.
# If a clone's HEAD does not match the pinned SHA, setup aborts — this
# catches upstream tag rewrites or unexpected branch changes.
# To upgrade a dependency: change the branch/tag AND update the SHA here.
# ---------------------------------------------------------------------------
declare -A DEP_SHAS=(
    [zlib]="f9dd6009be3ed32415edf1e89d1bc38380ecb95d"
    [libffi]="c5abbdad2f930f806791942776ccd45beeff1613"
    [pcre2]="ff92e0b9cea5b5ae3af12ba930d03556684f098b"
    [glib]="d40f72e98e4734ba826ba9a278814530720ba760"
    [libgpg-error]="9b108b54d1229fb1fb30eebe2f5ae958f4c93b2c"
    [libgcrypt]="92a2b41e94c1b63700b8b01ae11ccbeb0ae4a2a8"
    [openssl]="0c1194718301808d48db78355c03c6f5e884e4a3"
    [libpcap]="6b5de1e5f07a4fea6672caa2d34935c3da24a8f2"
    [c-ares]="c93e50f3ebc0373fe57677523ec960f6c1cb0e15"
    [lz4]="64e81c59de3971089c9a524db3eca174e1bbad49"
    [zstd]="5233c58e6ca0b1c4c6b353ad79649191ed195bdc"
    [brotli]="6312ee24cebbe329cee30fe12087469e3014442b"
    [wireshark]="9d81a981d05cd0d2e764871c5b4b7fcdb694182f"
    [meson]=""   # meson cloned from HEAD; no pinning (pure Python, low risk)
)

# ---------------------------------------------------------------------------
# Helper: clone a GitHub repo and verify the HEAD matches the pinned SHA
# ---------------------------------------------------------------------------
clone_if_missing() {
    local url="$1" dest="$2" branch="${3:-}"
    local name
    name=$(basename "$dest")
    local expected_sha="${DEP_SHAS[$name]:-}"

    if [ ! -d "$dest/.git" ]; then
        if [ -n "$branch" ]; then
            git clone --depth=1 --branch "$branch" "$url" "$dest"
        else
            git clone --depth=1 "$url" "$dest"
        fi
    fi

    # Verify pinned SHA when one is defined for this dependency
    if [ -n "$expected_sha" ]; then
        local actual_sha
        actual_sha=$(git -C "$dest" rev-parse HEAD)
        if [ "$actual_sha" != "$expected_sha" ]; then
            echo "ERROR: SHA mismatch for $name!" >&2
            echo "  Expected: $expected_sha" >&2
            echo "  Got:      $actual_sha" >&2
            echo "  If this is an intentional upgrade, update DEP_SHAS in setup.sh." >&2
            exit 1
        fi
        echo "    $name SHA verified: ${expected_sha:0:12}…"
    fi
}

# ---------------------------------------------------------------------------
# Phase 1 — Clone all dependency sources (in parallel)
# ---------------------------------------------------------------------------
echo ">>> Phase 1: clone dependency sources"
# M-8: Track each background PID so clone failures abort the build instead
# of being silently swallowed by plain `wait`.
CLONE_PIDS=()
clone_if_missing https://github.com/madler/zlib.git             "$WS/deps/src/zlib"     & CLONE_PIDS+=($!)
clone_if_missing https://github.com/libffi/libffi.git           "$WS/deps/src/libffi"   & CLONE_PIDS+=($!)
clone_if_missing https://github.com/PCRE2Project/pcre2.git      "$WS/deps/src/pcre2"    & CLONE_PIDS+=($!)
clone_if_missing https://github.com/GNOME/glib.git              "$WS/deps/src/glib" "2.78.6" & CLONE_PIDS+=($!)
clone_if_missing https://github.com/gpg/libgpg-error.git        "$WS/deps/src/libgpg-error" & CLONE_PIDS+=($!)
clone_if_missing https://github.com/gpg/libgcrypt.git           "$WS/deps/src/libgcrypt"    & CLONE_PIDS+=($!)
clone_if_missing https://github.com/openssl/openssl.git         "$WS/deps/src/openssl"      & CLONE_PIDS+=($!)
clone_if_missing https://github.com/the-tcpdump-group/libpcap.git "$WS/deps/src/libpcap"   & CLONE_PIDS+=($!)
clone_if_missing https://github.com/c-ares/c-ares.git           "$WS/deps/src/c-ares"       & CLONE_PIDS+=($!)
clone_if_missing https://github.com/lz4/lz4.git                 "$WS/deps/src/lz4"          & CLONE_PIDS+=($!)
clone_if_missing https://github.com/facebook/zstd.git           "$WS/deps/src/zstd"         & CLONE_PIDS+=($!)
clone_if_missing https://github.com/google/brotli.git           "$WS/deps/src/brotli"       & CLONE_PIDS+=($!)
CLONE_FAIL=0
for pid in "${CLONE_PIDS[@]}"; do
    wait "$pid" || { echo "ERROR: a clone job failed (PID $pid)" >&2; CLONE_FAIL=1; }
done
[ "$CLONE_FAIL" -eq 0 ] || exit 1
echo "All dependency sources ready."

# ---------------------------------------------------------------------------
# Phase 2 — Build static dependencies
# ---------------------------------------------------------------------------

# ---- zlib ------------------------------------------------------------------
echo ">>> Build zlib"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libz.a" ]; then
    mkdir -p "$WS/deps/build/zlib"
    cmake -G Ninja "$WS/deps/src/zlib" \
        -B "$WS/deps/build/zlib" \
        -DCMAKE_INSTALL_PREFIX="$DEPINST" \
        -DCMAKE_C_FLAGS="$CFLAGS" \
        -DBUILD_SHARED_LIBS=OFF \
        -DZLIB_BUILD_EXAMPLES=OFF
    ninja -C "$WS/deps/build/zlib" zlibstatic
    cmake --install "$WS/deps/build/zlib" --component Development
fi
echo "    libz.a: OK"

# ---- libffi ----------------------------------------------------------------
echo ">>> Build libffi"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libffi.a" ]; then
    cd "$WS/deps/src/libffi"
    autoreconf -fiv
    ./configure \
        --prefix="$DEPINST" \
        --enable-static --disable-shared \
        --disable-docs \
        CC="$CC" CFLAGS="$CFLAGS" AR="$AR" RANLIB="$RANLIB"
    make -j"$(nproc)"
    make install
fi
echo "    libffi.a: OK"

# ---- pcre2 -----------------------------------------------------------------
echo ">>> Build pcre2"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libpcre2-8.a" ]; then
    mkdir -p "$WS/deps/build/pcre2"
    cmake -G Ninja "$WS/deps/src/pcre2" \
        -B "$WS/deps/build/pcre2" \
        -DCMAKE_INSTALL_PREFIX="$DEPINST" \
        -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
        -DBUILD_SHARED_LIBS=OFF \
        -DPCRE2_BUILD_PCRE2_8=ON \
        -DPCRE2_BUILD_PCRE2_16=OFF \
        -DPCRE2_BUILD_PCRE2_32=OFF \
        -DPCRE2_SUPPORT_UNICODE=ON \
        -DPCRE2_BUILD_TESTS=OFF \
        -DPCRE2_BUILD_PCRE2GREP=OFF
    ninja -C "$WS/deps/build/pcre2"
    ninja -C "$WS/deps/build/pcre2" install
fi
echo "    libpcre2-8.a: OK"

# ---- glib2 -----------------------------------------------------------------
echo ">>> Build glib2"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libglib-2.0.a" ]; then
    $MESON setup "$WS/deps/build/glib" \
        "$WS/deps/src/glib" \
        --prefix="$DEPINST" \
        --default-library=static \
        --auto-features=disabled \
        --buildtype=release \
        -Dtests=false \
        -Dinstalled_tests=false \
        -Dgtk_doc=false \
        -Dglib_assert=false \
        -Dglib_checks=false
    ninja -C "$WS/deps/build/glib" -j"$(nproc)"
    ninja -C "$WS/deps/build/glib" install

    # glib installs to lib/aarch64-linux-gnu/ on Debian multiarch systems;
    # copy to lib/ so pkg-config and cmake searches work without special paths.
    MULTIARCH="$DEPINST/lib/aarch64-linux-gnu"
    if [ -d "$MULTIARCH" ]; then
        cp "$MULTIARCH"/*.a "$DEPINST/lib/" 2>/dev/null || true
        find "$MULTIARCH/pkgconfig/" -name "*.pc" \
            -exec cp {} "$DEPINST/lib/pkgconfig/" \; 2>/dev/null || true
        # Fix libdir in copied .pc files
        sed -i "s|lib/aarch64-linux-gnu|lib|g" "$DEPINST/lib/pkgconfig"/*.pc 2>/dev/null || true
    fi
fi
echo "    libglib-2.0.a: OK"

# Update env.sh with glibconfig.h private include path
_glib_hits=$(find "$DEPINST/lib" -name "glibconfig.h" -exec dirname {} \; )
[ -n "$_glib_hits" ] || { echo "ERROR: glibconfig.h not found under $DEPINST/lib" >&2; exit 1; }
[ "$(echo "$_glib_hits" | wc -l)" -eq 1 ] || { echo "ERROR: multiple glibconfig.h found — ambiguous: $_glib_hits" >&2; exit 1; }
GLIB_PRIV_INC="$_glib_hits"
cat > "$WS/toolchain/env.sh" << ENVEOF
export DEPINST=/workspace/deps/install
export CC=gcc
export CXX=g++
export AR=ar
export RANLIB=ranlib
export STRIP=strip
export NM=nm
export CFLAGS="-O2 -pipe"
export CXXFLAGS="-O2 -pipe"
export LDFLAGS="-L\${DEPINST}/lib"
export CPPFLAGS="-I\${DEPINST}/include -I${GLIB_PRIV_INC}"
export PKG_CONFIG_LIBDIR="\${DEPINST}/lib/pkgconfig"
export PKG_CONFIG_PATH="\${DEPINST}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""
export MESON="python3 /workspace/toolchain/meson/meson.py"
ENVEOF
source "$WS/toolchain/env.sh"

# ---- libgpg-error ----------------------------------------------------------
echo ">>> Build libgpg-error"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libgpg-error.a" ]; then
    cd "$WS/deps/src/libgpg-error"
    ./autogen.sh
    ./configure \
        --prefix="$DEPINST" \
        --enable-static --disable-shared \
        --disable-nls \
        --disable-languages \
        --disable-tests \
        CC="$CC" CFLAGS="$CFLAGS" AR="$AR" RANLIB="$RANLIB"
    # M-6: Build only the library subdirectories explicitly to avoid the
    # doc/ failure (missing texinfo) masking a real library build error.
    make -j"$(nproc)" -C src
    make -j"$(nproc)" -C lang
    make install -C src
    make install -C lang
    test -f "$DEPINST/lib/libgpg-error.a"
fi
echo "    libgpg-error.a: OK"

# ---- libgcrypt -------------------------------------------------------------
echo ">>> Build libgcrypt"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libgcrypt.a" ]; then
    cd "$WS/deps/src/libgcrypt"
    ./autogen.sh
    ./configure \
        --prefix="$DEPINST" \
        --enable-static --disable-shared \
        --disable-doc \
        --with-libgpg-error-prefix="$DEPINST" \
        CC="$CC" CFLAGS="$CFLAGS $CPPFLAGS" AR="$AR" RANLIB="$RANLIB" \
        LDFLAGS="$LDFLAGS"
    make -j"$(nproc)"
    make install
fi
echo "    libgcrypt.a: OK"

# ---- OpenSSL ---------------------------------------------------------------
echo ">>> Build OpenSSL"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libssl.a" ]; then
    cd "$WS/deps/src/openssl"
    # M-7: SHA is pinned via DEP_SHAS above (verified in clone_if_missing).
    # HEAD is used directly; do not checkout a different tag here to avoid
    # diverging from the verified SHA.
    ./Configure \
        linux-aarch64 \
        --prefix="$DEPINST" \
        --openssldir="$DEPINST/ssl" \
        no-shared no-tests no-docs \
        "$CFLAGS"
    make -j"$(nproc)" build_sw
    make install_sw
fi
echo "    libssl.a + libcrypto.a: OK"

# ---- libpcap (without libnl — avoids pulling in libnl for the static link) --
echo ">>> Build libpcap"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libpcap.a" ]; then
    mkdir -p "$WS/deps/build/libpcap"
    cmake -G Ninja "$WS/deps/src/libpcap" \
        -B "$WS/deps/build/libpcap" \
        -DCMAKE_INSTALL_PREFIX="$DEPINST" \
        -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_WITH_LIBNL=OFF \
        -DDISABLE_LINUX_USBMON=ON \
        -DDISABLE_RDMA=ON \
        -DDISABLE_BLUETOOTH=ON \
        -DDISABLE_DBUS=ON \
        -DDISABLE_NETMAP=ON
    ninja -C "$WS/deps/build/libpcap"
    ninja -C "$WS/deps/build/libpcap" install
fi
echo "    libpcap.a: OK"

# ---- c-ares ----------------------------------------------------------------
echo ">>> Build c-ares"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libcares.a" ]; then
    mkdir -p "$WS/deps/build/c-ares"
    cmake -G Ninja "$WS/deps/src/c-ares" \
        -B "$WS/deps/build/c-ares" \
        -DCMAKE_INSTALL_PREFIX="$DEPINST" \
        -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCARES_STATIC=ON \
        -DCARES_SHARED=OFF \
        -DCARES_BUILD_TESTS=OFF \
        -DCARES_BUILD_TOOLS=OFF
    ninja -C "$WS/deps/build/c-ares"
    ninja -C "$WS/deps/build/c-ares" install
fi
echo "    libcares.a: OK"

# ---- lz4 -------------------------------------------------------------------
echo ">>> Build lz4"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/liblz4.a" ]; then
    mkdir -p "$WS/deps/build/lz4"
    cmake -G Ninja "$WS/deps/src/lz4/build/cmake" \
        -B "$WS/deps/build/lz4" \
        -DCMAKE_INSTALL_PREFIX="$DEPINST" \
        -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
        -DBUILD_SHARED_LIBS=OFF \
        -DLZ4_BUILD_CLI=OFF \
        -DLZ4_BUILD_LEGACY_LZ4C=OFF
    ninja -C "$WS/deps/build/lz4"
    ninja -C "$WS/deps/build/lz4" install
fi
echo "    liblz4.a: OK"

# ---- zstd ------------------------------------------------------------------
echo ">>> Build zstd"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libzstd.a" ]; then
    mkdir -p "$WS/deps/build/zstd"
    cmake -G Ninja "$WS/deps/src/zstd/build/cmake" \
        -B "$WS/deps/build/zstd" \
        -DCMAKE_INSTALL_PREFIX="$DEPINST" \
        -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
        -DBUILD_SHARED_LIBS=OFF \
        -DZSTD_BUILD_STATIC=ON \
        -DZSTD_BUILD_SHARED=OFF \
        -DZSTD_BUILD_PROGRAMS=OFF \
        -DZSTD_BUILD_TESTS=OFF
    ninja -C "$WS/deps/build/zstd"
    ninja -C "$WS/deps/build/zstd" install
fi
echo "    libzstd.a: OK"

# ---- brotli ----------------------------------------------------------------
echo ">>> Build brotli"
source "$WS/toolchain/env.sh"
if [ ! -f "$DEPINST/lib/libbrotlidec.a" ]; then
    mkdir -p "$WS/deps/build/brotli"
    cmake -G Ninja "$WS/deps/src/brotli" \
        -B "$WS/deps/build/brotli" \
        -DCMAKE_INSTALL_PREFIX="$DEPINST" \
        -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBROTLI_DISABLE_TESTS=ON
    ninja -C "$WS/deps/build/brotli"
    ninja -C "$WS/deps/build/brotli" install
fi
echo "    libbrotlidec.a + libbrotlicommon.a: OK"

# ---------------------------------------------------------------------------
# Phase 3 — Combined static archive
#
# GNU ld resolves archives left-to-right and discards unreferenced symbols.
# glib2 references pcre2/ffi, and brotlidec references brotlicommon — but
# their link order in Wireshark's generated link command is not guaranteed.
# Merging them into a single archive lets the linker re-scan as needed.
# ---------------------------------------------------------------------------
echo ">>> Build combined deps archive"
source "$WS/toolchain/env.sh"
MULTIARCH="$DEPINST/lib/aarch64-linux-gnu"

# L-2: Register cleanup so the temp file is removed even if the script exits early.
ar_script=$(mktemp)
trap 'rm -f "$ar_script"' EXIT
cat > "$ar_script" << AREOF
CREATE ${DEPINST}/lib/libcombined-deps.a
ADDLIB ${DEPINST}/lib/libglib-2.0.a
AREOF
# Include multiarch copy if it exists (Debian glib install layout)
[ -f "$MULTIARCH/libglib-2.0.a" ] && echo "ADDLIB $MULTIARCH/libglib-2.0.a" >> "$ar_script"
cat >> "$ar_script" << AREOF
ADDLIB ${DEPINST}/lib/libgmodule-2.0.a
ADDLIB ${DEPINST}/lib/libgobject-2.0.a
ADDLIB ${DEPINST}/lib/libgthread-2.0.a
ADDLIB ${DEPINST}/lib/libpcre2-8.a
ADDLIB ${DEPINST}/lib/libffi.a
ADDLIB ${DEPINST}/lib/libbrotlidec.a
ADDLIB ${DEPINST}/lib/libbrotlicommon.a
SAVE
END
AREOF
ar -M < "$ar_script"
# trap handles cleanup; explicit rm is kept for clarity but is now redundant
rm -f "$ar_script"
trap - EXIT
echo "    libcombined-deps.a: $(du -sh "$DEPINST/lib/libcombined-deps.a" | cut -f1)"

# ---------------------------------------------------------------------------
# Phase 4 — Clone Wireshark
# ---------------------------------------------------------------------------
echo ">>> Clone Wireshark $WIRESHARK_VERSION"
clone_if_missing \
    https://github.com/wireshark/wireshark.git \
    "$WS/wireshark" \
    "$WIRESHARK_VERSION"

# ---------------------------------------------------------------------------
# Phase 5 — Integrate EtherCAT as a built-in dissector
#
# EtherCAT lives in plugins/epan/ethercat (loaded as a .so plugin at runtime).
# For a fully static build we copy the dissector sources into epan/dissectors/
# and add them to DISSECTOR_SRC so make-regs.py auto-registers all
# proto_register_*/proto_reg_handoff_* symbols at link time.
# plugin.c is intentionally excluded — it is only for dynamic plugin loading.
# ---------------------------------------------------------------------------
echo ">>> Integrate EtherCAT dissectors as built-in"
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

# Patch DISSECTOR_SRC in epan/dissectors/CMakeLists.txt if not already patched.
if ! grep -q "packet-ams.c" "$DISSECTORS/CMakeLists.txt"; then
    sed -i 's|set(DISSECTOR_SRC\n|set(DISSECTOR_SRC\n\t${CMAKE_CURRENT_SOURCE_DIR}/packet-ams.c\n|' \
        "$DISSECTORS/CMakeLists.txt" 2>/dev/null || true

    # M-9: Pass WS via argument so the script works regardless of cwd.
    # sed multiline is unreliable across platforms; use python3 instead.
    python3 - "$WS" << 'PYEOF'
import sys, pathlib
ws = sys.argv[1]
p = pathlib.Path(ws) / "wireshark/epan/dissectors/CMakeLists.txt"
if not p.exists():
    print(f"ERROR: {p} not found", file=sys.stderr); sys.exit(1)
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
    print("CMakeLists.txt patched: EtherCAT sources added to DISSECTOR_SRC")
else:
    print("CMakeLists.txt already patched, skipping")
PYEOF
fi

# ---------------------------------------------------------------------------
# Phase 6 — CMake toolchain cache file
# ---------------------------------------------------------------------------
echo ">>> Generate CMake cache file"
source "$WS/toolchain/env.sh"
_glib_hits=$(find "$DEPINST/lib" -name "glibconfig.h" -exec dirname {} \; )
[ -n "$_glib_hits" ] || { echo "ERROR: glibconfig.h not found under $DEPINST/lib" >&2; exit 1; }
[ "$(echo "$_glib_hits" | wc -l)" -eq 1 ] || { echo "ERROR: multiple glibconfig.h found — ambiguous: $_glib_hits" >&2; exit 1; }
GLIB_PRIV_INC="$_glib_hits"

cat > "$WS/toolchain/wireshark-cache.cmake" << CACHEEOF
# Auto-generated by setup.sh — static dep locations for Wireshark CMake.
set(CMAKE_PREFIX_PATH "${DEPINST}" CACHE STRING "")

# GLib2 — use combined archive to avoid pcre2/ffi link-order issue with GNU ld
set(GLIB2_INTERNAL_INCLUDE_DIR "${GLIB_PRIV_INC}" CACHE PATH "")
set(GLIB2_MAIN_INCLUDE_DIR "${DEPINST}/include/glib-2.0" CACHE PATH "")
set(GLIB2_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")
set(GLIB2_VERSION "2.78.6" CACHE STRING "")
set(GLIB2_GMODULE_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")
set(GLIB2_GOBJECT_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")
set(GLIB2_GIO_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")
set(GLIB2_GTHREAD_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")

# PCRE2 — also in combined archive
set(PCRE2_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")
set(PCRE2_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")

# Brotli — also in combined archive (brotlidec depends on brotlicommon)
set(BROTLIDEC_LIBRARY "${DEPINST}/lib/libcombined-deps.a" CACHE FILEPATH "")
set(BROTLI_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")

# libgcrypt + gpg-error (separate — each is a single archive)
set(GCRYPT_LIBRARY "${DEPINST}/lib/libgcrypt.a" CACHE FILEPATH "")
set(GCRYPT_ERROR_LIBRARY "${DEPINST}/lib/libgpg-error.a" CACHE FILEPATH "")
set(GCRYPT_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")

# OpenSSL
set(OPENSSL_ROOT_DIR "${DEPINST}" CACHE PATH "")
set(OPENSSL_USE_STATIC_LIBS TRUE CACHE BOOL "")

# libpcap
set(PCAP_LIBRARY "${DEPINST}/lib/libpcap.a" CACHE FILEPATH "")
set(PCAP_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")

# c-ares
set(CARES_LIBRARY "${DEPINST}/lib/libcares.a" CACHE FILEPATH "")
set(CARES_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")

# Compression
set(LZ4_LIBRARY "${DEPINST}/lib/liblz4.a" CACHE FILEPATH "")
set(LZ4_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")
set(ZSTD_LIBRARY "${DEPINST}/lib/libzstd.a" CACHE FILEPATH "")
set(ZSTD_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")

# zlib
set(ZLIB_LIBRARY "${DEPINST}/lib/libz.a" CACHE FILEPATH "")
set(ZLIB_INCLUDE_DIR "${DEPINST}/include" CACHE PATH "")
CACHEEOF

# ---------------------------------------------------------------------------
# Phase 7 — Configure CMake
# ---------------------------------------------------------------------------
echo ">>> Configure CMake"
source "$WS/toolchain/env.sh"
_glib_hits=$(find "$DEPINST/lib" -name "glibconfig.h" -exec dirname {} \; )
[ -n "$_glib_hits" ] || { echo "ERROR: glibconfig.h not found under $DEPINST/lib" >&2; exit 1; }
[ "$(echo "$_glib_hits" | wc -l)" -eq 1 ] || { echo "ERROR: multiple glibconfig.h found — ambiguous: $_glib_hits" >&2; exit 1; }
GLIB_PRIV_INC="$_glib_hits"

rm -rf "$WS/build"
cmake -G Ninja \
    -B "$WS/build" \
    -S "$WS/wireshark" \
    -C "$WS/toolchain/wireshark-cache.cmake" \
    \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$WS/build/install" \
    \
    -DBUILD_wireshark=OFF \
    -DBUILD_tshark=ON \
    -DBUILD_rawshark=OFF \
    -DBUILD_dumpcap=OFF \
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

# ---------------------------------------------------------------------------
# Phase 8 — Build tshark
# ---------------------------------------------------------------------------
echo ">>> Build tshark"
cmake --build "$WS/build" --target tshark -j"$(nproc)"

# ---------------------------------------------------------------------------
# Phase 9 — Verify & copy to output
# ---------------------------------------------------------------------------
echo ">>> Verify"
TSHARK_BIN=$(find "$WS/build" -name tshark -type f | head -1)

file "$TSHARK_BIN"
readelf -d "$TSHARK_BIN" | grep NEEDED \
    && { echo "ERROR: binary has shared library dependencies"; exit 1; } \
    || echo "PASS: statically linked"

nm "$TSHARK_BIN" | grep -q "proto_register_ecat" \
    && echo "PASS: EtherCAT dissector symbols present" \
    || { echo "ERROR: EtherCAT symbols missing"; exit 1; }

"$TSHARK_BIN" --version 2>&1 | head -1

echo ">>> Strip and copy to $OUTPUT"
strip --strip-all "$TSHARK_BIN" -o "$OUTPUT/tshark"
sha256sum "$OUTPUT/tshark" | tee "$OUTPUT/tshark.sha256"

cat > "$OUTPUT/BUILD_INFO.txt" << BEOF
Wireshark version: ${WIRESHARK_VERSION}
Build date: $(date -u +%Y-%m-%d)
Architecture: aarch64 (ARMv8-A, little-endian)
Linking: fully static (glibc; no runtime .so dependencies)
EtherCAT dissectors: built-in (packet-ethercat-frame, packet-ethercat-datagram,
                                packet-ecatmb, packet-ams, packet-esl,
                                packet-ioraw, packet-nv)
Binary size (stripped): $(du -sh "$OUTPUT/tshark" | cut -f1)
SHA256: $(awk '{print $1}' "$OUTPUT/tshark.sha256")

Note on static glibc vs musl:
  Debian bookworm's musl-tools compiles libstdc++ for glibc, making C++
  builds against musl headers infeasible without a purpose-built musl
  toolchain (not reachable over a GitHub-only network). A fully static
  glibc binary carries the entire C runtime internally and runs on any
  Linux aarch64 kernel, including musl-based Yocto rootfs images.
BEOF

echo ""
echo "================================================================"
echo "  Build complete: $OUTPUT/tshark"
echo "  $(du -sh "$OUTPUT/tshark" | cut -f1)   statically linked aarch64   EtherCAT built-in"
echo "================================================================"
