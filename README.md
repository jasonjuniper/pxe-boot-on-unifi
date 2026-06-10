<p align="center"><img src="assets/juniper-banner.svg" alt="JUNIPER · Lighting · Power Solutions · Systems" width="900"></p>

# pc-imaging-server

Automated Windows 10/11 deployment server for Juniper Design. PXE boots
desktops and laptops from the network, runs unattended installs, applies
all Windows updates, installs required software, configures printer queues,
joins Wi-Fi, and removes bloatware — zero-touch from power-on to ready desk.

Built at [Juniper Design](https://juniperdesign.com).

## What it does

| Phase | Script | Description |
|---|---|---|
| 0 | `00-rename-server.ps1` | Rename the imaging server host to `pc-deploy` |
| 1 | `01-setup-wds.ps1` | Install WDS + configure PXE boot service |
| 2 | `02-setup-dhcp-options.ps1` | Ubiquiti router DHCP option 66/67 configuration |
| 3 | `03-windows-update.ps1` | Force-apply all Windows updates on a target PC |
| 4 | `04-install-packages.ps1` | Install MSIs and winget packages |
| 5 | `05-setup-printers.ps1` | Add and share printer queues |
| 6 | `06-join-wifi.ps1` | Join a target PC to the office Wi-Fi profile |
| 7 | `07-remove-bloatware.ps1` | Remove unwanted apps and disable junk Windows features |

## Server requirements

- Windows Server 2019/2022 or Windows 10/11 Pro (WDS role)
- Static IP on the LAN segment used for PXE
- Ubiquiti UniFi or EdgeRouter for DHCP options 66/67
- Remote Desktop enabled (pre-configured on this machine)
- 1Password CLI (`op`) installed for secret retrieval

## Quick start

### 1 — Rename the server

```powershell
.\scripts\00-rename-server.ps1
# Reboots automatically; reconnect via RDP to DESKTOP-I8UM43L
# after it comes back up as pc-deploy
```

### 2 — Set up WDS + PXE

```powershell
.\scripts\01-setup-wds.ps1
```

Then configure DHCP — see `scripts\02-setup-dhcp-options.ps1` for the
exact Ubiquiti commands to add option 66 (TFTP server IP) and option 67
(`boot\x64\wdsnbp.com`).

### 3 — Import Windows images

Once WDS is running, add boot and install images via WDS console or:

```powershell
# Mount your Windows ISO first, then:
wdsutil /Add-Image /ImageFile:"D:\sources\boot.wim" /ImageType:Boot
wdsutil /Add-Image /ImageFile:"D:\sources\install.wim" /ImageType:Install /ImageGroup:"Windows"
```

### 4 — Drop answer files

Copy `unattend\unattend-win10.xml` or `unattend\unattend-win11.xml` into
WDS console → Properties → Client → "Unattend file" for the relevant image,
or embed them in the WIM with DISM.

### 5 — Post-install scripts

After Windows lands, run the remaining scripts in order (3 → 7) on the
target PC — either manually, via a GPO startup script, or called from the
unattend `FirstLogonCommands` section pointing at a UNC share on `pc-deploy`.

## Ubiquiti DHCP setup

The router lives at `192.168.0.1`. Before PXE works you need to add two
DHCP options on the LAN scope. Run:

```powershell
.\scripts\02-setup-dhcp-options.ps1
```

…or see the comments inside that file for the equivalent Ubiquiti CLI /
UniFi web UI steps.

## Credentials

All passwords and Wi-Fi PSKs are stored in 1Password. Scripts reference
them via `op run` or `op read` — **never hard-code secrets here**. The
1Password CLI must be signed in before running any script that calls `op`.

## Repo structure

```
pc-imaging-server/
├── assets/               ← Juniper brand assets (banner SVG)
├── docs/pdf/             ← Auto-generated branded PDF docs
├── scripts/
│   ├── 00-rename-server.ps1
│   ├── 01-setup-wds.ps1
│   ├── 02-setup-dhcp-options.ps1
│   ├── 03-windows-update.ps1
│   ├── 04-install-packages.ps1
│   ├── 05-setup-printers.ps1
│   ├── 06-join-wifi.ps1
│   └── 07-remove-bloatware.ps1
├── unattend/
│   ├── unattend-win10.xml
│   └── unattend-win11.xml
├── CLAUDE.md
├── push.ps1
└── README.md
```

---

*Juniper Design internal tooling — private repository.*
