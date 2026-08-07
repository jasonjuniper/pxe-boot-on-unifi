# scripts/winpe-src — reference copies of the live WinPE build pipeline

These are **reference/DR copies** of the scripts that actually build the WinPE
deploy image. The authoritative copies live on **pc-deploy at `C:\WinPE-src\`**
and run there (mostly as SYSTEM via scheduled tasks). Editing files here does
**not** change the build — sync changes to pc-deploy.

Full process and findings: [`../../docs/WINPE-USB-RUNBOOK.md`](../../docs/WINPE-USB-RUNBOOK.md)

| Script | Role |
|---|---|
| `build.ps1` | Master build from `winre-base.wim` (OCs, deploy scripts, startnet, OpenSSH) → `winpe-deploy-final.wim`. Injects **no drivers**. |
| `bake.ps1` | Overlay credentialed `deploy-boot-cred.ps1` into the WIM. |
| `usb.ps1` | The USB writer (ADK media + CA-2023 bootmgr, auto-detect single USB, FAT32 `JUNIPER-PE`). |
| `nic-only.ps1` (+ intel/realtek variants on server) | Inject storage/NIC `.inf` into the WIM (run AFTER build). |
| `inspect.ps1`, `inspect-boot.ps1`, `wim-verify.ps1` | Read-only WIM sanity checks. |
| `wim-enc-fix.ps1` | One-off WIM encoding fix (WDS stopped around it). |
| **`edge-inject.ps1`** | Modern-UI update step 1: patch a copy of the live WIM with Edge-kiosk `deploy-boot.ps1` + `imaging-screen.html` + staged Edge. |
| **`ssh-and-finalize.ps1`** | Step 2: add OpenSSH + startnet sshd block, compress-export final. |
| **`promote.ps1`** | Step 3: deploy the verified WIM to both PXE (`RemoteInstall`) and the USB source, hash-verified. |
| **`usb-verify.ps1`** | Post-write SHA256 check of the stick's `boot.wim` vs source. |

The three **bold** scripts are the reproducible modern-UI (Edge kiosk + SSH)
update authored 2026-08-07; run them in order, then `usb.ps1`, then `usb-verify.ps1`.
