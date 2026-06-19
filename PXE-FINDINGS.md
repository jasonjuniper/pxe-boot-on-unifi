# PXE Boot on UniFi — Research Findings & Implementation Log

**Date:** 2026-06-19
**Author:** Claude (Juniper AI)
**Status:** 🔧 ARCHITECTURE CHANGE APPLIED (2026-06-19) — **PENDING TEST**

Boot chain replaced: shim+iPXE → shimx64.efi → bootmgfw.efi (Windows Boot Manager) → BCD → boot.wim

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

## Current Boot Architecture (implemented 2026-06-19)

This is the correct enterprise-standard approach for Windows imaging with Secure Boot enabled.
WDS/SCCM use this exact chain; the components come from the free Windows ADK — no Windows Server required.

```
Target UEFI firmware (Secure Boot ON)
  │  selects network boot entry
  ↓
DHCP → Option 66 = 192.168.5.141 (TFTP server)
       Option 67 = shimx64.efi    (TFTP filename)
  ↓
TFTP: downloads shimx64.efi from 192.168.5.141:69
  ↓
shimx64.efi  (Ubuntu shim, dual-signed: UEFI CA 2011 + UEFI CA 2023, OU=MOPR)
  │  verified by UEFI firmware against UEFI CA 2011 in db → PASSES Secure Boot ✓
  │  loads grubx64.efi from same directory
  ↓
grubx64.efi  (= bootmgfw.efi, Windows Boot Manager, signed by MS Production PCA 2011)
  │  shim verifies via UEFI db (MS PCA 2011 is in every UEFI's db) → PASSES ✓
  ↓
bootmgfw.efi reads BCD from:
  TFTP path: EFI\Microsoft\Boot\BCD
  HTTP path: https://192.168.5.141/EFI/Microsoft/Boot/BCD
  ↓
BCD: ramdisksdidevice=boot, path=\windows\system32\boot\winload.efi
     device=ramdisk=[boot]\sources\boot.wim
  ↓
boot.wim (~513 MB) served via TFTP or HTTPS
  ↓
WinPE boots → deploy.ps1 → Juniper PC Deployment System
```

---

## Key Files on pc-deploy (current state as of 2026-06-19)

| Path | Description | Status |
|---|---|---|
| `C:\tftpd64\shimx64.efi` | Ubuntu shim, dual-signed UEFI CA 2011 + 2023, 1,048,424 bytes | ✅ correct |
| `C:\tftpd64\grubx64.efi` | **Windows Boot Manager** (bootmgfw.efi), MS PCA 2011, NotAfter 10/17/2026, 2,984 KB | ✅ **UPDATED** |
| `C:\tftpd64\grubx64-ipxe-20260619.efi` | Backup of old iPXE binary (413,168 bytes, Juniper CA) | 🗄️ backup |
| `C:\tftpd64\EFI\Boot\bootx64.efi` | Same bootmgfw.efi (TFTP PXE fallback), MS PCA 2011, NotAfter 10/17/2026 | ✅ **UPDATED** |
| `C:\tftpd64\EFI\Microsoft\Boot\BCD` | UEFI BCD: winload.efi + ramdisksdidevice=boot + block size opts | ✅ correct |
| `C:\tftpd64\Boot\BCD` | Legacy BCD: winload.exe + ramdisksdidevice=boot | ✅ correct |
| `C:\tftpd64\sources\boot.wim` | WinPE (NIC drivers injected, ~513 MB) | ✅ correct |
| `C:\tftpd64\tftpd64.ini` | PXECompatibility=0, BaseDirectory=C:\tftpd64, Services=1 | ✅ **FIXED** |

### Caddyfile (`C:\caddy\Caddyfile`)

Both HTTP and HTTPS serve `C:\tftpd64` as the file root.

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

### UniFi DHCP (current state)

| Field | Value |
|---|---|
| Network Boot | ✅ enabled |
| Network Boot — server | `192.168.5.141` |
| Network Boot — filename | `shimx64.efi` |
| TFTP Server | `192.168.5.141` |

---

## Changes Applied 2026-06-19 (Architecture Change)

All changes made to pc-deploy via WinRM (credentials from DPAPI cache).

### 1. Replace iPXE with Windows Boot Manager

```powershell
# Backup old binary
Copy-Item "C:\tftpd64\grubx64.efi" "C:\tftpd64\grubx64-ipxe-20260619.efi"

# Replace with Windows Boot Manager (shim loads this as its second stage)
Copy-Item "C:\Windows\Boot\EFI\bootmgfw.efi" "C:\tftpd64\grubx64.efi"
# Result: 2,984 KB, Issuer = Microsoft Windows Production PCA 2011, NotAfter = 10/17/2026

# Update TFTP PXE boot file with fresher cert (old was NotAfter 11/14/2024 — effectively expired)
Copy-Item "C:\Windows\Boot\EFI\bootmgfw.efi" "C:\tftpd64\EFI\Boot\bootx64.efi"
```

### 2. Fix TFTP compatibility flag

```ini
; tftpd64.ini (was 1, changed to 0)
PXECompatibility=0
; UEFI clients require RFC 2347 TFTP option negotiation.
; PXECompatibility=1 forces legacy mode and breaks UEFI clients.
```

### 3. Add TFTP block size optimizations to all BCD stores

```powershell
$ramdiskGuid = "{7619dcc8-fafe-11d9-b411-000476eba25f}"
foreach ($bcd in @(
    "C:\tftpd64\Boot\BCD",
    "C:\tftpd64\EFI\Microsoft\Boot\BCD",
    "C:\tftpd64\EFI\EFI\Microsoft\Boot\BCD"
)) {
    bcdedit /store $bcd /set $ramdiskGuid ramdisktftpblocksize 16384
    bcdedit /store $bcd /set $ramdiskGuid ramdisktftpwindowsize 4
}
```

### 4. Restarted tftpd64 service

tftpd64 was restarted to pick up the `PXECompatibility=0` change.

---

## Why the Previous Architecture Failed

### Root cause: wrong boot chain for Secure Boot + Windows imaging

The previous chain was: `shimx64.efi → grubx64.efi (iPXE signed by Juniper CA)`

#### Why this fails with Secure Boot ON

Shim's verification chain checks (in order):
1. UEFI `db` — list of trusted keys embedded in firmware
2. `MokList` — Machine Owner Keys enrolled per-machine via MokManager
3. Shim's embedded vendor cert — Ubuntu's Canonical cert, baked into shimx64.efi

The Juniper PXE CA cert is **none of these**. It's not in any UEFI db, it's not in MokList
unless enrolled manually, and Ubuntu shim has no knowledge of it. Result: every boot attempt
produced a `Secure Boot Violation` before iPXE could run.

#### Why MOK enrollment didn't stick

Multiple attempts were made to enroll the Juniper PXE CA via MokManager (`mmx64.efi`).
All failed: ThinkShield on the P14s Gen 5 appears to wipe `MokNew` between reboots when
the enrollment isn't completed within the same BIOS session. A "Configuration change.
Restarting." message cleared the pending enrollment each time.

Even if MOK enrollment worked, it would require manual BIOS interaction on every machine
before imaging — not viable for fleet deployment.

#### Why the fix works

`bootmgfw.efi` (Windows Boot Manager) is signed by `Microsoft Windows Production PCA 2011`.
This certificate is **already in the UEFI db** on every PC manufactured in the last decade —
it's how Windows itself boots with Secure Boot enabled. Shim loads `grubx64.efi`, verifies
it against the UEFI db, finds the MS PCA 2011 cert, and passes it without any MOK enrollment.

No per-machine configuration required. This is the same chain WDS/SCCM/MDT use in every
enterprise Windows deployment — the components just come from the free ADK instead of Windows Server.

---

## Previous Root Cause: HTTPS URL as TFTP Filename (Resolved 2026-06-19)

An earlier root cause was identified and fixed:

The EFG DHCP `dhcpd_boot_filename` was set to `https://192.168.5.141/shimx64.efi`
(a full URL). A PXEBOOT client only speaks TFTP — it sent that literal string as the TFTP filename.
tftpd64 received an RRQ for `https:\192.168.5.141\shimx64.efi`, which is an invalid Windows
path. It silently discarded the request. Zero tftpd64 log entries. No TFTP response.

**Fix applied:** Changed to `shimx64.efi` (plain filename). PXEBOOT clients now request the
correct TFTP file, which exists at `C:\tftpd64\shimx64.efi`.

**Confirmed via pktmon:** 10 TFTP RRQ packets (76 bytes each, two source ports) visible
arriving at pc-deploy:69 from ThinkPad 192.168.11.24 (MAC C8-53-09-2D-0D-56) with zero
outbound response — consistent with tftpd64 receiving an unparseable URL-format filename.

---

## Testing Instructions

### Test the new chain (Jason must run)

1. Boot the ThinkPad P14s Gen 5 to the F12 boot menu
2. Try **Boot0024** first (TFTP/PXE path):
   - Select the entry labeled "PXE BOOT" or similar
   - Expected: TFTP downloads shimx64.efi → shim loads grubx64.efi (=bootmgfw.efi)
     → Windows Boot Manager reads BCD → boot.wim loads over TFTP
   - WinPE should appear and launch deploy.ps1
3. If TFTP path doesn't work, try **Boot002E** (UEFI HTTPS Boot, if present):
   - Expected: same chain but boot.wim fetched over HTTPS from Caddy

### What success looks like

The ThinkPad displays the Windows Boot Manager loading screen (spinning dots),
then WinPE loads and the deploy prompt appears.

### If bootmgfw.efi shows a Secure Boot violation

This means MS PCA 2011 is in the DBX (revocation list) on this specific ThinkPad —
Lenovo pushed KB5025885 to some machines that revoked PCA 2011 to mitigate the BlackLotus bootkit.

**Option A — use PCA2023-signed bootmgfw.efi:**
Install the Windows ADK December 2024 update or later on pc-deploy. The newer ADK ships
`bootmgfw.efi` signed by `Microsoft Windows UEFI CA 2023` (PCA2023), which is not revoked.
Copy to `C:\tftpd64\grubx64.efi` and `C:\tftpd64\EFI\Boot\bootx64.efi`.

**Option B — GRUB2 as intermediary:**
Use Ubuntu's `grubnetx64.efi.signed` (GRUB2, signed by UEFI CA 2011 — not in DBX) as
shim's second stage. Configure GRUB2 to chainload bootmgfw.efi. GRUB2 runs in shim's
security context and can chain-execute bootmgfw.efi without an additional Secure Boot check.

**Option C — Disable Secure Boot for imaging only:**
Set Secure Boot = Off in ThinkPad BIOS during the imaging run. Re-enable after Windows
installs. Not scalable for fleet deployment but useful for testing.

---

## Full Diagnostic History

### 🔬 pktmon Capture — 2026-06-19 (pre-fix)

`pktmon start --etw -f C:\boot-capture.etl` on pc-deploy during ThinkPad PXEBOOT attempt.

| Traffic | Direction | Finding |
|---|---|---|
| `192.168.0.1:67 → 255.255.255.255:68` | Inbound (broadcast) | EFG DHCP ACK confirmed |
| `192.168.11.24:1753 → 192.168.5.141:69` | Inbound | 5 TFTP RRQ packets (76 bytes each) |
| `192.168.11.24:1227 → 192.168.5.141:69` | Inbound | 5 more TFTP RRQ (~90 seconds later) |
| `192.168.5.141 → 192.168.11.24` | Outbound | NOTHING — zero TFTP responses |

10 packets, two source ports = two independent TFTP session attempts, each retried 5× on timeout.
MAC `C8-53-09-2D-0D-56` = ThinkPad P14s Gen 5.

This proved: (1) EFG delivers boot options, (2) STP not blocking traffic, (3) failure on pc-deploy.
Root cause: tftpd64 silently discarding RRQ with URL-format filename.

### tftpd64 Diagnostic Results — 2026-06-19

| Check | Result |
|---|---|
| Process | Running ✅ |
| `netstat -ano \| findstr ":69"` | `UDP 0.0.0.0:69 *:* PID` — socket bound ✅ |
| tftpd64.log size | 0 bytes — no successful transfers (explained by invalid filename) |
| Windows Firewall | All three profiles OFF ✅ |
| SecurityLevel | 0 (no IP filtering) ✅ |
| tftpd32.ini vs tftpd64.ini | Confirmed identical; tftpd64.exe reads tftpd32.ini (normal) ✅ |
| PXECompatibility | Was 1 (broke UEFI TFTP option negotiation) → fixed to 0 ✅ |

### All Attempts Summary

| What | Outcome |
|---|---|
| Standard PXEBOOT with URL as DHCP filename | TFTP arrived at pc-deploy, no response (URL filename bug) |
| UEFI HTTP Boot with `http://` URL | Zero Caddy hits — ThinkPad HTTPSBOOT ignores plain HTTP |
| UEFI HTTPS Boot (custom boot entry) | "Could not retrieve NBP file size" — TLS handshake fails |
| Enroll Juniper TLS CA via BIOS cert menu | No change — menu is Lenovo ON-PREMISE, not UEFI HTTPS Boot |
| MOK enrollment via mmx64.efi | ThinkShield wipes MokNew; enrollment never persists |
| Fixed URL-as-filename in UniFi DHCP | ✅ Fixed. TFTP now requests correct filename |
| Fixed tftpd64 competing DHCP (Services=15→1) | ✅ Fixed |
| **Replaced grubx64.efi with bootmgfw.efi** | ✅ Applied — PENDING TEST |

---

## Community Research Findings

| Source | Platform | Finding |
|---|---|---|
| community.ui.com (8yr old) | USG / EdgeOS | Garbage bytes in Option 67 — not applicable to EFG/UniFi OS |
| community.ui.com (13yr old) | EdgeRouter | Duplicate dhcpd.conf entries — not applicable |
| kenmoini.com (2023) | UDM-Pro | Single-arch PXE works via UniFi DHCP; multi-arch needs external DHCP |
| HardForum (2021) | UDM | TFTP blocked by Windows Firewall — ruled out (WF disabled) |
| EduGeek (Dec 2025) | EFG | PXE fixed by switch reboot; another user runs Windows DHCP instead |

---

## References

- [Lenovo CDRT — ThinkPad Startup settings](https://docs.lenovocdrt.com/ref/bios/settings/thinkpad/startup/)
- [Lenovo CDRT — ThinkPad Network settings](https://docs.lenovocdrt.com/ref/bios/settings/thinkpad/network/)
- [UEFI HTTPS Boot — tianocore wiki](https://github.com/tianocore/tianocore.github.io/wiki/HTTPS-Boot)
- [PXE & HTTP(s) Booting DHCP Options — hannan.au](https://hannan.au/posts/pxe-dhcp/)
- [Ubiquiti Community — SCCM PXE Boot and UniFi](https://community.ui.com/questions/SCCM-PXE-Boot-and-Unifi-Network-Boot/14511d8b-6c57-4392-9b66-4a91e9f6e717)
- [pc-imaging-server repo](https://github.com/jasonjuniper/pc-imaging-server)

---

*Juniper Design internal documentation — last updated 2026-06-19*
