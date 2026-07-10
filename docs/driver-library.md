# Automated Lenovo driver library

End-to-end tooling that builds a complete, offline-injectable driver library for
any Lenovo machine type we own, straight from Lenovo's public Update Retriever
catalog. Replaces the old hand-assembled `<MT>-driver-manifest.json` files.

All scripts live in `scripts/` (this repo) and run on **pc-deploy**
(`C:\deploy\scripts`), which has outbound HTTPS to `download.lenovo.com`.

## Pipeline

```
build-lenovo-manifest.ps1   catalog  -> <MT>-driver-manifest.json   (XML only, fast)
  -> sync-lenovo-drivers.ps1   manifest -> driver_packages rows (status=unconfirmed)
  -> curate-lenovo-model.ps1   download each .exe, silent-extract, keep only .inf
  -> promote-lenovo-model.ps1  confirmed_working + backfill real sha256 + manifest.json
```

### 1. `build-lenovo-manifest.ps1` (NEW - the generator)
Fetches `https://download.lenovo.com/catalog/<MT>_<OS>.xml`, walks every package
descriptor, and resolves the installer `.exe` URL, version, category and PnP IDs.
Writes `<MT>-driver-manifest.json` in the schema the sync/curate steps expect.

- `sha256`/`size_bytes` are left blank/best-effort here - curate computes the real
  SHA256 on download and promote backfills it. Keeps generation to XML only (no
  multi-GB downloads at manifest time).
- Category mapping note: Lenovo's motherboard/chipset category string literally
  contains the word "video", so Chipset is matched **before** Display/Video.

```powershell
.\build-lenovo-manifest.ps1 -MachineType 83JU -Os Win11
```

### 2/3. sync + curate (existing)
`sync-lenovo-drivers.ps1` upserts catalog rows; `curate-lenovo-model.ps1` downloads
each SoftPaq, silently extracts (`/VERYSILENT /EXTRACT=YES`), keeps only packages
that yield `.inf` (BIOS/firmware/app packages are dropped), and stages them under
`C:\deploy\drivers\<slug>-curated\<subdir>\<name>\`. Writes
`_staging\<MT>_curate-results.json`.

### 4. `promote-lenovo-model.ps1` (NEW)
Renames `<slug>-curated` -> `<slug>`, marks every `.inf`-bearing row
`confirmed_working` with `file_path = <slug>\<subdir>\<name>` and the real SHA256
curate computed, then regenerates `manifest.json` (DB-driven) and writes it to
`C:\deploy\drivers\manifest.json` for deploy.ps1 offline injection.

```powershell
.\promote-lenovo-model.ps1 -MachineType 83JU -Slug lenovo-yoga-7-16akp10
```

## Fleet runner: `build-driver-library.ps1` (NEW)
Runs the full pipeline for every target in `driver-library-targets.json`
sequentially (best-effort; one model failing never aborts the rest). Logs to
`C:\deploy\_staging\driver-library.log`. Intended to run as a SYSTEM scheduled task.

```powershell
.\build-driver-library.ps1                    # all targets
.\build-driver-library.ps1 -OnlyMt 20Y3,82YN  # subset
.\build-driver-library.ps1 -SkipCurate        # manifests + DB rows only (no downloads)
```

### Adding a new model
Append an entry to `driver-library-targets.json`:

```json
{ "mt": "83JU", "slug": "lenovo-yoga-7-16akp10", "model": "Yoga 7 2-in-1 16AKP10" }
```

`mt` = Lenovo 4-char machine type (first 4 chars of the WMI model string), `slug`
= driver folder under `C:\deploy\drivers\`, `model` = friendly name for the catalog.
The `/api/drivers/manifest.json` endpoint auto-maps the machine type to the real
WMI Model strings from the `devices` table, so deploy.ps1 matches a live machine.

## Owned-fleet targets (as of 2026-07-07)
| MT | Model | Slug | Notes |
|----|-------|------|-------|
| 83JU | Yoga 7 2-in-1 16AKP10 | lenovo-yoga-7-16akp10 | 28 confirmed_working |
| 20Y3 | ThinkPad P1 Gen 4 | lenovo-thinkpad-p1-gen4 | |
| 21DC | ThinkPad P1 Gen 5 | lenovo-thinkpad-p1-gen5 | |
| 20TQ | ThinkPad P15v Gen 1 | lenovo-thinkpad-p15v-gen1 | |
| 21M7 | ThinkPad E14 Gen 6 | lenovo-thinkpad-e14-gen6 | |
| 82YN | IdeaPad Flex 5 | lenovo-ideapad-flex5 | |
| 21FE | ThinkPad T14s Gen 4 | lenovo-thinkpad-t14s-gen4 | previously curated |
| 21G2 | ThinkPad P14s Gen 5 | lenovo-thinkpad-p14s-gen5 | previously curated |

Dell (XPS, OptiPlex) and HP (Pavilion) use their own existing pipelines
(`sync-dell-drivers.ps1`, `fetch-hp-catalog.ps1`). UniFi devices (UAPA/UDME/US48)
are network gear - no drivers.

> Note: consumer models (Yoga/IdeaPad) have no Lenovo SCCM driver pack - only
> individual SoftPaqs - which is exactly what this generator consumes. Windows
> Update also covers consumer models well; the offline library guarantees coverage
> for WinPE injection and network-less first boot.
