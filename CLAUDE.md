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
- **Custom WinPE image** — `winpe/startnet.cmd` + `winpe/deploy-boot.ps1` baked in at build time
  - Main deploy logic lives on the share: `scripts/deploy.ps1` → `deploy$\scripts\deploy.ps1`
  - To update deploy.ps1: edit it, then copy to pc-deploy share (no WIM rebuild needed)
- **tftpd64** — PXE + TFTP server (installed by `01c-build-winpe.ps1`)

`01b-configure-mdt.ps1` is archived/obsolete — do not run it.

## Key paths (on pc-deploy)

- WinPE workspace (build time): `C:\WinPE_amd64\`
- TFTP root + boot media: `C:\tftpd64\`
- Deploy share (WIM images, scripts, unattend): `C:\deploy\` → `\\192.168.5.141\deploy$`
- Post-install scripts + deploy.ps1: `\\192.168.5.141\deploy$\scripts\`
- WIM images: `\\192.168.5.141\deploy$\images\` (`win11-home.wim`, `win11-pro.wim`, `win10.wim`)

## Script run order (first-time server setup)

1. `00-rename-server.ps1` — rename + reboot  *(done)*
2. `01a-enable-remote-access.ps1` — WinRM + deploy$ share *(must run AS ADMIN)*
3. `02-setup-dhcp-options.ps1` — verify Ubiquiti DHCP options 66/67  *(done)*
4. `01-setup-wds.ps1` — install ADK + WinPE Add-on *(ADK+WinPE done)*
5. `01c-build-winpe.ps1` — download tftpd64, build custom WinPE, populate TFTP root
6. `01d-setup-deploy-share.ps1` — create `deploy$` share + copy scripts/unattend
7. Copy WIM files: export single-edition WIMs to `C:\deploy\images\`:
   - `win11-home.wim` (index 1 = Home from multi-edition ISO)
   - `win11-pro.wim`  (index 6 = Pro from multi-edition ISO)
   - `win10.wim`      (multi-edition ISO, Win10 Pro = index 6)

## Script run order (per target PC, post-install)

WinPE `deploy.ps1` handles: partition → DISM apply → unattend inject → bcdboot → reboot

After first logon (via `FirstLogonCommands` in unattend):
03 → 04 → 07 (05 and 06 can be added as needed)

## Router access

Ubiquiti at `192.168.0.1` — credentials in 1Password.
DHCP options: `66` = TFTP server IP of pc-deploy (`192.168.5.141`),
`67` = boot file = `EFI\Boot\bootx64.efi` (UEFI PXE — copype puts the bootloader here).

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

### Inventory agent

`scripts/static/install_agent.ps1` is the agent script. It is served dynamically by the
inventory server at `GET /static/install_agent.ps1` — the server replaces the
`##INVENTORY_API##` placeholder with the live base URL before sending.

The agent collects a full WMI hardware snapshot (CPU, RAM, disks, GPU, BIOS serial,
chassis type, OS, BitLocker state, Defender status, TPM, Secure Boot, installed software)
and POSTs it to `POST /ingest/endpoint`. The server upserts the device record by MAC address.

One-liner (run on any imaged PC to register or re-register):
```powershell
irm http://inventory.juniperdesign.local:8080/static/install_agent.ps1 | iex
```

`04-install-packages.ps1` runs this automatically at the end of every imaging run.

The agent file lives on the server at `C:\inventory\app\static\install_agent.ps1`.
To update it: edit `scripts/static/install_agent.ps1` in this repo, then copy to the server:
```powershell
$s = New-PSSession -ComputerName 192.168.5.141
Copy-Item scripts\static\install_agent.ps1 -Destination C:\inventory\app\static\ -ToSession $s
Remove-PSSession $s
```

## Windows activation (OEM UEFI key)

`04-install-packages.ps1` includes an OEM activation step that:
1. Reads the embedded product key from UEFI firmware via
   `SoftwareLicensingService.OA3xOriginalProductKey` (WMI)
2. Installs it with `slmgr.vbs /ipk` and activates with `slmgr.vbs /ato`
3. **Never logs the key value** — only slmgr's result text is written to output
4. Gracefully skips on VMs or hardware without an embedded OEM key

This works for any OEM PC shipped with Windows 8 or later (ACPI MSDM table).
Non-OEM machines will activate via digital license or KMS automatically.
