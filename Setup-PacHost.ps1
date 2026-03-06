<#
.SYNOPSIS
    Sets up an IIS-hosted PAC file server for Fiddler proxy routing on iOS devices.

.DESCRIPTION
    - Enables required IIS features on Windows 11 Pro.
    - Detects the machine's LAN IP (or accepts one via parameter).
    - Generates proxy.pac and wpad.dat from the template.
    - Creates an IIS site ("PacHost") serving the PAC files.
    - Adds a Windows Firewall rule to allow inbound traffic on the PAC port.
    - Registers a scheduled task that watches for Fiddler and swaps the PAC
      between PROXY and DIRECT mode automatically.

    Safe to re-run: skips already-enabled features, overwrites PAC files
    with the current IP, and re-registers the scheduled task.

.PARAMETER FiddlerPort
    Port Fiddler listens on (default 8888).

.PARAMETER PacPort
    Port for the IIS PAC site (default 80).

.PARAMETER SitePath
    Physical path for the IIS site (default C:\inetpub\PacHost).

.PARAMETER ProxyIP
    Override auto-detected LAN IP.

.EXAMPLE
    .\Setup-PacHost.ps1
    .\Setup-PacHost.ps1 -FiddlerPort 8866 -PacPort 8080
    .\Setup-PacHost.ps1 -ProxyIP 192.168.1.42
#>

[CmdletBinding()]
param(
    [int]$FiddlerPort = 8888,
    [int]$PacPort     = 80,
    [string]$SitePath = 'C:\inetpub\PacHost',
    [string]$ProxyIP  = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Require elevation ────────────────────────────────────────────────────────
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator. Right-click PowerShell and choose 'Run as administrator'."
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Resolve the logged-in user (not the elevated admin)
$loggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
if ([string]::IsNullOrWhiteSpace($loggedInUser)) {
    $loggedInUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

# ── 1. Enable IIS features ──────────────────────────────────────────────────
Write-Host "`n[1/7] Enabling IIS features..." -ForegroundColor Cyan

$features = @(
    'IIS-WebServerRole',
    'IIS-WebServer',
    'IIS-CommonHttpFeatures',
    'IIS-StaticContent',
    'IIS-DefaultDocument',
    'IIS-HttpErrors',
    'IIS-RequestFiltering',
    'IIS-ManagementConsole'
)

foreach ($feature in $features) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
    if ($state -ne 'Enabled') {
        Write-Host "  Enabling $feature..."
        Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null
    } else {
        Write-Host "  $feature already enabled." -ForegroundColor DarkGray
    }
}

# ── 2. Detect LAN IP ────────────────────────────────────────────────────────
Write-Host "`n[2/7] Detecting LAN IP..." -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($ProxyIP)) {
    $netConfig = Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway -ne $null } |
        Select-Object -First 1

    if ($null -eq $netConfig) {
        Write-Error "Could not auto-detect LAN IP. Pass -ProxyIP manually."
        exit 1
    }

    $ProxyIP = $netConfig.IPv4Address.IPAddress
}

Write-Host "  Using IP: $ProxyIP" -ForegroundColor Green

# ── 3. Generate PAC files ───────────────────────────────────────────────────
Write-Host "`n[3/7] Generating PAC files..." -ForegroundColor Cyan

$templatePath = Join-Path $scriptDir 'proxy.pac.template'
if (-not (Test-Path $templatePath)) {
    Write-Error "Template not found: $templatePath"
    exit 1
}

$template = Get-Content $templatePath -Raw
$timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$pacContent = $template `
    -replace '{{PROXY_IP}}',     $ProxyIP `
    -replace '{{FIDDLER_PORT}}', $FiddlerPort `
    -replace '{{PAC_PORT}}',     $PacPort `
    -replace '{{TIMESTAMP}}',    $timestamp

# Ensure site directory exists
if (-not (Test-Path $SitePath)) {
    New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
}

# Grant the logged-in user write access so the watcher can update PAC files
if (-not [string]::IsNullOrWhiteSpace($loggedInUser)) {
    $acl = Get-Acl $SitePath
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $loggedInUser, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -Path $SitePath -AclObject $acl
    Write-Host "  Granted Modify access to $loggedInUser"
}

# Write proxy.pac and wpad.dat (identical content)
$pacFile  = Join-Path $SitePath 'proxy.pac'
$wpadFile = Join-Path $SitePath 'wpad.dat'

Set-Content -Path $pacFile  -Value $pacContent -Encoding UTF8 -Force
Set-Content -Path $wpadFile -Value $pacContent -Encoding UTF8 -Force

# Copy web.config
$webConfigSrc  = Join-Path $scriptDir 'web.config'
$webConfigDest = Join-Path $SitePath  'web.config'
Copy-Item -Path $webConfigSrc -Destination $webConfigDest -Force

Write-Host "  Written: $pacFile"
Write-Host "  Written: $wpadFile"
Write-Host "  Copied:  $webConfigDest"

# ── 4. Create / update IIS site ─────────────────────────────────────────────
Write-Host "`n[4/7] Configuring IIS site 'PacHost'..." -ForegroundColor Cyan

Import-Module WebAdministration -ErrorAction Stop

$siteName = 'PacHost'

# Stop Default Web Site if it's using the same port
$defaultSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
if ($null -ne $defaultSite) {
    $defaultBindings = $defaultSite.Bindings.Collection | Where-Object { $_.bindingInformation -like "*:${PacPort}:*" }
    if ($defaultBindings) {
        Write-Host "  Stopping 'Default Web Site' (port $PacPort conflict)..." -ForegroundColor Yellow
        Stop-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
    }
}

# Remove existing PacHost site if present (idempotent)
$existing = Get-Website -Name $siteName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    Write-Host "  Removing existing '$siteName' site..."
    Remove-Website -Name $siteName
}

# Create site
New-Website -Name $siteName -PhysicalPath $SitePath -Port $PacPort -Force | Out-Null
Start-Website -Name $siteName
Write-Host "  Site '$siteName' created and started on port $PacPort." -ForegroundColor Green

# ── 5. Firewall rule ────────────────────────────────────────────────────────
Write-Host "`n[5/7] Configuring firewall..." -ForegroundColor Cyan

$fwRuleName = "PacHost (TCP-In $PacPort)"

$existingRule = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
if ($null -eq $existingRule) {
    New-NetFirewallRule `
        -DisplayName $fwRuleName `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $PacPort `
        -Action Allow `
        -Profile Private `
        -Description 'Allow LAN access to PAC host for iOS proxy configuration' | Out-Null
    Write-Host "  Firewall rule '$fwRuleName' created (Private profile only)." -ForegroundColor Green
} else {
    Write-Host "  Firewall rule '$fwRuleName' already exists." -ForegroundColor DarkGray
}

# ── 6. Scheduled task for Fiddler watcher ────────────────────────────────────
Write-Host "`n[6/7] Registering Fiddler watcher scheduled task..." -ForegroundColor Cyan

$taskName = 'FiddlerPacWatcher'

# Resolve the logged-in user (not the elevated admin) for task registration
Write-Host "  Registering task for user: $loggedInUser"

# Remove existing task if present (idempotent)
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $existingTask) {
    Write-Host "  Removing existing '$taskName' task..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# Launch via Launch-Hidden.vbs so no console window ever appears
# (WScript.Shell.Run with window-style 0 prevents it entirely).
$vbsPath = Join-Path $scriptDir 'Launch-Hidden.vbs'
$watcherArgs = "-FiddlerPort $FiddlerPort -PacPort $PacPort -SitePath `"$SitePath`" -ProxyIP `"$ProxyIP`""
$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsPath`" $watcherArgs"
$trigger = New-ScheduledTaskTrigger -AtLogon -User $loggedInUser
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

$principal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Watches for Fiddler and swaps PAC between PROXY and DIRECT mode' | Out-Null

# Start it now so the user doesn't have to log out
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
$taskInfo = Get-ScheduledTask -TaskName $taskName
if ($taskInfo.State -eq 'Running') {
    Write-Host "  Task '$taskName' registered and running." -ForegroundColor Green
} else {
    Write-Host "  Task '$taskName' registered but state is '$($taskInfo.State)'." -ForegroundColor Yellow
    Write-Host "  Check the watcher script path and permissions. It will start at next logon." -ForegroundColor Yellow
}

# ── 7. Summary ──────────────────────────────────────────────────────────────
Write-Host "`n[7/7] Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  PAC URL:  http://${ProxyIP}:${PacPort}/proxy.pac" -ForegroundColor White
Write-Host "  WPAD URL: http://${ProxyIP}:${PacPort}/wpad.dat"  -ForegroundColor White
Write-Host ""
Write-Host "  iOS Setup:" -ForegroundColor Cyan
Write-Host "    Settings > Wi-Fi > tap (i) on your network"
Write-Host "    Configure Proxy > Automatic"
Write-Host "    URL: http://${ProxyIP}:${PacPort}/proxy.pac"
Write-Host ""
Write-Host "  Fiddler:" -ForegroundColor Cyan
Write-Host "    Ensure 'Allow remote computers to connect' is ON"
Write-Host "    Tools > Options > Connections > port $FiddlerPort"
Write-Host ""
Write-Host "  Watcher:" -ForegroundColor Cyan
Write-Host "    Scheduled task '$taskName' is running in the background."
Write-Host "    It starts automatically at logon and restarts on failure."
Write-Host "    Manage with: Get-ScheduledTask -TaskName '$taskName'"
Write-Host ""
Write-Host "  Behavior:" -ForegroundColor Cyan
Write-Host "    Fiddler running  -> PAC routes through ${ProxyIP}:${FiddlerPort}"
Write-Host "    Fiddler stopped  -> PAC returns DIRECT (no disruption)"
Write-Host ""
