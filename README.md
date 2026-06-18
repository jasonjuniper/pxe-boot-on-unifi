# PXE Boot on UniFi

Troubleshooting and fix documentation for native PXE boot on Juniper's UniFi network.

## Problem

Target machines on the engineering subnet (192.168.5.x) could not PXE boot natively —
only via a USB flash drive with iPXE bootstrap. This repo documents the investigation,
root causes, and the fix applied to pc-deploy (192.168.5.141).

## Stack

- **pc-deploy** — Windows 11, 192.168.5.141
- **tftpd64** — TFTP + proxy DHCP server (`C:\tftpd64\`)
- **WinPE** — boot image at `C:\tftpd64\EFI\Boot\bootx64.efi`
- **UniFi router** — EFG Router at 192.168.0.1, provides DHCP options 66/67
- **Engineering switch** — TP-Link TL-SG108-M2 (unmanaged)

## Root Causes Found

1. **`Boot File` missing from tftpd64's `[DHCP]` config** — proxy DHCP had nothing to advertise
2. **`SecurityLevel=1` in tftpd32.ini** — blocked TFTP access to `EFI\Boot\bootx64.efi` (subdirectory)
3. **Wrong INI format** — build script wrote custom keys tftpd64 doesn't recognize

All three were fixed on 2026-06-18. See [PXE-FINDINGS.md](PXE-FINDINGS.md) for full details.

## Fix Summary

Both `C:\tftpd64\tftpd64.ini` and `C:\tftpd64\tftpd32.ini` on pc-deploy were updated:
- Added `Boot File=EFI\Boot\bootx64.efi` to `[DHCP]`
- Set `SecurityLevel=0`
- Set `PXECompatibility=1`
- Set `BaseDirectory=C:\tftpd64` (absolute)

## Related Projects

- [pc-imaging-server](https://github.com/jasonjuniper/pc-imaging-server) — WinPE build scripts, tftpd64 setup
- [computer-inventory](https://github.com/jasonjuniper/computer-inventory) — network inventory, UniFi API

---

*Juniper Design — internal infrastructure documentation*
