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

This repo controls the **pc-deploy** imaging server (host currently named
`DESKTOP-I8UM43L`). It PXE-boots target PCs and automates:

- Windows 10 and 11 unattended installation (WDS + answer files in `unattend/`)
- All Windows updates (`03-windows-update.ps1`)
- MSI and winget package installs (`04-install-packages.ps1`)
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

## Key paths (on pc-deploy once renamed)

- WDS root: `C:\RemoteInstall\`
- Boot images: `C:\RemoteInstall\Boot\x64\`
- Install images: `C:\RemoteInstall\Images\`
- Answer files: `C:\RemoteInstall\WdsClientUnattend\`
- Post-install scripts share: `\\pc-deploy\deploy$\scripts\`

## Script run order (first-time server setup)

1. `00-rename-server.ps1` — rename + reboot
2. `01-setup-wds.ps1` — install WDS role + configure
3. `02-setup-dhcp-options.ps1` — update Ubiquiti router DHCP options
4. Add Windows images via WDS console or `wdsutil`
5. Drop unattend XML files into WDS

## Script run order (per target PC, post-install)

3 → 4 → 5 → 6 → 7 (can be chained via `FirstLogonCommands` in unattend)

## Router access

Ubiquiti at `192.168.0.1` — credentials in 1Password.
DHCP options required: `66` = TFTP server IP of pc-deploy, `67` = `boot\x64\wdsnbp.com`.
