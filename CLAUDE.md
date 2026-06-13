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

The Ubiquiti router at `192.168.0.1` needs DHCP options 66/67 set for PXE -
see `scripts/02-setup-dhcp-options.ps1`.

## Secrets policy

**No passwords, tokens, PSKs, or usernames in scripts or this repo.**
All secrets are in 1Password and retrieved at runtime via `op read` or
`op run`. The 1Password CLI (`op`) must be authenticated before running
any script that calls it.

## Imaging stack (pc-deploy is Windows 11, not Windows Server)

**WDS is NOT available on Windows 11** - it is a Windows Server-only role.
**MDT was retired by Microsoft in 2025** - the download URL was removed.

The correct stack for a Windows 11 imaging server is:
- **Windows ADK + WinPE Add-on** - provides DISM, WinPE build tools *(installed)*
- **Custom WinPE image** - `winpe/startnet.cmd` + `winpe/deploy-boot.ps1` baked in at build time
  - Main deploy logic lives on the share: `scripts/deploy.ps1` -> `deploy$\scripts\deploy.ps1`
  - To update deploy.ps1: edit it, then copy to pc-deploy share (no WIM rebuild needed)
- **tftpd64** - PXE + TFTP server (installed by `01c-build-winpe.ps1`)

`01b-configure-mdt.ps1` is archived/obsolete - do not run it.

## Key paths (on pc-deploy)

- WinPE workspace (build time): `C:\WinPE_amd64\`
- TFTP root + boot media: `C:\tftpd64\`
- Deploy share (WIM images, scripts, unattend): `C:\deploy\` -> `\\192.168.5.141\deploy$`
- Post-install scripts + deploy.ps1: `\\192.168.5.141\deploy$\scripts\`
- WIM images: `\\192.168.5.141\deploy$\images\` (`win11-home.wim`, `win11-pro.wim`, `win10.wim`)
- Driver store: `C:\deploy\drivers\` -> `\\192.168.5.141\deploy$\drivers\`
  - Subfolders by model slug, e.g. `dell-xps-13-9380\`, `lenovo-thinkpad-t14s\`
  - `manifest.json` in root maps model slugs to WMI model strings (for DISM injection)
  - The inventory DB is the source of truth; `GET /api/drivers/manifest.json` regenerates
    the manifest from confirmed_working entries on demand

## Script run order (first-time server setup)

1. `00-rename-server.ps1` - rename + reboot  *(done)*
2. `01a-enable-remote-access.ps1` - WinRM + deploy$ share *(must run AS ADMIN)*
3. `02-setup-dhcp-options.ps1` - verify Ubiquiti DHCP options 66/67  *(done)*
4. `01-setup-wds.ps1` - install ADK + WinPE Add-on *(ADK+WinPE done)*
5. `01c-build-winpe.ps1` - download tftpd64, build custom WinPE, populate TFTP root
6. `01d-setup-deploy-share.ps1` - create `deploy$` share + copy scripts/unattend
7. Copy WIM files: export single-edition WIMs to `C:\deploy\images\`:
   - `win11-home.wim` (index 1 = Home from multi-edition ISO)
   - `win11-pro.wim`  (index 6 = Pro from multi-edition ISO)
   - `win10.wim`      (multi-edition ISO, Win10 Pro = index 6)

## Script run order (per target PC, post-install)

WinPE `deploy.ps1` handles: partition -> DISM apply -> unattend inject -> bcdboot
-> driver injection (DISM /Add-Driver from manifest.json) -> reboot

After first logon (via `FirstLogonCommands` in unattend):
03 -> 04 -> 07 (05 and 06 can be added as needed)

`03b-install-catalog-drivers.ps1` (new) - post-boot online driver install from the
inventory catalog. Auto-detects manufacturer/model/OS from WMI; queries
`/api/drivers?status=confirmed_working`; installs `.inf` via pnputil, `.msi` via
msiexec /qn, `.exe` via /s /norestart; verifies SHA256 when present. Pass
`--IncludeUnconfirmed` on first run for brand-new hardware. `deploy.ps1` has a
`Get-DriverManifest` helper that tries `/api/drivers/manifest.json` first and
falls back to the on-disk manifest.json if the inventory server is unreachable.

`09-update-driver-warehouse.ps1` - audit script; cross-references models in inventory,
driver catalog status, and actual files on disk. Run on pc-deploy at any time.

## Router access

Ubiquiti at `192.168.0.1` - credentials in 1Password.
DHCP options: `66` = TFTP server IP of pc-deploy (`192.168.5.141`),
`67` = boot file = `EFI\Boot\bootx64.efi` (UEFI PXE - copype puts the bootloader here).

## Local DNS records (UniFi static DNS)

Managed via UniFi API - `POST/PUT https://192.168.0.1/proxy/network/v2/api/site/default/static-dns`
with `X-API-Key` header (key in `op://Private/Unifi API Key (Inventory)/Token`).

| Hostname | Type | Value |
|---|---|---|
| `pc-deploy.juniperdesign.local` | A | `192.168.5.141` |
| `inventory.juniperdesign.local` | A | `192.168.5.141` |
| `inv.juniperdesign.local` | A | `192.168.5.141` |

## Inventory server (pc-deploy)

FastAPI + PostgreSQL 16 running natively on pc-deploy as `JuniperInventory` Windows service.
- App: `C:\inventory\app\` - service managed by NSSM (`C:\nssm\nssm.exe`)
- DB data: `C:\PGdata\`
- Logs: `C:\inventory\uvicorn.log`, `C:\inventory\uvicorn-err.log`
- HTTP: `http://192.168.5.141:8080/` (also `http://inventory.juniperdesign.local:8080/`)
- Secrets: `op://Private/inventory-server/` - db-password, pg-superpassword
- DPAPI cache on ENG-2: `C:\Users\ENG2\.juniper-inv-secrets.xml`
- Service env vars (UNIFI_HOST, UNIFI_API_KEY, DATABASE_URL, etc.) stored in registry:
  `HKLM:\SYSTEM\CurrentControlSet\Services\JuniperInventory\Environment`

### Inventory agent

`scripts/static/install_agent.ps1` is the agent script. It is served dynamically by the
inventory server at `GET /static/install_agent.ps1` - the server replaces the
`##INVENTORY_API##` placeholder with the live base URL before sending.

The agent collects a full WMI hardware snapshot (CPU, RAM, disks, GPU, BIOS serial,
chassis type, OS, BitLocker state, Defender status, TPM, Secure Boot, installed software)
and POSTs it to `POST /ingest/endpoint`. The server resolves which device record to
upsert using **serial number first**, then ethernet MAC, then wireless MAC, then hostname.
This means a machine re-resolves to its existing inventory record after a re-image as
long as the BIOS serial number is unchanged.

One-liner (run on any imaged PC to register or re-register):
```powershell
irm http://inventory.juniperdesign.local:8080/static/install_agent.ps1 | iex
```

`04-install-packages.ps1` runs this automatically at the end of every imaging run.

**Agent files are synced automatically:** `push.ps1` in this repo compares
`scripts/static/install_agent.ps1`, `JuniperInventoryAgent.msi`, and
`JuniperInventoryAgent.json` against the live server and pulls any newer
version before committing. Never manually copy these files.

### Inventory API for imaging decisions

Full API reference: **`C:\dev\inventory\Computer Inventory\docs\imaging-api.md`**

Auth is not required for any endpoint used by imaging scripts. All `/api/` and
`/ingest/` routes bypass the session gate.

Key endpoints:
- `GET /api/drivers` - driver catalog (manufacturer, model, OS filters; see below)
- `GET /api/drivers/manifest.json` - DISM-compatible manifest generated from DB
- `GET /api/devices?q={serial}` - look up a machine by serial number
- `GET /api/device/{id}` - full device detail (OS, BitLocker, TPM, user, etc.)
- `POST /ingest/endpoint` - register or update a machine record
- `GET /api/agent/latest` - current agent version + SHA256
- `GET /static/JuniperInventoryAgent.msi` - MSI download

### Driver catalog

The inventory database tracks individual drivers by hardware model + OS. No files
are copied between servers - the API returns the direct UNC path on the deploy share.

#### Getting drivers for a machine

```
GET /api/drivers?manufacturer=Lenovo&model=ThinkPad T14s&os_filter=Windows 11&status=confirmed_working
```

All params optional. Entries with `model=NULL` apply to all models of a manufacturer.
Response: array of driver objects. Key fields for imaging scripts:

| Field | Use |
|---|---|
| `unc_path` | `\\192.168.5.141\deploy$\drivers\<file_path>` - pass directly to pnputil or Copy-Item |
| `file_path` | Relative to `C:\deploy\drivers\` - same convention as manifest.json `driverPath` |
| `status` | Only act on `confirmed_working`. Skip `confirmed_buggy`. |
| `update_available` | `true` when `latest_version` differs from `driver_version` |
| `sha256` | File hash if populated - verify before running |

#### PowerShell pattern for post-install driver install

```powershell
$wmi = Get-WmiObject Win32_ComputerSystem
$drivers = Invoke-RestMethod (
    "http://192.168.5.141:8080/api/drivers" +
    "?manufacturer=$([uri]::EscapeDataString($wmi.Manufacturer.Trim()))" +
    "&model=$([uri]::EscapeDataString($wmi.Model.Trim()))" +
    "&os_filter=Windows+11&status=confirmed_working"
)
foreach ($d in $drivers) {
    if (-not $d.unc_path) { continue }
    if ($d.unc_path -match '\.inf$') {
        pnputil /add-driver $d.unc_path /install
    } elseif ($d.unc_path -match '\.(exe|msi)$') {
        Start-Process $d.unc_path -ArgumentList '/quiet','/norestart' -Wait
    }
}
```

#### DISM offline injection via manifest.json

`deploy.ps1`'s `Invoke-DriverInjection` reads `manifest.json` and calls
`dism /Add-Driver /Driver:"\\server\deploy$\drivers\<driverPath>" /Recurse`
for each model entry. To regenerate manifest.json from the DB (confirmed_working only):

```
GET /api/drivers/manifest.json
```

This returns a file in exactly the format deploy.ps1 expects - lets the DB drive
the manifest rather than editing the JSON by hand.

#### Driver warehouse audit

Cross-references inventory device models, driver catalog status, and on-disk files:

```powershell
# On pc-deploy as Administrator:
.\scripts\09-update-driver-warehouse.ps1
```

Reports: models in inventory missing from manifest, manifest entries with no files
on disk, catalog entries with a newer version available, entries marked confirmed_buggy.

#### Adding a new driver

Use the web UI at `http://192.168.5.141:8080/drivers` (admin login required).
Set `file_path` relative to `C:\deploy\drivers\` - e.g. `lenovo-thinkpad-t14s\network\Intel-NIC.exe`.
This is the same path convention as manifest.json `driverPath`. After saving, test the
driver and mark it confirmed_working or confirmed_buggy via the status panel.

## Windows activation (OEM UEFI key)

`04-install-packages.ps1` includes an OEM activation step that:
1. Reads the embedded product key from UEFI firmware via
   `SoftwareLicensingService.OA3xOriginalProductKey` (WMI)
2. Installs it with `slmgr.vbs /ipk` and activates with `slmgr.vbs /ato`
3. **Never logs the key value** - only slmgr's result text is written to output
4. Gracefully skips on VMs or hardware without an embedded OEM key

This works for any OEM PC shipped with Windows 8 or later (ACPI MSDM table).
Non-OEM machines will activate via digital license or KMS automatically.
