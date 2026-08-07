# WinPE Build & USB Runbook (post-WDS migration)

**Server:** pc-deploy (192.168.5.141) · **Last verified:** 2026-08-07
**Scope:** How the WinPE deployment boot image is built, what goes in it, how it
reaches machines (PXE + USB), and the exact steps to (re)build a bootable USB.

> Read this before touching the imaging boot image. The pre-July-2026 tooling
> (`01c-build-winpe.ps1`, tftpd64, `C:\WinPE_amd64`, `WimUpdate4`) is **dead** —
> see "Retired / do-not-use" at the bottom. Everything live now lives in
> `C:\WinPE-src\` on pc-deploy.

---

## 1. Architecture at a glance

There is **one** boot image, delivered **two** ways:

```
            C:\WinPE-src\  (the build workshop, all SYSTEM scheduled tasks)
                 |
   build.ps1  -> winpe-deploy-final.wim   (base build: OCs, deploy scripts, startnet, OpenSSH)
   (+ driver/NIC inject scripts add storage/NIC .inf on top)
                 |
                 +-------------------------------+
                 |                               |
        PXE (network boot)                 USB (physical stick)
        served by WDS from:               written by usb.ps1 from:
   C:\RemoteInstall\Boot\x64\Images\        C:\WinPE-src\winpe-deploy-final.wim
        winpe-deploy-final.wim              -> Disk 1 (SanDisk), label JUNIPER-PE
```

- **PXE is served by WDS**, not TFTP. The old **tftpd64 stack is retired**
  (`C:\tftpd64` no longer exists). WDS transfers the whole boot image to the
  client before WinPE starts, so image size matters for boot time (see §6).
- The two copies of `winpe-deploy-final.wim` (WDS at `C:\RemoteInstall\...` and
  the workshop at `C:\WinPE-src\...`) must be kept **identical**. They drifted
  before (see §7); always deploy the same file to both.

### Boot flow on the target machine
`startnet.cmd` → `wpeinit` → starts `sshd` (best-effort) → runs
`X:\Windows\System32\deploy-boot.ps1`. `deploy-boot.ps1` waits for network, maps
`\\pc-deploy\deploy$` as `junadmin`, then either launches the **Edge kiosk**
imaging screen (`X:\imaging-screen.html`, tailing `X:\deploy_log.txt`) with
`deploy.ps1` running hidden, or falls back to the **console** `deploy.ps1` if
Edge can't start. The full deploy logic (`deploy.ps1`) lives on the share, so
day-to-day changes to it do **not** require a WIM rebuild — only changes to
`deploy-boot.ps1`, `startnet.cmd`, `toolkit.ps1`, `imaging-screen.html`, staged
Edge, or injected drivers require a rebuild.

---

## 2. The build workshop — `C:\WinPE-src\`

| File | Runs as | Purpose |
|---|---|---|
| `build.ps1` (`WINPE-Build` task) | SYSTEM | Master build from `winre-base.wim`: add OCs (NetFx/PowerShell/DismCmdlets), drop `winpeshl.ini`, bake `deploy-boot.ps1`+`toolkit.ps1` (from `C:\deploy\scripts\winpe\`), write `startnet.cmd`, bake OpenSSH + host keys, export compressed `winpe-deploy-final.wim`. |
| `bake.ps1` | SYSTEM | Overlay the credentialed `deploy-boot-cred.ps1` (junadmin password substituted) into the final WIM. |
| `usb.ps1` | admin | **The USB writer.** Builds an ADK media tree in `C:\WinPE_usb\media`, copies the WIM as `boot.wim`, uses the CA-2023 Secure Boot loader (`C:\RemoteInstall\boot_EX\x64\bootmgfw_EX.efi`), fixes the media BCD, auto-detects the single USB disk (guards: USB bus, <64 GB, not system/boot), formats FAT32 `JUNIPER-PE`, robocopies. |
| NIC/storage inject scripts (`nic-only.ps1`, `intel-nic.ps1`, `realtek-nic.ps1`, `winpe-nic-inject.ps1`, …) | SYSTEM | Mount the WIM and `Add-WindowsDriver` storage/NIC `.inf`. **These run AFTER `build.ps1`** — a fresh `build.ps1` does NOT include them. |
| `inspect*.ps1`, `wim-verify.ps1` | SYSTEM | Read-only WIM sanity checks (file presence, `toolkit.ps1` BOM/parse). |
| `wim-enc-fix.ps1` | SYSTEM | One-off encoding fix applied directly to the WDS WIM (WDS stopped around it). |

**Key consequence:** because drivers are injected *after* the base build,
**never** promote a raw `build.ps1` output without re-injecting the current
driver set — or you regress "can't see the disk / no network" on machines whose
NICs/storage need those `.inf`s.

---

## 3. Drivers currently in the live image (baseline 2026-08-07)

7 third-party `[Net]` drivers (verify with `Get-WindowsDriver -Path <mount>`):

- Intel `e1r68x64.inf` (12.18.11.1 and 12.18.9.6)
- Intel `e1dn.inf` (20.0.2.19)
- Realtek `ws640x64.inf` (10.50.511.2021)
- Microsoft USB-C RNDIS dongle: `netrndis.inf`, `usbnet.inf`, `rndiscmp.inf`

If a rebuild shows fewer than 7, the NIC-inject step was skipped — re-run it
before promoting.

---

## 4. Credential handling (junadmin password)

`deploy-boot.ps1` carries `$DeployPass = '##WINPE_PASS##'` as a **placeholder**;
the real junadmin password is substituted only into `deploy-boot-cred.ps1` and
baked into the WIM. Rules:

- The placeholder must **never** be replaced with a real password in any file in
  git or on the share. Only the in-WIM copy holds the real value.
- Substitute with a literal string replace (`.Replace()`), never regex `-replace`
  (a `$` in the password would corrupt it).
- Source of the password: the junadmin credential (e.g. `push-cred.xml`
  PSCredential, or `op://Private/pc-deploy/password`). Never echo it to console,
  a log, or chat. Scrub `deploy-boot-cred.ps1` after baking.

---

## 5. RUNBOOK — build a bootable USB stick

**Prereqs:** run on pc-deploy (or remote as junadmin/SYSTEM), USB stick inserted
(the only USB disk present), ADK + WinPE add-on installed, live WIM present.

### 5a. If you only changed `deploy.ps1` (share logic)
Nothing to rebuild. `deploy.ps1` is read from `\\pc-deploy\deploy$\scripts\` at
boot. Just re-run the deploy.

### 5b. If you changed `deploy-boot.ps1`, `startnet.cmd`, `toolkit.ps1`, the imaging screen, Edge, or drivers
You must update the WIM, then write media.

1. **Update the source files** in `C:\deploy\scripts\winpe\` (`deploy-boot.ps1`
   with the `##WINPE_PASS##` placeholder, `toolkit.ps1`, `imaging-screen.html`).
2. **Produce the credentialed boot script:** write `C:\WinPE-src\deploy-boot-cred.ps1`
   = the new `deploy-boot.ps1` with the junadmin password substituted (see §4).
3. **Patch the live image (driver-safe method):** copy the current live WIM to a
   work copy, mount it, then:
   - overwrite `\Windows\System32\deploy-boot.ps1` with the credentialed version,
   - copy `imaging-screen.html` to the WIM root (`X:\imaging-screen.html`),
   - stage installed Edge: `robocopy "<Edge\Application>" "<mount>\edge" /E`,
   - (SSH) copy `C:\Windows\System32\OpenSSH\*` → `<mount>\Windows\System32\OpenSSH`,
     copy host keys/`sshd_config` from `C:\WinPE-src\ssh\` → `<mount>\ProgramData\ssh`,
     ensure `startnet.cmd` has the `sshd` start block,
   - `Dismount-WindowsImage -Save`, then `Export-WindowsImage -CompressionType max`
     to a final file, and **verify** (mount read-only: `deploy-boot.ps1` has no
     `##WINPE_PASS##`, `imaging-screen.html` present, `edge\msedge.exe` present,
     `sshd.exe` present, `Get-WindowsDriver` count == expected).
   > A from-scratch `build.ps1` is the alternative, but only if you re-inject the
   > full driver set afterward (see §2–§3).
4. **Promote the verified WIM to BOTH targets, hash-verified identical:**
   - `C:\WinPE-src\winpe-deploy-final.wim` (USB source)
   - `C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim` (PXE) — stop
     `WDSServer`, copy, start `WDSServer`. Keep a `.bak-*` of the prior WIM.
5. **Write the stick:** run `C:\WinPE-src\usb.ps1` (auto-detects the single USB
   disk, formats `JUNIPER-PE`, writes media).
6. **HASH-VERIFY THE STICK (mandatory):** flush the volume cache
   (`Write-VolumeCache`), then compare SHA256 of `<USB>:\sources\boot.wim` against
   the source WIM. They **must** match. (A stick pulled before the write cache
   flushed once produced a correct-size but silently corrupt, unbootable image.)
7. **(Optional) Refresh the legacy media tree** so the old `01e` path can't hand
   out a stale stick: run `01f-refresh-usb-media.ps1` (republishes
   `C:\deploy\winpe-media` from the live WDS WIM).

### 5c. Booting a target machine
UEFI boot from the stick (or PXE). **Secure Boot may be left ON** — the media
uses the CA-2023 signed `bootmgfw_EX`. At the WinPE menu: `[T]` = toolkit,
`[D]` = deploy now, otherwise auto-deploys after 60 s. The Edge kiosk shows the
branded imaging screen; if Edge can't start it falls back to the console.

---

## 6. Image size note

Bundling Microsoft Edge makes the WIM large (~1.38 GB; Edge's binaries are
already-compressed PE files, so `max` compression barely shrinks it). Fine for
USB. For **PXE**, WDS must push the full ~1.4 GB to the client before WinPE
starts — expect a longer wait on network boot than the old ~800 MB image.

---

## 7. Findings / gotchas (so we stop re-chasing these)

- **WDS migration (2026-07-21):** moved off tftpd64 to WDS. All the media sources
  the old `01e-make-usb.ps1` knew about (`winpemedia$`, `tftpd64$`,
  `C:\WinPE_amd64`) ceased to exist; a stale stick then couldn't see the disk on
  an RST-mode machine. Live boot image is now `C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim`.
- **PXE = WDS, not TFTP.** Don't look for tftpd64; it's gone.
- **Two WIM copies drift.** Before this update, PXE (`RemoteInstall`, Jul 23, 7
  drivers, no SSH) and the workshop build (`WinPE-src`, Aug 4, 4 drivers, +SSH)
  had diverged **both directions** — the Aug-4 build had dropped 3 NIC drivers
  (both Intel `e1r68x64` + Realtek `ws640x64`) because `build.ps1` rebuilds from
  pristine `winre-base.wim` and the NIC-inject scripts run afterward. That's why
  the Aug-4 build was never promoted. **Always deploy the same verified file to
  both paths and hash-check.**
- **`build.ps1` injects no drivers.** Patch the known-good live WIM (driver-safe)
  or re-inject drivers after a from-scratch build.
- **Edge in WinPE** renders the modern imaging screen (Trident/MSHTA cannot — no
  CSS custom properties / `min()` / variable fonts). Edge is staged from the
  installed, code-signed copy on pc-deploy — never a downloaded binary.
- **`##WINPE_PASS##` discipline** — see §4. Never commit a real password.
- **Always hash-verify a freshly written stick** — see §5 step 6.
- **DISM as SYSTEM:** WIM mount/dismount is run as SYSTEM (scheduled task) or as a
  normal elevated local process (CIM `Win32_Process.Create` as junadmin). WinRM's
  process isolation breaks DISM dismount — don't run the DISM steps over WinRM.

### Retired / do-not-use (pre-migration tooling — slated for cleanup)
- `01c-build-winpe.ps1` (built into `C:\WinPE_amd64` + tftpd64) — dead path.
- tftpd64 stack / `C:\tftpd64` — removed.
- `WimUpdate4` task + `wim-update4.ps1` / `wim-update-deploy-boot.ps1` (targeted
  `C:\tftpd64` / `C:\WinPE_amd64`) — superseded by `build.ps1`/`bake.ps1`.
- `winpemedia$` / `tftpd64$` shares — gone.
