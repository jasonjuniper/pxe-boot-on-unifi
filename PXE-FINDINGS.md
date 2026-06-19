# PXE Boot on UniFi — Research Findings & Fix Plan

**Date:** 2026-06-19
**Author:** Claude (Juniper AI)
**Status:** ⚠️ UNRESOLVED — TFTP has never logged a single connection. UEFI HTTPS Boot TLS blocked. Root cause narrowed: EFG IS delivering Option 67 (confirmed); leading suspects are Option 60 mismatch (HTTPClient echo confusing PXEBOOT clients) and STP convergence delay on Port 21.

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

### UniFi DHCP (current state)

| Setting | Value |
|---|---|
| `dhcpd_boot_enabled` | `True` |
| `dhcpd_boot_filename` | `https://192.168.5.141/shimx64.efi` |
| `dhcpd_boot_server` | `192.168.5.141` |
| Option 60 | `HTTPClient` (echo) |

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

#### 1. Standard PXE (PXEBOOT entry) — TFTP has never received a single connection

- tftpd64 has been running throughout every session
- **Zero TFTP connections ever logged, on any machine** — not one packet
- Tried with PXEBOOT mode on ThinkPad
- Windows Firewall disabled on pc-deploy — not a firewall issue
- Fixing tftpd64 competing DHCP (Services=15 → Services=1) did not help
- **No explanation found for why TFTP traffic never arrives at pc-deploy**

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

### Hypothesis 3: EFG echoes `HTTPClient` in Option 60 for ALL clients — breaks PXEBOOT

This is the **new leading hypothesis** for why TFTP never connects.

**Background:** The UniFi DHCP is configured with Option 60 echo = `HTTPClient`. This tells
UEFI firmware the DHCP response is for UEFI HTTP Boot, not standard TFTP PXE.

**The problem:** The ThinkPad's PXEBOOT entry sends `PXEClient` in its DHCP Discover (Option 60).
If the EFG echoes `HTTPClient` back unconditionally (regardless of what the client sent), the
UEFI TFTP stack sees an incompatible vendor class and may:
- Reject the DHCP offer entirely (no PXE option acknowledged)
- Interpret Option 67 as a URL instead of a TFTP filename and try HTTP boot — which then fails
  on TLS, exactly as the HTTPSBOOT entry does

**Why this would explain zero TFTP connections:**
- PXEBOOT client expects `PXEClient` echoed back → receives `HTTPClient` → ignores the offer
- No TFTP request is ever sent → tftpd64 sees nothing → machine falls through to NVMe

**Why changing http:// to https:// made no difference:** If the PXEBOOT client ignores the offer
entirely due to Option 60 mismatch, the URL value is irrelevant.

**The fix:** Remove the Option 60 `HTTPClient` echo from UniFi DHCP, OR switch to a DHCP server
(dnsmasq) that echoes back the same Option 60 the client sent.

**How to verify:** pktmon capture on pc-deploy — if DHCP ACK contains Option 60 = `HTTPClient`
for a PXEBOOT client request, this hypothesis is confirmed.

---

### Hypothesis 2: STP on the UniFi Core Switch dropping PXE traffic

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

## Proposed Next Diagnostic Steps (in priority order)

1. **pktmon capture on pc-deploy during ThinkPad PXEBOOT attempt** — definitive test
   - Boot ThinkPad with PXEBOOT entry selected (not HTTPSBOOT)
   - Capture on pc-deploy: `pktmon start --etw -p 0 --comp nics; pktmon filter add -p 67; pktmon filter add -p 68; pktmon filter add -p 69`
   - Stop after boot attempt: `pktmon stop`
   - Inspect the DHCP ACK: does Option 60 say `HTTPClient` or `PXEClient`?
   - Any UDP/69 packets arriving from ThinkPad IP?

2. **Test: remove Option 60 = HTTPClient from UniFi DHCP** — try with PXEBOOT
   - If Option 60 echo is the problem, removing it may unblock standard TFTP PXE

3. **Check Port 21 STP / Edge Port setting in UniFi** — low risk, high leverage
   - UniFi → Switches → USW Pro 48 PoE → Port 21 → enable Edge Port (PortFast)
   - This eliminates STP convergence delay as a cause

4. **Manual TFTP test from ThinkPad** — bypass BIOS entirely
   - Boot into WinPE via USB
   - Run: `tftp -i 192.168.5.141 GET shimx64.efi test.efi`
   - If this succeeds → TFTP server and network path are fine; BIOS is the problem
   - If this fails → TFTP server or firewall issue

5. **Check ThinkPad BIOS → Network for TLS Auth Configuration menu** — for HTTPSBOOT path
   - If present, this is the correct path to enroll the Juniper PXE TLS CA cert
   - Path on ThinkSystem/ThinkEdge: `Network → TLS Auth Configuration → Server CA Configuration → Enroll Cert`

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

*Juniper Design internal documentation — updated 2026-06-19*
