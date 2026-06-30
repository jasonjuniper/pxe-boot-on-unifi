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

**WinPE phase** - `deploy.ps1` handles:
resolve machine + name/OS pre-fill (see below) -> partition -> DISM apply WIM
-> unattend inject -> bcdboot
-> offline driver injection (DISM /Add-Driver from manifest.json or live API)
-> pre-register machine in inventory (pushes chosen name + OS back) -> reboot

### WinPE serial via SMBIOS + OEM edition detection (WinPE limits)

Two hardware-identity reads in `deploy.ps1` are hardened so brand-new (never-inventoried)
machines pre-fill correctly. **WinPE reality, verified on ENG-2 (Lenovo P14s Gen 5) and
from the WinPE build (`01c-build-winpe.ps1` adds `WinPE-WMI` + `WinPE-NetFX`):**

- **Serial (`Get-SmbiosHardwareSerial`)** - reads the raw SMBIOS table via
  `Get-WmiObject -Namespace root\wmi -Class MSSmBios_RawSMBiosTables` (`.SMBiosData`)
  and parses the **Type 1** (System Information) Serial Number string (string-index at
  formatted-area offset `0x07`), with **Type 3** (Chassis) as a secondary. This needs
  **no `Add-Type`/csc** (WinPE-WMI provides the provider). The high-level WMI classes
  (`Win32_BIOS` / `Win32_SystemEnclosure`) return junk on **Lenovo ThinkPads in WinPE**
  (Dell works); the SMBIOS Type 1 serial is correct. Precedence: existing
  `Win32_BIOS`/`Enclosure`/`CSProduct` values first if valid, else the SMBIOS-parsed
  serial; same placeholder/`$_bogus` filter applies. **Validated:** on ENG-2 the parsed
  Type 1 serial (`PF5XFBL6`) == `(Get-CimInstance Win32_BIOS).SerialNumber` exactly.
- **OEM edition (`Get-OemMsdmInfo` + tiered default)** - the exact edition NAME is only
  computed by `SoftwareLicensingService`, which **does not exist in WinPE**; the MSDM
  ACPI table carries the product KEY, not the edition name (key->edition needs
  pkeyconfig). So the precise edition is **not readable in WinPE**. What we do:
  - Detect an embedded OEM/MSDM license via P/Invoke
    `GetSystemFirmwareTable('ACPI','MSDM')`. **HONEST LIMIT:** this needs `Add-Type`,
    which needs `csc.exe`; WinPE-NetFX ships only the .NET *runtime*, **not the
    compiler**, so `Add-Type` generally **fails in WinPE** and MSDM detection returns
    `Present=$false` there (it works in full Windows - verified on ENG-2: Add-Type
    compiles, MSDM present, 25-char key extractable). There is no `root\wmi` class that
    exposes an arbitrary ACPI table by signature, so MSDM cannot be read without P/Invoke.
    The product key is held in memory only - **never logged** to repo or shared logs.
  - **Edition-default tiers** (`$defaultOsKey`): (a) a precise `SoftwareLicensingService`
    edition name (`$slsEditionResolved`, full Windows only) wins over all; (b) inventory's
    last `os_key` from `Resolve-PriorDevice` wins for re-images over a mere business-SKU
    guess; (c) for new hardware with an OEM license present, default to **Pro** when the
    model is a Juniper business SKU (Lenovo ThinkPad/ThinkStation/`^21`/`^20`, Dell
    Precision/Latitude/OptiPlex, HP EliteBook/ProBook/ZBook/EliteDesk) - surfaced as
    "OEM digital license detected (defaulting to Windows 11 Pro for business SKU)"; (d)
    else fall through to the operator menu.

Both reads are wrapped in try/catch and best-effort - a missing provider or failed
compile never breaks imaging; the existing WMI/SLS reads remain as fallbacks.

### Name/OS inventory round-trip (10s pre-fill)

Before applying the image, `deploy.ps1` looks this machine up in inventory and
pre-fills the computer name and OS edition from its last record, then pushes the
operator's final choices back so the next re-image remembers them.

- **Resolution** (mirrors the server's own dedupe order): exact BIOS/chassis
  serial first (`GET /api/devices?q=<serial>`, filtered to `serial_number` exact),
  then primary/any MAC (`?q=<mac>`, filtered to `mac_address` exact). Junk serials
  ("to be filled", etc.) are skipped so it falls straight to MAC. Helper:
  `Resolve-PriorDevice`. Defaults: name = inventory `hostname`; OS edition = UEFI
  MSDM license (preferred, since the firmware key is authoritative) else inventory
  `os_caption`/`os` mapped to a WIM (`*11*Home*`->win11-home, `*11*Pro*`->win11-pro,
  `*10*`->win10-pro).
- **10s per-field countdown** (two INDEPENDENT fields, helper `Invoke-FieldCountdown`,
  modeled on the `[Console]::KeyAvailable`/`ReadKey` loop proven in
  `winpe/deploy-boot.ps1`): the Name field shows `Computer name [<lastName>]` and
  auto-accepts after 10s of no keypress; pressing any key stops the countdown and
  opens a validated `Read-Host` (Enter keeps the default). The OS field then runs
  its own separate 10s countdown defaulting to the resolved edition; a keypress
  opens the existing edition menu (Enter keeps the default). No default on a field
  -> today's mandatory prompt/menu for that field only.
- **Push back**: the existing pre-register step posts the final
  `hostname` + `os_caption` ("Microsoft <edition>") + ethernet/wireless MACs +
  serial to `POST /ingest/endpoint` (auth-free, WinPE-reachable). Best-effort,
  wrapped in try/catch - never blocks imaging if the server is down. No new endpoint
  was needed; `/ingest/endpoint` already resolves serial->MAC->hostname and upserts
  `hostname`/`os`/`os_caption`, so a re-image re-resolves to the same record.
- **Validate on next (re)image**: a known machine shows "Inventory match found"
  with the resolved-via source, the name default appears and auto-accepts at 10s
  (or a keypress lets you retype), the OS default appears and auto-accepts at 10s
  (or a keypress shows the menu), and after imaging the device record in inventory
  reflects the chosen name + OS. Brand-new hardware just prompts as before.

**After first logon** the `orchestrator.ps1` phase pipeline runs (driven by its
`$Phases` ordered map): `join-wifi` -> `windows-update` -> `install-packages` ->
`remove-bloatware` -> `setup-user` -> `file-associations`. (`03b` driver install +
the inventory agent are invoked from within `04`.)

**Wi-Fi is now the FIRST phase** (ahead of `windows-update`): the machine joins
office Wi-Fi before the long, multi-reboot update phase, so if someone unplugs
ethernet mid-update the box stays online and provisioning keeps going. The Wi-Fi
driver is injected offline in WinPE and ethernet is how the box imaged, so the join
works at the first post-OOBE boot. `06-join-wifi.ps1` stays best-effort/non-fatal -
a desktop with no Wi-Fi NIC exits 0 and the phase just advances. Progress bands
(monotonic, 0-100): join-wifi 1-4, windows-update 4-45, install-packages 45-76,
remove-bloatware 76-85, setup-user 85-91, file-associations 91-99, done=100.

### Assigned-user local account (`setup-user` phase, `10-setup-user.ps1`)

Near the end of provisioning the orchestrator creates the **assigned user's local
admin account** so the machine is ready for its owner at first real logon (the
kiosk still locks login until provisioning completes).

- **Who:** resolves this machine in inventory by BIOS serial
  (`GET /api/devices?q=<serial>`), reads the assigned **owner** (`owner_email`
  preferred, `owner` display name for the full name). If the device record has no
  linked owner, it falls back to the auto-discovered primary user from the last
  agent snapshot (`GET /api/device/<id>` -> `system_info.primary_user_email` /
  `primary_user_name`).
- **Account name (Juniper convention):** `local_` + the owner's **first name**,
  lowercased and stripped to letters/digits (e.g. owner "Faldu, Rishi" ->
  **`local_rishi`**; "Smith, Jay" -> `local_jay`). First name comes from the
  inventory display name (handles both "Last, First" and "First Last"); if only an
  email is known, the first token of the local-part is used (`jay.smith@` -> jay).
  Capped at 20 chars; reserved names skipped.
- **Display name:** stored as "**First Last**" (e.g. inventory "Faldu, Rishi" ->
  `Rishi Faldu`), Title-cased when the source is an all-lower email or ALL-CAPS
  inventory entry, otherwise the inventory casing is preserved.
- **What it does:** creates the local account (or resets it if it already exists),
  sets its full name, **adds it to the local `Administrators` group**, and forces a
  **password change at first logon** (`PasswordExpired = 1` via ADSI).
- **Initial password (no secret in repo):** fetched at runtime from the inventory
  server's auth-exempt `GET /api/management/user-init` (RFC-1918 only), which reads
  `C:\inventory\user-init.json` (`{"initialPassword":"..."}`, ACL'd to SYSTEM +
  Administrators) on pc-deploy. The password is the same generic onboarding value
  for all machines, stored in 1Password (`Private/Juniper New-PC Initial Password`),
  held in memory only, cleared immediately after use, and **never logged**. To
  rotate: regenerate the 1Password item and rewrite `C:\inventory\user-init.json`
  (no service restart needed).
- **Best-effort/non-fatal:** no assigned owner, an unreachable API, a reserved/blank
  derived name, or a missing password config all exit 0 - the image never aborts.

- `03-windows-update.ps1` - all Windows updates
- `03b-install-catalog-drivers.ps1` - post-boot online driver install from inventory
  catalog. Auto-detects manufacturer/model/OS from WMI; queries
  `/api/drivers?status=confirmed_working`; installs `.inf` via pnputil, `.msi` via
  msiexec /qn, `.exe` via /s /norestart; verifies SHA256 when present. Pass
  `--IncludeUnconfirmed` on first run for brand-new hardware.
- `04-install-packages.ps1` - winget + MSI packages + inventory agent registration.
  The inventory agent also installs the Juniper root CA certificate automatically,
  so HTTPS to internal services works after this step.
- `06-join-wifi.ps1` - joins the office Wi-Fi (orchestrator phase `join-wifi`,
  band 1-4, now the FIRST phase so Wi-Fi is up before the multi-reboot update pass
  - ethernet-unplug fallback). Best-effort/non-fatal (exits 0 with no Wi-Fi NIC).
  See "Wi-Fi join during imaging" below.
- `07-remove-bloatware.ps1` - removes unwanted Windows features and apps

### Servicing Stack Updates (SSUs) install FIRST

`03-windows-update.ps1` now runs an **SSU-first pass** at the top of every round,
before the cumulative/.NET/driver/optional updates. A repeatedly-failing update
(often a .NET/prerequisite case) can stem from being installed before its required
servicing-stack update; installing SSUs first avoids that.

- An update is an SSU if its `Categories` includes the "Servicing Stack Updates"
  category (CategoryID `2eb0c6a8-b6e9-4c33-8c39-92e9b3bf91e9`) or its `Title`
  matches `Servicing Stack Update` / `*servicing stack*` (`Test-IsSsu` helper).
- If any SSUs are pending, ONLY those are downloaded+installed first
  (`stepMessage` "Installing servicing stack update(s) first..."), then the existing
  flow installs everything else. SSUs usually need no reboot; if the SSU install
  reports reboot-required, the phase returns **3010** so the orchestrator reboots and
  the next round continues with the remaining (now-installable) updates.
- **No-ops cleanly when no SSU is pending** - the block is gated on
  `$ssuItems.Count -gt 0`, so behaviour is exactly as before. SSUs honour the same
  skip-after-3 guard and feed the same `wu-failures.json` fail map / log upload.
- This is purely an ORDERING change - granular reporting, per-update result,
  skip-after-3, stall/round-cap, and WU-log-on-failure are all preserved.

### Windows Update failure surfacing + loop guard

`03-windows-update.ps1` installs updates one-at-a-time across many reboot "rounds"
(round number from `phase.json`). On top of the granular per-update progress it now
makes update FAILURES impossible to miss and guarantees a repeatedly-failing update
can never trap a machine in an endless reboot loop. All best-effort - a failing
update is skipped/flagged so imaging COMPLETES, never aborts.

- **Per-update RESULT reporting.** After each install it sets `stepMessage` to a
  running per-round tally, e.g. `"Round 3: installed 12, FAILED 1 (last: KB5034123
  0x80240022)"` with `state=warning` whenever anything failed this round; a clean
  item shows `"Round 3: installed N of M OK"`. The failing KB + HResult are always
  in the message. Failed = WUA `ResultCode` 4 (Failed) / 5 (Aborted); 3
  (SucceededWithErrors) is treated as a SOFT failure (counted as failed) so it is
  retried/eventually skipped rather than silently passed.
- **Per-update failure history** persists in
  `C:\ProgramData\JuniperSetup\wu-failures.json`
  (`{ "<updateKey>": { kb, title, hresult, count } }`, key = WUA UpdateID GUID, else
  KB, else title). Each round increments `count` for updates that failed that round.
  Bootstrap (`orchestrator.ps1`) deletes this file at the start of a fresh image so
  a prior image's skip counts never carry over.
- **Skip-after-3 loop guard.** An update whose `count >= 3` is EXCLUDED from the
  install collection on every subsequent round (no decline API is called - it is
  just not added), surfaced as `"Skipping update KB... (failed 3x) - continuing"`.
  This lets the phase finish the OTHER updates and reach `done`.
- **Stall detection.** If a round installs **0** new updates yet updates are still
  pending (everything left is failing/being-skipped), the phase is treated as
  complete-with-failures: it STOPS returning 3010 (no more pointless reboots),
  publishes `state=warning` + `"Windows Update finished with N failed update(s):
  KB..., KB... (see log)"`, exits **0**, and the orchestrator advances to the next
  phase. **Round cap** `$MaxRounds=12` is an absolute backstop - after the cap it
  stops rebooting for updates and moves on with a flagged warning.
- **WU log upload on failure.** Whenever any update fails (and again at phase end if
  any failures occurred), `Send-WuFailureLog` uploads the phase log + a concise
  per-KB/HResult summary to `/ingest/deploy-log` with `status=error`, so the Imaging
  tab flags the card red and a tech reads exactly which KBs failed + HResults from
  `/deploy/status` without reaching the machine.
- **Imaging tab.** `device_provisioning.state` (free-form TEXT) gains a `warning`
  value rendered distinctly in `deploy_status.html` (amber pill + amber bar + red
  bold step text; sorts just below `error`). The FAILED stepMessage and the
  "updated Ns ago" freshness stay visible; the per-card Logs button turns red
  because an `error` log exists. No migration was needed.

> Only fully verifiable on a real image (a genuinely failing KB). Synthetic
> `/ingest/deploy-progress` (state=warning) + `/ingest/deploy-log` (status=error)
> round-trips were verified against `/api/deploy/progress` and the logs API.

### Wi-Fi join during imaging
Imaged PCs auto-join the corporate Wi-Fi during post-install.
- **Source chain:** UniFi controller (read via the Inventory `X-API-Key`,
  `GET /proxy/network/api/s/default/rest/wlanconf`) -> inventory `/api/management/wifi`
  endpoint -> `06-join-wifi.ps1` phase. The PSK is **never** in the repo or in any
  script - it lives only server-side in `C:\inventory\wifi.json` on pc-deploy
  (`{"ssid","psk"}`, ACL'd to SYSTEM + Administrators), which the auth-exempt
  `/api/management/wifi` endpoint reads at request time and returns to the imaging
  client. SSID wired up: **Juniper** (WPA2-PSK; the `Juniper-Guest` SSID is NOT used).
- **Orchestrator wiring:** `join-wifi` = `06-join-wifi.ps1` sits in `$Phases` right
  after `install-packages`, with `$PhaseMeta` label "Connecting to office Wi-Fi"
  (band 72-78). It's also in the orchestrator self-update list so it can be hotfixed
  from the share. `06` is best-effort: it skips cleanly (exit 0) when there is no
  wireless NIC, when the API is unreachable, or when the join doesn't confirm - a
  desktop with no Wi-Fi adapter never fails the image. It builds a minimal
  WPA2PSK/AES profile and runs `netsh wlan add profile ... user=all` (PSK cleared
  from memory and removed from disk immediately after import).
- **To change the office Wi-Fi creds:** re-run the UniFi pull and rewrite
  `C:\inventory\wifi.json` on pc-deploy (no service restart needed; the endpoint
  reads the file per request).

`deploy.ps1` has a `Get-DriverManifest` helper that tries `/api/drivers/manifest.json`
first and falls back to the on-disk `manifest.json` if the inventory server is unreachable.

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
- Service env vars (UNIFI_HOST, UNIFI_API_KEY, DATABASE_URL, etc.) - NSSM stores these in
  TWO registry locations; always use the Parameters subkey (the live one NSSM actually reads):
  - **Live (use this):** `HKLM:\SYSTEM\CurrentControlSet\Services\JuniperInventory\Parameters\AppEnvironmentExtra`
    (REG_MULTI_SZ string array - one entry per env var)
  - **Stale mirror (ignore):** `HKLM:\SYSTEM\CurrentControlSet\Services\JuniperInventory\Environment`
    (REG_SZ with null separators - may have an old DATABASE_URL password)

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

#### Lenovo driver curate pipeline (catalog -> .inf -> confirmed_working)

End-to-end flow for Lenovo models (run on pc-deploy, scripts in `C:\deploy\scripts`):
1. `sync-lenovo-drivers.ps1 -ManifestPath <MT>-driver-manifest.json -Model "<model>" -MachineType <MT>`
   upserts catalog rows (status=unconfirmed) from a per-machine-type SoftPaq manifest.
2. `curate-lenovo-model.ps1 -MachineType <MT> -Slug <model-slug>` downloads each SoftPaq
   `.exe`, silently extracts it (`/VERYSILENT /EXTRACT=YES`), keeps ONLY packages that
   yield `.inf` (BIOS/firmware flashers excluded), and stages them under
   `C:\deploy\drivers\<slug>-curated\<subdir>\<name>\`. Writes `_staging\<MT>_curate-results.json`.
3. Promote: move the old `<slug>` aside, rename `<slug>-curated` -> `<slug>`, then mark the
   kept catalog rows `confirmed_working` with `file_path = <slug>\<subdir>\<name>`.
4. `GET /api/drivers/manifest.json` regenerates the manifest from confirmed_working rows.
   The endpoint auto-includes each model's real WMI Model strings (e.g. `21G2002DUS`) by
   matching the catalog `machine_type` prefix against the `devices` table, so deploy.ps1's
   `Invoke-DriverInjection` matches a real machine at image time.

Curated models (offline DISM-injectable): ThinkPad P14s Gen 5 (21G2, 142 .inf),
ThinkPad T14s Gen 4 (21FE, 99 .inf). Other Lenovo models still hold raw `.exe` only
(unconfirmed) and rely on the post-boot online installer until curated.
#### Adding a new driver

Use the web UI at `http://192.168.5.141:8080/drivers` (admin login required).
Set `file_path` relative to `C:\deploy\drivers\` - e.g. `lenovo-thinkpad-t14s\network\Intel-NIC.exe`.
This is the same path convention as manifest.json `driverPath`. After saving, test the
driver and mark it confirmed_working or confirmed_buggy via the status panel.

## OOBE / no Microsoft account (local accounts only)

Juniper images use **local admin accounts only - never a Microsoft account**.
Two layers keep OOBE off the MSA / Office-365 sign-in path:

1. **Unattend (`oobeSystem` pass, both win11 + win10):** the `junadmin` local
   admin is created in `UserAccounts\LocalAccounts`, and `Microsoft-Windows-Shell-Setup\OOBE`
   sets `HideOnlineAccountScreens=true`, `HideLocalAccountScreen=true`, `HideEULAPage=true`,
   `HideOEMRegistrationScreen=true`, `HideWirelessSetupInOOBE=true`, `NetworkLocation=Work`,
   `ProtectYourPC=3`, `SkipMachineOOBE/SkipUserOOBE=true`. Because a local account already
   exists, OOBE has no reason to demand an MSA - this is the supported method. Win11 also
   sets `HKLM\...\OOBE\BypassNRO=1` via a `specialize`-pass `RunSynchronousCommand`
   (belt-and-suspenders for builds that gate the local-account path on a network adapter).
   Note: BypassNRO is increasingly restricted on 24H2 - the local-account + Hide* flags are
   what we actually rely on; BypassNRO is only a fallback.

2. **Post-OOBE nag suppression (`scripts/SetupComplete.cmd`):** runs once post-OOBE as
   SYSTEM, before the login screen and before the orchestrator arms junadmin autologon, so
   the keys are machine-wide and idempotent. It writes:
   - `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement\ScoobeSystemSettingEnabled=0`
     (kills the "Let's finish setting up your device" SCOOBE prompt)
   - `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\{DisableConsumerFeatures,
     DisableWindowsConsumerFeatures,DisableSoftLanding}=1` (consumer/Spotlight/suggestion content)
   - `HKLM\SOFTWARE\Policies\Microsoft\OneDrive\DisablePersonalSync=1` (OneDrive personal
     first-run nag - does NOT uninstall OneDrive)
   - `HKLM\SOFTWARE\Policies\Microsoft\office\16.0\common\signin\SignInOptions=3` (Office/M365
     first-launch sign-in disabled, so Office installed later via the catalog never forces MSA)

   These keys do NOT touch junadmin creation, autologon, the JuniperImaging task, or the
   kiosk/provision-status screen - all keep working.

**Verify on next image:** OOBE completes with no online-account / "sign in with Microsoft"
screen and lands on the local junadmin session; no "finish setting up your device" prompt;
first launch of Office (when installed) shows no M365 sign-in nag. The reg writes are logged
in `C:\ProgramData\JuniperSetup\imaging.log` ("Applying OOBE no-MSA / first-run nag suppression").

## Windows activation (OEM UEFI key)

`04-install-packages.ps1` includes an OEM activation step that:
1. Reads the embedded product key from UEFI firmware via
   `SoftwareLicensingService.OA3xOriginalProductKey` (WMI)
2. Installs it with `slmgr.vbs /ipk` and activates with `slmgr.vbs /ato`
3. **Never logs the key value** - only slmgr's result text is written to output
4. Gracefully skips on VMs or hardware without an embedded OEM key

This works for any OEM PC shipped with Windows 8 or later (ACPI MSDM table).
Non-OEM machines will activate via digital license or KMS automatically.

## Provisioning status screen + lockout (kiosk)

During post-image setup the machine now shows a **fullscreen status screen** and
**locks the user out** until all phases finish. This solves the old problem where
a user could log in mid-install and see no indication that setup was still running.

### How it works
- **`scripts/provision-status.ps1`** - a borderless, topmost, fullscreen **WPF**
  window (navy Juniper background, "Setting up this PC", determinate progress bar,
  phase label + sub-status, "Step X of Y", elapsed time). It polls
  `C:\ProgramData\JuniperSetup\progress.json` every ~1.5s. Alt-F4/close and keys
  are swallowed so it can't be dismissed. ASCII-safe, no BOM. Relaunched fresh on
  every provisioning reboot.
- **Kiosk lockout**: `orchestrator.ps1 -Bootstrap` arms autologon for `junadmin`
  (using the password it just pulled from the bootstrap API - never stored in the
  repo) and sets the **Winlogon Shell** to launch `provision-status.ps1` INSTEAD of
  `explorer.exe`. Auto-logged-in `junadmin` therefore sees ONLY the status screen -
  no desktop, no Start menu, no taskbar = locked out. Both the system-wide
  `HKLM\...\Winlogon\Shell` (reliable on first logon) and the per-user shell are set.
  Fast user switching is hidden. `AutoLogonCount` is set to a **very high value
  (100000)** in BOTH `Set-KioskMode`/`Set-AutoLogon` and `Reset-AutoLogonCount`, and
  is **re-armed on every orchestrator run**, so the MANY rapid back-to-back reboots
  Windows Update triggers between orchestrator runs can never exhaust the count and
  drop the machine to the normal login screen mid-provision. As belt-and-suspenders,
  `Reassert-KioskArming` runs every orchestrator pass (not only bootstrap) and
  re-asserts `AutoAdminLogon=1` + `DefaultUserName`/`DefaultDomainName` + the kiosk
  Shell (provision-status.ps1) - **without touching `DefaultPassword`** (the
  bootstrap-API value is never re-read or logged) - so even a stray reboot that
  skipped the orchestrator re-arms junadmin straight into the kiosk on the next boot.
  Net: from the first post-OOBE boot until `done` (or a stop), every boot auto-logs
  junadmin into the fullscreen status screen - never a usable desktop OR a login prompt.
- **No sleep during install**: at `-Bootstrap` (and idempotently re-asserted each run)
  the orchestrator forces the machine to stay awake **on AC** for the whole multi-reboot
  install via `powercfg /change standby-timeout-ac 0`, `hibernate-timeout-ac 0`, and
  `monitor-timeout-ac 0` (display kept on so the kiosk screen stays visible). `powercfg`
  persists the active scheme across reboots, which matters since imaging spans dozens of
  them. Machines image plugged in, so only AC settings are touched; battery/DC is left
  alone. Before changing them, `Save-PriorAcPower` snapshots the prior AC standby/
  hibernate/monitor minutes (parsed from `powercfg /query`) to
  `C:\ProgramData\JuniperSetup\.power-ac-prior.json` so they can be restored. All power
  calls are best-effort (try/catch) and never abort imaging.
- **Teardown on completion**: when the orchestrator reaches the `done` branch it sets
  `progress.json` state=`done`/100%, restores the Shell to `explorer.exe`, clears
  `AutoAdminLogon`/`DefaultPassword`/`AutoLogonCount`/`DefaultUserName`, un-hides fast
  user switching, **restores power settings** via `Restore-PowerSettings` (captured
  prior AC values, or sane defaults standby 30 / monitor 10 / hibernate 0 min if the
  snapshot is missing/unreadable), removes the scheduled task, then reboots. The same
  `Remove-KioskMode` + `Restore-PowerSettings` pair also runs on the break-glass/safety-
  timeout teardown path. **Next boot = clean normal login screen** for the end user.
  Teardown is idempotent.

### progress.json schema (`C:\ProgramData\JuniperSetup\progress.json`, UTF8 no BOM)
| Field | Type | Meaning |
|---|---|---|
| `overallPercent` | int 0-100 | weighted across phases (windows-update 5-45, install-packages 45-80, remove-bloatware 80-92, file-associations 92-99, done=100) |
| `phaseKey` | string | current phase key, or `bootstrap`/`done` |
| `phaseLabel` | string | friendly text, e.g. "Installing Windows updates" |
| `phaseIndex` / `phaseTotal` | int | 1-based phase position / total phases |
| `stepMessage` | string | optional sub-status |
| `state` | string | `running` \| `rebooting` \| `done` \| `error` |
| `updatedUtc` | string | ISO-8601 UTC timestamp |

`orchestrator.ps1` writes it (helper `Write-ProgressJson` + `Publish-PhaseProgress`)
at bootstrap, every phase transition, and completion. It writes to a `.tmp` then
atomically moves into place, so the GUI never reads a half-written file.

**Phase sub-status:** a phase script can surface live detail by writing one line to
`C:\ProgramData\JuniperSetup\logs\<phaseKey>.step`; the orchestrator folds it into
`progress.json` as `stepMessage` on the next transition. (Optional - phases work
unchanged without it.)

### Granular Windows Update progress (live, per-update, across reboots)

The orchestrator only updates progress at phase TRANSITIONS, so the long, multi-reboot
`windows-update` phase used to sit frozen (`overall_percent=25`, empty `step_message`,
stale `updated_utc`). To fix this, the phase script now reports its OWN progress
directly and frequently via a shared helper.

- **`scripts/progress.ps1`** - dot-sourced shared helper. `Publish-Progress` writes
  `progress.json` atomically (.tmp+move) AND best-effort POSTs `/ingest/deploy-progress`,
  ALWAYS stamping `updatedUtc` (ISO-8601). It resolves device identity (serial -> mac ->
  hostname) exactly like `orchestrator.ps1`'s `Get-MachineIdentity`, so phase posts key
  the SAME `device_provisioning` row. `Get-ProgBandPercent` maps a fraction-within-phase
  to an absolute overall percent using the SAME phase bands as the orchestrator (so the
  bar stays monotonic across orchestrator + phase writes). `progress.ps1` is staged at
  `C:\ProgramData\JuniperSetup\` by `deploy.ps1` and self-updated by the orchestrator's
  share sync (both the early block and `Sync-Scripts`).
- **`scripts/03-windows-update.ps1`** now reports (best-effort, never blocks the install):
  searching -> "Found N update(s)" -> installs updates **one at a time** so each item
  reports `"Round R - installing X of Y: <Title> (KB...)"` with a moving sub-percent ->
  reboot-pending ("...restarting to continue...", state=rebooting) -> "Windows updates
  complete". The **round** comes from `phase.json`; a per-round band floor keeps
  `overallPercent` creeping forward (not snapping back) across the many reboots.
- **Server/UI** (inventory repo): `/ingest/deploy-progress` already stored `step_message`
  + `reported_utc` and `/api/deploy/progress` already returned them plus `age_s`/`stale`
  (no `main.py` change needed). `deploy_status.html` now shows "updated Ns ago" and flips
  it to red "no update Ns ago" when `stale` (>10 min), so a frozen `updated_utc` visibly
  flags a possibly stuck machine. The kiosk `provision-status.ps1` already renders
  `stepMessage` prominently, so the granular text shows on-screen too.
- **Not end-to-end testable without imaging a real machine.** Validate on the next image:
  during Windows Update the kiosk + `/deploy/status` card should show the per-update step
  text changing, "Step 1 of 5", a creeping percent within the 5-45 band, the round number
  rising across reboots, and "updated Ns ago" staying fresh.

### Break-glass recovery (stuck machine)
Two escapes, so a tech is never permanently locked out:
1. **Flag file**: create `C:\ProgramData\JuniperSetup\break-glass.txt` (e.g. over the
   admin share from another PC) and reboot - the next orchestrator run tears down the
   kiosk and restores a normal desktop/login.
2. **Hotkey**: on the kiosk screen press **Ctrl+Shift+Alt+F12** to immediately launch
   `explorer.exe` on that session and close the kiosk window (this session only).
3. **Auto safety timeout**: the kiosk self-tears-down after `$KioskMaxHours` (default 8)
   from imaging start, in case a phase hangs.

### Staging / self-update
`scripts/deploy.ps1` stages `provision-status.ps1` into `C:\ProgramData\JuniperSetup\`
alongside the orchestrator. The orchestrator's self-update list now includes
`provision-status.ps1`, so the lockout screen can be **hotfixed from the deploy share
without re-imaging**.

> Not end-to-end testable without imaging a real machine. To validate on the next
> image: watch for the fullscreen status screen right after the first post-OOBE
> autologon, confirm there is no desktop/taskbar, confirm the bar advances across
> phases and reboots, and confirm the FINAL boot lands on a normal login screen
> (no autologon, explorer shell restored). Check `imaging.log` for the
> "Kiosk mode armed" and "Kiosk mode removed" lines.

## End-to-end imaging status + per-phase log upload

The inventory **Imaging tab (`/deploy/status`)** shows each machine's progress
for the WHOLE lifecycle - WinPE imaging through every post-install phase to
`done` - as ONE record, and uploads per-phase log files viewable from the page.

### Unified `device_provisioning` timeline (one record, WinPE -> done)
A single `device_provisioning` row per device is resolved serial-first
(serial -> MAC -> hostname, same as the agent), so WinPE and post-install both
write the SAME record and a re-image reuses it.

- **WinPE** (`deploy.ps1`): `Send-WinpeProgress` posts coarse milestones to
  `POST /ingest/deploy-progress` with `state=winpe`, `phaseKey=winpe`, and
  `overallPercent` 1-5 ("Imaging Windows" -> "Applying Windows image" ->
  "Injecting drivers" -> "Finalizing - rebooting to Windows"). Keyed by
  serial/MAC/hostname so it stitches to the record the orchestrator continues.
- **Post-install** (`orchestrator.ps1`): `Send-ProgressToServer` (already wired)
  continues the same record across the 4 phases (windows-update 5-45,
  install-packages 45-80, remove-bloatware 80-92, file-associations 92-99) to
  `state=done`/100%. The WinPE 1-5 band sits below the post-install bands so the
  bar advances monotonically across the whole process.
- All reporting is **best-effort** - a server error never blocks or aborts
  imaging (every call is wrapped, short timeouts, swallowed exceptions).

### `POST /ingest/deploy-log` contract (auth-free, like all `/ingest/*`)
Upload a finished phase's log. Body (JSON):
`{ serial?, hostname?, mac?, phase_key, status: "ok"|"error", log_text, ts }`.
The server resolves the device (serial-first), writes the bytes to
`C:\inventory\provisioning-logs\<device_id>\<phase>-<utc-ts>.log`, and inserts an
index row into the `provisioning_logs` table (migration `db/27_provisioning_logs.sql`).
Oversized logs are tailed to the last ~480 KB by the client and capped at 512 KB
server-side (errors live at the end).

**When logs upload (best-effort):**
- `orchestrator.ps1` `Send-PhaseLog` uploads `logs\<phaseKey>.log` at the END of
  each phase (`status=ok`) AND immediately when a phase fails (`status=error`).
- `deploy.ps1` `Send-WinpeLog` uploads the WinPE phase log on completion
  (`status=ok`) and on a fatal WinPE error (`status=error`, e.g. DISM apply fail).

### Viewing logs on the Imaging tab
Each live progress card on `/deploy/status` has a **Logs** button (turns red if any
error log exists). It calls `GET /api/deploy/logs?device=<id>` to list the device's
uploaded phase logs (newest first, ok/error badges) and opens any one in a viewer
via `GET /api/deploy/log/<log_id>` (with a download link). The page keeps its
existing 4s auto-refresh. The `/deploy/status` HTML page stays behind login
(302 -> /login); the `/ingest/*` and `/api/*` routes are auth-free for imaging clients.

> Fully testable only on a real image. To validate: watch a machine appear on
> `/deploy/status` during WinPE (purple "winpe" state, 1-5%), see it continue
> through the 4 post-install phases to done/100% in the SAME card, then open the
> Logs drawer and confirm each phase's log is present (error phases flagged red).
