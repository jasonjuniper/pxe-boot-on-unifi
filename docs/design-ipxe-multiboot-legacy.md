# Design — iPXE multi-boot menu + legacy (pre‑CA‑2023) PC support

**Date:** 2026-08-02
**Status:** DESIGN (for sign-off) → then phase 1 build
**Author:** Claude (Juniper AI)
**Scope:** Add an operator boot **menu** to PXE, and a boot path for **older PCs whose firmware `db` predates the Microsoft UEFI CA 2023**, without disturbing the working WDS + patched‑WinPE Secure Boot deploy that already images modern machines.

---

## 1. Why now

Two things the current stack can't do gracefully:

- **A boot menu.** WDS hands a single boot image straight to the client. There's no operator choice of "deploy vs. rescue tool vs. a different image."
- **Old firmware.** The live NBP is `wdsmgfw_EX` / `bootmgfw_EX`, signed **CA 2023 only**. A machine whose `db` still trusts only the 2011 CAs (never got the KB5025885‑era update) will **reject** that NBP outright — it can't even reach WinPE.

Spike #22 removed the historical blocker: the official **`ipxe-16.1` shim is dual-signed (MS UEFI CA 2011 + MS UEFI CA 2023)** and is vetted on‑hand at `C:\pxe-spike\` (shim `sha256 5eecca…fa6cf`, `mmx64` `sha256 ccb0c4…9b7f`). A dual-signed first stage is exactly what both features need.

## 2. What dual-signing does and does NOT solve

**Solves — the first stage, for everyone.** The dual-signed shim validates on **both** populations: modern firmware accepts it via its 2023 signature (IMAGE‑ME), legacy firmware via its 2011 signature. One NBP, both worlds — strictly better than the CA‑2023‑only `wdsmgfw_EX`.

**Does NOT solve — the last stage.** Once WinPE is loading, the OS loader `winload.efi` inside it must still be trusted by that specific machine's `db`. The current patched WinPE's `winload` is signed **Windows UEFI CA 2023** — perfect for modern firmware, **rejected** by legacy firmware that lacks that CA (the mirror image of the original IMAGE‑ME failure). So a single boot.wim cannot cover both under Secure Boot regardless of the shim.

**The menu is the resolver.** Because iPXE (chainloaded by the shim) draws the menu, each entry can HTTP‑boot a *different* payload. Modern machines pick a CA‑2023 WinPE; legacy machines pick a **PCA‑2011‑signed** WinPE their firmware still trusts. Goal #1 (menu) becomes the delivery mechanism for goal #2 (legacy). For truly un‑updatable stragglers the honest fallbacks remain: push the KB5025885 `db` update, or image with Secure Boot off.

## 3. Target architecture

```
Client UEFI PXE  →  DHCP opt 67 = ipxe-shimx64.efi   (served by WDS's TFTP; WDS keeps UDP 69)
  → shim (dual-signed, boots on 2011-only AND 2023 db)
      → loads grubx64.efi  (= grubx64-juniper-signed.efi, SB iPXE signed by Juniper PXE CA)   [MOK: juniper-pxe-ca]
          → iPXE runs menu.ipxe  →  operator chooses:
                1) Deploy — modern (CA 2023 firmware)   → HTTP wimboot + patched WinPE (winload 26100.32995)   [DEFAULT]
                2) Deploy — legacy (pre-CA-2023 PC)      → HTTP wimboot + PCA-2011 WinPE (winload old-but-trusted)
                3) Tools — memtest / rescue shell        → HTTP payload                                   [phase 2+]
                4) Boot from local disk                  → exit / sanboot
                5) Reboot
```

Only the **NBP swap** (`wdsmgfw_EX` → `ipxe-shimx64.efi`) touches the live path, and `wdsmgfw_EX` stays staged for a one‑line rollback. WDS remains the TFTP transport and the WinPE host; Caddy keeps serving the HTTP payloads on pc‑deploy.

## 4. Trust / signing model (the fiddly part)

- **Shim:** MS‑signed and dual‑signed → boots under Secure Boot with **no MOK** on both firmware generations. Nothing to enroll for stage 1.
- **grubx64 (iPXE):** it's **Juniper‑signed**, and the `ipxe-16.1` shim's embedded vendor cert is the **iPXE Secure Boot CA**, not ours. So the shim will not trust our iPXE via its vendor cert — **MOK enrollment of `juniper-pxe-ca.cer` is still required per machine** (unchanged from today's Ubuntu‑shim path; `push-mok-enrollment.ps1` already does this). Dropping MOK entirely would mean shipping stock iPXE‑CA‑signed iPXE — a separate decision, out of scope here.
- **SBAT:** shim 16.x carries newer SBAT revocation levels. Our `grubx64-juniper-signed.efi` must satisfy shim 16.1's SBAT or the shim will refuse it. **Verify during phase 1**; rebuild/bump iPXE SBAT if needed.
- **winload (per entry):** modern entry = CA‑2023 winload (already have it); legacy entry = PCA‑2011 winload that old `db` still trusts (source below).

## 5. The modern-vs-legacy WinPE split

| Entry | winload signing | Boots on | Source |
|---|---|---|---|
| Modern (default) | Windows UEFI CA 2023 | firmware WITH CA 2023 `db` (modern, IMAGE‑ME) | existing "deploy‑ready" WinPE (26100.32995) — reuse as‑is |
| Legacy | Windows Production PCA 2011 | firmware WITHOUT CA 2023 (old, un‑updated) | a WinPE whose `winload` is PCA‑2011 and NOT DBX‑revoked on the target — e.g. an older 24H2 WinPE; validate against a real pre‑2023 unit |

Assumption to confirm with Jason: the legacy entry serves **both** "machines we re‑image before they've received the CA‑2023 `db` update" *and* genuinely old hardware that will never get it — the mechanism (a PCA‑2011‑trusted WinPE) is identical either way, so the entry is designed as a durable fixture, not a temporary bridge. Same `deploy.ps1` payload runs inside both WinPE variants; only the boot‑critical files differ.

## 6. Phased plan

1. **Stand up + validate the iPXE menu chain in staging (WDS untouched).** Assemble `ipxe-shimx64.efi` + `grubx64.efi` + `mmx64.efi` + `menu.ipxe` in a staging dir; confirm the shim→grubx64 loader name, the SBAT level, and that the HTTP payloads (wimboot + boot.wim) are reachable via Caddy. No live‑path change.
2. **Wire the menu entries.** Modern WinPE first (re‑use the deploy‑ready image), then add the legacy‑WinPE entry once a PCA‑2011 WinPE is sourced. Tools/rescue entries optional.
3. **Flip the live NBP for a hardware test.** Copy the shim + grubx64 + menu into `C:\RemoteInstall\Boot\x64\`, back up `wdsmgfw_EX`, point the NBP (DHCP opt 67 / `wdsutil /set-server /bootprogram`) at `ipxe-shimx64.efi`, restart WDS. **Rollback = point NBP back at `wdsmgfw.efi` + restart WDS** (`wdsmgfw_EX` untouched throughout). Test IMAGE‑ME (modern) with Secure Boot ON.
4. **Validate the legacy path** against an actual pre‑CA‑2023 machine; confirm menu entry 2 boots where the CA‑2023 chain can't.

## 7. Testing matrix

| Machine | Firmware `db` | Expect | Confirms |
|---|---|---|---|
| IMAGE‑ME (ThinkPad P14s Gen 5) | CA 2023, no CA 2011 | shim boots (2023 sig) → menu → modern entry → images | no regression vs. WDS; menu works |
| A pre‑CA‑2023 unit | CA 2011, no CA 2023 | shim boots (2011 sig) → menu → **legacy** entry → images | goal #2 end‑to‑end |
| (rollback drill) | — | NBP back to `wdsmgfw_EX`, modern images as today | instant revert path proven |

## 8. Risks / open items

- **MOK friction** stays per‑machine for the Juniper‑signed iPXE (same as today). Acceptable; note it.
- **SBAT mismatch** between shim 16.1 and our iPXE is the most likely phase‑1 surprise — verify early.
- **Legacy WinPE sourcing** — need a PCA‑2011 `winload` WinPE that old `db` trusts and that isn't DBX‑revoked on the target; validate on real hardware, don't assume.
- **iPXE feature set** — `grubx64-juniper-signed.efi` must be an HTTP‑capable SB build; confirm it can reach Caddy (HTTP, and TLS if we move payloads to HTTPS).
- **NBP swap blast radius** — it changes the first stage for *every* PXE client, so it's gated behind the phase‑3 hardware test with the `wdsmgfw_EX` rollback staged.

---

*Juniper Design — internal infrastructure. Companion to `docs/spike-22-dual-signed-ipxe-shim.md`.*
