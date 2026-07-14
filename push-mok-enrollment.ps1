#Requires -RunAsAdministrator
# push-mok-enrollment.ps1
# Deploys a pre-staged MOK (Machine Owner Key) enrollment request to remote machines
# so that the Juniper CA root is trusted by the Ubuntu shim during Secure Boot PXE boot.
#
# HOW IT WORKS
# ------------
# 1. For each managed machine (sourced from inventory), connect via WinRM as junadmin.
# 2. On the remote machine:
#    a. Check if Juniper CA is already enrolled in MOK (reads MokListRT UEFI variable).
#    b. If not enrolled, build an EFI_SIGNATURE_LIST containing the Juniper CA cert.
#    c. Enable SE_SYSTEM_ENVIRONMENT_PRIVILEGE (required to write UEFI variables).
#    d. Write MokNew UEFI variable  -- shim reads this on next boot.
#    e. Write MokAuth UEFI variable -- SHA256(""), so user just presses Enter at the
#       MokManager prompt. No password entry needed.
# 3. On next reboot, MokManager appears (one screen), user presses Enter to confirm.
#    All subsequent Secure Boot PXE boots work permanently.
#
# This script is idempotent: machines that already have the cert enrolled are skipped.
#
# REQUIREMENTS
# ------------
# - Runs on pc-deploy (192.168.5.141) as SYSTEM or a local admin.
# - Credentials for remote WinRM: $env:USERPROFILE\.juniper\push-cred.xml (same as cert-compliance-push).
# - Juniper CA cert available at http://192.168.5.141/juniper-pxe-ca.cer (served by Caddy).
#
# SCHEDULED TASK
# --------------
# Can be triggered from cert-compliance-push.ps1 or run standalone as a one-shot.
# After the initial push, machines only need this once (MOK survives firmware updates).
#
# Scheduled task: SYSTEM, run after cert-compliance-push (e.g., 09:35 / 13:05 / 16:35).
# Log: C:\inventory\logs\push-mok-enrollment.log

[CmdletBinding()]
param(
    [string]$InventoryApi   = 'https://inventory.juniperdesign.com',
    [string]$FallbackApi    = 'http://192.168.5.141:8080',
    [string]$CertServerBase = 'http://192.168.5.141',
    [string]$CertPath       = 'C:\tftpd64\juniper-pxe-ca.cer',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Continue'
$logDir  = 'C:\inventory\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'push-mok-enrollment.log'
Start-Transcript -Path $logFile -Append -NoClobber:$false | Out-Null

Write-Host "=== push-mok-enrollment  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  on $env:COMPUTERNAME ==="

# ---------------------------------------------------------------------------
# Load WinRM credentials (same DPAPI-encrypted file as cert-compliance-push)
# ---------------------------------------------------------------------------
$credPath = "$env:USERPROFILE\.juniper\push-cred.xml"
$cred = $null
if (Test-Path $credPath) {
    $cred = Import-Clixml $credPath
    Write-Host "Using credentials for '$($cred.UserName)'"
} else {
    Write-Warning "No saved credentials at $credPath - using current session credentials."
}

# ---------------------------------------------------------------------------
# Read Juniper CA cert DER bytes (local copy on pc-deploy)
# ---------------------------------------------------------------------------
if (-not (Test-Path $CertPath)) {
    Write-Error "Juniper CA cert not found at $CertPath - aborting."
    Stop-Transcript | Out-Null
    exit 1
}
$certDerBytes = [IO.File]::ReadAllBytes($CertPath)
Write-Host "Juniper CA cert loaded: $($certDerBytes.Length) bytes from $CertPath"

# Thumbprint for log output (SHA1 of DER cert)
$x509tmp = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certDerBytes)
$certThumbprint = $x509tmp.Thumbprint
Write-Host "Cert thumbprint: $certThumbprint"

# ---------------------------------------------------------------------------
# Get machine list from inventory API
# ---------------------------------------------------------------------------
Write-Host "Fetching machine list from $InventoryApi..."
$machinesJson = $null
try {
    $machinesJson = (Invoke-WebRequest -Uri "$InventoryApi/api/machines" -UseBasicParsing -ErrorAction Stop).Content
} catch {
    Write-Warning "HTTPS failed: $_  -- trying fallback"
    try {
        $machinesJson = (Invoke-WebRequest -Uri "$FallbackApi/api/machines" -UseBasicParsing -ErrorAction Stop).Content
    } catch {
        Write-Error "Could not reach inventory API: $_"
        Stop-Transcript | Out-Null
        exit 1
    }
}
$machines = $machinesJson | ConvertFrom-Json

# Filter: Windows machines with an IP
$targets = @($machines | Where-Object { $_.os -like '*Windows*' -and $_.ip })
Write-Host "Targeting $($targets.Count) Windows machines."

# ---------------------------------------------------------------------------
# Remote scriptblock — runs on each managed machine via Invoke-Command
# ---------------------------------------------------------------------------
$mokEnrollSB = {
    param(
        [byte[]]$CertDer,        # DER-encoded Juniper CA cert
        [string]$CertServerBase  # fallback URL if we need to re-fetch
    )

    # ------------------------------------------------------------------
    # P/Invoke: UEFI variable access + privilege adjustment
    # ------------------------------------------------------------------
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.ComponentModel;

public class UefiVars {
    // Write a UEFI variable (requires SE_SYSTEM_ENVIRONMENT_PRIVILEGE)
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetFirmwareEnvironmentVariableEx(
        string lpName, string lpGuid,
        byte[] pBuffer, uint nSize, uint dwAttributes);

    // Read a UEFI variable
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint GetFirmwareEnvironmentVariableEx(
        string lpName, string lpGuid,
        byte[] pBuffer, uint nSize, out uint pdwAttributes);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(
        IntPtr hProcess, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool LookupPrivilegeValue(
        string lpSystemName, string lpName, out long lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(
        IntPtr TokenHandle, bool DisableAllPrivileges,
        ref TokenPrivileges NewState, uint BufferLength,
        IntPtr PreviousState, IntPtr ReturnLength);

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct TokenPrivileges {
        public uint PrivilegeCount;
        public long Luid;
        public uint Attributes;
    }

    public static void EnableSystemEnvironmentPrivilege() {
        const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
        const uint TOKEN_QUERY             = 0x0008;
        const uint SE_PRIVILEGE_ENABLED    = 0x00000002;

        IntPtr hToken;
        if (!OpenProcessToken(GetCurrentProcess(),
                TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out hToken))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "OpenProcessToken failed");

        long luid;
        if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "LookupPrivilegeValue failed");

        var tp = new TokenPrivileges {
            PrivilegeCount = 1,
            Luid           = luid,
            Attributes     = SE_PRIVILEGE_ENABLED
        };
        AdjustTokenPrivileges(hToken, false, ref tp, 0,
            IntPtr.Zero, IntPtr.Zero);
        int err = Marshal.GetLastWin32Error();
        if (err != 0)
            throw new Win32Exception(err, "AdjustTokenPrivileges failed");
    }
}
'@

    # ------------------------------------------------------------------
    # Constants
    # ------------------------------------------------------------------
    # EFI_CERT_X509_GUID = {a5c059a1-94e4-4aa7-87b5-ab155c2bf072}
    # Encoded as UEFI mixed-endian (Data1/Data2/Data3 LE, Data4 big-endian)
    $X509_GUID_BYTES = [byte[]](
        0xa1, 0x59, 0xc0, 0xa5,   # Data1: a5c059a1 → LE
        0xe4, 0x94,                # Data2: 94e4     → LE
        0xa7, 0x4a,                # Data3: 4aa7     → LE
        0x87, 0xb5, 0xab, 0x15, 0x5c, 0x2b, 0xf0, 0x72  # Data4: big-endian
    )

    # Signature owner GUID (Juniper Design — arbitrary stable GUID)
    # {4a554e49-5045-5220-4465-736967000000}
    $OWNER_GUID_BYTES = [byte[]](
        0x49, 0x4e, 0x55, 0x4a,   # "JUNI"
        0x45, 0x50,                # "PE"
        0x20, 0x52,                # "R "
        0x44, 0x65, 0x73, 0x69, 0x67, 0x00, 0x00, 0x00  # "Desig..."
    )

    # MokNew / MokAuth variable GUID (shim's MOK namespace)
    $MOK_GUID = '{605dab50-e046-4300-abb6-3dd810dd8b23}'

    # UEFI variable attribute: NV | BS | RT
    $UEFI_ATTRS = [uint32]0x7

    # ------------------------------------------------------------------
    # Helper: build EFI_SIGNATURE_LIST for an X.509 DER cert
    # ------------------------------------------------------------------
    function Build-EfiSignatureList([byte[]]$DerCert) {
        $sigSize  = [uint32](16 + $DerCert.Length)  # GUID + cert
        $listSize = [uint32](16 + 4 + 4 + 4 + $sigSize)  # type GUID + 3x uint32 + sig

        $buf = [byte[]]::new($listSize)

        # EFI_SIGNATURE_LIST header
        [Array]::Copy($X509_GUID_BYTES, 0, $buf, 0, 16)                          # SignatureType
        [BitConverter]::GetBytes($listSize).CopyTo($buf, 16)                     # SignatureListSize
        [BitConverter]::GetBytes([uint32]0).CopyTo($buf, 20)                     # SignatureHeaderSize
        [BitConverter]::GetBytes($sigSize).CopyTo($buf, 24)                      # SignatureSize

        # EFI_SIGNATURE_DATA
        [Array]::Copy($OWNER_GUID_BYTES, 0, $buf, 28, 16)                        # SignatureOwner
        [Array]::Copy($DerCert, 0, $buf, 44, $DerCert.Length)                    # SignatureData (DER)

        return $buf
    }

    # ------------------------------------------------------------------
    # Check if UEFI / Secure Boot info available
    # ------------------------------------------------------------------
    $isUEFI = $false
    $sbState = 'unknown'
    try {
        $sb = Confirm-SecureBootUEFI
        $isUEFI  = $true
        $sbState = if ($sb) { 'enabled' } else { 'disabled' }
    } catch {
        # Throws on legacy BIOS or if cmdlet unavailable
        $sbState = 'not-uefi'
    }

    if (-not $isUEFI) {
        return "SKIP: not UEFI (Secure Boot unavailable)"
    }

    # ------------------------------------------------------------------
    # Check if Juniper CA is already in MokListRT
    # (If enrolled, MokListRT contains an EFI_SIGNATURE_LIST with our DER)
    # ------------------------------------------------------------------
    $alreadyEnrolled = $false
    try {
        [UefiVars]::EnableSystemEnvironmentPrivilege()
        $readBuf  = [byte[]]::new(65536)
        $readAttrs = [uint32]0
        $readLen = [UefiVars]::GetFirmwareEnvironmentVariableEx(
            'MokListRT', $MOK_GUID, $readBuf, $readBuf.Length, [ref]$readAttrs)

        if ($readLen -gt 0) {
            # Scan the raw bytes for our cert DER (simple substring check)
            $haystack = [System.Text.Encoding]::Default.GetString($readBuf, 0, [int]$readLen)
            $needle   = [System.Text.Encoding]::Default.GetString($CertDer)
            if ($haystack.Contains($needle)) {
                $alreadyEnrolled = $true
            }
        }
    } catch {
        # GetFirmwareEnvironmentVariableEx returns 0 + sets ERROR_ENVVAR_NOT_FOUND
        # if variable doesn't exist — that's fine, it means no MOKs enrolled yet
    }

    if ($alreadyEnrolled) {
        return "SKIP: Juniper CA already enrolled in MOK (Secure Boot: $sbState)"
    }

    # Check if MokNew is already staged (previous run that hasn't been confirmed yet)
    $alreadyStaged = $false
    try {
        $stageBuf   = [byte[]]::new(65536)
        $stageAttrs = [uint32]0
        $stageLen = [UefiVars]::GetFirmwareEnvironmentVariableEx(
            'MokNew', $MOK_GUID, $stageBuf, $stageBuf.Length, [ref]$stageAttrs)
        if ($stageLen -gt 0) {
            $needle2 = [System.Text.Encoding]::Default.GetString($CertDer)
            $staged  = [System.Text.Encoding]::Default.GetString($stageBuf, 0, [int]$stageLen)
            if ($staged.Contains($needle2)) { $alreadyStaged = $true }
        }
    } catch { }

    if ($alreadyStaged) {
        return "SKIP: MokNew already staged (awaiting reboot + Enter confirmation) (Secure Boot: $sbState)"
    }

    # ------------------------------------------------------------------
    # Build EFI_SIGNATURE_LIST and write MokNew
    # ------------------------------------------------------------------
    $sigList = Build-EfiSignatureList $CertDer

    $ok = [UefiVars]::SetFirmwareEnvironmentVariableEx(
        'MokNew', $MOK_GUID, $sigList, [uint32]$sigList.Length, $UEFI_ATTRS)

    if (-not $ok) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return "FAILED: SetFirmwareEnvironmentVariableEx(MokNew) error $err"
    }

    # ------------------------------------------------------------------
    # Write MokAuth = SHA256("") — user just presses Enter at MokManager
    # No typed password required.
    # ------------------------------------------------------------------
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $emptyHash = $sha256.ComputeHash([byte[]]@())   # 32-byte hash of empty input

    $ok2 = [UefiVars]::SetFirmwareEnvironmentVariableEx(
        'MokAuth', $MOK_GUID, $emptyHash, [uint32]$emptyHash.Length, $UEFI_ATTRS)

    if (-not $ok2) {
        $err2 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        # Non-fatal: MokManager will ask for a password instead of just Enter,
        # but enrollment will still work
        return "PARTIAL: MokNew staged OK but MokAuth failed (error $err2) -- user must type a password at next reboot. (Secure Boot: $sbState)"
    }

    return "OK: MokNew + MokAuth staged. Reboot machine; press Enter at MokManager to confirm. (Secure Boot: $sbState)"
}

# ---------------------------------------------------------------------------
# Push to each target machine
# ---------------------------------------------------------------------------
$sopts = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
$sessionParams = @{ SessionOption = $sopts; ErrorAction = 'SilentlyContinue' }
if ($cred) { $sessionParams['Credential'] = $cred }

$ok = 0; $fail = 0; $skip = 0; $staged = 0
foreach ($m in $targets) {
    $label = "$($m.hostname) ($($m.ip))"
    Write-Host "  [$label]" -NoNewline

    if ($WhatIf) {
        Write-Host " [WhatIf - skipped]" -ForegroundColor DarkGray
        $skip++
        continue
    }

    $session = New-PSSession -ComputerName $m.ip @sessionParams
    if (-not $session) {
        Write-Host " UNREACHABLE" -ForegroundColor Red
        $fail++
        continue
    }

    try {
        $result = Invoke-Command -Session $session -ScriptBlock $mokEnrollSB `
            -ArgumentList (,$certDerBytes), $CertServerBase

        if ($result -like 'OK:*') {
            Write-Host " $result" -ForegroundColor Green
            $staged++
        } elseif ($result -like 'SKIP:*') {
            Write-Host " $result" -ForegroundColor Cyan
            $skip++
        } elseif ($result -like 'PARTIAL:*') {
            Write-Host " $result" -ForegroundColor Yellow
            $staged++
        } else {
            Write-Host " $result" -ForegroundColor Red
            $fail++
        }
        $ok++
    } catch {
        Write-Host " ERROR: $_" -ForegroundColor Red
        $fail++
    } finally {
        Remove-PSSession $session -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "=== Results: Reached=$ok  Staged=$staged  Skipped=$skip  Failed=$fail ===" -ForegroundColor Cyan
Write-Host "Staged machines need ONE reboot + Enter at MokManager to complete enrollment."
Write-Host "After that, Secure Boot PXE boots with the Juniper-signed shim chain work permanently."

Stop-Transcript | Out-Null
