# 05-setup-printers.ps1
# Adds and configures printer queues on a freshly imaged PC.
# Drivers are pulled from the print server on pc-deploy (or a UNC share).
#
# USAGE: .\05-setup-printers.ps1
#        .\05-setup-printers.ps1 -PrintServer \\pc-deploy -DryRun

param(
    [string]$PrintServer = '\\pc-deploy',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# PRINTERS - add entries here
# Each entry: @{ Name='Queue name on server'; LocalAlias='Name on this PC' }
# Leave LocalAlias blank to use the same name as on the server.
# ---------------------------------------------------------------------------
$Printers = @(
    # Example:
    # @{ Name='HP-OfficeJet-Main'; LocalAlias='Main Office Printer' },
    # @{ Name='Brother-Label';     LocalAlias='' },
)

# ---------------------------------------------------------------------------

if ($Printers.Count -eq 0) {
    Write-Host 'No printers defined. Edit $Printers in 05-setup-printers.ps1.' -ForegroundColor Yellow
    exit 0
}

Write-Host "==> Adding $($Printers.Count) printer(s) from $PrintServer..." -ForegroundColor Cyan

foreach ($p in $Printers) {
    $serverQueue = "$PrintServer\$($p.Name)"
    $localName   = if ($p.LocalAlias) { $p.LocalAlias } else { $p.Name }

    Write-Host "  $serverQueue -> '$localName'" -ForegroundColor Cyan
    if ($DryRun) { continue }

    try {
        # Add the printer connection (installs driver automatically from server)
        Add-Printer -ConnectionName $serverQueue -ErrorAction Stop
        # Rename locally if needed
        if ($p.LocalAlias -and $p.LocalAlias -ne $p.Name) {
            $existing = Get-Printer -Name $p.Name -ErrorAction SilentlyContinue
            if ($existing) { Rename-Printer -InputObject $existing -NewName $localName }
        }
        Write-Host "    OK" -ForegroundColor Green
    } catch {
        Write-Host "    WARN: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '==> Printer setup complete.' -ForegroundColor Green
if ($DryRun) { Write-Host '    (Dry run - nothing was actually added.)' -ForegroundColor Yellow }
