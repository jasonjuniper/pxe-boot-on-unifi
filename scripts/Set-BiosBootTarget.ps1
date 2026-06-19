<#
.SYNOPSIS
    Translates a logical boot target ("PXE", "HDD", "USB", "OneBoot-PXE") into the
    correct BIOS/UEFI command for the current machine's vendor.

.DESCRIPTION
    Detects vendor and model from WMI, loads the matching profile from bios-profiles\,
    then executes the appropriate BIOS change:

      Lenovo ThinkPad   — root\WMI Lenovo_SetBiosSetting / Lenovo_SaveBiosSettings
      Dell              — DellBIOSProvider module (installs if needed) or generic UEFI
      HP                — HPCMSL module or generic UEFI
      Any UEFI system   — Generic EFI variable manipulation (fallback)

    Can run locally or be invoked via Invoke-Command for remote machines.
    Requires admin rights. For remote use, the remote session needs LocalAccountTokenFilterPolicy=1.

.PARAMETER Target
    Logical boot target. One of:
        PXE          — Put wired PXE first in boot order (permanent)
        HDD          — Put local disk first (normal post-imaging setting)
        USB          — Put USB first
        OneBoot-PXE  — One-time PXE boot via BootNext EFI variable (next boot only)
        OneBoot-HDD  — One-time HDD boot via BootNext EFI variable

.PARAMETER BiosPassword
    BIOS supervisor password. Required for Lenovo ThinkPad if a supervisor password
    is set. Leave empty if no BIOS password is configured.

.PARAMETER ProfilesPath
    Path to the bios-profiles\ directory. Defaults to the sibling directory of this
    script (i.e., this script should live in scripts\, profiles in bios-profiles\).

.PARAMETER WhatIf
    Show what would be changed without making any changes.

.EXAMPLE
    # Set PXE as first boot device on the local machine
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Set-Location "C:\dev\PXE Boot on Unifi"
    .\scripts\Set-BiosBootTarget.ps1 -Target PXE

.EXAMPLE
    # Post-imaging: revert to HDD boot
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Set-Location "C:\dev\PXE Boot on Unifi"
    .\scripts\Set-BiosBootTarget.ps1 -Target HDD

.EXAMPLE
    # One-time PXE boot for a remote machine (from pc-deploy)
    $cred = Import-Clixml 'C:\Users\Junadmin\.juniper\push-cred.xml'
    Invoke-Command -ComputerName 192.168.11.24 -Credential $cred -FilePath .\scripts\Set-BiosBootTarget.ps1 -ArgumentList 'OneBoot-PXE'

.NOTES
    Profiles directory: C:\dev\PXE Boot on Unifi\bios-profiles\
    See bios-profiles\README or individual .json files for vendor-specific details.
    Author: Juniper Design — 2026-06-19
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('PXE', 'HDD', 'USB', 'OneBoot-PXE', 'OneBoot-HDD')]
    [string]$Target,

    [string]$BiosPassword = '',

    [string]$ProfilesPath = '',

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy Bypass -Scope Process -Force

# ---------------------------------------------------------------------------
# Locate profiles directory
# ---------------------------------------------------------------------------
if (-not $ProfilesPath) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ProfilesPath = Join-Path (Split-Path -Parent $scriptDir) 'bios-profiles'
}
if (-not (Test-Path $ProfilesPath)) {
    throw "bios-profiles directory not found at: $ProfilesPath"
}

# ---------------------------------------------------------------------------
# Detect vendor and model
# ---------------------------------------------------------------------------
$cs = Get-WmiObject Win32_ComputerSystem
$vendor = $cs.Manufacturer.Trim()
$model  = $cs.Model.Trim()
Write-Host "Detected: Vendor='$vendor'  Model='$model'"

# ---------------------------------------------------------------------------
# Load vendor map and find matching profile
# ---------------------------------------------------------------------------
$vendorMap = Get-Content (Join-Path $ProfilesPath 'vendor-map.json') | ConvertFrom-Json
$matched = $null
foreach ($m in $vendorMap.mappings) {
    if ($vendor -like $m.vendor_pattern -and $model -like $m.model_pattern) {
        $matched = $m
        break
    }
}
if (-not $matched) {
    Write-Warning "No vendor profile matched '$vendor' / '$model' — using generic UEFI fallback."
    $matched = [pscustomobject]@{ profile = 'generic-uefi'; bios_method = 'generic'; friendly_name = 'Unknown' }
}
Write-Host "Profile: $($matched.friendly_name) ($($matched.profile))"

# ---------------------------------------------------------------------------
# Dispatch to the right method
# ---------------------------------------------------------------------------
switch -Wildcard ($matched.bios_method) {

    'wmi' {
        Invoke-LenovoThinkPadWmi -Target $Target -ProfilesPath $ProfilesPath -BiosPassword $BiosPassword -WhatIf:$WhatIf
    }

    'wmi-or-generic' {
        # Try WMI first; fall back to generic UEFI
        $wmiOk = $null -ne (Get-WmiObject -Namespace root\WMI -Class Lenovo_BIOSSetting -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($wmiOk) {
            Write-Host "WMI available — using Lenovo WMI"
            Invoke-LenovoThinkPadWmi -Target $Target -ProfilesPath $ProfilesPath -BiosPassword $BiosPassword -WhatIf:$WhatIf
        } else {
            Write-Host "Lenovo WMI not available — falling back to generic UEFI"
            Invoke-GenericUefi -Target $Target -WhatIf:$WhatIf
        }
    }

    'dell-bios-provider-or-generic' {
        $dellOk = $null -ne (Get-Module -Name DellBIOSProvider -ListAvailable -ErrorAction SilentlyContinue)
        if (-not $dellOk) {
            Write-Host "DellBIOSProvider not installed — installing from PSGallery..."
            if (-not $WhatIf) {
                Install-Module -Name DellBIOSProvider -Force -SkipPublisherCheck -ErrorAction SilentlyContinue
                $dellOk = $null -ne (Get-Module -Name DellBIOSProvider -ListAvailable -ErrorAction SilentlyContinue)
            }
        }
        if ($dellOk) {
            Invoke-DellBiosProvider -Target $Target -WhatIf:$WhatIf
        } else {
            Write-Warning "DellBIOSProvider unavailable — using generic UEFI"
            Invoke-GenericUefi -Target $Target -WhatIf:$WhatIf
        }
    }

    'hpcmsl-or-generic' {
        $hpOk = $null -ne (Get-Module -Name HPCMSL -ListAvailable -ErrorAction SilentlyContinue)
        if (-not $hpOk) {
            Write-Host "HPCMSL not installed — installing from PSGallery..."
            if (-not $WhatIf) {
                Install-Module -Name HPCMSL -Force -SkipPublisherCheck -AcceptLicense -ErrorAction SilentlyContinue
                $hpOk = $null -ne (Get-Module -Name HPCMSL -ListAvailable -ErrorAction SilentlyContinue)
            }
        }
        if ($hpOk) {
            Invoke-HpCmsl -Target $Target -WhatIf:$WhatIf
        } else {
            Write-Warning "HPCMSL unavailable — using generic UEFI"
            Invoke-GenericUefi -Target $Target -WhatIf:$WhatIf
        }
    }

    default {
        Invoke-GenericUefi -Target $Target -WhatIf:$WhatIf
    }
}

# ===========================================================================
# METHOD: Lenovo ThinkPad WMI
# ===========================================================================
function Invoke-LenovoThinkPadWmi {
    param([string]$Target, [string]$ProfilesPath, [string]$BiosPassword, [bool]$WhatIf)

    $profileFile = Join-Path $ProfilesPath 'lenovo-thinkpad.json'
    $profile = Get-Content $profileFile | ConvertFrom-Json

    # Read current boot order
    $currentSetting = (Get-WmiObject -Namespace root\WMI -Class Lenovo_BIOSSetting |
        Where-Object { $_.CurrentSetting -match '^BootOrder,' }).CurrentSetting
    if (-not $currentSetting) { throw "Could not read Lenovo BootOrder setting." }

    $components = ($currentSetting -split ',', 2)[1] -split ':'
    Write-Host "Current BootOrder: $($components -join ' : ')"

    switch ($Target) {
        'PXE' {
            $newOrder = Set-ComponentFirst $components 'PXEBOOT'
            Set-LenovoBiosSetting "BootOrder,$($newOrder -join ':')" $BiosPassword $WhatIf
        }
        'HDD' {
            # NVMe0 first, or HDD0 if NVMe0 not present
            $newOrder = Set-ComponentFirst $components 'NVMe0'
            if (($newOrder[0]) -ne 'NVMe0') { $newOrder = Set-ComponentFirst $components 'HDD0' }
            Set-LenovoBiosSetting "BootOrder,$($newOrder -join ':')" $BiosPassword $WhatIf
        }
        'USB' {
            $newOrder = Set-ComponentFirst $components 'USBHDD'
            Set-LenovoBiosSetting "BootOrder,$($newOrder -join ':')" $BiosPassword $WhatIf
        }
        'OneBoot-PXE' {
            # For one-shot, use generic UEFI BootNext approach (more reliable than WMI)
            Write-Host "Using EFI BootNext for one-time PXE boot"
            Invoke-GenericUefi -Target 'OneBoot-PXE' -WhatIf:$WhatIf
        }
        'OneBoot-HDD' {
            Write-Host "Using EFI BootNext for one-time HDD boot"
            Invoke-GenericUefi -Target 'OneBoot-HDD' -WhatIf:$WhatIf
        }
    }
}

function Set-ComponentFirst([string[]]$components, [string]$target) {
    if ($components -notcontains $target) {
        Write-Warning "'$target' not found in current boot order. Current components: $($components -join ', ')"
        return $components
    }
    $rest = $components | Where-Object { $_ -ne $target }
    return @($target) + $rest
}

function Set-LenovoBiosSetting([string]$settingValue, [string]$password, [bool]$WhatIf) {
    Write-Host "Setting: $settingValue"
    if ($WhatIf) { Write-Host "[WhatIf] Would set $settingValue and save."; return }

    $result = (Get-WmiObject -Namespace root\WMI -Class Lenovo_SetBiosSetting).SetBiosSetting($settingValue)
    if ($result.return -ne 0) { throw "SetBiosSetting failed: return=$($result.return)" }

    $saveResult = (Get-WmiObject -Namespace root\WMI -Class Lenovo_SaveBiosSettings).SaveBiosSettings($password)
    if ($saveResult.return -ne 0) {
        if ($saveResult.return -eq 32) {
            throw "SaveBiosSettings failed: BIOS supervisor password is required but none provided (or wrong password). Return=$($saveResult.return)"
        }
        throw "SaveBiosSettings failed: return=$($saveResult.return)"
    }
    Write-Host "Boot order updated successfully. Change takes effect on next boot."
}

# ===========================================================================
# METHOD: Dell BIOSProvider
# ===========================================================================
function Invoke-DellBiosProvider {
    param([string]$Target, [bool]$WhatIf)

    Import-Module DellBIOSProvider -ErrorAction Stop
    $current = (Get-Item 'DellSmbios:\BootSequence\BootList').CurrentValue
    Write-Host "Current Dell BootList: $current"

    $targetMap = @{
        'PXE' = 'NetworkBoot,HardDisk.List,HardDisk,Optical,UsbStorageDevice'
        'HDD' = 'HardDisk.List,HardDisk,NetworkBoot,Optical,UsbStorageDevice'
        'USB' = 'UsbStorageDevice,HardDisk.List,HardDisk,NetworkBoot,Optical'
    }

    if ($Target -like 'OneBoot-*') {
        Write-Host "Dell one-shot boot — using generic UEFI BootNext"
        Invoke-GenericUefi -Target $Target -WhatIf:$WhatIf
        return
    }

    $newValue = $targetMap[$Target]
    if (-not $newValue) { throw "Unsupported target '$Target' for DellBIOSProvider" }
    Write-Host "Setting Dell BootList to: $newValue"
    if (-not $WhatIf) {
        Set-Item 'DellSmbios:\BootSequence\BootList' -Value $newValue
        Write-Host "Dell boot order updated. Change takes effect on next boot."
    } else {
        Write-Host "[WhatIf] Would set: $newValue"
    }
}

# ===========================================================================
# METHOD: HP HPCMSL
# ===========================================================================
function Invoke-HpCmsl {
    param([string]$Target, [bool]$WhatIf)

    Import-Module HPCMSL -ErrorAction Stop

    if ($Target -like 'OneBoot-*') {
        Write-Host "HP one-shot boot — using generic UEFI BootNext"
        Invoke-GenericUefi -Target $Target -WhatIf:$WhatIf
        return
    }

    # HP boot order uses 'UEFI Boot Order' setting
    try {
        $setting = Get-HPBIOSSettingValue -Name 'UEFI Boot Order' -ErrorAction Stop
        Write-Host "Current HP boot order: $setting"
    } catch {
        Write-Warning "Could not read HP boot order: $_"
    }

    $targetLabel = switch ($Target) {
        'PXE' { 'Network Controller' }
        'HDD' { 'OS Boot Manager' }
        'USB' { 'USB Storage Device' }
    }
    Write-Host "HP: requesting '$targetLabel' first"
    Write-Host "NOTE: HP BIOS boot order value format is model-specific — run Get-HPBIOSSettingsList to verify exact setting name and values for this hardware."
    if (-not $WhatIf) {
        Write-Warning "HP BIOS update via HPCMSL not yet fully implemented — falling back to generic UEFI."
        Invoke-GenericUefi -Target $Target -WhatIf:$WhatIf
    }
}

# ===========================================================================
# METHOD: Generic UEFI (EFI variable manipulation)
# ===========================================================================
function Invoke-GenericUefi {
    param([string]$Target, [bool]$WhatIf)

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.ComponentModel;
using System.Text;

public class UefiBootMgr {
    public const string EFI_GLOBAL_GUID = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}";
    public const uint NV_BS_RT = 7;

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool SetFirmwareEnvironmentVariableEx(string name, string guid, byte[] buf, uint size, uint attrs);

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern uint GetFirmwareEnvironmentVariableEx(string name, string guid, byte[] buf, uint size, out uint attrs);

    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool LookupPrivilegeValue(string s, string n, out long l);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr t, bool d, ref TP s, uint b, IntPtr p, IntPtr r);

    [StructLayout(LayoutKind.Sequential, Pack=4)]
    public struct TP { public uint Count; public long Luid; public uint Attrs; }

    public static void EnableSEP() {
        IntPtr tok;
        OpenProcessToken(GetCurrentProcess(), 0x28, out tok);
        long luid;
        LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid);
        var tp = new TP { Count=1, Luid=luid, Attrs=2 };
        AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }

    // Read EFI variable, return byte[] or null
    public static byte[] ReadVar(string name) {
        var buf = new byte[4096];
        uint attrs = 0;
        uint len = GetFirmwareEnvironmentVariableEx(name, EFI_GLOBAL_GUID, buf, (uint)buf.Length, out attrs);
        if (len == 0) return null;
        var result = new byte[len];
        Array.Copy(buf, result, (int)len);
        return result;
    }

    // Get description from a Boot#### entry (UTF-16 string after the device path)
    public static string GetBootEntryDescription(byte[] data) {
        if (data == null || data.Length < 6) return "";
        // Offset 0: Attributes (4 bytes)
        // Offset 4: FilePathListLength (2 bytes)
        ushort fpLen = BitConverter.ToUInt16(data, 4);
        int descOffset = 6 + fpLen;
        if (descOffset >= data.Length) return "";
        // Description is null-terminated UTF-16LE
        int descLen = data.Length - descOffset;
        // Find null terminator
        for (int i = descOffset; i + 1 < data.Length; i += 2) {
            if (data[i] == 0 && data[i+1] == 0) {
                descLen = i - descOffset;
                break;
            }
        }
        if (descLen <= 0) return "";
        return Encoding.Unicode.GetString(data, descOffset, descLen);
    }
}
'@ -ErrorAction Stop

    [UefiBootMgr]::EnableSEP()

    # Read current BootOrder
    $bootOrderBytes = [UefiBootMgr]::ReadVar('BootOrder')
    if (-not $bootOrderBytes) { throw "Could not read EFI BootOrder variable. SeSystemEnvironmentPrivilege may not be available." }

    $bootNums = for ($i = 0; $i -lt $bootOrderBytes.Length; $i += 2) {
        [BitConverter]::ToUInt16($bootOrderBytes, $i)
    }

    Write-Host "Current EFI BootOrder: $($bootNums | ForEach-Object { '{0:X4}' -f $_ })"

    # Read all boot entries and their descriptions
    $entries = @{}
    foreach ($num in $bootNums) {
        $varName = 'Boot{0:X4}' -f $num
        $data = [UefiBootMgr]::ReadVar($varName)
        if ($data) {
            $desc = [UefiBootMgr]::GetBootEntryDescription($data)
            $entries[$num] = $desc
            Write-Host "  Boot{0:X4}: $desc" -f $num
        }
    }

    # One-time boot (BootNext)
    if ($Target -like 'OneBoot-*') {
        $matchPattern = if ($Target -eq 'OneBoot-PXE') { '*PXE*', '*Network*', '*NIC*', '*LAN*' } else { '*Windows*', '*OS*', '*NVMe*', '*HDD*' }
        $found = $null
        foreach ($num in $bootNums) {
            $desc = $entries[$num]
            foreach ($pat in $matchPattern) {
                if ($desc -like $pat) { $found = $num; break }
            }
            if ($found -ne $null) { break }
        }
        if ($found -eq $null) {
            Write-Warning "Could not find a matching EFI boot entry for $Target. Available entries: $($entries.GetEnumerator() | ForEach-Object { "Boot{0:X4}: $($_.Value)" -f $_.Key })"
            return
        }
        Write-Host "Setting BootNext to Boot{0:X4} ($($entries[$found]))" -f $found
        if (-not $WhatIf) {
            $nextBytes = [BitConverter]::GetBytes([uint16]$found)
            $ok = [UefiBootMgr]::SetFirmwareEnvironmentVariableEx('BootNext', [UefiBootMgr]::EFI_GLOBAL_GUID, $nextBytes, 2, [UefiBootMgr]::NV_BS_RT)
            if (-not $ok) { throw "Failed to write BootNext: err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
            Write-Host "BootNext set. Machine will boot Boot{0:X4} on next boot only." -f $found
        } else {
            Write-Host "[WhatIf] Would set BootNext to Boot{0:X4}" -f $found
        }
        return
    }

    # Permanent boot order change
    $matchPattern = switch ($Target) {
        'PXE' { '*PXE*', '*Network*', '*NIC*', '*LAN*' }
        'HDD' { '*Windows*', '*NVMe*', '*Hard*', '*OS*' }
        'USB' { '*USB*' }
    }

    $targetNums = @()
    foreach ($num in $bootNums) {
        foreach ($pat in $matchPattern) {
            if ($entries[$num] -like $pat) { $targetNums += $num; break }
        }
    }

    if ($targetNums.Count -eq 0) {
        Write-Warning "No EFI boot entry matched pattern for '$Target'. Entries: $($entries.GetEnumerator() | ForEach-Object { "Boot{0:X4}=$($_.Value)" -f $_.Key })"
        return
    }

    $others   = $bootNums | Where-Object { $_ -notin $targetNums }
    $newOrder = @($targetNums) + @($others)

    Write-Host "New EFI BootOrder: $($newOrder | ForEach-Object { 'Boot{0:X4}({1})' -f $_, $entries[$_] })"

    if (-not $WhatIf) {
        $newBytes = [byte[]]($newOrder | ForEach-Object { [BitConverter]::GetBytes([uint16]$_) } | ForEach-Object { $_ })
        # Flatten nested arrays
        $flatBytes = [byte[]]::new($newOrder.Count * 2)
        for ($i = 0; $i -lt $newOrder.Count; $i++) {
            [Array]::Copy([BitConverter]::GetBytes([uint16]$newOrder[$i]), 0, $flatBytes, $i * 2, 2)
        }
        $ok = [UefiBootMgr]::SetFirmwareEnvironmentVariableEx('BootOrder', [UefiBootMgr]::EFI_GLOBAL_GUID, $flatBytes, [uint32]$flatBytes.Length, [UefiBootMgr]::NV_BS_RT)
        if (-not $ok) { throw "Failed to write BootOrder: err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
        Write-Host "EFI BootOrder updated. Change takes effect on next boot."
    } else {
        Write-Host "[WhatIf] Would rewrite BootOrder"
    }
}
