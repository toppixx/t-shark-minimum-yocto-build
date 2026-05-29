# Termshark aarch64 — Terminal UI for TShark

**Termshark 2.4.0 · ARMv8-A (aarch64) · Fully static (pure Go, CGO disabled)**

Termshark is a Wireshark-inspired terminal user interface that drives `tshark`
and `dumpcap` under the hood. It provides interactive packet browsing, filtering,
and decoding — including the full EtherCAT dissector suite — directly in a
text terminal, with no X server or GUI required.

---

## Requirements

Termshark is **not standalone** — it launches `tshark` and `dumpcap` as child
processes. All three binaries must be installed and reachable:

| Binary | Role |
|--------|------|
| `termshark` | Terminal UI front-end |
| `tshark` | Packet dissection engine (invoked by termshark) |
| `dumpcap` | Live capture helper (invoked by tshark) |

Termshark finds `tshark` via `$PATH`. `tshark` finds `dumpcap` in its own
directory. The simplest correct layout is **all three in the same directory
that is on `$PATH`** (e.g. `/usr/bin`).

---

## Installation

```sh
# Extract all three binaries into a directory on PATH
tar -xzf tshark-aarch64-*-termshark-*-static.tar.gz -C /usr/bin/ --strip-components=1
chmod +x /usr/bin/termshark /usr/bin/tshark /usr/bin/dumpcap

# Verify
termshark --help | head -1      # -> termshark v2.4.0
tshark --version | head -1      # -> TShark (Wireshark) 4.2.14
```

If you keep the binaries in a non-PATH directory, point termshark at tshark
explicitly:

```sh
export TERMSHARK_TSHARK=/opt/ts/tshark
/opt/ts/termshark -r capture.pcap
```

---

## Permissions

Same as tshark — live capture needs raw-socket access.

```sh
# Option A: run as root (typical on embedded targets)
termshark -i eth0

# Option B: grant capabilities to dumpcap, then run as any user
setcap cap_net_raw,cap_net_admin+eip /usr/bin/dumpcap
termshark -i eth0
```

---

## Usage

### Live capture (interactive TUI)

```sh
# Open the TUI capturing all traffic on eth0
termshark -i eth0

# Capture only EtherCAT frames (BPF capture filter)
termshark -i eth0 -f "ether proto 0x88a4"
```

### Analyse an existing capture file

```sh
termshark -r capture.pcap
termshark -r capture.pcapng
```

### Open with a display filter pre-applied

```sh
# Show only EtherCAT frames
termshark -r capture.pcap -Y "ethercat"

# Show only EtherCAT mailbox (CoE/FoE/EoE) traffic
termshark -r capture.pcap -Y "ecat_mailbox"

# Live capture, pre-filtered to LRW process-data datagrams
termshark -i eth0 -f "ether proto 0x88a4" -Y "ecat.cmd == 12"
```

---

## Keyboard Navigation

Once inside the TUI:

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move between packets |
| `Enter` | Expand / focus the selected packet's detail pane |
| `Tab` | Cycle between the packet list, detail, and hex panes |
| `/` | Edit the display filter |
| `PgUp` / `PgDn` | Scroll a page at a time |
| `Home` / `End` | Jump to first / last packet |
| `c` | Switch colour scheme |
| `|` | Toggle the layout (stacked / side-by-side) |
| `?` | Show the full keybinding help |
| `q` | Quit |

The display-filter bar (opened with `/`) accepts the same Wireshark display
filter syntax as `tshark -Y`, e.g. `ecat.cmd == 12 && ecat.wkc == 0`.

---

## EtherCAT in Termshark

All EtherCAT dissectors compiled into `tshark` are available in termshark's
detail pane and display-filter bar:

```
ethercat            EtherCAT frame
ecat                EtherCAT datagram (cmd, adp, ado, len, wkc)
ecat_mailbox        Mailbox layer
ecatcoe             CANopen over EtherCAT (CoE)
ecatfoe             File Access over EtherCAT (FoE)
ecateoe             Ethernet over EtherCAT (EoE)
```

Type any of these into the filter bar (`/`) to narrow the packet list live.

---

## Configuration & State

Termshark writes its config and temporary files under the invoking user's home:

| Path | Purpose |
|------|---------|
| `~/.config/termshark/termshark.toml` | Persisted settings (colours, layout) |
| `~/.cache/termshark/` | Temporary pcap fragments during live capture |

On a minimal Yocto rootfs ensure `$HOME` is set and writable. To relocate:

```sh
export XDG_CONFIG_HOME=/var/lib/termshark/config
export XDG_CACHE_HOME=/var/lib/termshark/cache
```

---

## Troubleshooting

### `termshark: didn't find tshark in your PATH`

`tshark` is not on `$PATH`. Either add its directory to `$PATH`, or set
`TERMSHARK_TSHARK=/full/path/to/tshark`.

### Live capture shows no packets / permission denied

`dumpcap` lacks capture privileges. Run as root, or
`setcap cap_net_raw,cap_net_admin+eip /usr/bin/dumpcap`.

### `Couldn't run dumpcap in child process`

`dumpcap` is not in the same directory as `tshark`. Co-locate them.

### Garbled display / wrong colours

Set a sane terminal type before launching:

```sh
export TERM=xterm-256color
termshark -r capture.pcap
```

### Termshark hangs at "Loading…" on a slow target

Large captures are decoded incrementally by tshark. On low-power aarch64
hardware, pre-filter to reduce the working set:

```sh
termshark -r big.pcap -Y "ethercat"
```

---

*Termshark 2.4.0 · aarch64 · pure-Go static binary · drives the bundled tshark/dumpcap*
