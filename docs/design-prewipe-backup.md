# Design — Pre-wipe user-data backup for imaging/inventory

**Date:** 2026-08-03
**Status:** DESIGN — for sign-off, then phased build
**Author:** Claude (Juniper AI)
**Scope:** Capture a machine's user data before it's wiped and reimaged, from two
angles — a **live** capture by the agent while the OS is still up, and an
**offline** WinPE capture right before the disk is formatted — with per-device
selection/presets set ahead of the wipe, and a full self-service restore UI.

---

## Decisions locked (this design is built on these)

| Question | Decision |
|---|---|
| **Storage target** | **Interim (now):** pc-deploy's existing drive — a `C:\backups` root — because there's no dedicated disk yet. C: has only ~305 GB free of 476 GB and is shared with the OS, app, and `deploy$`, so **retention + capacity guards are mandatory, not optional** (see §3, §9). **Future (end-state):** a dedicated backup volume provisioned when the entire pc-deploy server is migrated to the webserver (§3.1). *Not* the world-readable `deploy$` share in either case. |
| **What to capture** | **Known folders + app data:** Desktop, Documents, Downloads, Pictures, Videos, plus browser profiles (Edge/Chrome bookmarks, favorites, saved passwords/profile) and Outlook data files (`.ost`/`.pst`). |
| **Capture mechanism** | **Both** — agent live capture as primary (ahead of the wipe window), WinPE offline as the final delta/fallback right before format. |
| **Restore** | **Full self-service restore UI** — browse any machine's backup file-by-file from the inventory app and restore (to the reimaged machine or download). |

---

## 1. Why / what this solves

Today the wipe is unforgiving: `winpe\deploy.ps1` targets disk 0, runs `diskpart
clean`, and DISM-applies the image (~line 260-290). Anything a user left on the
machine — files on the desktop, an Outlook archive, browser passwords — is gone
the moment `clean` runs. There is no capture step and no per-machine choice about
it. This design inserts a **protected, selectable capture** ahead of that point
and makes the result restorable.

Two capture angles because neither alone is sufficient:

- **Live (agent, OS up):** can run *hours ahead* of the wipe (no imaging-window
  cost), reports footprint so an operator can plan, and uses VSS to grab
  locked/open files (Outlook, browsers, OneDrive) consistently. But it needs a
  healthy OS and a logged-out-ish state, and can miss last-minute changes.
- **Offline (WinPE, right before format):** perfectly consistent (nothing is
  running), no locked-file problem, no dependency on OS health — but it happens
  *inside* the imaging window (adds time) and WinPE has no credentials.

Running both, with the WinPE pass as a **delta over a recent live capture**, gets
the best of each: most bytes moved off-hours by the agent, and a final small
catch-up in WinPE so the captured set is current as of the format.

---

## 2. Architecture at a glance

```
                        ┌─────────────────────────── pc-deploy ───────────────────────────┐
                        │                                                                  │
 [ endpoint machine ]   │   FastAPI (JuniperInventory)          C:\backups (interim volume)│
   agent (SYSTEM)       │   ├─ /api/backup/*     (config, UI)   └─ <device>\<runid>\...     │
   ├─ report footprint ─┼──▶├─ /ingest/backup/*  (agent+WinPE)     manifest.json + files    │
   ├─ live VSS capture ─┼──▶│      (token-gated)                   ACL: SYSTEM+Admins+writer │
   └─ status ───────────┼──▶├─ /api/management/backup-writer       (NOT Everyone)           │
                        │   │      (scoped SMB cred for WinPE)                               │
 [ same machine, later ]│   │                                    backup$  (NEW share)        │
   WinPE deploy.ps1      │   │                                    └─ writer-account, RW      │
   ├─ GET backup config ─┼──▶│   PostgreSQL 16                                               │
   ├─ mount old volume   │   │   ├─ device_backup_config                                     │
   ├─ delta vs live      │   │   ├─ backup_runs                                              │
   └─ write to backup$ ──┼──▶│   └─ backup_files (manifest index → restore browse)          │
                        │   │                                                                │
                        │   Inventory UI:  device page (select/preset) · /backups browse+restore │
                        └──────────────────────────────────────────────────────────────────┘
```

---

## 3. Storage & security model

**Backup store, not `deploy$`.** The imaging `deploy$` share is `Everyone:Read`
by design (WinPE has no creds, and it holds no secrets). User data is the opposite
of that — it's sensitive and must never be world-readable. So, wherever the bytes
land:

- **Interim location:** a `C:\backups` root on pc-deploy's existing drive (no
  dedicated disk yet). Because C: is shared with the OS/app/`deploy$` and has only
  ~305 GB free, the capacity guard (§9) is a hard gate here, not a nicety: the
  server refuses a capture that wouldn't fit and retention runs aggressively. A
  setup script (`setup-backup-store.ps1`, mirrors `01d-setup-deploy-share.ps1`)
  creates the tree, the `backup$` share, and the ACLs — and takes a `-BackupRoot`
  parameter so the same script re-points to the dedicated volume later with no
  code change.
- **Layout:** `<BackupRoot>\<device-serial>\<run-id>\` containing the captured tree
  under a normalized root plus a `manifest.json` (per-file path, size, hash,
  source user, mtime, capture phase). One folder per run; latest run is the
  restore default.
- **ACLs:** `SYSTEM` + `Administrators` (full) + a **dedicated low-privilege
  `backup-writer` local account** (write to `backup$` only). Explicitly **not**
  `Everyone`. Optional BitLocker/EFS on the volume for at-rest protection.
- **Two write paths, both authenticated:**
  - *Agent (live):* already holds `X-Inventory-Token`; streams to
    `/ingest/backup/*` **or** writes to `backup$` using the writer cred fetched
    from a token-gated endpoint. SMB is far more efficient for bulk data, so the
    agent mounts `backup$` with the writer cred (same runtime-fetch pattern as
    `sweep-bitlocker-fleet.ps1` uses for junadmin).
  - *WinPE (offline):* has no creds, but has network + can hit the API by IP.
    It calls the new token-gated `GET /api/management/backup-writer` (mirrors
    `/api/management/bootstrap`) to obtain the **scoped writer credential** at
    runtime, mounts `backup$`, and writes. The writer account can only write to
    the backup share — blast radius if the WinPE token leaks is one write-only
    share, and the cred is rotatable.

**Access to read backups** (restore/browse) is **admin-gated** in the app and
**audit-logged** (reuses the existing audit-logging suite), because it exposes
other people's files.

### 3.1 Interim → end-state (server migration to the webserver)

For now the store is a **dedicated `backup$` share on pc-deploy's existing C:
drive** — a *separate share* from `deploy$`, with its own path, ACLs, and writer
account, even though it's on the same physical disk. That separation is the whole
point: the data gets locked down properly now (never `Everyone:Read`), and the
storage can move later without touching any client. The one live limitation while
on C: is capacity (§9), which retention and the pre-capture free-space gate carry.

**End-state:** when the entire pc-deploy server is migrated to the webserver, a
**dedicated backup volume** is provisioned there and `setup-backup-store.ps1` is
re-run with `-BackupRoot <new-volume>`. Because the agent, WinPE, and restore all
address the store through the **`backup$` share name** — never a hardcoded drive
letter — the migration is a re-point + data copy, not a code change. The dedicated
volume is sized from the real footprint numbers collected by then (§9).

---

## 4. Data model (PostgreSQL)

Three new tables (migration `NN_backup.sql`):

- **`device_backup_config`** — the per-device selection/preset (§7).
  `device_id` (FK, unique), `enabled` (bool), `scope` (`known_folders` default |
  `custom`), `include_paths` (jsonb, for custom/extra), `exclude_paths` (jsonb),
  `destination` (defaults to the `backup$` share; kept configurable), `updated_by`,
  `updated_at`.
- **`backup_runs`** — one row per capture attempt.
  `id`, `device_id`, `phase` (`live` | `winpe`), `status` (`pending` |
  `running` | `complete` | `partial` | `failed`), `started_at`, `finished_at`,
  `bytes`, `file_count`, `accounts` (jsonb: which user profiles), `path`
  (`\\pc-deploy\backup$\<serial>\<run-id>`), `notes`.
- **`backup_files`** — the manifest index that powers restore-browse.
  `run_id` (FK), `rel_path`, `size`, `sha256`, `source_user`, `mtime`. (Populated
  from `manifest.json`; enables file-level browse/restore without walking the
  disk each time.)

A view **`v_device_backup_status`** joins the latest run per device for the UI
(last backup time, size, phase, status, fully-captured flag) — same shape as the
existing `v_cert_compliance` convenience view.

---

## 5. Live capture (agent, OS running)

**Footprint reporting (always on, cheap).** On each check-in the agent adds a
`user_data_footprint` block to its inventory POST: per real-user profile, the size
of each in-scope known folder + browser/Outlook data, and a total. This surfaces
in the UI so an operator sizing a wipe can see "ENG-7 has 42 GB across 2 profiles"
*before* deciding, and the destination volume can be capacity-checked.

**Execution (on assignment).** The agent already polls `/api/deploy/assignments`;
add a **backup assignment** to that check-in (or a sibling `/api/backup/pending`).
When a device is flagged for backup:

1. Agent creates a `backup_runs` row (`phase=live, status=running`) via
   `/ingest/backup/start`.
2. Creates a **VSS snapshot** (`diskshadow` / WMI `Win32_ShadowCopy`) so open
   files — Outlook `.ost`, browser SQLite, OneDrive — copy consistently.
3. Enumerates in-scope paths per real user profile (skip `SYSTEM`/service
   profiles), `robocopy` from the shadow to `backup$\<serial>\<run-id>\<user>\...`
   with retry/backoff; hashes as it goes to build `manifest.json`.
4. Releases the shadow; POSTs the manifest + final status
   (`complete`/`partial`) to `/ingest/backup/finish`, which populates
   `backup_files`.

Runs as `SYSTEM` (the agent's context), throttled/off-hours friendly. Idempotent:
re-running produces a new run folder; old runs age out per retention.

---

## 6. Offline capture (WinPE, right before format)

Hook in `winpe\deploy.ps1` **immediately before the `diskpart clean`** (~line
253-260), gated on config:

1. **Fetch config:** `GET /api/backup/for-device?serial=<s>&mac=<m>` (open to
   RFC1918 like the other imaging endpoints, or token via the WinPE bundle) →
   `{ enabled, scope, include/exclude, last_live_run }`.
2. **Skip/short-circuit:** if not `enabled`, continue to wipe unchanged (zero
   behavior change for machines that aren't flagged). If a **live run completed
   recently**, do a **delta** (copy only newer/missing vs the live manifest)
   instead of a full copy — keeps the imaging-window cost small.
3. **Mount the old OS volume** (it's still intact pre-`clean`); load its
   `SOFTWARE` hive to read `ProfileList` and map each user SID → profile path
   (the offline equivalent of the agent's per-user enumeration). No locked files
   offline, so no VSS needed.
4. **Auth + write:** `GET /api/management/backup-writer` (token-gated) → scoped
   writer cred; `net use` mount `backup$`; `robocopy` the in-scope tree to
   `\\pc-deploy\backup$\<serial>\<run-id-winpe>\...`; write `manifest.json`.
5. POST a `winpe` `backup_runs` row + manifest (reuse the existing
   `/ingest/winpe-event` plumbing pattern → `/ingest/backup/finish`).
6. **Only then** proceed to `diskpart clean` / DISM apply. If the backup step
   **fails and the device was flagged `enabled`, halt the wipe** and surface a
   loud error on the `/imaging` live viewer rather than silently destroying data
   (fail-safe, not fail-open). A per-run override lets an operator force-continue.

---

## 7. Selection & presets (set before the wipe)

- **Per-device control** on the inventory device page: a "Back up before wipe"
  panel — toggle, scope (`known folders` default, or `custom` with a path
  add/remove list), destination (defaults to the `backup$` share), and the live
  footprint readout so the operator sees expected size/accounts.
- **Fleet default preset:** a global setting so wipes are protected *by default*
  (recommend: `enabled=known_folders` on by default, opt-out per device) — a wipe
  should be safe unless someone deliberately says "don't bother."
- **Pre-wipe gate:** the deploy/wipe flow shows each target's backup status
  (configured? live backup present & how fresh? size?) and requires the operator
  to confirm. This is the "select or pre-set before a machine gets wiped" ask —
  either preset the fleet default and leave it, or set it per device on the way
  into a wipe.

---

## 8. Restore (full self-service UI)

A new **`/backups`** section in the inventory app (admin-gated, audited):

- **Catalog:** per device, list `backup_runs` (date, phase, size, accounts,
  status). Pick a run.
- **Browse:** a file tree built from `backup_files` (no disk walk) — expand
  folders, see sizes/dates, select files/folders or a whole scope.
- **Restore targets:**
  - *To the reimaged machine:* queue a **restore assignment**; the agent on the
    (now-reimaged) machine pulls the selected set from `backup$` into the new
    user's profile (known folders remapped to the new SID). Natural handoff after
    a wipe+reimage of the same hardware.
  - *Download:* stream selected files/a zip to the operator's browser for ad-hoc
    retrieval (e.g., "just get me their Documents").
- **Safety:** restore is admin-only, every browse/restore/download is written to
  the audit log (it's other people's data), and restores are non-destructive
  (write into place, never delete).

---

## 9. Retention, capacity, privacy

- **Retention:** auto-purge a device's backups **N days after a successful
  reimage + confirmed restore** (default 30 days, configurable) to reclaim the
  volume. A run can be **pinned** to exempt it. A nightly job (SYSTEM task on
  pc-deploy, like the others) enforces retention and logs what it purged (no
  silent deletion).
- **Capacity:** known-folders scope is modest but real, and while the store sits
  on pc-deploy's shared C: (~305 GB free) this is the tightest constraint in the
  design. The footprint report gives real per-machine numbers; budget
  `(avg GB/machine) × (machines in flight) × (retention overlap)` and keep it well
  under C:'s free space until the dedicated volume exists. The UI shows `backup$`
  free space and **refuses to start a capture that wouldn't fit** (fail-safe), and
  retention (below) runs aggressively to hold headroom on the shared drive.
- **Privacy:** user data is sensitive. Destination ACL'd (no `Everyone`), restore
  admin-gated + audited, at-rest encryption optional on the volume, and the
  `backup-writer` credential is scoped write-only and rotatable. This backup
  store is explicitly **not** the `deploy$` trust model.

---

## 10. Phased build

1. **Storage + schema:** `setup-backup-store.ps1` creates `C:\backups` + the
   `backup$` share + ACLs + writer account (interim; `-BackupRoot` re-points to the
   dedicated volume post-migration); migration `NN_backup.sql`;
   `/api/management/backup-writer`.
2. **Footprint reporting:** agent reports `user_data_footprint`; device page shows
   size/accounts. *(Low risk, immediately useful, no data moved yet.)*
3. **Live capture:** backup assignment + VSS robocopy + manifest +
   `/ingest/backup/*`; per-device config panel + fleet default.
4. **WinPE capture:** the pre-`clean` hook, offline profile enumeration, writer-
   cred mount, delta-vs-live, fail-safe halt.
5. **Restore UI:** `/backups` browse + download, then agent-driven restore-to-
   machine.
6. **Retention + capacity guards.**

Each phase is independently useful; 1-2 are safe to land with zero risk to the
live imaging path (nothing touches `winpe\deploy.ps1` until phase 4, and that
change is gated so un-flagged machines are unaffected).

## 11. Open items to confirm at build time

- Interim: how much `C:\backups` headroom to reserve and how aggressive retention
  must be to stay safe on the shared C: drive. At server-migration time: the size
  and encryption (BitLocker/EFS) of the dedicated backup volume on the webserver.
- Agent SMB-write to `backup$` vs HTTP chunked upload to `/ingest/backup` — SMB
  recommended for bulk; confirm firewall/pathing from endpoints to pc-deploy.
- Fleet default: ship backup **on-by-default** (opt-out) vs off-by-default
  (opt-in). Recommendation: on-by-default for known-folders — a wipe should be
  safe unless someone opts out.
- Browser saved-password portability: capturing the profile preserves them only
  when restored to the same user/machine identity; cross-user restore won't
  decrypt DPAPI-bound secrets. Documented limitation, not a blocker.

---

*Juniper Design — internal infrastructure. Companion to the imaging (`PXE Boot on
Unifi`) and inventory (`Computer Inventory`) repos.*

## Build status — 2026-08-03

Implemented, deployed live, and validated on ASSEMBLY2 (device 66):
- **Phase 1** — backup store + schema + `/api/management/backup-writer` (`backup$` share, low-priv `junbackup` writer, ACL'd key file).
- **Phase 2** — agent `user_data_footprint` reporting + device-page readout.
- **Phase 3** — live capture pipeline (request → pending → writer-cred mount → robocopy `/B` to `backup$` → manifest → start/finish) + device-page panel (status, enable/scope, "Back up now").
- **Phase 5** — restore browse + download over the manifest (admin-gated, path-traversal-guarded).
- **Phase 6** — capacity guard (`/api/backup/request` refuses over-capacity vs footprint) + nightly retention task (`JuniperBackupRetention`, prunes complete/unpinned runs older than N days; `pinned` exempts).
- **Phase 4 server contract** — `GET /ingest/backup/for-device` (RFC-1918) returns config + last completed live run for WinPE.

Pending (needs real-hardware validation before touching the wipe path):
- **Phase 4 WinPE hook** in `winpe\deploy.ps1` immediately before `diskpart clean` — deliberately NOT wired yet. It sits right before an irreversible wipe, and WinPE's reduced PowerShell must first be verified on a real PXE boot to support the capture (`Invoke-RestMethod` / `New-PSDrive` / offline `ProfileList` hive reads may be absent). Open item: WinPE carries no token, so it needs an RFC-1918 `/ingest/backup/writer` variant (mirroring the bootstrap-cred model) to fetch the `backup$` writer credential.

Refinements: VSS-consistent capture (currently robocopy `/B`); honor `exclude_paths` in the agent; per-file SHA-256 + manifest chunking; agent-driven restore-to-machine (5b); add mutating `/ingest/backup/*` to `ENFORCE_INGEST`; `junbackup` 1Password record.

Note: agent **0.5.20** (footprint + capture) serves on the deferred agent deploy (bundled with Option A, at stuck-agent sweep convergence).

## Finalized capture scope (2026-08-03, validated on ASSEMBLY2)

Baked into `endpoint_agent.ps1` (0.5.20). Per user profile:
- Known folders: Desktop, Documents, Downloads, Pictures, Videos (full).
- Favorites folder (.url shortcuts).
- Browser **Bookmarks file only** (Edge/Chrome, per profile) — NOT the profile tree.
- Outlook data **minus `*.ost`** (the .ost re-downloads from M365 after reimage; `.pst` kept).

Machine-level: **`C:\dev`** (standing fleet default) + any `device_backup_config.include_paths`.

Explicitly excluded: browser cache/storage/extensions, Outlook `.ost`. Result on ASSEMBLY2 (device 66, run 6): **121 files / 25 MB / 18 s** — versus 15+ minutes and hundreds of MB when cache/OST were swept in. The sanity check confirmed the genuinely-needed data is ~25 MB (C:\dev 12 MB + profile 13 MB).

## Update — restore-to-machine + WinPE writer (2026-08-03)

- **Phase 5b restore-to-machine** implemented + validated on ASSEMBLY2 (run 6 pulled back: 121 files / 24.5 MB): `POST /api/backup/restore`, `GET /api/backup/restore/pending`, `POST /ingest/backup/restore-finish`; agent stages the run to `C:\JuniperRestore\<run>` (non-destructive); device panel gains a "restore to machine" link per run. **Restore-into-place** (remap into the current profile / `C:\dev`) is the remaining follow-up and should be validated on a freshly-reimaged machine, not a live one.
- **Phase 4 WinPE writer cred**: `GET /ingest/backup/writer` (RFC-1918, token-less) added so the offline hook can mount `backup$` without a token. The Phase-4 **server side (for-device + writer) is now complete**; the `winpe\deploy.ps1` hook itself still needs the supervised real-boot test.
- **Design note:** `/ingest/backup/*` intentionally stays OPEN (RFC-1918, no token) rather than joining `ENFORCE_INGEST`, because the WinPE offline path carries no token pre-OS — this matches the existing wifi/bootstrap imaging model. `writer` and `for-device` are additionally RFC-1918-gated.
- **Pending (needs a human at the machine):** the `junbackup` 1Password record — `op` on ENG-1 requires interactive Windows Hello, so it can't be created from a headless session.
