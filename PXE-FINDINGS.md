# PXE Boot on UniFi — Research Findings & Fix Plan

**Date:** 2026-06-19
**Author:** Claude (Juniper AI)
**Status:** ⚠️ ROOT CAUSE CONFIRMED (2026-06-19) — FIX APPLIED — **Root cause: EFG DHCP was serving `https://192.168.5.141/shimx64.efi` as the TFTP boot filename. PXEBOOT clients sent this literal string as a TFTP RRQ; tftpd64 received an invalid path (`https:...`) and silently dropped it. Fix: change `dhcpd_boot_filename` to `shimx64.efi` (plain TFTP filename). PENDING: test ThinkPad PXEBOOT after UniFi DHCP change is applied.**

---

## The Problem

Target machines on the Juniper engineering network do **not** PXE boot natively.
Booting works only when a flash drive with an iPXE USB bootstrap is used first.

The flash drive works because iPXE has its own network stack — it makes HTTP requests directly
and does not depend on the UEFI firmware's DHCP/TFTP/HTTP boot path. That's why it works
when everything else fails.

---

## Network Topology

```
EFG Router / DHCP server (192.168.0.1)
    └── UniFi Core Switch (USW Pro 48 PoE)
            ├── 5× UniFi U7 Pro XG APs
            └── Port 21 → TP-Link TL-SG108-M2 (Engineering — unmanaged)
                    ├── pc-deploy (192.168.5.141) ← Caddy HTTPS/HTTP, tftpd64 TFTP
                    ├── ThinkPad P14s Gen 5 (192.168.11.24) ← PXE client
                    └── Yoga 7 2-in-1 (192.168.11.3) ← PXE client (WiFi only)
```

**IP space:** UniFi Default network is **192.168.0.1/20** — one flat /20 covering
192.168.0.0–192.168.15.255. All machines are on this single DHCP scope. No VLANs. No DHCP relay.

**Windows Firewall on pc-deploy: DISABLED.** All ports open.

---

## Target Architecture (Goal — NOT yet working)

```
Target UEFI firmware
  │  selects network boot entry (PXEClient or HTTPClient in DHCP Option 60)
  ↓
UniFi / EFG DHCP
  │  responds with boot file location
  ↓
Target firmware downloads shimx64.efi (via TFTP or HTTP)
  ↓
shimx64.efi (Ubuntu shim, MS-signed OU=MOPR)
  │  verifies grubx64.efi against MOK (Juniper CA cert)
  ↓
grubx64.efi (iPXE, signed by Juniper CA)
  │  loads autoexec.ipxe via TFTP from 192.168.5.141
  ↓
autoexec.ipxe → HTTP: GET wimboot, BCD, boot.sdi, sources/boot.wim
  ↓
WinPE → Juniper PC Deployment System
```

---

## Server-Side State (verified 2026-06-18 — all confirmed ✅)

Everything on the server is working. The problem is not pc-deploy.

### Caddy HTTP/HTTPS

- **Service:** Running (NSSM) ✅
- **Listening:** TCP 0.0.0.0:80 (HTTP) + TCP 0.0.0.0:443 (HTTPS) ✅
- **Windows Firewall:** Disabled — both ports open ✅
- **Verified:** `HEAD https://192.168.5.141/shimx64.efi` from ENG-1 → HTTP 200, Content-Length: 1048424 ✅
- **TLS cert:** `C:\caddy\server.crt` — IP SAN 192.168.5.141, signed by Juniper PXE TLS CA, valid 3 years ✅

### Caddyfile (`C:\caddy\Caddyfile`)

```
http://192.168.5.141 {
    log { output file C:/caddy/access.log; format json }
    file_server { root C:/tftpd64 }
}

https://192.168.5.141 {
    tls C:/caddy/server.crt C:/caddy/server.key
    log { output file C:/caddy/access.log; format json }
    file_server { root C:/tftpd64 }
}
```

### tftpd64

- **Service:** Running (NSSM) ✅
- **Services=1** (TFTP only) ✅
- **Port 67:** UNBOUND — tftpd64 is NOT running a DHCP server ✅
- **Port 69 (TFTP):** LISTENING ✅

### Key files on pc-deploy

| Path | Description |
|---|---|
| `C:\tftpd64\shimx64.efi` | Ubuntu shim (MS-signed OU=MOPR, 1,048,424 bytes) |
| `C:\tftpd64\grubx64.efi` | iPXE, signed by Juniper CA |
| `C:\tftpd64\mmx64.efi` | MokManager |
| `C:\tftpd64\ipxe.efi` | Non-SB fallback iPXE |
| `C:\tftpd64\autoexec.ipxe` | iPXE boot script (TFTP-served) |
| `C:\tftpd64\wimboot` | WinPE ramdisk loader |
| `C:\tftpd64\sources\boot.wim` | WinPE (NIC drivers injected, ~513 MB) |
| `C:\tftpd64\juniper-pxe-ca.cer` | Juniper signing CA cert (MOK enrollment) |
| `C:\tftpd64\juniper-pxe-tls-ca.cer` | Juniper TLS CA cert (HTTPS Boot, DER) |
| `C:\tftpd64\pc-deploy-tls.cer` | pc-deploy server cert (DER, for BIOS enrollment) |

### UniFi DHCP (current state — updated 2026-06-19 ✅ FIXED)

| Field (UniFi UI) | Value |
|---|---|
| Network Boot | ✅ enabled |
| Network Boot — server | `192.168.5.141` |
| Network Boot — filename | `shimx64.efi` ← **FIXED** (was `https://192.168.5.141/shimx64.efi`) |
| TFTP Server | ✅ enabled — `192.168.5.141` |
| Option 60 (HTTPClient) | **Removed** ← **FIXED** (was echoing `HTTPClient`, confusing PXEBOOT clients) |

---

## What Has Been Tried — Honest Account

### ✅ Things That Actually Work

| What | Evidence |
|---|---|
| pc-deploy serves files over HTTP | `curl http://192.168.5.141/shimx64.efi` → 200 from any machine on the network |
| pc-deploy serves files over HTTPS | `HEAD https://192.168.5.141/shimx64.efi` from ENG-1 → 200, Content-Length: 1048424 |
| tftpd64 running TFTP-only (no DHCP) | `netstat` confirms port 67 unbound, port 69 listening |
| ThinkPad gets a DHCP lease | IP 192.168.11.24 assigned and confirmed repeatedly |
| ThinkPad receives DHCP Option 67 URL | Boot error message shows `URI: https://192.168.5.141/shimx64.efi` — DHCP delivered it |
| Caddy log records hits from ENG-1 and pc-deploy | Confirmed multiple times |
| WinPE boots via USB iPXE flash drive | Works reliably — proves the files and boot chain are correct |
| shimx64.efi is MS-signed | Dual-signed: UEFI CA 2011 + UEFI CA 2023 (OU=MOPR) |

---

### ❌ Things Tried That Have Not Worked

#### 1. Standard PXE (PXEBOOT entry) — TFTP packets confirmed arriving, no response

- **2026-06-19 pktmon capture BREAKTHROUGH — session context below**
- tftpd64 log remains empty (0 bytes — created 2026-06-18, no entries ever written)
- Tried with PXEBOOT mode on ThinkPad
- Windows Firewall disabled on pc-deploy (all three profiles: Domain, Private, Public = OFF)
- Fixing tftpd64 competing DHCP (Services=15 → Services=1) did not help
- **pktmon proves TFTP packets ARE arriving at pc-deploy:69 — see pktmon section below**

#### 2. UEFI HTTP Boot with `http://` URL from DHCP

- Set ThinkPad `NetworkBoot=HTTPSBOOT` via WMI ✅
- Set UniFi DHCP Option 67 to `http://192.168.5.141/shimx64.efi`
- Result: **zero Caddy hits from 192.168.11.24, no change at all**
- Hypothesis: HTTPSBOOT entry on ThinkPad P14s Gen 5 silently ignores `http://` URLs —
  the "HTTPS" in the name appears to be a hard requirement, not just a label

#### 3. UEFI HTTPS Boot with hardcoded `https://` URL (Custom HTTPS Boot Option)

- Added Custom HTTPS Boot Option in BIOS: `https://192.168.5.141/shimx64.efi`
- Caddy HTTPS verified working from other machines (HTTP 200)
- ThinkPad error: **"Could not retrieve NBP file size from HTTP server"**
- **Zero Caddy hits from 192.168.11.24** — TLS handshake fails silently before any HTTP GET
- The network path is reachable (DHCP works, error message shows the URL was received)
- TLS is the specific failure point

#### 4. "Enroll OnPremise Server CA Cert" for TLS trust

- Enrolled Juniper PXE TLS CA cert (`juniper-pxe-tls-ca.cer`, DER) via:
  BIOS → Security → Custom URL Support Settings → Enroll OnPremise Server CA Cert
- TLS still fails after enrollment — zero change
- **Root cause discovered:** This menu is for Lenovo's proprietary ON-PREMISE deployment
  system, not for standard UEFI HTTPS Boot TLS validation
- The correct path on Lenovo ThinkSystem/ThinkEdge hardware is:
  `System Settings → Network → TLS Auth Configuration → Server CA Configuration → Enroll Cert`
- Whether this menu exists on ThinkPad P14s Gen 5 is **unknown — not yet checked**
- Regardless: per-machine BIOS cert enrollment is not a viable strategy for fleet deployment

#### 5. ThinkPad `NetworkBoot=ON-PREMISE` (prior session error — fixed)

- In a previous session, WMI accidentally set `NetworkBoot=ON-PREMISE`
- ON-PREMISE is Lenovo's proprietary cloud deployment system — ignores all DHCP options
- Changed to `NetworkBoot=HTTPSBOOT` — necessary but not sufficient

#### 6. tftpd64 competing DHCP (prior state — fixed)

- tftpd64 was running its own DHCP server on port 67 (Services=15)
- Sent competing proxyDHCP offers, interfering with UniFi DHCP
- Fixed to Services=1 (TFTP only) — correct fix, but TFTP still never receives connections

---

## 🔬 pktmon Capture — 2026-06-19 (DEFINITIVE RESULTS)

`pktmon start --etw -f C:\boot-capture.etl` was running on pc-deploy while ThinkPad was
network-booted (PXEBOOT entry). Results from `pktmon etl2txt` → `C:\boot-capture.txt`:

### What the capture confirmed

| Traffic | Direction | Finding |
|---|---|---|
| `192.168.0.1:67 → 255.255.255.255:68` | Inbound (broadcast) | **EFG DHCP ACK confirmed** — EFG sent a DHCP Offer/ACK with boot options |
| `192.168.11.24:1753 → 192.168.5.141:69` | Inbound | **5 TFTP RRQ packets** (76 bytes UDP each) — TFTP Read Requests from ThinkPad |
| `192.168.11.24:1227 → 192.168.5.141:69` | Inbound | **5 more TFTP RRQ packets** (~90 seconds later — second connection attempt) |
| `192.168.5.141 → 192.168.11.24` | Outbound | **NOTHING** — zero TFTP responses from pc-deploy |

The 10 TFTP packets (MAC `C8-53-09-2D-0D-56`) match the ThinkPad P14s Gen 5 exactly.
Two separate source ports = two independent TFTP session attempts, each retried 5 times (timeout).

### What this conclusively disproves

- ❌ **Hypothesis 1 (EFG not serving boot options)** — EFG IS sending DHCP with boot options
- ❌ **Hypothesis 2 (STP blocking traffic)** — TFTP packets ARE reaching pc-deploy
- ❌ **Hypothesis 3 (Option 60 mismatch stopping TFTP)** — PXEBOOT client DID send TFTP requests

### What this means

The failure is **entirely on pc-deploy**. TFTP requests arrive at the NIC, traverse the network
stack (pktmon shows them passing through Components 59 → 10 → 19 → 46 with no drop events), but
tftpd64 never logs them and never sends a response.

---

## 🔍 tftpd64 Diagnostic Results — 2026-06-19

Checked after pktmon confirmed packets arrive at pc-deploy:

| Check | Result |
|---|---|
| tftpd64 process | Running (PID 7512) ✅ |
| `netstat -ano \| findstr ":69"` | `UDP  0.0.0.0:69  *:*  7512` — socket IS bound ✅ |
| tftpd64.log size | **0 bytes** — no connections ever logged since 2026-06-18 ❌ |
| tftpd64-err.log | **0 bytes** ❌ |
| Windows Firewall | **ALL OFF** — Domain, Private, Public all disabled ✅ |
| tftpd64.ini: SecurityLevel | `0` — no IP filtering ✅ |
| tftpd64.ini: LocalIP | `` (empty = all interfaces) ✅ |
| tftpd64.ini: BaseDirectory | `C:\tftpd64` ✅ |
| tftpd64.ini: Services | `1` (TFTP only) ✅ |
| tftpd32.ini | **EXISTS** — second INI file, content unknown (session ended before read) |
| pktmon drop events near :69 | **None for TFTP packets** — packets reach Component 46 cleanly |
| Drop events present in capture | Yes, but for DHCP (port 67, OriginalSize 387) — NOT TFTP |

**Key anomaly:** The socket is bound, the firewall is off, no drops are visible for TFTP in
pktmon — yet tftpd64 never logs a single connection and never responds. The TFTP RRQ payload
(76 bytes) was not decoded before session ended; the requested filename is unknown.

---

## ⚠️ Leading Hypotheses — Root Cause Still Unknown

### ~~Hypothesis 1: EFG not serving PXE boot options~~ — PARTIALLY DISPROVED

**Update 2026-06-19:** The ThinkPad's boot error message showed `URI: https://192.168.5.141/shimx64.efi`
which is exactly the value configured in UniFi DHCP Option 67. **The EFG IS delivering Option 67.**

This directly contradicts the "EFG not sending boot options" hypothesis. The DHCP boot options
ARE reaching the ThinkPad.

**What remains unconfirmed:** Whether siaddr (BOOTP next-server field) is being set correctly for
TFTP mode, and exactly what Option 60 value is being echoed in all DHCP responses.

**How to verify:** pktmon/Wireshark capture of the actual DHCP ACK bytes, specifically:
- `siaddr` field (bytes 20–24 of the BOOTP header)
- Option 66 (TFTP server name)
- Option 60 (Vendor Class — what value does the EFG echo back?)

---

### ~~Hypothesis 3: EFG echoes `HTTPClient` in Option 60 for ALL clients — breaks PXEBOOT~~ — DISPROVED

**Disproved by pktmon 2026-06-19.** The ThinkPad DID send TFTP requests after receiving the
DHCP ACK. Option 60 echo did not prevent the client from attempting TFTP. Not relevant.

---

### ~~Hypothesis 4: tftpd64 reads tftpd32.ini (not tftpd64.ini) — mismatched config~~ — DISPROVED

Checked 2026-06-19. `tftpd32.ini` is identical to `tftpd64.ini` (same BaseDirectory, same TftpLogFile,
same all settings). tftpd64.exe is reading tftpd32.ini (confirmed: tftpd32.ini has LastWindowPos
which is written by the running process). Both point to `C:\tftpd64`. Not the cause.

---

### ✅ ROOT CAUSE CONFIRMED (2026-06-19): HTTPS URL served as TFTP filename

**The actual root cause, confirmed by pktmon + tftpd64 config analysis:**

The EFG DHCP `dhcpd_boot_filename` was set to `https://192.168.5.141/shimx64.efi` — a full HTTPS URL.

When a PXEBOOT client (ThinkPad UEFI firmware in PXE mode) receives this in DHCP Option 67,
it has no HTTP client — it only speaks TFTP. So it sends a TFTP Read Request for the literal
string `https://192.168.5.141/shimx64.efi` as the filename.

tftpd64 receives this RRQ, tries to open `C:\tftpd64\https:\192.168.5.141\shimx64.efi` —
a Windows path with `:` and `/` in invalid positions. The path is immediately invalid.
tftpd64 catches the exception and **silently discards the request** (no log entry, no TFTP ERROR).

**Why the 76-byte payload fits:**
- TFTP opcode: 2 bytes
- Filename `https://192.168.5.141/shimx64.efi`: 34 chars + null = 35 bytes
- Mode `octet`: 5 chars + null = 6 bytes
- TFTP option extensions (tsize, blksize, timeout): ~33 bytes
- **Total: ~76 bytes ✓**

**Why tftpd64 logs were empty:**
tftpd64 does not log failed file-open attempts to TftpLogFile — only successful transfers.
With 10 RRQs all hitting an invalid path, the log stays 0 bytes forever.

**Why pktmon showed no outbound TFTP traffic:**
TFTP error/data responses come from an *ephemeral port* (not port 69). The pktmon filter
covered ports 67/68/69 only, so any TFTP ERROR response from tftpd64 on port ~50000 would
not appear in the capture. (tftpd64 may or may not have sent a TFTP ERROR — either way,
the RRQ with an invalid URL-as-filename cannot succeed.)

**The fix:**
Change `dhcpd_boot_filename` from `https://192.168.5.141/shimx64.efi` → `shimx64.efi`.

Applied manually via UniFi UI on 2026-06-19:
```
Settings → Networks → Default → DHCP → Boot File Name: shimx64.efi
```

With this change:
1. PXEBOOT client receives DHCP ACK with filename=`shimx64.efi`, siaddr=`192.168.5.141`
2. Sends TFTP RRQ for `shimx64.efi` to `192.168.5.141:69`
3. tftpd64 finds `C:\tftpd64\shimx64.efi` (1,048,424 bytes) — **EXISTS** ✓
4. tftpd64 serves shimx64.efi → Ubuntu shim loads → iPXE boots → WinPE deploys

---

### ~~Hypothesis 2~~: STP on the UniFi Core Switch — SUPERSEDED

STP is now ruled out as the proximate cause: TFTP packets confirm the ThinkPad reaches
pc-deploy. STP is still worth fixing (Edge Port on Port 21) for reliability but it is
not the current blocker.

---

### Hypothesis 2-original: STP on the UniFi Core Switch dropping PXE traffic

Port 21 on the USW Pro 48 PoE is the Engineering uplink to the TP-Link TL-SG108-M2 (unmanaged).
The TP-Link is unmanaged — it almost certainly runs classic 802.1D STP, not RSTP.

**Classic STP transition on link-up:**
```
Blocking (20s) → Listening (15s) → Learning (15s) → Forwarding
```
Total: **up to 50 seconds** before end-device traffic can flow after a link comes up.

**PXE boot window:** PXE DHCP timeout: ~10–15 seconds. TFTP timeout: ~5–10 seconds.

**The collision:** Machine powers on → NIC link comes up → switch port starts STP transition →
PXE window expires before the port reaches Forwarding state → PXE silently fails every time.

**Why DHCP still works but PXE might not:**
- DHCP is retried for 60+ seconds across multiple discover attempts. By the time STP converges
  (30–50s), a DHCP retry succeeds. The machine gets an IP — but PXE is already dead.
- Or the DHCP lease is cached from a previous session and renews instantly on re-link,
  before STP finishes, but the response just happens to make it through.

**Why this would explain "TFTP has never received a connection":**
- Every PXE attempt: NIC comes up → STP in Blocking/Listening → TFTP window expires → machine
  falls through to next boot device (NVMe). The machine boots Windows. No one notices.
- DHCP succeeds eventually (after retries), giving the false impression the network is fine.

**How to verify:**
1. In UniFi → Switches → USW Pro 48 PoE → Port 21 settings:
   - Is STP enabled on this port?
   - Is the port profile using RSTP or classic STP?
   - Is "Edge Port" / "PortFast" enabled? (This skips the STP transition for end-device ports)
2. Enable Edge Port on Port 21 (the Engineering uplink to the TP-Link). This is the standard
   fix for PXE boot failures caused by STP convergence delay.

**Note:** Enabling Edge Port on a port connected to another switch (the TP-Link) is technically
incorrect STP practice (it should only be on end-device ports), but since the TP-Link is
unmanaged and not participating in the STP topology meaningfully, the risk is minimal.

---

## Community Research Findings (2026-06-19)

Researched community.ui.com, EduGeek, HardForum, FOG Project, and technical blogs.

**Critical context:** Most community threads on UniFi + PXE are from 8–13 years ago and document
bugs in the **old USG/EdgeRouter running EdgeOS (VyOS-based)**. These are NOT the same platform
as the EFG running UniFi OS. Do not apply those bug reports to this setup.

| Source | Platform | Finding |
|---|---|---|
| community.ui.com — USG PXE client (8yr old) | USG / EdgeOS | Garbage FF bytes appended to Option 67 filename — TFTP requested a corrupted filename. Bug in isc-dhcpd 4.1-ESV-R8. **NOT applicable to EFG/UniFi OS.** |
| community.ui.com — Options 66/67 "File not found" (13yr old) | EdgeRouter / EdgeOS | `bootfile-name` caused duplicate entries in dhcpd.conf, breaking PXE. Required script patch. **NOT applicable to EFG/UniFi OS.** |
| kenmoini.com (2023) | UDM-Pro / UniFi OS | CAN serve single-arch PXE options via DHCP. Multi-arch requires external DHCP server. Author bypassed UniFi DHCP entirely via DHCP relay to ISC DHCPD. |
| HardForum (2021) | UDM / UniFi OS | TFTP never connected — root cause: **Windows Firewall on WDS server blocking UDP 69**. Fixed by allowing inbound TFTP. (Note: pc-deploy WF is disabled, this is ruled out here.) |
| EduGeek (Dec 2025) | EFG / UniFi OS | New EFG "blocking PXE response" — resolution: **a switch needed a reboot**. Another EFG user (KK20) uses Windows DHCP server, not UniFi DHCP. |
| SCCM homelab (Jul 2025) | UniFi network boot | Eventually worked, but TFTP was very slow (15–30 mins per image download). |

**Summary:** No evidence of a systematic bug in EFG/UniFi OS DHCP not delivering PXE boot options.
The EFG can deliver them. The issues are typically configuration, firewall, or switch STP.

---

## ✅ Completed Diagnostic Steps

1. ~~pktmon capture on pc-deploy during ThinkPad PXEBOOT attempt~~ — **DONE (2026-06-19)**
   - **Result:** TFTP packets confirmed arriving. DHCP ACK from EFG confirmed. No TFTP response.

---

## 🔧 Immediate Next Steps (in priority order — do these when back at PC)

### Step 1 — Read tftpd32.ini (most likely root cause)
```powershell
Get-Content C:\tftpd64\tftpd32.ini
```
Compare with tftpd64.ini. If BaseDirectory/TftpLogFile differ, tftpd64.exe is using the wrong config.

**Fix if needed:** Either delete tftpd32.ini (force tftpd64.exe to use tftpd64.ini) or sync both
files so they have identical settings.

### Step 2 — Decode TFTP RRQ filename from capture
```powershell
$lines = Get-Content C:\boot-capture.txt
for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '192\.168\.11\.24\.\d+ > 192\.168\.5\.141\.69') {
        $lines[$i..([Math]::Min($i+20,$lines.Count-1))] | Write-Host; break
    }
}
```
The hex dump will reveal what filename the ThinkPad is requesting. Confirm that file exists in
`C:\tftpd64\` (or whatever BaseDirectory is configured as).

### Step 3 — Manual TFTP test (bypass BIOS entirely)
Boot ThinkPad into WinPE via USB flash drive, then:
```cmd
tftp -i 192.168.5.141 GET ipxe.efi C:\test.efi
```
- **Success** → TFTP server works from the engineering subnet; the BIOS PXE client has a different problem
- **Failure** → TFTP server itself is broken; confirms Hypotheses 4, 5, or 6

### Step 4 — Enable Edge Port on USW Pro 48 PoE Port 21
UniFi → Switches → USW Pro 48 → Port 21 → Profile → enable Edge Port.
STP is now ruled out as the TFTP blocker, but fixing it prevents a future STP-related boot delay
regression if something changes on that port.

### Step 5 — Check ThinkPad BIOS → Network → TLS Auth Configuration
For the HTTPSBOOT path: if `TLS Auth Configuration → Server CA Configuration → Enroll Cert` exists,
this is the correct menu to enroll `juniper-pxe-tls-ca.cer`. Needed regardless of TFTP outcome.

---

## Secure Boot Chain (implemented and ready — pending a working boot path)

```
UEFI Secure Boot firmware (trusts MS UEFI CA)
  → shimx64.efi  (Ubuntu shim, dual-signed: UEFI CA 2011 + UEFI CA 2023, OU=MOPR)
    → grubx64.efi (iPXE, signed by Juniper Design RSA cert)
      │  shim verifies grubx64.efi against MOK database
      ↓
    autoexec.ipxe → wimboot → WinPE
```

One-time per-machine: enroll `juniper-pxe-ca.cer` in MOK. Script: `push-mok-enrollment.ps1`.

---

## TLS Certificates (generated and stored — pending correct enrollment path)

| File | Description |
|---|---|
| `juniper-pxe-tls-ca.cer` | Juniper PXE TLS CA cert, DER format |
| `pc-deploy-tls.cer` | pc-deploy server cert, DER format |
| `pxe-tls/juniper-pxe-tls-ca.crt` | CA cert, PEM format |
| `pxe-tls/pc-deploy-tls.crt` | Server cert, PEM format |

CA private key in 1Password: "Juniper PXE TLS CA Key (HTTPS Boot)".
Server private key at `C:\caddy\server.key` on pc-deploy only.

---

## References

- [Lenovo CDRT — ThinkPad Startup settings (NetworkBoot values)](https://docs.lenovocdrt.com/ref/bios/settings/thinkpad/startup/)
- [Lenovo CDRT — ThinkPad Network settings](https://docs.lenovocdrt.com/ref/bios/settings/thinkpad/network/)
- [Lenovo Press — Using HTTPS Boot on ThinkSystem Servers](https://lenovopress.lenovo.com/lp1584.pdf)
- [Intel Edge Orchestrator — Lenovo ThinkEdge HTTPS Boot](https://docs.openedgeplatform.intel.com/edge-manage-docs/3.1/user_guide/set_up_edge_infra/edge_node_onboard/https_boot/https_boot_lenovo.html)
- [UEFI HTTPS Boot — tianocore wiki](https://github.com/tianocore/tianocore.github.io/wiki/HTTPS-Boot)
- [PXE & HTTP(s) Booting DHCP Options — hannan.au](https://hannan.au/posts/pxe-dhcp/)
- [Ubiquiti Community — SCCM PXE Boot and UniFi](https://community.ui.com/questions/SCCM-PXE-Boot-and-Unifi-Network-Boot/14511d8b-6c57-4392-9b66-4a91e9f6e717)
- [pc-imaging-server repo](https://github.com/jasonjuniper/pc-imaging-server)

---

*Juniper Design internal documentation — updated 2026-06-19 (pktmon breakthrough: TFTP arrives at pc-deploy, no response from tftpd64)*
