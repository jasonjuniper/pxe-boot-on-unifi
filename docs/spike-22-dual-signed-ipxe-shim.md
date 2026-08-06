# Spike #22 — Dual-signed PXE boot manager availability

**Date:** 2026-08-02
**Status:** ✅ **RESOLVED — a dual-signed iPXE shim now exists, is published, and is verified.**
**Bottom line:** The exact binary `PXE-FINDINGS.md` marked as *"Does not exist yet"* (a CA 2023 / dual-signed iPXE shim) shipped on **2025-11-07** as `ipxe-shimx64.efi` in the **ipxe/shim `ipxe-16.1`** release. It is dual-signed by **both** Microsoft UEFI CA 2011 and Microsoft UEFI CA 2023, so it boots under Secure Boot on legacy firmware *and* on IMAGE-ME (which removed CA 2011). This unblocks the Secure Boot PXE chain.

---

## The question

`PXE-FINDINGS.md` left the chain **BLOCKED**: the iPXE shim we had was signed by **MS UEFI CA 2011 only**, and IMAGE-ME (ThinkPad P14s Gen 5) had received Lenovo firmware that **removed CA 2011** from its Secure Boot `db` and added **CA 2023**. The open question tracked upstream as **rhboot/shim-review#319**: *when does a CA 2023-signed (ideally dual-signed) iPXE shim become available?*

## The answer

It's available now.

| Item | Detail |
|---|---|
| Upstream review | **rhboot/shim-review #319 — approved & signed by Microsoft** |
| Release | **ipxe/shim `ipxe-16.1`**, published **2025-11-07** |
| x64 shim | `ipxe-shimx64.efi` — **dual-signed (CA 2011 + CA 2023)** |
| aarch64 shim | `ipxe-shimaa64.efi` — **CA 2023 only** (not needed for our x64 fleet) |
| MOK manager | `mmx64.efi` / `mmaa64.efi` (same release) |
| Embedded vendor cert | **iPXE Secure Boot CA** (trusts official iPXE-signed payloads) |

## Verification (done on pc-deploy, not from the release notes alone)

I downloaded `ipxe-shimx64.efi` from the `ipxe-16.1` release onto the deploy server and parsed its PE **Attribute Certificate Table** — the same method `PXE-FINDINGS.md` used to prove `wimboot` was dual-signed.

```
file:    ipxe-shimx64.efi   (1,048,424 bytes)
sha256:  5eecca2780bd49c900565e124516a1bd666ec5e012825f34991b6ba1ef2fa6cf
PE:      PE32+ (0x20B)
Cert Table size: 19232  →  cert#1 = 9728 B , cert#2 = 9504 B   (TWO WIN_CERTIFICATE entries)
  signature #1 issuer: CN=Microsoft Corporation UEFI CA 2011   (leaf: Microsoft Windows UEFI Driver Publisher)
  signature #2 issuer: CN=Microsoft UEFI CA 2023               (leaf: Microsoft UEFI CA 2023 signer)
```

The cert table is **`19232 = 9728 + 9504`** — byte-for-byte the same two-signature layout the project already validated on the known-good dual-signed `wimboot`. Both Microsoft UEFI CAs are named explicitly in the embedded PKCS#7 blobs, so this is confirmed dual-signing, not an inference.

> Note: `Get-AuthenticodeSignature` reports `UnknownError` on this file under Windows. That is expected and **not** a problem — the Microsoft *UEFI* CAs are not in Windows' Authenticode trust store. UEFI Secure Boot validates the binary against firmware `db`, not the Windows trust store; the `certutil` dump of the embedded signatures above is the authoritative view.

## What it unblocks

- **IMAGE-ME (CA 2011 removed, CA 2023 present):** `ipxe-shimx64.efi` validates via signature #2 → passes Secure Boot. Previously rejected `0xc0000272`-class failures at the shim stage should clear.
- **Older/unpatched firmware (CA 2011 present, no CA 2023):** validates via signature #1 → still boots. One binary covers the whole fleet regardless of where each machine sits in the CA-2011→2023 rollover.
- Removes the dependency on the **Ubuntu-shim + MOK** workaround as the *first stage* (README currently uses `shimx64.efi` = Ubuntu shim as the first TFTP payload). We can move to the **official iPXE shim** as stage 1.

## Recommendation

1. **Adopt `ipxe-16.1` `ipxe-shimx64.efi` as the first TFTP payload**, plus `mmx64.efi` from the same release for MOK management. The verified copy is staged on pc-deploy at `C:\pxe-spike\ipxe-shimx64.efi` (scratch — not yet in the live `tftpd64` path).
2. **Pin the binary + hash.** After **June 2026, Microsoft will no longer dual-sign new artifacts** with CA 2011; future submissions are **CA 2023-only** and will *not* boot on firmware that still lacks CA 2023. The `ipxe-16.1` binary is the last-generation, universally-bootable dual-signed shim — capture it now and record the sha256 (`5eecca…fa6cf`) rather than tracking "latest".
3. **Decide the downstream trust model.** The shim's embedded vendor cert is the **iPXE Secure Boot CA**, so *official* iPXE binaries signed by iPXE's key chainload without MOK. Our chain uses a **Juniper-signed** `grubx64-juniper-signed.efi` / iPXE, so **MOK enrollment (`push-mok-enrollment.ps1`) is still required** — the new shim fixes stage-1 bootability but does not by itself remove the per-machine MOK step. If we're willing to run stock iPXE-signed binaries, MOK could be dropped entirely.
4. **Acceptance test = IMAGE-ME.** With Secure Boot **enabled**, PXE-boot IMAGE-ME and confirm it gets past the shim to the iPXE/MOK stage. That's the machine the whole blocker was defined against.
5. **Check SBAT.** shim 16.x ships newer SBAT generation/revocation levels; confirm the downstream Juniper iPXE/grub SBAT entries satisfy 16.1 so the shim doesn't self-revoke the next stage.

## Residual risks / watch-items

- The staged binary is verified but **not yet deployed or boot-tested** on real hardware — items 1 and 4 above are the follow-up deployment task.
- SBAT mismatch between shim 16.1 and our older Juniper iPXE is the most likely surprise; test before rolling to the fleet.
- Keep the Ubuntu-shim path documented as a fallback until the iPXE-shim chain is proven on IMAGE-ME.

## Sources

- iPXE shim signed release (dual-signed x64): https://github.com/ipxe/shim/releases/tag/ipxe-16.1
- Upstream review: rhboot/shim-review #319 — https://github.com/rhboot/shim-review/issues/319
- Microsoft — signing with the new 2023 UEFI certificates (submitter guidance): https://techcommunity.microsoft.com/blog/hardware-dev-center/signing-with-the-new-2023-microsoft-uefi-certificates-what-submitters-need-to-kn/4455787
- AlmaLinux — UEFI Secure Boot: Microsoft 2023 certificate transition (shim 16.x dual-signing; post-June-2026 no new 2011 signing): https://wiki.almalinux.org/documentation/secure-boot-2023-certificates
- Red Hat — Secure Boot certificate changes in 2026: https://developers.redhat.com/articles/2026/02/04/secure-boot-certificate-changes-2026-guidance-rhel-environments
- Local project prior art: `PXE-FINDINGS.md` (wimboot dual-sign cert-table method, CertTableSize 19232 = 9728 + 9504)
