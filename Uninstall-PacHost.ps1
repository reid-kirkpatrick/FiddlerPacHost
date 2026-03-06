<#
.SYNOPSIS
    Removes the FiddlerPacHost setup: scheduled task, IIS site, firewall rule,
    and deployed files.

.DESCRIPTION
    Reverses everything Setup-PacHost.ps1 created. Safe to re-run.
    Does NOT uninstall IIS itself (you may be using it for other things).

.PARAMETER PacPort
    Port the IIS PAC site runs on (default 80). Must match what was used
    during setup so the correct firewall rule is removed.

.PARAMETER SitePath
    Physical path of the IIS PacHost site (default C:\inetpub\PacHost).

.EXAMPLE
    .\Uninstall-PacHost.ps1
    .\Uninstall-PacHost.ps1 -PacPort 8080
#>

[CmdletBinding()]
param(
    [int]$PacPort    = 80,
    [string]$SitePath = 'C:\inetpub\PacHost'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Require elevation ────────────────────────────────────────────────────────
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

# ── 1. Scheduled task ───────────────────────────────────────────────────────
Write-Host "`n[1/4] Removing scheduled task..." -ForegroundColor Cyan

$taskName = 'FiddlerPacWatcher'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "  Removed '$taskName'." -ForegroundColor Green
} else {
    Write-Host "  Task '$taskName' not found, skipping." -ForegroundColor DarkGray
}

# ── 2. IIS site ─────────────────────────────────────────────────────────────
Write-Host "`n[2/4] Removing IIS site..." -ForegroundColor Cyan

try {
    Import-Module WebAdministration -ErrorAction Stop
    $site = Get-Website -Name 'PacHost' -ErrorAction SilentlyContinue
    if ($null -ne $site) {
        Stop-Website -Name 'PacHost' -ErrorAction SilentlyContinue
        Remove-Website -Name 'PacHost'
        Write-Host "  Removed IIS site 'PacHost'." -ForegroundColor Green
    } else {
        Write-Host "  Site 'PacHost' not found, skipping." -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  Could not load WebAdministration module (IIS may not be installed). Skipping." -ForegroundColor DarkGray
}

# ── 3. Firewall rule ────────────────────────────────────────────────────────
Write-Host "`n[3/4] Removing firewall rule..." -ForegroundColor Cyan

$fwRuleName = "PacHost (TCP-In $PacPort)"
$rule = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
if ($null -ne $rule) {
    Remove-NetFirewallRule -DisplayName $fwRuleName
    Write-Host "  Removed '$fwRuleName'." -ForegroundColor Green
} else {
    Write-Host "  Rule '$fwRuleName' not found, skipping." -ForegroundColor DarkGray
}

# ── 4. Deployed files ───────────────────────────────────────────────────────
Write-Host "`n[4/4] Removing deployed files..." -ForegroundColor Cyan

if (Test-Path $SitePath) {
    Remove-Item -Recurse -Force $SitePath
    Write-Host "  Removed $SitePath" -ForegroundColor Green
} else {
    Write-Host "  $SitePath not found, skipping." -ForegroundColor DarkGray
}

Write-Host "`nUninstall complete." -ForegroundColor Green
Write-Host "Note: IIS itself was left installed. Disable via 'Turn Windows features on or off' if no longer needed.`n"
