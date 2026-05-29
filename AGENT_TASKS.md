# TShark 4.2.x — ARMv8 (aarch64) Fully Static Build with musl libc
## Agent Task List

**Goal**: Produce a single fully static `tshark` binary for aarch64 (ARMv8 little-endian)
using musl libc, with EtherCAT full dissector support, and copy it to `/build/output`.

**Constraints**:
- Wireshark version: latest `v4.2.x` tag from `github.com/wireshark/wireshark`
- C library: musl libc (from `github.com/bminor/musl`)
- All dependencies cross-compiled for aarch64 from GitHub sources
- No outbound network access except to GitHub IP ranges
- Output: `/build/output/tshark` (static ELF, aarch64)

---

## Directory Layout Convention

```
/workspace/
  musl-sysroot/          # musl headers + libs (becomes --sysroot target)
    usr/
      include/           # musl headers
      lib/               # musl static libs + startup objects
  deps/
    src/                 # cloned dependency source trees
    build/               # per-dep out-of-source build dirs
    install/             # dep install prefix (headers + .a files only)
  wireshark/             # cloned Wireshark 4.2.x source
  build/                 # CMake out-of-source build for tshark
  toolchain/
    meson/               # cloned meson source (used as python3 meson.py)
    aarch64-musl-cc      # compiler wrapper script
    aarch64-musl-c++     # C++ compiler wrapper script
```

---

## Phase 0 — Preflight & Environment Setup

### T-00: Verify base tools
Check that each of the following is present and note its version.
Exit with a clear error message listing any that are missing.

Required tools:
- `aarch64-linux-gnu-gcc` and `aarch64-linux-gnu-g++` (Debian cross-compiler package: `gcc-aarch64-linux-gnu`, `g++-aarch64-linux-gnu`)
- `cmake` >= 3.20
- `ninja`
- `python3` >= 3.6
- `git`
- `flex`, `bison`
- `pkg-config`
- `perl` (needed by OpenSSL configure)
- `m4`, `autoconf`, `automake`, `libtool`

If `gcc-aarch64-linux-gnu` or `g++-aarch64-linux-gnu` are missing, install them:
```bash
sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu
```

If `m4`, `autoconf`, `automake`, `libtool` are missing, install them:
```bash
sudo apt-get install -y m4 autoconf automake libtool gettext
```

If `pkg-config` is missing:
```bash
sudo apt-get install -y pkg-config
```

**Success criterion**: All tools found and versions printed.

---

### T-01: Create directory structure

```bash
mkdir -p /workspace/musl-sysroot/usr/include
mkdir -p /workspace/musl-sysroot/usr/lib
mkdir -p /workspace/deps/src
mkdir -p /workspace/deps/build
mkdir -p /workspace/deps/install
mkdir -p /workspace/toolchain
mkdir -p /build/output
```

**Success criterion**: All directories exist.

---

### T-02: Clone meson build system from GitHub

Meson is required for building glib2 (glib2 >= 2.68 only supports meson).
Clone it and use it as a Python script — no installation needed.

```bash
git clone --depth=1 https://github.com/mesonbuild/meson.git /workspace/toolchain/meson
```

Alias for use in subsequent tasks:
```bash
MESON="python3 /workspace/toolchain/meson/meson.py"
```

Verify:
```bash
python3 /workspace/toolchain/meson/meson.py --version
```

**Success criterion**: meson version printed without error.

---

## Phase 1 — musl libc Cross-Toolchain for aarch64

### T-10: Clone musl libc

```bash
git clone --depth=1 --branch v1.2.5 https://github.com/bminor/musl.git /workspace/deps/src/musl
```

If `v1.2.5` does not exist, use the latest tag matching `v1.2.*`:
```bash
git ls-remote --tags https://github.com/bminor/musl.git | grep 'v1\.2\.' | sort -V | tail -1
```

**Success criterion**: `/workspace/deps/src/musl/configure` exists.

---

### T-11: Cross-compile musl for aarch64

Build musl using the Debian aarch64-linux-gnu cross-compiler. Install into
`/workspace/musl-sysroot/usr` so that `--sysroot=/workspace/musl-sysroot` causes
gcc to find musl headers in `<sysroot>/usr/include` and libs in `<sysroot>/usr/lib`.

```bash
cd /workspace/deps/src/musl
make clean || true

./configure \
  --prefix=/workspace/musl-sysroot/usr \
  --host=aarch64-linux-gnu \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CC=aarch64-linux-gnu-gcc \
  CFLAGS="-march=armv8-a -O2" \
  --disable-shared \
  --enable-static

make -j$(nproc)
make install
```

After install, verify:
```bash
ls /workspace/musl-sysroot/usr/include/stdio.h    # must exist
ls /workspace/musl-sysroot/usr/lib/libc.a         # must exist
ls /workspace/musl-sysroot/usr/lib/crt1.o         # must exist
```

**Success criterion**: All three files exist.

---

### T-12: Create compiler wrapper scripts

Create `/workspace/toolchain/aarch64-musl-cc`:
```bash
#!/bin/bash
exec aarch64-linux-gnu-gcc \
  --sysroot=/workspace/musl-sysroot \
  -march=armv8-a \
  "$@"
```

Create `/workspace/toolchain/aarch64-musl-c++`:
```bash
#!/bin/bash
exec aarch64-linux-gnu-g++ \
  --sysroot=/workspace/musl-sysroot \
  -march=armv8-a \
  "$@"
```

Make both executable:
```bash
chmod +x /workspace/toolchain/aarch64-musl-cc
chmod +x /workspace/toolchain/aarch64-musl-c++
```

Set environment variables that all subsequent tasks will use (add to a sourced file
`/workspace/toolchain/env.sh` and source it at the start of each task):

```bash
cat > /workspace/toolchain/env.sh << 'EOF'
export SYSROOT=/workspace/musl-sysroot
export DEPINST=/workspace/deps/install
export CC=/workspace/toolchain/aarch64-musl-cc
export CXX=/workspace/toolchain/aarch64-musl-c++
export AR=aarch64-linux-gnu-ar
export RANLIB=aarch64-linux-gnu-ranlib
export STRIP=aarch64-linux-gnu-strip
export NM=aarch64-linux-gnu-nm
export LD=aarch64-linux-gnu-ld
export CFLAGS="-O2 -pipe -fPIC"
export CXXFLAGS="-O2 -pipe -fPIC"
export LDFLAGS="-static -L${SYSROOT}/usr/lib -L${DEPINST}/lib"
export CPPFLAGS="-I${DEPINST}/include"
export PKG_CONFIG_LIBDIR="${DEPINST}/lib/pkgconfig"
export PKG_CONFIG_PATH="${DEPINST}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""
export MESON="python3 /workspace/toolchain/meson/meson.py"
EOF
```

**Success criterion**: `source /workspace/toolchain/env.sh` runs without errors.

---

### T-13: Verify musl toolchain produces valid aarch64 static binary

```bash
source /workspace/toolchain/env.sh
cat > /tmp/hello.c << 'EOF'
#include <stdio.h>
int main(void) { puts("hello aarch64 musl"); return 0; }
EOF
$CC $CFLAGS $LDFLAGS -o /tmp/hello-aarch64 /tmp/hello.c
file /tmp/hello-aarch64
```

Expected output must contain all of:
- `ELF 64-bit LSB executable`
- `ARM aarch64`
- `statically linked`

**Success criterion**: `file` output matches all three criteria above.

---

## Phase 2 — Static Dependency Builds

All tasks in this phase must:
1. `source /workspace/toolchain/env.sh` at the start
2. Install artifacts into `$DEPINST` (`/workspace/deps/install`)
3. Install only static libraries (`.a` files); do not install `.so` files
4. Verify the `.a` file exists in `$DEPINST/lib/` after installation

Cross-compilation build flags for autotools-based packages (use as a baseline):
```bash
./configure \
  --host=aarch64-linux-gnu \
  --prefix=$DEPINST \
  --enable-static \
  --disable-shared \
  CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB \
  CFLAGS="$CFLAGS $CPPFLAGS" \
  CXXFLAGS="$CXXFLAGS $CPPFLAGS" \
  LDFLAGS="$LDFLAGS"
```

---

### T-20: Build zlib

**Source**: `https://github.com/madler/zlib.git` — use latest `v1.3.x` tag.

zlib uses a custom configure script (not autotools). Use the following approach:

```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/madler/zlib.git /workspace/deps/src/zlib
mkdir -p /workspace/deps/build/zlib && cd /workspace/deps/build/zlib

cmake -G Ninja /workspace/deps/src/zlib \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$DEPINST \
  -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
  -DBUILD_SHARED_LIBS=OFF

ninja
ninja install
```

**Verify**: `ls $DEPINST/lib/libz.a`

---

### T-21: Build libffi

**Source**: `https://github.com/libffi/libffi.git` — use latest `v3.4.x` tag.

```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/libffi/libffi.git /workspace/deps/src/libffi
cd /workspace/deps/src/libffi
autoreconf -fiv

./configure \
  --host=aarch64-linux-gnu \
  --prefix=$DEPINST \
  --enable-static --disable-shared \
  --disable-docs \
  CC=$CC CFLAGS="$CFLAGS" AR=$AR RANLIB=$RANLIB
make -j$(nproc)
make install
```

**Verify**: `ls $DEPINST/lib/libffi.a`

---

### T-22: Build pcre2

**Source**: `https://github.com/PCRE2Project/pcre2.git` — use latest `pcre2-10.x` tag.

```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/PCRE2Project/pcre2.git /workspace/deps/src/pcre2
mkdir -p /workspace/deps/build/pcre2 && cd /workspace/deps/build/pcre2

cmake -G Ninja /workspace/deps/src/pcre2 \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$DEPINST \
  -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
  -DBUILD_SHARED_LIBS=OFF \
  -DPCRE2_BUILD_PCRE2_8=ON \
  -DPCRE2_BUILD_PCRE2_16=OFF \
  -DPCRE2_BUILD_PCRE2_32=OFF \
  -DPCRE2_SUPPORT_UNICODE=ON \
  -DPCRE2_BUILD_TESTS=OFF \
  -DPCRE2_BUILD_PCRE2GREP=OFF

ninja
ninja install
```

**Verify**: `ls $DEPINST/lib/libpcre2-8.a`

---

### T-23: Build glib2

**Source**: `https://github.com/GNOME/glib.git` — use the latest `2.78.x` tag
(Wireshark 4.2.x requires >= 2.56; 2.78.x is stable and compatible).

glib2 uses meson. Create a cross-file for meson:

```bash
source /workspace/toolchain/env.sh

cat > /workspace/toolchain/aarch64-musl-meson.ini << EOF
[binaries]
c = '/workspace/toolchain/aarch64-musl-cc'
cpp = '/workspace/toolchain/aarch64-musl-c++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkgconfig = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
pkg_config_libdir = '/workspace/deps/install/lib/pkgconfig'
EOF
```

Then build:
```bash
git clone --depth=1 https://github.com/GNOME/glib.git /workspace/deps/src/glib
cd /workspace/deps/src/glib

# Find the latest 2.78.x tag and check it out
GLIB_TAG=$(git tag | grep '^2\.78\.' | sort -V | tail -1)
git checkout $GLIB_TAG

$MESON setup /workspace/deps/build/glib \
  --cross-file /workspace/toolchain/aarch64-musl-meson.ini \
  --prefix=$DEPINST \
  --default-library=static \
  -Ddefault_library=static \
  -Dintrospection=disabled \
  -Ddocumentation=false \
  -Dtests=false \
  -Dinstalled_tests=false \
  -Dlibmount=disabled \
  -Dselinux=disabled \
  -Dxattr=false \
  -Dman-pages=disabled \
  -Dlibelf=disabled \
  -Ddbus=disabled \
  --buildtype=release

ninja -C /workspace/deps/build/glib
ninja -C /workspace/deps/build/glib install
```

**Troubleshooting**:
- If meson complains about `iconv`, musl provides iconv built-in; add `-Diconv=libc` to the meson options.
- If meson complains about `libmount`, it should be disabled already via `-Dlibmount=disabled`.
- If the build fails due to `gettext`/`intl`, add `-Dnls=disabled`.

**Verify**: `ls $DEPINST/lib/libglib-2.0.a`

---

### T-24: Build libgpg-error

**Source**: `https://github.com/gpg/libgpg-error.git` — use latest `libgpg-error-1.x` tag.

```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/gpg/libgpg-error.git /workspace/deps/src/libgpg-error
cd /workspace/deps/src/libgpg-error
autoreconf -fiv 2>/dev/null || ./autogen.sh

./configure \
  --host=aarch64-linux-gnu \
  --prefix=$DEPINST \
  --enable-static --disable-shared \
  --disable-nls \
  --disable-languages \
  --disable-tests \
  CC=$CC CFLAGS="$CFLAGS" AR=$AR RANLIB=$RANLIB
make -j$(nproc)
make install
```

**Note**: `libgpg-error` provides the `gpg-error-config` and `gpgrt-config` scripts
and the lock-object code needed by libgcrypt. It must be built before libgcrypt.

**Verify**: `ls $DEPINST/lib/libgpg-error.a`

---

### T-25: Build libgcrypt

**Source**: `https://github.com/gpg/libgcrypt.git` — use latest `libgcrypt-1.10.x` tag.

```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/gpg/libgcrypt.git /workspace/deps/src/libgcrypt
cd /workspace/deps/src/libgcrypt
autoreconf -fiv 2>/dev/null || ./autogen.sh

./configure \
  --host=aarch64-linux-gnu \
  --prefix=$DEPINST \
  --enable-static --disable-shared \
  --disable-doc \
  --with-libgpg-error-prefix=$DEPINST \
  CC=$CC CFLAGS="$CFLAGS $CPPFLAGS" AR=$AR RANLIB=$RANLIB \
  LDFLAGS="$LDFLAGS"
make -j$(nproc)
make install
```

**Verify**: `ls $DEPINST/lib/libgcrypt.a`

---

### T-26: Build OpenSSL (for TLS session decryption support)

**Source**: `https://github.com/openssl/openssl.git` — use latest `openssl-3.2.x` tag.

OpenSSL uses a Perl-based configure script with its own cross-compile support.

```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/openssl/openssl.git /workspace/deps/src/openssl
cd /workspace/deps/src/openssl

# Find and checkout latest 3.2.x tag
OPENSSL_TAG=$(git tag | grep '^openssl-3\.2\.' | sort -V | tail -1)
git checkout $OPENSSL_TAG

./Configure \
  linux-aarch64 \
  --prefix=$DEPINST \
  --openssldir=$DEPINST/ssl \
  --cross-compile-prefix=aarch64-linux-gnu- \
  no-shared \
  no-tests \
  no-docs \
  -march=armv8-a \
  "$CFLAGS"

make -j$(nproc) build_sw
make install_sw
```

**Note**: OpenSSL's `linux-aarch64` target is its built-in profile for aarch64 Linux.
The `--sysroot` is passed via the `CC` wrapper implicitly since we set
`CROSS_COMPILE=aarch64-linux-gnu-` which OpenSSL uses to prefix the compiler.
If the build fails due to the wrapper CC, fall back to:
```bash
CC="aarch64-linux-gnu-gcc --sysroot=/workspace/musl-sysroot -march=armv8-a" \
./Configure linux-aarch64 ...
```

**Verify**: `ls $DEPINST/lib/libssl.a && ls $DEPINST/lib/libcrypto.a`

---

### T-27: Build libpcap

**Source**: `https://github.com/the-tcpdump-group/libpcap.git` — use latest `libpcap-1.10.x` tag.

libpcap uses CMake:
```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/the-tcpdump-group/libpcap.git /workspace/deps/src/libpcap
mkdir -p /workspace/deps/build/libpcap && cd /workspace/deps/build/libpcap

cmake -G Ninja /workspace/deps/src/libpcap \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$DEPINST \
  -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
  -DBUILD_SHARED_LIBS=OFF \
  -DDISABLE_LINUX_USBMON=ON \
  -DDISABLE_RDMA=ON \
  -DDISABLE_BLUETOOTH=ON \
  -DDISABLE_DBUS=ON \
  -DDISABLE_NETMAP=ON

ninja
ninja install
```

**Note**: libpcap on Linux requires either `libpcap-dev` headers for `linux/if_packet.h`
or direct kernel headers. Since we use `--sysroot=/workspace/musl-sysroot` and musl
ships Linux kernel headers, `linux/if_packet.h` should be available. If not, add
`-DPKT_DATALINK_SOURCE=bpf` to fall back to BPF-only capture.

**Verify**: `ls $DEPINST/lib/libpcap.a`

---

### T-28: Build c-ares (async DNS resolver)

**Source**: `https://github.com/c-ares/c-ares.git` — use latest `v1.x` tag.

```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/c-ares/c-ares.git /workspace/deps/src/c-ares
mkdir -p /workspace/deps/build/c-ares && cd /workspace/deps/build/c-ares

cmake -G Ninja /workspace/deps/src/c-ares \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$DEPINST \
  -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
  -DBUILD_SHARED_LIBS=OFF \
  -DCARES_STATIC=ON \
  -DCARES_SHARED=OFF \
  -DCARES_BUILD_TESTS=OFF \
  -DCARES_BUILD_TOOLS=OFF

ninja
ninja install
```

**Verify**: `ls $DEPINST/lib/libcares.a`

---

### T-29: Build lz4

**Source**: `https://github.com/lz4/lz4.git` — use latest `v1.9.x` tag.

```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/lz4/lz4.git /workspace/deps/src/lz4
mkdir -p /workspace/deps/build/lz4 && cd /workspace/deps/build/lz4

cmake -G Ninja /workspace/deps/src/lz4/build/cmake \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$DEPINST \
  -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
  -DBUILD_SHARED_LIBS=OFF \
  -DLZ4_BUILD_CLI=OFF \
  -DLZ4_BUILD_LEGACY_LZ4C=OFF

ninja
ninja install
```

**Verify**: `ls $DEPINST/lib/liblz4.a`

---

### T-30: Build zstd

**Source**: `https://github.com/facebook/zstd.git` — use latest `v1.5.x` tag.

```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/facebook/zstd.git /workspace/deps/src/zstd
mkdir -p /workspace/deps/build/zstd && cd /workspace/deps/build/zstd

cmake -G Ninja /workspace/deps/src/zstd/build/cmake \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$DEPINST \
  -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
  -DBUILD_SHARED_LIBS=OFF \
  -DZSTD_BUILD_STATIC=ON \
  -DZSTD_BUILD_SHARED=OFF \
  -DZSTD_BUILD_PROGRAMS=OFF \
  -DZSTD_BUILD_TESTS=OFF

ninja
ninja install
```

**Verify**: `ls $DEPINST/lib/libzstd.a`

---

### T-31: Build brotli

**Source**: `https://github.com/google/brotli.git` — use latest tag.

```bash
source /workspace/toolchain/env.sh
git clone --depth=1 https://github.com/google/brotli.git /workspace/deps/src/brotli
mkdir -p /workspace/deps/build/brotli && cd /workspace/deps/build/brotli

cmake -G Ninja /workspace/deps/src/brotli \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$DEPINST \
  -DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBROTLI_DISABLE_TESTS=ON

ninja
ninja install
```

**Verify**: `ls $DEPINST/lib/libbrotlidec.a`

---

## Phase 3 — Wireshark Source Acquisition

### T-40: Clone Wireshark 4.2.x

Find the latest `v4.2.x` release tag and do a shallow clone of that tag:

```bash
# List all v4.2.x tags, pick the highest
WIRESHARK_TAG=$(git ls-remote --tags https://github.com/wireshark/wireshark.git \
  | grep 'refs/tags/v4\.2\.[0-9]*$' \
  | awk '{print $2}' \
  | sed 's|refs/tags/||' \
  | sort -V \
  | tail -1)
echo "Using Wireshark tag: $WIRESHARK_TAG"

git clone --depth=1 --branch "$WIRESHARK_TAG" \
  https://github.com/wireshark/wireshark.git \
  /workspace/wireshark
```

**Verify**: `/workspace/wireshark/CMakeLists.txt` exists and contains `project(Wireshark`.

---

### T-41: Confirm EtherCAT dissector source files are present

EtherCAT dissectors are built-in to Wireshark. Confirm they exist:

```bash
ls /workspace/wireshark/epan/dissectors/packet-ethercat.c
ls /workspace/wireshark/epan/dissectors/packet-ethercat-mailbox.c
```

Additionally check for full EtherCAT sub-protocol coverage:
```bash
ls /workspace/wireshark/epan/dissectors/packet-ecat-*.c 2>/dev/null || true
```

Document which EtherCAT dissectors are present. All of the following should be found:
- `packet-ethercat.c` — base EtherCAT frame dissector
- `packet-ethercat-mailbox.c` — CoE, FoE, EoE, SoE, AoE mailbox
- Any `packet-ecat-*.c` files present (e.g., `packet-ecat-datagram.c`)

These dissectors have no external library dependencies — they are compiled unconditionally
as part of the `epan` library and will be statically linked into the `tshark` binary.

**Success criterion**: `packet-ethercat.c` and `packet-ethercat-mailbox.c` both exist.

---

## Phase 4 — CMake Configuration

### T-50: Write CMake toolchain file

```bash
cat > /workspace/toolchain/aarch64-musl.cmake << 'EOF'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(SYSROOT /workspace/musl-sysroot)
set(DEPINST /workspace/deps/install)

set(CMAKE_C_COMPILER   /workspace/toolchain/aarch64-musl-cc)
set(CMAKE_CXX_COMPILER /workspace/toolchain/aarch64-musl-c++)
set(CMAKE_AR           aarch64-linux-gnu-ar)
set(CMAKE_RANLIB       aarch64-linux-gnu-ranlib)
set(CMAKE_STRIP        aarch64-linux-gnu-strip)

set(CMAKE_C_FLAGS_INIT   "-O2 -march=armv8-a -pipe")
set(CMAKE_CXX_FLAGS_INIT "-O2 -march=armv8-a -pipe")

# Force static linking for all executables
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static -L${SYSROOT}/usr/lib -L${DEPINST}/lib")

# pkg-config must find only our static dep libs
set(ENV{PKG_CONFIG_LIBDIR} "${DEPINST}/lib/pkgconfig")
set(ENV{PKG_CONFIG_PATH}   "${DEPINST}/lib/pkgconfig")

# sysroot: headers from musl, libs from musl + depinst
set(CMAKE_FIND_ROOT_PATH ${SYSROOT} ${DEPINST})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)   # host tools run on build machine
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
```

**Success criterion**: File `/workspace/toolchain/aarch64-musl.cmake` is non-empty.

---

### T-51: Configure CMake for tshark static build

```bash
source /workspace/toolchain/env.sh
mkdir -p /workspace/build

cmake -G Ninja \
  -B /workspace/build \
  -S /workspace/wireshark \
  --toolchain /workspace/toolchain/aarch64-musl.cmake \
  \
  -DCMAKE_INSTALL_PREFIX=/workspace/build/install \
  -DCMAKE_BUILD_TYPE=Release \
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
  -DENABLE_BCWEXT=OFF \
  -DENABLE_AIRPCAP=OFF \
  \
  -DGLIB2_INCLUDE_DIR=$DEPINST/include/glib-2.0 \
  -DCMAKE_PREFIX_PATH=$DEPINST
```

**Expected outcome**: CMake configuration succeeds and reports:
- GLib2 found
- libpcap found
- libgcrypt found
- OpenSSL found
- c-ares found

**Troubleshooting**:

If CMake cannot find glib2, pass explicit paths:
```
-DGLIB2_INCLUDE_DIR=$DEPINST/include/glib-2.0
-DGLIB2_LIBRARIES=$DEPINST/lib/libglib-2.0.a
-DGLIB2_GMODULE_INCLUDE_DIR=$DEPINST/include/glib-2.0
-DGLIB2_GMODULE_LIBRARIES=$DEPINST/lib/libgmodule-2.0.a
-DGLIB2_GOBJECT_INCLUDE_DIR=$DEPINST/include/glib-2.0
-DGLIB2_GOBJECT_LIBRARIES=$DEPINST/lib/libgobject-2.0.a
```

Note: glib2's internal header `glibconfig.h` is installed in
`$DEPINST/lib/glib-2.0/include/`. If includes fail, add this path:
```
-DCMAKE_REQUIRED_INCLUDES="$DEPINST/include/glib-2.0;$DEPINST/lib/glib-2.0/include"
```

If linker errors occur about missing `-lresolv` or `-lpthread`, add to linker flags:
```
-DCMAKE_EXE_LINKER_FLAGS="-static -L${SYSROOT}/usr/lib -L${DEPINST}/lib -lpthread -lm -lrt"
```

**Success criterion**: `cmake --build /workspace/build --target help | grep tshark` lists the tshark target.

---

## Phase 5 — Build tshark

### T-60: Build tshark target

```bash
cmake --build /workspace/build --target tshark -j$(nproc)
```

Monitor build output for linker errors about missing `.so` files. Any `cannot find -lfoo`
for a shared lib indicates a dependency built as `.so` instead of `.a` — go back to
that dep's build task and verify `--disable-shared --enable-static` was applied.

**Success criterion**: Build completes without error and
`/workspace/build/run/tshark` (or `/workspace/build/tshark`) is present.

Locate the binary:
```bash
find /workspace/build -name tshark -type f | head -5
```

---

### T-61: Verify the binary

Run all of the following checks:

```bash
TSHARK_BIN=$(find /workspace/build -name tshark -type f | head -1)

# 1. Architecture and link type
file $TSHARK_BIN
# Must contain: ELF 64-bit LSB executable, ARM aarch64, statically linked

# 2. No dynamic library dependencies
readelf -d $TSHARK_BIN | grep NEEDED || echo "PASS: no shared library dependencies"

# 3. Binary size sanity check (static tshark is typically 20–80 MB)
du -sh $TSHARK_BIN

# 4. EtherCAT dissector symbol presence (confirms dissector compiled in)
aarch64-linux-gnu-nm $TSHARK_BIN | grep -i ethercat
# Should list symbols like: proto_register_ethercat, proto_reg_handoff_ethercat
```

**Success criteria**:
- `file` output contains `ARM aarch64` and `statically linked`
- `readelf -d` shows no `NEEDED` entries (or the command exits with no output)
- `nm | grep ethercat` returns at least `proto_register_ethercat`

If the binary is dynamically linked, identify which shared libs are still linked:
```bash
readelf -d $TSHARK_BIN | grep NEEDED
```
Then trace back which CMake target pulled them in and fix the dependency.

---

## Phase 6 — Output & Cleanup

### T-70: Strip and copy to output volume

```bash
TSHARK_BIN=$(find /workspace/build -name tshark -type f | head -1)

aarch64-linux-gnu-strip --strip-all $TSHARK_BIN -o /build/output/tshark

# Confirm
file /build/output/tshark
du -sh /build/output/tshark
```

**Success criterion**: `/build/output/tshark` exists and passes the same `file` check as T-61.

---

### T-71: Write build manifest

Write a summary of the build to `/build/output/BUILD_INFO.txt`:

```
Wireshark version: <tag used>
musl libc version: <version>
Build date: <date>
Architecture: aarch64 (ARMv8-A, little-endian)
Libc: musl (static)
EtherCAT dissectors: yes (built-in, no external deps)
Binary size (stripped): <size>
SHA256: <sha256sum of /build/output/tshark>
```

Compute SHA256:
```bash
sha256sum /build/output/tshark | tee /build/output/tshark.sha256
```

---

## Error Recovery Reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `cannot find -lglib-2.0` | glib2 not found in `DEPINST` | Verify T-23 installed `libglib-2.0.a`; check `PKG_CONFIG_PATH` |
| `undefined reference to pthread_*` | musl pthreads | Add `-lpthread` to `CMAKE_EXE_LINKER_FLAGS` |
| `linux/if_packet.h not found` | Missing kernel headers in musl sysroot | Run `ls /workspace/musl-sysroot/usr/include/linux/`; if empty, re-run musl install |
| glib2 meson cross-file errors | Meson can't invoke the CC wrapper | Check that `/workspace/toolchain/aarch64-musl-cc` is executable and outputs valid aarch64 |
| OpenSSL config fails | Wrong target string | Use `linux-aarch64` exactly, not `linux-arm` |
| `undefined reference to __stack_chk_fail` | Stack protector vs musl | Add `-fno-stack-protector` to `CFLAGS` or ensure `__stack_chk_fail` is in `musl/src/env/` |
| CMake finds host libs instead of cross libs | `CMAKE_FIND_ROOT_PATH_MODE` not honoured | Ensure `--toolchain` flag (not `-DCMAKE_TOOLCHAIN_FILE`) is used |
| EtherCAT symbols missing from `nm` output | Dissector excluded from build | Check `epan/dissectors/CMakeLists.txt` for `packet-ethercat`; it should be in the unconditional list |
