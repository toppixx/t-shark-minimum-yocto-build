# TShark aarch64 — Static Build with EtherCAT Support

**Wireshark 4.2.x · ARMv8-A (aarch64) · Fully static · EtherCAT built-in**

---

## Package Contents

| File | Size | Description |
|------|------|-------------|
| `tshark` | ~84 MB | Network analyser binary — fully static, no library dependencies |
| `dumpcap` | ~2.3 MB | Packet capture helper — must live in the same directory as tshark |
| `BUILD_INFO.txt` | — | Build metadata and SHA256 checksums |
| `tshark.sha256` | — | SHA256 of the tshark binary |
| `dumpcap.sha256` | — | SHA256 of the dumpcap binary |

> **No shared libraries, no plugin directories, no Wireshark data files are
> required.** All protocol dissectors (including the full EtherCAT suite) are
> compiled directly into the binary.

---

## Installation

### 1 — Copy both files to the same directory

`tshark` locates `dumpcap` by reading `/proc/self/exe` to discover its own
path, then looking for `dumpcap` in **the exact same directory**.  
If the two binaries are separated, live capture fails with:

```
tshark: Couldn't run dumpcap in child process: No such file or directory
```

```sh
# Install to /usr/bin (or any directory on the target)
cp tshark dumpcap /usr/bin/
chmod +x /usr/bin/tshark /usr/bin/dumpcap
```

Extract directly from the archive:

```sh
tar -xzf tshark-aarch64-v4.2.14-static.tar.gz -C /usr/bin/ --strip-components=1
```

### 2 — Verify integrity

```sh
sha256sum -c tshark.sha256
sha256sum -c dumpcap.sha256
```

### 3 — Set permissions

**Option A — Run as root** (simplest on embedded targets):

```sh
sudo ./tshark -i eth0
# or just root on a minimal Yocto system
./tshark -i eth0
```

**Option B — Run as non-root using Linux capabilities**:

```sh
# Grant dumpcap the right to capture packets without root
setcap cap_net_raw,cap_net_admin+eip /usr/bin/dumpcap

# tshark can now be run by any user
./tshark -i eth0
```

**Option C — Add user to a capture group** (common Wireshark pattern):

```sh
groupadd wireshark
chown root:wireshark /usr/bin/dumpcap
chmod 750 /usr/bin/dumpcap
setcap cap_net_raw,cap_net_admin+eip /usr/bin/dumpcap
usermod -aG wireshark $USER
```

---

## Basic Commands

### List network interfaces

```sh
./tshark -D
```

Example output:
```
1. eth0
2. any
3. lo (Loopback)
```

### Check version

```sh
./tshark --version
```

### Read a pcap or pcapng file

Reading files does **not** require `dumpcap`:

```sh
./tshark -r capture.pcap
./tshark -r capture.pcapng
```

---

## EtherCAT Capture

EtherCAT uses Ethernet type `0x88A4`.

### Live capture — capture everything on an interface

```sh
./tshark -i eth0
```

### Live capture — filter to EtherCAT frames only (BPF capture filter)

Using a BPF capture filter reduces CPU load — non-EtherCAT frames are
discarded in the kernel before reaching tshark:

```sh
./tshark -i eth0 -f "ether proto 0x88a4"
```

### Live capture to a file for later analysis

```sh
./tshark -i eth0 -f "ether proto 0x88a4" -w /tmp/ethercat.pcap
```

Stop with `Ctrl+C`. The file can then be analysed offline with `tshark -r`.

### Live capture with rolling file (ring buffer)

Capture in 10 MB chunks, keep 5 files (50 MB total), rotate continuously:

```sh
./tshark -i eth0 -f "ether proto 0x88a4" \
    -b filesize:10000 -b files:5 \
    -w /tmp/ecat_ring.pcap
```

### Capture for a fixed duration or packet count

```sh
# Stop after 30 seconds
./tshark -i eth0 -f "ether proto 0x88a4" -a duration:30 -w /tmp/ecat_30s.pcap

# Stop after 10 000 packets
./tshark -i eth0 -f "ether proto 0x88a4" -c 10000 -w /tmp/ecat_10k.pcap
```

---

## EtherCAT Analysis — Display Filters (`-Y`)

Display filters are applied after capture (or when reading files). They use
Wireshark's dissector field names, not BPF syntax.

### Show all EtherCAT frames

```sh
./tshark -r capture.pcap -Y "ethercat"
```

### Show EtherCAT datagram layer only

```sh
./tshark -r capture.pcap -Y "ecat"
```

### Filter by EtherCAT command type

| Command | Filter |
|---------|--------|
| LRW (Logical Read/Write) | `ecat.cmd == 12` |
| LRD (Logical Read) | `ecat.cmd == 10` |
| LWR (Logical Write) | `ecat.cmd == 11` |
| FPRD (Configured Address Read) | `ecat.cmd == 4` |
| FPWR (Configured Address Write) | `ecat.cmd == 5` |
| BRD (Broadcast Read) | `ecat.cmd == 7` |
| BWR (Broadcast Write) | `ecat.cmd == 8` |
| APRD (Auto Increment Read) | `ecat.cmd == 1` |
| APWR (Auto Increment Write) | `ecat.cmd == 2` |

```sh
# Show only LRW (process data)
./tshark -r capture.pcap -Y "ecat.cmd == 12"

# Show only write commands
./tshark -r capture.pcap -Y "ecat.cmd == 11 or ecat.cmd == 5 or ecat.cmd == 8 or ecat.cmd == 2"
```

### Filter by slave address

```sh
# Datagrams targeting configured address 1003
./tshark -r capture.pcap -Y "ecat.adp == 1003"

# Datagrams targeting auto-increment address 0
./tshark -r capture.pcap -Y "ecat.adp == 0 and ecat.cmd == 1"
```

### EtherCAT Mailbox protocols

```sh
# All mailbox traffic (CoE, FoE, EoE, SoE, AoE)
./tshark -r capture.pcap -Y "ecat_mailbox"

# CANopen over EtherCAT (CoE) — SDO and PDO
./tshark -r capture.pcap -Y "ecatcoe"

# File Access over EtherCAT (FoE)
./tshark -r capture.pcap -Y "ecatfoe"

# Ethernet over EtherCAT (EoE)
./tshark -r capture.pcap -Y "ecateoe"
```

### Filter on working counter

The Working Counter (WC) indicates how many slaves processed a datagram.
A WC of 0 means no slave responded:

```sh
# Find datagrams with zero working counter (slave not responding)
./tshark -r capture.pcap -Y "ecat.wkc == 0 and ecat.cmd != 0"
```

---

## Field Extraction (`-T fields -e`)

Extract specific fields as tab-separated values — useful for scripting and
log analysis. Combine with `-E` to control output format.

### Frame number, timestamp, source, destination

```sh
./tshark -r capture.pcap -Y "ethercat" \
    -T fields \
    -e frame.number \
    -e frame.time_relative \
    -e eth.src \
    -e eth.dst
```

### EtherCAT command, address, length, working counter

```sh
./tshark -r capture.pcap -Y "ecat" \
    -T fields \
    -e frame.number \
    -e ecat.cmd \
    -e ecat.adp \
    -e ecat.ado \
    -e ecat.len \
    -e ecat.wkc \
    -E header=y \
    -E separator=,
```

### Extract with CSV header to a file

```sh
./tshark -r capture.pcap -Y "ecat" \
    -T fields \
    -e frame.number \
    -e frame.time_epoch \
    -e ecat.cmd \
    -e ecat.adp \
    -e ecat.ado \
    -e ecat.len \
    -e ecat.wkc \
    -E header=y \
    -E separator=, \
    > /tmp/ecat_fields.csv
```

### Extract CoE SDO data

```sh
./tshark -r capture.pcap -Y "ecatcoe" \
    -T fields \
    -e frame.number \
    -e ecatcoe.type \
    -e ecatcoe.sdoccs \
    -e ecatcoe.index \
    -e ecatcoe.subindex \
    -E header=y
```

---

## Output Formats (`-T`)

| Format | Flag | Use case |
|--------|------|----------|
| Human-readable text | `-T text` (default) | Console output, quick inspection |
| JSON | `-T json` | Integration with logging systems |
| JSON (Ek/Elasticsearch) | `-T ek` | Elasticsearch / OpenSearch ingestion |
| PDML (XML) | `-T pdml` | Full decode, interop with other tools |
| Tab-separated fields | `-T fields` | Scripting, CSV export |
| Packet summary only | `-T tabs` | Quick summary |

### JSON output

```sh
./tshark -r capture.pcap -Y "ethercat" -T json | head -50
```

### JSON for a specific field subset

```sh
./tshark -r capture.pcap -Y "ecat" -T json \
    -e ecat.cmd -e ecat.adp -e ecat.wkc \
    | python3 -m json.tool
```

### PDML (full XML decode)

```sh
./tshark -r capture.pcap -Y "ethercat" -T pdml > /tmp/ecat.pdml
```

---

## Combining Capture and Display Filters

BPF capture filter (`-f`) and display filter (`-Y`) can be combined.
The BPF filter runs in the kernel (fast); the display filter runs on matching
frames in tshark (flexible):

```sh
# Capture only EtherCAT (fast BPF), display only LRW datagrams (display filter)
./tshark -i eth0 \
    -f "ether proto 0x88a4" \
    -Y "ecat.cmd == 12"
```

---

## Statistics

### Protocol hierarchy

```sh
./tshark -r capture.pcap -q -z io,phs
```

### EtherCAT command distribution

```sh
./tshark -r capture.pcap -q -z "plen,tree"
```

### Packet rate and bytes per second

```sh
./tshark -r capture.pcap -q -z io,stat,1,"ethercat"
```

### Conversations

```sh
./tshark -r capture.pcap -q -z eth,conv
```

---

## Verbose / Detailed Decode

```sh
# Single-line summary per packet (default)
./tshark -r capture.pcap -Y "ethercat"

# Full field decode for each packet
./tshark -r capture.pcap -Y "ethercat" -V

# Full decode, first 5 packets only
./tshark -r capture.pcap -Y "ethercat" -V -c 5
```

---

## Troubleshooting

### `Couldn't run dumpcap in child process: No such file or directory`

`dumpcap` is not in the same directory as `tshark`. Fix:

```sh
# Confirm both are together
ls -la $(dirname $(readlink -f ./tshark))/dumpcap

# Copy dumpcap to the same location
cp /path/to/dumpcap $(dirname $(readlink -f ./tshark))/
```

### `Permission denied` / `you don't have permission to capture on that device`

Either run as root, or grant capabilities to dumpcap:

```sh
setcap cap_net_raw,cap_net_admin+eip $(which dumpcap)
```

### `Running as user "root" and group "root". This could be dangerous.`

This is a warning, not an error. tshark still works. On a minimal embedded
system running as root is common and acceptable.

### No EtherCAT frames seen during live capture

1. Confirm the EtherCAT master is running and sending frames.
2. Use a BPF filter to reduce noise: `-f "ether proto 0x88a4"`.
3. Verify the correct interface: `./tshark -D` then try `-i eth1` etc.
4. Check with a raw capture first: `./tshark -i eth0 -c 100 -w /tmp/raw.pcap`,
   then inspect offline: `./tshark -r /tmp/raw.pcap`.

### Binary reports glibc version mismatch

The binary uses glibc static linking and is self-contained. It does not
require any specific glibc version on the target. If you see symbol errors,
confirm the kernel version is ≥ 3.7 (shown in `file tshark` output).

---

## EtherCAT Filter Quick Reference

```
ethercat                      All EtherCAT frames
ecat                          EtherCAT datagram layer
ecat.cmd == 12                LRW (process data read/write)
ecat.cmd == 10                LRD (process data read)
ecat.cmd == 11                LWR (process data write)
ecat.cmd == 4                 FPRD (slave register read)
ecat.cmd == 5                 FPWR (slave register write)
ecat.adp == <addr>            Specific slave configured address
ecat.wkc == 0                 Zero working counter (no slave response)
ecat_mailbox                  All mailbox traffic
ecatcoe                       CANopen over EtherCAT (CoE)
ecatfoe                       File Access over EtherCAT (FoE)
ecateoe                       Ethernet over EtherCAT (EoE)
```

---

*Built with Wireshark 4.2.14 · aarch64 · statically linked · EtherCAT built-in*
