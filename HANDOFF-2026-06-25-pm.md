# Session Handoff — 2026-06-25 (PM): 0xc0000272 ROOT CAUSE FOUND + FIXED

## TL;DR
`0xc0000272` was **Secure Boot rejecting the WDS boot manager**, not a WDS config or BINL
problem. The active boot chain was the April-2024 **PCA-2011** binaries, whose hashes are
**DBX-revoked on IMAGE-ME** (Lenovo's CA-2011 removal — already proven in the 2026-06-22
findings). The previous session had *restored those exact revoked binaries* into the active
path, so the error never moved.

**Fix applied this session:** swapped the active x64 boot chain to the **CA-2023 "EX"**
binaries that were already staged on the server. WDS restarted clean. Awaiting a physical
boot test of IMAGE-ME with Secure Boot ON.

---

## Diagnosis (evidence-based)

| Fact | Source |
|---|---|
| Server is **Windows Server 2025** (boot.wim WDS-*mode* is blocked here) | live `Get-CimInstance` |
| Registered boot image is a **custom WinPE** (`boot-winload-fix.wim`), runs `deploy.ps1` — so the Server-2025 deprecation does **not** block us | live `wdsutil /Get-AllImages` |
| Error fires at the **boot-manager stage, before boot.wim is requested** | prior handoff |
| Active `wdsmgfw.efi`/`bootmgfw.efi` were **PCA-2011** (no "UEFI CA 2023" string) | live PE inspection |
| IMAGE-ME UEFI has **DBX-hash-revoked** the PCA-2011 `bootmgfw.efi` | `PXE-FINDINGS.md` Attempt 1 (2026-06-22) |
| `0xc0000272` = classic "boot file signed with a cert the UEFI DBX blacklists" | MS troubleshooting + community |
| CA-2023 EX binaries staged and unused at `C:\RemoteInstall\boot_EX\x64\` | live dir listing |

## Architecture verdict
The current stack — **WDS as PXE transport + custom WinPE running `deploy.ps1` (DISM apply +
inventory)** — is the correct, Microsoft-*supported* lightweight path on Server 2025.
SCCM (MS's literal rec) is licensed/overkill; MDT is retired (2025); pure iPXE re-breaks Secure
Boot (no CA-2023 iPXE shim exists yet). **Keep the architecture.**

---

## What was changed (live, on pc-deploy 192.168.5.141)

Overwrote in place (DHCP option 67 path unchanged → no UniFi edit needed):

| Active file (`C:\RemoteInstall\Boot\x64\`) | Replaced with (CA-2023) |
|---|---|
| `wdsmgfw.efi` (1,093,952 B, PCA-2011) | `boot_EX\x64\wdsmgfw_EX.efi` (1,171,224 B, **UEFI CA 2023**) |
| `bootmgfw.efi` (2,756,512 B, PCA-2011) | `boot_EX\x64\bootmgfw_EX.efi` (3,055,456 B, **UEFI CA 2023**) |
| `en-US\wdsmgfw.efi.mui` | EX `.mui` |
| `en-US\bootmgfw.efi.mui` | EX `.mui` |

Post-swap verify: both active binaries now contain the `UEFI CA 2023` reference. WDSServer = Running.

**Backups (same folders):** `*.pre-ex-20260625-155804.bak` (this session) plus the prior
`*.apr24.bak` / `*.wim-apr24.bak` / `*.june23.bak`. Rollback = copy a `.bak` back over the
active name and `Restart-Service WDSServer`.

---

## UPDATE — REAL root cause found (BCD missing winload path)

The EX swap was correct hygiene but **not** the cause. WDS diagnostic logs (Operational channel)
across 4 boot attempts proved the failure is **identical whether the boot manager is the old
PCA-2011 binary (size 2,756,512) or the new EX/CA-2023 binary (3,055,456)**: client downloads
`wdsmgfw.efi` → `bootmgfw.efi` → per-client BCD (`Tmp\x64uefi{GUID}.bcd`) → `wgl4_boot.ttf`,
then halts and **never requests `Boot.SDI` or `boot.wim`**. Server logs zero errors. So it is not
a signature/DBX problem and not the boot binaries.

**Cause:** the Windows Boot Loader entry `{430cd194-9089-44e0-ba65-1493922c4144}` in the boot
image's companion BCD (`C:\RemoteInstall\Boot\x64\Images\boot-winload-fix.wim.bcd`) was **missing
its `path` element**. A loader entry with no `path` gives bootmgr no application to launch → it
fails right after parsing the BCD (consistent with `0xC0000272` / STATUS_NO_MATCH), before any
ramdisk request. Hand-editing in a prior session (image is literally named "boot-winload-**fix**")
dropped it. This predates the NoPrompt change, matching Jason's recollection that the error came first.

**Fix applied (live):**
```
bcdedit /store "C:\RemoteInstall\Boot\x64\Images\boot-winload-fix.wim.bcd" \
  /set {430cd194-9089-44e0-ba65-1493922c4144} path \windows\system32\boot\winload.efi
Restart-Service WDSServer
```
Verified: the freshly generated served BCD (`Tmp\x64uefi{...}.bcd`) now contains
`path \windows\system32\boot\winload.efi`. Backup: `boot-winload-fix.wim.bcd.pre-pathfix-20260625-161316.bak`.

**Ruled out:** CVE-2026-0386 hands-free hardening — that governs the unattended Setup step
*inside* WinPE; our failure is in bootmgr *before* WinPE loads. NoPrompt prompt policy — error
predates it.

**Credential caching:** pc-deploy cred now cached DPAPI-encrypted at `C:\Users\ENG2\.pc-deploy-cred.xml`
(user+machine bound). Use `Import-Clixml` — no more `op` calls per command.

## UPDATE 2 — CONFIRMED root cause: revoked winload inside the WinPE WIM

Jason's Secure Boot test was decisive:
- Reset Secure Boot keys to factory → no change (still 0xc0000272, SB ON)
- Enabled "Allow Microsoft 3rd Party UEFI CA" → no change
- **Secure Boot OFF → boots to WinPE** (no NIC driver, separate issue)

WDS Operational log, post path-fix, three attempts:
- SB ON (16:17, 16:20): wdsmgfw → bootmgfw → BCD → fonts, **stops before Boot.SDI**
- SB OFF (16:23): same, then **Boot.SDI → full boot-winload-fix.wim (536MB) → WinPE**

So the EX `bootmgfw` loads fine under Secure Boot; the stage Secure Boot rejects is the **OS loader
`winload.efi` *inside* the WIM**. WIM metadata: **build 10.0.26100.1, created April 2024** — the
original 24H2 WinPE, predating the CVE-2023-24932 / KB5025885 boot-manager revocations now enforced
in firmware DBX/SBAT. Factory-key reset does NOT clear DBX/SBAT, so the old winload stays rejected.
`0xc0000272` ≈ STATUS_NO_MATCH = no trusted match for the image being loaded. Every observation fits.

**This is a known, documented condition.** Authoritative remediation (GaryTown KB5025885; TechDirect-
Archive "Update WinPE Boot Images with Windows UEFI CA Certificates", Apr 2026): the boot-critical
files (winload/bootmgr/kernel) in the WinPE WIM must be brought to a current **patched** build —
done by applying the latest 24H2 (26100) SSU+LCU to the mounted WIM, then re-exporting. The WDS-side
`wdsmgfw_EX`/`bootmgfw_EX` we already swapped are the correct CA-2023 NBP/boot-manager (one commenter
confirms the unpatched `wdsmgfw.efi` is 2011-signed and SB-rejected — we already handled that).

### Remediation plan (pending Jason's go-ahead)
1. Back up `boot-winload-fix.wim`.
2. Mount it; apply latest 26100 SSU + LCU (`.msu` from Microsoft Update Catalog) via `Add-WindowsPackage`.
3. **Also inject the correct NIC driver for the ThinkPad P14s Gen 5** (current injected driver is Intel
   I219-V, wrong for this model — why WinPE has no network). Fixes the second problem in the same pass.
4. DISM cleanup, commit, export, re-register/refresh the WDS boot image.
5. Test IMAGE-ME with Secure Boot ON.

Alternative: clean WinPE rebuild from a patched ADK (more steps; discards accumulated cruft).

## SESSION END STATE (2026-06-25 PM)

### Confirmed by Jason's Secure Boot test
- Reset Secure Boot keys to factory → no change
- "Allow Microsoft 3rd Party UEFI CA" ON → no change
- **Secure Boot OFF → boots to WinPE** (no NIC driver). WDS log: SB-OFF reaches Boot.SDI + full WIM;
  SB-ON stops before Boot.SDI. ⇒ Secure Boot rejects the OS-loader (`winload`) stage. Root cause = the
  WIM is build **26100.1 (Apr 2024)**, whose `winload` predates the enforced DBX/SBAT revocations.

### Done this session
- EX/CA-2023 boot chain swapped in (wdsmgfw/bootmgfw). BCD missing `path` fixed. Both verified.
- **ADK 10.1.26100.2454 + WinPE add-on installed** on pc-deploy.
- **pc-deploy maintenance:** Windows Update current (26100.32995, 0 pending). Dell Command Update
  installed and applied 11 driver updates (Intel HID/SerialIO/UHD/RST/DPTF, NVIDIA Quadro, Realtek
  card reader + audio, Goodix fingerprint, Killer WiFi/BT). `.NET 8` runtime + **PowerShell 7.6.3**
  installed (PATH + remoting endpoint). A reboot will clear the last few driverless devices (GPU/chipset).
- Repo committed + pushed to GitHub.
- Cred cached DPAPI at `C:\Users\ENG2\.pc-deploy-cred.xml`.

### THE ONE REMAINING STEP — build a patched WinPE (winload not revoked)
The fix is a WinPE whose boot files are current. Options, in order of preference:
1. **Apply latest 24H2 (26100) SSU+LCU to a WinPE**, then register with WDS. *Blocked right now:*
   `catalog.update.microsoft.com` is returning its transient "please try again later" error (MSCatalog
   retried ~12×). Retry later, or download the LCU `.msu` manually from the catalog in a browser.
2. **Use the host's serviced WinRE image as the base** (catalog-free). The fully-patched host's
   `WinRE.wim` has a current, non-revoked, version-matched winload. Stage via `reagentc /disable`
   (copies to `C:\Windows\System32\Recovery\WinRE.wim`), copy it out, `reagentc /enable`. Then add
   WinPE OCs (WMI, NetFx, PowerShell, Scripting, StorageWMI), inject deploy.ps1/startnet + the NIC
   driver, export, register with WDS. *(First attempt staged nothing — re-try; WinRE confirmed Enabled.)*
3. Copype from the new ADK gives 26100.1 (still revoked) — must then apply the LCU (option 1).

Also fold in: **inject the correct NIC driver for IMAGE-ME (ThinkPad P14s Gen 5)** — current WIM has
Intel I219-V (wrong), which is why SB-OFF WinPE had no network. Identify its actual NIC (likely a
USB-C dock Realtek/Intel GbE) and add that driver to the rebuilt WIM.

Then: register the rebuilt WIM, regenerate the WDS BCD (keep the `path` element), and have Jason
PXE-boot IMAGE-ME with **Secure Boot ON**. Expected: boots cleanly to the deploy prompt.

## ✅ PATCHED WinPE BUILT & REGISTERED (catalog-free, via WinRE base)

Since `catalog.update.microsoft.com` was down for the LCU, used the **host's serviced WinRE image
as the WinPE base** — already at build **26100.32995** with a current, non-revoked, version-matched
winload. Build steps (all on pc-deploy, scripted in `C:\WinPE-src\`):
1. `reagentc /disable` → staged `WinRE.wim` (26100.32995) → copied to `C:\WinPE-src\winre-base.wim`
   → `reagentc /enable` (WinRE confirmed back Enabled).
2. Copied base → mounted → added OCs **WinPE-NetFx, WinPE-PowerShell, WinPE-DismCmdlets** (+en-US)
   so `deploy.ps1` can run (WinRE lacks PowerShell by default; WMI/Scripting/StorageWMI already present).
3. Removed WinRE's `winpeshl.ini` so it boots to `startnet.cmd` (not the recovery UI).
4. Baked `startnet.cmd` + `deploy-boot.ps1` + `toolkit.ps1` into `X:\Windows\System32\`.
5. Committed + exported → `winpe-deploy-final.wim` (784 MB).
6. `Remove-WdsBootImage` old broken image; `Import-WdsBootImage` new one as
   **"Juniper WinPE (patched 26100.32995)"** (now the only x64 boot image).
7. **Re-applied the BCD `path` fix** — this WDS/Server-2025 build generates loader entries WITHOUT
   `path \windows\system32\boot\winload.efi` on import (systemic, not a hand-edit). Set it on
   `winpe-deploy-final.wim.bcd` + restarted WDS; served BCD now has the path.

State now: NBP `wdsmgfw_EX`+`bootmgfw_EX` (CA-2023) → BCD (with path) → **winpe-deploy-final.wim
(winload 26100.32995, non-revoked)** → PowerShell WinPE → `deploy-boot.ps1`. DHCP opt 67 unchanged.

### TEST: PXE-boot IMAGE-ME with **Secure Boot ON**
Expected: clears `0xc0000272`, boots to the **"Juniper Design – PC Deployment System"** prompt
(T=toolkit, D=deploy). That confirms the Secure Boot + winload fix end-to-end.

### If it boots but has no network (NIC)
The WIM relies on WinRE's inbox NIC drivers. If IMAGE-ME (ThinkPad P14s Gen 5, Lenovo type **21G2**)
has no network in WinPE, inject its NIC driver: `21G2-driver-manifest.json` +
`scripts/09-inject-usb-nic-drivers.ps1` are on pc-deploy; mount `winpe-deploy-final.wim`,
`Add-WindowsDriver` the NIC `.inf`, commit, re-import. (Many P14s units PXE/network via a USB-C
dock → likely a Realtek USB GbE / RTL8153.)

## (Earlier) NEXT STEP — physical boot test

PXE-boot **IMAGE-ME** (ThinkPad P14s Gen 5, MAC C8-53-09-2D-0D-56) **with Secure Boot ON**
(F12 → Network/PXE boot).

**Pass:** gets past `0xc0000272` → Windows Boot Manager dots → WinPE → `deploy.ps1` prompt.
→ Secure Boot PXE is solved. Proceed to a full image run.

**If it now shows a "Windows Setup / WDS client deprecated" message** (Wall 2): that means the
custom WinPE is still invoking WDS-mode Setup. Fix = ensure `startnet.cmd` runs `deploy.ps1`
directly. (Not expected — image is custom WinPE, WDS unattend policy is disabled.)

**If still `0xc0000272` with Secure Boot ON:** boot once with Secure Boot OFF to confirm the
chain works, then check whether IMAGE-ME has the **Windows UEFI CA 2023** enrolled in its db
(`Get-SecureBootUEFI -Name db`); if absent it needs the KB5025885-era db update.
