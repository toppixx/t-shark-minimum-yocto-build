# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Planning & Confidence Protocol

**Before executing any task**, Claude Code must follow this protocol — no exceptions:

1. **Clarify requirements first.** Ask the user targeted questions to resolve ambiguities: target version, desired flags, acceptable trade-offs, constraints not obvious from context.
2. **Estimate confidence.** After each round of clarification, internally assess confidence in understanding the task (0–100%). Continue asking until ≥ 95% confidence is reached.
3. **Present a written plan.** Once confidence ≥ 95%, write out a concise step-by-step plan and ask for explicit approval before touching anything.
4. **Get approval, then act.** Only proceed with execution after the user confirms the plan. If the user requests changes to the plan, revise it and confirm again.

**Confidence self-assessment criteria** — consider each dimension:
- Target (what exactly must be built/changed)
- Scope (what is in/out of scope)
- Constraints (versions, flags, paths, network limits)
- Success criteria (how to verify the result)
- Risks (what could go wrong and how to recover)

If confidence in *any* dimension is below 95%, ask a follow-up question targeting that specific gap before proceeding.

**Example interaction flow:**
```
User: "Build tshark for ARMv7"
Agent: [asks about version, hard-float vs soft-float, output path, stripped binary?]
User: [answers]
Agent: [if still < 95% on a dimension, asks another targeted question]
User: [answers]
Agent: [confidence ≥ 95% → presents plan → waits for approval]
User: "Looks good, proceed"
Agent: [executes]
```

## Overview

This repo is a **devcontainer-based build environment** for cross-compiling TShark to ARMv7. Claude Code runs inside the container and drives the entire build process. There is no pre-existing tshark source here — the task is to fetch, configure, and build it.

## Devcontainer

The container (`debian:bookworm`, user `node`) has all build dependencies pre-installed:

- **Toolchain**: `build-essential`, `cmake`, `ninja-build`, `flex`, `bison`
- **TShark libs**: `libglib2.0-dev`, `libpcap-dev`, `libgcrypt-dev`, `libssl-dev`, `libc-ares-dev`, `libzstd-dev`, `liblz4-dev`, `libsnappy-dev`, `libbrotli-dev`, `libnl-3-dev`, `zlib1g-dev`
- **Paths**: workspace at `/workspace`, build output volume at `/build/output`

## Network Restrictions

The container runs with a strict iptables firewall (`init-firewall.sh`). Outbound access is limited to:

- GitHub IP ranges (web, API, git)
- `registry.npmjs.org`
- `api.anthropic.com`
- `sentry.io`, `statsig.anthropic.com`, `statsig.com`
- VSCode marketplace/update endpoints, `playwright.azureedge.net`, `skill.fish`

Fetching tshark source must go through GitHub (e.g., `github.com/wireshark/wireshark`). Direct downloads from wireshark.org or other domains will fail.

## Build Output

Built artifacts must be placed in `/build/output`, which is a persistent Docker volume (`tshark-build-output`) shared across container rebuilds. Claude Code config is persisted in `/home/node/.claude` (volume `tshark-builder-config-*`).

## Typical Build Flow

1. Clone Wireshark source from GitHub into `/workspace`
2. Configure a CMake cross-compile build targeting ARMv7 (`-DCMAKE_SYSTEM_PROCESSOR=armv7` or a toolchain file)
3. Build only the `tshark` target (not the full Wireshark GUI) to minimize build time and dependencies
4. Copy output binary/libraries to `/build/output`

CMake out-of-source build pattern:
```bash
cmake -G Ninja -B /workspace/build -S /workspace/wireshark \
  -DBUILD_wireshark=OFF -DBUILD_tshark=ON \
  <cross-compile flags>
cmake --build /workspace/build --target tshark
```
