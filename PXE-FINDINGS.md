# PXE Boot on UniFi — Research Findings & Implementation Log

**Date:** 2026-06-22 (session 2), original 2026-06-19
**Author:** Claude (Juniper AI)
**Status:** 🔴 BLOCKED — iPXE shim is CA 2011 only; CA 2011 removed from IMAGE-ME's Secure Boot db

**Immediate fix:** Disable Secure Boot on IMAGE-ME in BIOS (F1 → Security → Secure Boot → Disabled). No DHCP changes needed. Long-term fix: wait for a CA 2023-signed iPXE shim (iPXE team working on it, rhboot/shim-review#319).

---

## ⚠️ CURRENT BLOCKER: MS UEFI CA 2011 is expiring / removed from ThinkPad db

**Microsoft Corporation UEFI CA 2011** — the certificate used to sign ALL third-party UEFI boot
applications including every Linux shim and the iPXE shim — **expires June 26, 2026** (this week).

Lenovo pushed ThinkPad firmware updates proactively removing CA 2011 from the Secure Boot db and
replacing it with CA 2023. IMAGE-ME (ThinkPad P14s Gen 5) has received this firmware update.

### What's signed by what

| Component | Signing | IMAGE-ME result |
|---|---|---|
| `ipxe-shim.efi` (iPXE v2.0.0) | MS UEFI CA 2011 **only** (1 cert in PE table) | ❌ Rejected — CA 2011 not trusted |
| `wimboot` (v2.9.0) | CA 2011 + **CA 2023** (dual-signed, 2 certs in PE table) | ✅ Would pass Secure Boot |
| `EFI/Boot/bootx64.efi` (bootmgfw_EX.efi) | Windows PCA 2011 (separate chain from UEFI CA) | ✅ Passes (Windows chain still trusted) |
| CA 2023-signed iPXE shim | **Does not exist yet** — iPXE team tracking in rhboot/shim-review#319 | — |

**Key finding:** wimboot IS dual-signed and would pass IMAGE-ME's Secure Boot. But wimboot requires
iPXE to inject BCD/boot.sdi/boot.wim into memory — it cannot function as a standalone PXE boot file.
So the chain still needs a working iPXE shim, which requires CA 2023 signing.

### How we confirmed dual-signing

PE certificate table analysis (not Get-AuthenticodeSignature, which only reads the primary cert):

```powershell
# on pc-deploy via WinRM:
# shimx64.efi: CertTableSize=9728  (one cert)  → CA 2011 only
# wimboot:     CertTableSize=19232 (two certs, 9728+9504) → CA 2011 + CA 2023
```

### Why no CA 2023 iPXE shim exists yet

iPXE v2.0.0 (March 6, 2026) shim was submitted to Microsoft for signing before the October 2025
dual-signing cutover, so it only got CA 2011. The iPXE team is working on a re-submission via the
shim-review process (rhboot/shim-review#319). No release date. The next iPXE release will include
a CA 2023-signed (or dual-signed) shim.

Source: github.com/ipxe/ipxe/discussions/1638 — iPXE collaborator NiKiZe confirmed this directly
in March 2026.

---

## 🔬 Enterprise Research: Secure Boot PXE in June 2026 (post-CA2011 expiry)

*Research conducted 2026-06-23. Sources: Lenovo Press LP2353, TechDirectArchive 4-part series
(Parts 2/3/4), miloch.dev, systemcenterdudes.com, 2Pint Software, winreflection.com.*

### The Two Cert Chains — Critical Distinction

There are **two completely separate Microsoft Secure Boot certificate hierarchies**. Confusing them
is the most common mistake in post-CA2011 PXE troubleshooting:

| Chain | Signing authority | Validates | IMAGE-ME status (after Lenovo FW update) |
|---|---|---|---|
| **Microsoft Corporation UEFI CA 2011** | Signs third-party UEFI boot apps | iPXE shim, Linux shims, unsigned drivers | ❌ REMOVED from db |
| **Microsoft Corporation UEFI CA 2023** | Replacement for UEFI CA 2011 | Same, next generation | ✅ ADDED to db |
| **Microsoft Windows Production PCA 2011** | Signs Windows OS boot components | bootmgfw.efi, winload.efi, boot.wim internals | ✅ STILL TRUSTED |

**The Lenovo firmware update ONLY removed UEFI CA 2011.** The Windows Production PCA 2011 (which
signs `bootmgfw_EX.efi`, `winload.efi`, and everything inside `boot.wim`) is **unaffected**.

This means: our existing `boot.wim` WinPE components (`winload.efi`, etc.) do **not** need to be
replaced. They use the Windows Production PCA 2011 chain, which IMAGE-ME still trusts.

**The ONLY thing broken is the iPXE shim** — it is signed by UEFI CA 2011 (third-party UEFI CA),
which is now removed from IMAGE-ME's db.

### How Enterprises Are Solving This Right Now

#### Path A: WDS + Windows Server 2022 (`boot_EX` directory)

Microsoft ships CA 2023-signed WDS PXE loaders in a special directory on Windows Server 2022 only:
```
C:\Windows\System32\RemInst\boot_EX\x64\
  wdsmgfw_EX.efi    ← CA 2023-signed WDS PXE loader
  bootmgfw_EX.efi   ← CA 2023-signed Windows Boot Manager
```

**Fix for WDS environments:**
```cmd
copy "C:\Windows\System32\RemInst\boot_EX\x64\wdsmgfw_EX.efi" "F:\RemoteInstall\Boot\x64\wdsmgfw.efi" /Y
copy "C:\Windows\System32\RemInst\boot_EX\x64\bootmgfw_EX.efi" "F:\RemoteInstall\Boot\x64\bootmgfw.efi" /Y
net stop WDSServer && net start WDSServer
```

**Caveats:**
- `boot_EX` directory only exists on **Windows Server 2022** (fully patched). Does NOT exist on
  Windows 11. Therefore **this approach is not available for pc-deploy**.
- MDT environments: when MDT rebuilds LiteTouchPE, it regenerates WinPE from the ADK baseline which
  still contains CA 2011 components. **MDT overwrites any manual patches** — the fix is not persistent.
- As of May 2026, the ADK servicing updates (10.1.28000.1) still contain outdated WinPE binaries.
  True fix requires Microsoft to ship a corrected ADK. (TechDirectArchive Part 4, May 15, 2026)

**What DOES work persistently:** Build a custom WinPE outside MDT/WDS (Lenovo Press LP2353 approach).
In that model, MDT never touches the WIM. For us this doesn't matter — we already build custom WinPE
using ADK tools directly, without MDT.

#### Path B: ConfigMgr (SCCM) 2509 PXE Responder

Starting with SCCM ConfigMgr 2509, Microsoft added a checkbox:
**"Use Windows Boot Loader signed with Windows UEFI CA 2023"**

This is the **cleanest enterprise solution** for CA 2023 Secure Boot PXE. Requirements:
- ConfigMgr 2509 or later
- ConfigMgr PXE Responder (NOT WDS — ConfigMgr has its own PXE service)
- Latest ADK + WinPE Add-on

This is a Windows Server + SCCM-licensed solution. Not applicable to our Windows 11 setup.

#### Path C: iPXE + wimboot (Our Approach) — Waiting for CA 2023 Shim

Our stack (tftpd64 → iPXE shim → iPXE → wimboot → boot.wim via HTTP) is architecturally correct
and actually **superior** to WDS for our use case:

| Feature | WDS approach | iPXE + wimboot approach |
|---|---|---|
| boot.wim delivery | TFTP (requires WDS ramdisk extensions) | HTTP (no WDS needed) |
| Works on Windows 11 server | ❌ WDS is Windows Server-only | ✅ Works on Windows 11 |
| MDT regeneration problem | ❌ MDT overwrites patches | ✅ No MDT used |
| Secure Boot (right now) | ⚠️ Complex, requires boot_EX + custom WinPE | 🔄 Waiting for CA 2023 shim |
| WiFi PXE support | ❌ TFTP too slow/large for 802.11 | ✅ HTTP scales fine |

**The one missing piece:** a CA 2023-signed iPXE shim (UEFI CA 2023). Issue tracked:
- rhboot/shim-review#319 — iPXE shim submission
- github.com/ipxe/ipxe/discussions/1638 — iPXE collaborator NiKiZe confirmed CA 2023 shim in progress

Once that shim is released: drop it into `C:\tftpd64\ipxeboot\x86_64-sb\ipxe-shim.efi`, re-enable
Secure Boot on target machines. No other changes required.

### Why the 0xc0000225 Error Happens Without WDS

When using `bootmgfw.efi` directly (without iPXE/wimboot) as the TFTP boot file, Windows Boot Manager
tries to download `boot.wim` via TFTP using WDS-specific TFTP ramdisk extensions. Standard TFTP
servers (tftpd64, SolarWinds, etc.) do NOT implement these WDS extensions. Result: 0xc0000225.

This is confirmed independently by winreflection.com (Aug 2024) — same error, same conclusion.
iPXE + wimboot bypasses this entirely by delivering boot.wim via HTTP.

### Why Our boot.wim Does NOT Need CA 2023 Updates

A common misconception (from MDT/WDS articles) is that `winload.efi` inside boot.wim needs to be
updated to CA 2023. This is ONLY true in environments where the device has had the **Windows Production
PCA 2011** revoked from its db — which is a separate, additional enforcement step.

IMAGE-ME (ThinkPad P14s Gen 5, Lenovo firmware update) had **UEFI CA 2011 removed** (the third-party
UEFI CA), but **Windows Production PCA 2011 remains trusted**. Therefore:

- `winload.efi` inside boot.wim (signed by Windows Production PCA 2011) → ✅ still trusted
- `bootmgfw_EX.efi` (Windows Production PCA 2011) → ✅ still trusted  
- Only `ipxe-shim.efi` (UEFI CA 2011) → ❌ no longer trusted

The techdirectarchive articles describe environments where **BOTH** CA 2011 chains are being revoked
(some Dell SafeBIOS devices), which is a more aggressive enforcement. That situation DOES require CA
2023 updates to WinPE internals. For IMAGE-ME, only the iPXE shim needs to change.

### Sources

| Source | Published | Relevance |
|---|---|---|
| [Lenovo Press LP2353](https://lenovopress.lenovo.com/lp2353-updating-windows-boot-manager-and-winpe-windows-uefi-ca-2023-certificate) | 2025-2026 | Official Lenovo guide: build custom WinPE outside MDT with CA 2023 |
| [TechDirectArchive Part 2](https://techdirectarchive.com/2026/04/27/update-winpe-boot-images-with-windows-uefi-ca-certificates-part-2/) | 2026-04-27 | Updating WinPE boot images with CA 2023 certs |
| [TechDirectArchive Part 3](https://techdirectarchive.com/2026/05/08/fix-operating-system-loader-failed-signature-verification-on-dell-safe-bios-systems-via-pxe-part-3/) | 2026-05-08 | Dell SafeBIOS PXE; boot_EX source files; trust gap analysis |
| [TechDirectArchive Part 4](https://techdirectarchive.com/2026/05/15/pxe-boot-failure-access-denied-or-aborted-with-secure-boot-on/) | 2026-05-15 | **Key:** ADK still broken as of May 2026; MDT overwrites patches; confirms no durable fix without MS ADK update |
| [miloch.dev SCCM playbook](https://miloch.dev/blog/secure-boot-certificates-2026-sccm/) | 2026-05-21 | Full enterprise playbook: AvailableUpdates registry, SCCM Baselines, event-log signals |
| [System Center Dudes](https://www.systemcenterdudes.com/update-sccm-boot-images-for-devices-with-hardened-secure-boot/) | 2026-06-09 | SCCM boot images for hardened Secure Boot; CA 2023 checkbox in ConfigMgr 2509 |
| [2Pint Software](https://2pintsoftware.com/news/details/kb5025885-and-boot-wims) | 2024-04-19 | KB5025885 + boot WIM updates; TrustedInstaller permission issue replacing winload.efi |
| [winreflection.com](https://www.winreflection.com/simplify-pxe-booting-no-wds-required-on-unifi-setups/) | 2024-08-15 | PXE without WDS on UniFi; confirms 0xc0000225 with bootmgfw.efi UEFI boot without WDS |

---

## ✅ DHCP OPTIONS — already applied, no changes needed

| Field | Current value | Notes |
|---|---|---|
| Boot server (Option 66) | `192.168.5.141` | Correct |
| Boot filename (Option 67) | `ipxeboot/x86_64-sb/ipxe-shim.efi` | Applied by Jason 2026-06-22 |
| Network Boot | Enabled | Correct |

---

## Recommended Interim Solution: Disable Secure Boot for Imaging

Until a CA 2023-signed iPXE shim is released:

1. On IMAGE-ME: **Enter BIOS (F1 at Lenovo logo) → Security → Secure Boot → Disabled → Save & Exit**
2. No DHCP changes needed — `ipxeboot/x86_64-sb/ipxe-shim.efi` works with Secure Boot off
3. PXE boot IMAGE-ME: shim → iPXE → HTTP → wimboot → WinPE → deploy.ps1

With Secure Boot disabled, UEFI skips signature validation entirely. The existing chain runs as designed.
After imaging, Secure Boot can be re-enabled in BIOS; Windows boots fine either way.

**For the long-term WiFi PXE + Secure Boot goal:** the stack is ready. wimboot is already CA 2023
dual-signed. bootmgfw_EX.efi is Windows-chain signed. When iPXE releases a CA 2023 shim, drop it
into `C:\tftpd64\ipxeboot\x86_64-sb\ipxe-shim.efi` and re-enable Secure Boot — done.

---

## Architecture History (this session, 2026-06-22)

### What happened with the bootmgfw_EX.efi approach

A test with `ipxe-http-embedded.efi` (DHCP option 67) confirmed that the unsigned iPXE got a
**Secure Boot Violation** — expected, since that binary isn't signed by any key in the ThinkPad's db.

The bootmgfw_EX.efi approach (set earlier in the session) was superseded because:
- `boot.wim` (513 MB) cannot be delivered via TFTP without WDS — UEFI TFTP has a ~4 GB limit but
  the Windows Boot Manager tries to load it at boot time and fails with **0xc0000225** ("Required
  device is inaccessible") — confirmed by WinReflection article author who hit the exact same issue.
- The correct solution for non-WDS servers is: **iPXE + wimboot** (wimboot loads boot.wim via HTTP).

### Why we're using iPXE v2.0.0 (released March 6, 2026)

iPXE v2.0.0 added official Secure Boot support via a dedicated Microsoft-signed shim:
- `ipxe-shim.efi` — signed by **Microsoft Corporation UEFI CA 2011** (in every PC's UEFI db)
- The shim internally verifies and loads `ipxe.efi` (signed by iPXE's own CA)
- No MOK enrollment required — the shim chain is fully trusted out of the box
- wimboot is already signed by Microsoft — passes Secure Boot validation
- `autoexec.ipxe` controls boot behavior (TFTP-fetched by iPXE, same directory as shim)

This is the correct long-term path. It also supports WiFi PXE (802.11 clients) once configured,
because wimboot + UEFI HTTP avoids the TFTP size limitation entirely.

### Files deployed to pc-deploy (2026-06-22)

| Path on pc-deploy | Description | Status |
|---|---|---|
| `C:\tftpd64\ipxeboot\x86_64-sb\ipxe-shim.efi` | MS UEFI CA 2011-signed shim, 1,038,920 bytes | ✅ deployed |
| `C:\tftpd64\ipxeboot\x86_64-sb\ipxe.efi` | iPXE binary (signed by iPXE CA), 397,160 bytes | ✅ deployed |
| `C:\tftpd64\ipxeboot\x86_64-sb\shimx64.efi` | Same as ipxe-shim.efi (original name in archive) | ✅ deployed |
| `C:\tftpd64\ipxeboot\x86_64-sb\autoexec.ipxe` | iPXE boot script (copy of root autoexec.ipxe) | ✅ deployed |
| `C:\tftpd64\wimboot` | MS-signed wimboot loader, 76,064 bytes | ✅ pre-existing |
| `C:\tftpd64\sources\boot.wim` | WinPE (~513 MB) | ✅ pre-existing |
| `C:\tftpd64\EFI\Microsoft\Boot\BCD` | UEFI BCD | ✅ pre-existing |
| `C:\tftpd64\Boot\boot.sdi` | Boot SDI | ✅ pre-existing |

### HTTP endpoints verified (Caddy serves C:\tftpd64\)

- `http://192.168.5.141/ipxeboot/x86_64-sb/ipxe-shim.efi` → 200, 1,038,920 bytes ✅
- `http://192.168.5.141/ipxeboot/x86_64-sb/autoexec.ipxe` → 200 ✅
- `http://192.168.5.141/wimboot` → 200, 76,064 bytes ✅

### autoexec.ipxe content

```
#!ipxe
echo Juniper WinPE -- Secure Boot chain (shimx64 -> ipxe -> wimboot)
set http http://192.168.5.141
kernel ${http}/wimboot
initrd ${http}/EFI/Microsoft/Boot/BCD   BCD
initrd ${http}/Boot/boot.sdi            boot.sdi
initrd ${http}/sources/boot.wim         boot.wim
boot
```

---

## Previous state (2026-06-22, morning session)

- CA2023 IS enrolled in IMAGE-ME's UEFI db ✅ (previous "not enrolled" diagnosis was a false negative)
- bootmgfw_EX.efi IS properly CA2023-signed ✅
- PXECompatibility=0 is set on pc-deploy ✅
- BCD correctly configured ✅
- The "nope" failure from 2026-06-19 was almost certainly PXECompatibility=1 (TFTP log shows zero activity after the fix was applied at 3:18 PM that day)

**Remaining uncertainty (pre-iPXE pivot):** Our `bootx64.efi` is a preview/insider build (version 10.0.26100.1085, file date 4/1/2024, signing cert NotAfter 10/19/2024). A production version (3,055,456 bytes, updated 6/19/2026 by Windows Update) exists at `C:\Windows\Boot\EFI_EX\bootmgfw_EX.efi` on IMAGE-ME. If the preview file's Authenticode hash is in the DBX, Secure Boot will still fail. This issue is moot — we've pivoted to iPXE v2.0.0 which doesn't use bootmgfw_EX.efi.

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

---

## Expected Boot Sequence (Secure Boot DISABLED — current interim path)

1. IMAGE-ME PXE boots → DHCP gives option 66=`192.168.5.141`, option 67=`ipxeboot/x86_64-sb/ipxe-shim.efi`
2. UEFI TFTP downloads `ipxe-shim.efi` (1 MB) — no Secure Boot signature check
3. Shim verifies `ipxe.efi` via its own embedded iPXE vendor cert → loads `ipxe.efi` via TFTP
4. iPXE fetches `autoexec.ipxe` via TFTP from same directory
5. iPXE executes the script: downloads `wimboot`, `BCD`, `boot.sdi`, `boot.wim` via HTTP from `http://192.168.5.141/`
6. wimboot (CA 2023 dual-signed) loads WinPE from boot.wim in memory
7. WinPE boots → `deploy.ps1` → Juniper imaging prompt

## Expected Boot Sequence (Secure Boot ENABLED — requires CA 2023 iPXE shim, not yet released)

1. IMAGE-ME PXE boots → DHCP gives option 66=`192.168.5.141`, option 67=`ipxeboot/x86_64-sb/ipxe-shim.efi`
2. UEFI TFTP downloads `ipxe-shim.efi` (1 MB)
3. **UEFI Secure Boot validates shim against CA 2023** → PASSES once shim is CA 2023-signed
4. Shim verifies `ipxe.efi` via embedded vendor cert → loads via TFTP
5. iPXE fetches `autoexec.ipxe` via TFTP
6. iPXE downloads wimboot, BCD, boot.sdi, boot.wim via HTTP
7. **UEFI Secure Boot validates wimboot against CA 2023** → PASSES (wimboot already dual-signed)
8. wimboot loads WinPE → deploy.ps1 → Juniper imaging prompt

When the CA 2023 shim arrives: replace `C:\tftpd64\ipxeboot\x86_64-sb\ipxe-shim.efi` and re-enable
Secure Boot on target machines. No other changes needed.

---

## Signing Evidence (collected 2026-06-22)

```
shimx64.efi  (1,038,920 bytes, LastWrite 2026-03-06)
  PE CertTable: 9,728 bytes = ONE signature
  Cert 1: CN=Microsoft Windows UEFI Driver Publisher, issuer CN=Microsoft Corporation UEFI CA 2011
  → CA 2011 ONLY — fails on IMAGE-ME (CA 2011 removed from Lenovo ThinkPad firmware db)

wimboot  (76,064 bytes, LastWrite 2026-06-18)
  PE CertTable: 19,232 bytes = TWO signatures
  Cert 1 (9,728 bytes): CA 2011 primary
  Cert 2 (9,504 bytes): CA 2023 secondary  ← confirmed by "UEFI CA 2023" string in binary
  → DUAL-SIGNED — passes Secure Boot on IMAGE-ME ✅

bootx64.efi (bootmgfw_EX.efi, 3,055,456 bytes)
  Signer: CN=Microsoft Windows, issuer CN=Microsoft Windows Production PCA 2011
  → Windows cert chain (separate from UEFI CA chain) — IMAGE-ME trusts it ✅
```

*Juniper Design internal documentation — last updated 2026-06-22 session 2*
