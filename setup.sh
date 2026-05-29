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
    aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ binutils-aarch64-linux-gnu \
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
# Helper: clone a GitHub repo if the destination doesn't already exist
# ---------------------------------------------------------------------------
clone_if_missing() {
    local url="$1" dest="$2" branch="${3:-}"
    if [ ! -d "$dest/.git" ]; then
        if [ -n "$branch" ]; then
            git clone --depth=1 --branch "$branch" "$url" "$dest"
        else
            git clone --depth=1 "$url" "$dest"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Phase 1 — Clone all dependency sources (in parallel)
# ---------------------------------------------------------------------------
echo ">>> Phase 1: clone dependency sources"
clone_if_missing https://github.com/madler/zlib.git             "$WS/deps/src/zlib"     &
clone_if_missing https://github.com/libffi/libffi.git           "$WS/deps/src/libffi"   &
clone_if_missing https://github.com/PCRE2Project/pcre2.git      "$WS/deps/src/pcre2"    &
clone_if_missing https://github.com/GNOME/glib.git              "$WS/deps/src/glib" "2.78.6" &
clone_if_missing https://github.com/gpg/libgpg-error.git        "$WS/deps/src/libgpg-error" &
clone_if_missing https://github.com/gpg/libgcrypt.git           "$WS/deps/src/libgcrypt"    &
clone_if_missing https://github.com/openssl/openssl.git         "$WS/deps/src/openssl"      &
clone_if_missing https://github.com/the-tcpdump-group/libpcap.git "$WS/deps/src/libpcap"   &
clone_if_missing https://github.com/c-ares/c-ares.git           "$WS/deps/src/c-ares"   &
clone_if_missing https://github.com/lz4/lz4.git                 "$WS/deps/src/lz4"      &
clone_if_missing https://github.com/facebook/zstd.git           "$WS/deps/src/zstd"     &
clone_if_missing https://github.com/google/brotli.git           "$WS/deps/src/brotli"   &
wait
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
GLIB_PRIV_INC=$(find "$DEPINST/lib" -name "glibconfig.h" -exec dirname {} \; | head -1)
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
    # The doc/ subdir may fail (missing texinfo) — ignore, library still builds.
    make -j"$(nproc)" || true
    make install || true
    # Verify the library itself was installed despite any doc errors
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
    # Use the latest available tag in the source; fall back to HEAD if no tag found.
    OPENSSL_TAG=$(git tag | grep '^openssl-3\.' | sort -V | tail -1)
    [ -n "$OPENSSL_TAG" ] && git checkout "$OPENSSL_TAG" || true
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

ar_script=$(mktemp)
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
rm -f "$ar_script"
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

    # sed multiline is unreliable across platforms; use python3 instead.
    python3 - << 'PYEOF'
import re, pathlib
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
GLIB_PRIV_INC=$(find "$DEPINST/lib" -name "glibconfig.h" -exec dirname {} \; | head -1)

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
GLIB_PRIV_INC=$(find "$DEPINST/lib" -name "glibconfig.h" -exec dirname {} \; | head -1)

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
