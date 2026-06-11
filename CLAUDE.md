# CLAUDE.md
<!-- push-automation-breadcrumb -->
## Pushing this repo

Don't push ad-hoc. Pushing is handled by the consolidated automation
(master `C:\dev\dev-push-automation\push-all.ps1`, canonical home GitLab
`automation/dev-push-automation`). From this repo, run:

```powershell
.\push.ps1            # full pipeline for THIS repo (commit + brand PDFs + push)
.\push.ps1 -DryRun    # preview only
```

`push.ps1` calls the master scoped to this repo. The master auto-commits work,
regenerates **Juniper**-branded doc PDFs (only if this repo has a `docs/pdf/`
folder), pushes to this repo's own origin (**GitHub**), and reverts pure
`docs/pdf/*.pdf` timestamp churn. The daily `push-changes-to-github` scheduled
task runs the master across every repo under C:\dev. Brand for this repo:
**Juniper** (GitHub/business = Juniper; personal GitLab = FatalException).

## Project overview

This repo controls the **pc-deploy** imaging server (renamed from DESKTOP-I8UM43L,
IP 192.168.5.141). It PXE-boots target PCs and automates:

- Windows 10 and 11 unattended installation (WinPE + DISM, answer files in `unattend/`)
- All Windows updates (`03-windows-update.ps1`)
- MSI and winget package installs + inventory agent registration (`04-install-packages.ps1`)
- Printer queue setup (`05-setup-printers.ps1`)
- Wi-Fi join (`06-join-wifi.ps1`)
- Bloatware and feature removal (`07-remove-bloatware.ps1`)

The Ubiquiti router at `192.168.0.1` needs DHCP options 66/67 set for PXE —
see `scripts/02-setup-dhcp-options.ps1`.

## Secrets policy

**No passwords, tokens, PSKs, or usernames in scripts or this repo.**
All secrets are in 1Password and retrieved at runtime via `op read` or
`op run`. The 1Password CLI (`op`) must be authenticated before running
any script that calls it.

## Imaging stack (pc-deploy is Windows 11, not Windows Server)

**WDS is NOT available on Windows 11** — it is a Windows Server-only role.
**MDT was retired by Microsoft in 2025** — the download URL was removed.

The correct stack for a Windows 11 imaging server is:
- **Windows ADK + WinPE Add-on** — provides DISM, WinPE build tools *(installed)*
- **Custom WinPE image** — `winpe/startnet.cmd` + `winpe/deploy.ps1` injected at build time
- **tftpd64** — PXE + TFTP server (installed by `01c-build-winpe.ps1`)

`01b-configure-mdt.ps1` is archived/obsolete — do not run it.

## Key paths (on pc-deploy)

- WinPE workspace (build time): `C:\WinPE_amd64\`
- TFTP root + boot media: `C:\tftpd64\`
- Deploy share (WIM images, scripts, unattend): `C:\deploy\` → `\\192.168.5.141\deploy$`
- Post-install scripts: `\\192.168.5.141\deploy$\scripts\`

## Script run order (first-time server setup)

1. `00-rename-server.ps1` — rename + reboot  *(done)*
2. `01a-enable-remote-access.ps1` — WinRM + deploy$ share *(must run AS ADMIN)*
3. `02-setup-dhcp-options.ps1` — verify Ubiquiti DHCP options 66/67  *(done)*
4. `01-setup-wds.ps1` — install ADK + WinPE Add-on *(ADK+WinPE done)*
5. `01c-build-winpe.ps1` — download tftpd64, build custom WinPE, populate TFTP root
6. `01d-setup-deploy-share.ps1` — create `deploy$` share + copy scripts/unattend
7. Copy WIM files: mount Windows ISOs → `copy install.wim C:\deploy\images\win11.wim`

## Script run order (per target PC, post-install)

WinPE `deploy.ps1` handles: partition → DISM apply → unattend inject → bcdboot → reboot

After first logon (via `FirstLogonCommands` in unattend):
03 → 04 → 07 (05 and 06 can be added as needed)

## Router access

Ubiquiti at `192.168.0.1` — credentials in 1Password.
DHCP options: `66` = TFTP server IP of pc-deploy (`192.168.5.141`),
`67` = boot file = `boot\bootmgfw.efi` (UEFI PXE).

## Local DNS records (UniFi static DNS)

Managed via UniFi API — `POST/PUT https://192.168.0.1/proxy/network/v2/api/site/default/static-dns`
with `X-API-Key` header (key in `op://Private/Unifi API Key (Inventory)/Token`).

| Hostname | Type | Value |
|---|---|---|
| `pc-deploy.juniperdesign.local` | A | `192.168.5.141` |
| `inventory.juniperdesign.local` | A | `192.168.5.141` |
| `inv.juniperdesign.local` | A | `192.168.5.141` |

## Inventory server (pc-deploy)

FastAPI + PostgreSQL 16 running natively on pc-deploy as `JuniperInventory` Windows service.
- App: `C:\inventory\app\` — service managed by NSSM (`C:\nssm\nssm.exe`)
- DB data: `C:\PGdata\`
- Logs: `C:\inventory\uvicorn.log`, `C:\inventory\uvicorn-err.log`
- HTTP: `http://192.168.5.141:8080/` (also `http://inventory.juniperdesign.local:8080/`)
- Secrets: `op://Private/inventory-server/` — db-password, pg-superpassword
- DPAPI cache on ENG-2: `C:\Users\ENG2\.juniper-inv-secrets.xml`
- Service env vars (UNIFI_HOST, UNIFI_API_KEY, DATABASE_URL, etc.) stored in registry:
  `HKLM:\SYSTEM\CurrentControlSet\Services\JuniperInventory\Environment`
