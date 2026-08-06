# Design v3 — Fleet Secure Boot imaging + PXE menu (evidence‑validated)

**Date:** 2026-08-02
**Status:** DESIGN — **supersedes** `design-ipxe-multiboot-legacy.md`. Core Secure‑Boot claims below are now **validated on real hardware (ENG‑3)**, not theoretical.
**Author:** Claude (Juniper AI)

## Foundation (proven, unchanged)

The only PXE chain that has ever worked in this environment is **WDS serving the up‑to‑date Microsoft `Windows UEFI CA 2023` boot manager** (`wdsmgfw_EX`/`bootmgfw_EX`) with the patched, non‑revoked WinPE (`winload` 26100.32995). Everything below is built on that. iPXE is not part of the working baseline.

---

## Goal A — Multi‑boot menu  (design only — NOT yet validated)

WDS automatically presents a **boot‑image selection menu** when more than one boot image is registered for the client architecture. So the menu is a native capability: register a **Rescue/Diagnostics** WinPE and/or a **Tools** WinPE alongside the deploy image, each built the same WinRE‑based way so they all boot under Secure Boot. OS selection already lives inside WinPE (`deploy.ps1`), so the WDS menu is for choosing the WinPE/role. No third‑party bootloader, nothing new to sign.

A **fresh, current iPXE** menu is a real alternative now that iPXE ships official signed binaries (MS‑signed dual‑signed shim → official iPXE‑CA‑signed `ipxe.efi`, **no MOK**), built only from current official binaries — but it has never booted in this environment and would need its own hardware proof before trust. Recommendation: **WDS‑native menu first**; treat official‑iPXE as an optional later pilot.

---

## Goal B — Pre‑CA‑2023 machines  (VALIDATED today on ENG‑3)

Machines fail on the working chain when their firmware `db` lacks **Windows UEFI CA 2023**. The fix is to bring the machine onto CA 2023 — not to maintain a second boot chain. Two cases, split by whether the machine has an OS.

### B1 — Machine HAS an OS  →  in‑OS servicing  (PROVEN)

Opt in and let Windows' built‑in servicing enroll CA 2023:

- Registry opt‑in `AvailableUpdates = 0x1844` (Microsoft: **"KEK 2023 + DB certificates only"** — additive; does not touch the boot loader or DBX), then trigger `\Microsoft\Windows\PI\Secure-Boot-Update`. Or the GPO *Enable Secure Boot Certificate Deployment* for domain‑wide rollout.
- Verify: `[Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name db).Bytes) -match 'Windows UEFI CA 2023'`.

**Validated on ENG‑3 (HP ZBook Fury 16 G9), a genuine pre‑CA‑2023 machine:** the opt‑in added Windows UEFI CA 2023 to `db` **and** CA 2023 to KEK; the `WindowsUEFICA2023Capable` flag resolved `0 → 1` (the earlier `0` meant "not yet assessed," not "incapable"); `Status` went `NotStarted → InProgress`; the enrollment **survived a reboot**; and the machine stayed healthy throughout because its on‑disk boot manager remained the trusted PCA‑2011 build. **Important behavior:** the `0x1844` step itself is additive, but Windows' servicing is **phased** — it auto‑stages the next phase (`AvailableUpdates 0x4100`, the boot‑manager swap to CA 2023) and completes over **a couple of reboots / servicing passes** on its own. That's the full, desired modernization; it's safe because `db` already trusts CA 2023 before the boot manager is swapped.

**Constraint:** this servicing runs **inside a live Windows OS** — it is **not** available from WinPE (Microsoft‑confirmed: WinPE lacks the Task Scheduler + `tpmtasks.dll` servicing stack). So B1 is a **pre‑image fleet task** (Intune/GPO/agent) *or* a **post‑deploy first‑boot** step — never a bare‑metal trick.

### B2 — Machine has NO OS (new‑old‑stock, bare metal)  →  image SB‑off, self‑heal on first boot

Because CA‑2023 enrollment needs a running OS, a NOS box can't be pre‑enrolled. Flow:

1. Image with **Secure Boot OFF** (its firmware trusts only 2011‑era CAs; the working chain images it fine).
2. On first boot the deployed OS runs two post‑deploy steps: **(a)** the servicing task self‑enrolls CA 2023 into `db` (B1), and **(b)** a vendor‑branch step re‑enables Secure Boot.
3. Reboot → permanently on the modern chain.

The blocker we worried about was step (b) needing a human. **Resolved by test** (below): on the HP ZBook it re‑enables **unattended**.

---

## Per‑vendor Secure Boot enable  (the automation hinge)

There is no generic OS API to enable Secure Boot (by design). It goes through each vendor's authenticated BIOS tooling:

- **Lenovo** (ENG‑0/1/2 — ThinkPad P14s Gen 5, `21G2002DUS`): WMI `Lenovo_SetBiosSetting("SecureBoot,Enable")` + `Lenovo_SaveBiosSettings("<supervisor-pw>,ascii,us")`, applied on reboot, **no physical presence**. Standard OSD practice.
- **HP** (ENG‑3 — ZBook Fury 16 G9): HP WMI `HP_BIOSSettingInterface.SetBIOSSetting('Secure Boot','Enable',<pw>)` (or HP CMSL / BCU).

**Validated on ENG‑3:** enabling Secure Boot from the OS via HP WMI returned success and applied **with NO physical‑presence confirmation code** — it booted straight into Windows with `SecureBoot = True`. This directly **disproves the earlier "HP needs the code" belief for this model**, even though Sure Start's *Secure Boot Keys Protection* and the *Physical Presence Interface* setting were both enabled and **no setup password was set**. So HP folds into the automated flow rather than being a one‑keypress exception.

**Caveats worth respecting:**
- This was proven **for the ZBook Fury 16 G9 with no setup password**. Other HP models / BIOS revisions may behave differently — **re‑verify per model** before trusting unattended.
- If a **setup password** is set (recommended for authenticated fleet control), some HP/Lenovo models require it be **supplied** to the WMI/CMSL call — a known, solvable requirement, not a wall. The password is standard IT hygiene, is itself scriptable to set via the same tools, and per policy lives in 1Password (handed to the tool at runtime, never in a script).
- Safe ordering for the real workflow: **CA 2023 into `db` first, then enable Secure Boot.** (On ENG‑3 we did the reverse for the test and verified first that the boot manager was PCA‑2011/trusted, so there was no brick risk — but production should enroll first.)

---

## Fleet rollout checklist

1. **Existing machines (have an OS):** push the CA‑2023 db‑servicing opt‑in (GPO/Intune/agent), let it modernize over its phased passes; verify `db`.
2. **New imaging (has‑OS end state):** post‑deploy first‑boot step — self‑enroll CA 2023, then vendor‑branch Secure Boot enable (Lenovo WMI / HP WMI), keyed off make (inventory already knows make/model). Fold into `deploy.ps1`.
3. **NOS/bare metal:** image SB‑off → the same post‑deploy self‑heal (enroll + re‑enable) brings it onto the modern chain hands‑off (given the per‑model SB‑enable is confirmed unattended).
4. **Menu (Goal A):** register extra WDS boot images when the Rescue/Tools WinPEs are built.
5. **Standardize a known BIOS admin/supervisor password** across the fleet (1Password‑sourced) so authenticated SB changes stay unattended even where a password is required.

## Open items

- Re‑verify unattended Secure‑Boot‑enable on **non‑ZBook HP models** and on machines **with a setup password set** before fleet‑wide trust.
- ENG‑3's boot‑manager phase (`0x4100`) still finishing over its remaining passes — confirm it reaches `Status = Completed` with `bootmgr = CA 2023`.
- Goal A menu unproven; official‑iPXE path unproven — both need a hardware test before adoption.
- `AvailableUpdates` bitmask values are staged/version‑specific — confirm against Microsoft's live KB at rollout time rather than hard‑coding.

## Sources

- Microsoft — Secure Boot certificate updates guidance for IT pros: https://support.microsoft.com/en-us/topic/secure-boot-certificate-updates-guidance-for-it-professionals-and-organizations-e2b43f9f-b424-42df-bc6a-8476db65ab2f
- Microsoft — updating Secure Boot variables from WinPE is unsupported (needs full‑OS servicing stack): https://learn.microsoft.com/en-my/answers/questions/5789001/updating-secure-boot-variables-(kek-db-dbx)-from-w
- woshub — AvailableUpdates opt‑in, `Secure-Boot-Update` task, `Get-SecureBootUEFI` verify: https://woshub.com/updating-uefi-secure-boot-certificates-windows-faq/
- Lenovo Secure Boot enable via WMI (OSD): https://www.mcsmlab.com/blog/2025/1/28/enable-securebootonlenovo-powershell-script · https://www.imab.dk/configure-and-use-lenovo-bios-supervisor-password-during-osd-using-powershell-and-configuration-manager/
- HP Sure Admin + CMSL BIOS config: https://developers.hp.com/hp-client-management/blog/secure-bios-hp-sure-admin-and-cmsl
- **Live validation, ENG‑3 (2026‑08‑02):** unattended HP Secure Boot enable (no code); CA‑2023 `db`/KEK enrollment via `0x1844`, Capable `0→1`, survived reboot, boot manager PCA‑2011 trusted throughout.

---

*Juniper Design — internal infrastructure.*
