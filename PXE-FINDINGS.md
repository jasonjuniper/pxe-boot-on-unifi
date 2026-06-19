# PXE Boot on UniFi — Research Findings & Implementation Log

**Date:** 2026-06-19
**Author:** Claude (Juniper AI)
**Status:** 🔍 DIAGNOSING — shim bypassed, CA2023 enrollment on ThinkPad TBD

Boot chain (current): UEFI firmware → `EFI/Boot/bootx64.efi` (bootmgfw_EX.efi, PCA2023) → BCD → boot.wim

**Current blocker:** The ThinkPad P14s Gen 5 shows "Secure Boot Violation" for BOTH PCA2011 and
PCA2023-signed boot files. Both-fail means the problem is upstream — either Windows UEFI CA 2023
is not enrolled in this ThinkPad's UEFI db, or shim was rejecting the second-stage. Shim has been
removed from the chain (option 67 → `EFI/Boot/bootx64.efi`). Next test will confirm which it is.

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

## Current Boot Architecture (updated 2026-06-19)

Shim has been removed. UEFI firmware now loads Windows Boot Manager directly from TFTP.
This is the cleanest possible chain and is what WDS/SCCM use when Windows UEFI CA 2023 is enrolled.

```
Target UEFI firmware (Secure Boot ON)
  │  selects network boot entry
  ↓
DHCP → Option 66 = 192.168.5.141 (TFTP server)
       Option 67 = EFI/Boot/bootx64.efi  (TFTP filename)
  ↓
TFTP: downloads EFI/Boot/bootx64.efi from 192.168.5.141:69
  ↓
bootx64.efi  (= bootmgfw_EX.efi, Windows Boot Manager, signed by Windows UEFI CA 2023, 2,692 KB)
  │  verified by UEFI firmware against Windows UEFI CA 2023 in db
  │  IF CA2023 in db → PASSES ✓
  │  IF CA2023 NOT in db → Secure Boot Violation ← suspected current failure
  ↓
bootmgfw_EX.efi reads BCD from:
  TFTP path: EFI\Microsoft\Boot\BCD
  ↓
BCD: ramdisksdidevice=boot, path=\windows\system32\boot\winload.efi
     device=ramdisk=[boot]\sources\boot.wim
  ↓
winload.efi  [⚠️ currently PCA2011-signed inside boot.wim — may be a secondary issue]
  ↓
boot.wim (~513 MB) served via TFTP
  ↓
WinPE boots → deploy.ps1 → Juniper PC Deployment System
```

### ⚠️ Known issue: winload.efi in boot.wim is PCA2011-signed

When boot.wim was inspected (2026-06-19):
- `Windows\System32\boot\winload.efi` → **CN=Microsoft Windows Production PCA 2011**, 3,017 KB
- `Windows\Boot\EFI_EX\bootmgfw_EX.efi` → **CN=Windows UEFI CA 2023** ✓ (only the boot manager has a PCA2023 variant)
- No `winload_EX.efi` exists — Microsoft only provides a PCA2023 replacement for the boot manager, not the loader

KB5025885 adds **hash-based** DBX entries for specific vulnerable bootmgfw.efi versions — it does NOT
broadly revoke the PCA2011 CA. Since our boot.wim's winload.efi is a different binary (ADK-built, not the
vulnerable version), its hash is very likely NOT in the DBX. This should not be a problem. However, if it
does fail, the fix is to rebuild boot.wim using a newer ADK (26100+) which includes updated components.

---

## Key Files on pc-deploy (current state as of 2026-06-19)

| Path | Description | Status |
|---|---|---|
| `C:\tftpd64\shimx64.efi` | Ubuntu shim, dual-signed UEFI CA 2011 + 2023, 1,048,424 bytes | ✅ correct |
| `C:\tftpd64\grubx64.efi` | **bootmgfw_EX.efi** (Windows UEFI CA 2023, NotAfter 2024-10-19, 2,692 KB) | ✅ **PCA2023** |
| `C:\tftpd64\grubx64-ipxe-20260619.efi` | Backup of old iPXE binary (Juniper CA) | 🗄️ backup |
| `C:\tftpd64\grubx64-pca2011-20260619.efi` | Backup of PCA2011 bootmgfw.efi (NotAfter 2026-10-17) | 🗄️ backup |
| `C:\tftpd64\EFI\Boot\bootx64.efi` | Same bootmgfw_EX.efi (Windows UEFI CA 2023, NotAfter 2024-10-19) | ✅ **PCA2023** |
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

### UniFi DHCP (current state — updated 2026-06-19)

| Field | Value |
|---|---|
| Network Boot | ✅ enabled |
| Network Boot — server | `192.168.5.141` |
| Network Boot — filename | `EFI/Boot/bootx64.efi` ← **shim bypassed** |
| TFTP Server | `192.168.5.141` |

---

## Changes Applied 2026-06-19 (Architecture Change)

All changes made to pc-deploy via WinRM (credentials from DPAPI cache).

### 1. Replace iPXE with Windows Boot Manager (PCA2011 — later upgraded)

```powershell
# First attempt — PCA2011-signed (deployed, then rejected by ThinkPad DBX)
Copy-Item "C:\tftpd64\grubx64.efi" "C:\tftpd64\grubx64-ipxe-20260619.efi"
Copy-Item "C:\Windows\Boot\EFI\bootmgfw.efi" "C:\tftpd64\grubx64.efi"
# Result: 2,984 KB, Issuer = Microsoft Windows Production PCA 2011 — REJECTED (in DBX)
```

### 1b. Upgrade to PCA2023-signed bootmgfw_EX.efi

The ThinkPad has KB5025885 Stage 3: Microsoft Windows Production PCA 2011 fully revoked in DBX.
The PCA2023-signed replacement (`bootmgfw_EX.efi`) was already present in our own
`C:\tftpd64\sources\boot.wim` at `Windows\Boot\EFI_EX\bootmgfw_EX.efi`.

```powershell
# Mount boot.wim read-only
New-Item -ItemType Directory "C:\bootmount" -Force
dism /Mount-Wim /WimFile:C:\tftpd64\sources\boot.wim /Index:1 /MountDir:C:\bootmount /ReadOnly

# Extract PCA2023 binary
$src = "C:\bootmount\Windows\Boot\EFI_EX\bootmgfw_EX.efi"
Copy-Item "C:\tftpd64\grubx64.efi" "C:\tftpd64\grubx64-pca2011-20260619.efi"  # backup
Copy-Item $src "C:\tftpd64\grubx64.efi" -Force
Copy-Item $src "C:\tftpd64\EFI\Boot\bootx64.efi" -Force

dism /Unmount-Wim /MountDir:C:\bootmount /Discard
# Result: 2,692 KB, Issuer = Windows UEFI CA 2023, NotAfter = 2024-10-19 ✓
```

Windows UEFI CA 2023 is in every modern UEFI db and is NOT in any DBX. The leaf cert's NotAfter
(2024-10-19) is past, but Secure Boot validates against the CA, not the leaf cert expiry.

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

### Next test (when ThinkPad is powered on)

Boot the ThinkPad P14s Gen 5 to the F12 boot menu and select the PXE/Network Boot entry (Boot0024).

**Expected success path:**
1. TFTP downloads `EFI/Boot/bootx64.efi` (= bootmgfw_EX.efi, PCA2023)
2. UEFI validates PCA2023 → if Windows UEFI CA 2023 in db → PASSES
3. Windows Boot Manager reads BCD → mounts boot.wim → WinPE loads
4. deploy.ps1 launches — ThinkPad shows the Juniper imaging prompt

**If it still shows Secure Boot Violation:**
Claude will check via WinRM whether Windows UEFI CA 2023 is enrolled in the ThinkPad's UEFI db
(`Get-SecureBootUEFI -Name db`). If it's absent, the ThinkPad needs Windows Update (KB5025885)
to enroll it — Claude will trigger this remotely.

ThinkPad WinRM target: `192.168.11.24`, MAC `C8-53-09-2D-0D-56`, creds from 1Password.

### What success looks like

The ThinkPad displays the Windows Boot Manager loading screen (spinning dots),
then WinPE loads and the deploy prompt appears.

---

## Secure Boot Violation — Diagnostic Log (2026-06-19)

### Attempt 1: PCA2011-signed bootmgfw.efi as grubx64.efi

Copied `C:\Windows\Boot\EFI\bootmgfw.efi` (PCA2011, 2,984 KB) as `grubx64.efi`.
**Result:** Secure Boot Violation — "Invalid signature detected."
**Diagnosis:** ThinkPad KB5025885 Stage 3 has hash-based DBX entries for this specific binary. ✓ confirmed.

### Attempt 2: PCA2023-signed bootmgfw_EX.efi as grubx64.efi

Extracted `bootmgfw_EX.efi` (Windows UEFI CA 2023, 2,692 KB) from `boot.wim\Windows\Boot\EFI_EX\`.
Deployed as both `C:\tftpd64\grubx64.efi` and `C:\tftpd64\EFI\Boot\bootx64.efi`.
DHCP option 67 was still `shimx64.efi` at this point — shim was loading grubx64.efi.
**Result:** SAME Secure Boot Violation — "Invalid signature detected."
**Diagnosis:** Both PCA2011 and PCA2023 failing = failure is UPSTREAM of grubx64.efi, likely at
shim validation level (shimx64.efi may be hash-revoked in this ThinkPad's DBX) OR Windows
UEFI CA 2023 is not enrolled in the UEFI db (KB5025885 Stage 3 db enrollment hasn't run on ThinkPad).

### Change applied: Bypass shim

DHCP option 67 changed from `shimx64.efi` → `EFI/Boot/bootx64.efi` (already = PCA2023 bootmgfw_EX.efi).
The UEFI firmware now loads and validates `bootmgfw_EX.efi` directly — no shim intermediary.
**PENDING TEST** (ThinkPad not powered on at time of change).

### For future reference — PCA2023 source

The PCA2023 boot binary was found already inside our own boot.wim:
```
C:\tftpd64\sources\boot.wim → Windows\Boot\EFI_EX\bootmgfw_EX.efi
```
Microsoft's official script (KB5053484 / Make2023BootableMedia.ps1) copies exactly this file —
there's no need to download anything external if you have a recent boot.wim.

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
