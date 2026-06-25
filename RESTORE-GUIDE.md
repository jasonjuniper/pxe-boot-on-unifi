# pc-deploy → Windows Server 2025 Restoration Guide

**Prepared:** 2026-06-23  
**Completed:** 2026-06-24  
**Reason:** Bare metal WS2025 install to gain WDS + `boot_EX` Secure Boot PXE support  
**Backup location:** `C:\deploy-backup\` on ENG-2  

## Restoration status (2026-06-25)

| Component | Status | Notes |
|---|---|---|
| PostgreSQL 16 | ✅ Running | Data restored from 38 MB dump; 164 devices, 166 driver packages |
| JuniperInventory (FastAPI) | ✅ Running | NSSM service; 10 env vars set; `itsdangerous>=2.0` added to requirements.txt |
| Caddy | ✅ Running | `tls internal` certs for inventory domains; HTTP file server on port 80/443 |
| WDSServer | ✅ Running | Initialized StandAlone; boot.wim (custom WinPE, ~519 MB) registered as x64uefi |
| boot_EX EFI | ✅ Present | `C:\RemoteInstall\boot_EX\x64\wdsmgfw_EX.efi` (1143.8 KB, CA 2023 signed) |
| WIM images | ✅ Copied | win10.wim, win10-pro.wim, win11-home.wim, win11-pro.wim, win11.wim; .bad files removed |
| Drivers | ✅ Copied | 15 GB driver warehouse to `C:\deploy\drivers\` |
| DHCP option 67 | ✅ Done | `boot_EX\x64\wdsmgfw_EX.efi` set in UniFi — PXE boot confirmed working |
| WinPE NIC driver | ✅ Injected (2026-06-24) | **Intel I219-V** (`e1dn.inf`, VEN_8086 DEV_550B) — P14s Gen 5 Intel has Intel NIC, not Realtek. Staged at `C:\deploy\drivers\_winpe-drivers\intel-i219v\`. |
| toolkit.ps1 logging | ✅ Added (2026-06-24) | toolkit.ps1 writes structured logs to `X:\Logs\` (always) + deploy share `logs\` + POSTs to `/ingest/winpe-event`. Added [6] Hardware Info menu item with PCI DeviceIDs for NIC diagnosis. |
| /ingest/winpe-event API | ✅ Added (2026-06-25) | New endpoint added to inventory app — accepts WinPE diagnostic bundles, writes to `/imaging` live log viewer |
| Alert timezone bug | ✅ Fixed (2026-06-25) | `alerts.py`: `datetime.now()` → `datetime.now(timezone.utc)` — was crashing the alert scheduler every hour |
| inv.juniperdesign.local DNS | ⚠️ Wrong | Points CNAME → `eng-1.juniperdesign.local` (192.168.13.94). Should be A record → 192.168.5.141. **Jason to fix in UniFi UI.** |
| P14s Gen 5 post-install drivers | ⚠️ Not catalogued | Zero entries in driver catalog for ThinkPad P14s Gen 5 Intel (21G2). WinPE NIC driver is injected but post-install drivers (NIC, GPU, audio, etc.) need to be added to the catalog. |

**PXE boot end-to-end verified.** WIM rebuilt 2026-06-24 with Intel I219-V driver + logging. 0xc0000272 fixed 2026-06-24 (x64uefi default boot image was not set).

> **Lesson learned:** DS569123 is the Lenovo SCCM WinPE PE11 pack for the **AMD variant** of the
> P14s Gen 5. We have the **Intel variant** (type 21G2, Core Ultra 7). The Intel platform ships with
> an Intel I219-V NIC (DEV_550B) — not Realtek — so the AMD pack's Realtek drivers were wrong entirely.
> Always verify the actual PCI hardware ID from Device Manager (Hardware Ids tab) before assuming any
> vendor-supplied driver pack covers the right chip. Use toolkit option [6] Hardware Info in WinPE to confirm.

### WinPE NIC driver injection (for future models)

If a new model fails to get network in WinPE:
1. Boot into Windows on that machine (or a twin), open Device Manager → NIC → Details → Hardware Ids
2. Note the `VEN_XXXX&DEV_XXXX` — this tells you the exact chip
3. Export the driver from the Windows driver store (`C:\Windows\System32\DriverStore\FileRepository\`)
4. Copy to `C:\deploy\drivers\_winpe-drivers\<model>\` on the deploy share
5. Run the DISM task below to inject and commit

```powershell
# On pc-deploy — run as scheduled task under SYSTEM (DISM takes ~5 min total)
$mount  = "C:\WinPE_amd64\mount"
$wim    = "C:\RemoteInstall\Boot\x64\Images\boot.wim"
$driver = "C:\deploy\drivers\_winpe-drivers\<model>"   # folder with .inf/.sys/.cat

New-Item -ItemType Directory $mount -Force | Out-Null
dism /Mount-Wim /WimFile:$wim /Index:1 /MountDir:$mount
dism /Image:$mount /Add-Driver /Driver:$driver /Recurse
dism /Unmount-Wim /MountDir:$mount /Commit
# WDS serves the updated boot.wim automatically — no service restart needed
```

Known NIC → driver mapping:
| Model | Chip | VEN/DEV | Driver INF | Source |
|---|---|---|---|---|
| ThinkPad P14s Gen 5 Intel (21G2, Core Ultra 7) | Intel I219-V | VEN_8086 DEV_550B REV_20 | `e1dn.inf` | ENG-2 driver store |
| *(Realtek injection — wrong variant)* | RTL8168/8111 | VEN_10EC DEV_8168 | `rt68cx21x64.inf` | Lenovo DS569123 WinPE PE11 (AMD variant) |

Staged driver files at `C:\deploy\drivers\_winpe-drivers\intel-i219v\` on pc-deploy.



---

## Inventory server functional audit (2026-06-25)

### Services

| Service | Status | Port(s) |
|---|---|---|
| WDSServer | ✅ Running | UDP 69 (TFTP, built-in to WDS — tftpd64 NOT installed or needed) |
| postgresql-16 | ✅ Running | 5432 (localhost only) |
| JuniperInventory | ✅ Running | 8080 |
| Caddy | ✅ Running | 80, 443 |
| tftpd64 | ✅ NOT present | Fully replaced by WDS native TFTP |

### API endpoints (verified)

| Endpoint | Method | Status |
|---|---|---|
| `/healthz` | GET | ✅ `{"ok":true}` |
| `/ingest/endpoint` | POST | ✅ Device registration |
| `/ingest/host` | POST | ✅ Host scanner batch |
| `/ingest/imaging-log` | POST | ✅ Live log lines for `/imaging` viewer |
| `/ingest/winpe-event` | POST | ✅ **Added 2026-06-25** — WinPE toolkit diagnostic events |
| `/api/devices` | GET | ✅ Device list |
| `/api/drivers` | GET | ✅ Driver catalog (166 entries: 143 Lenovo, 23 Dell) |
| `/api/drivers/manifest.json` | GET | ✅ DISM-compatible manifest |
| `/imaging` | GET | ✅ Live imaging log viewer |

### DNS (UniFi static DNS — Jason to fix)

| Hostname | Current | Expected | Action needed |
|---|---|---|---|
| `inventory.juniperdesign.local` | A → 192.168.5.141 | ✅ Correct | None |
| `pc-deploy.juniperdesign.local` | A → 192.168.5.141 | ✅ Correct | None |
| `inv.juniperdesign.local` | CNAME → eng-1.juniperdesign.local | A → 192.168.5.141 | **Delete CNAME, add A record** |

To fix `inv.juniperdesign.local` in UniFi:
1. UniFi UI → Network → Settings → Services → DNS → Static DNS
2. Delete the entry for `inv.juniperdesign.local` (currently CNAME to eng-1)
3. Add new A record: `inv.juniperdesign.local` → `192.168.5.141`

### Known bugs fixed this session

**Alert timezone crash (`alerts.py`):**
- Symptom: `[alerts] rule Agent silent > 7 days failed: can't subtract offset-naive and offset-aware datetimes` — logged every hour
- Root cause: `datetime.now()` (naive) subtracted from `r["captured_at"]` (PostgreSQL TIMESTAMPTZ, always tz-aware)
- Fix: `from datetime import datetime, timezone` + `datetime.now(timezone.utc)` with fallback tzinfo on captured_at

**Missing `/ingest/winpe-event` endpoint:**
- Symptom: toolkit.ps1 logged to file fine, but API POST returned 404
- Fix: Added new endpoint to `main.py`; writes events to `C:\inventory\imaging-logs\<hostname>.log` so they appear in the live `/imaging` viewer

---

## Service assessment: Windows 11-era vs Server 2025 native

| Service | Legacy approach (W11) | Current (WS2025) | Recommendation |
|---|---|---|---|
| TFTP / PXE boot | tftpd64 (third-party) | WDS native TFTP | ✅ Already migrated — tftpd64 removed |
| Boot image serving | tftpd64 + custom iPXE | WDS + boot_EX (CA 2023 signed) | ✅ Already migrated — better Secure Boot support |
| HTTPS proxy / file server | Caddy | IIS (available on WS2025) | **Keep Caddy** — IIS is heavier and requires more configuration; Caddy handles TLS-internal certs automatically |
| Service wrapper | NSSM | Task Scheduler / SC.exe | **Keep NSSM** — Python/uvicorn requires a wrapper; NSSM handles stdout/stderr logging and restart policies better than native SC.exe |
| Database | PostgreSQL 16 | SQL Server Express (free) | **Keep PostgreSQL** — no migration benefit; SQL Server Express has 10 GB limit and different syntax |
| Deploy share | SMB / `deploy$` | SMB / `deploy$` | ✅ Already native Windows |
| Inventory web app | FastAPI / Python | ASP.NET Core or Azure app | **Keep FastAPI** — no reason to rewrite a working app |

**Net assessment:** All meaningful migrations are already done. The move to WDS on Server 2025 was the only service that *required* Server 2025. Everything else (Caddy, NSSM, PostgreSQL, FastAPI) works fine and would cost more to migrate than to keep.

---

## P14s Gen 5 Intel (21G2) driver coverage

| Phase | Component | Status |
|---|---|---|
| WinPE (boot) | Intel I219-V NIC (VEN_8086 DEV_550B) | ✅ Injected into boot.wim |
| Post-install | Intel I219-V NIC | ⚠️ Not in driver catalog |
| Post-install | Intel Arc Graphics (Meteor Lake integrated) | ⚠️ Not in driver catalog |
| Post-install | Intel SST Audio | ⚠️ Not in driver catalog |
| Post-install | Fingerprint reader | ⚠️ Not in driver catalog |
| Post-install | Intel Thunderbolt 4 | ⚠️ Not in driver catalog |
| Post-install | Intel Bluetooth | ⚠️ Not in driver catalog |

Post-install drivers for the P14s Gen 5 Intel can be sourced two ways:
1. **Lenovo's PSREF/SCCM pack for model 21G2** — download from [Lenovo Support](https://support.lenovo.com) for ThinkPad P14s Gen 5, type 21G2
2. **Extract from ENG-2 driver store** — ENG-2 is an identical model; run `pnputil /export-driver * C:\drivers-export\` and filter by hardware ID

Once downloaded, add via the inventory web UI at `http://192.168.5.141:8080/drivers` and mark `confirmed_working` after verifying on IMAGE-ME.

---

## Backup manifest (on ENG-2 at C:\deploy-backup)

| Path | Size | Notes |
|---|---|---|
| `images/` | 44.4 GB | win10-pro.wim, win11-home.wim, win11-pro.wim + ISOs |
| `drivers/` | 15.0 GB | Driver warehouse (all models) |
| `tftpd64/` | 146.9 MB | iPXE EFI binaries, EFI/, Boot/, Caddyfile, ipxeboot/ |
| `boot-wim/boot.wim` | 509.4 MB | **Custom WinPE** (has deploy scripts baked in) |
| `inventory-app-backup.zip` | 53.1 MB | FastAPI app (identical to GitHub commit 82cee1d) |
| `inventory-db.dump` | 38.4 MB | PostgreSQL 16 pg_dump (custom format `-F c`) |
| `caddy/` | ~55 MB | Caddyfile + server.crt + server.key |
| `scripts/`, `unattend/`, `winpe/` | <1 MB | Deployment scripts (also in GitHub) |

**App code canonical source:** `https://github.com/jasonjuniper/computer-inventory` (commit 82cee1d)

---

## What was running on pc-deploy

- **OS:** Windows 11 (now being replaced with Windows Server 2025 Evaluation)
- **Hostname:** pc-deploy  
- **IP:** 192.168.5.141 (static — set in UniFi DHCP reservation)
- **Local admin:** junadmin (credentials in 1Password)

### Services

| Service | Binary | Port |
|---|---|---|
| JuniperInventory | `C:\inventory\venv\Scripts\uvicorn.exe` | 8080 |
| Caddy | `C:\caddy\caddy.exe` | 80, 443 |
| tftpd64 | `C:\tftpd64\tftpd64.exe` | UDP 69 (TFTP) |
| PostgreSQL 16 | Windows service | 5432 (localhost only) |

---

## Post-install steps

### 1. Initial Windows Server 2025 setup

- Install WS2025 Evaluation (Standard Desktop Experience)
- Set hostname: `pc-deploy`
- Set static IP: `192.168.5.141 / 255.255.240.0`, gateway `192.168.0.1`, DNS `192.168.0.1`
- Enable WinRM: `Enable-PSRemoting -Force`
- Create local admin user `junadmin` (password from 1Password)
- Join `pc-deploy.juniperdesign.local` to DNS (UniFi static DNS already points there)

### 2. Restore deploy share

```powershell
# Create deploy$ share
New-Item -ItemType Directory -Path 'C:\deploy' -Force
New-SmbShare -Name 'deploy$' -Path 'C:\deploy' -FullAccess 'Everyone'

# Robocopy from backup on ENG-2 (run on ENG-2):
net use Z: \\192.168.5.141\deploy$ /user:junadmin <password> /persistent:no
robocopy C:\deploy-backup Z:\ /E /COPY:DAT /MT:8 /R:3 /W:5
# (excludes inventory-db.dump, boot-wim, caddy — those go elsewhere)
```

### 3. Install WDS (Windows Deployment Services)

```powershell
# WDS is now available on Windows Server!
Install-WindowsFeature WDS -IncludeManagementTools
# Initialize WDS
wdsutil /Initialize-Server /RemInst:"C:\RemoteInstall"
# Configure PXE: respond to all clients
wdsutil /Set-Server /AnswerClients:All
```

**Boot file setup (Secure Boot with CA 2023):**
```
C:\RemoteInstall\boot_EX\x64\wdsnbp_EX.com    ← BIOS
C:\RemoteInstall\boot_EX\x64\wdsmgfw_EX.efi   ← UEFI (CA 2023 signed!)
```
Update DHCP option 67 to `boot_EX\x64\wdsmgfw_EX.efi` (Jason to apply in UniFi UI).  
Add boot.wim to WDS: `wdsutil /Add-Image /ImageFile:"C:\deploy-backup\boot-wim\boot.wim" /ImageType:Boot`

### 4. Install PostgreSQL 16

Installer is downloaded to `C:\pg16-installer.exe` on pc-deploy (333 MB, PostgreSQL 16.9 for Windows x64).
Source: `https://get.enterprisedb.com/postgresql/postgresql-16.9-1-windows-x64.exe`

**Silent install (run as scheduled task under SYSTEM — do NOT pass password via cmd.exe `set`, it breaks on special chars):**

```powershell
# On ENG-2: decrypt pg-super, pass via encrypted WinRM channel, Base64-embed in script on pc-deploy
$cred    = Import-Clixml "C:\Users\ENG2\.juniper\winrm-cred.xml"
$sec     = Get-Content "C:\Users\ENG2\.juniper\pg-super.enc" | ConvertTo-SecureString
$pgSuper = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
               [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
$sec = $null

Invoke-Command -ComputerName 192.168.5.141 -Credential $cred -Authentication Negotiate -ArgumentList $pgSuper -ScriptBlock {
    param($pw)
    $pwB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($pw)); $pw = $null
    $l1 = '$p = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String("' + $pwB64 + '"))'
    $l2 = '$proc = Start-Process "C:\pg16-installer.exe" -ArgumentList @("--mode","unattended","--superpassword",$p,"--datadir","C:\PGdata","--servicename","postgresql-16","--disable-components","pgAdmin,stackbuilder") -Wait -PassThru -NoNewWindow'
    $l3 = '$p = $null'
    $l4 = '"ExitCode=$($proc.ExitCode) at $(Get-Date)" | Set-Content "C:\pg16-install-result.txt"'
    Set-Content "C:\pg-inst.ps1" -Value @($l1,$l2,$l3,$l4) -Encoding UTF8
    icacls "C:\pg-inst.ps1" /inheritance:r /grant "NT AUTHORITY\SYSTEM:(F)" /grant "BUILTIN\Administrators:(R)" 2>&1 | Out-Null; $pwB64=$null
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -ExecutionPolicy Bypass -File C:\pg-inst.ps1"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName "PG16-Install" -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1)) -Force | Out-Null
    Start-ScheduledTask -TaskName "PG16-Install"
}
$pgSuper = $null
# Monitor: poll C:\pg16-install-result.txt on pc-deploy for ExitCode=0
```

Result: installs to `C:\Program Files\PostgreSQL\16\`, data at `C:\PGdata\`, service `postgresql-16`.

```powershell
# After install — create inv user and inventory database
# On ENG-2: decrypt db-pw, pass via WinRM
$sec   = Get-Content "C:\Users\ENG2\.juniper\db-pw.enc" | ConvertTo-SecureString
$dbPw  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)); $sec=$null
$sec   = Get-Content "C:\Users\ENG2\.juniper\pg-super.enc" | ConvertTo-SecureString
$pgSup = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)); $sec=$null

Invoke-Command -ComputerName 192.168.5.141 -Credential $cred -Authentication Negotiate -ArgumentList $pgSup,$dbPw -ScriptBlock {
    param($sup,$db)
    $env:PGPASSWORD = $sup
    & 'C:\Program Files\PostgreSQL\16\bin\psql.exe' -U postgres -h 127.0.0.1 -c "CREATE USER inv WITH PASSWORD '$db';"
    & 'C:\Program Files\PostgreSQL\16\bin\psql.exe' -U postgres -h 127.0.0.1 -c "CREATE DATABASE inventory OWNER inv;"
    $env:PGPASSWORD = $db
    & 'C:\Program Files\PostgreSQL\16\bin\pg_restore.exe' -U inv -h 127.0.0.1 -d inventory 'C:\deploy\inventory-db.dump'
    $env:PGPASSWORD = $null; $sup=$null; $db=$null
}
$pgSup=$null; $dbPw=$null
```

### 5. Restore inventory app

```powershell
# Expand backup
New-Item -ItemType Directory 'C:\inventory' -Force
Expand-Archive 'C:\deploy-backup\inventory-app-backup.zip' 'C:\inventory'

# Create Python venv (Python 3.12 must be installed first)
python -m venv C:\inventory\venv
& 'C:\inventory\venv\Scripts\pip.exe' install -r C:\inventory\app\requirements.txt

# Run database migrations
Set-Location 'C:\inventory\app'
& 'C:\inventory\venv\Scripts\python.exe' -c "from db import run_migrations; run_migrations()"
# OR apply SQL migration files in C:\deploy\images\db\ (already backed up)
```

### 6. Install NSSM and register JuniperInventory service

Download NSSM: https://nssm.cc/download — install to `C:\nssm\nssm.exe`

```powershell
$nssm = 'C:\nssm\nssm.exe'
& $nssm install JuniperInventory 'C:\inventory\venv\Scripts\uvicorn.exe'
& $nssm set JuniperInventory AppDirectory 'C:\inventory\app'
& $nssm set JuniperInventory AppParameters 'main:app --host 0.0.0.0 --port 8080'
& $nssm set JuniperInventory Start SERVICE_AUTO_START
& $nssm set JuniperInventory AppStdout 'C:\inventory\uvicorn.log'
& $nssm set JuniperInventory AppStderr 'C:\inventory\uvicorn-err.log'
```

**Set service env vars** (retrieve secrets from 1Password at runtime — do NOT paste into this script):
```powershell
# Non-secret values:
$envVars = @(
    "UNIFI_HOST=https://192.168.0.1",
    "UNIFI_SITE=default",
    "AZURE_CLIENT_ID=0ccb3a45-47a2-43a4-9663-966a0c54d877",
    "AZURE_TENANT_ID=39a0a64f-4095-440a-a330-fd3b7e8a1cc9",
    "INVENTORY_REDIRECT_URI=https://inventory.juniperdesign.local/auth/callback"
)
# Secret values — retrieve with op CLI at restoration time:
# DATABASE_URL=postgresql+psycopg://inv:<db-password>@127.0.0.1/inventory
# UNIFI_API_KEY=<from op://Private/Unifi API Key (Inventory)/Token>
# SESSION_SECRET=<from op://Private/inventory-server/session-secret>
# LOCAL_ADMIN_PASSWORD=<from op://Private/inventory-server/local-admin-password>
# AZURE_CLIENT_SECRET=<from op://Private/inventory-server/azure-client-secret>
# Set via: nssm set JuniperInventory AppEnvironmentExtra "KEY=VALUE" (one per call)
```

### 7. Install and configure Caddy

```powershell
# Copy from backup
New-Item -ItemType Directory 'C:\caddy\data' -Force
Copy-Item 'C:\deploy-backup\caddy\caddy.exe' 'C:\caddy\caddy.exe'
Copy-Item 'C:\deploy-backup\caddy\Caddyfile'  'C:\caddy\Caddyfile'
Copy-Item 'C:\deploy-backup\caddy\server.crt'  'C:\caddy\server.crt'
Copy-Item 'C:\deploy-backup\caddy\server.key'  'C:\caddy\server.key'

# Register as Windows service
& 'C:\caddy\caddy.exe' service install --config 'C:\caddy\Caddyfile'
Start-Service Caddy
```

The Caddyfile serves:
- `https://inventory.juniperdesign.local` → uvicorn on 8080
- `http/https://192.168.5.141` → tftpd64 root (`C:\tftpd64\`) for PXE HTTP boot

### 8. Restore tftpd64

```powershell
New-Item -ItemType Directory 'C:\tftpd64' -Force
# Copy iPXE binaries, EFI dir, Boot dir, config from backup
Copy-Item 'C:\deploy-backup\tftpd64\*' 'C:\tftpd64\' -Recurse -Force
# Restore boot.wim
New-Item -ItemType Directory 'C:\tftpd64\sources' -Force
Copy-Item 'C:\deploy-backup\boot-wim\boot.wim' 'C:\tftpd64\sources\boot.wim'
# Register tftpd64 as a service (see 01c-build-winpe.ps1 in deploy share)
```

### 9. Reinstall Windows ADK + WinPE Add-on

Needed for rebuilding WinPE if required. Download:
- ADK: https://go.microsoft.com/fwlink/?linkid=2196127
- WinPE Add-on: https://go.microsoft.com/fwlink/?linkid=2196224

### 10. Install 1Password CLI on pc-deploy

```powershell
winget install AgileBits.1Password.CLI
```
Required for scripts that call `op read` at runtime.

---

## WDS DHCP changes (Jason to apply in UniFi UI)

Once WDS is running and tested, update DHCP option 67:

| Option | Old value | New value |
|---|---|---|
| 67 (bootfile) | `ipxeboot/x86_64-sb/ipxe-shim.efi` | `boot_EX\x64\wdsmgfw_EX.efi` |
| 66 (TFTP server) | `192.168.5.141` | `192.168.5.141` (unchanged) |

Test PXE boot with Secure Boot **enabled** on IMAGE-ME after this change.

---

## Key credentials (all in 1Password — retrieve at restoration time)

| Item | Vault | Fields |
|---|---|---|
| `inventory-server` | Private | `db-password`, `pg-superpassword`, `session-secret`, `local-admin-password`, `azure-client-secret` |
| `Unifi API Key (Inventory)` | Private | `Token` |
| `pc-deploy` (junadmin) | Private | `password` |
| GitHub (jasonjuniper) | — | via `gh` CLI |
