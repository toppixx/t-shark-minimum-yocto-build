# Dependency License List

License inventory for the aarch64 TShark + dumpcap + termshark build.

- **Generated:** 2026-05-29
- **Method:** licenses read directly from each pinned source tree
  (`deps/src/*`, `wireshark/`, `toolchain/meson/`) and from the resolved Go
  module cache for termshark.
- Exact dependency commit SHAs are pinned in `setup.sh` (`DEP_SHAS`) and in
  `upgrade-tshark-by-termshark.sh` (`TERMSHARK_SHA`).

---

## 1. Distributed binaries — what governs each artifact

| Binary | Effective license of the binary | Why |
|--------|----------------------------------|-----|
| `tshark` | **GPL-2.0-or-later** | Wireshark code is GPL-2.0+; the whole binary inherits it |
| `dumpcap` | **GPL-2.0-or-later** | same Wireshark codebase |
| `termshark` | **MIT** (binary aggregates MIT/Apache-2.0/MPL-2.0/BSD/ISC/LGPL-2.1 deps) | termshark itself is MIT; it is a separate Go binary that *invokes* tshark, it does not link Wireshark code |

> `termshark` does **not** statically link Wireshark — it runs `tshark`/`dumpcap`
> as child processes. So termshark's MIT license and tshark's GPL license apply
> to separate binaries, not to one combined work.

---

## 2. TShark / dumpcap dependency stack (C, statically linked)

These are compiled into the `tshark` and `dumpcap` binaries.

| Component | Version / ref | License | Notes |
|-----------|---------------|---------|-------|
| **Wireshark** (tshark, dumpcap, EtherCAT dissectors) | v4.2.14 | **GPL-2.0-or-later** | governs the final binary |
| zlib | 1.3.x (`f9dd600`) | **Zlib** | permissive |
| libffi | (`c5abbda`) | **MIT** | permissive |
| PCRE2 | 10.48 (`ff92e0b`) | **BSD-3-Clause WITH PCRE2-exception** | permissive |
| GLib (glib-2.0, gmodule, gobject, gthread) | 2.78.6 | **LGPL-2.1-or-later** | static-link relinking obligation ⚠ |
| libgpg-error | (`9b108b5`) | **LGPL-2.1-or-later** (library) | tools are GPL but not linked |
| libgcrypt | 1.12.x (`92a2b41`) | **LGPL-2.1-or-later** | static-link relinking obligation ⚠ |
| OpenSSL | 3.x (`0c11947`) | **Apache-2.0** | permissive; NOTICE retention |
| libpcap | 1.10.x (`6b5de1e`) | **BSD-3-Clause** | permissive |
| c-ares | 1.34.5 (`c93e50f`) | **MIT** | permissive |
| lz4 | 1.9.x (`64e81c5`) | **BSD-2-Clause** (library; CLI is GPL-2 but not built) | permissive |
| zstd | 1.6.0 (`5233c58`) | **BSD-3-Clause** (dual BSD/GPL-2; BSD chosen) | permissive |
| brotli | (`6312ee2`) | **MIT** | permissive |
| libnl-3 / libnl-genl-3 / libnl-route-3 | 3.7.0 (Debian) | **LGPL-2.1** | linked into `dumpcap`; relinking obligation ⚠ |
| GNU C Library (glibc, static) | Debian 2.36 | **LGPL-2.1-or-later** (with linking exceptions) | binary is statically linked → relinking obligation ⚠ |

### musl note
`musl` (MIT) was installed during build experimentation but the **final
binaries are statically linked against glibc**, not musl. musl is therefore a
build-time-only artifact and is not distributed in the binaries.

---

## 3. termshark dependency stack (Go, statically linked)

termshark is a pure-Go binary (`CGO_ENABLED=0`). The table summarises the
license families across **209 resolved Go modules** (direct + transitive),
classified from each module's license file.

| License | Module count | Examples |
|---------|--------------|----------|
| MIT | 30 | termshark, gcla/gowid, sirupsen/logrus, spf13/viper, stretchr/testify |
| Apache-2.0 | 19 | gdamore/tcell, cloud.google.com/go/*, google.golang.org/* |
| MPL-2.0 | 15 | hashicorp/* (golang-lru, hcl, serf, memberlist, …) |
| BSD-3-Clause | 11 | golang.org/x/*, google protobuf |
| BSD-2-Clause | 2 | pkg/errors, kballard/go-shellquote |
| ISC | 1 | (one module) |
| **LGPL-2.1** | **1** | **salsa.debian.org/vasudev/gospake2** ⚠ |

### Notable direct termshark dependencies

| Module | Version | License |
|--------|---------|---------|
| github.com/gcla/gowid | v1.4.0 | MIT |
| github.com/gdamore/tcell/v2 | v2.5.0 | Apache-2.0 |
| github.com/antchfx/xmlquery | v1.3.3 | MPL-2.0 |
| github.com/sirupsen/logrus | v1.7.0 | MIT |
| github.com/spf13/viper | v1.12.0 | MIT |
| github.com/jessevdk/go-flags | v1.4.0 | BSD-3-Clause |
| github.com/pkg/errors | v0.9.1 | BSD-2-Clause |
| github.com/hashicorp/golang-lru | v0.5.4 | MPL-2.0 |
| github.com/psanford/wormhole-william | v1.0.6-pre | MIT |
| salsa.debian.org/vasudev/gospake2 | (pinned) | **LGPL-2.1** ⚠ |
| golang.org/x/sys | (pinned) | BSD-3-Clause |

> **gospake2 (LGPL-2.1)** is pulled in transitively by `wormhole-william`
> (termshark's "send pcap via magic-wormhole" feature) and **is compiled into
> the termshark binary** (confirmed: `gospake2.SPAKE2` symbols present).
> If the magic-wormhole feature is not needed on the embedded target, building
> termshark without it removes the only LGPL component from the Go binary.

There is **no GPL** code in the termshark Go dependency tree.

---

## 4. Build-time-only tools (NOT distributed in any binary)

| Tool | License | Role |
|------|---------|------|
| Meson | Apache-2.0 | builds glib2 |
| Ninja, CMake | Apache-2.0 / BSD-3-Clause | build drivers |
| GCC / binutils | GPL-3.0 (with runtime exception) | compiler; runtime exception means produced binaries are not GPL-encumbered by the compiler |
| Go toolchain (golang-1.19) | BSD-3-Clause | builds termshark |
| flex / bison | BSD / GPL-3-with-exception | lexer/parser generators |

These run on the build host only and do not contribute code to the shipped
binaries (compiler runtime exceptions apply), so they impose no distribution
obligations on the artifacts.

---

## 5. Compliance obligations summary

When distributing the binaries, the following must be honoured:

### GPL-2.0-or-later — `tshark`, `dumpcap`
- Provide, or offer in writing, the **complete corresponding source code** of
  Wireshark 4.2.14 plus the build scripts (`setup.sh`, `build.sh`).
- Include the GPL-2.0 license text.
- The EtherCAT dissector sources moved into the build are also GPL-2.0+.

### LGPL-2.1 — glibc (static), GLib, libgcrypt, libgpg-error, libnl, gospake2
- Because these are **statically linked**, LGPL-2.1 §6 requires you to enable
  relinking: ship either the dependency object files, or the full build tree
  that lets a user rebuild with a modified version of the LGPL library.
  Shipping this repository (the pinned sources + `setup.sh`) satisfies this.
- Include the LGPL-2.1 license text.

### Apache-2.0 — OpenSSL, tcell, others
- Retain copyright/NOTICE files and the Apache-2.0 license text.

### MPL-2.0 — HashiCorp libraries, xmlquery
- If any MPL-covered file is modified, its source must be made available.
  Unmodified use only requires retaining the license.

### MIT / BSD / ISC / Zlib — most permissive deps
- Retain copyright notices and license text in distributed documentation.

### Recommended deliverable
Bundle a `licenses/` directory containing the full license text of:
GPL-2.0, LGPL-2.1, Apache-2.0, MPL-2.0, BSD-2-Clause, BSD-3-Clause, MIT, ISC,
Zlib — alongside this list. The pinned source repositories referenced in
`setup.sh` constitute the corresponding source for the GPL/LGPL obligations.

---

*This list reflects the dependency set as pinned at generation time. Re-run the
license scan after changing any pinned SHA in `setup.sh` or `TERMSHARK_SHA` in
`upgrade-tshark-by-termshark.sh`.*
